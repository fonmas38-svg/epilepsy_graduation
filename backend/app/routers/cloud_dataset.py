"""Cloud + dataset streaming APIs for MVP without hardware."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from app import cloud_store
from app.device_hub import DeviceSample
from app.preprocessing import extract_features
from app.schemas import VitalWindow
from app.auth import authorize_patient_access, get_optional_principal
from app.settings import settings

router = APIRouter(tags=["cloud-dataset"])

DATA_CSV = Path(__file__).resolve().parents[2] / "data" / "epilepsy_signal_dataset.csv"
SAMPLES = 128
_dataset_cursor: dict[str, int] = {}


class CloudReadingIn(BaseModel):
    patient_id: str
    reading: dict
    assessment: dict | None = None
    alert: dict | None = None


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
    cloud_store.upsert_patient(body.patient_id, {"name": body.patient_id})
    reading = cloud_store.add_reading(body.patient_id, body.reading)
    assessment = None
    alert = None
    if body.assessment:
        assessment = cloud_store.add_assessment(body.patient_id, body.assessment)
    if body.alert:
        alert = cloud_store.add_alert(body.patient_id, body.alert)
    return {"ok": True, "reading": reading, "assessment": assessment, "alert": alert}


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
    features = extract_features(window)
    label, confidence = request.app.state.classifier.predict(features)

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
    cloud_store.add_reading(body.patient_id, reading)
    cloud_store.add_assessment(body.patient_id, assessment)

    alert = None
    if label == "high_risk":
        alert = cloud_store.add_alert(
            body.patient_id,
            {
                "timestamp": window.timestamp,
                "severity": "critical",
                "message": "High seizure risk detected from dataset stream",
                "recipients": ["patient", "caregiver", "doctor"],
            },
        )

    return {
        "window": window.model_dump(),
        "assessment": assessment,
        "alert": alert,
        "truth_label": row["label_name"],
    }
