from uuid import uuid4
from fastapi.testclient import TestClient
from app import cloud_store, users_store
from app.auth import create_token
from app.main import app
from tests.test_phase5_6_channels_outcomes_meds import _setup_care_circle


def test_review_queue_paginates_all_assigned_alerts_without_leaking_other_patients():
    client = TestClient(app)
    pid, _, _, patient, doctor, caregiver = _setup_care_circle(client)
    for index in range(125):
        cloud_store.add_alert(pid, {"id": f"q-{index}", "timestamp": "2026-11-24T12:00:00Z", "severity": "critical"})
    cloud_store.add_alert("other", {"id": "foreign", "severity": "critical"})
    cloud_store.add_alert(pid, {"id": "info", "severity": "info"})
    path = "/doctor/review-queue?limit=40"
    collected = []
    while path:
        response = client.get(path, headers=doctor)
        assert response.status_code == 200, response.text
        data = response.json()
        collected.extend(row["alert"]["id"] for row in data["items"])
        cursor = data["nextCursor"]
        path = f"/doctor/review-queue?limit=40&before={cursor}" if cursor else None
    assert len(collected) == len(set(collected)) == 125
    for forbidden in (patient, caregiver):
        assert client.get("/doctor/review-queue", headers=forbidden).status_code == 403
    assert client.get("/doctor/review-queue").status_code == 401
    assert client.get("/doctor/review-queue?patient_id=other", headers=doctor).status_code == 403


def test_patient_report_does_not_hide_or_replace_clinician_review():
    client = TestClient(app)
    pid, _, _, patient, doctor, _ = _setup_care_circle(client)
    cloud_store.add_alert(pid, {"id": "reported", "timestamp": "2026-11-24T12:00:00Z", "severity": "critical"})
    payload = {"id": str(uuid4()), "occurred_at": "2026-11-24T12:00:00Z", "alert_id": "reported"}
    for _ in range(2):
        report = client.post(f"/patients/{pid}/seizure-logs", headers=patient, json=payload)
        assert report.status_code == 201, report.text
        assert report.json()["event"]["alertId"] == "reported"
    assert len(client.get("/doctor/review-queue", headers=doctor).json()["items"]) == 1
    outcome = client.post(f"/patients/{pid}/outcomes", headers=doctor,
        json={"id": str(uuid4()), "outcome": "false_alarm", "occurred_at": payload["occurred_at"], "alert_id": "reported"})
    assert outcome.status_code == 201, outcome.text
    assert client.get("/doctor/review-queue", headers=doctor).json()["items"] == []
    reports = client.get(f"/patients/{pid}/seizure-logs", headers=patient).json()
    assert len(reports) == 1 and reports[0]["clinicallyConfirmed"] is False
