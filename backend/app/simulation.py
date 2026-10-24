"""Synthetic vital-sign windows for V1 (no real sensors)."""
from __future__ import annotations

from datetime import datetime, timezone

import numpy as np

from app.schemas import RiskLabel, VitalWindow


def generate_window(
    pattern: RiskLabel = "stable",
    samples: int = 262,
    seed: int | None = None,
    patient_id: str | None = None,
) -> VitalWindow:
    if pattern not in ("stable", "watch", "high_risk"):
        raise ValueError("Unknown simulation pattern")
    if not 32 <= samples <= 1024:
        raise ValueError("Simulation window must contain 32..1024 samples")
    rng = np.random.default_rng(seed)
    t = np.arange(samples) / 256.0 * 2 * np.pi

    if pattern == "stable":
        eeg = 0.4 * np.sin(8 * t) + 0.1 * rng.normal(size=samples)
        ecg = 0.8 * np.sin(5 * t) + 0.05 * rng.normal(size=samples)
        motion = 0.15 * rng.normal(size=samples)
        hr = float(rng.normal(72, 3))
    elif pattern == "watch":
        eeg = 0.7 * np.sin(12 * t) + 0.25 * rng.normal(size=samples)
        ecg = 0.9 * np.sin(6.5 * t) + 0.12 * rng.normal(size=samples)
        motion = 0.45 * np.sin(3 * t) + 0.2 * rng.normal(size=samples)
        hr = float(rng.normal(95, 6))
    else:  # high_risk
        bursts = (np.sin(25 * t) > 0.6).astype(float)
        eeg = 1.4 * np.sin(20 * t) + 0.8 * bursts + 0.35 * rng.normal(size=samples)
        ecg = 1.1 * np.sin(8 * t) + 0.3 * rng.normal(size=samples)
        motion = 1.2 * np.abs(np.sin(10 * t)) + 0.5 * rng.normal(size=samples)
        hr = float(rng.normal(125, 10))

    return VitalWindow(
        timestamp=datetime.now(timezone.utc).isoformat(),
        eeg=eeg.astype(float).tolist(),
        ecg=ecg.astype(float).tolist(),
        motion=motion.astype(float).tolist(),
        hr=hr,
        patient_id=patient_id,
    )
