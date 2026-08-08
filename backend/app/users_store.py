"""File-backed user + assignment store for the account-management system.

Mirrors the design of `cloud_store.py` exactly — a thread-locked JSON file under
`backend/data/` — so it adds NO new dependency and follows a pattern already
proven in this codebase. It is intentionally separate from `cloud_store.py`
(which holds monitoring data: readings/assessments/alerts) so the two concerns
stay decoupled; the accounts router is responsible for mirroring a newly created
patient account into `cloud_store` so the monitoring pipeline and the Flutter app
see it.

Schema (data/users_store.json)::

    {
      "users": {
        "<id>": {
          id, username, name, role,               # role: admin|doctor|patient|caregiver
          passwordHash, disabled,
          primaryDoctorId,                          # patients: creating/owning doctor
          patientId,                                # patients: monitoring id (== id)
          createdBy, createdAt, updatedAt, meta
        }
      },
      "assignments": [ {patientId, doctorId, assignedBy, assignedAt} ],
      "audit":       [ {id, at, actor, actorRole, action, target, detail} ]
    }

Visibility rule: a doctor sees exactly the patients for which an assignment row
(patientId, doctorId) exists. `primaryDoctorId` is display-only (who created the
patient). The admin can add/remove assignment rows for ANY patient/doctor pair.

The store path is resolved per-call from USERS_STORE_PATH (falling back to the
default), so tests can point it at a temp file without import-order gymnastics.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from threading import RLock
from typing import Any
from uuid import uuid4

from app import security

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_STORE = ROOT / "data" / "users_store.json"
_lock = RLock()

ROLES = ("admin", "doctor", "patient", "caregiver")


def _store_path() -> Path:
    return Path(os.getenv("USERS_STORE_PATH") or DEFAULT_STORE)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _empty() -> dict:
    return {"users": {}, "assignments": [], "audit": []}


def _load() -> dict:
    path = _store_path()
    if not path.exists():
        return _empty()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return _empty()
    # tolerate partial/old files
    for k, v in _empty().items():
        data.setdefault(k, v)
    return data


def _save(data: dict) -> None:
    path = _store_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def public_user(u: dict | None) -> dict | None:
    """A user dict safe to return over the API (password hash stripped)."""
    if not u:
        return None
    return {k: v for k, v in u.items() if k != "passwordHash"}


# --------------------------------------------------------------------------- users


def get_user(user_id: str) -> dict | None:
    with _lock:
        return _load()["users"].get(user_id)


def get_by_username(username: str) -> dict | None:
    if not username:
        return None
    target = username.strip().lower()
    with _lock:
        for u in _load()["users"].values():
            if str(u.get("username", "")).lower() == target:
                return u
    return None


def username_taken(username: str) -> bool:
    return get_by_username(username) is not None


def create_user(
    *,
    username: str,
    name: str,
    role: str,
    password_hash: str,
    created_by: str | None = None,
    primary_doctor_id: str | None = None,
    patient_id: str | None = None,
    meta: dict | None = None,
) -> dict:
    """Create a user. Raises ValueError on bad role or duplicate username.

    For patients, `id == patientId` so a single identifier flows through the
    accounts store, the cloud monitoring store, and the Flutter app.
    """
    username = (username or "").strip()
    name = (name or "").strip()
    if role not in ROLES:
        raise ValueError(f"invalid role: {role}")
    if not username:
        raise ValueError("username is required")
    if not name:
        raise ValueError("name is required")
    with _lock:
        db = _load()
        for u in db["users"].values():
            if str(u.get("username", "")).lower() == username.lower():
                raise ValueError("username already exists")
        uid = patient_id if (role == "patient" and patient_id) else str(uuid4())
        now = _now()
        user = {
            "id": uid,
            "username": username,
            "name": name,
            "role": role,
            "passwordHash": password_hash,
            "disabled": False,
            "primaryDoctorId": primary_doctor_id if role == "patient" else None,
            "patientId": uid if role == "patient" else None,
            "createdBy": created_by,
            "createdAt": now,
            "updatedAt": now,
            "meta": dict(meta or {}),
        }
        db["users"][uid] = user
        _save(db)
        return user


_MUTABLE_FIELDS = {"name", "username", "meta", "primaryDoctorId"}


def update_user(user_id: str, patch: dict[str, Any]) -> dict | None:
    with _lock:
        db = _load()
        u = db["users"].get(user_id)
        if not u:
            return None
        new_username = patch.get("username")
        if new_username and new_username.strip().lower() != str(u["username"]).lower():
            for other in db["users"].values():
                if other["id"] != user_id and str(other.get("username", "")).lower() == new_username.strip().lower():
                    raise ValueError("username already exists")
        for k, v in patch.items():
            if k in _MUTABLE_FIELDS and v is not None:
                u[k] = v.strip() if isinstance(v, str) else v
        u["updatedAt"] = _now()
        db["users"][user_id] = u
        _save(db)
        return u


def set_password(user_id: str, password_hash: str) -> dict | None:
    with _lock:
        db = _load()
        u = db["users"].get(user_id)
        if not u:
            return None
        u["passwordHash"] = password_hash
        u["updatedAt"] = _now()
        _save(db)
        return u


def set_disabled(user_id: str, disabled: bool) -> dict | None:
    with _lock:
        db = _load()
        u = db["users"].get(user_id)
        if not u:
            return None
        u["disabled"] = bool(disabled)
        u["updatedAt"] = _now()
        _save(db)
        return u


def delete_user(user_id: str) -> bool:
    """Remove a user and any assignment rows that reference them."""
    with _lock:
        db = _load()
        if user_id not in db["users"]:
            return False
        db["users"].pop(user_id, None)
        db["assignments"] = [
            a
            for a in db["assignments"]
            if a.get("patientId") != user_id and a.get("doctorId") != user_id
        ]
        _save(db)
        return True


def list_users(
    role: str | None = None,
    q: str | None = None,
    include_disabled: bool = True,
) -> list[dict]:
    with _lock:
        users = list(_load()["users"].values())
    if role:
        users = [u for u in users if u.get("role") == role]
    if not include_disabled:
        users = [u for u in users if not u.get("disabled")]
    if q:
        needle = q.strip().lower()
        users = [
            u
            for u in users
            if needle in str(u.get("name", "")).lower()
            or needle in str(u.get("username", "")).lower()
        ]
    users.sort(key=lambda u: (u.get("role", ""), str(u.get("name", "")).lower()))
    return users


# ---------------------------------------------------------------------- assignments


def assign_patient(patient_id: str, doctor_id: str, by: str | None = None) -> dict:
    """Idempotently link a patient to a doctor. Returns the assignment row."""
    with _lock:
        db = _load()
        for a in db["assignments"]:
            if a.get("patientId") == patient_id and a.get("doctorId") == doctor_id:
                return a
        row = {
            "patientId": patient_id,
            "doctorId": doctor_id,
            "assignedBy": by,
            "assignedAt": _now(),
        }
        db["assignments"].append(row)
        _save(db)
        return row


def unassign_patient(patient_id: str, doctor_id: str) -> bool:
    with _lock:
        db = _load()
        before = len(db["assignments"])
        db["assignments"] = [
            a
            for a in db["assignments"]
            if not (a.get("patientId") == patient_id and a.get("doctorId") == doctor_id)
        ]
        changed = len(db["assignments"]) != before
        if changed:
            _save(db)
        return changed


def list_assignments() -> list[dict]:
    with _lock:
        return list(_load()["assignments"])


def patients_for_doctor(doctor_id: str) -> list[str]:
    with _lock:
        return [
            a["patientId"]
            for a in _load()["assignments"]
            if a.get("doctorId") == doctor_id
        ]


def doctors_for_patient(patient_id: str) -> list[str]:
    with _lock:
        return [
            a["doctorId"]
            for a in _load()["assignments"]
            if a.get("patientId") == patient_id
        ]


def is_assigned(patient_id: str, doctor_id: str) -> bool:
    return doctor_id in doctors_for_patient(patient_id)


# --------------------------------------------------------------------------- audit


def log(
    actor: str | None,
    actor_role: str | None,
    action: str,
    target: str | None = None,
    detail: dict | None = None,
) -> dict:
    with _lock:
        db = _load()
        entry = {
            "id": str(uuid4()),
            "at": _now(),
            "actor": actor,
            "actorRole": actor_role,
            "action": action,
            "target": target,
            "detail": detail or {},
        }
        db["audit"].insert(0, entry)
        db["audit"] = db["audit"][:1000]
        _save(db)
        return entry


def list_audit(limit: int = 200) -> list[dict]:
    with _lock:
        return _load()["audit"][:limit]


# ----------------------------------------------------------------------- overview


def counts() -> dict:
    with _lock:
        db = _load()
        users = list(db["users"].values())
        by_role: dict[str, int] = {r: 0 for r in ROLES}
        disabled = 0
        for u in users:
            by_role[u.get("role", "")] = by_role.get(u.get("role", ""), 0) + 1
            if u.get("disabled"):
                disabled += 1
        return {
            "totalUsers": len(users),
            "byRole": by_role,
            "disabled": disabled,
            "assignments": len(db["assignments"]),
        }


# -------------------------------------------------------------------------- seeding


def seed_admin() -> dict | None:
    """Ensure at least one admin exists. Called once at app startup.

    Reads ADMIN_USERNAME / ADMIN_PASSWORD from the environment. If an admin
    already exists nothing happens (idempotent). When the built-in default
    password is used the caller-visible return signals it so startup can log a
    loud warning — a default admin password must never survive into production.
    """
    with _lock:
        db = _load()
        for u in db["users"].values():
            if u.get("role") == "admin":
                return None  # already seeded

    username = os.getenv("ADMIN_USERNAME", "admin")
    password = os.getenv("ADMIN_PASSWORD")
    used_default = password is None
    if used_default:
        password = "change-me-admin"

    user = create_user(
        username=username,
        name=os.getenv("ADMIN_NAME", "System Administrator"),
        role="admin",
        password_hash=security.hash_password(password),
        created_by="system",
    )
    log("system", "system", "seed_admin", target=user["id"], detail={"username": username})
    return {"user": public_user(user), "usedDefaultPassword": used_default}
