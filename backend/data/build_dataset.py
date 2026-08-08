"""
Generate a realistic offline EEG-like dataset for graduation MVP
when the physical device is not available yet.

Labels:
  0 = interictal / stable
  1 = preictal / watch   (rising risk — soft prediction)
  2 = ictal / high_risk  (seizure-like activity)
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "epilepsy_signal_dataset.csv"
SAMPLES = 128


def _window(kind: str, rng: np.random.Generator, n: int = SAMPLES) -> np.ndarray:
    t = np.linspace(0, 2 * np.pi, n)
    if kind == "stable":
        eeg = 0.35 * np.sin(8 * t) + 0.12 * np.sin(13 * t) + 0.08 * rng.normal(size=n)
        ecg = 0.75 * np.sin(5 * t) + 0.05 * rng.normal(size=n)
        motion = 0.12 * rng.normal(size=n)
        hr = rng.normal(72, 4)
    elif kind == "watch":
        # pre-ictal style: rising high-frequency energy
        eeg = 0.55 * np.sin(14 * t) + 0.35 * np.sin(22 * t) + 0.2 * rng.normal(size=n)
        ecg = 0.85 * np.sin(6.2 * t) + 0.1 * rng.normal(size=n)
        motion = 0.35 * np.sin(2.5 * t) + 0.18 * rng.normal(size=n)
        hr = rng.normal(96, 7)
    else:
        spikes = (np.sin(28 * t) > 0.55).astype(float)
        eeg = 1.35 * np.sin(20 * t) + 0.9 * spikes + 0.35 * rng.normal(size=n)
        ecg = 1.05 * np.sin(8 * t) + 0.25 * rng.normal(size=n)
        motion = 1.1 * np.abs(np.sin(11 * t)) + 0.45 * rng.normal(size=n)
        hr = rng.normal(128, 10)
    return eeg, ecg, motion, float(hr)


def build(n_per_class: int = 800, seed: int = 42) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    rows = []
    mapping = {"stable": 0, "watch": 1, "high_risk": 2}
    for kind, label in mapping.items():
        for i in range(n_per_class):
            eeg, ecg, motion, hr = _window(kind, rng)
            row = {
                "label": label,
                "label_name": kind,
                "hr": hr,
            }
            for j in range(SAMPLES):
                row[f"eeg_{j}"] = eeg[j]
                row[f"ecg_{j}"] = ecg[j]
                row[f"motion_{j}"] = motion[j]
            rows.append(row)
    df = pd.DataFrame(rows).sample(frac=1, random_state=seed).reset_index(drop=True)
    return df


def main():
    OUT.parent.mkdir(parents=True, exist_ok=True)
    df = build()
    df.to_csv(OUT, index=False)
    print(f"saved {OUT} shape={df.shape}")
    print(df["label_name"].value_counts().to_string())


if __name__ == "__main__":
    main()
