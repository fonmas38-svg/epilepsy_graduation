"""Phase 5 & Phase 6 backend verification: Care Circle 4-channel messaging, read receipts, outcomes optimistic locking, and prescription adherence sync."""
from __future__ import annotations

from fastapi.testclient import TestClient

from app import users_store
from app.auth import create_token
from app.main import app


def _setup_care_circle(client: TestClient):
    admins = users_store.list_users(role="admin")
    if not admins:
        users_store.seed_admin()
        admins = users_store.list_users(role="admin")
    admin = admins[0]
    admin_headers = {
        "Authorization": f"Bearer {create_token(admin['id'], 'admin', extra={'username': admin['username']})}"
    }

    r_doc = client.post(
        "/admin/doctors",
        headers=admin_headers,
        json={"username": "dr_p5_care", "name": "د. عادل الشهري", "password": "password123"},
    )
    assert r_doc.status_code in (200, 201)
    doc_id = r_doc.json()["user"]["id"]
    doc_headers = {
        "Authorization": f"Bearer {create_token(doc_id, 'doctor', extra={'username': 'dr_p5_care'})}"
    }

    r_pat = client.post(
        "/doctor/patients",
        headers=doc_headers,
        json={
            "username": "pat_p5_care",
            "name": "نواف الحربي",
            "password": "password123",
            "caregiver_name": "فهد الحربي",
            "caregiver_username": "cg_p5_care",
            "caregiver_password": "password123",
            "caregiver_relation": "أب / ولي أمر",
        },
    )
    assert r_pat.status_code in (200, 201)
    pat_id = r_pat.json()["user"]["id"]
    cg_id = r_pat.json()["caregiver"]["id"]

    pat_headers = {
        "Authorization": f"Bearer {create_token(pat_id, 'patient', extra={'username': 'pat_p5_care'})}",
    }
    cg_headers = {
        "Authorization": f"Bearer {create_token(cg_id, 'caregiver', extra={'username': 'cg_p5_care'})}",
    }
    return pat_id, doc_id, cg_id, pat_headers, doc_headers, cg_headers


def test_care_circle_five_channels_rbac_and_read_receipts():
    client = TestClient(app)
    pat_id, doc_id, cg_id, pat_headers, doc_headers, cg_headers = _setup_care_circle(client)

    # 1. Caregiver blocked from private doctor_patient
    r_forbid1 = client.post(
        f"/patients/{pat_id}/messages",
        headers=cg_headers,
        json={"channel_type": "doctor_patient", "content": "Forbidden peek"},
    )
    assert r_forbid1.status_code == 403

    # 2. Patient blocked from private doctor_caregiver
    r_forbid2 = client.post(
        f"/patients/{pat_id}/messages",
        headers=pat_headers,
        json={"channel_type": "doctor_caregiver", "content": "Forbidden peek"},
    )
    assert r_forbid2.status_code == 403

    # 3. Doctor blocked from private patient_caregiver
    r_forbid3 = client.post(
        f"/patients/{pat_id}/messages",
        headers=doc_headers,
        json={"channel_type": "patient_caregiver", "content": "Forbidden peek"},
    )
    assert r_forbid3.status_code == 403

    # 4. Doctor sends to doctor_caregiver with peer_user_id=cg_id
    r_dc = client.post(
        f"/patients/{pat_id}/messages",
        headers=doc_headers,
        json={
            "channel_type": "doctor_caregiver",
            "peer_user_id": cg_id,
            "content": "يرجى مراقبة الجرعة المسائية",
        },
    )
    assert r_dc.status_code == 201
    msg_dc = r_dc.json()["message"]
    assert msg_dc["channelType"] == "doctor_caregiver"
    assert msg_dc["peerUserId"] == cg_id
    assert msg_dc["deliveredAt"] is not None
    assert msg_dc["readAt"] is None

    # 5. Caregiver marks doctor_caregiver as read
    r_read = client.post(
        f"/patients/{pat_id}/messages/read",
        headers=cg_headers,
        json={"channel_type": "doctor_caregiver"},
    )
    assert r_read.status_code == 200
    assert r_read.json()["updated"] >= 1

    r_list = client.get(
        f"/patients/{pat_id}/messages?channel_type=doctor_caregiver",
        headers=doc_headers,
    )
    assert r_list.status_code == 200
    assert r_list.json()["messages"][0]["readAt"] is not None

    # 6. Care Team Triage ("دائرة الرعاية") group channel accessible to all 3 roles
    for hdrs in (doc_headers, pat_headers, cg_headers):
        r_grp = client.post(
            f"/patients/{pat_id}/messages",
            headers=hdrs,
            json={"channel_type": "care_team_triage", "content": "تحديث في دائرة الرعاية"},
        )
        assert r_grp.status_code == 201


def test_outcomes_optimistic_version_locking_and_conflict():
    client = TestClient(app)
    from app import cloud_store

    pat_id, doc_id, cg_id, pat_headers, doc_headers, cg_headers = _setup_care_circle(client)
    alert = cloud_store.add_alert(
        pat_id,
        {
            "id": "alert-p5-lock-1",
            "patientId": pat_id,
            "timestamp": "2026-11-22T12:00:00Z",
            "severity": "critical",
            "message": "Critical EEG spike",
            "recipients": ["doctor"],
        },
    )
    assert alert["id"] == "alert-p5-lock-1"

    # First adjudication -> version 1
    r1 = client.post(
        f"/patients/{pat_id}/outcomes",
        headers=doc_headers,
        json={
            "outcome": "seizure",
            "occurred_at": "2026-11-22T12:00:00Z",
            "alert_id": "alert-p5-lock-1",
            "seizure_type": "focal",
            "notes": "Confirmed focal ictal discharge",
        },
    )
    assert r1.status_code == 201
    assert r1.json()["outcome"]["version"] == 1
    assert r1.json()["outcome"]["seizure_type"] == "focal"

    # Concurrent adjudication for same alert_id without expected_version -> 409 Conflict
    r_conflict = client.post(
        f"/patients/{pat_id}/outcomes",
        headers=doc_headers,
        json={
            "outcome": "false_alarm",
            "occurred_at": "2026-11-22T12:01:00Z",
            "alert_id": "alert-p5-lock-1",
            "artifact_cause": "حركة الرأس / مضغ",
        },
    )
    assert r_conflict.status_code == 409

    # Updating with matching expected_version=1 -> succeeds and increments version to 2
    r_update = client.post(
        f"/patients/{pat_id}/outcomes",
        headers=doc_headers,
        json={
            "outcome": "false_alarm",
            "occurred_at": "2026-11-22T12:01:00Z",
            "alert_id": "alert-p5-lock-1",
            "expected_version": 1,
            "artifact_cause": "حركة الرأس / مضغ",
            "notes": "Reclassified after reviewing motion channel",
        },
    )
    assert r_update.status_code == 201
    assert r_update.json()["outcome"]["version"] == 2
    assert r_update.json()["outcome"]["outcome"] == "false_alarm"
    assert r_update.json()["outcome"]["artifact_cause"] == "حركة الرأس / مضغ"


def test_phase6_prescription_meal_context_and_patient_only_intake_log():
    client = TestClient(app)
    pat_id, doc_id, cg_id, pat_headers, doc_headers, cg_headers = _setup_care_circle(client)

    # Doctor prescribes with meal/period context
    r_rx = client.post(
        f"/doctor/patients/{pat_id}/prescriptions",
        headers=doc_headers,
        json={
            "name": "Levetiracetam",
            "dose": "500mg",
            "schedule": "08:00 ص - بعد الإفطار",
            "period_context": "morning",
            "meal_context": "after_meal",
            "meal_type": "breakfast",
            "times": ["08:00", "20:00"],
        },
    )
    assert r_rx.status_code == 201
    rx_id = r_rx.json()["prescription"]["id"]

    # Doctor or Caregiver attempting to log intake -> 403 Forbidden (#11 strict segregation)
    for forbidden_hdr in (doc_headers, cg_headers):
        r_forbid = client.post(
            f"/patient/prescriptions/{rx_id}/intake-log",
            headers=forbidden_hdr,
            json={"scheduled_time": "2026-11-22T08:00:00Z", "status": "taken"},
        )
        assert r_forbid.status_code == 403

    # Patient logs dose taken -> 201 Created
    r_log = client.post(
        f"/patient/prescriptions/{rx_id}/intake-log",
        headers=pat_headers,
        json={"scheduled_time": "2026-11-22T08:00:00Z", "status": "taken"},
    )
    assert r_log.status_code == 201
    assert r_log.json()["log"]["status"] == "taken"

    # Doctor & Caregiver can query adherence summary
    for reader_hdr in (doc_headers, cg_headers, pat_headers):
        r_adh = client.get(f"/patients/{pat_id}/adherence", headers=reader_hdr)
        assert r_adh.status_code == 200
        body = r_adh.json()
        assert body["totalLogs"] == 1
        assert body["takenCount"] == 1
        assert body["adherenceRate"] == 100.0
