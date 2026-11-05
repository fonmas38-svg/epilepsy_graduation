"""Patient-scoped clinical feedback and observed outcome endpoints."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.exc import IntegrityError

from app import cloud_store, outcomes_store, users_store
from app.auth import authorize_patient_access, get_optional_principal
from app.schemas import validate_utc_timestamp

router = APIRouter(prefix="/patients", tags=["clinical-feedback"])


class AcknowledgeRequest(BaseModel):
    note: str | None = Field(default=None, max_length=1000)


class OutcomeRequest(BaseModel):
    outcome: Literal["seizure", "no_seizure", "false_alarm", "unknown"]
    occurred_at: str
    assessment_id: str | None = None
    alert_id: str | None = None
    notes: str | None = Field(default=None, max_length=2000)
    metadata: dict = Field(default_factory=dict)


@router.get("/{patient_id}/alerts/{alert_id}")
def alert_details(patient_id: str, alert_id: str,
                  principal: dict = Depends(get_optional_principal)):
    authorize_patient_access(patient_id, principal, enforce=True)
    alert = cloud_store.get_alert(patient_id, alert_id)
    if alert is None:
        raise HTTPException(status_code=404, detail="alert not found or no longer retained")
    return {"alert": alert}


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
    authorize_patient_access(patient_id, principal)
    try:
        validate_utc_timestamp(body.occurred_at, "occurred_at")
        outcome = outcomes_store.add_outcome(
            patient_id=patient_id, outcome=body.outcome,
            occurred_at=body.occurred_at, recorded_by=str(principal.get("sub", "unknown")),
            assessment_id=body.assessment_id, alert_id=body.alert_id,
            notes=body.notes, metadata=body.metadata,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    except IntegrityError:
        raise HTTPException(status_code=422, detail="linked assessment or alert is invalid")
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
