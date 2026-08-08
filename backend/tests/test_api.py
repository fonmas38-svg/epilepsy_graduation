import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.simulation import generate_window


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_analyze_stable(client):
    window = generate_window("stable", seed=1)
    r = client.post("/analyze", json=window.model_dump())
    assert r.status_code == 200
    body = r.json()
    assert body["label"] in ("stable", "watch", "high_risk")
    assert body["processing_ms"] < 60_000


def test_analyze_high_risk_tends_high(client):
    window = generate_window("high_risk", seed=7)
    r = client.post("/analyze", json=window.model_dump())
    assert r.status_code == 200
    assert r.json()["label"] in ("watch", "high_risk")


def test_simulate_stream(client):
    r = client.post("/simulate/stream", json={"pattern": "watch", "samples": 64})
    assert r.status_code == 200
    assert len(r.json()["window"]["eeg"]) == 64


def test_alert_evaluate(client):
    window = generate_window("high_risk", seed=99)
    r = client.post(
        "/alerts/evaluate",
        json={"patient_id": "p1", "window": window.model_dump()},
    )
    assert r.status_code == 200
    body = r.json()
    assert "should_notify" in body
    assert body["patient_id"] == "p1"


def test_device_ingest_and_status(client):
    headers = {"Authorization": "Bearer headband-demo-token"}
    samples = [
        {"eeg": 0.2, "ecg": 0.5, "motion": 0.01, "hr": 80}
        for _ in range(128)
    ]
    r = client.post(
        "/device/ingest",
        json={
            "patient_id": "patient-demo",
            "device_id": "headband-01",
            "samples": samples,
        },
        headers=headers,
    )
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["assessment"] is not None
    assert body["assessment"]["label"] in ("stable", "watch", "high_risk")

    st = client.get("/device/status/patient-demo")
    assert st.status_code == 200
    assert st.json()["connected"] is True
    assert st.json()["last_label"] is not None


def test_device_rejects_bad_token(client):
    r = client.post(
        "/device/ingest",
        json={"patient_id": "p1", "samples": [{"eeg": 1, "ecg": 1, "motion": 1}]},
        headers={"Authorization": "Bearer wrong"},
    )
    assert r.status_code == 403


def test_auth_issue_jwt_and_ingest(client):
    """A device can exchange its enrollment secret for a JWT and ingest with it."""
    tok = client.post(
        "/auth/token",
        json={"subject": "headband-01", "role": "device",
              "enrollment_secret": "enroll-device-demo"},
    )
    assert tok.status_code == 200
    access = tok.json()["access_token"]
    assert tok.json()["token_type"] == "bearer"

    r = client.post(
        "/device/ingest",
        json={"patient_id": "p-jwt", "device_id": "headband-01",
              "samples": [{"eeg": 0.2, "ecg": 0.5, "motion": 0.01, "hr": 80}
                          for _ in range(64)]},
        headers={"Authorization": f"Bearer {access}"},
    )
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_auth_rejects_bad_enrollment_secret(client):
    r = client.post(
        "/auth/token",
        json={"subject": "x", "role": "device", "enrollment_secret": "nope"},
    )
    assert r.status_code == 401


def test_auth_wrong_role_cannot_ingest(client):
    """A patient-role JWT must not be allowed to push device data."""
    tok = client.post(
        "/auth/token",
        json={"subject": "u1", "role": "patient",
              "enrollment_secret": "enroll-patient-demo"},
    ).json()["access_token"]
    r = client.post(
        "/device/ingest",
        json={"patient_id": "p1", "samples": [{"eeg": 1, "ecg": 1, "motion": 1}]},
        headers={"Authorization": f"Bearer {tok}"},
    )
    assert r.status_code == 403


def test_dataset_next_and_cloud(client):
    r = client.post(
        "/dataset/next",
        json={"patient_id": "patient-demo", "prefer_label": "high_risk"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["assessment"]["label"] in ("stable", "watch", "high_risk")
    cloud = client.get("/cloud/patients/patient-demo")
    assert cloud.status_code == 200
    assert len(cloud.json()["assessments"]) >= 1


def test_model_info_reports_engine(client):
    r = client.get("/model/info")
    assert r.status_code == 200
    body = r.json()
    assert body["active_engine"] in ("cnn_lstm_fusion", "sklearn", "rules")
    assert "deep" in body and "thresholds" in body


def test_analyze_reports_engine(client):
    window = generate_window("high_risk", seed=3)
    r = client.post("/analyze", json=window.model_dump())
    assert r.status_code == 200
    body = r.json()
    assert body["engine"] in ("cnn_lstm_fusion", "sklearn", "rules")


def test_bonn_stream_discriminates_when_available(client):
    """If the real Bonn dataset + deep model are present, the deep engine must
    actually separate ictal from non-ictal on in-domain data."""
    info = client.get("/model/info").json()
    if not (info["deep"]["available"] and info["bonn_stream_available"]):
        pytest.skip("deep model or Bonn dataset not available in this env")
    correct = 0
    n = 16
    for i in range(n):
        label = "ictal" if i % 2 == 0 else "nonictal"
        r = client.post(
            "/dataset/bonn/next",
            json={"patient_id": "p-bonn", "prefer_label": label},
        )
        assert r.status_code == 200
        if r.json()["deep_correct"]:
            correct += 1
    # in-domain accuracy should be well above chance
    assert correct / n >= 0.75

