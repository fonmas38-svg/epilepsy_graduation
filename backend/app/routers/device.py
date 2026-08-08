"""Head-worn device ingestion API (EEG/ECG/Motion gateway)."""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException, Request
from pydantic import BaseModel, Field

from app.device_hub import DeviceHub, DeviceSample
from app.preprocessing import extract_features
from app.schemas import VitalWindow
from app.auth import get_current_principal, AuthError

router = APIRouter(prefix="/device", tags=["device"])

# Legacy static token kept ONLY as a fallback for the demo gateway/tests.
# Real auth is JWT (see app/auth.py). Set AUTH_ALLOW_LEGACY_TOKEN=0 to disable.
DEVICE_TOKEN = "headband-demo-token"


class SampleIn(BaseModel):
    eeg: float
    ecg: float
    motion: float
    hr: float | None = None
    ts: str | None = None


class IngestRequest(BaseModel):
    patient_id: str = Field(..., min_length=1)
    device_id: str = Field(default="headband-01")
    samples: list[SampleIn] = Field(..., min_length=1, max_length=512)


class BatchWindowRequest(BaseModel):
    patient_id: str
    device_id: str = "headband-01"
    eeg: list[float] = Field(..., min_length=8)
    ecg: list[float] = Field(..., min_length=8)
    motion: list[float] = Field(..., min_length=8)
    hr: float | None = None


def _check_token(authorization: str | None) -> dict:
    """Authenticate an ingest call. Prefers JWT; falls back to the legacy static
    token only while AUTH_ALLOW_LEGACY_TOKEN is enabled (default on for the demo).
    Returns the decoded principal so callers can log who ingested."""
    try:
        principal = get_current_principal(authorization)
    except AuthError as e:
        # keep the historical contract: bad/absent creds -> 403 on this endpoint
        raise HTTPException(status_code=403, detail=e.detail)
    if principal.get("role") not in ("device", "admin"):
        raise HTTPException(status_code=403, detail="Role not permitted to ingest")
    return principal


def get_hub(request: Request) -> DeviceHub:
    return request.app.state.device_hub


@router.post("/ingest")
def ingest_samples(
    body: IngestRequest,
    request: Request,
    authorization: str | None = Header(default=None),
):
    """Receive streaming samples from the head device over WiFi/HTTP."""
    _check_token(authorization)
    hub = get_hub(request)
    samples = []
    for s in body.samples:
        sample = DeviceSample(eeg=s.eeg, ecg=s.ecg, motion=s.motion, hr=s.hr)
        if s.ts:
            sample.ts = s.ts
        samples.append(sample)

    result = hub.ingest(
        patient_id=body.patient_id,
        device_id=body.device_id,
        samples=samples,
        classifier=request.app.state.classifier,
    )
    return {"ok": True, **result}


@router.post("/ingest-window")
def ingest_window(
    body: BatchWindowRequest,
    request: Request,
    authorization: str | None = Header(default=None),
):
    """Accept a full analysis window from the device firmware or PC gateway."""
    _check_token(authorization)
    window = VitalWindow(
        eeg=body.eeg,
        ecg=body.ecg,
        motion=body.motion,
        hr=body.hr,
        patient_id=body.patient_id,
    )
    features = extract_features(window)
    label, confidence = request.app.state.classifier.predict(features)

    hub = get_hub(request)
    samples = [
        DeviceSample(eeg=body.eeg[i], ecg=body.ecg[i], motion=body.motion[i], hr=body.hr)
        for i in range(len(body.eeg))
    ]
    hub.ingest(body.patient_id, body.device_id, samples, request.app.state.classifier)

    return {
        "ok": True,
        "assessment": {
            "label": label,
            "confidence": confidence,
            "features": features.model_dump(),
        },
    }


@router.get("/status/{patient_id}")
def device_status(patient_id: str, request: Request):
    hub = get_hub(request)
    status = hub.status(patient_id)
    if status is None:
        return {
            "patient_id": patient_id,
            "connected": False,
            "samples_buffered": 0,
            "last_label": None,
            "last_confidence": None,
            "last_window": None,
            # Prediction layer (additive) — null until a window has been assessed.
            "last_preictal_prob": None,
            "last_lead_time_min": None,
            "last_horizon_min": None,
            "last_predicted": None,
            "last_prediction_source": None,
            "preictal_trajectory": [],
        }
    return {
        "patient_id": status.patient_id,
        "device_id": status.device_id,
        "connected": status.connected,
        "last_seen": status.last_seen,
        "samples_buffered": status.samples_buffered,
        "last_label": status.last_label,
        "last_confidence": status.last_confidence,
        "last_window": status.last_window.model_dump() if status.last_window else None,
        "last_engine": status.last_engine,
        "last_deep_prob": status.last_deep_prob,
        "source": status.source,
        # Prediction layer (additive) — latest forecast for this patient.
        "last_preictal_prob": status.last_preictal_prob,
        "last_lead_time_min": status.last_lead_time_min,
        "last_horizon_min": status.last_horizon_min,
        "last_predicted": status.last_predicted,
        "last_prediction_source": status.last_prediction_source,
        "preictal_trajectory": status.preictal_trajectory,
    }


@router.get("/token-info")
def token_info():
    return {
        "header": "Authorization: Bearer <token>",
        "demo_token": DEVICE_TOKEN,
        "endpoints": [
            "/device/ingest",
            "/device/ingest-window",
            "/device/status/{patient_id}",
        ],
    }
