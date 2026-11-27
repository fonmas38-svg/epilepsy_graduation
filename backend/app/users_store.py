"""SQL-backed account, assignment, and audit store.

The public functions preserve the former JSON-store contract so routers and
clients do not need a coordinated migration.
"""
from __future__ import annotations

import os
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from sqlalchemy import delete, func, insert, or_, select, update
from sqlalchemy.exc import IntegrityError

from app import security
from app.database import (
    alert_outbox,
    assignments,
    audit_logs,
    care_records,
    caregiver_links,
    connection,
    devices,
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


def list_users(
    role: str | None = None,
    q: str | None = None,
    include_disabled: bool = True,
    disabled_only: bool = False,
) -> list[dict]:
    stmt = select(users)
    if role:
        stmt = stmt.where(users.c.role == role)
    if disabled_only:
        stmt = stmt.where(users.c.disabled.is_(True))
    elif not include_disabled:
        stmt = stmt.where(users.c.disabled.is_(False))
    if q and q.strip():
        needle = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                users.c.name.ilike(needle),
                users.c.username.ilike(needle),
                users.c.email.ilike(needle),
                users.c.meta_json.ilike(needle),
            )
        )
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


def list_audit(
    limit: int = 200,
    *,
    actor_role: str | None = None,
    action: str | None = None,
    q: str | None = None,
) -> list[dict]:
    stmt = select(audit_logs)
    if actor_role and actor_role.strip():
        stmt = stmt.where(audit_logs.c.actor_role == actor_role.strip())
    if action and action.strip():
        stmt = stmt.where(audit_logs.c.action == action.strip())
    if q and q.strip():
        needle = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                audit_logs.c.action.ilike(needle),
                audit_logs.c.actor.ilike(needle),
                audit_logs.c.target.ilike(needle),
                audit_logs.c.detail_json.ilike(needle),
            )
        )
    with connection() as conn:
        return [_audit(row) for row in conn.execute(
            stmt.order_by(audit_logs.c.sequence.desc()).limit(limit)
        )]


def counts() -> dict:
    with connection() as conn:
        role_rows = dict(
            conn.execute(select(users.c.role, func.count()).group_by(users.c.role)).all()
        )
        device_total = conn.scalar(select(func.count()).select_from(devices)) or 0
        device_disabled = conn.scalar(
            select(func.count()).select_from(devices).where(devices.c.disabled.is_(True))
        ) or 0
        device_enrolled = conn.scalar(
            select(func.count()).select_from(devices).where(devices.c.last_enrolled_at.isnot(None))
        ) or 0
        deletion_requests = conn.scalar(
            select(func.count())
            .select_from(care_records)
            .where(care_records.c.kind == "deletion-request", care_records.c.deleted.is_(False))
        ) or 0
        deletion_rejected = conn.scalar(
            select(func.count())
            .select_from(care_records)
            .where(
                care_records.c.kind == "deletion-review",
                care_records.c.deleted.is_(False),
                care_records.c.payload_json.ilike('%"status": "rejected"%'),
            )
        ) or 0
        moh_overrides = conn.scalar(
            select(func.count())
            .select_from(doctor_profiles)
            .where(
                doctor_profiles.c.moh_verified.is_(False),
                doctor_profiles.c.moh_override_by.isnot(None),
            )
        ) or 0
        outbox_rows = dict(
            conn.execute(
                select(alert_outbox.c.status, func.count()).group_by(alert_outbox.c.status)
            ).all()
        )
        return {
            "totalUsers": conn.scalar(select(func.count()).select_from(users)) or 0,
            "byRole": {role: int(role_rows.get(role, 0)) for role in ROLES},
            "disabled": conn.scalar(select(func.count()).select_from(users).where(
                users.c.disabled.is_(True))) or 0,
            "assignments": conn.scalar(select(func.count()).select_from(assignments)) or 0,
            "devices": {
                "total": int(device_total),
                "disabled": int(device_disabled),
                "enrolled": int(device_enrolled),
            },
            "pendingDeletionRequests": max(0, int(deletion_requests) - int(deletion_rejected)),
            "mohOverrides": int(moh_overrides),
            "outbox": {
                "pending": int(outbox_rows.get("pending", 0)),
                "failed": int(outbox_rows.get("failed", 0)),
                "dead": int(outbox_rows.get("dead", 0)),
                "sent": int(outbox_rows.get("sent", 0)),
            },
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
    import re
    def normalize_name(value):
        return re.sub(r"^(?:د\.|الدكتور|الدكتورة|Dr\.)\s*", "", (value or "").strip(), flags=re.I).casefold()
    if name and normalize_name(name) not in {normalize_name(rec.get("full_name_ar")), normalize_name(rec.get("full_name_en"))}:
        return {"verified": False, "status": "mismatch", "record": rec,
                "message": "الاسم لا يطابق سجل التحقق التجريبي؛ راجع البيانات أو استخدم التجاوز الإداري الموثق."}
    status = rec.get("status", "active")
    expiry = rec.get("expiration_date")
    if expiry:
        try:
            if datetime.fromisoformat(expiry).date() < datetime.now(timezone.utc).date():
                status = "expired"
        except (TypeError, ValueError):
            status = "expired"
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
        "message": "مطابقة ناجحة في سجل التحقق التجريبي (ليس اتصالاً رسمياً بوزارة الصحة).",
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


def list_moh_registry(
    *,
    status: str | None = None,
    q: str | None = None,
) -> list[dict]:
    ensure_default_moh_registry()
    stmt = select(moh_registry)
    if status and status.strip():
        stmt = stmt.where(moh_registry.c.status == status.strip())
    if q and q.strip():
        needle = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                moh_registry.c.license_number.ilike(needle),
                moh_registry.c.national_id.ilike(needle),
                moh_registry.c.full_name_ar.ilike(needle),
                moh_registry.c.full_name_en.ilike(needle),
                moh_registry.c.specialization.ilike(needle),
            )
        )
    with connection() as conn:
        rows = conn.execute(stmt.order_by(moh_registry.c.license_number)).all()
    return [
        {
            "licenseNumber": r._mapping["license_number"],
            "nationalId": r._mapping["national_id"],
            "fullNameAr": r._mapping["full_name_ar"],
            "fullNameEn": r._mapping["full_name_en"],
            "specialization": r._mapping["specialization"],
            "hospitalAffiliation": r._mapping["hospital_affiliation"],
            "status": r._mapping["status"],
            "expirationDate": r._mapping["expiration_date"],
        }
        for r in rows
    ]


def reverify_doctor_moh(user_id: str) -> dict | None:
    user = get_user(user_id)
    profile = get_doctor_profile(user_id)
    if not user or user.get("role") != "doctor" or not profile:
        return None
    result = verify_moh_license(
        license_number=profile["licenseNumber"],
        national_id=profile["nationalId"],
        name=user["name"],
    )
    updated = upsert_doctor_profile(
        user_id,
        license_number=profile["licenseNumber"],
        specialization=profile["specialization"],
        hospital_affiliation=profile["hospitalAffiliation"],
        national_id=profile["nationalId"],
        phone=profile["phone"],
        moh_verified=bool(result["verified"]),
        moh_status=result["status"],
        moh_override_by=None if result["verified"] else profile.get("mohOverrideBy"),
    )
    return {"verification": result, "doctorProfile": get_doctor_profile(user_id) or updated}
