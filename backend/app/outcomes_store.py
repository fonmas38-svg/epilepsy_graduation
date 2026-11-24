"""Persistence for clinically observed outcomes linked to predictions."""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import insert, select, update

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
        "id": r["id"],
        "patientId": r["patient_id"],
        "assessmentId": r["assessment_id"],
        "alertId": r["alert_id"],
        "outcome": r["outcome"],
        "occurredAt": r["occurred_at"],
        "recordedBy": r["recorded_by"],
        "recordedAt": r["recorded_at"],
        "notes": r["notes"],
        "version": int(r.get("version") or 1),
    })
    return payload


def _detach_report(conn, row):
    payload = load_json(row._mapping["payload_json"], {})
    payload["reported_alert_id"] = row._mapping["alert_id"]
    conn.execute(update(outcomes).where(outcomes.c.id == row._mapping["id"]).values(
        alert_id=None, payload_json=dump_json(payload)))
    return conn.execute(select(outcomes).where(outcomes.c.id == row._mapping["id"])).one()


def add_outcome(
    *,
    patient_id: str,
    outcome: str,
    occurred_at: str,
    recorded_by: str,
    assessment_id: str | None = None,
    alert_id: str | None = None,
    notes: str | None = None,
    metadata: dict | None = None,
    client_id: str | None = None,
    expected_version: int | None = None,
) -> dict:
    outcome_id, recorded_at = client_id or str(uuid4()), _now()
    with transaction() as conn:
        metadata = dict(metadata or {})
        if metadata.get("record_kind") == "reported_seizure_log" and alert_id:
            if not conn.execute(select(alerts.c.id).where(alerts.c.id == alert_id, alerts.c.patient_id == patient_id)).first():
                raise ValueError("alert does not belong to this patient")
            metadata["reported_alert_id"] = alert_id
            alert_id = None
        if client_id:
            previous = conn.execute(
                select(outcomes).where(outcomes.c.id == client_id)
            ).first()
            if previous:
                if (load_json(previous._mapping["payload_json"], {}).get("record_kind") == "reported_seizure_log"
                        and previous._mapping["alert_id"]):
                    previous = _detach_report(conn, previous)
                saved = _outcome(previous)
                if (
                    saved["patientId"] != patient_id
                    or saved["recordedBy"] != recorded_by
                    or saved["outcome"] != outcome
                    or saved["occurredAt"] != occurred_at
                    or saved["alertId"] != alert_id
                    or saved["notes"] != notes
                    or saved["assessmentId"] != assessment_id
                    or load_json(previous._mapping["payload_json"], {}) != (metadata or {})
                ):
                    raise ValueError("client id is already used by another record")
                return saved

        if alert_id:
            existing_alert_outcome = conn.execute(
                select(outcomes).where(
                    outcomes.c.patient_id == patient_id,
                    outcomes.c.alert_id == alert_id,
                )
            ).first()
            if (existing_alert_outcome and load_json(existing_alert_outcome._mapping["payload_json"], {}).get("record_kind") == "reported_seizure_log"):
                _detach_report(conn, existing_alert_outcome)
                existing_alert_outcome = None
            if existing_alert_outcome:
                current_ver = int(existing_alert_outcome._mapping.get("version") or 1)
                existing_id = existing_alert_outcome._mapping["id"]
                if expected_version is None or int(expected_version) != current_ver:
                    raise ValueError("outcome version conflict for this alert")
                next_ver = current_ver + 1
                result = conn.execute(
                    update(outcomes)
                    .where(outcomes.c.id == existing_id, outcomes.c.version == current_ver)
                    .values(
                        outcome=outcome,
                        occurred_at=occurred_at,
                        recorded_by=recorded_by,
                        recorded_at=recorded_at,
                        notes=notes,
                        payload_json=dump_json(metadata or {}),
                        version=next_ver,
                    )
                )
                if result.rowcount != 1:
                    raise ValueError("outcome version conflict for this alert")
                return get_outcome(existing_id)

        if (
            assessment_id
            and conn.execute(
                select(assessments.c.patient_id).where(assessments.c.id == assessment_id)
            ).scalar_one_or_none()
            != patient_id
        ):
            raise ValueError("assessment_id does not belong to this patient")
        if (
            alert_id
            and conn.execute(
                select(alerts.c.patient_id).where(alerts.c.id == alert_id)
            ).scalar_one_or_none()
            != patient_id
        ):
            raise ValueError("alert_id does not belong to this patient")

        conn.execute(
            insert(outcomes).values(
                id=outcome_id,
                patient_id=patient_id,
                assessment_id=assessment_id,
                alert_id=alert_id,
                outcome=outcome,
                occurred_at=occurred_at,
                recorded_by=recorded_by,
                recorded_at=recorded_at,
                notes=notes,
                payload_json=dump_json(metadata or {}),
                version=1,
            )
        )
    return get_outcome(outcome_id)


def get_outcome(outcome_id: str) -> dict | None:
    with connection() as conn:
        row = conn.execute(select(outcomes).where(outcomes.c.id == outcome_id)).first()
    return _outcome(row) if row else None


def list_outcomes(patient_id: str, limit: int = 100) -> list[dict]:
    with connection() as conn:
        rows = conn.execute(
            select(outcomes)
            .where(outcomes.c.patient_id == patient_id)
            .order_by(outcomes.c.sequence.desc())
            .limit(limit)
        )
        return [_outcome(row) for row in rows]


list_for_patient = list_outcomes
