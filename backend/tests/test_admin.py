"""Tests for the account-management system (login + admin/doctor RBAC).

Uses TestClient(app) exactly like test_api.py. The autouse fixture in
conftest.py isolates the users store to a temp file and seeds a known-password
admin, so these tests are hermetic and never touch real data.
"""
from tests.account_payloads import doctor_payload, patient_payload
import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def _login(client, username, password):
    r = client.post("/auth/login", json={"username": username, "password": password, "device_id": "test-installation"})
    assert r.status_code == 200, r.text
    return r.json()


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def test_admin_login_and_me(client):
    body = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)
    assert body["role"] == "admin"
    token = body["access_token"]
    me = client.get("/auth/me", headers=_auth(token))
    assert me.status_code == 200
    assert me.json()["user"]["role"] == "admin"
    assert "passwordHash" not in me.json()["user"]
    assert me.json()["patients"] == []


def test_me_returns_only_patients_accessible_to_account(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    doctor_body = client.post(
        "/admin/doctors",
        json=doctor_payload({"username": "dr_context", "name": "Context Doctor"}),
        headers=_auth(admin),
    ).json()
    doctor_id = doctor_body["user"]["id"]
    doctor = _login(client, "dr_context", doctor_body["generatedPassword"])["access_token"]

    assigned = client.post(
        "/doctor/patients",
        json=patient_payload({"username": "context_patient", "name": "Assigned", "password": "secret123"}),
        headers=_auth(doctor),
    ).json()["user"]
    unassigned = client.post(
        "/admin/patients",
        json=patient_payload({"username": "other_patient", "name": "Other", "password": "secret123"}),
        headers=_auth(admin),
    ).json()["user"]
    caregiver = client.post(
        "/admin/users",
        json={"username": "context_carer", "name": "Carer", "role": "caregiver",
              "password": "secret123"},
        headers=_auth(admin),
    ).json()["user"]
    client.post(
        "/admin/caregiver-links",
        json={"patient_id": assigned["id"], "caregiver_id": caregiver["id"]},
        headers=_auth(admin),
    )

    doctor_me = client.get("/auth/me", headers=_auth(doctor)).json()
    assert [p["id"] for p in doctor_me["patients"]] == [assigned["id"]]
    assert doctor_me["patients"][0]["doctorIds"] == [doctor_id]
    assert doctor_me["patients"][0]["caregiverIds"] == [caregiver["id"]]
    assert unassigned["id"] not in {p["id"] for p in doctor_me["patients"]}

    caregiver_token = _login(client, "context_carer", "secret123")["access_token"]
    caregiver_me = client.get("/auth/me", headers=_auth(caregiver_token)).json()
    assert [p["id"] for p in caregiver_me["patients"]] == [assigned["id"]]

    patient_token = _login(client, "context_patient", "secret123")["access_token"]
    patient_me = client.get("/auth/me", headers=_auth(patient_token)).json()
    assert [p["id"] for p in patient_me["patients"]] == [assigned["id"]]


def test_admin_bad_password_rejected(client):
    r = client.post("/auth/login", json={"username": TEST_ADMIN_USERNAME, "password": "wrong", "device_id": "test-installation"})
    assert r.status_code == 401


def test_admin_creates_doctor_who_can_login(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    r = client.post(
        "/admin/doctors",
        json=doctor_payload({"username": "dr_house", "name": "Dr House"}),
        headers=_auth(admin),
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["user"]["role"] == "doctor"
    # no explicit password was given → server returns a one-time password
    pw = body["generatedPassword"]
    assert pw
    login = _login(client, "dr_house", pw)
    assert login["role"] == "doctor"


def test_doctor_creates_patient_auto_assigned(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    dr_pw = client.post(
        "/admin/doctors",
        json=doctor_payload({"username": "dr_a", "name": "Doctor A"}),
        headers=_auth(admin),
    ).json()["generatedPassword"]
    doctor = _login(client, "dr_a", dr_pw)["access_token"]

    created = client.post(
        "/doctor/patients",
        json=patient_payload({"username": "patient_x", "name": "Patient X", "password": "secret123"}),
        headers=_auth(doctor),
    )
    assert created.status_code == 201, created.text
    patient_id = created.json()["user"]["id"]

    # the patient shows up in the doctor's own list
    mine = client.get("/doctor/patients", headers=_auth(doctor))
    assert mine.status_code == 200
    assert any(p["id"] == patient_id for p in mine.json()["patients"])


def test_admin_assigns_patient_to_another_doctor(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    dr_a_pw = client.post(
        "/admin/doctors", json=doctor_payload({"username": "dr_a", "name": "A"}), headers=_auth(admin)
    ).json()["generatedPassword"]
    dr_b = client.post(
        "/admin/doctors", json=doctor_payload({"username": "dr_b", "name": "B"}), headers=_auth(admin)
    ).json()["user"]
    doctor_a = _login(client, "dr_a", dr_a_pw)["access_token"]

    patient_id = client.post(
        "/doctor/patients",
        json=patient_payload({"username": "pat1", "name": "Pat One", "password": "secret123"}),
        headers=_auth(doctor_a),
    ).json()["user"]["id"]

    # admin assigns that patient to doctor B as well
    r = client.post(
        "/admin/assignments",
        json={"patient_id": patient_id, "doctor_id": dr_b["id"]},
        headers=_auth(admin),
    )
    assert r.status_code == 201, r.text

    dr_b_pw = client.post(
        "/admin/users/" + dr_b["id"] + "/password", json={}, headers=_auth(admin)
    ).json()["generatedPassword"]
    doctor_b = _login(client, "dr_b", dr_b_pw)["access_token"]
    b_patients = client.get("/doctor/patients", headers=_auth(doctor_b)).json()["patients"]
    assert any(p["id"] == patient_id for p in b_patients)


def test_rbac_doctor_cannot_create_doctor(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    dr_pw = client.post(
        "/admin/doctors", json=doctor_payload({"username": "dr_c", "name": "C"}), headers=_auth(admin)
    ).json()["generatedPassword"]
    doctor = _login(client, "dr_c", dr_pw)["access_token"]
    r = client.post(
        "/admin/doctors",
        json=doctor_payload({"username": "dr_sneaky", "name": "Sneaky"}),
        headers=_auth(doctor),
    )
    assert r.status_code == 403


def test_rbac_patient_cannot_reach_admin(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    created = client.post(
        "/admin/patients",
        json=patient_payload({"username": "pat_only", "name": "Pat", "password": "secret123"}),
        headers=_auth(admin),
    )
    assert created.status_code == 201
    patient = _login(client, "pat_only", "secret123")["access_token"]
    r = client.get("/admin/overview", headers=_auth(patient))
    assert r.status_code == 403


def test_doctor_cannot_view_unassigned_patient(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    # patient created by admin, assigned to nobody
    pid = client.post(
        "/admin/patients",
        json=patient_payload({"username": "orphan", "name": "Orphan", "password": "secret123"}),
        headers=_auth(admin),
    ).json()["user"]["id"]
    dr_pw = client.post(
        "/admin/doctors", json=doctor_payload({"username": "dr_d", "name": "D"}), headers=_auth(admin)
    ).json()["generatedPassword"]
    doctor = _login(client, "dr_d", dr_pw)["access_token"]
    r = client.get(f"/doctor/patients/{pid}", headers=_auth(doctor))
    assert r.status_code == 403


def test_duplicate_username_conflicts(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    first = client.post(
        "/admin/doctors", json=doctor_payload({"username": "dup", "name": "One"}), headers=_auth(admin)
    )
    assert first.status_code == 201
    second = client.post(
        "/admin/doctors", json=doctor_payload({"username": "dup", "name": "Two"}), headers=_auth(admin)
    )
    assert second.status_code == 409


def test_admin_cannot_disable_self(client):
    body = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)
    admin = body["access_token"]
    admin_id = body["user"]["id"]
    r = client.post(f"/admin/users/{admin_id}/disable", headers=_auth(admin))
    assert r.status_code == 400


def test_disabled_user_cannot_login(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    doc = client.post(
        "/admin/doctors", json=doctor_payload({"username": "dr_e", "name": "E"}), headers=_auth(admin)
    ).json()
    doc_id = doc["user"]["id"]
    pw = doc["generatedPassword"]
    assert client.post(f"/admin/users/{doc_id}/disable", headers=_auth(admin)).status_code == 200
    r = client.post("/auth/login", json={"username": "dr_e", "password": pw, "device_id": "test-installation"})
    assert r.status_code == 403


def test_admin_overview_counts(client):
    admin = _login(client, TEST_ADMIN_USERNAME, TEST_ADMIN_PASSWORD)["access_token"]
    client.post("/admin/doctors", json=doctor_payload({"username": "dr_f", "name": "F"}), headers=_auth(admin))
    ov = client.get("/admin/overview", headers=_auth(admin))
    assert ov.status_code == 200
    counts = ov.json()["counts"]
    assert counts["byRole"]["admin"] >= 1
    assert counts["byRole"]["doctor"] >= 1
