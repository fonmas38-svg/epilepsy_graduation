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
if (_MODELS_DIR / "cloud_preictal_model.pt").exists():
    DEFAULT_WEIGHTS = _MODELS_DIR / "cloud_preictal_model.pt"
    DEFAULT_META = _MODELS_DIR / "cloud_preictal_model.meta.json"
else:
    DEFAULT_WEIGHTS = _MODELS_DIR / "cnn_lstm_chbmit.pt"
    DEFAULT_META = _MODELS_DIR / "cnn_lstm_chbmit.meta.json"

# Fallbacks used only when the .meta.json is absent/corrupt.
_FALLBACK_META = {
    "arch": "CloudPreictalNet",
    "in_ch": 1,
    "n_classes": 2,
    "hidden_dim": 64,
    "num_heads": 4,
    "input_len": 262,
    "fs": 256,
    "decision_threshold": 0.60,
    "horizon_min": 30.0,
    "dataset": "chbmit",
    "task": "prediction(preictal_vs_interictal)",
}


def _build_cloud_preictal_net(torch, nn, in_ch: int = 1, n_classes: int = 2, hidden_dim: int = 64, num_heads: int = 4):
    """Deep Cloud Preictal Forecasting Engine: Multi-scale Conv1D + Self-Attention + BiLSTM."""
    class CloudPreictalNet(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.c1 = nn.Conv1d(in_ch, 24, kernel_size=3, padding=1)
            self.c2 = nn.Conv1d(in_ch, 24, kernel_size=5, padding=2)
            self.c3 = nn.Conv1d(in_ch, 24, kernel_size=7, padding=3)
            self.bn = nn.BatchNorm1d(72)
            self.relu = nn.ReLU()
            self.pool = nn.MaxPool1d(2)
            self.attn = nn.MultiheadAttention(embed_dim=72, num_heads=num_heads, batch_first=True)
            self.lstm = nn.LSTM(72, hidden_dim, batch_first=True, bidirectional=True)
            self.head = nn.Sequential(
                nn.Dropout(0.3),
                nn.Linear(hidden_dim * 2, 64),
                nn.ReLU(),
                nn.Dropout(0.3),
                nn.Linear(64, n_classes),
            )

        def forward(self, x):
            z = torch.cat([self.c1(x), self.c2(x), self.c3(x)], dim=1)
            z = self.pool(self.relu(self.bn(z)))
            z_t = z.transpose(1, 2)
            attn_out, _ = self.attn(z_t, z_t, z_t)
            lstm_out, _ = self.lstm(attn_out)
            pooled = lstm_out.mean(dim=1)
            return self.head(pooled)

    return CloudPreictalNet()


def _build_model(torch, nn, in_ch: int, n_classes: int, hidden: int):
    """Legacy research multichannel CNN1D_LSTM."""
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

        def forward(self, x):
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
        self.engine_name = "cloud_preictal_net"
        self._weights_name = DEFAULT_WEIGHTS.name

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
            self._weights_name = weights.name
            state = torch.load(weights, map_location="cpu")
            arch = self.meta.get("arch", "")
            if arch == "CloudPreictalNet" or "attn.in_proj_weight" in state:
                model = _build_cloud_preictal_net(
                    torch, nn,
                    in_ch=int(self.meta.get("in_ch", 1)),
                    n_classes=int(self.meta.get("n_classes", 2)),
                    hidden_dim=int(self.meta.get("hidden_dim", 64)),
                    num_heads=int(self.meta.get("num_heads", 4)),
                )
                self.engine_name = "cloud_preictal_net"
            else:
                model = _build_model(
                    torch, nn,
                    int(self.meta.get("in_ch", 16)), int(self.meta.get("n_classes", 2)), int(self.meta.get("hidden", 64)),
                )
                self.engine_name = "cnn_lstm_preictal"

            model.load_state_dict(state)
            model.eval()
            self._model = model
            self._loaded = True
            log.info("preictal_model: loaded %s (arch=%s, in_ch=%s, input_len=%s, thr=%s)",
                     weights.name, self.engine_name, self.meta.get("in_ch"),
                     self.meta.get("input_len"), self.meta.get("decision_threshold"))
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
            "engine": getattr(self, "engine_name", "cloud_preictal_net"),
            "available": self.available,
            "error": self.error,
            "weights": getattr(self, "_weights_name", DEFAULT_WEIGHTS.name),
            "meta": self.meta,
        }
