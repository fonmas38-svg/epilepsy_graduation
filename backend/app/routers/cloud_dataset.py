"""Cloud + dataset streaming APIs for MVP without hardware."""
from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

import numpy as np
import pandas as pd
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import AliasChoices, BaseModel, ConfigDict, Field, model_validator
from sqlalchemy.exc import IntegrityError

from app import cloud_store
from app.device_hub import DeviceSample
from app.schemas import VitalWindow
from app.auth import (
    authorize_patient_access,
    get_current_principal,
    get_optional_principal,
)
from app.settings import settings

router = APIRouter(tags=["cloud-dataset"])

DATA_CSV = Path(__file__).resolve().parents[2] / "data" / "epilepsy_signal_dataset.csv"
SAMPLES = 128
MAX_SYNC_BATCH_ITEMS = 500
_dataset_cursor: dict[str, int] = {}


class CloudReadingIn(BaseModel):
    patient_id: str
    reading: dict
    assessment: dict | None = None
    alert: dict | None = None


class IntakeLogIn(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    id: str | None = Field(default=None, min_length=1, max_length=64)
    patient_id: str | None = Field(
        default=None,
        validation_alias=AliasChoices("patient_id", "patientId"),
    )
    prescription_id: str = Field(
        ...,
        min_length=1,
        max_length=64,
        validation_alias=AliasChoices("prescription_id", "medicationId"),
    )
    scheduled_time: str = Field(
        ...,
        min_length=1,
        max_length=64,
        validation_alias=AliasChoices("scheduled_time", "scheduledFor"),
    )
    taken_at: str | None = Field(
        default=None,
        max_length=64,
        validation_alias=AliasChoices("taken_at", "takenAt"),
    )
    status: Literal["taken", "missed", "skipped"] = "taken"
    recorded_by: str | None = Field(
        default=None,
        max_length=64,
        validation_alias=AliasChoices("recorded_by", "recordedBy"),
    )


class CloudSyncBundleIn(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    patient_id: str | None = Field(
        default=None,
        validation_alias=AliasChoices("patient_id", "patientId"),
    )
    reading: dict[str, Any]
    assessment: dict[str, Any] | None = None
    alert: dict[str, Any] | None = None


class CloudSyncBatchIn(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    patient_id: str | None = Field(
        default=None,
        validation_alias=AliasChoices("patient_id", "patientId"),
    )
    bundles: list[CloudSyncBundleIn] = Field(
        default_factory=list,
        validation_alias=AliasChoices("bundles", "items"),
    )
    readings: list[dict[str, Any]] = Field(default_factory=list)
    assessments: list[dict[str, Any]] = Field(default_factory=list)
    alerts: list[dict[str, Any]] = Field(default_factory=list)
    intake_logs: list[IntakeLogIn] = Field(
        default_factory=list,
        validation_alias=AliasChoices("intake_logs", "medication_logs"),
    )
    idempotency_key: str | None = Field(default=None, max_length=128)

    @model_validator(mode="after")
    def validate_batch_limits(self):
        total = (
            len(self.bundles)
            + len(self.readings)
            + len(self.assessments)
            + len(self.alerts)
            + len(self.intake_logs)
        )
        if total > MAX_SYNC_BATCH_ITEMS:
            raise ValueError(
                f"batch cannot exceed {MAX_SYNC_BATCH_ITEMS} items (got {total})"
            )
        return self


class CloudSyncBatchResponse(BaseModel):
    ok: bool = True
    processed: dict[str, int]
    synced_reading_ids: list[str]
    readings: list[dict[str, Any]]
    assessments: list[dict[str, Any]]
    alerts: list[dict[str, Any]]
    intake_logs: list[dict[str, Any]]


class DatasetNextRequest(BaseModel):
    patient_id: str = "patient-demo"
    prefer_label: str | None = Field(
        default=None, description="stable | watch | high_risk or null for sequential"
    )
    push_to_device_hub: bool = True


def _ensure_dataset() -> Path:
    if DATA_CSV.exists():
        return DATA_CSV
    # build if missing
    import subprocess
    import sys

    build = DATA_CSV.parent / "build_dataset.py"
    subprocess.check_call([sys.executable, str(build)])
    if not DATA_CSV.exists():
        raise FileNotFoundError("dataset missing")
    return DATA_CSV


def _row_to_window(row: pd.Series, patient_id: str) -> VitalWindow:
    eeg = [float(row[f"eeg_{i}"]) for i in range(SAMPLES)]
    ecg = [float(row[f"ecg_{i}"]) for i in range(SAMPLES)]
    motion = [float(row[f"motion_{i}"]) for i in range(SAMPLES)]
    return VitalWindow(
        eeg=eeg,
        ecg=ecg,
        motion=motion,
        hr=float(row["hr"]),
        patient_id=patient_id,
    )


@router.get("/cloud/patients")
def cloud_patients(principal: dict = Depends(get_optional_principal)):
    patients = cloud_store.list_patients()
    if principal.get("role") == "admin" or not settings.require_patient_auth:
        return {"patients": patients}
    allowed = []
    for patient in patients:
        try:
            authorize_patient_access(patient.get("patientId", ""), principal)
            allowed.append(patient)
        except HTTPException:
            continue
    return {"patients": allowed}


@router.get("/cloud/patients/{patient_id}")
def cloud_patient(patient_id: str, principal: dict = Depends(get_optional_principal)):
    authorize_patient_access(patient_id, principal)
    p = cloud_store.get_patient(patient_id)
    if not p:
        # default demo patient
        p = cloud_store.upsert_patient(
            patient_id,
            {"name": patient_id, "currentStatus": "stable"},
        )
    return {
        "patient": p,
        "readings": cloud_store.list_readings(patient_id, 30),
        "assessments": cloud_store.list_assessments(patient_id, 30),
        "alerts": cloud_store.list_alerts(patient_id, 30),
    }


@router.post("/cloud/sync")
def cloud_sync(body: CloudReadingIn, principal: dict = Depends(get_optional_principal)):
    authorize_patient_access(body.patient_id, principal)
    # One transaction: a client never ends up with a reading whose derived
    # assessment/alert failed to persist.
    try:
        saved = cloud_store.save_monitoring_bundle(
            body.patient_id,
            body.reading,
            assessment=body.assessment or None,
            alert=body.alert or None,
            patient_profile={"name": body.patient_id},
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc

    return {
        "ok": True,
        "reading": saved["reading"],
        "assessment": saved["assessment"],
        "alert": saved["alert"],
    }


def _str_or_none(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    return None


def _resolve_patient_id(explicit: str | None, fallback: str | None) -> str:
    pid = (explicit or fallback or "").strip()
    if not pid:
        raise HTTPException(status_code=422, detail="patient_id is required")
    return pid


@router.post("/cloud/sync-batch", response_model=CloudSyncBatchResponse)
def cloud_sync_batch(
    body: CloudSyncBatchIn,
    principal: dict = Depends(get_current_principal),
):
    distinct_patients: list[str] = []
    seen_patients: set[str] = set()

    def _track_patient(pid: str) -> str:
        if pid not in seen_patients:
            seen_patients.add(pid)
            distinct_patients.append(pid)
        return pid

    bundle_items: list[
        tuple[str, dict[str, Any], dict[str, Any] | None, dict[str, Any] | None]
    ] = []
    for bundle in body.bundles:
        pid = _track_patient(
            _resolve_patient_id(
                bundle.patient_id
                or _str_or_none(bundle.reading.get("patient_id"))
                or _str_or_none(bundle.reading.get("patientId")),
                body.patient_id,
            )
        )
        for nested in (bundle.assessment, bundle.alert):
            if nested is not None:
                nested_pid = _str_or_none(nested.get("patient_id")) or _str_or_none(
                    nested.get("patientId")
                )
                if nested_pid and nested_pid.strip() != pid:
                    raise HTTPException(
                        status_code=422,
                        detail="nested bundle item patient_id does not match bundle patient_id",
                    )
        bundle_items.append((pid, bundle.reading, bundle.assessment, bundle.alert))

    readings_items: list[tuple[str, dict[str, Any]]] = []
    for reading in body.readings:
        pid = _track_patient(
            _resolve_patient_id(
                _str_or_none(reading.get("patient_id"))
                or _str_or_none(reading.get("patientId")),
                body.patient_id,
            )
        )
        readings_items.append((pid, reading))

    assessments_items: list[tuple[str, dict[str, Any]]] = []
    for assessment in body.assessments:
        pid = _track_patient(
            _resolve_patient_id(
                _str_or_none(assessment.get("patient_id"))
                or _str_or_none(assessment.get("patientId")),
                body.patient_id,
            )
        )
        assessments_items.append((pid, assessment))

    alerts_items: list[tuple[str, dict[str, Any]]] = []
    for alert in body.alerts:
        pid = _track_patient(
            _resolve_patient_id(
                _str_or_none(alert.get("patient_id"))
                or _str_or_none(alert.get("patientId")),
                body.patient_id,
            )
        )
        alerts_items.append((pid, alert))

    intake_logs_items: list[tuple[str, dict[str, Any]]] = []
    for log_entry in body.intake_logs:
        pid = _track_patient(_resolve_patient_id(log_entry.patient_id, body.patient_id))
        intake_logs_items.append(
            (
                pid,
                {
                    "id": log_entry.id,
                    "prescription_id": log_entry.prescription_id,
                    "scheduled_time": log_entry.scheduled_time,
                    "taken_at": log_entry.taken_at,
                    "status": log_entry.status,
                    "recorded_by": log_entry.recorded_by,
                },
            )
        )

    for pid in distinct_patients:
        authorize_patient_access(pid, principal, enforce=True)

    try:
        saved = cloud_store.save_monitoring_batch(
            bundles=bundle_items,
            readings_items=readings_items,
            assessments_items=assessments_items,
            alerts_items=alerts_items,
            intake_logs_items=intake_logs_items,
            recorded_by=str(principal.get("sub") or "system"),
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except LookupError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except IntegrityError as exc:
        raise HTTPException(
            status_code=422, detail="Batch persistence constraint violation"
        ) from exc

    return CloudSyncBatchResponse(
        ok=True,
        processed={
            "bundles": len(body.bundles),
            "readings": len(body.readings),
            "assessments": len(body.assessments),
            "alerts": len(body.alerts),
            "intake_logs": len(body.intake_logs),
        },
        synced_reading_ids=saved["synced_reading_ids"],
        readings=saved["readings"],
        assessments=saved["assessments"],
        alerts=saved["alerts"],
        intake_logs=saved["intake_logs"],
    )


@router.post("/cloud/alerts/{patient_id}/{alert_id}/ack")
def cloud_ack(
    patient_id: str,
    alert_id: str,
    principal: dict = Depends(get_optional_principal),
):
    authorize_patient_access(patient_id, principal)
    a = cloud_store.ack_alert(patient_id, alert_id, str(principal.get("sub")))
    if not a:
        raise HTTPException(404, "alert not found")
    return a


@router.get("/dataset/info")
def dataset_info():
    path = _ensure_dataset()
    df = pd.read_csv(path, usecols=["label_name"])
    return {
        "path": str(path),
        "rows": int(len(df)),
        "labels": df["label_name"].value_counts().to_dict(),
        "note": "Offline dataset used while hardware is unavailable",
    }


@router.post("/dataset/next")
def dataset_next(
    body: DatasetNextRequest,
    request: Request,
    principal: dict = Depends(get_optional_principal),
):
    """Fetch next labeled window from dataset, analyze, optionally publish to device hub/cloud."""
    authorize_patient_access(body.patient_id, principal)
    path = _ensure_dataset()
    df = pd.read_csv(path)
    if body.prefer_label:
        subset = df[df["label_name"] == body.prefer_label]
        if subset.empty:
            raise HTTPException(400, f"no rows for label {body.prefer_label}")
        row = subset.sample(1, random_state=None).iloc[0]
    else:
        idx = _dataset_cursor.get(body.patient_id, 0) % len(df)
        _dataset_cursor[body.patient_id] = idx + 1
        row = df.iloc[idx]

    window = _row_to_window(row, body.patient_id)
    result = request.app.state.classifier.predict_window(window)
    features = result.features
    label, confidence = result.label, result.confidence

    if body.push_to_device_hub:
        samples = [
            DeviceSample(eeg=window.eeg[i], ecg=window.ecg[i], motion=window.motion[i], hr=window.hr)
            for i in range(len(window.eeg))
        ]
        request.app.state.device_hub.ingest(
            body.patient_id, "dataset-player", samples, request.app.state.classifier
        )

    assessment = {
        "label": label,
        "confidence": confidence,
        "features": features.model_dump(),
        "timestamp": window.timestamp,
        "dataset_label": row["label_name"],
        "mode": "dataset",
    }
    reading = {
        "timestamp": window.timestamp,
        "eeg": window.eeg,
        "ecg": window.ecg,
        "motion": window.motion,
        "hr": window.hr,
        "source": "dataset",
    }
    alert_payload = None
    if label == "high_risk":
        alert_payload = {
            "timestamp": window.timestamp,
            "severity": "critical",
            "message": "High seizure risk detected from dataset stream",
            "recipients": ["patient", "caregiver", "doctor"],
        }
    saved = cloud_store.save_monitoring_bundle(
        body.patient_id, reading, assessment=assessment, alert=alert_payload
    )
    alert = saved["alert"]

    return {
        "window": window.model_dump(),
        "assessment": assessment,
        "alert": alert,
        "truth_label": row["label_name"],
    }
