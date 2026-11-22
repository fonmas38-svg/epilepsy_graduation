"""Phase 4 backend verification: MOH license verification, doctor profiles, idempotency keys, optional email, and doctor dashboard summary."""
from __future__ import annotations

from fastapi.testclient import TestClient

from app import users_store
from app.auth import create_token
from app.main import app


def _admin_headers() -> dict[str, str]:
    admins = users_store.list_users(role="admin")
    if not admins:
        users_store.seed_admin()
        admins = users_store.list_users(role="admin")
    admin = admins[0]
    token = create_token(admin["id"], "admin", extra={"username": admin["username"]})
    return {"Authorization": f"Bearer {token}"}


def test_verify_moh_active_not_found_suspended_and_mismatch():
    client = TestClient(app)
    headers = _admin_headers()

    # 1. Active seeded license MOH-100200
    r_ok = client.post(
        "/admin/doctors/verify-moh",
        headers=headers,
        json={"license_number": "MOH-100200", "national_id": "1010101010"},
    )
    assert r_ok.status_code == 200
    body_ok = r_ok.json()
    assert body_ok["verified"] is True
    assert body_ok["status"] == "active"

    # 2. National ID mismatch
    r_mismatch = client.post(
        "/admin/doctors/verify-moh",
        headers=headers,
        json={"license_number": "MOH-100200", "national_id": "9999999999"},
    )
    assert r_mismatch.status_code == 200
    assert r_mismatch.json()["verified"] is False
    assert r_mismatch.json()["status"] == "mismatch"

    # 3. Suspended license MOH-999000
    r_susp = client.post(
        "/admin/doctors/verify-moh",
        headers=headers,
        json={"license_number": "MOH-999000"},
    )
    assert r_susp.status_code == 200
    assert r_susp.json()["verified"] is False
    assert r_susp.json()["status"] == "suspended"

    # 4. Unknown license
    r_miss = client.post(
        "/admin/doctors/verify-moh",
        headers=headers,
        json={"license_number": "MOH-UNKNOWN-404"},
    )
    assert r_miss.status_code == 200
    assert r_miss.json()["verified"] is False
    assert r_miss.json()["status"] == "not_found"


def test_create_doctor_with_moh_verification_override_and_idempotency():
    client = TestClient(app)
    headers = _admin_headers()

    # Unverified license without moh_override -> rejected 422
    r_reject = client.post(
        "/admin/doctors",
        headers=headers,
        json={
            "username": "dr_unverified_1",
            "name": "د. طارق غير مسجل",
            "password": "password123",
            "email": "tareq@hospital.sa",
            "phone": "+966500001111",
            "license_number": "MOH-UNLISTED-77",
            "specialization": "أعصاب",
            "hospital_affiliation": "مستشفى التخصصي",
            "national_id": "1077777771",
            "moh_override": False,
        },
    )
    assert r_reject.status_code == 422

    # Same unverified license WITH moh_override=True + idempotency_key -> succeeds 201
    idem_key = "idem-doc-override-77"
    payload = {
        "username": "dr_unverified_1",
        "name": "د. طارق غير مسجل",
        "password": "password123",
        "email": "tareq@hospital.sa",
        "phone": "+966500001111",
        "license_number": "MOH-UNLISTED-77",
        "specialization": "أعصاب",
        "hospital_affiliation": "مستشفى التخصصي",
        "national_id": "1077777771",
        "moh_override": True,
        "idempotency_key": idem_key,
    }
    r_create = client.post("/admin/doctors", headers=headers, json=payload)
    assert r_create.status_code == 201
    doc_user = r_create.json()["user"]
    assert doc_user["email"] == "tareq@hospital.sa"
    assert doc_user["doctorProfile"]["licenseNumber"] == "MOH-UNLISTED-77"
    assert doc_user["doctorProfile"]["mohVerified"] is False
    assert doc_user["doctorProfile"]["mohOverrideBy"] is not None

    # Re-sending identical request with same idempotency_key returns cached result instead of 409
    r_retry = client.post("/admin/doctors", headers=headers, json=payload)
    assert r_retry.status_code in (200, 201)
    assert r_retry.json()["user"]["id"] == doc_user["id"]


def test_patient_creation_idempotency_and_doctor_dashboard_summary():
    client = TestClient(app)
    headers = _admin_headers()

    # Create a doctor
    r_doc = client.post(
        "/admin/doctors",
        headers=headers,
        json={"username": "dr_summary_doc", "name": "د. مازن العتيبي", "password": "password123"},
    )
    assert r_doc.status_code == 201
    doc_id = r_doc.json()["user"]["id"]
    doc_token = create_token(doc_id, "doctor", extra={"username": "dr_summary_doc"})
    doc_headers = {"Authorization": f"Bearer {doc_token}"}

    pat_payload = {
        "username": "pat_idem_summary_1",
        "name": "سلمان القحطاني",
        "password": "password123",
        "email": "salman@patient.sa",
        "phone": "+966511112222",
        "age": 29,
        "gender": "male",
        "emergency_contact": "+966533334444",
        "diagnosis": "صرع بؤري",
        "idempotency_key": "idem-pat-summary-1",
    }
    r1 = client.post("/doctor/patients", headers=doc_headers, json=pat_payload)
    assert r1.status_code == 201
    pat_id = r1.json()["user"]["id"]
    assert r1.json()["user"]["email"] == "salman@patient.sa"

    # Retry with same idempotency_key does not throw 409 Conflict
    r2 = client.post("/doctor/patients", headers=doc_headers, json=pat_payload)
    assert r2.status_code in (200, 201)
    assert r2.json()["user"]["id"] == pat_id

    # Verify /doctor/dashboard-summary
    r_sum = client.get("/doctor/dashboard-summary", headers=doc_headers)
    assert r_sum.status_code == 200
    summary = r_sum.json()
    assert summary["totalPatients"] >= 1
    assert any(p["id"] == pat_id for p in summary["patients"])
