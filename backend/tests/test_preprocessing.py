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
