"""Signal preprocessing: denoise, normalize, feature extraction."""
from __future__ import annotations

import numpy as np

from app.schemas import FeatureVector, VitalWindow


def _moving_average(signal: np.ndarray, window: int = 5) -> np.ndarray:
    if len(signal) < window:
        return signal.copy()
    kernel = np.ones(window) / window
    return np.convolve(signal, kernel, mode="same")


def denoise(signal: list[float] | np.ndarray) -> np.ndarray:
    arr = np.asarray(signal, dtype=float)
    return _moving_average(arr, window=5)


def normalize(signal: np.ndarray) -> np.ndarray:
    std = float(np.std(signal))
    if std < 1e-8:
        return signal - np.mean(signal)
    return (signal - np.mean(signal)) / std


def estimate_hr_from_ecg(ecg: np.ndarray, fs: float = 64.0) -> tuple[float, float]:
    """Rough peak-based HR estimate (bpm) and RR std proxy."""
    x = normalize(denoise(ecg))
    threshold = 0.5 * float(np.max(x)) if np.max(x) > 0 else 0.5
    peaks = []
    for i in range(1, len(x) - 1):
        if x[i] > threshold and x[i] >= x[i - 1] and x[i] >= x[i + 1]:
            if not peaks or (i - peaks[-1]) > int(0.25 * fs):
                peaks.append(i)
    if len(peaks) < 2:
        mean_hr = 72.0
        return mean_hr, 5.0
    rr = np.diff(peaks) / fs
    hr_series = 60.0 / np.clip(rr, 0.3, 2.0)
    return float(np.mean(hr_series)), float(np.std(hr_series))


def extract_features(window: VitalWindow, *, unit_variance: bool = True) -> FeatureVector:
    """Keep the legacy sklearn contract by default; preserve amplitude for rules.

    Unit variance makes power/variance identically one for nonconstant signals.
    Rule thresholds must therefore use unit_variance=False. Neural engines retain
    their own training-time preprocessing, independent of these context features.
    """
    transform = normalize if unit_variance else lambda signal: signal
    eeg = transform(denoise(window.eeg))
    ecg = transform(denoise(window.ecg))
    motion = transform(denoise(window.motion))

    hr_mean, hr_std = estimate_hr_from_ecg(ecg)
    if window.hr is not None:
        hr_mean = float(window.hr)

    eeg_power = float(np.mean(eeg**2))
    eeg_peak = float(np.max(np.abs(eeg)))
    motion_energy = float(np.mean(motion**2))
    motion_variance = float(np.var(motion))
    ecg_variability = float(np.std(ecg))

    return FeatureVector(
        hr_mean=hr_mean,
        hr_std=hr_std,
        eeg_power=eeg_power,
        eeg_peak=eeg_peak,
        motion_energy=motion_energy,
        motion_variance=motion_variance,
        ecg_variability=ecg_variability,
    )


def features_to_array(features: FeatureVector) -> np.ndarray:
    return np.array(
        [
            features.hr_mean,
            features.hr_std,
            features.eeg_power,
            features.eeg_peak,
            features.motion_energy,
            features.motion_variance,
            features.ecg_variability,
        ],
        dtype=float,
    )
