"""Push-token privacy, recipient resolution, and FCM adapter tests."""
from __future__ import annotations
from tests.account_payloads import patient_payload

from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app import notification_delivery, push_tokens_store
from app.main import app
from app.auth import create_token, decode_token
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME


@pytest.fixture
def client():
    with TestClient(app) as test_client:
        yield test_client


def _login(client: TestClient, username: str, password: str) -> str:
    response = client.post(
        "/auth/login", json={"username": username, "password": password, "device_id": "test-installation"}
    )
    assert response.status_code == 200, response.text
    return response.json()["access_token"]


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def test_notification_configuration_skips_firebase_for_stub(monkeypatch):
    monkeypatch.setenv("NOTIFICATION_CHANNEL", "stub")
    monkeypatch.setattr(
        notification_delivery,
        "_firebase_messaging",
        lambda: pytest.fail("Firebase must not initialize in stub mode"),
    )

    notification_delivery.validate_configuration()


def test_notification_configuration_initializes_firebase_for_fcm(monkeypatch):
    initialized: list[bool] = []
    monkeypatch.setenv("NOTIFICATION_CHANNEL", "fcm")
    monkeypatch.setattr(
        notification_delivery,
        "_firebase_messaging",
        lambda: initialized.append(True),
    )

    notification_delivery.validate_configuration()

    assert initialized == [True]


def _create_patient(client: TestClient) -> tuple[dict, str]:
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)
    response = client.post(
        "/admin/patients",
        json=patient_payload({
            "username": "push_patient", "name": "Push Patient",
            "password": "secret123",
        }),
        headers=_headers(admin),
    )
    assert response.status_code == 201, response.text
    return response.json()["user"], admin


def test_token_registration_is_authenticated_and_never_exposes_token(client):
    token_value = "fcm-registration-token-value-123456789"
    anonymous = client.post(
        "/notifications/device-token",
        json={"token": token_value, "platform": "android"},
    )
    assert anonymous.status_code == 401
    patient, admin = _create_patient(client)
    patient_token = _login(client, "push_patient", "secret123")

    registered = client.post(
        "/notifications/device-token",
        json={"token": token_value, "platform": "android"},
        headers=_headers(patient_token),
    )
    assert registered.status_code == 201, registered.text
    assert registered.json() == {
        "status": "registered", "registered_devices": 1
    }
    assert token_value not in registered.text
    assert token_value not in client.get(
        "/auth/me", headers=_headers(patient_token)
    ).text
    assert token_value not in client.get(
        f"/admin/users/{patient['id']}", headers=_headers(admin)
    ).text

    removed = client.request(
        "DELETE", "/notifications/device-token",
        json={"token": token_value, "platform": "android"},
        headers=_headers(patient_token),
    )
    assert removed.json() == {"status": "removed", "registered_devices": 0}


def test_recipient_resolution_uses_only_patient_care_graph(client):
    patient, admin = _create_patient(client)
    caregiver = client.post(
        "/admin/users",
        json={
            "username": "push_care", "name": "Care", "role": "caregiver",
            "password": "carepass123",
        },
        headers=_headers(admin),
    ).json()["user"]
    unrelated = client.post(
        "/admin/users",
        json={
            "username": "push_other", "name": "Other", "role": "caregiver",
            "password": "otherpass123",
        },
        headers=_headers(admin),
    ).json()["user"]
    linked = client.post(
        "/admin/caregiver-links",
        json={"patient_id": patient["id"], "caregiver_id": caregiver["id"]},
        headers=_headers(admin),
    )
    assert linked.status_code == 201, linked.text
    push_tokens_store.register(
        patient["id"], "patient-token-123456789012345", "android",
        session_id=decode_token(create_token(patient["id"], "patient"))["sid"],
    )
    push_tokens_store.register(
        caregiver["id"], "care-token-123456789012345678", "ios",
        session_id=decode_token(create_token(caregiver["id"], "caregiver"))["sid"],
    )
    push_tokens_store.register(
        unrelated["id"], "unrelated-token-123456789012", "ios",
        session_id=decode_token(create_token(unrelated["id"], "caregiver"))["sid"],
    )

    tokens = push_tokens_store.tokens_for_alert(
        patient["id"], ["patient", "caregiver", unrelated["id"]]
    )
    assert set(tokens) == {
        "patient-token-123456789012345", "care-token-123456789012345678"
    }


def test_fcm_adapter_removes_invalid_token_but_does_not_claim_delivery(client, monkeypatch):
    patient, _ = _create_patient(client)
    token = "invalid-fcm-token-123456789012345"
    push_tokens_store.register(patient["id"], token, "android",
        session_id=decode_token(create_token(patient["id"], "patient"))["sid"])

    class UnregisteredError(Exception):
        pass

    class FakeMessaging:
        class Notification:
            def __init__(self, **kwargs):
                self.values = kwargs

        class MulticastMessage:
            def __init__(self, **kwargs):
                self.values = kwargs

        @staticmethod
        def send_each_for_multicast(_message):
            return SimpleNamespace(
                success_count=0,
                failure_count=1,
                responses=[SimpleNamespace(
                    success=False, exception=UnregisteredError()
                )],
            )

    monkeypatch.setenv("NOTIFICATION_CHANNEL", "fcm")
    monkeypatch.setattr(
        notification_delivery, "_firebase_messaging", lambda: FakeMessaging
    )
    with pytest.raises(RuntimeError, match="no recipients"):
        notification_delivery.deliver({
            "id": "alert-push", "patient_id": patient["id"],
            "severity": "critical", "message": "Check patient",
            "recipients": ["patient"],
        })

    assert push_tokens_store.count_for_user(patient["id"]) == 0

def test_invalid_payload_error_does_not_delete_registration():
    class InvalidArgumentError(Exception):
        pass
    assert not notification_delivery._is_invalid_token_error(InvalidArgumentError("bad data payload"))
