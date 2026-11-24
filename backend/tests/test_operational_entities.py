"""End-to-end tests for device, caregiver, acknowledgment, and outcome flows."""
from tests.account_payloads import patient_payload
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from app import cloud_store
from app.main import app
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client


def _login(client: TestClient, username: str, password: str) -> str:
    response = client.post("/auth/login", json={"username": username, "password": password, "device_id": "test-installation"})
    assert response.status_code == 200, response.text
    return response.json()["access_token"]


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _admin(client: TestClient) -> str:
    return _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)


def _create_patient(client: TestClient, admin: str, username: str = "patient_ops") -> dict:
    response = client.post(
        "/admin/patients",
        json=patient_payload({"username": username, "name": "Operational Patient", "password": "secret123"}),
        headers=_headers(admin),
    )
    assert response.status_code == 201, response.text
    return response.json()["user"]


def test_registered_device_token_is_revoked_by_secret_rotation(client, monkeypatch):
    from app import auth as auth_policy
    from app.routers import auth as auth_router

    admin = _admin(client)
    patient = _create_patient(client, admin)
    created = client.post(
        "/admin/devices",
        json={
            "device_id": "headband-secure-1",
            "patient_id": patient["id"],
            "name": "Patient headband",
            "enrollment_secret": "first-device-secret",
        },
        headers=_headers(admin),
    )
    assert created.status_code == 201, created.text
    assert "secretHash" not in created.text

    production = replace(auth_router.settings, environment="production", require_patient_auth=True)
    monkeypatch.setattr(auth_router, "settings", production)
    monkeypatch.setattr(auth_policy, "settings", production)

    enrollment = {
        "subject": "headband-secure-1", "role": "device",
        "patient_id": patient["id"], "enrollment_secret": "first-device-secret",
    }
    issued = client.post("/auth/token", json=enrollment)
    assert issued.status_code == 200, issued.text
    old_token = issued.json()["access_token"]
    assert client.get("/auth/me", headers=_headers(old_token)).status_code == 200

    rotated = client.post(
        "/admin/devices/headband-secure-1/secret",
        json={"enrollment_secret": "second-device-secret"},
        headers=_headers(admin),
    )
    assert rotated.status_code == 200, rotated.text
    assert client.get("/auth/me", headers=_headers(old_token)).status_code == 401
    assert client.post("/auth/token", json=enrollment).status_code == 401

    enrollment["enrollment_secret"] = "second-device-secret"
    new_token = client.post("/auth/token", json=enrollment).json()["access_token"]
    assert client.post(
        "/admin/devices/headband-secure-1/disable", headers=_headers(admin)
    ).status_code == 200
    assert client.get("/auth/me", headers=_headers(new_token)).status_code == 401


def test_caregiver_link_controls_patient_access(client, monkeypatch):
    from app import auth as auth_policy

    admin = _admin(client)
    patient = _create_patient(client, admin, "patient_linked")
    caregiver_response = client.post(
        "/admin/users",
        json={
            "username": "caregiver_linked", "name": "Caregiver",
            "role": "caregiver", "password": "carepass123",
        },
        headers=_headers(admin),
    )
    caregiver_id = caregiver_response.json()["user"]["id"]
    caregiver = _login(client, "caregiver_linked", "carepass123")
    monkeypatch.setattr(
        auth_policy, "settings", replace(auth_policy.settings, require_patient_auth=True)
    )

    path = f"/patients/{patient['id']}/outcomes"
    assert client.get(path, headers=_headers(caregiver)).status_code == 403
    linked = client.post(
        "/admin/caregiver-links",
        json={"patient_id": patient["id"], "caregiver_id": caregiver_id},
        headers=_headers(admin),
    )
    assert linked.status_code == 201, linked.text
    assert client.get(path, headers=_headers(caregiver)).status_code == 200
    assert client.request(
        "DELETE", "/admin/caregiver-links",
        json={"patient_id": patient["id"], "caregiver_id": caregiver_id},
        headers=_headers(admin),
    ).status_code == 200
    assert client.get(path, headers=_headers(caregiver)).status_code == 403


def test_alert_keeps_independent_acknowledgments_per_actor(client, monkeypatch):
    from app import auth as auth_policy

    admin = _admin(client)
    patient = _create_patient(client, admin, "patient_ack")
    caregiver_response = client.post(
        "/admin/users",
        json={"username": "care_ack", "name": "Care", "role": "caregiver",
              "password": "carepass123"},
        headers=_headers(admin),
    )
    caregiver_id = caregiver_response.json()["user"]["id"]
    client.post(
        "/admin/caregiver-links",
        json={"patient_id": patient["id"], "caregiver_id": caregiver_id},
        headers=_headers(admin),
    )
    patient_token = _login(client, "patient_ack", "secret123")
    caregiver_token = _login(client, "care_ack", "carepass123")
    alert = cloud_store.add_alert(patient["id"], {"id": "alert-multi", "severity": "warning"})
    monkeypatch.setattr(
        auth_policy, "settings", replace(auth_policy.settings, require_patient_auth=True)
    )
    endpoint = f"/patients/{patient['id']}/alerts/{alert['id']}/acknowledgments"

    assert client.post(endpoint, json={"note": "I am safe"},
                       headers=_headers(patient_token)).status_code == 201
    assert client.post(endpoint, json={"note": "On my way"},
                       headers=_headers(caregiver_token)).status_code == 201
    # Retrying the same actor is idempotent and cannot duplicate the event.
    assert client.post(endpoint, json={}, headers=_headers(caregiver_token)).status_code == 201
    acknowledgments = client.get(endpoint, headers=_headers(patient_token)).json()["acknowledgments"]
    assert {row["actorRole"] for row in acknowledgments} == {"patient", "caregiver"}
    assert len(acknowledgments) == 2


def test_outcome_links_to_same_patient_assessment_only(client):
    admin = _admin(client)
    patient = _create_patient(client, admin, "patient_outcome")
    other = _create_patient(client, admin, "patient_other")
    own_assessment = cloud_store.add_assessment(
        patient["id"], {"id": "assessment-own", "label": "high_risk"}
    )
    cloud_store.add_assessment(other["id"], {"id": "assessment-other", "label": "watch"})
    endpoint = f"/patients/{patient['id']}/outcomes"
    payload = {
        "outcome": "seizure", "occurred_at": "2026-08-15T10:00:00+00:00",
        "assessment_id": own_assessment["id"], "notes": "Confirmed by clinician",
    }

    created = client.post(endpoint, json=payload, headers=_headers(admin))
    assert created.status_code == 201, created.text
    assert created.json()["outcome"]["assessmentId"] == "assessment-own"
    assert client.get(endpoint, headers=_headers(admin)).json()["outcomes"][0]["outcome"] == "seizure"

    payload["assessment_id"] = "assessment-other"
    rejected = client.post(endpoint, json=payload, headers=_headers(admin))
    assert rejected.status_code == 422
    assert "does not belong" in rejected.text