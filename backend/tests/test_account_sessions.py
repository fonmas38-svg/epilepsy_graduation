"""Isolated tests for per-login revocation and notification routing ownership."""
from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, update

from app import account_sessions_store, auth, push_tokens_store, security, users_store
from app.database import account_sessions, connection, push_tokens, transaction
from app.main import app

PASSWORD = "session-original-password-123"


@pytest.fixture
def client():
    with TestClient(app) as result:
        yield result


def make_user(role="patient", username="session-person"):
    return users_store.create_user(username=username, name="Session person", role=role,
        password_hash=security.hash_password(PASSWORD))


def login(client, username, name="Test device", password=PASSWORD, device_id=None):
    payload = {"username": username, "password": password,
        "device_name": name, "platform": "android"}
    if device_id is not None:
        payload["device_id"] = device_id
    response = client.post("/auth/login", json=payload)
    assert response.status_code == 200, response.text
    token = response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}, auth.decode_token(token), token


def login_raw(client, username, name="Test device", password=PASSWORD, device_id=None):
    payload = {"username": username, "password": password,
        "device_name": name, "platform": "android"}
    if device_id is not None:
        payload["device_id"] = device_id
    return client.post("/auth/login", json=payload)


def register(client, headers, token):
    response = client.post("/notifications/device-token", headers=headers,
        json={"token": token, "platform": "android"})
    assert response.status_code == 201, response.text


@pytest.mark.parametrize("role", ["patient", "caregiver", "doctor", "admin"])
def test_each_login_has_independent_session_and_logout_revokes_current(client, role):
    user = make_user(role)
    first, first_claims, first_token = login(client, user["username"], "First phone")
    second, second_claims, second_token = login(client, user["username"], "Second phone")
    assert first_claims["sid"] != second_claims["sid"]
    listed = client.get("/auth/sessions", headers=second)
    assert listed.status_code == 200
    data = listed.json()
    assert data["currentSessionId"] == second_claims["sid"]
    assert {item["deviceName"] for item in data["sessions"]} == {"First phone", "Second phone"}
    assert sum(item["current"] for item in data["sessions"]) == 1
    assert all(item["active"] for item in data["sessions"])
    assert not data["hasMore"]
    assert first_token not in listed.text and second_token not in listed.text and PASSWORD not in listed.text
    revoked = client.delete(f"/auth/sessions/{first_claims['sid']}", headers=second)
    assert revoked.json() == {"ok": True, "sign_in_required": False}
    assert client.get("/auth/me", headers=first).status_code == 401
    assert client.get("/auth/me", headers=second).status_code == 200
    # Repeated removal is safe while another owned session remains authorized.
    assert client.delete(f"/auth/sessions/{first_claims['sid']}", headers=second).status_code == 200
    assert client.post("/auth/logout", headers=second).json()["sign_in_required"] is True
    assert client.get("/auth/me", headers=second).status_code == 401


def test_session_management_cannot_read_or_revoke_another_account(client):
    one = make_user(username="session-one")
    two = make_user(username="session-two")
    first, _, _ = login(client, one["username"])
    second, claims, _ = login(client, two["username"])
    listed = client.get("/auth/sessions", headers=first)
    assert claims["sid"] not in listed.text
    assert client.delete(f"/auth/sessions/{claims['sid']}", headers=first).status_code == 404
    assert client.get("/auth/me", headers=second).status_code == 200
    assert client.get("/auth/sessions").status_code == 401


def test_revoke_others_removes_their_push_routes_but_preserves_current(client):
    user = make_user()
    old, _, _ = login(client, user["username"], "Lost phone")
    current, current_claims, _ = login(client, user["username"], "Current phone")
    old_push = "old-push-registration-1234567890"
    new_push = "current-push-registration-1234567890"
    register(client, old, old_push)
    register(client, current, new_push)
    assert set(push_tokens_store.tokens_for_alert(user["id"], ["patient"])) == {old_push, new_push}
    result = client.post("/auth/sessions/revoke-others", headers=current)
    assert result.json() == {"ok": True, "revoked": 1}
    assert push_tokens_store.tokens_for_alert(user["id"], ["patient"]) == [new_push]
    assert client.get("/auth/me", headers=old).status_code == 401
    assert client.get("/auth/me", headers=current).status_code == 200
    assert client.post("/auth/sessions/revoke-others", headers=current).json()["revoked"] == 0
    revoked_self = client.delete(f"/auth/sessions/{current_claims['sid']}", headers=current)
    assert revoked_self.json()["sign_in_required"] is True
    assert push_tokens_store.tokens_for_alert(user["id"], ["patient"]) == []


def test_password_change_invalidates_all_sessions_and_their_push_routes(client):
    user = make_user()
    old, _, _ = login(client, user["username"])
    second, _, _ = login(client, user["username"])
    push = "password-reset-push-token-1234567890"
    register(client, old, push)
    result = client.post("/auth/password", headers=second, json={
        "current_password": PASSWORD, "new_password": "replacement-session-password-123"})
    assert result.status_code == 200, result.text
    assert client.get("/auth/me", headers=old).status_code == 401
    assert client.get("/auth/me", headers=second).status_code == 401
    assert push_tokens_store.tokens_for_alert(user["id"], ["patient"]) == []
    assert push_tokens_store.count_for_user(user["id"]) == 0
    fresh, _, _ = login(client, user["username"], password="replacement-session-password-123")
    register(client, fresh, push)
    assert push_tokens_store.tokens_for_alert(user["id"], ["patient"]) == [push]


def test_push_reregistration_cannot_be_erased_or_revived_by_old_session(client):
    user = make_user()
    old, old_claims, _ = login(client, user["username"])
    current, current_claims, _ = login(client, user["username"])
    token = "same-installation-push-token-1234567890"
    register(client, old, token)
    register(client, current, token)
    with pytest.raises(ValueError, match="newer session"):
        push_tokens_store.register(user["id"], token, session_id=old_claims["sid"])
    # A delayed unregister operation from the previous login does not remove
    # the same installation's newly registered notification route.
    assert push_tokens_store.unregister(user["id"], token, session_id=old_claims["sid"]) is False
    assert client.delete(f"/auth/sessions/{old_claims['sid']}", headers=current).status_code == 200
    with pytest.raises(ValueError, match="inactive"):
        push_tokens_store.register(user["id"], token, session_id=old_claims["sid"])
    assert push_tokens_store.tokens_for_alert(user["id"], ["patient"]) == [token]
    with connection() as conn:
        assert conn.scalar(select(push_tokens.c.session_id).where(push_tokens.c.token == token)) == current_claims["sid"]


def test_legacy_account_tokens_fail_closed_but_device_token_policy_is_unchanged(client):
    user = make_user()
    legacy = auth.jwt.encode({"sub": user["id"], "role": "patient", "iat": int(time.time()),
        "exp": int(time.time()) + 600, "session_version": 0}, auth.JWT_SECRET, algorithm=auth.JWT_ALG)
    response = client.get("/auth/me", headers={"Authorization": f"Bearer {legacy}"})
    assert response.status_code == 401
    device = auth.create_token("test-device", "device")
    assert auth.decode_token(device)["sub"] == "test-device"
    assert "sid" not in auth.decode_token(device)


def test_registry_expiry_and_unbound_legacy_push_rows_are_enforced(client):
    user = make_user()
    headers, claims, _ = login(client, user["username"])
    register(client, headers, "expired-session-push-token-1234567890")
    with transaction() as conn:
        conn.execute(update(account_sessions).where(account_sessions.c.id == claims["sid"])
            .values(expires_at=account_sessions_store.stamp(time.time() - 1)))
        conn.execute(push_tokens.insert().values(id="legacy-push", user_id=user["id"],
            token="unbound-legacy-push-token-1234567890", platform="android", session_id=None,
            created_at="old", updated_at="old"))
    assert client.get("/auth/me", headers=headers).status_code == 401
    assert push_tokens_store.tokens_for_alert(user["id"], ["patient"]) == []


def test_expired_and_disabled_sessions_cannot_register_notifications(client):
    user = make_user()
    headers, claims, _ = login(client, user["username"])
    users_store.set_disabled(user["id"], True)
    assert client.get("/auth/me", headers=headers).status_code == 401
    with pytest.raises(ValueError, match="inactive"):
        push_tokens_store.register(user["id"], "disabled-account-token-1234567890", session_id=claims["sid"])
    users_store.set_disabled(user["id"], False)
    assert client.get("/auth/me", headers=headers).status_code == 401
    fresh, _, _ = login(client, user["username"])
    assert client.get("/auth/me", headers=fresh).status_code == 200


def test_token_extra_cannot_override_identity_and_revocation_claims(client):
    user = make_user()
    token = auth.create_token(user["id"], "patient", extra={"sub": "someone-else", "role": "admin",
        "sid": "unregistered", "session_version": 999, "exp": int(time.time()) + 100000})
    claims = auth.decode_token(token)
    assert claims["sub"] == user["id"] and claims["role"] == "patient"
    assert claims["sid"] != "unregistered" and claims["session_version"] == 0
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {token}"}).status_code == 200


def test_login_snapshot_cannot_survive_password_reset_between_verification_and_issuance(client, monkeypatch):
    user = make_user()
    original_create = account_sessions_store.create

    def reset_before_create(*args, **kwargs):
        users_store.set_password(user["id"], security.hash_password("replacement-session-password-123"))
        return original_create(*args, **kwargs)

    monkeypatch.setattr(account_sessions_store, "create", reset_before_create)
    response = client.post("/auth/login", json={"username": user["username"], "password": PASSWORD})
    assert response.status_code == 401
    with connection() as conn:
        assert conn.execute(select(account_sessions).where(account_sessions.c.user_id == user["id"])).first() is None


def test_session_revocation_and_audit_are_atomic(client, monkeypatch):
    user = make_user()
    headers, claims, _ = login(client, user["username"])
    register(client, headers, "atomic-revocation-push-token-1234567890")

    def failed_audit(*args, **kwargs):
        raise RuntimeError("injected audit failure")

    monkeypatch.setattr(users_store, "log", failed_audit)
    with pytest.raises(RuntimeError, match="injected audit failure"):
        client.post("/auth/logout", headers=headers)
    assert account_sessions_store.is_active(claims["sid"], user["id"], 0)
    assert push_tokens_store.tokens_for_alert(user["id"], ["patient"]) == ["atomic-revocation-push-token-1234567890"]


def test_frequent_session_checks_do_not_take_a_sqlite_write_for_activity(client):
    from sqlalchemy import event, update
    from app.database import get_engine
    user = make_user()
    headers, claims, _ = login(client, user['username'])
    statements = []
    def capture(conn, cursor, statement, parameters, context, executemany):
        if statement.startswith('UPDATE account_sessions'):
            statements.append(statement)
    engine = get_engine()
    event.listen(engine, 'before_cursor_execute', capture)
    try:
        for _ in range(3):
            assert client.get('/auth/sessions', headers=headers).status_code == 200
        assert statements == []
        with transaction() as conn:
            conn.execute(update(account_sessions).where(account_sessions.c.id == claims['sid']).values(last_seen_at='2000-01-01T00:00:00+00:00'))
        statements.clear()
        assert client.get('/auth/sessions', headers=headers).status_code == 200
        assert client.get('/auth/sessions', headers=headers).status_code == 200
        assert len(statements) == 1
    finally:
        event.remove(engine, 'before_cursor_execute', capture)


def test_token_refresh_succeeds_and_extends_active_session(client):
    user = make_user(username="refresh-success-user")
    headers, claims, token = login(client, user["username"])
    response = client.post("/auth/refresh", headers=headers)
    assert response.status_code == 200, response.text
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    assert data["expires_in"] > 0
    new_token = data["access_token"]
    new_claims = auth.decode_token(new_token)
    assert new_claims["sid"] == claims["sid"]
    assert new_claims["sub"] == user["id"]
    # New token can access protected endpoints
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {new_token}"}).status_code == 200


def test_token_refresh_works_for_expired_jwt_if_session_active(client):
    user = make_user(username="refresh-expired-jwt-user")
    headers, claims, token = login(client, user["username"])
    # Fabricate an expired JWT with the same valid sid and secret
    expired_payload = {
        "sub": user["id"],
        "role": user["role"],
        "sid": claims["sid"],
        "session_version": 0,
        "iat": int(time.time()) - 3600,
        "exp": int(time.time()) - 60,  # expired 1 minute ago
    }
    expired_token = auth.jwt.encode(expired_payload, auth.JWT_SECRET, algorithm=auth.JWT_ALG)
    # Protected endpoint rejects expired token
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {expired_token}"}).status_code == 401
    # But /auth/refresh accepts it because the DB session is still active
    refresh_response = client.post("/auth/refresh", headers={"Authorization": f"Bearer {expired_token}"})
    assert refresh_response.status_code == 200
    fresh_token = refresh_response.json()["access_token"]
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {fresh_token}"}).status_code == 200


def test_token_refresh_fails_if_session_revoked(client):
    user = make_user(username="refresh-revoked-session-user")
    headers, claims, token = login(client, user["username"])
    # Revoke session
    assert client.post("/auth/logout", headers=headers).status_code == 200
    # Refresh must fail
    refresh_response = client.post("/auth/refresh", headers=headers)
    assert refresh_response.status_code == 401
    assert "inactive or revoked" in refresh_response.json()["detail"]


def test_token_refresh_fails_if_password_changed(client):
    user = make_user(username="refresh-pw-changed-user")
    headers, claims, token = login(client, user["username"])
    # Change password (increments sessionVersion)
    client.post("/auth/password", headers=headers, json={
        "current_password": PASSWORD, "new_password": "new-session-password-1234"
    })
    # Old session refresh must fail
    refresh_response = client.post("/auth/refresh", headers=headers)
    assert refresh_response.status_code == 401


def test_token_refresh_fails_if_account_disabled(client):
    user = make_user(username="refresh-disabled-user")
    headers, claims, token = login(client, user["username"])
    users_store.set_disabled(user["id"], True)
    refresh_response = client.post("/auth/refresh", headers=headers)
    assert refresh_response.status_code == 401


def test_patient_login_hardware_binding_rejects_second_device_with_409(client):
    user = make_user(role="patient", username="hw-bound-patient-1")
    # Device A logs in successfully
    first_headers, first_claims, _ = login(client, user["username"], device_id="device-alpha")
    assert first_claims["role"] == "patient"

    # Device B attempts login -> rejected with 409 Conflict
    conflict_res = login_raw(client, user["username"], device_id="device-beta")
    assert conflict_res.status_code == 409
    assert conflict_res.json()["detail"] == "هذا الحساب مسجل ونشط حالياً على جهاز آخر. يرجى تسجيل الخروج من الجهاز السابق أولاً."

    # Login without device_id while hardware bound session is active -> also rejected with 409
    no_dev_res = login_raw(client, user["username"])
    assert no_dev_res.status_code == 409
    assert no_dev_res.json()["detail"] == "هذا الحساب مسجل ونشط حالياً على جهاز آخر. يرجى تسجيل الخروج من الجهاز السابق أولاً."


def test_caregiver_login_hardware_binding_rejects_second_device_with_409(client):
    user = make_user(role="caregiver", username="hw-bound-caregiver-1")
    # Caregiver Device 1 logs in
    first_headers, first_claims, _ = login(client, user["username"], device_id="caregiver-phone-1")
    assert first_claims["role"] == "caregiver"

    # Caregiver Device 2 attempts login -> 409 Conflict
    conflict_res = login_raw(client, user["username"], device_id="caregiver-phone-2")
    assert conflict_res.status_code == 409
    assert conflict_res.json()["detail"] == "هذا الحساب مسجل ونشط حالياً على جهاز آخر. يرجى تسجيل الخروج من الجهاز السابق أولاً."


def test_same_device_relogin_allowed(client):
    user = make_user(role="patient", username="same-dev-patient")
    # First login from device-persistent-uuid
    first_headers, first_claims, first_token = login(client, user["username"], device_id="persistent-uuid-42")
    assert client.get("/auth/me", headers=first_headers).status_code == 200

    # Same device logs in again -> allowed without 409 conflict
    second_headers, second_claims, second_token = login(client, user["username"], device_id="persistent-uuid-42")
    assert client.get("/auth/me", headers=second_headers).status_code == 200


def test_doctor_and_admin_not_restricted_by_single_device(client):
    doc = make_user(role="doctor", username="multi-doc-user")
    adm = make_user(role="admin", username="multi-adm-user")

    # Doctor logs in on workstation 1 and tablet 2
    d1_headers, _, _ = login(client, doc["username"], device_id="doc-pc-1")
    d2_headers, _, _ = login(client, doc["username"], device_id="doc-tablet-2")
    assert client.get("/auth/me", headers=d1_headers).status_code == 200
    assert client.get("/auth/me", headers=d2_headers).status_code == 200

    # Admin logs in on office PC and mobile
    a1_headers, _, _ = login(client, adm["username"], device_id="adm-office-1")
    a2_headers, _, _ = login(client, adm["username"], device_id="adm-mobile-2")
    assert client.get("/auth/me", headers=a1_headers).status_code == 200
    assert client.get("/auth/me", headers=a2_headers).status_code == 200


def test_logout_releases_hardware_binding_allowing_new_device(client):
    user = make_user(role="patient", username="logout-unbind-patient")
    headers, claims, _ = login(client, user["username"], device_id="old-hardware-id")

    # Second device blocked
    blocked = login_raw(client, user["username"], device_id="new-hardware-id")
    assert blocked.status_code == 409

    # Logout from old device
    logout_res = client.post("/auth/logout", headers=headers)
    assert logout_res.status_code == 200
    assert logout_res.json()["ok"] is True

    # Now second device can log in cleanly
    new_headers, new_claims, _ = login(client, user["username"], device_id="new-hardware-id")
    assert client.get("/auth/me", headers=new_headers).status_code == 200


def test_admin_revoke_user_sessions_endpoint(client):
    admin = make_user(role="admin", username="super-admin-user")
    patient = make_user(role="patient", username="lost-phone-patient")
    admin_headers, _, _ = login(client, admin["username"])

    # Patient logged into lost phone
    patient_headers, _, _ = login(client, patient["username"], device_id="lost-phone-uuid")

    # Replacement phone blocked by 409
    assert login_raw(client, patient["username"], device_id="replacement-phone-uuid").status_code == 409

    # Non-admin cannot call admin revoke-sessions
    assert client.post(f"/admin/users/{patient['id']}/revoke-sessions", headers=patient_headers).status_code == 403
    assert client.post(f"/admin/users/{patient['id']}/revoke-sessions").status_code == 401

    # Calling for non-existent user returns 404
    non_existent = client.post("/admin/users/non-existent-user-id/revoke-sessions", headers=admin_headers)
    assert non_existent.status_code == 404
    assert non_existent.json()["detail"] == "user not found"

    # Admin revokes patient sessions
    revoke_res = client.post(f"/admin/users/{patient['id']}/revoke-sessions", headers=admin_headers)
    assert revoke_res.status_code == 200
    assert revoke_res.json() == {"ok": True, "revoked": 1}

    # Old session is now invalid
    assert client.get("/auth/me", headers=patient_headers).status_code == 401

    # Replacement phone can now log in cleanly
    new_headers, _, _ = login(client, patient["username"], device_id="replacement-phone-uuid")
    assert client.get("/auth/me", headers=new_headers).status_code == 200


def test_list_sessions_includes_device_id_and_hardware_binding(client):
    user = make_user(role="patient", username="list-sessions-hw-user")
    headers, claims, _ = login(client, user["username"], device_id="device-inspect-123")
    res = client.get("/auth/sessions", headers=headers)
    assert res.status_code == 200
    data = res.json()
    assert len(data["sessions"]) >= 1
    session = data["sessions"][0]
    assert session["deviceId"] == "device-inspect-123"
    assert session["isHardwareBound"] is True


def test_baseline_compatibility_logins_without_device_id_work(client):
    user = make_user(role="patient", username="compat-no-device-id-user")
    # Two logins without device_id both succeed
    first, _, _ = login(client, user["username"])
    second, _, _ = login(client, user["username"])
    assert client.get("/auth/me", headers=first).status_code == 200
    assert client.get("/auth/me", headers=second).status_code == 200

