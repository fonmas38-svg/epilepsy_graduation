"""Row-based prescriptions: independent inserts cannot overwrite another order."""
from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import insert, select, update

from app import cloud_store
from app.database import connection, prescriptions, transaction


def create(patient_id: str, doctor_id: str, fields: dict) -> dict:
    now = datetime.now(timezone.utc).isoformat()
    values = {**fields, "id": str(uuid4()), "patient_id": patient_id, "doctor_id": doctor_id,
              "active": True, "created_at": now, "updated_at": now}
    with transaction() as conn:
        cloud_store._ensure_patient(conn, patient_id)
        conn.execute(insert(prescriptions).values(**values))
    return values


def list_for(patient_id: str) -> list[dict]:
    with connection() as conn:
        return [dict(row._mapping) for row in conn.execute(select(prescriptions).where(
            prescriptions.c.patient_id == patient_id,
        ).order_by(prescriptions.c.created_at, prescriptions.c.id))]


def patch(patient_id: str, prescription_id: str, fields: dict) -> dict | None:
    values = {k: v for k, v in fields.items() if k in {"name", "dose", "schedule", "notes", "active"}}
    values["updated_at"] = datetime.now(timezone.utc).isoformat()
    where = (prescriptions.c.id == prescription_id, prescriptions.c.patient_id == patient_id)
    with transaction() as conn:
        result = conn.execute(update(prescriptions).where(*where).values(**values))
        if not result.rowcount:
            return None
        return dict(conn.execute(select(prescriptions).where(*where)).one()._mapping)
