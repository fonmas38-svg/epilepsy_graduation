"""Account-management API: password login + admin/doctor account administration.

This is the REST surface behind the React admin dashboard. It is fully additive:
it introduces new routes only and never touches the existing device/analyze/cloud
endpoints or their auth. Roles reuse the JWTs already issued by `app.auth`
(`create_token` / `require_role`), so a token minted here works everywhere in the
API and vice-versa.

RBAC summary (enforced below):
  * admin  — full control of every account; create doctors & patients (and other
             admins); assign/unassign ANY patient to ANY doctor; enable/disable,
             reset passwords, delete; read the audit log.
  * doctor — create patient accounts (auto-assigned to themselves); view and
             manage ONLY their assigned patients; reset a patient's password.
  * patient/caregiver — may log in and read their own profile via /auth/me;
             no account-administration rights.

Guardrails: unique usernames; only admins create doctor/admin accounts; a user
cannot disable or delete their own account; doctors can never touch a patient
that is not assigned to them; passwords are always stored hashed (PBKDF2).
"""
from __future__ import annotations

import time
from collections import defaultdict

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field

from app import cloud_store, device_store, security, users_store
from app.database import transaction
from app.auth import (
    Role,
    create_token,
    get_current_principal,
    require_role,
)

router = APIRouter(tags=["accounts"])

# Anti-Brute-Force Rate Limiting & High-Security Surveillance
_FAILED_ATTEMPTS: dict[str, list[float]] = defaultdict(list)
_FAILED_IP_ATTEMPTS: dict[str, list[float]] = defaultdict(list)
_MAX_FAILED_ATTEMPTS = 5
_MAX_ADMIN_FAILED_ATTEMPTS = 3  # High-security threshold for admin accounts
_LOCKOUT_WINDOW_SECONDS = 900


def _get_client_ip(request: Request) -> str:
    # Uvicorn's trusted proxy configuration resolves request.client. Never trust
    # an arbitrary client-supplied X-Forwarded-For header here.
    return request.client.host if request.client else "unknown"


def _check_rate_limit(username: str, ip: str) -> None:
    now = time.time()
    cutoff = now - _LOCKOUT_WINDOW_SECONDS
    u_key = username.strip().lower()

    # Username check
    attempts = [t for t in _FAILED_ATTEMPTS[u_key] if t > cutoff]
    _FAILED_ATTEMPTS[u_key] = attempts
    limit = _MAX_ADMIN_FAILED_ATTEMPTS if u_key == "admin" else _MAX_FAILED_ATTEMPTS
    if len(attempts) >= limit:
        users_store.log(
            actor=username,
            actor_role="admin" if u_key == "admin" else "user",
            action="account_lockout_triggered",
            target=f"ip:{ip}",
            detail={"reason": "rate_limit_exceeded", "attempts": len(attempts), "ip": ip},
        )
        raise HTTPException(
            status_code=429,
            detail=f"Too many failed login attempts ({len(attempts)}/{limit}). Account locked for 15 minutes.",
        )

    # IP check (prevents spray attacks)
    ip_attempts = [t for t in _FAILED_IP_ATTEMPTS[ip] if t > cutoff]
    _FAILED_IP_ATTEMPTS[ip] = ip_attempts
    if len(ip_attempts) >= 15:
        raise HTTPException(
            status_code=429,
            detail="Too many requests from this IP. Temporarily blocked for 15 minutes.",
        )


def _record_failed_attempt(username: str, ip: str) -> None:
    now = time.time()
    _FAILED_ATTEMPTS[username.strip().lower()].append(now)
    _FAILED_IP_ATTEMPTS[ip].append(now)


def _reset_attempts(username: str) -> None:
    _FAILED_ATTEMPTS.pop(username.strip().lower(), None)

require_admin = require_role("admin")
require_doctor = require_role("doctor", "admin")


# --------------------------------------------------------------------------- models


class LoginRequest(BaseModel):
    username: str = Field(..., min_length=1)
    password: str = Field(..., min_length=1)


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: Role
    user: dict


class CreateDoctorRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=64)
    name: str = Field(..., min_length=1, max_length=120)
    password: str | None = Field(default=None, min_length=6, max_length=128)


class CreatePatientRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=64)
    name: str = Field(..., min_length=1, max_length=120)
    password: str | None = Field(default=None, min_length=6, max_length=128)
    # admin may target any doctor; ignored (forced to self) for doctor callers.
    doctor_id: str | None = None
    # Clinical and contact fields (optional)
    phone: str | None = Field(default=None, max_length=32)
    age: int | None = Field(default=None, ge=0, le=130)
    diagnosis: str | None = Field(default=None, max_length=200)
    notes: str | None = Field(default=None, max_length=500)
    # Optional family / caregiver member created with the patient
    caregiver_name: str | None = Field(default=None, max_length=120)
    caregiver_username: str | None = Field(default=None, max_length=64)
    caregiver_phone: str | None = Field(default=None, max_length=32)
    caregiver_relation: str | None = Field(default=None, max_length=64)
    caregiver_password: str | None = Field(default=None, min_length=6, max_length=128)


class CreateUserRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=64)
    name: str = Field(..., min_length=1, max_length=120)
    role: Role = "patient"
    password: str | None = Field(default=None, min_length=6, max_length=128)
    doctor_id: str | None = None


class UpdateUserRequest(BaseModel):
    name: str | None = Field(default=None, max_length=120)
    username: str | None = Field(default=None, min_length=3, max_length=64)


class PasswordResetRequest(BaseModel):
    password: str | None = Field(default=None, min_length=6, max_length=128)


class AssignmentRequest(BaseModel):
    patient_id: str
    doctor_id: str


class CaregiverLinkRequest(BaseModel):
    patient_id: str
    caregiver_id: str


class CreateDeviceRequest(BaseModel):
    device_id: str = Field(..., min_length=3, max_length=128)
    patient_id: str
    name: str = Field(default="Headband device", min_length=1, max_length=120)
    enrollment_secret: str | None = Field(default=None, min_length=12, max_length=128)


class RotateDeviceSecretRequest(BaseModel):
    enrollment_secret: str | None = Field(default=None, min_length=12, max_length=128)


# ---------------------------------------------------------------------------- helpers


def _issue_password(explicit: str | None) -> tuple[str, str | None]:
    """Return (hash, generated_plain_or_None). If the caller supplied a password
    we hash it and return None for the plaintext; otherwise we generate a
    one-time password and return it so the admin/doctor can hand it over."""
    if explicit:
        return security.hash_password(explicit), None
    generated = security.generate_password()
    return security.hash_password(generated), generated


def _require_doctor_exists(doctor_id: str) -> dict:
    doc = users_store.get_user(doctor_id)
    if not doc or doc.get("role") != "doctor":
        raise HTTPException(status_code=404, detail="doctor not found")
    return doc


def _patient_view(user: dict) -> dict:
    """Public patient dict enriched with live monitoring status from cloud_store."""
    pub = users_store.public_user(user) or {}
    cloud = cloud_store.get_patient(user["id"]) or {}
    for key in ("diagnosis", "medications", "phone"):
        if cloud.get(key) is not None:
            pub[key] = cloud[key]
    pub["currentStatus"] = cloud.get("currentStatus") or "stable"
    pub["lastUpdated"] = cloud.get("lastUpdated") or cloud.get("updatedAt")
    pub["doctorIds"] = users_store.doctors_for_patient(user["id"])
    pub["caregiverIds"] = users_store.caregivers_for_patient(user["id"])
    return pub


def _accessible_patient_views(user: dict) -> list[dict]:
    """Patient profiles the account may access under the same policy as API routes."""
    role = user.get("role")
    user_id = user.get("id")
    if role == "patient":
        patient_ids = {user_id}
    elif role == "doctor":
        patient_ids = set(users_store.patients_for_doctor(user_id))
    elif role == "caregiver":
        patient_ids = set(users_store.patients_for_caregiver(user_id))
    elif role == "admin":
        patient_ids = {u["id"] for u in users_store.list_users(role="patient")}
    else:
        patient_ids = set()
    patients = [
        candidate for candidate in users_store.list_users(role="patient")
        if candidate["id"] in patient_ids and not candidate.get("disabled")
    ]
    return [_patient_view(patient) for patient in patients]


# ------------------------------------------------------------------------------ auth


@router.post("/auth/login", response_model=LoginResponse)
def login(body: LoginRequest, request: Request):
    """Exchange username + password for a signed JWT with active surveillance & rate-limiting."""
    client_ip = _get_client_ip(request)
    user_agent = request.headers.get("user-agent", "unknown")
    _check_rate_limit(body.username, client_ip)

    user = users_store.get_by_username(body.username)
    if not user or not security.verify_password(body.password, user.get("passwordHash", "")):
        _record_failed_attempt(body.username, client_ip)
        is_admin = body.username.strip().lower() == "admin"
        users_store.log(
            actor=body.username,
            actor_role="admin" if is_admin else "user",
            action="admin_login_failed" if is_admin else "login_failed",
            target=f"ip:{client_ip}",
            detail={
                "ip": client_ip,
                "user_agent": user_agent[:120],
                "reason": "invalid_credentials",
                "severity": "high" if is_admin else "medium",
            },
        )
        raise HTTPException(status_code=401, detail="invalid username or password")

    if user.get("disabled"):
        users_store.log(
            actor=user["id"],
            actor_role=user["role"],
            action="login_rejected_disabled",
            target=f"ip:{client_ip}",
            detail={"ip": client_ip, "username": user["username"]},
        )
        raise HTTPException(status_code=403, detail="account disabled")

    _reset_attempts(body.username)
    token = create_token(user["id"], user["role"], extra={"username": user["username"]})
    is_admin = user["role"] == "admin"
    users_store.log(
        actor=user["id"],
        actor_role=user["role"],
        action="admin_login_success" if is_admin else "login",
        target=user["id"],
        detail={
            "ip": client_ip,
            "user_agent": user_agent[:120],
            "security_level": "maximum" if is_admin else "standard",
            "timestamp": time.time(),
        },
    )
    return LoginResponse(
        access_token=token,
        role=user["role"],
        user=users_store.public_user(user),
    )


@router.get("/auth/me")
def me(principal: dict = Depends(get_current_principal)):
    """Return the account plus patient profiles authorized for this session."""
    user = users_store.get_user(principal.get("sub", ""))
    if user:
        return {
            "user": users_store.public_user(user),
            "patients": _accessible_patient_views(user),
        }
    return {"user": None, "principal": principal}


# ----------------------------------------------------------------------------- admin


@router.get("/admin/overview")
def admin_overview(_: dict = Depends(require_admin)):
    """Dashboard summary cards: user counts by role, assignments, recent audit."""
    return {
        "counts": users_store.counts(),
        "recentAudit": users_store.list_audit(limit=10),
    }


@router.get("/admin/users")
def admin_list_users(
    _: dict = Depends(require_admin),
    role: Role | None = None,
    q: str | None = None,
    include_disabled: bool = True,
):
    users = users_store.list_users(role=role, q=q, include_disabled=include_disabled)
    return {"users": [users_store.public_user(u) for u in users]}


@router.get("/admin/users/{user_id}")
def admin_get_user(user_id: str, _: dict = Depends(require_admin)):
    user = users_store.get_user(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="user not found")
    out = users_store.public_user(user)
    if user.get("role") == "patient":
        out["doctorIds"] = users_store.doctors_for_patient(user_id)
        out["caregiverIds"] = users_store.caregivers_for_patient(user_id)
    elif user.get("role") == "doctor":
        out["patientIds"] = users_store.patients_for_doctor(user_id)
    elif user.get("role") == "caregiver":
        out["patientIds"] = users_store.patients_for_caregiver(user_id)
    return {"user": out}


@router.post("/admin/doctors", status_code=201)
def admin_create_doctor(body: CreateDoctorRequest, actor: dict = Depends(require_admin)):
    if users_store.username_taken(body.username):
        raise HTTPException(status_code=409, detail="username already exists")
    password_hash, generated = _issue_password(body.password)
    try:
        doctor = users_store.create_user(
            username=body.username,
            name=body.name,
            role="doctor",
            password_hash=password_hash,
            created_by=actor.get("sub"),
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    users_store.log(actor.get("sub"), "admin", "create_doctor", target=doctor["id"])
    return {"user": users_store.public_user(doctor), "generatedPassword": generated}


@router.post("/admin/patients", status_code=201)
def admin_create_patient(body: CreatePatientRequest, actor: dict = Depends(require_admin)):
    return _create_patient_account(body, actor, body.doctor_id)


@router.post("/admin/users", status_code=201)
def admin_create_user(body: CreateUserRequest, actor: dict = Depends(require_admin)):
    """General-purpose create for admins (any role, incl. caregiver/admin)."""
    if body.role not in users_store.ROLES:
        raise HTTPException(status_code=422, detail="invalid role")
    if body.role == "patient":
        return _create_patient_account(CreatePatientRequest(**body.model_dump(exclude={"role"})), actor, body.doctor_id)
    if users_store.username_taken(body.username):
        raise HTTPException(status_code=409, detail="username already exists")
    if body.role == "patient" and body.doctor_id:
        _require_doctor_exists(body.doctor_id)
    password_hash, generated = _issue_password(body.password)
    try:
        user = users_store.create_user(
            username=body.username,
            name=body.name,
            role=body.role,
            password_hash=password_hash,
            created_by=actor.get("sub"),
            primary_doctor_id=body.doctor_id if body.role == "patient" else None,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    if body.role == "patient":
        _mirror_patient_to_cloud(user)
        if body.doctor_id:
            users_store.assign_patient(user["id"], body.doctor_id, by=actor.get("sub"))
    users_store.log(actor.get("sub"), "admin", f"create_{body.role}", target=user["id"])
    return {"user": users_store.public_user(user), "generatedPassword": generated}


@router.patch("/admin/users/{user_id}")
def admin_update_user(user_id: str, body: UpdateUserRequest, actor: dict = Depends(require_admin)):
    if not users_store.get_user(user_id):
        raise HTTPException(status_code=404, detail="user not found")
    try:
        updated = users_store.update_user(
            user_id, {"name": body.name, "username": body.username}
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    users_store.log(actor.get("sub"), "admin", "update_user", target=user_id)
    return {"user": users_store.public_user(updated)}


@router.post("/admin/users/{user_id}/password")
def admin_reset_password(user_id: str, body: PasswordResetRequest, actor: dict = Depends(require_admin)):
    if not users_store.get_user(user_id):
        raise HTTPException(status_code=404, detail="user not found")
    password_hash, generated = _issue_password(body.password)
    users_store.set_password(user_id, password_hash)
    users_store.log(actor.get("sub"), "admin", "reset_password", target=user_id)
    return {"ok": True, "generatedPassword": generated}


@router.post("/admin/users/{user_id}/disable")
def admin_disable_user(user_id: str, actor: dict = Depends(require_admin)):
    if user_id == actor.get("sub"):
        raise HTTPException(status_code=400, detail="cannot disable your own account")
    if not users_store.set_disabled(user_id, True):
        raise HTTPException(status_code=404, detail="user not found")
    users_store.log(actor.get("sub"), "admin", "disable_user", target=user_id)
    return {"ok": True}


@router.post("/admin/users/{user_id}/enable")
def admin_enable_user(user_id: str, actor: dict = Depends(require_admin)):
    if not users_store.set_disabled(user_id, False):
        raise HTTPException(status_code=404, detail="user not found")
    users_store.log(actor.get("sub"), "admin", "enable_user", target=user_id)
    return {"ok": True}


@router.delete("/admin/users/{user_id}")
def admin_delete_user(user_id: str, actor: dict = Depends(require_admin)):
    if user_id == actor.get("sub"):
        raise HTTPException(status_code=400, detail="cannot delete your own account")
    if not users_store.delete_user(user_id):
        raise HTTPException(status_code=404, detail="user not found")
    users_store.log(actor.get("sub"), "admin", "delete_user", target=user_id)
    return {"ok": True}


# ------------------------------------------------------------------------ assignments


@router.get("/admin/assignments")
def admin_list_assignments(_: dict = Depends(require_admin)):
    return {"assignments": users_store.list_assignments()}


@router.post("/admin/assignments", status_code=201)
def admin_assign(body: AssignmentRequest, actor: dict = Depends(require_admin)):
    patient = users_store.get_user(body.patient_id)
    if not patient or patient.get("role") != "patient":
        raise HTTPException(status_code=404, detail="patient not found")
    _require_doctor_exists(body.doctor_id)
    row = users_store.assign_patient(body.patient_id, body.doctor_id, by=actor.get("sub"))
    users_store.log(
        actor.get("sub"), "admin", "assign", target=body.patient_id,
        detail={"doctorId": body.doctor_id},
    )
    return {"assignment": row}


@router.delete("/admin/assignments")
def admin_unassign(body: AssignmentRequest, actor: dict = Depends(require_admin)):
    changed = users_store.unassign_patient(body.patient_id, body.doctor_id)
    if not changed:
        raise HTTPException(status_code=404, detail="assignment not found")
    users_store.log(
        actor.get("sub"), "admin", "unassign", target=body.patient_id,
        detail={"doctorId": body.doctor_id},
    )
    return {"ok": True}


@router.get("/admin/audit")
def admin_audit(_: dict = Depends(require_admin), limit: int = Query(200, ge=1, le=1000)):
    return {"audit": users_store.list_audit(limit=limit)}


@router.get("/admin/caregiver-links")
def admin_list_caregiver_links(_: dict = Depends(require_admin)):
    return {"links": users_store.list_caregiver_links()}


@router.post("/admin/caregiver-links", status_code=201)
def admin_link_caregiver(body: CaregiverLinkRequest, actor: dict = Depends(require_admin)):
    patient = users_store.get_user(body.patient_id)
    caregiver = users_store.get_user(body.caregiver_id)
    if not patient or patient.get("role") != "patient":
        raise HTTPException(status_code=404, detail="patient not found")
    if not caregiver or caregiver.get("role") != "caregiver":
        raise HTTPException(status_code=404, detail="caregiver not found")
    link = users_store.link_caregiver(body.patient_id, body.caregiver_id, actor.get("sub"))
    users_store.log(actor.get("sub"), "admin", "link_caregiver", body.patient_id,
                    {"caregiverId": body.caregiver_id})
    return {"link": link}


@router.delete("/admin/caregiver-links")
def admin_unlink_caregiver(body: CaregiverLinkRequest, actor: dict = Depends(require_admin)):
    if not users_store.unlink_caregiver(body.patient_id, body.caregiver_id):
        raise HTTPException(status_code=404, detail="caregiver link not found")
    users_store.log(actor.get("sub"), "admin", "unlink_caregiver", body.patient_id,
                    {"caregiverId": body.caregiver_id})
    return {"ok": True}


def _device_secret(explicit: str | None) -> tuple[str, str | None]:
    generated = explicit or security.generate_password(length=24)
    return generated, None if explicit else generated


@router.get("/admin/devices")
def admin_list_devices(
    patient_id: str | None = None, _: dict = Depends(require_admin)
):
    return {"devices": device_store.list_devices(patient_id)}


@router.post("/admin/devices", status_code=201)
def admin_create_device(body: CreateDeviceRequest, actor: dict = Depends(require_admin)):
    patient = users_store.get_user(body.patient_id)
    if not patient or patient.get("role") != "patient":
        raise HTTPException(status_code=404, detail="patient not found")
    secret, generated = _device_secret(body.enrollment_secret)
    try:
        device = device_store.create_device(
            device_id=body.device_id, patient_id=body.patient_id, name=body.name,
            secret=secret, created_by=actor.get("sub"),
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    users_store.log(actor.get("sub"), "admin", "create_device", body.device_id,
                    {"patientId": body.patient_id})
    return {"device": device, "generatedEnrollmentSecret": generated}


@router.post("/admin/devices/{device_id}/secret")
def admin_rotate_device_secret(
    device_id: str, body: RotateDeviceSecretRequest,
    actor: dict = Depends(require_admin),
):
    secret, generated = _device_secret(body.enrollment_secret)
    device = device_store.rotate_secret(device_id, secret)
    if not device:
        raise HTTPException(status_code=404, detail="device not found")
    users_store.log(actor.get("sub"), "admin", "rotate_device_secret", device_id)
    return {"device": device, "generatedEnrollmentSecret": generated}


@router.post("/admin/devices/{device_id}/disable")
def admin_disable_device(device_id: str, actor: dict = Depends(require_admin)):
    device = device_store.set_disabled(device_id, True)
    if not device:
        raise HTTPException(status_code=404, detail="device not found")
    users_store.log(actor.get("sub"), "admin", "disable_device", device_id)
    return {"device": device}


@router.post("/admin/devices/{device_id}/enable")
def admin_enable_device(device_id: str, actor: dict = Depends(require_admin)):
    device = device_store.set_disabled(device_id, False)
    if not device:
        raise HTTPException(status_code=404, detail="device not found")
    users_store.log(actor.get("sub"), "admin", "enable_device", device_id)
    return {"device": device}


# ---------------------------------------------------------------------------- doctor


@router.get("/doctor/patients")
def doctor_patients(actor: dict = Depends(require_doctor)):
    """Patients assigned to the calling doctor (admins see all patients)."""
    if actor.get("role") == "admin":
        patients = users_store.list_users(role="patient")
    else:
        ids = set(users_store.patients_for_doctor(actor.get("sub")))
        patients = [u for u in users_store.list_users(role="patient") if u["id"] in ids]
    return {"patients": [_patient_view(p) for p in patients]}


@router.post("/doctor/patients", status_code=201)
def doctor_create_patient(body: CreatePatientRequest, actor: dict = Depends(require_doctor)):
    doctor_id = body.doctor_id if actor.get("role") == "admin" else actor.get("sub")
    return _create_patient_account(body, actor, doctor_id)


def _create_patient_account(body: CreatePatientRequest, actor: dict, doctor_id: str | None) -> dict:
    """Account, profile, caregiver and assignment commit together or not at all."""
    if doctor_id:
        _require_doctor_exists(doctor_id)
    password_hash, generated = _issue_password(body.password)
    caregiver_user = None
    cg_generated = None
    try:
        with transaction():
            if body.caregiver_name:
                cg_username = body.caregiver_username or f"cg_{body.username}"
                caregiver_user = users_store.get_by_username(cg_username)
                if caregiver_user and (caregiver_user["role"] != "caregiver" or caregiver_user["disabled"]):
                    raise HTTPException(status_code=409, detail="username is not an active caregiver account")
                if caregiver_user is None:
                    cg_hash, cg_generated = _issue_password(body.caregiver_password)
                    caregiver_user = users_store.create_user(
                        username=cg_username, name=body.caregiver_name, role="caregiver",
                        password_hash=cg_hash, created_by=actor.get("sub"),
                        meta={"phone": body.caregiver_phone, "relation": body.caregiver_relation},
                    )
            patient = users_store.create_user(
                username=body.username, name=body.name, role="patient",
                password_hash=password_hash, created_by=actor.get("sub"), primary_doctor_id=doctor_id,
            )
            cloud_store.upsert_patient(patient["id"], {
                "name": body.name, "diagnosis": body.diagnosis, "phone": body.phone,
                "notes": body.notes, "age": body.age,
            })
            if doctor_id:
                users_store.assign_patient(patient["id"], doctor_id, by=actor.get("sub"))
            if caregiver_user:
                users_store.link_caregiver(patient["id"], caregiver_user["id"], by=actor.get("sub"))
            users_store.log(actor.get("sub"), actor.get("role"), "create_patient", target=patient["id"])
            result = _patient_view(patient)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {
        "user": result, "generatedPassword": generated,
        "caregiver": users_store.public_user(caregiver_user),
        "caregiverGeneratedPassword": cg_generated,
    }


@router.get("/doctor/patients/{patient_id}")
def doctor_get_patient(patient_id: str, actor: dict = Depends(require_doctor)):
    patient = users_store.get_user(patient_id)
    if not patient or patient.get("role") != "patient":
        raise HTTPException(status_code=404, detail="patient not found")
    if actor.get("role") != "admin" and not users_store.is_assigned(patient_id, actor.get("sub")):
        raise HTTPException(status_code=403, detail="patient not assigned to you")
    return {"user": _patient_view(patient)}


@router.post("/doctor/patients/{patient_id}/password")
def doctor_reset_patient_password(
    patient_id: str, body: PasswordResetRequest, actor: dict = Depends(require_doctor)
):
    patient = users_store.get_user(patient_id)
    if not patient or patient.get("role") != "patient":
        raise HTTPException(status_code=404, detail="patient not found")
    if actor.get("role") != "admin" and not users_store.is_assigned(patient_id, actor.get("sub")):
        raise HTTPException(status_code=403, detail="patient not assigned to you")
    password_hash, generated = _issue_password(body.password)
    users_store.set_password(patient_id, password_hash)
    users_store.log(actor.get("sub"), actor.get("role"), "reset_password", target=patient_id)
    return {"ok": True, "generatedPassword": generated}


# ----------------------------------------------------------------------------- utils


def _mirror_patient_to_cloud(patient: dict) -> None:
    """Register a newly created patient in the monitoring cloud store so the
    device pipeline and Flutter app immediately see them (best-effort)."""
    try:
        cloud_store.upsert_patient(
            patient["id"],
            {"name": patient["name"], "currentStatus": "stable"},
        )
    except Exception:  # pragma: no cover - never block account creation on this
        pass


# ---------------------------------------------------------------- patient self-service


require_patient = require_role("patient", "admin")


class CreateCaregiverRequest(BaseModel):
    """Payload when a patient adds a new family member from their own account."""
    name: str = Field(..., min_length=1, max_length=120)
    username: str = Field(..., min_length=3, max_length=64)
    phone: str | None = Field(default=None, max_length=32)
    relation: str | None = Field(default=None, max_length=64)
    password: str | None = Field(default=None, min_length=6, max_length=128)


class UpdateCaregiverRequest(BaseModel):
    name: str | None = Field(default=None, max_length=120)
    phone: str | None = Field(default=None, max_length=32)
    relation: str | None = Field(default=None, max_length=64)


@router.get("/patient/caregivers")
def patient_list_caregivers(actor: dict = Depends(require_patient)):
    """List all family / caregiver accounts linked to the calling patient."""
    patient_id = actor.get("sub")
    caregiver_ids = users_store.caregivers_for_patient(patient_id, include_disabled=True)
    active_ids = set(users_store.caregivers_for_patient(patient_id))
    caregivers = []
    for cg_id in caregiver_ids:
        cg = users_store.get_user(cg_id)
        if cg:
            user_data = users_store.public_user(cg)
            user_data["accountDisabled"] = cg["disabled"]
            user_data["disabled"] = cg_id not in active_ids
            user_data["phone"] = cg.get("meta", {}).get("phone")
            user_data["relation"] = cg.get("meta", {}).get("relation")
            try:
                extra = cloud_store.get_patient(cg_id)
                if extra:
                    user_data["phone"] = extra.get("phone")
                    user_data["relation"] = extra.get("relation")
            except Exception:
                pass
            caregivers.append(user_data)
    return {"caregivers": caregivers}


@router.post("/patient/caregivers", status_code=201)
def patient_add_caregiver(body: CreateCaregiverRequest, actor: dict = Depends(require_patient)):
    """A patient creates and links a new family member account to themselves.

    This creates a full caregiver account (with username + password) and
    immediately links it to the calling patient so they can receive alerts.
    """
    patient_id = actor.get("sub")
    if users_store.username_taken(body.username):
        raise HTTPException(status_code=409, detail="اسم المستخدم مستخدم بالفعل")
    password_hash, generated = _issue_password(body.password)
    try:
        caregiver = users_store.create_user(
            username=body.username,
            name=body.name,
            role="caregiver",
            password_hash=password_hash,
            created_by=patient_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    # Store extra fields (phone, relation) in the cloud store if available.
    if body.phone or body.relation:
        try:
            cloud_store.upsert_patient(caregiver["id"], {
                "phone": body.phone,
                "relation": body.relation,
            })
        except Exception:
            pass
    users_store.link_caregiver(patient_id, caregiver["id"], by=patient_id)
    users_store.log(patient_id, "patient", "add_caregiver", caregiver["id"],
                    {"username": body.username})
    return {
        "caregiver": users_store.public_user(caregiver),
        "generatedPassword": generated,
    }


@router.patch("/patient/caregivers/{caregiver_id}")
def patient_update_caregiver(
    caregiver_id: str,
    body: UpdateCaregiverRequest,
    actor: dict = Depends(require_patient),
):
    """A patient updates name / phone / relation of one of their caregivers."""
    patient_id = actor.get("sub")
    # Verify the caregiver is actually linked to this patient.
    if caregiver_id not in users_store.caregivers_for_patient(patient_id):
        raise HTTPException(status_code=403, detail="هذا الفرد غير مرتبط بحسابك")
    cg = users_store.get_user(caregiver_id)
    if not cg or cg.get("role") != "caregiver":
        raise HTTPException(status_code=404, detail="لم يتم العثور على الفرد")
    try:
        updated = users_store.update_user(caregiver_id, {"name": body.name})
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    if body.phone or body.relation:
        try:
            cloud_store.upsert_patient(caregiver_id, {
                "phone": body.phone,
                "relation": body.relation,
            })
        except Exception:
            pass
    users_store.log(patient_id, "patient", "update_caregiver", caregiver_id)
    return {"caregiver": users_store.public_user(updated)}


@router.post("/patient/caregivers/{caregiver_id}/disable")
def patient_disable_caregiver(caregiver_id: str, actor: dict = Depends(require_patient)):
    """A patient temporarily disables a family member's access."""
    return _set_caregiver_access(actor, caregiver_id, disabled=True)


@router.post("/patient/caregivers/{caregiver_id}/enable")
def patient_enable_caregiver(caregiver_id: str, actor: dict = Depends(require_patient)):
    return _set_caregiver_access(actor, caregiver_id, disabled=False)


def _set_caregiver_access(actor: dict, caregiver_id: str, *, disabled: bool) -> dict:
    patient_id = actor.get("sub")
    if caregiver_id not in users_store.caregivers_for_patient(patient_id, include_disabled=True):
        raise HTTPException(status_code=403, detail="هذا الفرد غير مرتبط بحسابك")
    try:
        changed = users_store.set_caregiver_link_disabled(patient_id, caregiver_id, disabled)
    except ValueError as exc:
        raise HTTPException(status_code=403, detail=str(exc)) from exc
    if not changed:
        raise HTTPException(status_code=404, detail="لم يتم العثور على الرابط")
    users_store.log(patient_id, "patient", "disable_caregiver_link" if disabled else "enable_caregiver_link", caregiver_id)
    return {"ok": True}

