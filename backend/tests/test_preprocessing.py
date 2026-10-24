from app.preprocessing import extract_features, features_to_array
from app.simulation import generate_window
from app.ml.classifier import RiskClassifier


def test_feature_extraction_shape():
    w = generate_window("stable", samples=64, seed=0)
    f = extract_features(w)
    arr = features_to_array(f)
    assert arr.shape == (7,)
    assert f.hr_mean > 0


def test_rule_based_classifier_runs():
    clf = RiskClassifier()
    for pattern in ("stable", "watch", "high_risk"):
        w = generate_window(pattern, seed=3)
        label, conf = clf.predict(extract_features(w))
        assert label in ("stable", "watch", "high_risk")
        assert 0 < conf <= 1


def test_rule_context_preserves_signal_amplitude_and_legacy_contract():
    import numpy as np
    import pytest
    from app.schemas import VitalWindow
    x = np.sin(np.linspace(0, 8 * np.pi, 128))
    def window(scale):
        return VitalWindow(patient_id="p", eeg=list(x * scale), ecg=list(x * scale),
                           motion=list(x * scale), hr=72)
    quiet = extract_features(window(0.01), unit_variance=False)
    loud = extract_features(window(1), unit_variance=False)
    assert loud.motion_energy / quiet.motion_energy == pytest.approx(10000)
    assert loud.eeg_power / quiet.eeg_power == pytest.approx(10000)
    assert extract_features(window(0.01)).motion_energy == pytest.approx(1)
    clf = RiskClassifier()
    assert clf.predict_window(window(0.01)).label == "stable"
