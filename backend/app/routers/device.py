"""Head-worn device ingestion API (EEG/ECG/Motion gateway)."""
from __future__ import annotations

from fastapi import APIRouter, Header, HTTPException, Request, Depends
from pydantic import BaseModel, Field, model_validator
from typing import Literal

from app.device_hub import DEVICE_WINDOW_SAMPLES, DeviceHub, DeviceSample
from app.schemas import VitalWindow, validate_utc_timestamp
from app.auth import (
    get_current_principal,
    get_optional_principal,
    AuthError,
    authorize_patient_access,
)
from app.settings import settings

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

    @model_validator(mode="after")
    def validate_values(self):
        import math
        values = (self.eeg, self.ecg, self.motion)
        if not all(math.isfinite(value) for value in values):
            raise ValueError("sample values must be finite")
        if any(abs(value) > 1e6 for value in values):
            raise ValueError("sample exceeds supported numerical input range")
        if self.hr is not None and (not math.isfinite(self.hr) or not 20 <= self.hr <= 240):
            raise ValueError("hr must be finite and between 20 and 240 bpm")
        validate_utc_timestamp(self.ts, "ts", enforce_max_age=True)
        return self


class IngestRequest(BaseModel):
    # Current gateway is a normalized prototype contract, not a raw EEG adapter.
    sample_rate_hz: Literal[256] = 256
    signal_units: Literal["normalized_demo"] = "normalized_demo"
    patient_id: str = Field(..., min_length=1)
    device_id: str = Field(default="headband-01")
    samples: list[SampleIn] = Field(..., min_length=1, max_length=512)
    batch_id: str | None = Field(default=None, min_length=1, max_length=128)
    sequence_number: int | None = Field(default=None, ge=0)


class BatchWindowRequest(BaseModel):
    patient_id: str
    device_id: str = "headband-01"
    eeg: list[float] = Field(..., min_length=8, max_length=4096)
    ecg: list[float] = Field(..., min_length=8, max_length=4096)
    motion: list[float] = Field(..., min_length=8, max_length=4096)
    hr: float | None = None
    timestamp: str | None = None
    batch_id: str | None = Field(default=None, min_length=1, max_length=128)
    sequence_number: int | None = Field(default=None, ge=0)

    @model_validator(mode="after")
    def validate_window(self):
        VitalWindow(
            timestamp=self.timestamp,
            eeg=self.eeg,
            ecg=self.ecg,
            motion=self.motion,
            hr=self.hr,
        )
        validate_utc_timestamp(
            self.timestamp, "timestamp", enforce_max_age=True
        )
        return self


def _check_token(authorization: str | None, patient_id: str, device_id: str) -> dict:
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
    if principal.get("legacy") and settings.require_patient_auth:
        raise HTTPException(
            status_code=403,
            detail="Legacy device token is disabled when patient authorization is required",
        )
    if principal.get("role") == "device" and not principal.get("legacy"):
        if principal.get("sub") != device_id:
            raise HTTPException(status_code=403, detail="device_id does not match token")
        authorize_patient_access(patient_id, principal)
    elif principal.get("role") == "admin":
        authorize_patient_access(patient_id, principal)
    return principal


def get_hub(request: Request) -> DeviceHub:
    return request.app.state.device_hub


@router.get("/contract")
def device_contract():
    return {
        "version": 1, "intended_use": "research_and_simulation_only",
        "sample_rate_hz": 256, "eeg_channels": 1,
        "signal_units": "normalized_demo", "max_batch_samples": 512,
        "analysis_window_samples": DEVICE_WINDOW_SAMPLES,
        "channels": ["eeg", "ecg", "motion", "hr"],
        "physical_device_compatible": False,
        "requirements_for_physical_device": [
            "Document sensor, electrode montage and reference, units and calibration",
            "Implement validated sampling, timestamps, signal quality and missing-channel handling",
            "Match the deployed model preprocessing and training input contract",
            "Validate on independent continuous annotated patient recordings",
        ],
    }


@router.post("/ingest")
def ingest_samples(
    body: IngestRequest,
    request: Request,
    authorization: str | None = Header(default=None),
):
    """Receive streaming samples from the head device over WiFi/HTTP."""
    principal = _check_token(authorization, body.patient_id, body.device_id)
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
        batch_id=body.batch_id,
        sequence_number=body.sequence_number,
    )
    return {"ok": True, **result}


@router.post("/ingest-window")
def ingest_window(
    body: BatchWindowRequest,
    request: Request,
    authorization: str | None = Header(default=None),
):
    """Accept a full analysis window from the device firmware or PC gateway."""
    _check_token(authorization, body.patient_id, body.device_id)
    window = VitalWindow(
        eeg=body.eeg,
        ecg=body.ecg,
        motion=body.motion,
        hr=body.hr,
        timestamp=body.timestamp,
        patient_id=body.patient_id,
    )
    result = request.app.state.classifier.predict_window(window)
    features = result.features
    label, confidence = result.label, result.confidence

    hub = get_hub(request)
    samples = [
        DeviceSample(eeg=body.eeg[i], ecg=body.ecg[i], motion=body.motion[i], hr=body.hr)
        for i in range(len(body.eeg))
    ]
    hub.ingest(
        body.patient_id, body.device_id, samples, request.app.state.classifier,
        batch_id=body.batch_id,
        sequence_number=body.sequence_number,
    )

    return {
        "ok": True,
        "assessment": {
            "label": label,
            "confidence": confidence,
            "features": features.model_dump(),
        },
    }


@router.get("/status/{patient_id}")
def device_status(
    patient_id: str,
    request: Request,
    principal: dict = Depends(get_optional_principal),
):
    authorize_patient_access(patient_id, principal)
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
    info = {
        "header": "Authorization: Bearer <token>",
        "endpoints": [
            "/device/ingest",
            "/device/ingest-window",
            "/device/status/{patient_id}",
        ],
    }
    if not settings.is_production and settings.allow_legacy_token:
        info["demo_token"] = DEVICE_TOKEN
    return info
