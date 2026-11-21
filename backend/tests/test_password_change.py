import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME


@pytest.mark.parametrize("role", ["patient", "caregiver", "doctor", "admin"])
def test_password_change_requires_current_secret_and_revokes_old_sessions(role):
    with TestClient(app) as client:
        def login(username, password):
            return client.post("/auth/login", json={"username": username, "password": password})

        admin = login(TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD).json()["access_token"]
        admin_headers = {"Authorization": f"Bearer {admin}"}
        password = "original-password-123"
        username = f"change-{role}"
        created = client.post("/admin/users", headers=admin_headers, json={
            "username": username, "name": "Password test", "role": role, "password": password,
        })
        assert created.status_code == 201, created.text
        token = login(username, password).json()["access_token"]
        headers = {"Authorization": f"Bearer {token}"}
        bad = client.post("/auth/password", headers=headers, json={
            "current_password": "wrong-password", "new_password": "replacement-password-123",
        })
        assert bad.status_code == 400
        assert client.get("/auth/me", headers=headers).status_code == 200
        short = client.post("/auth/password", headers=headers, json={
            "current_password": password, "new_password": "short",
        })
        assert short.status_code == 422
        changed = client.post("/auth/password", headers=headers, json={
            "current_password": password, "new_password": "replacement-password-123",
        })
        assert changed.status_code == 200, changed.text
        assert changed.json()["sign_in_required"] is True
        assert client.get("/auth/me", headers=headers).status_code == 401
        assert login(username, password).status_code == 401
        assert login(username, "replacement-password-123").status_code == 200


def test_password_change_rejects_anonymous_requests():
    with TestClient(app) as client:
        assert client.post("/auth/password", json={
            "current_password": "original-password", "new_password": "replacement-password-123",
        }).status_code == 401
