"""Risk classifier: multi-engine with graceful degradation.

Decision engines, in priority order:
  1. cnn_lstm  — the research deep model (single-channel EEG) fused with the
                 multimodal context score (HR / motion / ECG). Primary when
                 the PyTorch weights load.
  2. sklearn   — the compact model in models/risk_model.joblib (7 features).
  3. rules     — a transparent additive heuristic. Always available.

The public entry point is ``predict_window(window)`` which returns a rich
``RiskResult`` (label, confidence, features, engine, deep_prob). ``predict``
is kept as a thin feature-only wrapper for backward compatibility.
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from app.ml.deep_model import DeepSeizureModel
from app.preprocessing import extract_features, features_to_array
from app.schemas import FeatureVector, RiskLabel, VitalWindow

log = logging.getLogger("epilepsy.classifier")

LABELS: list[RiskLabel] = ["stable", "watch", "high_risk"]
_SEVERITY = {"stable": 0, "watch": 1, "high_risk": 2}
MODEL_PATH = Path(__file__).resolve().parents[2] / "models" / "risk_model.joblib"

USE_DEEP = os.getenv("USE_DEEP_MODEL", "1") == "1"
# Fusion weight given to the deep EEG probability vs. the multimodal score.
DEEP_WEIGHT = float(os.getenv("DEEP_FUSION_WEIGHT", "0.7"))
HIGH_THR = float(os.getenv("RISK_HIGH_THRESHOLD", "0.5"))
WATCH_THR = float(os.getenv("RISK_WATCH_THRESHOLD", "0.3"))

# --- Prediction layer (forecasting a seizure ahead, preictal-vs-interictal).
# Kept separate from the detection thresholds above so the pivot is additive.
USE_PREICTAL = os.getenv("USE_PREICTAL_MODEL", "1") == "1"
# Seizure-prediction-horizon (minutes): how far ahead a full-confidence preictal
# reading forecasts onset. The estimated lead-time counts down from here.
HORIZON_MIN = float(os.getenv("PREICTAL_HORIZON_MIN", "15"))
# Preictal probability at/above which we raise an early pre-alert.
PREICTAL_PREALERT_THR = float(os.getenv("PREICTAL_PREALERT_THRESHOLD", "0.6"))


def _ramp(x: float, lo: float, hi: float) -> float:
    """Clamped linear ramp: 0 below ``lo``, 1 at/above ``hi``, linear between.

    Used to turn each physiological feature into a smooth [0,1] contribution so
    the forecast probability rises continuously as a seizure approaches."""
    if hi <= lo:
        return 1.0 if x >= hi else 0.0
    return float(min(max((x - lo) / (hi - lo), 0.0), 1.0))


@dataclass
class RiskResult:
    label: RiskLabel
    confidence: float
    features: FeatureVector
    engine: str
    deep_prob: float | None = None
    components: dict = field(default_factory=dict)
    # --- Prediction layer (additive, optional). Populated beside the detection
    # label; never changes label/confidence semantics.
    preictal_prob: float | None = None
    lead_time_min: float | None = None
    horizon_min: float | None = None
    predicted: bool | None = None
    prediction_source: str | None = None

    def as_tuple(self) -> tuple[RiskLabel, float]:
        return self.label, self.confidence


class RiskClassifier:
    def __init__(self, model=None, high_risk_threshold: float = 0.55,
                 deep: DeepSeizureModel | None = None, preictal=None):
        self.model = model
        self.high_risk_threshold = high_risk_threshold
        self.deep = deep
        # Optional real preictal-vs-interictal model (multichannel CHB-MIT).
        # None until the Phase-3 weights + engine are present; the transparent
        # heuristic below stands in for the live simulated-trajectory demo.
        self.preictal = preictal

    @classmethod
    def load(cls) -> "RiskClassifier":
        model, thr = None, 0.55
        if MODEL_PATH.exists():
            try:
                import joblib

                payload = joblib.load(MODEL_PATH)
                model = payload.get("model")
                thr = float(payload.get("high_risk_threshold", 0.55))
            except Exception as e:  # noqa: BLE001
                log.warning("sklearn model load failed (%s); using rules", e)
        deep = DeepSeizureModel.load() if USE_DEEP else None
        if deep and deep.available:
            log.info("classifier: deep engine ACTIVE (cnn_lstm)")
        preictal = cls._load_preictal() if USE_PREICTAL else None
        if preictal is not None and getattr(preictal, "available", False):
            log.info("classifier: preictal engine ACTIVE (cnn_lstm_preictal)")
        return cls(model=model, high_risk_threshold=thr, deep=deep, preictal=preictal)

    @staticmethod
    def _load_preictal():
        """Load the optional real preictal model, if the Phase-3 engine + weights
        exist. Absent module/weights degrade silently to the heuristic."""
        try:
            from app.ml.preictal_model import PreictalModel
        except Exception:  # noqa: BLE001 - engine not present yet (Phase 3)
            return None
        try:
            return PreictalModel.load()
        except Exception as e:  # noqa: BLE001
            log.warning("preictal model load failed (%s); using heuristic", e)
            return None

    # ---------------------------------------------------------------- public
    def predict_window(self, window: VitalWindow) -> RiskResult:
        """Full multimodal decision from a raw analysis window."""
        features = extract_features(window)

        deep_prob = None
        if self.deep is not None and self.deep.available:
            deep_prob = self.deep.predict_proba(window.eeg)

        if deep_prob is not None:
            mm = self._multimodal_score(features)  # 0..1 from HR/motion/ECG
            fused = DEEP_WEIGHT * deep_prob + (1.0 - DEEP_WEIGHT) * mm
            label = self._score_to_label(fused)
            confidence = fused if label != "stable" else 1.0 - fused
            result = RiskResult(
                label=label,
                confidence=round(float(min(max(confidence, 0.5), 0.99)), 4),
                features=features,
                engine="cnn_lstm_fusion",
                deep_prob=round(float(deep_prob), 4),
                components={"deep_prob": round(float(deep_prob), 4),
                            "multimodal_score": round(float(mm), 4),
                            "fused": round(float(fused), 4)},
            )
            return self._attach_prediction(result, window, features)

        # no deep engine -> sklearn or rules on features
        label, confidence, engine = self._predict_features(features)
        result = RiskResult(label=label, confidence=confidence,
                            features=features, engine=engine)
        return self._attach_prediction(result, window, features)

    def predict(self, features: FeatureVector) -> tuple[RiskLabel, float]:
        """Backward-compatible feature-only prediction (no deep EEG path)."""
        label, confidence, _ = self._predict_features(features)
        return label, confidence

    # ------------------------------------------------------------- prediction
    def _attach_prediction(self, result: RiskResult, window: VitalWindow,
                           features: FeatureVector) -> RiskResult:
        """Compute the forecasting layer (preictal probability -> lead-time ->
        pre-alert) and attach it to ``result`` WITHOUT touching the detection
        label/confidence. Prefers the real preictal model when available, else
        the transparent heuristic that rises with the simulated trajectory."""
        if not USE_PREICTAL:
            return result

        preictal_prob = None
        source = None
        horizon = HORIZON_MIN
        thr = PREICTAL_PREALERT_THR
        if self.preictal is not None and getattr(self.preictal, "available", False):
            try:
                preictal_prob = self.preictal.predict_proba(window)
            except Exception as e:  # noqa: BLE001
                log.warning("preictal predict failed (%s); using heuristic", e)
                preictal_prob = None
            if preictal_prob is not None:
                source = getattr(self.preictal, "engine_name", "cloud_preictal_net")
                horizon = float(getattr(self.preictal, "meta", {}).get("horizon_min", HORIZON_MIN))
                thr = float(getattr(self.preictal, "meta", {}).get("decision_threshold", PREICTAL_PREALERT_THR))

        if preictal_prob is None:
            preictal_prob = self._preictal_score(features)
            source = "simulated_heuristic"

        preictal_prob = float(min(max(preictal_prob, 0.0), 1.0))
        lead_time = self._lead_time(preictal_prob, horizon)

        result.preictal_prob = round(preictal_prob, 4)
        result.lead_time_min = round(lead_time, 2)
        result.horizon_min = horizon
        result.predicted = preictal_prob >= thr
        result.prediction_source = source
        # Surface the auditable drivers of the forecast (never overwrites the
        # detection components already set by the fusion engine).
        result.components.setdefault("preictal_prob", round(preictal_prob, 4))
        result.components.setdefault("preictal_drivers", self._preictal_breakdown(features))
        return result

    def _preictal_score(self, f: FeatureVector) -> float:
        """Transparent preictal (rising-risk) score in [0,1].

        Mirrors ``_multimodal_score`` but is tuned as a *forecast*: it climbs
        smoothly as the physiological trajectory ramps toward onset (rising EEG
        power/peak, tachycardia, motion), so the estimated lead-time counts down
        continuously rather than snapping between discrete states."""
        return float(min(sum(self._preictal_breakdown(f).values()), 1.0))

    def _preictal_breakdown(self, f: FeatureVector) -> dict:
        """Per-channel contributions to the preictal score (auditable "why")."""
        eeg = 0.28 * _ramp(f.eeg_power, 0.4, 1.4) + 0.22 * _ramp(f.eeg_peak, 0.6, 2.2)
        hr = 0.25 * _ramp(f.hr_mean, 80.0, 125.0)
        motion = 0.15 * _ramp(f.motion_energy, 0.2, 1.0)
        ecg = 0.10 * _ramp(f.ecg_variability, 0.3, 1.0)
        return {
            "eeg": round(float(eeg), 4),
            "hr": round(float(hr), 4),
            "motion": round(float(motion), 4),
            "ecg": round(float(ecg), 4),
        }

    def _lead_time(self, prob: float, horizon: float) -> float:
        """Estimated minutes until onset: monotone countdown from the horizon.

        prob 0 -> full horizon (far from a seizure); prob 1 -> ~0 (imminent)."""
        return max(0.0, horizon * (1.0 - prob))

    # --------------------------------------------------------------- engines
    def _predict_features(self, features: FeatureVector) -> tuple[RiskLabel, float, str]:
        if self.model is not None:
            x = features_to_array(features).reshape(1, -1)
            try:
                if hasattr(self.model, "predict_proba"):
                    proba = self.model.predict_proba(x)[0]
                    classes = list(self.model.classes_)
                    idx = int(np.argmax(proba))
                    label = str(classes[idx])
                    confidence = float(proba[idx])
                    if "high_risk" in classes:
                        hr_idx = classes.index("high_risk")
                        if float(proba[hr_idx]) >= self.high_risk_threshold:
                            return "high_risk", float(proba[hr_idx]), "sklearn"
                    if label in LABELS:
                        return label, confidence, "sklearn"  # type: ignore[return-value]
                pred = str(self.model.predict(x)[0])
                if pred in LABELS:
                    return pred, 0.7, "sklearn"  # type: ignore[return-value]
            except Exception as e:  # noqa: BLE001
                log.warning("sklearn predict failed (%s); using rules", e)
        label, confidence = self._rule_based(features)
        return label, confidence, "rules"

    def _multimodal_score(self, f: FeatureVector) -> float:
        """Additive risk score in [0,1] from the non-EEG-morphology channels.

        Kept separate from the deep EEG probability so the fusion is auditable:
        tachycardia + motion bursts raise the score independently of the CNN."""
        score = 0.0
        if f.hr_mean >= 110:
            score += 0.35
        elif f.hr_mean >= 90:
            score += 0.15
        if f.eeg_peak >= 2.0 or f.eeg_power >= 1.2:
            score += 0.30
        elif f.eeg_peak >= 1.2 or f.eeg_power >= 0.7:
            score += 0.15
        if f.motion_energy >= 0.8 or f.motion_variance >= 0.7:
            score += 0.25
        elif f.motion_energy >= 0.35:
            score += 0.10
        if f.ecg_variability >= 0.9:
            score += 0.10
        return float(min(score, 1.0))

    def _score_to_label(self, score: float) -> RiskLabel:
        if score >= HIGH_THR:
            return "high_risk"
        if score >= WATCH_THR:
            return "watch"
        return "stable"

    def _rule_based(self, f: FeatureVector) -> tuple[RiskLabel, float]:
        score = self._multimodal_score(f)
        if score >= 0.65:
            return "high_risk", min(0.5 + score / 2, 0.99)
        if score >= 0.3:
            return "watch", min(0.5 + score / 2, 0.95)
        return "stable", max(0.55, 1.0 - score)

    # ------------------------------------------------------------------ info
    def engine_info(self) -> dict:
        deep = self.deep.info() if self.deep is not None else {
            "engine": "cnn_lstm", "available": False, "error": "disabled"}
        preictal = self.preictal.info() if self.preictal is not None else {
            "engine": "cloud_preictal_net", "available": False, "error": "disabled"}
        prediction_source = (preictal.get("engine", "cloud_preictal_net") if preictal.get("available")
                             else "simulated_heuristic")
        meta = preictal.get("meta") or {}
        horizon = float(meta.get("horizon_min", HORIZON_MIN))
        thr = float(meta.get("decision_threshold", PREICTAL_PREALERT_THR))
        return {
            "active_engine": "cnn_lstm_fusion" if deep.get("available")
            else ("sklearn" if self.model is not None else "rules"),
            "deep": deep,
            "preictal": preictal,
            "sklearn_loaded": self.model is not None,
            "fusion_weight": DEEP_WEIGHT,
            "thresholds": {"high": HIGH_THR, "watch": WATCH_THR},
            "prediction": {
                "enabled": USE_PREICTAL,
                "source": prediction_source,
                "horizon_min": horizon,
                "prealert_threshold": thr,
            },
        }
