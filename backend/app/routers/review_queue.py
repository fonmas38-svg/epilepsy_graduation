"""Doctor-scoped keyset pagination over unreviewed clinical alerts."""
from fastapi import APIRouter, Depends, Query
from sqlalchemy import JSON, cast, func, or_, select

from app.auth import authorize_patient_access, require_role
from app.database import alerts, assignments, connection, load_json, outcomes, users

router = APIRouter(prefix="/doctor", tags=["clinical-review"])


@router.get("/review-queue")
def review_queue(patient_id: str | None = None,
                 before: int | None = Query(None, ge=1),
                 limit: int = Query(50, ge=1, le=100),
                 principal: dict = Depends(require_role("doctor", "admin"))):
    if patient_id:
        authorize_patient_access(patient_id, principal, enforce=True)
    with connection() as conn:
        kind = (func.json_extract(outcomes.c.payload_json, "$.record_kind")
                if conn.dialect.name == "sqlite" else
                cast(outcomes.c.payload_json, JSON)["record_kind"].as_string())
        reviewed = select(outcomes.c.id).where(
            outcomes.c.patient_id == alerts.c.patient_id,
            outcomes.c.alert_id == alerts.c.id,
            func.coalesce(kind, "") != "reported_seizure_log",
        ).exists()
        query = select(alerts, users.c.name.label("patient_name")).join(
            users, users.c.id == alerts.c.patient_id).where(
            users.c.role == "patient", users.c.disabled.is_(False), ~reviewed,
            or_(alerts.c.severity.is_(None), alerts.c.severity.not_in(
                ["info", "normal", "stable", "safe", "resolved"])),
        )
        if principal["role"] == "doctor":
            query = query.where(select(assignments.c.patient_id).where(
                assignments.c.patient_id == alerts.c.patient_id,
                assignments.c.doctor_id == principal["sub"],
            ).exists())
        if patient_id:
            query = query.where(alerts.c.patient_id == patient_id)
        if before:
            query = query.where(alerts.c.sequence < before)
        rows = conn.execute(query.order_by(alerts.c.sequence.desc()).limit(limit + 1)).mappings().all()
    page = rows[:limit]
    return {"items": [{"alert": {**load_json(row["payload_json"], {}),
                                "id": row["id"], "patientId": row["patient_id"]},
                       "patientName": row["patient_name"]} for row in page],
            "nextCursor": int(page[-1]["sequence"]) if len(rows) > limit else None}
