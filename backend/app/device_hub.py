"""Buffer incoming head-device samples into analysis windows."""
from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from threading import Lock
from typing import Deque

from app.preprocessing import extract_features
from app.schemas import RiskLabel, VitalWindow


@dataclass
class DeviceSample:
    eeg: float
    ecg: float
    motion: float
    hr: float | None = None
    ts: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


@dataclass
class DeviceStatus:
    patient_id: str
    device_id: str
    connected: bool
    last_seen: str
    samples_buffered: int
    last_label: RiskLabel | None = None
    last_confidence: float | None = None
    last_window: VitalWindow | None = None
    last_engine: str | None = None
    last_deep_prob: float | None = None
    source: str = "device"
    # --- Prediction layer (additive). Latest forecast for this patient.
    last_preictal_prob: float | None = None
    last_lead_time_min: float | None = None
    last_horizon_min: float | None = None
    last_predicted: bool | None = None
    last_prediction_source: str | None = None
    preictal_trajectory: list = field(default_factory=list)


class DeviceHub:
    """In-memory hub for graduation demo (replace with Redis in production)."""

    def __init__(self, window_size: int = 128):
        self.window_size = window_size
        self._buffers: dict[str, Deque[DeviceSample]] = defaultdict(
            lambda: deque(maxlen=window_size * 4)
        )
        self._meta: dict[str, dict] = {}
        self._latest: dict[str, DeviceStatus] = {}
        # Bounded per-patient history of preictal probabilities → forecast sparkline.
        self._trajectories: dict[str, Deque[float]] = defaultdict(
            lambda: deque(maxlen=60)
        )
        self._lock = Lock()

    def ingest(
        self,
        patient_id: str,
        device_id: str,
        samples: list[DeviceSample],
        classifier,
    ) -> dict:
        with self._lock:
            key = patient_id
            buf = self._buffers[key]
            for s in samples:
                buf.append(s)
            self._meta[key] = {
                "device_id": device_id,
                "last_seen": datetime.now(timezone.utc).isoformat(),
            }

            result = {
                "accepted": len(samples),
                "buffered": len(buf),
                "window_ready": len(buf) >= self.window_size,
                "assessment": None,
            }

            if len(buf) >= self.window_size:
                window_samples = list(buf)[-self.window_size :]
                window = VitalWindow(
                    timestamp=window_samples[-1].ts,
                    eeg=[s.eeg for s in window_samples],
                    ecg=[s.ecg for s in window_samples],
                    motion=[s.motion for s in window_samples],
                    hr=next((s.hr for s in reversed(window_samples) if s.hr is not None), None),
                    patient_id=patient_id,
                )
                # Prefer the full multimodal + deep path when available.
                if hasattr(classifier, "predict_window"):
                    res = classifier.predict_window(window)
                    label, confidence = res.label, res.confidence
                    features = res.features
                    engine, deep_prob = res.engine, res.deep_prob
                    preictal_prob = res.preictal_prob
                    lead_time_min = res.lead_time_min
                    horizon_min = res.horizon_min
                    predicted = res.predicted
                    prediction_source = res.prediction_source
                else:  # pragma: no cover - legacy classifiers
                    features = extract_features(window)
                    label, confidence = classifier.predict(features)
                    engine, deep_prob = "features", None
                    preictal_prob = lead_time_min = horizon_min = None
                    predicted = prediction_source = None

                traj = self._trajectories[key]
                if preictal_prob is not None:
                    traj.append(round(float(preictal_prob), 4))
                trajectory = list(traj)

                status = DeviceStatus(
                    patient_id=patient_id,
                    device_id=device_id,
                    connected=True,
                    last_seen=self._meta[key]["last_seen"],
                    samples_buffered=len(buf),
                    last_label=label,
                    last_confidence=confidence,
                    last_window=window,
                    last_engine=engine,
                    last_deep_prob=deep_prob,
                    last_preictal_prob=preictal_prob,
                    last_lead_time_min=lead_time_min,
                    last_horizon_min=horizon_min,
                    last_predicted=predicted,
                    last_prediction_source=prediction_source,
                    preictal_trajectory=trajectory,
                )
                self._latest[key] = status
                result["assessment"] = {
                    "label": label,
                    "confidence": confidence,
                    "features": features.model_dump(),
                    "timestamp": window.timestamp,
                    "engine": engine,
                    "deep_prob": deep_prob,
                    "preictal_prob": preictal_prob,
                    "lead_time_min": lead_time_min,
                    "horizon_min": horizon_min,
                    "predicted": predicted,
                    "prediction_source": prediction_source,
                    "preictal_trajectory": trajectory,
                }
            else:
                prev = self._latest.get(key)
                self._latest[key] = DeviceStatus(
                    patient_id=patient_id,
                    device_id=device_id,
                    connected=True,
                    last_seen=self._meta[key]["last_seen"],
                    samples_buffered=len(buf),
                    last_label=prev.last_label if prev else None,
                    last_confidence=prev.last_confidence if prev else None,
                    last_window=prev.last_window if prev else None,
                    last_engine=prev.last_engine if prev else None,
                    last_deep_prob=prev.last_deep_prob if prev else None,
                    last_preictal_prob=prev.last_preictal_prob if prev else None,
                    last_lead_time_min=prev.last_lead_time_min if prev else None,
                    last_horizon_min=prev.last_horizon_min if prev else None,
                    last_predicted=prev.last_predicted if prev else None,
                    last_prediction_source=prev.last_prediction_source if prev else None,
                    preictal_trajectory=list(self._trajectories[key]),
                )
            return result

    def status(self, patient_id: str) -> DeviceStatus | None:
        with self._lock:
            return self._latest.get(patient_id)
