"""Persistent device registry and per-device credential lifecycle."""
from __future__ import annotations

from datetime import datetime, timezone

from sqlalchemy import insert, select, update
from sqlalchemy.exc import IntegrityError

from app import security
from app.database import connection, devices, transaction


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _device(row, *, include_secret_hash: bool = False) -> dict | None:
    if row is None:
        return None
    r = row._mapping
    result = {
        "deviceId": r["device_id"],
        "patientId": r["patient_id"],
        "name": r["name"],
        "credentialVersion": int(r["credential_version"]),
        "disabled": bool(r["disabled"]),
        "createdBy": r["created_by"],
        "createdAt": r["created_at"],
        "updatedAt": r["updated_at"],
        "lastEnrolledAt": r["last_enrolled_at"],
    }
    if include_secret_hash:
        result["secretHash"] = r["secret_hash"]
    return result


def get_device(device_id: str, *, include_secret_hash: bool = False) -> dict | None:
    with connection() as conn:
        row = conn.execute(select(devices).where(devices.c.device_id == device_id)).first()
    return _device(row, include_secret_hash=include_secret_hash)


def list_devices(patient_id: str | None = None) -> list[dict]:
    stmt = select(devices)
    if patient_id:
        stmt = stmt.where(devices.c.patient_id == patient_id)
    with connection() as conn:
        return [_device(row) for row in conn.execute(stmt.order_by(devices.c.created_at.desc()))]


def create_device(*, device_id: str, patient_id: str, name: str, secret: str,
                  created_by: str | None) -> dict:
    now = _now()
    try:
        with transaction() as conn:
            conn.execute(insert(devices).values(
                device_id=device_id.strip(), patient_id=patient_id,
                name=name.strip(), secret_hash=security.hash_password(secret),
                credential_version=0, disabled=False, created_by=created_by,
                created_at=now, updated_at=now, last_enrolled_at=None,
            ))
    except IntegrityError as exc:
        raise ValueError("device_id already exists") from exc
    return get_device(device_id)


def verify_enrollment(device_id: str, patient_id: str, secret: str) -> dict | None:
    device = get_device(device_id, include_secret_hash=True)
    if not device or device["disabled"] or device["patientId"] != patient_id:
        return None
    if not security.verify_password(secret, device["secretHash"]):
        return None
    now = _now()
    with transaction() as conn:
        conn.execute(update(devices).where(devices.c.device_id == device_id).values(
            last_enrolled_at=now, updated_at=now,
        ))
    return get_device(device_id)


def set_disabled(device_id: str, disabled: bool) -> dict | None:
    with transaction() as conn:
        result = conn.execute(update(devices).where(devices.c.device_id == device_id).values(
            disabled=bool(disabled), credential_version=devices.c.credential_version + 1,
            updated_at=_now(),
        ))
        if not result.rowcount:
            return None
    return get_device(device_id)


def rotate_secret(device_id: str, secret: str) -> dict | None:
    with transaction() as conn:
        result = conn.execute(update(devices).where(devices.c.device_id == device_id).values(
            secret_hash=security.hash_password(secret),
            credential_version=devices.c.credential_version + 1,
            updated_at=_now(),
        ))
        if not result.rowcount:
            return None
    return get_device(device_id)


def token_is_active(device_id: str, patient_id: str | None, credential_version: int) -> bool:
    device = get_device(device_id)
    return bool(
        device
        and not device["disabled"]
        and device["patientId"] == patient_id
        and device["credentialVersion"] == credential_version
    )