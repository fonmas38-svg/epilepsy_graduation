"""One-time import of the legacy JSON stores into SQLite.

Safety rules enforced here:
  * the JSON files are never deleted or rewritten — only read,
  * a timestamped backup copy is taken before the first import,
  * the whole import runs inside a single transaction, and
  * a `store_imports` row makes repeat runs a no-op (idempotent).
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from sqlalchemy import func, insert, select
from sqlalchemy.engine import Connection

from app.database import (
    ROOT,
    alerts,
    assessments,
    assignments,
    audit_logs,
    dump_json,
    patients,
    readings,
    store_imports,
    transaction,
    users,
)

log = logging.getLogger("epilepsy.migration")

DEFAULT_USERS_JSON = ROOT / "data" / "users_store.json"
DEFAULT_CLOUD_JSON = ROOT / "data" / "cloud_store.json"
VALID_ROLES = {"admin", "doctor", "patient", "caregiver"}


def _users_json_path() -> Path:
    return Path(os.getenv("USERS_STORE_PATH") or DEFAULT_USERS_JSON)


def _cloud_json_path() -> Path:
    return Path(os.getenv("CLOUD_STORE_PATH") or DEFAULT_CLOUD_JSON)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _checksum(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        log.warning("skipping unreadable legacy store: %s", path)
        return None
    return data if isinstance(data, dict) else None


def _backup(path: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = path.with_name(f"{path.name}.pre-sqlite-{stamp}.bak")
    shutil.copy2(path, target)
    return target


def _already_imported(conn: Connection, path: Path) -> bool:
    return bool(conn.scalar(
        select(store_imports.c.source_path).where(store_imports.c.source_path == str(path))
    ))


def _mark_imported(conn: Connection, path: Path, backup_path: Path) -> None:
    conn.execute(insert(store_imports).values(
        source_path=str(path), checksum=_checksum(path),
        imported_at=_now(), backup_path=str(backup_path),
    ))


def _import_users(conn: Connection, data: dict[str, Any]) -> dict[str, int]:
    stats = {"users": 0, "assignments": 0, "audit": 0}
    known_ids: set[str] = set()
    seen_usernames: set[str] = set()

    for uid, user in (data.get("users") or {}).items():
        username = str(user.get("username") or "").strip()
        role = user.get("role")
        if not username or role not in VALID_ROLES:
            log.warning("skipping legacy user %s: invalid username/role", uid)
            continue
        if username.lower() in seen_usernames:
            log.warning("skipping legacy user %s: duplicate username %s", uid, username)
            continue
        seen_usernames.add(username.lower())
        now = _now()
        conn.execute(insert(users).values(
            id=uid,
            username=username,
            name=str(user.get("name") or username),
            role=role,
            password_hash=str(user.get("passwordHash") or ""),
            disabled=bool(user.get("disabled")),
            session_version=int(user.get("sessionVersion") or 0),
            primary_doctor_id=user.get("primaryDoctorId"),
            patient_id=user.get("patientId"),
            created_by=user.get("createdBy"),
            created_at=str(user.get("createdAt") or now),
            updated_at=str(user.get("updatedAt") or now),
            meta_json=dump_json(user.get("meta") or {}),
        ))
        known_ids.add(uid)
        stats["users"] += 1

    seen_pairs: set[tuple[str, str]] = set()
    for row in data.get("assignments") or []:
        patient_id, doctor_id = row.get("patientId"), row.get("doctorId")
        if patient_id not in known_ids or doctor_id not in known_ids:
            log.warning("skipping assignment %s->%s: unknown user", patient_id, doctor_id)
            continue
        if (patient_id, doctor_id) in seen_pairs:
            continue
        seen_pairs.add((patient_id, doctor_id))
        conn.execute(insert(assignments).values(
            patient_id=patient_id, doctor_id=doctor_id,
            assigned_by=row.get("assignedBy"),
            assigned_at=str(row.get("assignedAt") or _now()),
        ))
        stats["assignments"] += 1

    # JSON kept newest-first; insert oldest-first so `sequence` matches history.
    for entry in reversed(data.get("audit") or []):
        conn.execute(insert(audit_logs).values(
            id=str(entry.get("id") or ""), at=str(entry.get("at") or _now()),
            actor=entry.get("actor"), actor_role=entry.get("actorRole"),
            action=str(entry.get("action") or "unknown"), target=entry.get("target"),
            detail_json=dump_json(entry.get("detail") or {}),
        ))
        stats["audit"] += 1

    return stats


def _import_cloud(conn: Connection, data: dict[str, Any]) -> dict[str, int]:
    stats = {"patients": 0, "readings": 0, "assessments": 0, "alerts": 0}

    patient_ids: set[str] = set()
    for patient_id, profile in (data.get("patients") or {}).items():
        profile = dict(profile or {})
        conn.execute(insert(patients).values(
            patient_id=patient_id,
            current_status=profile.get("currentStatus"),
            last_updated=profile.get("lastUpdated"),
            updated_at=str(profile.get("updatedAt") or _now()),
            profile_json=dump_json({
                k: v for k, v in profile.items()
                if k not in {"patientId", "updatedAt", "currentStatus", "lastUpdated"}
            }),
        ))
        patient_ids.add(patient_id)
        stats["patients"] += 1

    def _import_records(key: str, table, extra) -> None:
        for patient_id, records in (data.get(key) or {}).items():
            if patient_id not in patient_ids:
                conn.execute(insert(patients).values(
                    patient_id=patient_id, current_status=None, last_updated=None,
                    updated_at=_now(), profile_json=dump_json({}),
                ))
                patient_ids.add(patient_id)
                stats["patients"] += 1
            for record in reversed(records or []):
                record = dict(record or {})
                record.setdefault("patientId", patient_id)
                values = {
                    "id": str(record.get("id") or ""),
                    "patient_id": patient_id,
                    "captured_at": record.get("timestamp"),
                    "payload_json": dump_json(record),
                }
                values.update(extra(record))
                conn.execute(insert(table).values(**values))
                stats[key] += 1

    _import_records("readings", readings, lambda record: {})
    _import_records("assessments", assessments, lambda record: {"label": record.get("label")})
    _import_records("alerts", alerts, lambda record: {
        "severity": record.get("severity"),
        "acknowledged": bool(record.get("acknowledged")),
    })
    return stats


def import_legacy_stores() -> dict[str, Any]:
    """Import both legacy JSON stores if present and not yet imported."""
    result: dict[str, Any] = {"imported": [], "skipped": []}
    users_path, cloud_path = _users_json_path(), _cloud_json_path()

    with transaction() as conn:
        has_rows = bool(conn.scalar(select(func.count()).select_from(users))) or bool(
            conn.scalar(select(func.count()).select_from(patients))
        )
        for path, importer, label in (
            (users_path, _import_users, "users_store.json"),
            (cloud_path, _import_cloud, "cloud_store.json"),
        ):
            if not path.exists():
                result["skipped"].append({"store": label, "reason": "missing"})
                continue
            if _already_imported(conn, path):
                result["skipped"].append({"store": label, "reason": "already imported"})
                continue
            if has_rows:
                result["skipped"].append({"store": label, "reason": "database already populated"})
                continue
            data = _read_json(path)
            if data is None:
                result["skipped"].append({"store": label, "reason": "unreadable"})
                continue
            backup_path = _backup(path)
            stats = importer(conn, data)
            _mark_imported(conn, path, backup_path)
            result["imported"].append({
                "store": label, "stats": stats, "backup": str(backup_path),
            })
    return result
