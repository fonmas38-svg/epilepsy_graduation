from __future__ import annotations
from datetime import datetime, timezone
from typing import Literal
from uuid import uuid4
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from app import cloud_store, messages_store, users_store
from app.auth import get_current_principal, require_role

router = APIRouter(tags=["prescriptions"])
require_doctor = require_role("doctor", "admin")


def _now():
    return datetime.now(timezone.utc).isoformat()


def _assert_patient_access(patient_id, actor):
    if actor.get("role") == "admin":
        return
    patient = users_store.get_user(patient_id)
    if not patient or patient.get("role") != "patient":
        raise HTTPException(status_code=404, detail="patient not found")
    if not users_store.is_assigned(patient_id, actor.get("sub")):
        raise HTTPException(status_code=403, detail="patient not assigned to you")


class PrescriptionRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=200)
    dose: str = Field(..., min_length=1, max_length=100)
    schedule: str = Field(..., min_length=1, max_length=200)
    notes: str | None = Field(default=None, max_length=1000)
    period_context: str | None = Field(default=None, max_length=32)
    meal_context: str | None = Field(default=None, max_length=32)
    meal_type: str | None = Field(default=None, max_length=32)
    times: list[str] | None = None


class UpdatePrescriptionRequest(BaseModel):
    name: str | None = Field(default=None, max_length=200)
    dose: str | None = Field(default=None, max_length=100)
    schedule: str | None = Field(default=None, max_length=200)
    notes: str | None = Field(default=None, max_length=1000)
    active: bool | None = None
    period_context: str | None = Field(default=None, max_length=32)
    meal_context: str | None = Field(default=None, max_length=32)
    meal_type: str | None = Field(default=None, max_length=32)
    times: list[str] | None = None


class IntakeLogRequest(BaseModel):
    id: str | None = Field(default=None, max_length=64)
    scheduled_time: str = Field(..., min_length=1, max_length=64)
    taken_at: str | None = Field(default=None, max_length=64)
    status: Literal["taken", "missed", "skipped"] = "taken"


@router.post("/doctor/patients/{patient_id}/prescriptions", status_code=201)
def prescribe(patient_id: str, body: PrescriptionRequest, actor: dict = Depends(require_doctor)):
    _assert_patient_access(patient_id, actor)
    rx_id = str(uuid4())
    now = _now()
    rx = {
        "id": rx_id,
        "patient_id": patient_id,
        "doctor_id": actor.get("sub"),
        "name": body.name,
        "dose": body.dose,
        "schedule": body.schedule,
        "notes": body.notes,
        "period_context": body.period_context,
        "meal_context": body.meal_context,
        "meal_type": body.meal_type,
        "times": body.times or [],
        "active": True,
        "created_at": now,
        "updated_at": now,
    }
    cloud_store.upsert_sql_prescription(rx)
    patient_doc = cloud_store.get_patient(patient_id) or {}
    existing = list(patient_doc.get("prescriptions") or [])
    existing.append(rx)
    cloud_store.upsert_patient(patient_id, {"prescriptions": existing})
    users_store.log(
        actor.get("sub"),
        actor.get("role"),
        "prescribe",
        rx_id,
        {"patientId": patient_id, "medication": body.name},
    )

    try:
        doc_user = users_store.get_user(actor.get("sub"))
        doc_name = doc_user.get("name") if doc_user else "الطبيب المعالج"
        msg_text = f"💊 وصفة طبية جديدة: {body.name} (الجرعة: {body.dose} - {body.schedule})"
        if body.notes:
            msg_text += f"\nملاحظات: {body.notes}"
        messages_store.create_message(
            patient_id=patient_id,
            sender_id=str(actor.get("sub", "")),
            sender_name=doc_name,
            sender_role="doctor",
            channel_type="doctor_patient",
            content=msg_text,
        )
    except Exception:
        pass

    return {"prescription": rx}


@router.get("/doctor/patients/{patient_id}/prescriptions")
def list_prescriptions(patient_id: str, actor: dict = Depends(require_doctor)):
    _assert_patient_access(patient_id, actor)
    patient_doc = cloud_store.get_patient(patient_id) or {}
    return {"prescriptions": list(patient_doc.get("prescriptions") or [])}


@router.patch("/doctor/patients/{patient_id}/prescriptions/{rx_id}")
def update_prescription(
    patient_id: str,
    rx_id: str,
    body: UpdatePrescriptionRequest,
    actor: dict = Depends(require_doctor),
):
    _assert_patient_access(patient_id, actor)
    patient_doc = cloud_store.get_patient(patient_id) or {}
    prescriptions = list(patient_doc.get("prescriptions") or [])
    rx = next((p for p in prescriptions if p.get("id") == rx_id), None)
    if rx is None:
        raise HTTPException(status_code=404, detail="prescription not found")
    for field, val in [
        ("name", body.name),
        ("dose", body.dose),
        ("schedule", body.schedule),
        ("notes", body.notes),
        ("active", body.active),
        ("period_context", body.period_context),
        ("meal_context", body.meal_context),
        ("meal_type", body.meal_type),
        ("times", body.times),
    ]:
        if val is not None:
            rx[field] = val
    rx["updated_at"] = _now()
    cloud_store.upsert_sql_prescription(rx)
    cloud_store.upsert_patient(patient_id, {"prescriptions": prescriptions})
    users_store.log(
        actor.get("sub"),
        actor.get("role"),
        "update_prescription",
        rx_id,
        {"patientId": patient_id},
    )
    return {"prescription": rx}


@router.delete("/doctor/patients/{patient_id}/prescriptions/{rx_id}")
def cancel_prescription(patient_id: str, rx_id: str, actor: dict = Depends(require_doctor)):
    _assert_patient_access(patient_id, actor)
    patient_doc = cloud_store.get_patient(patient_id) or {}
    prescriptions = list(patient_doc.get("prescriptions") or [])
    rx = next((p for p in prescriptions if p.get("id") == rx_id), None)
    if rx is None:
        raise HTTPException(status_code=404, detail="prescription not found")
    rx["active"] = False
    rx["updated_at"] = _now()
    cloud_store.upsert_sql_prescription(rx)
    cloud_store.upsert_patient(patient_id, {"prescriptions": prescriptions})
    users_store.log(
        actor.get("sub"),
        actor.get("role"),
        "cancel_prescription",
        rx_id,
        {"patientId": patient_id},
    )
    return {"ok": True, "prescription": rx}


# --------------------------------------------------------------------------- Patient & Caregiver Access


@router.get("/patient/prescriptions")
def patient_list_prescriptions(
    patient_id: str | None = None,
    actor: dict = Depends(get_current_principal),
):
    """Retrieve prescriptions for the authenticated patient or their linked caregiver."""
    role = actor.get("role")
    sub = str(actor.get("sub", ""))
    target_pid = patient_id

    if role == "patient":
        target_pid = sub
    elif role == "caregiver":
        linked = users_store.patients_for_caregiver(sub)
        if not linked:
            return {"prescriptions": []}
        if not target_pid or target_pid not in linked:
            target_pid = linked[0]
    elif role in ("doctor", "admin"):
        if not target_pid:
            raise HTTPException(status_code=400, detail="patient_id is required")
        _assert_patient_access(target_pid, actor)
    else:
        raise HTTPException(status_code=403, detail="access denied")

    patient_doc = cloud_store.get_patient(target_pid) or {}
    return {
        "patientId": target_pid,
        "prescriptions": list(patient_doc.get("prescriptions") or []),
    }


@router.get("/patients/{patient_id}/prescriptions")
def get_patient_prescriptions(
    patient_id: str,
    actor: dict = Depends(get_current_principal),
):
    """Fetch prescriptions for a given patient with RBAC enforcement."""
    role = actor.get("role")
    sub = str(actor.get("sub", ""))

    if role == "patient":
        if sub != patient_id:
            raise HTTPException(status_code=403, detail="cannot view another patient's prescriptions")
    elif role == "caregiver":
        if not users_store.is_caregiver_linked(patient_id, sub):
            raise HTTPException(status_code=403, detail="patient not linked to this caregiver")
    elif role in ("doctor", "admin"):
        _assert_patient_access(patient_id, actor)
    else:
        raise HTTPException(status_code=403, detail="access denied")

    patient_doc = cloud_store.get_patient(patient_id) or {}
    return {
        "patientId": patient_id,
        "prescriptions": list(patient_doc.get("prescriptions") or []),
    }


@router.post("/patient/prescriptions/{rx_id}/intake-log", status_code=201)
def record_prescription_intake_log(
    rx_id: str,
    body: IntakeLogRequest,
    actor: dict = Depends(require_role("patient")),
):
    """Patient-only endpoint to record medication adherence (taken/missed/skipped) (#11)."""
    patient_id = str(actor.get("sub", ""))
    patient_doc = cloud_store.get_patient(patient_id) or {}
    prescriptions = list(patient_doc.get("prescriptions") or [])
    rx = next((p for p in prescriptions if p.get("id") == rx_id), None)
    if rx is not None:
        cloud_store.upsert_sql_prescription(rx)

    try:
        saved = cloud_store.add_medication_log(
            patient_id,
            {
                "id": body.id,
                "prescription_id": rx_id,
                "scheduled_time": body.scheduled_time,
                "taken_at": body.taken_at or (_now() if body.status == "taken" else None),
                "status": body.status,
            },
            recorded_by=patient_id,
        )
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc

    users_store.log(
        patient_id,
        "patient",
        "record_medication_intake",
        rx_id,
        {"status": body.status, "scheduledTime": body.scheduled_time},
    )
    return {"log": saved}


@router.get("/doctor/patients/{patient_id}/adherence")
@router.get("/patients/{patient_id}/adherence")
def get_patient_adherence(
    patient_id: str,
    limit: int = Query(200, ge=1, le=500),
    actor: dict = Depends(get_current_principal),
):
    """Retrieve dose adherence logs and summary statistics for a patient (#11)."""
    role = actor.get("role")
    sub = str(actor.get("sub", ""))
    if role == "patient":
        if sub != patient_id:
            raise HTTPException(status_code=403, detail="cannot view another patient's adherence")
    elif role == "caregiver":
        if not users_store.is_caregiver_linked(patient_id, sub):
            raise HTTPException(status_code=403, detail="patient not linked to this caregiver")
    elif role in ("doctor", "admin"):
        _assert_patient_access(patient_id, actor)
    else:
        raise HTTPException(status_code=403, detail="access denied")

    logs = cloud_store.list_medication_logs(patient_id, limit=limit)
    total = len(logs)
    taken = sum(1 for l in logs if l["status"] == "taken")
    missed = sum(1 for l in logs if l["status"] == "missed")
    skipped = sum(1 for l in logs if l["status"] == "skipped")
    rate = round((taken / total) * 100.0, 1) if total > 0 else 100.0
    return {
        "patientId": patient_id,
        "totalLogs": total,
        "takenCount": taken,
        "missedCount": missed,
        "skippedCount": skipped,
        "adherenceRate": rate,
        "logs": logs,
    }
