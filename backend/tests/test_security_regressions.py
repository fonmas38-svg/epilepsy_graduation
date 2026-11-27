"""Regression coverage for production configuration and malformed stored hashes."""
from dataclasses import replace
from pathlib import Path
import asyncio
import importlib

import pytest
from fastapi import HTTPException
from app import security


@pytest.mark.parametrize("iterations", ["0", "-1", "bad", "100000000000000000000"])
def test_corrupt_password_hash_fails_closed(iterations):
    assert security.verify_password("password", f"pbkdf2_sha256${iterations}$YQ==$Yg==") is False


def test_corrupt_rehash_metadata_is_handled():
    assert security.needs_rehash("pbkdf2_sha256$bad$a$b") is True


def test_production_validation_cannot_be_disabled(monkeypatch):
    settings_module = importlib.import_module("app.settings")
    monkeypatch.setattr(settings_module, "settings", replace(settings_module.settings,
        environment="production", jwt_secret="dev-only-change-me-in-production"))
    monkeypatch.setenv("STRICT_PRODUCTION_VALIDATION", "0")
    with pytest.raises(RuntimeError, match="JWT_SECRET"):
        settings_module.validate_production_settings()


def test_admin_static_route_rejects_escape():
    module = importlib.import_module("app.main")
    if not hasattr(module, "serve_admin_dashboard"):
        pytest.skip("Dashboard dist is absent")
    with pytest.raises(HTTPException) as exc:
        asyncio.run(module.serve_admin_dashboard("../../backend/app/settings.py"))
    assert exc.value.status_code == 404


def test_only_patient_or_device_writes_telemetry_and_pages_circle(monkeypatch):
    """A linked caregiver or doctor may read, but never forge readings or
    alerts that page the care circle."""
    from fastapi.testclient import TestClient
    from app import security
    from app.auth import create_token
    from app.main import app
    from app.settings import settings
    from app.users_store import assign_patient, create_user, link_caregiver

    from dataclasses import replace
    from app import auth as auth_module

    monkeypatch.setattr(
        auth_module, "settings", replace(settings, require_patient_auth=True)
    )
    pat = create_user(username="tw_pat", name="Real Name", role="patient",
                      password_hash=security.hash_password("pw123456"))
    doc = create_user(username="tw_doc", name="Doc", role="doctor",
                      password_hash=security.hash_password("pw123456"))
    cg = create_user(username="tw_cg", name="Cg", role="caregiver",
                     password_hash=security.hash_password("pw123456"))
    assign_patient(pat["id"], doc["id"])
    link_caregiver(pat["id"], cg["id"])
    h = lambda uid, role: {"Authorization": f"Bearer {create_token(uid, role)}"}
    reading = {"id": "r-tw", "patientId": pat["id"], "timestamp": "2026-11-27T10:00:00Z",
               "eeg": [0.1] * 8, "ecg": [0.1] * 8, "motion": [0.0] * 8, "hr": 70}
    body = {"patient_id": pat["id"], "reading": reading}
    alert = {"patient_id": pat["id"], "label": "high_risk", "confidence": 0.9,
             "should_notify": True, "severity": "critical",
             "message": "forged", "recipients": ["caregiver"]}
    with TestClient(app) as client:
        for uid, role in ((doc["id"], "doctor"), (cg["id"], "caregiver")):
            assert client.post("/cloud/sync", json=body, headers=h(uid, role)).status_code == 403
            assert client.post("/alerts/fcm-stub", json=alert, headers=h(uid, role)).status_code == 403
        ok = client.post("/cloud/sync", json=body, headers=h(pat["id"], "patient"))
        assert ok.status_code == 200
        # The patient's real name survives a sync.
        got = client.get(f"/cloud/patients/{pat['id']}", headers=h(pat["id"], "patient")).json()
        assert got["patient"].get("name") != pat["id"]


def test_failed_logins_from_one_place_do_not_lock_the_owner_elsewhere():
    """An attacker guessing a patient's password must not lock the patient out
    of their monitoring app; the guesser's own address is what gets blocked."""
    from fastapi import HTTPException
    import pytest
    from app.routers import accounts

    accounts._FAILED_PAIR_ATTEMPTS.clear()
    accounts._FAILED_USER_ATTEMPTS.clear()
    accounts._FAILED_IP_ATTEMPTS.clear()
    for _ in range(accounts._MAX_FAILED_ATTEMPTS):
        accounts._record_failed_attempt("victim", "10.0.0.66")
    with pytest.raises(HTTPException) as blocked:
        accounts._check_rate_limit("victim", "10.0.0.66")
    assert blocked.value.status_code == 429
    # The real owner, from their own phone, can still sign in.
    accounts._check_rate_limit("victim", "10.0.0.7")
