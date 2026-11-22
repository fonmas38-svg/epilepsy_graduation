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
    doctor_profiles,
    dump_json,
    idempotency_keys,
    load_json,
    moh_registry,
    transaction,
    upsert,
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
        "email": r.get("email"),
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
            select(users).where(func.lower(users.c.username) == username.strip().lower())
        ).first())


def username_taken(username: str) -> bool:
    return get_by_username(username) is not None


def create_user(
    *, username: str, name: str, role: str, password_hash: str,
    email: str | None = None,
    created_by: str | None = None, primary_doctor_id: str | None = None,
    patient_id: str | None = None, meta: dict | None = None,
) -> dict:
    username, name = (username or "").strip(), (name or "").strip()
    clean_email = (email or "").strip().lower() or None
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
                id=uid, username=username, name=name, email=clean_email, role=role,
                password_hash=password_hash, disabled=False, session_version=0,
                primary_doctor_id=primary_doctor_id if role == "patient" else None,
                patient_id=uid if role == "patient" else None,
                created_by=created_by, created_at=now, updated_at=now,
                meta_json=dump_json(dict(meta or {})),
            ))
    except IntegrityError as exc:
        raise ValueError("username or email already exists") from exc
    return get_user(uid)


_MUTABLE_FIELDS = {
    "name": "name", "username": "username", "email": "email", "primaryDoctorId": "primary_doctor_id"
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
    with transaction() as conn:
        _require_link_roles(conn, patient_id, doctor_id, "doctor")
        conn.execute(upsert(assignments, {
            "patient_id": patient_id, "doctor_id": doctor_id,
            "assigned_by": by, "assigned_at": _now(),
        }).on_conflict_do_nothing(index_elements=["patient_id", "doctor_id"]))
        return _assignment(conn.execute(select(assignments).where(
            assignments.c.patient_id == patient_id,
            assignments.c.doctor_id == doctor_id,
        )).one())


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
        "disabled": bool(r["disabled"]),
    }


def _require_link_roles(conn, patient_id: str, other_id: str, role: str) -> None:
    roles = dict(conn.execute(select(users.c.id, users.c.role).where(
        users.c.id.in_([patient_id, other_id]),
    )).all())
    if roles.get(patient_id) != "patient" or roles.get(other_id) != role:
        raise ValueError(f"a patient and a {role} account are required")


def link_caregiver(patient_id: str, caregiver_id: str, by: str | None = None) -> dict:
    with transaction() as conn:
        _require_link_roles(conn, patient_id, caregiver_id, "caregiver")
        conn.execute(upsert(caregiver_links, {
            "patient_id": patient_id, "caregiver_id": caregiver_id,
            "linked_by": by, "linked_at": _now(), "disabled": False,
        }).on_conflict_do_nothing(index_elements=["patient_id", "caregiver_id"]))
        return _caregiver_link(conn.execute(select(caregiver_links).where(
            caregiver_links.c.patient_id == patient_id,
            caregiver_links.c.caregiver_id == caregiver_id,
        )).one())


def set_caregiver_link_disabled(patient_id: str, caregiver_id: str, disabled: bool) -> bool:
    """A patient can revoke only their own relationship, never another account."""
    with transaction() as conn:
        _require_link_roles(conn, patient_id, caregiver_id, "caregiver")
        return bool(conn.execute(update(caregiver_links).where(
            caregiver_links.c.patient_id == patient_id,
            caregiver_links.c.caregiver_id == caregiver_id,
        ).values(disabled=disabled)).rowcount)


def unlink_caregiver(patient_id: str, caregiver_id: str) -> bool:
    with transaction() as conn:
        return bool(conn.execute(delete(caregiver_links).where(
            caregiver_links.c.patient_id == patient_id,
            caregiver_links.c.caregiver_id == caregiver_id,
        )).rowcount)


def list_caregiver_links() -> list[dict]:
    with connection() as conn:
        return [_caregiver_link(row) for row in conn.execute(select(caregiver_links))]


def caregivers_for_patient(patient_id: str, *, include_disabled: bool = False) -> list[str]:
    stmt = select(caregiver_links.c.caregiver_id).join(
        users, users.c.id == caregiver_links.c.caregiver_id,
    ).where(caregiver_links.c.patient_id == patient_id, users.c.role == "caregiver")
    if not include_disabled:
        stmt = stmt.where(caregiver_links.c.disabled.is_(False), users.c.disabled.is_(False))
    with connection() as conn:
        return list(conn.execute(stmt).scalars())


def patients_for_caregiver(caregiver_id: str) -> list[str]:
    with connection() as conn:
        return list(conn.execute(select(caregiver_links.c.patient_id).join(
            users, users.c.id == caregiver_links.c.patient_id,
        ).where(
            caregiver_links.c.caregiver_id == caregiver_id,
            caregiver_links.c.disabled.is_(False),
            users.c.role == "patient", users.c.disabled.is_(False),
        )).scalars())


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


def seed_demo_accounts() -> None:
    """Explicit demo-only setup; never inferred from whether pytest is running."""
    if os.getenv("APP_ENV", "demo").strip().lower() != "demo":
        raise RuntimeError("Demo accounts are forbidden outside APP_ENV=demo")
    doc = get_by_username("doctor")
    if not doc:
        doc = create_user(
            username="doctor",
            name="د. خالد العمري",
            role="doctor",
            password_hash=security.hash_password("doctor123"),
            created_by="system",
        )
    pat = get_by_username("patient")
    if not pat:
        pat = create_user(
            username="patient",
            name="أحمد محمود",
            role="patient",
            password_hash=security.hash_password("patient123"),
            created_by="system",
        )
    if doc and pat:
        try:
            assign_patient(pat["id"], doc["id"], by="system")
        except Exception:
            pass
    cg = get_by_username("caregiver")
    if not cg:
        cg = create_user(
            username="caregiver",
            name="سارة محمود (المرافق)",
            role="caregiver",
            password_hash=security.hash_password("caregiver123"),
            created_by="system",
        )
    if pat and cg:
        try:
            link_caregiver(pat["id"], cg["id"], by="system")
        except Exception:
            pass


def seed_admin() -> dict | None:
    environment = os.getenv("APP_ENV", "demo").strip().lower()
    if environment in {"production", "prod"}:
        # Existing default accounts are just as unsafe as creating new ones.
        for username, password in (("doctor", "doctor123"), ("patient", "patient123"),
                                   ("caregiver", "caregiver123"), ("admin", "change-me-admin")):
            existing = get_by_username(username)
            if existing and not existing["disabled"] and security.verify_password(password, existing["passwordHash"]):
                raise RuntimeError("Default credentials found; disable or reset demo accounts before production")
    if os.getenv("SEED_DEMO_ACCOUNTS", "0") == "1":
        seed_demo_accounts()
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


# ------------------------------------------------------------------ Phase 4: Idempotency, MOH Registry & Doctor Profiles


def get_idempotent_response(key: str | None, actor_id: str, endpoint: str) -> dict | None:
    if not key or not key.strip():
        return None
    clean_key = key.strip()[:128]
    with connection() as conn:
        row = conn.execute(
            select(idempotency_keys).where(
                idempotency_keys.c.key == clean_key,
                idempotency_keys.c.actor_id == str(actor_id),
                idempotency_keys.c.endpoint == endpoint,
            )
        ).first()
    if not row:
        return None
    r = row._mapping
    return {
        "status_code": int(r["response_status"]),
        "payload": load_json(r["response_json"], {}),
    }


def save_idempotent_response(
    key: str | None, actor_id: str, endpoint: str, status_code: int, payload: dict
) -> None:
    if not key or not key.strip():
        return
    clean_key = key.strip()[:128]
    now = _now()
    values = {
        "key": clean_key,
        "actor_id": str(actor_id),
        "endpoint": endpoint,
        "response_status": int(status_code),
        "response_json": dump_json(payload),
        "created_at": now,
    }
    with transaction() as conn:
        conn.execute(
            upsert(idempotency_keys, values).on_conflict_do_update(
                index_elements=["key"],
                set_={
                    "response_status": values["response_status"],
                    "response_json": values["response_json"],
                },
            )
        )


_DEFAULT_MOH_RECORDS = (
    {
        "license_number": "MOH-100200",
        "national_id": "1010101010",
        "full_name_ar": "خالد العمري",
        "full_name_en": "Khaled Alomari",
        "specialization": "مخ وأعصاب وصرع",
        "hospital_affiliation": "مستشفى الملك فيصل التخصصي",
        "status": "active",
        "expiration_date": "2029-12-31",
    },
    {
        "license_number": "MOH-2026-8841",
        "national_id": "1020304050",
        "full_name_ar": "مطهر الحميدي",
        "full_name_en": "Mutahar Alhumidi",
        "specialization": "طب الأعصاب والصرع",
        "hospital_affiliation": "المستشفى التخصصي الجامعي",
        "status": "active",
        "expiration_date": "2028-12-31",
    },
    {
        "license_number": "MOH-999000",
        "national_id": "1099990000",
        "full_name_ar": "سامي الموقوف",
        "full_name_en": "Sami Suspended",
        "specialization": "أعصاب",
        "hospital_affiliation": "عيادة خاصة",
        "status": "suspended",
        "expiration_date": "2027-06-30",
    },
    {
        "license_number": "MOH-111000",
        "national_id": "1011110000",
        "full_name_ar": "نبيل المنتهي",
        "full_name_en": "Nabil Expired",
        "specialization": "أعصاب",
        "hospital_affiliation": "مستشفى المركزي",
        "status": "expired",
        "expiration_date": "2023-01-01",
    },
)


def ensure_default_moh_registry() -> None:
    with transaction() as conn:
        count = conn.execute(select(func.count()).select_from(moh_registry)).scalar_one()
        if count == 0:
            for rec in _DEFAULT_MOH_RECORDS:
                conn.execute(
                    upsert(moh_registry, rec).on_conflict_do_nothing(
                        index_elements=["license_number"]
                    )
                )


def seed_moh_record(record: dict) -> dict:
    with transaction() as conn:
        conn.execute(
            upsert(moh_registry, record).on_conflict_do_update(
                index_elements=["license_number"],
                set_={k: v for k, v in record.items() if k != "license_number"},
            )
        )
    return record


def verify_moh_license(
    *,
    license_number: str,
    national_id: str | None = None,
    name: str | None = None,
) -> dict:
    ensure_default_moh_registry()
    clean_license = (license_number or "").strip().upper()
    if not clean_license:
        return {
            "verified": False,
            "status": "not_found",
            "record": None,
            "message": "رقم الترخيص المهني مطلوب للتحقق من سجل وزارة الصحة.",
        }
    with connection() as conn:
        row = conn.execute(
            select(moh_registry).where(func.upper(moh_registry.c.license_number) == clean_license)
        ).first()
    if not row:
        return {
            "verified": False,
            "status": "not_found",
            "record": None,
            "message": "رقم الترخيص غير مسجل في قاعدة بيانات وزارة الصحة. يمكنك إلغاء العملية أو إكمال الإنشاء على مسؤولية المدير.",
        }
    rec = dict(row._mapping)
    clean_nid = (national_id or "").strip()
    if clean_nid and rec.get("national_id") and clean_nid != rec["national_id"]:
        return {
            "verified": False,
            "status": "mismatch",
            "record": rec,
            "message": "رقم الهوية الوطنية لا يطابق السجل المرتبط بهذا الترخيص في وزارة الصحة.",
        }
    status = rec.get("status", "active")
    if status == "suspended":
        return {
            "verified": False,
            "status": "suspended",
            "record": rec,
            "message": "ترخيص الممارس الصحي موقوف حالياً في سجل وزارة الصحة.",
        }
    if status == "expired":
        return {
            "verified": False,
            "status": "expired",
            "record": rec,
            "message": "ترخيص الممارس الصحي منتهي الصلاحية في سجل وزارة الصحة.",
        }
    return {
        "verified": True,
        "status": "active",
        "record": rec,
        "message": "تم التحقق من ترخيص الممارس الصحي بنجاح في سجل وزارة الصحة (نشط).",
    }


def upsert_doctor_profile(
    user_id: str,
    *,
    license_number: str,
    specialization: str,
    hospital_affiliation: str,
    national_id: str,
    phone: str,
    moh_verified: bool,
    moh_status: str,
    moh_override_by: str | None = None,
) -> dict:
    now = _now()
    row = {
        "id": f"dp-{user_id}",
        "user_id": user_id,
        "license_number": license_number.strip(),
        "specialization": specialization.strip(),
        "hospital_affiliation": hospital_affiliation.strip(),
        "national_id": national_id.strip(),
        "phone": phone.strip(),
        "moh_verified": bool(moh_verified),
        "moh_status": moh_status,
        "moh_checked_at": now,
        "moh_override_by": moh_override_by,
        "created_at": now,
        "updated_at": now,
    }
    try:
        with transaction() as conn:
            conn.execute(
                upsert(doctor_profiles, row).on_conflict_do_update(
                    index_elements=["user_id"],
                    set_={k: v for k, v in row.items() if k not in ("id", "user_id")},
                )
            )
    except IntegrityError as exc:
        raise ValueError("doctor license_number or national_id already exists") from exc
    return row


def get_doctor_profile(user_id: str) -> dict | None:
    with connection() as conn:
        row = conn.execute(
            select(doctor_profiles).where(doctor_profiles.c.user_id == user_id)
        ).first()
    if not row:
        return None
    r = row._mapping
    return {
        "licenseNumber": r["license_number"],
        "specialization": r["specialization"],
        "hospitalAffiliation": r["hospital_affiliation"],
        "nationalId": r["national_id"],
        "phone": r["phone"],
        "mohVerified": bool(r["moh_verified"]),
        "mohStatus": r["moh_status"],
        "mohCheckedAt": r["moh_checked_at"],
        "mohOverrideBy": r["moh_override_by"],
    }
