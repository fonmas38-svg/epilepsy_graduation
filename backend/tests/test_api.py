import pytest
from dataclasses import replace
from fastapi.testclient import TestClient

import app.auth as auth_module
import app.middleware as middleware_module
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


def test_health_live_and_ready(client):
    live = client.get("/health/live")
    assert live.status_code == 200
    assert live.json()["status"] == "alive"
    ready = client.get("/health/ready")
    assert ready.status_code == 200
    assert ready.json()["status"] == "ready"
    # Assert on required checks instead of an exact dict, so adding a new
    # dependency check (e.g. database) does not break this test.
    checks = ready.json()["checks"]
    assert checks["classifier"] is True
    assert checks["device_hub"] is True
    assert checks["database"] is True
    assert all(checks.values())


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


def test_invalid_timestamp_is_rejected(client):
    window = generate_window("stable", seed=10).model_dump()
    window["timestamp"] = "2035-01-01T00:00:00+00:00"
    r = client.post("/analyze", json=window)
    assert r.status_code == 422


def test_naive_timestamp_is_rejected(client):
    window = generate_window("stable", seed=11).model_dump()
    window["timestamp"] = "2026-08-14T00:00:00"
    r = client.post("/analyze", json=window)
    assert r.status_code == 422


def test_historical_timestamp_is_allowed_for_offline_analysis(client):
    window = generate_window("stable", seed=12).model_dump()
    window["timestamp"] = "2020-01-01T00:00:00+00:00"
    r = client.post("/analyze", json=window)
    assert r.status_code == 200


def test_old_device_timestamp_is_rejected(client):
    r = client.post(
        "/device/ingest",
        json={
            "patient_id": "p-old-clock",
            "samples": [{
                "eeg": 1,
                "ecg": 1,
                "motion": 1,
                "ts": "2020-01-01T00:00:00+00:00",
            }],
        },
        headers={"Authorization": "Bearer headband-demo-token"},
    )
    assert r.status_code == 422


def test_request_body_limit_returns_413(client, monkeypatch):
    monkeypatch.setattr(
        middleware_module,
        "settings",
        replace(middleware_module.settings, max_request_body_bytes=32),
    )
    r = client.post("/analyze", json={"payload": "x" * 128})
    assert r.status_code == 413


def test_rate_limit_returns_429(client, monkeypatch):
    monkeypatch.setattr(
        middleware_module,
        "settings",
        replace(
            middleware_module.settings,
            rate_limit_requests=2,
            rate_limit_window_seconds=60,
        ),
    )
    path = "/test-only-rate-limit-key"
    assert client.get(path).status_code == 404
    assert client.get(path).status_code == 404
    limited = client.get(path)
    assert limited.status_code == 429
    assert int(limited.headers["retry-after"]) >= 1


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
        for _ in range(client.get("/device/contract").json()["analysis_window_samples"])
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


def test_device_token_info_hides_demo_token_in_production(client, monkeypatch):
    from dataclasses import replace
    from app.routers import device as device_router

    monkeypatch.setattr(
        device_router,
        "settings",
        replace(device_router.settings, environment="production", allow_legacy_token=False),
    )
    r = client.get("/device/token-info")
    assert r.status_code == 200
    assert "demo_token" not in r.json()


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


def test_device_ingest_rejects_wrong_device_id(client):
    token = client.post(
        "/auth/token",
        json={"subject": "headband-01", "role": "device", "enrollment_secret": "enroll-device-demo"},
    ).json()["access_token"]
    r = client.post(
        "/device/ingest",
        json={"patient_id": "p-jwt", "device_id": "another-device", "samples": [{"eeg": 1, "ecg": 1, "motion": 1}]},
        headers={"Authorization": f"Bearer {token}"},
    )
    assert r.status_code == 403


def test_device_batch_id_and_sequence_prevent_replay(client):
    headers = {"Authorization": "Bearer headband-demo-token"}
    payload = {
        "patient_id": "patient-replay",
        "device_id": "headband-01",
        "samples": [{"eeg": 0.2, "ecg": 0.5, "motion": 0.01, "hr": 80}],
        "batch_id": "batch-1",
        "sequence_number": 5,
    }
    first = client.post("/device/ingest", json=payload, headers=headers)
    assert first.status_code == 200
    assert first.json()["accepted"] == 1
    replay = client.post("/device/ingest", json=payload, headers=headers)
    assert replay.status_code == 200
    assert replay.json()["duplicate"] is True
    stale = client.post(
        "/device/ingest",
        json={**payload, "batch_id": "batch-0", "sequence_number": 4},
        headers=headers,
    )
    assert stale.status_code == 200
    assert stale.json()["out_of_order"] is True


def test_legacy_token_is_rejected_when_patient_authorization_is_enabled(client, monkeypatch):
    from dataclasses import replace

    monkeypatch.setattr(auth_module, "settings", replace(auth_module.settings, require_patient_auth=True))
    r = client.post(
        "/device/ingest",
        json={"patient_id": "p1", "samples": [{"eeg": 1, "ecg": 1, "motion": 1}]},
        headers={"Authorization": "Bearer headband-demo-token"},
    )
    assert r.status_code == 403


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

