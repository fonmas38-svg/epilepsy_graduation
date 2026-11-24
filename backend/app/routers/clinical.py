"""Patient-scoped clinical feedback and observed outcome endpoints."""
from typing import Literal
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.exc import IntegrityError
from sqlalchemy import DateTime, cast, func, select

from app import cloud_store, outcomes_store, users_store
from app.auth import authorize_patient_access, get_optional_principal, require_role
from app.schemas import validate_utc_timestamp
from app.database import connection, load_json, readings

router = APIRouter(prefix="/patients", tags=["clinical-feedback"])


@router.get("/{patient_id}/alerts/{alert_id}/evidence")
def event_evidence(patient_id: str, alert_id: str,
                   principal: dict = Depends(require_role("doctor", "admin"))):
    """Stored telemetry around the event; missing history stays explicitly missing."""
    authorize_patient_access(patient_id, principal, enforce=True)
    alert = cloud_store.get_alert(patient_id, alert_id)
    if alert is None:
        raise HTTPException(status_code=404, detail="alert not found")
    try:
        instant = datetime.fromisoformat(str(alert["timestamp"]).replace("Z", "+00:00"))
        if instant.tzinfo is None:
            raise ValueError("missing timezone")
        instant = instant.astimezone(timezone.utc)
    except (ValueError, KeyError):
        raise HTTPException(status_code=422, detail="alert has no valid event timestamp")
    start, end = instant - timedelta(seconds=10), instant + timedelta(seconds=10)
    with connection() as conn:
        if conn.dialect.name == "sqlite":
            stamp = func.julianday(readings.c.captured_at)
            lower, upper = func.julianday(start.isoformat()), func.julianday(end.isoformat())
        else:
            stamp = cast(readings.c.captured_at, DateTime(timezone=True))
            lower, upper = start, end
        rows = conn.execute(select(readings.c.payload_json).where(
            readings.c.patient_id == patient_id, stamp >= lower, stamp <= upper,
        ).order_by(stamp, readings.c.sequence).limit(65)).all()
    return {"alert": alert, "windowStart": start.isoformat(), "windowEnd": end.isoformat(),
            "readings": [load_json(row[0], {}) for row in rows[:64]],
            "truncated": len(rows) > 64, "available": bool(rows)}


class SeizureLogRequest(BaseModel):
    id: UUID
    occurred_at: str
    duration_seconds: int | None = Field(default=None, ge=1, le=86400)
    seizure_type: Literal["focal", "generalized", "absence", "other"] = "other"
    notes: str = Field(default="", max_length=2000)
    reported_by: str | None = Field(default=None, max_length=128)
    alert_id: str | None = None


def _reported_event(row: dict) -> dict:
    return {"id": row["id"], "patientId": row["patientId"],
            "occurredAt": row["occurredAt"], "durationSeconds": row.get("duration_seconds"),
            "type": row.get("seizure_type", "other"), "notes": row.get("notes", ""),
            "reportedBy": row["recordedBy"], "alertId": row.get("reported_alert_id", row.get("alertId")),
            "clinicallyConfirmed": False}


@router.post("/{patient_id}/seizure-logs", status_code=201)
def record_reported_event(patient_id: str, body: SeizureLogRequest,
                          principal: dict = Depends(require_role("patient", "caregiver", "doctor"))):
    authorize_patient_access(patient_id, principal, enforce=True)
    try:
        validate_utc_timestamp(body.occurred_at, "occurred_at")
        row = outcomes_store.add_outcome(
            patient_id=patient_id, outcome="seizure", occurred_at=body.occurred_at,
            recorded_by=str(principal["sub"]), alert_id=body.alert_id, notes=body.notes,
            client_id=str(body.id), metadata={"record_kind": "reported_seizure_log",
                "duration_seconds": body.duration_seconds, "seizure_type": body.seizure_type,
                "clinically_confirmed": False},
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except IntegrityError:
        # A concurrent replay may have inserted the same immutable record first.
        saved = outcomes_store.get_outcome(str(body.id))
        if not saved or saved.get("patientId") != patient_id or saved.get("recordedBy") != str(principal["sub"]):
            raise HTTPException(status_code=409, detail="record conflict")
        try:
            row = outcomes_store.add_outcome(patient_id=patient_id, outcome="seizure",
                occurred_at=body.occurred_at, recorded_by=str(principal["sub"]),
                alert_id=body.alert_id, notes=body.notes, client_id=str(body.id),
                metadata={"record_kind": "reported_seizure_log", "duration_seconds": body.duration_seconds,
                          "seizure_type": body.seizure_type, "clinically_confirmed": False})
        except ValueError:
            raise HTTPException(status_code=409, detail="record conflict")
    users_store.log(principal["sub"], principal["role"], "record_reported_event", row["id"], {"patientId": patient_id})
    return {"event": _reported_event(row)}


@router.get("/{patient_id}/seizure-logs")
def reported_events(patient_id: str, limit: int = Query(200, ge=1, le=500),
                    principal: dict = Depends(require_role("patient", "caregiver", "doctor"))):
    authorize_patient_access(patient_id, principal, enforce=True)
    rows = outcomes_store.list_outcomes(patient_id, limit)
    return [_reported_event(row) for row in rows if row.get("record_kind") == "reported_seizure_log"]


class AcknowledgeRequest(BaseModel):
    note: str | None = Field(default=None, max_length=1000)


class OutcomeRequest(BaseModel):
    id: UUID | None = None
    outcome: Literal["seizure", "no_seizure", "false_alarm", "unknown"]
    occurred_at: str
    assessment_id: str | None = None
    alert_id: str | None = None
    notes: str | None = Field(default=None, max_length=2000)
    expected_version: int | None = Field(default=None, ge=1)
    seizure_type: str | None = Field(default=None, max_length=64)
    artifact_cause: str | None = Field(default=None, max_length=120)
    metadata: dict = Field(default_factory=dict)


@router.get("/{patient_id}/alerts/{alert_id}")
def alert_details(patient_id: str, alert_id: str,
                  principal: dict = Depends(get_optional_principal)):
    authorize_patient_access(patient_id, principal, enforce=True)
    alert = cloud_store.get_alert(patient_id, alert_id)
    if alert is None:
        raise HTTPException(status_code=404, detail="alert not found or no longer retained")
    readings = cloud_store.list_readings(patient_id, 1)
    latest_reading = readings[0] if readings else None
    return {"alert": alert, "reading": latest_reading}


@router.post("/{patient_id}/alerts/{alert_id}/acknowledgments", status_code=201)
def acknowledge_alert(
    patient_id: str, alert_id: str, body: AcknowledgeRequest,
    principal: dict = Depends(get_optional_principal),
):
    authorize_patient_access(patient_id, principal)
    acknowledged = cloud_store.ack_alert(
        patient_id, alert_id, str(principal.get("sub", "unknown")),
        actor_role=principal.get("role"), note=body.note,
    )
    if not acknowledged:
        raise HTTPException(status_code=404, detail="alert not found")
    users_store.log(principal.get("sub"), principal.get("role"), "ack_alert", alert_id,
                    {"patientId": patient_id})
    return {"alert": acknowledged}


@router.get("/{patient_id}/alerts/{alert_id}/acknowledgments")
def list_acknowledgments(
    patient_id: str, alert_id: str,
    principal: dict = Depends(get_optional_principal),
):
    authorize_patient_access(patient_id, principal)
    if not any(a.get("id") == alert_id for a in cloud_store.list_alerts(patient_id, 200)):
        raise HTTPException(status_code=404, detail="alert not found")
    return {"acknowledgments": cloud_store.list_alert_acknowledgments(patient_id, alert_id)}


@router.post("/{patient_id}/outcomes", status_code=201)
def create_outcome(
    patient_id: str, body: OutcomeRequest,
    principal: dict = Depends(get_optional_principal),
):
    authorize_patient_access(patient_id, principal, enforce=True)
    if body.alert_id and principal.get("role") not in ("doctor", "admin"):
        raise HTTPException(status_code=403, detail="only a clinician can adjudicate an alert")
    meta = dict(body.metadata or {})
    if body.seizure_type:
        meta["seizure_type"] = body.seizure_type
    if body.artifact_cause:
        meta["artifact_cause"] = body.artifact_cause
    try:
        validate_utc_timestamp(body.occurred_at, "occurred_at")
        outcome = outcomes_store.add_outcome(
            patient_id=patient_id, outcome=body.outcome,
            occurred_at=body.occurred_at, recorded_by=str(principal.get("sub", "unknown")),
            assessment_id=body.assessment_id, alert_id=body.alert_id,
            notes=body.notes, metadata=meta,
            client_id=str(body.id) if body.id else None,
            expected_version=body.expected_version,
        )
    except ValueError as exc:
        if "client id is already used" in str(exc) or "outcome version conflict" in str(exc):
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        raise HTTPException(status_code=422, detail=str(exc))
    except IntegrityError as exc:
        raise HTTPException(status_code=409, detail="outcome conflict for this alert") from exc
    users_store.log(principal.get("sub"), principal.get("role"), "record_outcome",
                    outcome["id"], {"patientId": patient_id})
    return {"outcome": outcome}


@router.get("/{patient_id}/outcomes")
def list_outcomes(
    patient_id: str, limit: int = Query(100, ge=1, le=500),
    principal: dict = Depends(get_optional_principal),
):
    authorize_patient_access(patient_id, principal)
    return {"outcomes": outcomes_store.list_outcomes(patient_id, limit)}
