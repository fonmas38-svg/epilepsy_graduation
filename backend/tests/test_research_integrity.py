"""Regression checks for research claims, labels, and independent evaluation."""
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "research" / "scripts"))
from splits import patient_wise_split, make_lodo
from windows import WindowSpec, _label_for_window, iter_windows
from edf_prep import _norm_ch, load_chbmit, parse_chbmit_summary
from app.routers.model_info import _read_metrics
from app.routers.device import IngestRequest, device_contract
from app.ml.classifier import RiskClassifier
from app.schemas import VitalWindow
from evaluate_holdout import evaluate


@pytest.fixture
def client():
    from fastapi.testclient import TestClient
    from app.main import app
    with TestClient(app) as instance:
        yield instance


@pytest.mark.parametrize("n", [1, 2])
def test_tiny_subject_sets_rejected(n):
    with pytest.raises(ValueError, match="independent subjects"):
        patient_wise_split(np.arange(n))


@pytest.mark.parametrize("n", [3, 4, 5, 20])
def test_every_subject_in_exactly_one_fold(n):
    subjects = np.repeat(np.arange(n), 5)
    tr, va, te, _ = patient_wise_split(subjects)
    assert tr.any() and va.any() and te.any()
    assert np.all(tr.astype(int) + va.astype(int) + te.astype(int) == 1)
    assert not set(subjects[tr]) & set(subjects[te])


def test_two_way_split_never_reuses_validation_for_test():
    tr, va, te, _ = patient_wise_split(np.arange(2), ratios=(0.85, 0.15, 0))
    assert tr.any() and va.any() and not te.any()


def test_lodo_cannot_test_training_dataset():
    with pytest.raises(ValueError):
        make_lodo("same", "same")


@pytest.mark.parametrize("kwargs", [{"stride_sec": 0}, {"fs": 0},
                                  {"window_sec": float("nan")},
                                  {"preictal_min": 3, "safety_gap_min": 5}])
def test_invalid_window_contract_rejected(kwargs):
    with pytest.raises(ValueError):
        WindowSpec(**{"fs": 256, **kwargs})


def test_label_independent_of_seizure_order_and_excludes_postictal():
    spec = WindowSpec(fs=256)
    events = [(2000, 2060), (1000, 1060)]
    assert _label_for_window(1010, 1015, events, spec) is None
    assert _label_for_window(1100, 1105, events[::-1], spec) is None
    assert _label_for_window(600, 605, [(2000, 2060)], spec) == 1
    assert _label_for_window(1700, 1705, [(2000, 2060)], spec) is None


def test_invalid_annotations_rejected():
    with pytest.raises(ValueError):
        list(iter_windows(np.ones((1, 100)), [(20, 10)], WindowSpec(fs=10)))


def test_bipolar_montage_is_not_relabelled_as_referential():
    assert _norm_ch("EEG FP1-F7") == "FP1-F7"
    assert _norm_ch("FP1-REF") != _norm_ch("FP1-F7")


def test_missing_annotations_are_not_negative_labels(tmp_path):
    (tmp_path / "chb01").mkdir()
    with pytest.raises(ValueError, match="annotation"):
        list(load_chbmit(tmp_path, None))


def test_chb01_and_chb21_are_one_person(tmp_path):
    for name in ("chb01", "chb21"):
        d = tmp_path / name
        d.mkdir()
        (d / "record.edf").touch()
        (d / f"{name}-summary.txt").write_text("File Name: record.edf\nNumber of Seizures in File: 0\n")
    assert [x[0] for x in load_chbmit(tmp_path, None)] == [1, 1]


def test_incomplete_annotations_fail_closed(tmp_path):
    p = tmp_path / "summary.txt"
    p.write_text("File Name: test.edf\nSeizure Start Time: 10 seconds\n")
    with pytest.raises(ValueError):
        parse_chbmit_summary(p)


def test_missing_metrics_never_fabricated(tmp_path):
    report = _read_metrics("preictal_chbmit", tmp_path / "missing.json")
    assert report["available"] is False
    assert "metrics" not in report


def test_saved_metrics_are_not_clinical_validation(tmp_path):
    p = tmp_path / "metrics.json"
    p.write_text('{"test_at_tuned_threshold":{"tp":80,"fn":20,"sensitivity":0.99}}')
    report = _read_metrics("test", p)
    assert not report["available"]
    assert report["verification_issues"]


def test_no_probability_to_countdown_and_invalid_model_score_abstains():
    window = VitalWindow(eeg=np.sin(np.arange(128)).tolist(),
                         ecg=[0.1] * 128, motion=[0.1] * 128, hr=70)
    for score in (0.1, 0.9, float("nan"), float("inf"), -0.1):
        preictal = SimpleNamespace(available=True, predict_proba=lambda w: score, meta={})
        result = RiskClassifier(preictal=preictal).predict_window(window)
        assert result.lead_time_min is None
        if not np.isfinite(score) or score < 0:
            assert result.preictal_prob is None and result.predicted is None


def test_wrong_hardware_rate_or_units_rejected():
    base = {"patient_id": "p", "samples": [{"eeg": 0, "ecg": 0, "motion": 0}]}
    for extra in ({"sample_rate_hz": 128}, {"signal_units": "microvolts"}):
        with pytest.raises(ValueError):
            IngestRequest(**base, **extra)
    assert device_contract()["physical_device_compatible"] is False


def holdout_arrays():
    return {"train_group": ["train1"], "val_group": ["val1"] * 4,
            "val_y": [0, 0, 1, 1], "val_score": [0.1, 0.2, 0.8, 0.9],
            "group": ["test1"] * 4, "y": [0, 0, 1, 1],
            "score": [0.1, 0.3, 0.85, 0.95]}


def test_evaluation_threshold_never_uses_test_labels():
    data = holdout_arrays()
    first = evaluate(data)
    data["y"] = [1, 1, 0, 0]
    second = evaluate(data)
    assert first["test"]["threshold"] == second["test"]["threshold"]
    assert first["test"]["sensitivity"] != second["test"]["sensitivity"]
    assert first["false_alarms_per_hour"] is None
    assert first["clinically_validated"] is False


def test_evaluation_rejects_group_leakage():
    data = holdout_arrays()
    data["train_group"] = ["test1"]
    with pytest.raises(ValueError, match="overlap"):
        evaluate(data)


def test_flatline_is_not_a_reassuring_assessment():
    result = RiskClassifier().predict_window(VitalWindow(
        eeg=[0.0] * 128, ecg=[0.0] * 128, motion=[0.0] * 128, hr=72))
    assert result.label == "watch" and result.confidence == 0
    assert result.components["assessment_valid"] is False
    assert result.preictal_prob is None and result.predicted is None


def test_extreme_finite_input_cannot_overflow_preprocessing():
    with pytest.raises(ValueError):
        VitalWindow(eeg=[1e300] * 8, ecg=[0.0] * 8, motion=[0.0] * 8)


def test_neural_preprocessing_never_stretches_unknown_time_axis():
    from app.ml.deep_model import DeepSeizureModel
    from app.ml.preictal_model import PreictalModel
    for model, shape in ((DeepSeizureModel(), (128,)), (PreictalModel(), (1, 128))):
        with pytest.raises(ValueError, match="length"):
            model._preprocess(np.sin(np.arange(128)).reshape(shape))


def test_training_does_not_claim_event_alarm_rate():
    from train import clinical_metrics
    report = clinical_metrics(np.array([0, 1]), np.array([0.8, 0.9]), 256, 5)
    assert report["fpr_per_hour"] is None
    assert report["window_false_positive_rate"] == 1.0


def test_device_contract_length_reaches_loaded_neural_engine(client):
    contract = client.get("/device/contract").json()
    n = contract["analysis_window_samples"]
    samples = [{"eeg": float(np.sin(2 * np.pi * 8 * i / 256)),
                "ecg": 0.0, "motion": 0.0, "hr": 72} for i in range(n)]
    response = client.post("/device/ingest", json={
        "patient_id": "contract-integration", "device_id": "headband-01",
        "sample_rate_hz": contract["sample_rate_hz"],
        "signal_units": contract["signal_units"], "samples": samples,
    }, headers={"Authorization": "Bearer headband-demo-token"})
    assert response.status_code == 200
    assessment = response.json()["assessment"]
    assert assessment is not None and assessment["lead_time_min"] is None
    info = client.get("/model/info").json()
    if info["deep"]["available"]:
        assert assessment["engine"] == "cnn_lstm_fusion"
        assert assessment["deep_prob"] is not None


def test_simulation_defaults_match_device_and_model_contract(client):
    n = client.get('/device/contract').json()['analysis_window_samples']
    assert len(client.get('/simulate/window').json()['window']['eeg']) == n
    assert len(client.post('/simulate/stream', json={}).json()['window']['eeg']) == n


def test_simulator_rejects_unbounded_allocations_and_unknown_patterns(client):
    for query in ('samples=1000000000', 'samples=0', 'pattern=unknown'):
        assert client.get('/simulate/window?' + query).status_code == 422
