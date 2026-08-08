"""
Shared signal-harmonization primitives (scipy-based, no MNE dependency so it can
run anywhere). Both the Bonn CSV path and the EDF path call into these so every
dataset ends up on the SAME contract:

    resample -> band-pass 0.5-40 Hz -> notch -> artifact mask -> per-subject z-score

Windowing (preictal/interictal) lives in windows.py; this file is pure DSP.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
from scipy import signal

TARGET_FS = 256  # Hz, harmonization target


@dataclass
class HarmonizeConfig:
    target_fs: int = TARGET_FS
    bp_low: float = 0.5
    bp_high: float = 40.0
    notch_freq: float = 50.0  # 50 EU / 60 US -- set per acquisition site
    notch_q: float = 30.0
    clip_uv: float = 500.0  # reject windows exceeding this abs amplitude (uV)
    flat_eps: float = 1e-6  # reject near-flat channels


def resample_to(x: np.ndarray, fs_in: float, fs_out: int) -> np.ndarray:
    """Resample along the last axis. x shape: (channels, samples)."""
    if int(fs_in) == int(fs_out):
        return x.astype(np.float64, copy=False)
    n_out = int(round(x.shape[-1] * fs_out / fs_in))
    return signal.resample(x, n_out, axis=-1)


def bandpass(x: np.ndarray, fs: int, low: float, high: float) -> np.ndarray:
    high = min(high, fs / 2.0 - 1.0)  # keep below Nyquist
    sos = signal.butter(4, [low, high], btype="bandpass", fs=fs, output="sos")
    return signal.sosfiltfilt(sos, x, axis=-1)


def notch(x: np.ndarray, fs: int, freq: float, q: float) -> np.ndarray:
    if freq <= 0 or freq >= fs / 2.0:
        return x
    b, a = signal.iirnotch(freq, q, fs=fs)
    return signal.filtfilt(b, a, x, axis=-1)


def clean_signal(x: np.ndarray, fs_in: float, cfg: HarmonizeConfig) -> np.ndarray:
    """Full per-recording clean-up: resample + filters. Returns (ch, samples) @ target_fs."""
    x = np.atleast_2d(np.asarray(x, dtype=np.float64))
    x = resample_to(x, fs_in, cfg.target_fs)
    x = bandpass(x, cfg.target_fs, cfg.bp_low, cfg.bp_high)
    x = notch(x, cfg.target_fs, cfg.notch_freq, cfg.notch_q)
    return x


def window_is_artifact(win: np.ndarray, cfg: HarmonizeConfig) -> bool:
    """True if a window should be dropped (saturation or flatline)."""
    if np.max(np.abs(win)) > cfg.clip_uv:
        return True
    if np.any(np.std(win, axis=-1) < cfg.flat_eps):
        return True
    if not np.all(np.isfinite(win)):
        return True
    return False


@dataclass
class SubjectNormalizer:
    """Per-subject z-score. Fit on interictal data only, apply to all windows."""

    mean: np.ndarray = field(default=None)  # type: ignore[assignment]
    std: np.ndarray = field(default=None)  # type: ignore[assignment]

    def fit(self, x: np.ndarray) -> "SubjectNormalizer":
        # x: (channels, samples) concatenated interictal signal
        self.mean = x.mean(axis=-1, keepdims=True)
        self.std = x.std(axis=-1, keepdims=True) + 1e-8
        return self

    def apply(self, win: np.ndarray) -> np.ndarray:
        if self.mean is None:
            m = win.mean(axis=-1, keepdims=True)
            s = win.std(axis=-1, keepdims=True) + 1e-8
            return (win - m) / s
        return (win - self.mean) / self.std
