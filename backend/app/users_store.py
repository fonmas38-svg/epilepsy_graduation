"""SQL-backed account, assignment, and audit store.

The public functions preserve the former JSON-store contract so routers and
clients do not need a coordinated migration.
"""
from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from sqlalchemy import delete, func, insert, select, update
from sqlalchemy.exc import IntegrityError

from app import security
from app.database import (
    assignments,
    audit_logs,
    caregiver_links,
    connection,
    dump_json,
    load_json,
    transaction,
    users,
)

ROLES = ("admin", "doctor", "patient", "caregiver")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _user(row) -> dict | None:
    if row is None:
        return None
    r = row._mapping
    return {
        "id": r["id"], "username": r["username"], "name": r["name"],
        "role": r["role"], "passwordHash": r["password_hash"],
        "disabled": bool(r["disabled"]),
        "sessionVersion": int(r["session_version"]),
        "primaryDoctorId": r["primary_doctor_id"], "patientId": r["patient_id"],
        "createdBy": r["created_by"], "createdAt": r["created_at"],
        "updatedAt": r["updated_at"], "meta": load_json(r["meta_json"], {}),
    }


def _assignment(row) -> dict:
    r = row._mapping
    return {
        "patientId": r["patient_id"], "doctorId": r["doctor_id"],
        "assignedBy": r["assigned_by"], "assignedAt": r["assigned_at"],
    }


def _audit(row) -> dict:
    r = row._mapping
    return {
        "id": r["id"], "at": r["at"], "actor": r["actor"],
        "actorRole": r["actor_role"], "action": r["action"],
        "target": r["target"], "detail": load_json(r["detail_json"], {}),
    }


def public_user(u: dict | None) -> dict | None:
    return {k: v for k, v in u.items() if k != "passwordHash"} if u else None


def get_user(user_id: str) -> dict | None:
    with connection() as conn:
        return _user(conn.execute(select(users).where(users.c.id == user_id)).first())


def get_by_username(username: str) -> dict | None:
    if not username:
        return None
    with connection() as conn:
        return _user(conn.execute(
            select(users).where(users.c.username == username.strip())
        ).first())


def username_taken(username: str) -> bool:
    return get_by_username(username) is not None


def create_user(
    *, username: str, name: str, role: str, password_hash: str,
    created_by: str | None = None, primary_doctor_id: str | None = None,
    patient_id: str | None = None, meta: dict | None = None,
) -> dict:
    username, name = (username or "").strip(), (name or "").strip()
    if role not in ROLES:
        raise ValueError(f"invalid role: {role}")
    if not username:
        raise ValueError("username is required")
    if not name:
        raise ValueError("name is required")
    uid = patient_id if role == "patient" and patient_id else str(uuid4())
    now = _now()
    try:
        with transaction() as conn:
            conn.execute(insert(users).values(
                id=uid, username=username, name=name, role=role,
                password_hash=password_hash, disabled=False, session_version=0,
                primary_doctor_id=primary_doctor_id if role == "patient" else None,
                patient_id=uid if role == "patient" else None,
                created_by=created_by, created_at=now, updated_at=now,
                meta_json=dump_json(dict(meta or {})),
            ))
    except IntegrityError as exc:
        raise ValueError("username already exists") from exc
    return get_user(uid)


_MUTABLE_FIELDS = {
    "name": "name", "username": "username", "primaryDoctorId": "primary_doctor_id"
}


def update_user(user_id: str, patch: dict[str, Any]) -> dict | None:
    values: dict[str, Any] = {}
    for external, column in _MUTABLE_FIELDS.items():
        value = patch.get(external)
        if value is not None:
            values[column] = value.strip() if isinstance(value, str) else value
    if patch.get("meta") is not None:
        values["meta_json"] = dump_json(patch["meta"])
    values["updated_at"] = _now()
    try:
        with transaction() as conn:
            result = conn.execute(update(users).where(users.c.id == user_id).values(**values))
            if not result.rowcount:
                return None
    except IntegrityError as exc:
        raise ValueError("username already exists") from exc
    return get_user(user_id)


def _set_security_state(user_id: str, **values) -> dict | None:
    values.update(session_version=users.c.session_version + 1, updated_at=_now())
    with transaction() as conn:
        result = conn.execute(update(users).where(users.c.id == user_id).values(**values))
        if not result.rowcount:
            return None
    return get_user(user_id)


def set_password(user_id: str, password_hash: str) -> dict | None:
    return _set_security_state(user_id, password_hash=password_hash)


def set_disabled(user_id: str, disabled: bool) -> dict | None:
    return _set_security_state(user_id, disabled=bool(disabled))


def delete_user(user_id: str) -> bool:
    with transaction() as conn:
        return bool(conn.execute(delete(users).where(users.c.id == user_id)).rowcount)


def list_users(role: str | None = None, q: str | None = None,
               include_disabled: bool = True) -> list[dict]:
    stmt = select(users)
    if role:
        stmt = stmt.where(users.c.role == role)
    if not include_disabled:
        stmt = stmt.where(users.c.disabled.is_(False))
    if q:
        needle = f"%{q.strip()}%"
        stmt = stmt.where(users.c.name.ilike(needle) | users.c.username.ilike(needle))
    stmt = stmt.order_by(users.c.role, func.lower(users.c.name))
    with connection() as conn:
        return [_user(row) for row in conn.execute(stmt)]


def assign_patient(patient_id: str, doctor_id: str, by: str | None = None) -> dict:
    with connection() as conn:
        existing = conn.execute(select(assignments).where(
            assignments.c.patient_id == patient_id,
            assignments.c.doctor_id == doctor_id,
        )).first()
    if existing:
        return _assignment(existing)
    assigned_at = _now()
    try:
        with transaction() as conn:
            conn.execute(insert(assignments).values(
                patient_id=patient_id, doctor_id=doctor_id,
                assigned_by=by, assigned_at=assigned_at,
            ))
    except IntegrityError:
        with connection() as conn:
            existing = conn.execute(select(assignments).where(
                assignments.c.patient_id == patient_id,
                assignments.c.doctor_id == doctor_id,
            )).first()
        if existing:
            return _assignment(existing)
        raise
    return {"patientId": patient_id, "doctorId": doctor_id,
            "assignedBy": by, "assignedAt": assigned_at}


def unassign_patient(patient_id: str, doctor_id: str) -> bool:
    with transaction() as conn:
        return bool(conn.execute(delete(assignments).where(
            assignments.c.patient_id == patient_id,
            assignments.c.doctor_id == doctor_id,
        )).rowcount)


def list_assignments() -> list[dict]:
    with connection() as conn:
        return [_assignment(row) for row in conn.execute(select(assignments))]


def patients_for_doctor(doctor_id: str) -> list[str]:
    with connection() as conn:
        return list(conn.execute(select(assignments.c.patient_id).where(
            assignments.c.doctor_id == doctor_id)).scalars())


def doctors_for_patient(patient_id: str) -> list[str]:
    with connection() as conn:
        return list(conn.execute(select(assignments.c.doctor_id).where(
            assignments.c.patient_id == patient_id)).scalars())


def is_assigned(patient_id: str, doctor_id: str) -> bool:
    return doctor_id in doctors_for_patient(patient_id)


def _caregiver_link(row) -> dict:
    r = row._mapping
    return {
        "patientId": r["patient_id"], "caregiverId": r["caregiver_id"],
        "linkedBy": r["linked_by"], "linkedAt": r["linked_at"],
    }


def link_caregiver(patient_id: str, caregiver_id: str, by: str | None = None) -> dict:
    with connection() as conn:
        existing = conn.execute(select(caregiver_links).where(
            caregiver_links.c.patient_id == patient_id,
            caregiver_links.c.caregiver_id == caregiver_id,
        )).first()
    if existing:
        return _caregiver_link(existing)
    linked_at = _now()
    try:
        with transaction() as conn:
            conn.execute(insert(caregiver_links).values(
                patient_id=patient_id, caregiver_id=caregiver_id,
                linked_by=by, linked_at=linked_at,
            ))
    except IntegrityError:
        with connection() as conn:
            existing = conn.execute(select(caregiver_links).where(
                caregiver_links.c.patient_id == patient_id,
                caregiver_links.c.caregiver_id == caregiver_id,
            )).first()
        if existing:
            return _caregiver_link(existing)
        raise
    return {"patientId": patient_id, "caregiverId": caregiver_id,
            "linkedBy": by, "linkedAt": linked_at}


def unlink_caregiver(patient_id: str, caregiver_id: str) -> bool:
    with transaction() as conn:
        return bool(conn.execute(delete(caregiver_links).where(
            caregiver_links.c.patient_id == patient_id,
            caregiver_links.c.caregiver_id == caregiver_id,
        )).rowcount)


def list_caregiver_links() -> list[dict]:
    with connection() as conn:
        return [_caregiver_link(row) for row in conn.execute(select(caregiver_links))]


def caregivers_for_patient(patient_id: str) -> list[str]:
    with connection() as conn:
        return list(conn.execute(select(caregiver_links.c.caregiver_id).where(
            caregiver_links.c.patient_id == patient_id)).scalars())


def patients_for_caregiver(caregiver_id: str) -> list[str]:
    with connection() as conn:
        return list(conn.execute(select(caregiver_links.c.patient_id).where(
            caregiver_links.c.caregiver_id == caregiver_id)).scalars())


def is_caregiver_linked(patient_id: str, caregiver_id: str) -> bool:
    return caregiver_id in caregivers_for_patient(patient_id)


def log(actor: str | None, actor_role: str | None, action: str,
        target: str | None = None, detail: dict | None = None) -> dict:
    entry = {"id": str(uuid4()), "at": _now(), "actor": actor,
             "actorRole": actor_role, "action": action, "target": target,
             "detail": detail or {}}
    with transaction() as conn:
        conn.execute(insert(audit_logs).values(
            id=entry["id"], at=entry["at"], actor=actor,
            actor_role=actor_role, action=action, target=target,
            detail_json=dump_json(entry["detail"]),
        ))
        old = select(audit_logs.c.sequence).order_by(
            audit_logs.c.sequence.desc()).offset(1000)
        conn.execute(delete(audit_logs).where(audit_logs.c.sequence.in_(old)))
    return entry


def list_audit(limit: int = 200) -> list[dict]:
    with connection() as conn:
        return [_audit(row) for row in conn.execute(select(audit_logs).order_by(
            audit_logs.c.sequence.desc()).limit(limit))]


def counts() -> dict:
    with connection() as conn:
        role_rows = dict(
            conn.execute(select(users.c.role, func.count()).group_by(users.c.role)).all()
        )
        return {
            "totalUsers": conn.scalar(select(func.count()).select_from(users)) or 0,
            "byRole": {role: int(role_rows.get(role, 0)) for role in ROLES},
            "disabled": conn.scalar(select(func.count()).select_from(users).where(
                users.c.disabled.is_(True))) or 0,
            "assignments": conn.scalar(select(func.count()).select_from(assignments)) or 0,
        }


def seed_admin() -> dict | None:
    if list_users(role="admin"):
        return None
    username = os.getenv("ADMIN_USERNAME", "admin")
    password = os.getenv("ADMIN_PASSWORD")
    used_default = password is None
    user = create_user(
        username=username, name=os.getenv("ADMIN_NAME", "System Administrator"),
        role="admin", password_hash=security.hash_password(password or "change-me-admin"),
        created_by="system",
    )
    log("system", "system", "seed_admin", target=user["id"], detail={"username": username})
    return {"user": public_user(user), "usedDefaultPassword": used_default}