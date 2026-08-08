from pydantic import BaseModel, Field
from typing import Literal

RiskLabel = Literal["stable", "watch", "high_risk"]


class VitalWindow(BaseModel):
    """One analysis window of vital signals."""

    timestamp: str | None = None
    eeg: list[float] = Field(..., min_length=8)
    ecg: list[float] = Field(..., min_length=8)
    motion: list[float] = Field(..., min_length=8)
    hr: float | None = None
    patient_id: str | None = None


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
    samples: int = Field(default=128, ge=32, le=1024)
    seed: int | None = None


class SimulateResponse(BaseModel):
    window: VitalWindow
    pattern: RiskLabel
