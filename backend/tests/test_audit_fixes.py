"""Security/atomicity regressions from the October audit (temporary stores only)."""
from dataclasses import replace
import importlib

import pytest
from fastapi.testclient import TestClient

from app import cloud_store, security, users_store
from app.auth import create_token
from app.main import app


def account(name, role):
    return users_store.create_user(username=name, name=name, role=role,
                                   password_hash=security.hash_password("test-password"))


def headers(user):
    return {"Authorization": "Bearer " + create_token(user["id"], user["role"])}


def test_production_seed_has_no_demo_accounts_even_outside_pytest(monkeypatch):
    monkeypatch.setenv("APP_ENV", "production")
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    users_store.seed_admin()
    assert users_store.get_by_username("admin")
    for name in ("doctor", "patient", "caregiver"):
        assert users_store.get_by_username(name) is None
    with pytest.raises(RuntimeError, match="forbidden"):
        users_store.seed_demo_accounts()


def test_existing_default_credentials_block_production(monkeypatch):
    monkeypatch.setenv("APP_ENV", "demo")
    users_store.seed_demo_accounts()
    monkeypatch.setenv("APP_ENV", "production")
    with pytest.raises(RuntimeError, match="Default credentials"):
        users_store.seed_admin()


def test_cannot_link_admin_as_caregiver_or_leave_partial_patient():
    doctor = account("audit-doctor", "doctor")
    admin = account("audit-admin", "admin")
    with TestClient(app, raise_server_exceptions=False) as client:
        result = client.post("/doctor/patients", headers=headers(doctor), json={
            "username": "new-patient", "name": "Patient", "password": "test-password",
            "caregiver_name": "Caregiver", "caregiver_username": admin["username"],
        })
        assert result.status_code == 409
        assert users_store.get_by_username("new-patient") is None
    patient = account("patient-for-link", "patient")
    with pytest.raises(ValueError, match="caregiver"):
        users_store.link_caregiver(patient["id"], admin["id"])


def test_caregiver_disable_is_scoped_to_relationship(monkeypatch):
    auth_module = importlib.import_module("app.auth")
    monkeypatch.setattr(auth_module, "settings", replace(auth_module.settings, require_patient_auth=True))
    p1, p2 = account("patient-one", "patient"), account("patient-two", "patient")
    caregiver = account("shared-caregiver", "caregiver")
    for p in (p1, p2):
        users_store.link_caregiver(p["id"], caregiver["id"])
    # Even legacy metadata cannot resurrect a disabled relationship.
    users_store.update_user(caregiver["id"], {"meta": {"linkedPatientIds": [p1["id"]]}})
    with TestClient(app) as client:
        path = f"/patient/caregivers/{caregiver['id']}"
        assert client.post(path + "/disable", headers=headers(p1)).status_code == 200
        assert not users_store.get_user(caregiver["id"])["disabled"]
        assert not users_store.is_caregiver_linked(p1["id"], caregiver["id"])
        assert users_store.is_caregiver_linked(p2["id"], caregiver["id"])
        assert client.get(f"/cloud/patients/{p1['id']}", headers=headers(caregiver)).status_code == 403
        rows = client.get("/patient/caregivers", headers=headers(p1)).json()["caregivers"]
        assert rows[0]["disabled"] is True
        assert client.post(path + "/enable", headers=headers(p1)).status_code == 200
        assert users_store.is_caregiver_linked(p1["id"], caregiver["id"])


def test_patient_creation_with_clinical_fields_is_atomic(monkeypatch):
    doctor = account("clinical-doctor", "doctor")
    payload = {"username": "clinical-patient", "name": "Patient", "diagnosis": "Recorded diagnosis",
               "phone": "123456", "age": 30, "notes": "Recorded notes", "password": "test-password"}
    with TestClient(app, raise_server_exceptions=False) as client:
        result = client.post("/doctor/patients", headers=headers(doctor), json=payload)
        assert result.status_code == 201, result.text
        patient = result.json()["user"]
        assert users_store.is_assigned(patient["id"], doctor["id"])
        assert cloud_store.get_patient(patient["id"])["diagnosis"] == payload["diagnosis"]
        def fail(*args, **kwargs):
            raise RuntimeError("injected storage failure")
        monkeypatch.setattr(users_store, "assign_patient", fail)
        failed = client.post("/doctor/patients", headers=headers(doctor), json={
            **payload, "username": "rolled-back-patient", "caregiver_name": "Rollback caregiver",
            "caregiver_username": "rolled-back-caregiver",
        })
        assert failed.status_code == 500
        assert users_store.get_by_username("rolled-back-patient") is None
        assert users_store.get_by_username("rolled-back-caregiver") is None
        assert len(cloud_store.list_patients()) == 1
