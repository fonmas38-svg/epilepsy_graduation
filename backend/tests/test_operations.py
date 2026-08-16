"""P3 tests: alert outbox durability, readiness truthfulness, metrics, tracing.

The focus is behaviour that matters clinically: a critical alert must never be
silently lost, and readiness must not claim health while storage is broken.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import alert_outbox, cloud_store
from app.main import app
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client


def _admin_headers(client: TestClient) -> dict[str, str]:
    # /auth/login is the account login; /auth/token is for devices.
    response = client.post(
        "/auth/login",
        json={"username": TEST_ADMIN_USERNAME, "password": TEST_ADMIN_PASSWORD},
    )
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


CRITICAL_ALERT = {
    "id": "alert-1",
    "severity": "critical",
    "message": "High seizure risk",
    "timestamp": "2026-01-01T00:00:00+00:00",
}


# --------------------------------------------------------------- outbox basics

def test_critical_alert_is_enqueued_atomically_with_the_alert(client):
    cloud_store.save_monitoring_bundle(
        "p1",
        reading={"id": "r1", "hr": 90},
        assessment={"id": "a1", "label": "high_risk"},
        alert=CRITICAL_ALERT,
    )

    entries = alert_outbox.list_entries()
    assert len(entries) == 1
    assert entries[0]["alert_id"] == "alert-1"
    assert entries[0]["status"] == "pending"


def test_informational_alert_is_not_enqueued(client):
    cloud_store.save_monitoring_bundle(
        "p1",
        reading={"id": "r1", "hr": 70},
        alert={"id": "info-1", "severity": "info", "message": "stable"},
    )

    assert alert_outbox.list_entries() == []


def test_enqueue_is_idempotent_per_alert(client):
    """A retried enqueue of the same alert must not create a second delivery.

    Guards against double-notifying a caregiver when ingestion is replayed.
    """
    cloud_store.add_alert("p1", CRITICAL_ALERT)
    alert_outbox.enqueue_standalone("p1", CRITICAL_ALERT)  # replayed enqueue

    assert len(alert_outbox.list_entries()) == 1


# ------------------------------------------------------------ delivery retries

def test_failed_delivery_is_retried_not_lost(client):
    cloud_store.add_alert("p1", CRITICAL_ALERT)

    def failing_sender(_payload):
        raise ConnectionError("FCM unreachable")

    result = alert_outbox.process_once(failing_sender)

    assert result == {"processed": 1, "sent": 0, "failed": 1, "dead": 0}
    entry = alert_outbox.list_entries()[0]
    assert entry["status"] == "failed"
    assert entry["attempts"] == 1
    # The failure reason is retained for operators.
    assert "FCM unreachable" in entry["last_error"]


def test_entry_is_marked_dead_after_max_attempts(client):
    cloud_store.add_alert("p1", CRITICAL_ALERT)
    entry_id = alert_outbox.list_entries()[0]["id"]

    for _ in range(alert_outbox.MAX_ATTEMPTS):
        alert_outbox.mark_failure(entry_id, "boom")

    entry = alert_outbox.list_entries()[0]
    assert entry["status"] == "dead"
    assert entry["attempts"] == alert_outbox.MAX_ATTEMPTS
    # Dead rows are kept, never deleted, so the loss stays visible.
    assert alert_outbox.stats()["dead"] == 1


def test_successful_delivery_marks_entry_sent(client):
    cloud_store.add_alert("p1", CRITICAL_ALERT)
    delivered: list[dict] = []

    result = alert_outbox.process_once(delivered.append)

    assert result["sent"] == 1
    assert delivered[0]["id"] == "alert-1"
    assert alert_outbox.list_entries()[0]["status"] == "sent"


def test_sent_entries_are_not_redelivered(client):
    cloud_store.add_alert("p1", CRITICAL_ALERT)
    alert_outbox.process_once(lambda _payload: None)

    second_pass = alert_outbox.process_once(lambda _payload: None)

    assert second_pass["processed"] == 0


def test_backoff_grows_and_is_capped():
    assert alert_outbox.backoff_seconds(1) == 10
    assert alert_outbox.backoff_seconds(2) == 20
    assert alert_outbox.backoff_seconds(3) == 40
    assert alert_outbox.backoff_seconds(50) == 600  # capped


def test_failed_entry_is_not_due_until_backoff_elapses(client):
    cloud_store.add_alert("p1", CRITICAL_ALERT)
    alert_outbox.process_once(lambda _p: (_ for _ in ()).throw(TimeoutError("slow")))

    # Immediately afterwards the retry is scheduled in the future.
    assert alert_outbox.due_entries() == []


def test_worker_survives_a_sender_that_always_raises(client):
    cloud_store.add_alert("p1", CRITICAL_ALERT)

    # process_once must not propagate the sender's exception.
    result = alert_outbox.process_once(
        lambda _p: (_ for _ in ()).throw(RuntimeError("bad sender"))
    )

    assert result["processed"] == 1


# ---------------------------------------------------------------- API surfaces

def test_fcm_stub_returns_outbox_reference_and_keeps_legacy_status(client):
    payload = {
        "patient_id": "p1",
        "label": "high_risk",
        "confidence": 0.9,
        "message": "High seizure risk",
        "severity": "critical",
        "recipients": ["caregiver"],
        "should_notify": True,
    }

    response = client.post("/alerts/fcm-stub", json=payload)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["status"] == "queued"  # unchanged contract for the Flutter app
    assert body["delivery_status"] == "pending"
    assert body["outbox_id"]


def test_outbox_endpoint_requires_admin(client):
    assert client.get("/alerts/outbox").status_code in (401, 403)


def test_outbox_endpoint_reports_stats_for_admin(client):
    cloud_store.add_alert("p1", CRITICAL_ALERT)

    response = client.get("/alerts/outbox", headers=_admin_headers(client))

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["stats"]["pending"] == 1
    assert body["entries"][0]["alert_id"] == "alert-1"


# ------------------------------------------------------------------- readiness

def test_readiness_includes_a_real_database_check(client):
    response = client.get("/health/ready")

    assert response.status_code == 200, response.text
    assert response.json()["checks"]["database"] is True


def test_readiness_reports_degraded_when_the_database_is_unusable(client, monkeypatch):
    def broken_connection():
        raise RuntimeError("database is locked")

    monkeypatch.setattr("app.database.connection", broken_connection)

    response = client.get("/health/ready")

    # Claiming "ready" here would keep traffic flowing into guaranteed failures.
    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "degraded"
    assert body["checks"]["database"] is False
    assert "database" in body["errors"]


def test_liveness_does_not_depend_on_the_database(client, monkeypatch):
    monkeypatch.setattr(
        "app.database.connection",
        lambda: (_ for _ in ()).throw(RuntimeError("down")),
    )

    # Liveness must stay 200 so a storage blip cannot cause restart loops.
    assert client.get("/health/live").status_code == 200


# --------------------------------------------------------------------- metrics

def test_metrics_requires_admin(client):
    assert client.get("/metrics").status_code in (401, 403)


def test_metrics_reports_inference_latency_and_outbox_health(client):
    window = {
        "patient_id": "p1",
        "eeg": [0.1] * 128,
        "ecg": [0.2] * 128,
        "motion": [0.0] * 128,
        "hr": 80,
        "timestamp": "2026-01-01T00:00:00+00:00",
    }
    assert client.post("/analyze", json=window).status_code == 200

    response = client.get("/metrics", headers=_admin_headers(client))

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["counters"]["inference_total"] == 1
    assert body["latency"]["inference"]["count"] == 1
    assert body["latency"]["inference"]["p95_ms"] >= 0
    assert "alert_outbox" in body


def test_request_id_is_returned_for_tracing(client):
    response = client.get("/health")

    assert response.headers.get("x-request-id")


def test_supplied_request_id_is_preserved(client):
    response = client.get("/health", headers={"X-Request-ID": "trace-me-123"})

    assert response.headers["x-request-id"] == "trace-me-123"
