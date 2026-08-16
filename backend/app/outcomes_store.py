"""Persistence for clinically observed outcomes linked to predictions."""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import insert, select

from app.database import (
    alerts,
    assessments,
    connection,
    dump_json,
    load_json,
    outcomes,
    transaction,
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _outcome(row) -> dict:
    r = row._mapping
    payload = load_json(r["payload_json"], {})
    payload.update({
        "id": r["id"], "patientId": r["patient_id"],
        "assessmentId": r["assessment_id"], "alertId": r["alert_id"],
        "outcome": r["outcome"], "occurredAt": r["occurred_at"],
        "recordedBy": r["recorded_by"], "recordedAt": r["recorded_at"],
        "notes": r["notes"],
    })
    return payload


def add_outcome(*, patient_id: str, outcome: str, occurred_at: str,
                recorded_by: str, assessment_id: str | None = None,
                alert_id: str | None = None, notes: str | None = None,
                metadata: dict | None = None) -> dict:
    outcome_id, recorded_at = str(uuid4()), _now()
    with transaction() as conn:
        if assessment_id and conn.execute(select(assessments.c.patient_id).where(
            assessments.c.id == assessment_id
        )).scalar_one_or_none() != patient_id:
            raise ValueError("assessment_id does not belong to this patient")
        if alert_id and conn.execute(select(alerts.c.patient_id).where(
            alerts.c.id == alert_id
        )).scalar_one_or_none() != patient_id:
            raise ValueError("alert_id does not belong to this patient")
        conn.execute(insert(outcomes).values(
            id=outcome_id, patient_id=patient_id, assessment_id=assessment_id,
            alert_id=alert_id, outcome=outcome, occurred_at=occurred_at,
            recorded_by=recorded_by, recorded_at=recorded_at, notes=notes,
            payload_json=dump_json(metadata or {}),
        ))
    return get_outcome(outcome_id)


def get_outcome(outcome_id: str) -> dict | None:
    with connection() as conn:
        row = conn.execute(select(outcomes).where(outcomes.c.id == outcome_id)).first()
    return _outcome(row) if row else None


def list_outcomes(patient_id: str, limit: int = 100) -> list[dict]:
    with connection() as conn:
        rows = conn.execute(select(outcomes).where(
            outcomes.c.patient_id == patient_id
        ).order_by(outcomes.c.sequence.desc()).limit(limit))
        return [_outcome(row) for row in rows]