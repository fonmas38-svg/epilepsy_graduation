"""
Deep seizure model — production bridge for the research CNN-1D + LSTM.

This wires the PyTorch model trained in `research/scripts/train.py`
(`CNN1D_LSTM`, single-channel EEG, ictal-vs-non-ictal detection) into the live
API. It loads the saved `state_dict`, reproduces the *exact* architecture, and
applies the same signal contract the model was trained on before inference:

    EEG at the expected length -> band-pass 0.5-40 Hz -> per-window z-score
    -> Conv1D stack -> BiLSTM -> uncalibrated ictal score

Design decisions (deliberate, documented for the defense):
  * The model is loaded lazily and behind a lock; a failed/absent model or a
    missing torch install degrades gracefully (``available == False``) so the
    API never crashes — the caller falls back to the sklearn/rule engine.
  * The research model is single-channel (EEG). The live window carries EEG,
    ECG and Motion; only EEG is fed to the CNN-LSTM. The multimodal context
    (tachycardia, motion bursts) is fused on top by ``RiskClassifier``.
  * The input length must match the training length. Without a documented input
    sample rate, stretching an arbitrary window changes its frequencies and is
    not a valid conversion. Mismatches return no neural score.

CAVEAT for real clinical use: the Bonn model expects Bonn-domain EEG. Feeding
it signals from a different acquisition setup requires domain adaptation /
re-training. The wiring here is correct; the weights are only as good as their
training data. This is stated plainly rather than hidden.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path
from threading import Lock

import numpy as np

log = logging.getLogger("epilepsy.deep_model")

_MODELS_DIR = Path(__file__).resolve().parents[2] / "models"
DEFAULT_WEIGHTS = _MODELS_DIR / "cnn_lstm_bonn.pt"
DEFAULT_META = _MODELS_DIR / "cnn_lstm_bonn.meta.json"

# Fallbacks used only when the .meta.json is absent.
_FALLBACK_META = {
    "in_ch": 1,
    "n_classes": 2,
    "hidden": 64,
    "input_len": 262,
    "fs": 256,
    "decision_threshold": 0.5,
    "watch_threshold": 0.35,
    "dataset": "bonn",
    "task": "detection(ictal_vs_nonictal)",
}


def _build_model(torch, nn, in_ch: int, n_classes: int, hidden: int):
    """Re-declaration of research/scripts/train.py::CNN1D_LSTM (must match keys)."""

    class CNN1D_LSTM(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.features = nn.Sequential(
                nn.Conv1d(in_ch, 32, 7, padding=3), nn.BatchNorm1d(32), nn.ReLU(),
                nn.MaxPool1d(2),
                nn.Conv1d(32, 64, 5, padding=2), nn.BatchNorm1d(64), nn.ReLU(),
                nn.MaxPool1d(2),
                nn.Conv1d(64, 64, 3, padding=1), nn.BatchNorm1d(64), nn.ReLU(),
                nn.MaxPool1d(2),
            )
            self.lstm = nn.LSTM(64, hidden, batch_first=True, bidirectional=True)
            self.head = nn.Sequential(
                nn.Dropout(0.3), nn.Linear(hidden * 2, 64), nn.ReLU(),
                nn.Dropout(0.3), nn.Linear(64, n_classes),
            )

        def forward(self, x):                 # x: (B, C, L)
            z = self.features(x)
            z = z.transpose(1, 2)
            out, _ = self.lstm(z)
            z = out.mean(dim=1)
            return self.head(z)

    return CNN1D_LSTM()


class DeepSeizureModel:
    """Thread-safe, lazily-loaded inference wrapper. Never raises on load failure."""

    def __init__(self) -> None:
        self._model = None
        self._torch = None
        self._lock = Lock()
        self._loaded = False
        self.error: str | None = None
        self.meta: dict = dict(_FALLBACK_META)

    # ------------------------------------------------------------------ load
    @classmethod
    def load(cls, weights: Path | None = None, meta: Path | None = None) -> "DeepSeizureModel":
        inst = cls()
        inst._try_load(weights or DEFAULT_WEIGHTS, meta or DEFAULT_META)
        return inst

    def _try_load(self, weights: Path, meta: Path) -> None:
        if meta.exists():
            try:
                self.meta = {**_FALLBACK_META, **json.loads(meta.read_text())}
            except Exception as e:  # noqa: BLE001
                log.warning("deep_model: bad meta json (%s); using defaults", e)
        if not weights.exists():
            self.error = f"weights not found: {weights.name}"
            log.info("deep_model: %s -> deep engine disabled", self.error)
            return
        try:
            import torch
            import torch.nn as nn

            self._torch = torch
            model = _build_model(
                torch, nn,
                int(self.meta["in_ch"]), int(self.meta["n_classes"]), int(self.meta["hidden"]),
            )
            state = torch.load(weights, map_location="cpu")
            model.load_state_dict(state)
            model.eval()
            self._model = model
            self._loaded = True
            log.info("deep_model: loaded %s (input_len=%s, thr=%s)",
                     weights.name, self.meta["input_len"], self.meta["decision_threshold"])
        except Exception as e:  # noqa: BLE001
            self.error = f"load failed: {e}"
            log.warning("deep_model: %s -> deep engine disabled", self.error)

    @property
    def available(self) -> bool:
        return self._loaded and self._model is not None

    # -------------------------------------------------------------- inference
    def _preprocess(self, eeg: list[float] | np.ndarray) -> np.ndarray:
        """EEG -> (1, 1, input_len) float32, matching the training contract."""
        x = np.asarray(eeg, dtype=np.float64).ravel()
        if x.size < 8:
            x = np.pad(x, (0, 8 - x.size))
        target_len = int(self.meta["input_len"])
        fs = float(self.meta["fs"])

        # Do not change signal duration to fit a model tensor.
        if x.size != target_len:
            raise ValueError("EEG window length does not match training; implicit time stretching is unsafe")
        if not np.isfinite(x).all() or np.ptp(x) <= 1e-8:
            raise ValueError("Unusable EEG signal")

        # band-pass 0.5-40 Hz to match harmonize.clean_signal (best-effort; the
        # model tolerates already-filtered input since z-score follows).
        try:
            from scipy import signal as sp

            high = min(40.0, fs / 2.0 - 1.0)
            sos = sp.butter(4, [0.5, high], btype="bandpass", fs=fs, output="sos")
            x = sp.sosfiltfilt(sos, x)
        except Exception:  # noqa: BLE001 - filtering is best-effort
            pass

        # per-window z-score (Bonn prep normalizes each segment)
        x = (x - x.mean()) / (x.std() + 1e-8)
        return x.astype(np.float32).reshape(1, 1, -1)

    def predict_proba(self, eeg: list[float] | np.ndarray) -> float | None:
        """Return P(ictal) in [0,1], or None if the deep engine is unavailable."""
        if not self.available:
            return None
        torch = self._torch
        with self._lock:
            try:
                xb = torch.from_numpy(self._preprocess(eeg))
                with torch.no_grad():
                    logits = self._model(xb)
                    prob = torch.softmax(logits, dim=1)[0, 1].item()
                return float(prob) if np.isfinite(prob) and 0 <= prob <= 1 else None
            except Exception as e:  # noqa: BLE001
                log.warning("deep_model: inference failed (%s)", e)
                return None

    def info(self) -> dict:
        return {
            "engine": "cnn_lstm",
            "available": self.available,
            "error": self.error,
            "weights": DEFAULT_WEIGHTS.name,
            "meta": self.meta,
        }
