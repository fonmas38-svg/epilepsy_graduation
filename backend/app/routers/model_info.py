"""Model introspection + real-EEG (Bonn) streaming.

Two purposes:
  * GET /model/info  — expose which inference engine is active and the deep
    model's status/metrics, so the app (and the defense) can show it honestly.
  * POST /dataset/bonn/next — stream a REAL Bonn EEG window through the deep
    CNN-LSTM. Unlike the synthetic /dataset/next, these windows are in-domain,
    so the deep model's discrimination is meaningful here. Includes the ground
    truth so the UI can display correctness.
"""
from __future__ import annotations

import json
import logging
from pathlib import Path
from threading import Lock

import numpy as np
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel

from app import cloud_store
from app.device_hub import DeviceSample
from app.schemas import VitalWindow
from app.auth import authorize_patient_access, get_optional_principal

log = logging.getLogger("epilepsy.model_info")
router = APIRouter(tags=["model"])

BONN_H5 = Path(__file__).resolve().parents[2] / "data" / "bonn.h5"

# Clinical-metrics JSONs emitted by research/scripts/train.py. Optional: absent
# files degrade to {"available": false} rather than erroring, so the endpoint is
# safe before any offline training has been run.
_RESULTS_DIR = Path(__file__).resolve().parents[3] / "research" / "results"
_METRICS_FILES = {
    # headline: the seizure-PREDICTION model (preictal vs interictal, CHB-MIT)
    "preictal_chbmit": _RESULTS_DIR / "metrics_chbmit.json",
    # secondary: the seizure-DETECTION model (ictal vs non-ictal, Bonn)
    "detection_bonn": _RESULTS_DIR / "metrics_bonn.json",
}

_bonn_lock = Lock()
_bonn_cache: dict | None = None
_bonn_cursor: dict[str, int] = {}


def _load_bonn() -> dict | None:
    """Lazy-load the real Bonn windows once. Returns None if unavailable."""
    global _bonn_cache
    if _bonn_cache is not None:
        return _bonn_cache
    with _bonn_lock:
        if _bonn_cache is not None:
            return _bonn_cache
        if not BONN_H5.exists():
            return None
        try:
            import h5py

            with h5py.File(BONN_H5, "r") as f:
                X = f["X"][:].astype(np.float32)   # (N, 1, L)
                y = f["y"][:].astype(int)
                fs = int(f.attrs.get("fs", 256))
            _bonn_cache = {"X": X, "y": y, "fs": fs,
                           "pos": np.where(y == 1)[0], "neg": np.where(y == 0)[0]}
            log.info("bonn stream: loaded %s windows (fs=%s)", X.shape, fs)
            return _bonn_cache
        except Exception as e:  # noqa: BLE001
            log.warning("bonn stream: load failed (%s)", e)
            return None


@router.get("/model/info")
def model_info(request: Request):
    clf = request.app.state.classifier
    info = clf.engine_info()
    info["bonn_stream_available"] = _load_bonn() is not None
    return info


def _read_metrics(path: Path) -> dict:
    """Load one clinical-metrics JSON, degrading to available:false if absent."""
    if not path.exists():
        return {"available": False, "reason": f"{path.name} not found"}
    try:
        return {"available": True, "metrics": json.loads(path.read_text())}
    except Exception as e:  # noqa: BLE001
        return {"available": False, "reason": f"unreadable: {e}"}


@router.get("/model/metrics")
def model_metrics(request: Request):
    """Prediction/detection clinical metrics (sensitivity, specificity, FPR/hour).

    Additive, optional (#20): surfaces the offline-trained models' per-window
    metrics so the doctor screen can show them honestly. The preictal (CHB-MIT)
    block is the headline for the PREDICTION story; the Bonn block is the existing
    detection model. Missing files degrade to ``available:false`` — never a 404 —
    so this is safe to call before any training has been run."""
    reports = {key: _read_metrics(path) for key, path in _METRICS_FILES.items()}
    preictal_engine = request.app.state.classifier.engine_info().get("preictal", {})
    return {
        # which live engine currently backs the forecast (real model vs heuristic)
        "prediction_engine_available": bool(preictal_engine.get("available")),
        "reports": reports,
        "note": ("Per-window metrics from offline training (research/scripts/train.py). "
                 "For CHB-MIT, FPR/hour is a real alarm rate over continuous interictal "
                 "data; sensitivity is reported at the clinically-tuned threshold."),
    }


class BonnNextRequest(BaseModel):
    patient_id: str = "patient-demo"
    prefer_label: str | None = None  # "ictal" | "nonictal" | None (sequential)
    push_to_device_hub: bool = True


@router.post("/dataset/bonn/next")
def bonn_next(
    body: BonnNextRequest,
    request: Request,
    principal: dict = Depends(get_optional_principal),
):
    """Fetch the next REAL Bonn EEG window, classify with the deep model, publish."""
    authorize_patient_access(body.patient_id, principal)
    data = _load_bonn()
    if data is None:
        raise HTTPException(503, "Bonn dataset not available on server (data/bonn.h5 missing)")

    X, y = data["X"], data["y"]
    if body.prefer_label in ("ictal", "nonictal"):
        pool = data["pos"] if body.prefer_label == "ictal" else data["neg"]
        # deterministic-free choice without global RNG state
        cur = _bonn_cursor.get(f"{body.patient_id}:{body.prefer_label}", 0)
        _bonn_cursor[f"{body.patient_id}:{body.prefer_label}"] = cur + 1
        idx = int(pool[cur % len(pool)])
    else:
        cur = _bonn_cursor.get(body.patient_id, 0)
        _bonn_cursor[body.patient_id] = cur + 1
        idx = cur % len(X)

    eeg = X[idx, 0, :].astype(float).tolist()
    truth = "ictal" if int(y[idx]) == 1 else "nonictal"

    # Bonn is single-channel EEG; fill ECG/motion neutral so the multimodal
    # fusion leans on the deep EEG probability (which is the whole point here).
    window = VitalWindow(eeg=eeg, ecg=[0.0] * len(eeg), motion=[0.0] * len(eeg),
                         hr=70.0, patient_id=body.patient_id)
    result = request.app.state.classifier.predict_window(window)

    if body.push_to_device_hub:
        samples = [DeviceSample(eeg=eeg[i], ecg=0.0, motion=0.0, hr=70.0)
                   for i in range(len(eeg))]
        request.app.state.device_hub.ingest(
            body.patient_id, "bonn-eeg-player", samples, request.app.state.classifier)

    assessment = {
        "label": result.label, "confidence": result.confidence,
        "features": result.features.model_dump(), "timestamp": window.timestamp,
        "engine": result.engine, "deep_prob": result.deep_prob,
        "components": result.components, "mode": "bonn-real-eeg",
    }
    cloud_store.add_reading(body.patient_id, {
        "timestamp": window.timestamp, "eeg": eeg, "ecg": window.ecg,
        "motion": window.motion, "hr": 70.0, "source": "bonn"})
    cloud_store.add_assessment(body.patient_id, assessment)

    return {
        "window": window.model_dump(),
        "assessment": assessment,
        "truth_label": truth,
        "deep_correct": (result.deep_prob is not None
                         and ((result.deep_prob >= 0.5) == (truth == "ictal"))),
    }
