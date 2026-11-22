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

from app import account_sessions_store, cloud_store, device_store, security, users_store
from app.database import transaction
from app.auth import (
    JWT_EXPIRE_MINUTES,
    Role,
    create_token,
    decode_token_for_refresh,
    get_current_principal,
    issue_access_token,
    require_role,
    _extract_bearer,
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
    device_name: str = Field(default="Unknown device", min_length=1, max_length=120)
    platform: str = Field(default="unknown", min_length=1, max_length=32)
    device_id: str | None = Field(default=None, max_length=128)


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: Role
    user: dict


class RefreshResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int
    user: dict


class CreateDoctorRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=64)
    name: str = Field(..., min_length=1, max_length=120)
    password: str | None = Field(default=None, min_length=6, max_length=128)
    email: str | None = Field(default=None, max_length=254)
    phone: str | None = Field(default=None, max_length=32)
    license_number: str | None = Field(default=None, max_length=64)
    specialization: str | None = Field(default=None, max_length=120)
    hospital_affiliation: str | None = Field(default=None, max_length=180)
    national_id: str | None = Field(default=None, max_length=32)
    moh_override: bool = False
    idempotency_key: str | None = Field(default=None, max_length=128)


class VerifyMohRequest(BaseModel):
    license_number: str = Field(..., min_length=2, max_length=64)
    national_id: str | None = Field(default=None, max_length=32)
    name: str | None = Field(default=None, max_length=180)


class CreatePatientRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=64)
    name: str = Field(..., min_length=1, max_length=120)
    password: str | None = Field(default=None, min_length=6, max_length=128)
    email: str | None = Field(default=None, max_length=254)
    # admin may target any doctor; ignored (forced to self) for doctor callers.
    doctor_id: str | None = None
    # Clinical and contact fields (optional)
    phone: str | None = Field(default=None, max_length=32)
    age: int | None = Field(default=None, ge=0, le=130)
    gender: str | None = Field(default=None, max_length=24)
    emergency_contact: str | None = Field(default=None, max_length=120)
    diagnosis: str | None = Field(default=None, max_length=200)
    notes: str | None = Field(default=None, max_length=500)
    # Optional family / caregiver member created with the patient
    caregiver_name: str | None = Field(default=None, max_length=120)
    caregiver_username: str | None = Field(default=None, max_length=64)
    caregiver_phone: str | None = Field(default=None, max_length=32)
    caregiver_relation: str | None = Field(default=None, max_length=64)
    caregiver_password: str | None = Field(default=None, min_length=6, max_length=128)
    idempotency_key: str | None = Field(default=None, max_length=128)


class CreateUserRequest(BaseModel):
    username: str = Field(..., min_length=3, max_length=64)
    name: str = Field(..., min_length=1, max_length=120)
    role: Role = "patient"
    password: str | None = Field(default=None, min_length=6, max_length=128)
    email: str | None = Field(default=None, max_length=254)
    doctor_id: str | None = None


class UpdateUserRequest(BaseModel):
    name: str | None = Field(default=None, max_length=120)
    username: str | None = Field(default=None, min_length=3, max_length=64)
    email: str | None = Field(default=None, max_length=254)


class PasswordResetRequest(BaseModel):
    password: str | None = Field(default=None, min_length=6, max_length=128)


class ChangePasswordRequest(BaseModel):
    current_password: str = Field(..., min_length=1, max_length=128)
    new_password: str = Field(..., min_length=12, max_length=128)


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
    if user["role"] in ("patient", "caregiver"):
        conflicting = account_sessions_store.get_active_session_on_other_device(
            user["id"], body.device_id
        )
        if conflicting:
            users_store.log(
                actor=user["id"],
                actor_role=user["role"],
                action="login_rejected_device_conflict",
                target=f"ip:{client_ip}",
                detail={
                    "ip": client_ip,
                    "device_id": body.device_id,
                    "conflicting_session_id": conflicting.get("id"),
                    "conflicting_device_id": conflicting.get("device_id"),
                },
            )
            raise HTTPException(
                status_code=409,
                detail="هذا الحساب مسجل ونشط حالياً على جهاز آخر. يرجى تسجيل الخروج من الجهاز السابق أولاً.",
            )

    is_admin = user["role"] == "admin"
    with transaction():
        token = create_token(user["id"], user["role"], extra={"username": user["username"]},
            session_context={
                "device_name": body.device_name,
                "platform": body.platform,
                "device_id": body.device_id,
                "is_hardware_bound": bool(body.device_id and user["role"] in ("patient", "caregiver")),
            },
            expected_session_version=int(user["sessionVersion"]))
        users_store.log(
            actor=user["id"], actor_role=user["role"],
            action="admin_login_success" if is_admin else "login", target=user["id"],
            detail={"ip": client_ip, "user_agent": user_agent[:120],
                "security_level": "maximum" if is_admin else "standard", "timestamp": time.time()},
        )
    return LoginResponse(
        access_token=token,
        role=user["role"],
        user=users_store.public_user(user),
    )


@router.post("/auth/refresh", response_model=RefreshResponse)
def refresh_session_token(request: Request):
    """Issue a fresh access token for an active, unrevoked session."""
    raw_token = _extract_bearer(request.headers.get("authorization"))
    try:
        claims = decode_token_for_refresh(raw_token)
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Invalid token for refresh") from exc

    role = claims.get("role")
    sub = claims.get("sub")
    sid = claims.get("sid")
    version = claims.get("session_version", 0)

    if role not in ("patient", "caregiver", "doctor", "admin") or not sid or not sub:
        raise HTTPException(status_code=401, detail="Token cannot be refreshed")

    session = account_sessions_store.refresh_session(sid, str(sub), int(version))
    if not session:
        users_store.log(
            actor=str(sub),
            actor_role=str(role),
            action="session_refresh_rejected",
            target=f"session:{sid}",
            detail={"reason": "session_inactive_or_revoked"},
        )
        raise HTTPException(status_code=401, detail="Session is inactive or revoked; sign in again")

    user = users_store.get_user(str(sub))
    if not user or user.get("disabled"):
        raise HTTPException(status_code=401, detail="Account is disabled")

    new_token = issue_access_token(
        subject=user["id"],
        role=user["role"],
        sid=sid,
        session_version=int(user["sessionVersion"]),
        extra={"username": user["username"]},
    )

    users_store.log(
        actor=user["id"],
        actor_role=user["role"],
        action="session_refreshed",
        target=f"session:{sid}",
        detail={"device_name": session.get("device_name"), "platform": session.get("platform")},
    )

    return RefreshResponse(
        access_token=new_token,
        token_type="bearer",
        expires_in=JWT_EXPIRE_MINUTES * 60,
        user=users_store.public_user(user),
    )


@router.post("/auth/password")
def change_own_password(
    body: ChangePasswordRequest, request: Request,
    principal: dict = Depends(require_role("patient", "caregiver", "doctor", "admin")),
):
    user = users_store.get_user(principal["sub"])
    if not user:
        raise HTTPException(status_code=401, detail="account unavailable")
    ip = _get_client_ip(request)
    _check_rate_limit(user["username"], ip)
    if not security.verify_password(body.current_password, user["passwordHash"]):
        _record_failed_attempt(user["username"], ip)
        raise HTTPException(status_code=400, detail="current password is incorrect")
    if body.current_password == body.new_password:
        raise HTTPException(status_code=400, detail="new password must be different")
    users_store.set_password(user["id"], security.hash_password(body.new_password))
    _reset_attempts(user["username"])
    users_store.log(user["id"], user["role"], "change_own_password", target=user["id"])
    # set_password increments the version, invalidating all old login tokens.
    return {"ok": True, "sign_in_required": True}


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


require_account = require_role("patient", "caregiver", "doctor", "admin")


@router.get("/auth/sessions")
def own_sessions(principal: dict = Depends(require_account)):
    return account_sessions_store.list_for_user(principal["sub"], principal["sid"])


@router.post("/auth/logout")
def logout_current_session(principal: dict = Depends(require_account)):
    with transaction():
        account_sessions_store.revoke(principal["sub"], session_id=principal["sid"])
        users_store.log(principal["sub"], principal["role"], "logout_session", principal["sid"])
    return {"ok": True, "sign_in_required": True}


@router.post("/auth/sessions/revoke-others")
def revoke_other_sessions(principal: dict = Depends(require_account)):
    with transaction():
        count = account_sessions_store.revoke(principal["sub"], except_id=principal["sid"])
        users_store.log(principal["sub"], principal["role"], "revoke_other_sessions", principal["sub"], {"count": count})
    return {"ok": True, "revoked": count}


@router.delete("/auth/sessions/{session_id}")
def revoke_own_session(session_id: str, principal: dict = Depends(require_account)):
    with transaction():
        if account_sessions_store.revoke(principal["sub"], session_id=session_id) is None:
            raise HTTPException(status_code=404, detail="session not found")
        users_store.log(principal["sub"], principal["role"], "revoke_session", session_id)
    return {"ok": True, "sign_in_required": session_id == principal["sid"]}


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


@router.post("/admin/doctors/verify-moh")
def admin_verify_doctor_moh(body: VerifyMohRequest, actor: dict = Depends(require_admin)):
    """Verify a doctor's professional license against the MOH registry (#8)."""
    result = users_store.verify_moh_license(
        license_number=body.license_number,
        national_id=body.national_id,
        name=body.name,
    )
    users_store.log(
        actor.get("sub"),
        "admin",
        "verify_doctor_moh",
        target=body.license_number.strip(),
        detail={"verified": result["verified"], "status": result["status"]},
    )
    return result


@router.post("/admin/doctors", status_code=201)
def admin_create_doctor(body: CreateDoctorRequest, actor: dict = Depends(require_admin)):
    actor_id = str(actor.get("sub") or "admin")
    cached = users_store.get_idempotent_response(
        body.idempotency_key, actor_id, "/admin/doctors"
    )
    if cached is not None:
        return cached["payload"]

    if users_store.username_taken(body.username):
        raise HTTPException(status_code=409, detail="username already exists")

    moh_result = None
    if body.license_number and body.license_number.strip():
        moh_result = users_store.verify_moh_license(
            license_number=body.license_number,
            national_id=body.national_id,
            name=body.name,
        )
        if not moh_result["verified"] and not body.moh_override:
            raise HTTPException(
                status_code=422,
                detail=moh_result["message"],
            )

    password_hash, generated = _issue_password(body.password)
    meta: dict = {}
    if body.phone:
        meta["phone"] = body.phone.strip()
    if body.license_number:
        meta["licenseNumber"] = body.license_number.strip()
    if body.specialization:
        meta["specialization"] = body.specialization.strip()
    if body.hospital_affiliation:
        meta["hospitalAffiliation"] = body.hospital_affiliation.strip()
    if body.national_id:
        meta["nationalId"] = body.national_id.strip()

    try:
        with transaction():
            doctor = users_store.create_user(
                username=body.username,
                name=body.name,
                email=body.email,
                role="doctor",
                password_hash=password_hash,
                created_by=actor.get("sub"),
                meta=meta,
            )
            profile_dict = None
            if body.license_number and body.license_number.strip():
                profile_dict = users_store.upsert_doctor_profile(
                    doctor["id"],
                    license_number=body.license_number.strip(),
                    specialization=(body.specialization or "طب الأعصاب والصرع").strip(),
                    hospital_affiliation=(body.hospital_affiliation or "غير محدد").strip(),
                    national_id=(body.national_id or f"NID-{doctor['id'][:12]}").strip(),
                    phone=(body.phone or "0000000000").strip(),
                    moh_verified=bool(moh_result and moh_result["verified"]),
                    moh_status=(moh_result["status"] if moh_result else "not_checked"),
                    moh_override_by=(actor_id if body.moh_override and not (moh_result and moh_result["verified"]) else None),
                )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))

    action_name = (
        "create_doctor_moh_override"
        if (body.moh_override and moh_result and not moh_result["verified"])
        else "create_doctor"
    )
    users_store.log(
        actor.get("sub"),
        "admin",
        action_name,
        target=doctor["id"],
        detail={
            "license_number": body.license_number,
            "moh_verified": bool(moh_result and moh_result["verified"]),
            "moh_override": bool(body.moh_override),
        },
    )
    pub = users_store.public_user(doctor)
    if profile_dict:
        pub["doctorProfile"] = users_store.get_doctor_profile(doctor["id"])
    response_payload = {"user": pub, "generatedPassword": generated}
    users_store.save_idempotent_response(
        body.idempotency_key, actor_id, "/admin/doctors", 201, response_payload
    )
    return response_payload


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
            email=body.email,
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
            user_id, {"name": body.name, "username": body.username, "email": body.email}
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


@router.post("/admin/users/{user_id}/revoke-sessions")
def admin_revoke_user_sessions(user_id: str, actor: dict = Depends(require_admin)):
    user = users_store.get_user(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="user not found")
    with transaction():
        count = account_sessions_store.revoke(user_id) or 0
        users_store.log(
            actor.get("sub"),
            "admin",
            "admin_revoke_user_sessions",
            target=user_id,
            detail={"revoked_count": count},
        )
    return {"ok": True, "revoked": count}


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


@router.get("/doctor/dashboard-summary")
def doctor_dashboard_summary(actor: dict = Depends(require_doctor)):
    """Aggregated summary for Doctor Home: patient counts by risk status, pending alert reviews, and patient cards (#4)."""
    from app import outcomes_store

    if actor.get("role") == "admin":
        patients = users_store.list_users(role="patient")
    else:
        ids = set(users_store.patients_for_doctor(actor.get("sub")))
        patients = [u for u in users_store.list_users(role="patient") if u["id"] in ids]

    views = [_patient_view(p) for p in patients if not p.get("disabled")]
    high_risk = 0
    watch_count = 0
    stable_count = 0
    pending_reviews = 0
    critical_alerts = 0

    for v in views:
        pid = v["id"]
        status = (v.get("currentStatus") or "stable").lower()
        if status in ("high_risk", "highrisk", "critical"):
            high_risk += 1
        elif status == "watch":
            watch_count += 1
        else:
            stable_count += 1

        try:
            p_cloud = cloud_store.get_patient(pid) or {}
            alerts = p_cloud.get("alerts") or []
            outcomes = outcomes_store.list_for_patient(pid)
            adjudicated_alert_ids = {
                o.get("alert_id") for o in outcomes if o.get("alert_id")
            }
            p_pending = 0
            p_critical = 0
            for a in alerts:
                aid = a.get("id")
                sev = (a.get("severity") or "").lower()
                if sev == "critical" and not a.get("acknowledged"):
                    p_critical += 1
                if aid and aid not in adjudicated_alert_ids:
                    p_pending += 1
            v["pendingReviewsCount"] = p_pending
            v["criticalAlertsCount"] = p_critical
            pending_reviews += p_pending
            critical_alerts += p_critical
        except Exception:
            v["pendingReviewsCount"] = 0
            v["criticalAlertsCount"] = 0

    return {
        "totalPatients": len(views),
        "highRiskCount": high_risk,
        "watchCount": watch_count,
        "stableCount": stable_count,
        "pendingReviewsCount": pending_reviews,
        "criticalAlertsCount": critical_alerts,
        "patients": views,
    }


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
    actor_id = str(actor.get("sub") or "doctor")
    cached = users_store.get_idempotent_response(
        body.idempotency_key, actor_id, "/patients/create"
    )
    if cached is not None:
        return cached["payload"]

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
            pat_meta = {}
            if body.phone:
                pat_meta["phone"] = body.phone
            if body.gender:
                pat_meta["gender"] = body.gender
            if body.emergency_contact:
                pat_meta["emergencyContact"] = body.emergency_contact
            patient = users_store.create_user(
                username=body.username, name=body.name, email=body.email, role="patient",
                password_hash=password_hash, created_by=actor.get("sub"), primary_doctor_id=doctor_id,
                meta=pat_meta,
            )
            cloud_store.upsert_patient(patient["id"], {
                "name": body.name, "diagnosis": body.diagnosis, "phone": body.phone,
                "notes": body.notes, "age": body.age,
                "gender": body.gender, "emergencyContact": body.emergency_contact,
            })
            if doctor_id:
                users_store.assign_patient(patient["id"], doctor_id, by=actor.get("sub"))
            if caregiver_user:
                users_store.link_caregiver(patient["id"], caregiver_user["id"], by=actor.get("sub"))
            users_store.log(actor.get("sub"), actor.get("role"), "create_patient", target=patient["id"])
            result = _patient_view(patient)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    payload = {
        "user": result, "generatedPassword": generated,
        "caregiver": users_store.public_user(caregiver_user),
        "caregiverGeneratedPassword": cg_generated,
    }
    users_store.save_idempotent_response(
        body.idempotency_key, actor_id, "/patients/create", 201, payload
    )
    return payload


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
                    for field in ("phone", "relation"):
                        if field not in cg.get("meta", {}):
                            user_data[field] = extra.get(field)
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
    from app.database import transaction
    try:
        with transaction():
            caregiver = users_store.create_user(
                username=body.username, name=body.name, role="caregiver",
                password_hash=password_hash, created_by=patient_id,
                meta={"phone": body.phone, "relation": body.relation},
            )
            users_store.link_caregiver(patient_id, caregiver["id"], by=patient_id)
            users_store.log(patient_id, "patient", "add_caregiver", caregiver["id"],
                            {"username": body.username})
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
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
    if body.name is not None and not body.name.strip():
        raise HTTPException(status_code=422, detail="name must not be blank")
    from app.database import transaction
    patch = {}
    if body.name is not None:
        patch["name"] = body.name
    metadata = dict(cg.get("meta", {}))
    # Explicit empty/null clears a field; absent fields remain unchanged.
    for field in ("phone", "relation"):
        if field in body.model_fields_set:
            metadata[field] = getattr(body, field)
    patch["meta"] = metadata
    try:
        with transaction():
            updated = users_store.update_user(caregiver_id, patch)
            users_store.log(patient_id, "patient", "update_caregiver", caregiver_id)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
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

