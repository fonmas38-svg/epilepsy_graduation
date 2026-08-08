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

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from app import cloud_store, security, users_store
from app.auth import (
    Role,
    create_token,
    get_current_principal,
    require_role,
)

router = APIRouter(tags=["accounts"])

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
    pub["currentStatus"] = cloud.get("currentStatus")
    pub["lastUpdated"] = cloud.get("lastUpdated")
    pub["doctorIds"] = users_store.doctors_for_patient(user["id"])
    return pub


# ------------------------------------------------------------------------------ auth


@router.post("/auth/login", response_model=LoginResponse)
def login(body: LoginRequest):
    """Exchange username + password for a signed JWT (same tokens as /auth/token)."""
    user = users_store.get_by_username(body.username)
    if not user or not security.verify_password(body.password, user.get("passwordHash", "")):
        raise HTTPException(status_code=401, detail="invalid username or password")
    if user.get("disabled"):
        raise HTTPException(status_code=403, detail="account disabled")
    token = create_token(user["id"], user["role"], extra={"username": user["username"]})
    users_store.log(user["id"], user["role"], "login", target=user["id"])
    return LoginResponse(
        access_token=token,
        role=user["role"],
        user=users_store.public_user(user),
    )


@router.get("/auth/me")
def me(principal: dict = Depends(get_current_principal)):
    """Return the current principal's account (or the raw token claims if the
    subject is not a stored user, e.g. a device or legacy token)."""
    user = users_store.get_user(principal.get("sub", ""))
    if user:
        return {"user": users_store.public_user(user)}
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
    elif user.get("role") == "doctor":
        out["patientIds"] = users_store.patients_for_doctor(user_id)
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
    if users_store.username_taken(body.username):
        raise HTTPException(status_code=409, detail="username already exists")
    if body.doctor_id:
        _require_doctor_exists(body.doctor_id)
    password_hash, generated = _issue_password(body.password)
    try:
        patient = users_store.create_user(
            username=body.username,
            name=body.name,
            role="patient",
            password_hash=password_hash,
            created_by=actor.get("sub"),
            primary_doctor_id=body.doctor_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    _mirror_patient_to_cloud(patient)
    if body.doctor_id:
        users_store.assign_patient(patient["id"], body.doctor_id, by=actor.get("sub"))
    users_store.log(actor.get("sub"), "admin", "create_patient", target=patient["id"])
    return {"user": _patient_view(patient), "generatedPassword": generated}


@router.post("/admin/users", status_code=201)
def admin_create_user(body: CreateUserRequest, actor: dict = Depends(require_admin)):
    """General-purpose create for admins (any role, incl. caregiver/admin)."""
    if body.role not in users_store.ROLES:
        raise HTTPException(status_code=422, detail="invalid role")
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
    """A doctor creates a patient auto-assigned to themselves. Admins may pass
    an explicit doctor_id; for doctors it is forced to their own id."""
    if users_store.username_taken(body.username):
        raise HTTPException(status_code=409, detail="username already exists")
    if actor.get("role") == "admin":
        doctor_id = body.doctor_id
        if doctor_id:
            _require_doctor_exists(doctor_id)
    else:
        doctor_id = actor.get("sub")
    password_hash, generated = _issue_password(body.password)
    try:
        patient = users_store.create_user(
            username=body.username,
            name=body.name,
            role="patient",
            password_hash=password_hash,
            created_by=actor.get("sub"),
            primary_doctor_id=doctor_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc))
    _mirror_patient_to_cloud(patient)
    if doctor_id:
        users_store.assign_patient(patient["id"], doctor_id, by=actor.get("sub"))
    users_store.log(actor.get("sub"), actor.get("role"), "create_patient", target=patient["id"])
    return {"user": _patient_view(patient), "generatedPassword": generated}


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
