"""Tests for doctor prescribing, patient/caregiver reading, and prescription lifecycle."""
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
    """Create a linked patient, doctor, caregiver, and unlinked patient."""
    doc = create_user(
        username="rx_doc",
        name="Dr. Neurologist",
        role="doctor",
        password_hash=security.hash_password("password123"),
    )
    pat = create_user(
        username="rx_pat",
        name="Patient Ali",
        role="patient",
        password_hash=security.hash_password("password123"),
    )
    pat_unlinked = create_user(
        username="rx_unlinked_pat",
        name="Patient Other",
        role="patient",
        password_hash=security.hash_password("password123"),
    )
    cg = create_user(
        username="rx_cg",
        name="Caregiver Fatima",
        role="caregiver",
        password_hash=security.hash_password("password123"),
    )
    assign_patient(pat["id"], doc["id"])
    link_caregiver(pat["id"], cg["id"])

    doc_token = create_token(doc["id"], "doctor", extra={"name": doc["name"]})
    pat_token = create_token(pat["id"], "patient", extra={"name": pat["name"]})
    pat_unlinked_token = create_token(pat_unlinked["id"], "patient", extra={"name": pat_unlinked["name"]})
    cg_token = create_token(cg["id"], "caregiver", extra={"name": cg["name"]})

    return {
        "doc": doc, "pat": pat, "pat_unlinked": pat_unlinked, "cg": cg,
        "doc_token": doc_token, "pat_token": pat_token,
        "pat_unlinked_token": pat_unlinked_token, "cg_token": cg_token,
    }


def test_prescription_lifecycle_and_patient_access(client, test_setup):
    doc_token = test_setup["doc_token"]
    pat_token = test_setup["pat_token"]
    cg_token = test_setup["cg_token"]
    pat_id = test_setup["pat"]["id"]
    unlinked_token = test_setup["pat_unlinked_token"]

    # 1. Doctor prescribes a medication
    res = client.post(
        f"/doctor/patients/{pat_id}/prescriptions",
        headers={"Authorization": f"Bearer {doc_token}"},
        json={
            "name": "Levetiracetam (Keppra)",
            "dose": "500mg",
            "schedule": "مرتين يومياً بعد الأكل",
            "notes": "تناول الجرعة بانتظام دون انقطاع",
        },
    )
    assert res.status_code == 201
    rx = res.json()["prescription"]
    rx_id = rx["id"]
    assert rx["name"] == "Levetiracetam (Keppra)"
    assert rx["active"] is True

    # 2. Patient can view their prescriptions via /patient/prescriptions
    res_pat = client.get(
        "/patient/prescriptions",
        headers={"Authorization": f"Bearer {pat_token}"},
    )
    assert res_pat.status_code == 200
    prescriptions = res_pat.json()["prescriptions"]
    assert len(prescriptions) == 1
    assert prescriptions[0]["id"] == rx_id

    # 3. Patient can view via /patients/{id}/prescriptions
    res_pat2 = client.get(
        f"/patients/{pat_id}/prescriptions",
        headers={"Authorization": f"Bearer {pat_token}"},
    )
    assert res_pat2.status_code == 200
    assert len(res_pat2.json()["prescriptions"]) == 1

    # 4. Caregiver can view their linked patient's prescriptions
    res_cg = client.get(
        "/patient/prescriptions",
        headers={"Authorization": f"Bearer {cg_token}"},
    )
    assert res_cg.status_code == 200
    assert len(res_cg.json()["prescriptions"]) == 1

    # 5. Unlinked patient CANNOT view another patient's prescriptions
    res_unauth = client.get(
        f"/patients/{pat_id}/prescriptions",
        headers={"Authorization": f"Bearer {unlinked_token}"},
    )
    assert res_unauth.status_code == 403

    # 6. Automatic message was created in the doctor-patient channel
    res_msg = client.get(
        f"/patients/{pat_id}/messages?channel_type=doctor_patient",
        headers={"Authorization": f"Bearer {pat_token}"},
    )
    assert res_msg.status_code == 200
    msgs = res_msg.json()["messages"]
    assert any("Levetiracetam" in m["content"] for m in msgs)

    # 7. Doctor updates the prescription dose
    res_up = client.patch(
        f"/doctor/patients/{pat_id}/prescriptions/{rx_id}",
        headers={"Authorization": f"Bearer {doc_token}"},
        json={"dose": "750mg"},
    )
    assert res_up.status_code == 200
    assert res_up.json()["prescription"]["dose"] == "750mg"

    # 8. Doctor cancels/stops the prescription
    res_del = client.delete(
        f"/doctor/patients/{pat_id}/prescriptions/{rx_id}",
        headers={"Authorization": f"Bearer {doc_token}"},
    )
    assert res_del.status_code == 200
    assert res_del.json()["prescription"]["active"] is False
