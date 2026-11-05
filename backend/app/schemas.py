import math
from datetime import datetime, timezone
from pydantic import BaseModel, Field, model_validator
from typing import Literal

from app.settings import settings

RiskLabel = Literal["stable", "watch", "high_risk"]


def validate_utc_timestamp(
    value: str | None,
    field_name: str = "timestamp",
    *,
    enforce_max_age: bool = False,
) -> str | None:
    """Validate ISO-8601/UTC clock bounds and keep the original API string.

    Historical windows remain valid for research and replay. Live device
    ingestion opts into the maximum-age check explicitly.
    """
    if value is None:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be a valid ISO-8601 timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError(f"{field_name} must include a timezone")
    parsed_utc = parsed.astimezone(timezone.utc)
    now = datetime.now(timezone.utc)
    age = (now - parsed_utc).total_seconds()
    if age < -settings.timestamp_max_future_seconds:
        raise ValueError(f"{field_name} is too far in the future")
    if enforce_max_age and age > settings.timestamp_max_age_seconds:
        raise ValueError(f"{field_name} is too old")
    return value


class VitalWindow(BaseModel):
    """One analysis window of vital signals."""

    timestamp: str | None = None
    sample_rate_hz: float = Field(default=256.0, ge=1, le=8192, allow_inf_nan=False)
    eeg: list[float] = Field(..., min_length=8, max_length=4096)
    ecg: list[float] = Field(..., min_length=8, max_length=4096)
    motion: list[float] = Field(..., min_length=8, max_length=4096)
    hr: float | None = None
    patient_id: str | None = None

    @model_validator(mode="after")
    def validate_signals(self):
        validate_utc_timestamp(self.timestamp)
        lengths = (len(self.eeg), len(self.ecg), len(self.motion))
        if len(set(lengths)) != 1:
            raise ValueError("eeg, ecg and motion must have the same length")
        for channel_name, channel in (
            ("eeg", self.eeg), ("ecg", self.ecg), ("motion", self.motion)
        ):
            if not all(math.isfinite(value) for value in channel):
                raise ValueError(f"{channel_name} values must be finite")
            if any(abs(value) > 1e6 for value in channel):
                raise ValueError(f"{channel_name} exceeds supported numerical input range")
        if self.hr is not None and (not math.isfinite(self.hr) or not 20 <= self.hr <= 240):
            raise ValueError("hr must be finite and between 20 and 240 bpm")
        return self


class FeatureVector(BaseModel):
    hr_mean: float
    hr_std: float
    eeg_power: float
    eeg_peak: float
    motion_energy: float
    motion_variance: float
    ecg_variability: float


class AnalyzeResponse(BaseModel):
    label: RiskLabel
    confidence: float
    features: FeatureVector
    processing_ms: float
    engine: str = "rules"
    deep_prob: float | None = None
    # --- Prediction layer (additive, optional). These express *forecasting* a
    # seizure ahead of time (preictal-vs-interictal) and ride alongside the
    # existing detection label without changing it. All default to None so the
    # response stays backward-compatible with older clients and tests.
    preictal_prob: float | None = None       # P(preictal) in [0,1]
    lead_time_min: float | None = None       # estimated minutes until onset
    horizon_min: float | None = None         # SPH / prediction horizon used
    predicted: bool | None = None            # pre-alert threshold crossed
    prediction_source: str | None = None     # "simulated_heuristic" | "cnn_lstm_preictal"
    components: dict | None = None           # auditable "why" (rising EEG/HR/motion)


class SimulateRequest(BaseModel):
    pattern: RiskLabel = "stable"
    samples: int = Field(default=262, ge=32, le=1024)
    seed: int | None = None


class SimulateResponse(BaseModel):
    window: VitalWindow
    pattern: RiskLabel
