"""
Preictal model — optional real CNN-LSTM seizure-PREDICTION engine (CHB-MIT).

This is the Phase-3 thesis artifact: a MULTICHANNEL CNN-1D + LSTM trained by
``research/scripts/train.py`` on one CHB-MIT subject to discriminate PREICTAL
(a seizure approaching within the prediction horizon) from INTERICTAL (baseline).
It is wired as a SEPARATE, OPTIONAL engine alongside the Bonn detection model
(``deep_model.py``); it never replaces it, and the live simulated-trajectory demo
never depends on it.

Design (deliberate, mirrors ``DeepSeizureModel`` so the two read the same for the
defense):
  * Loaded lazily behind a lock. Absent weights / missing torch / bad meta all
    degrade gracefully (``available == False``) so the API never crashes — the
    caller (``RiskClassifier._attach_prediction``) then falls back to the
    transparent preictal heuristic that drives the live simulated trajectory.
  * The research preictal model is MULTICHANNEL (CHB-MIT scalp montage,
    ``in_ch > 1``). A live ``VitalWindow`` carries a single EEG channel, so
    ``predict_proba(window)`` HONESTLY returns ``None`` whenever the available
    channel count does not match the trained ``in_ch``. That is the whole point
    of the hybrid design: the real model still loads and reports its clinical
    metrics (the thesis evidence) and can be exercised offline on genuine
    multichannel windows via ``predict_proba_matrix`` — but it does not silently
    fabricate a montage from one channel to prop up the demo.
  * Same signal contract as training (``harmonize.clean_signal`` +
    ``SubjectNormalizer``): best-effort band-pass, resample to ``input_len``,
    per-channel z-score.

Do NOT confuse this with ``deep_model.py`` (single-channel Bonn DETECTION). They
are separate engines by design; this file must never edit or import that one.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path
from threading import Lock

import numpy as np

log = logging.getLogger("epilepsy.preictal_model")

_MODELS_DIR = Path(__file__).resolve().parents[2] / "models"
DEFAULT_WEIGHTS = _MODELS_DIR / "cnn_lstm_chbmit.pt"
DEFAULT_META = _MODELS_DIR / "cnn_lstm_chbmit.meta.json"

# Fallbacks used only when the .meta.json is absent/corrupt. The real values come
# from the hand-authored meta (reconciled with train.py's printed ``in_ch`` and
# the window_sec*fs input length) when the Phase-3 weights are produced.
_FALLBACK_META = {
    "in_ch": 16,
    "n_classes": 2,
    "hidden": 64,
    "input_len": 1280,      # window_sec (5.0) * fs (256)
    "fs": 256,
    "decision_threshold": 0.5,
    "dataset": "chbmit",
    "task": "prediction(preictal_vs_interictal)",
}


def _build_model(torch, nn, in_ch: int, n_classes: int, hidden: int):
    """Re-declaration of research/scripts/train.py::CNN1D_LSTM (must match keys).

    Identical architecture to ``deep_model._build_model`` — only ``in_ch`` differs
    (multichannel here). Kept as a separate copy so this engine never imports the
    detection engine and the two evolve independently.
    """

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


class PreictalModel:
    """Thread-safe, lazily-loaded preictal inference wrapper.

    Never raises on load or inference failure — the classifier treats a ``None``
    probability as "use the heuristic", so every failure path just yields ``None``.
    """

    def __init__(self) -> None:
        self._model = None
        self._torch = None
        self._lock = Lock()
        self._loaded = False
        self.error: str | None = None
        self.meta: dict = dict(_FALLBACK_META)

    # ------------------------------------------------------------------ load
    @classmethod
    def load(cls, weights: Path | None = None, meta: Path | None = None) -> "PreictalModel":
        inst = cls()
        inst._try_load(weights or DEFAULT_WEIGHTS, meta or DEFAULT_META)
        return inst

    def _try_load(self, weights: Path, meta: Path) -> None:
        if meta.exists():
            try:
                self.meta = {**_FALLBACK_META, **json.loads(meta.read_text())}
            except Exception as e:  # noqa: BLE001
                log.warning("preictal_model: bad meta json (%s); using defaults", e)
        if not weights.exists():
            self.error = f"weights not found: {weights.name}"
            log.info("preictal_model: %s -> preictal engine disabled (heuristic in use)",
                     self.error)
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
            log.info("preictal_model: loaded %s (in_ch=%s, input_len=%s, thr=%s)",
                     weights.name, self.meta["in_ch"], self.meta["input_len"],
                     self.meta["decision_threshold"])
        except Exception as e:  # noqa: BLE001
            self.error = f"load failed: {e}"
            log.warning("preictal_model: %s -> preictal engine disabled", self.error)

    @property
    def available(self) -> bool:
        return self._loaded and self._model is not None

    # -------------------------------------------------------------- inference
    def _to_matrix(self, source) -> np.ndarray | None:
        """Coerce a VitalWindow / array into a (C, L) float matrix.

        A live ``VitalWindow`` exposes a single EEG channel (``window.eeg``), so
        it yields a (1, L) matrix. A raw 2-D array is treated as (C, L) directly
        (the offline multichannel path). Returns ``None`` if nothing usable."""
        eeg = getattr(source, "eeg", None)
        if eeg is not None:
            arr = np.asarray(eeg, dtype=np.float64)
        else:
            arr = np.asarray(source, dtype=np.float64)
        if arr.size == 0:
            return None
        if arr.ndim == 1:
            arr = arr[None, :]
        elif arr.ndim > 2:
            arr = arr.reshape(arr.shape[0], -1)
        return arr

    def _preprocess(self, mat: np.ndarray) -> np.ndarray:
        """(C, L) -> (1, C, input_len) float32, matching the training contract."""
        x = np.asarray(mat, dtype=np.float64)
        target_len = int(self.meta["input_len"])
        fs = float(self.meta["fs"])

        # resample the time axis to the training length (channels preserved)
        if x.shape[-1] != target_len:
            from scipy import signal as sp

            x = sp.resample(x, target_len, axis=-1)

        # band-pass 0.5-40 Hz to mirror harmonize.clean_signal (best-effort; the
        # per-channel z-score below makes the model tolerant of already-filtered
        # input).
        try:
            from scipy import signal as sp

            high = min(40.0, fs / 2.0 - 1.0)
            sos = sp.butter(4, [0.5, high], btype="bandpass", fs=fs, output="sos")
            x = sp.sosfiltfilt(sos, x, axis=-1)
        except Exception:  # noqa: BLE001 - filtering is best-effort
            pass

        # per-channel z-score (inference-time stand-in for the per-subject
        # normalizer used in edf_prep, which cannot be reconstructed live).
        mu = x.mean(axis=-1, keepdims=True)
        sd = x.std(axis=-1, keepdims=True) + 1e-8
        x = (x - mu) / sd
        return x.astype(np.float32)[None, :, :]

    def _infer(self, mat: np.ndarray) -> float | None:
        """Run the model on an already channel-checked (C, L) matrix."""
        torch = self._torch
        with self._lock:
            try:
                xb = torch.from_numpy(self._preprocess(mat))
                with torch.no_grad():
                    logits = self._model(xb)
                    prob = torch.softmax(logits, dim=1)[0, 1].item()
                return float(prob)
            except Exception as e:  # noqa: BLE001
                log.warning("preictal_model: inference failed (%s)", e)
                return None

    def predict_proba(self, window) -> float | None:
        """Return P(preictal) in [0,1] for a live analysis window, or ``None``.

        ``None`` is returned — deliberately — whenever the engine is unavailable
        OR the window's channel count does not match the trained ``in_ch``. A live
        ``VitalWindow`` is single-channel, so a multichannel CHB-MIT model returns
        ``None`` here and the transparent heuristic drives the forecast. This never
        fabricates missing montage channels to force a real-model number in the
        live demo."""
        if not self.available:
            return None
        mat = self._to_matrix(window)
        if mat is None:
            return None
        expected = int(self.meta["in_ch"])
        if mat.shape[0] != expected:
            # Honest degrade: we will not run a montage model on the wrong number
            # of channels. Single-channel live window vs. multichannel model -> None.
            return None
        return self._infer(mat)

    def predict_proba_matrix(self, matrix) -> float | None:
        """Offline path: score a genuine multichannel (C, L) preictal window.

        For a future CHB-MIT streaming route (analogous to the Bonn player) that
        can supply a real ``in_ch``-channel montage. Same channel guard applies."""
        if not self.available:
            return None
        mat = self._to_matrix(matrix)
        if mat is None or mat.shape[0] != int(self.meta["in_ch"]):
            return None
        return self._infer(mat)

    def info(self) -> dict:
        return {
            "engine": "cnn_lstm_preictal",
            "available": self.available,
            "error": self.error,
            "weights": DEFAULT_WEIGHTS.name,
            "meta": self.meta,
        }
