"""Tests for clinical and family messaging channels and location sharing."""
import pytest
from fastapi.testclient import TestClient

from app.auth import create_token
from app.main import app
from app.users_store import create_user, assign_patient, link_caregiver
from app import security


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def test_setup():
    """Create a linked patient, doctor, and caregiver."""
    doc = create_user(
        username="test_doc",
        name="Dr. Test",
        role="doctor",
        password_hash=security.hash_password("password123"),
    )
    pat = create_user(
        username="test_pat",
        name="Patient Test",
        role="patient",
        password_hash=security.hash_password("password123"),
    )
    cg = create_user(
        username="test_cg",
        name="Caregiver Test",
        role="caregiver",
        password_hash=security.hash_password("password123"),
    )
    assign_patient(pat["id"], doc["id"])
    link_caregiver(pat["id"], cg["id"])

    doc_token = create_token(doc["id"], "doctor", extra={"name": doc["name"]})
    pat_token = create_token(pat["id"], "patient", extra={"name": pat["name"]})
    cg_token = create_token(cg["id"], "caregiver", extra={"name": cg["name"]})

    return {
        "doc": doc, "pat": pat, "cg": cg,
        "doc_token": doc_token, "pat_token": pat_token, "cg_token": cg_token,
    }


def test_doctor_patient_private_messaging(client, test_setup):
    pat_id = test_setup["pat"]["id"]
    pat_headers = {"Authorization": f"Bearer {test_setup['pat_token']}"}
    doc_headers = {"Authorization": f"Bearer {test_setup['doc_token']}"}
    cg_headers = {"Authorization": f"Bearer {test_setup['cg_token']}"}

    # 1. Patient sends private directive/message to doctor
    res = client.post(
        f"/patients/{pat_id}/messages",
        headers=pat_headers,
        json={"channel_type": "doctor_patient", "content": "Doctor, I took my Keppra at 8pm."},
    )
    assert res.status_code == 201
    msg_id = res.json()["message"]["id"]
    assert res.json()["message"]["channelType"] == "doctor_patient"

    # 2. Doctor can read this message
    res = client.get(
        f"/patients/{pat_id}/messages?channel_type=doctor_patient",
        headers=doc_headers,
    )
    assert res.status_code == 200
    msgs = res.json()["messages"]
    assert any(m["id"] == msg_id for m in msgs)

    # 3. Doctor replies to patient
    res = client.post(
        f"/patients/{pat_id}/messages",
        headers=doc_headers,
        json={"channel_type": "doctor_patient", "content": "Good. Continue on this dosage."},
    )
    assert res.status_code == 201

    # 4. PRIVACY CHECK: Caregiver is FORBIDDEN from reading doctor_patient channel!
    res = client.get(
        f"/patients/{pat_id}/messages?channel_type=doctor_patient",
        headers=cg_headers,
    )
    assert res.status_code == 403

    # 5. PRIVACY CHECK: Caregiver is FORBIDDEN from sending to doctor_patient channel!
    res = client.post(
        f"/patients/{pat_id}/messages",
        headers=cg_headers,
        json={"channel_type": "doctor_patient", "content": "Can I read this?"},
    )
    assert res.status_code == 403


def test_family_patient_messaging(client, test_setup):
    pat_id = test_setup["pat"]["id"]
    pat_headers = {"Authorization": f"Bearer {test_setup['pat_token']}"}
    cg_headers = {"Authorization": f"Bearer {test_setup['cg_token']}"}

    # Caregiver sends message to patient
    res = client.post(
        f"/patients/{pat_id}/messages",
        headers=cg_headers,
        json={"channel_type": "family_patient", "content": "How are you feeling right now?"},
    )
    assert res.status_code == 201
    msg_id = res.json()["message"]["id"]

    # Patient reads family messages
    res = client.get(
        f"/patients/{pat_id}/messages?channel_type=family_patient",
        headers=pat_headers,
    )
    assert res.status_code == 200
    assert any(m["id"] == msg_id for m in res.json()["messages"])

    # Caregiver reads family messages
    res = client.get(
        f"/patients/{pat_id}/messages",
        headers=cg_headers,
    )
    assert res.status_code == 200
    assert any(m["id"] == msg_id for m in res.json()["messages"])


def test_location_sharing(client, test_setup):
    pat_id = test_setup["pat"]["id"]
    pat_headers = {"Authorization": f"Bearer {test_setup['pat_token']}"}
    cg_headers = {"Authorization": f"Bearer {test_setup['cg_token']}"}

    # Patient shares current location
    res = client.post(
        f"/patients/{pat_id}/location",
        headers=pat_headers,
        json={"latitude": 24.7136, "longitude": 46.6753, "accuracy": 10.5, "note": "At university"},
    )
    assert res.status_code == 200
    loc = res.json()["location"]
    assert loc["latitude"] == 24.7136
    assert "maps.google.com" in loc["mapsUrl"]

    # Caregiver retrieves latest location
    res = client.get(
        f"/patients/{pat_id}/location",
        headers=cg_headers,
    )
    assert res.status_code == 200
    retrieved = res.json()["location"]
    assert retrieved["latitude"] == 24.7136
    assert retrieved["longitude"] == 46.6753

    # An auto-broadcast message should be in family_patient channel
    res = client.get(
        f"/patients/{pat_id}/messages?channel_type=family_patient",
        headers=cg_headers,
    )
    assert res.status_code == 200
    assert any("قام" in m["content"] and "موقعه" in m["content"] for m in res.json()["messages"])
