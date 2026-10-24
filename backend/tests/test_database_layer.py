"""Guarantees for the SQLite storage layer: migration, atomicity, concurrency.

These tests exercise the store modules directly (not through HTTP) so a failure
points at the persistence layer rather than at a router.
"""
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from sqlalchemy import func, insert, select

from app import cloud_store, users_store
from app.database import assessments, connection, patients, readings, users
from app.store_migration import import_legacy_stores


def _write_legacy_stores(tmp_path: Path) -> tuple[Path, Path]:
    users_json = tmp_path / "users_store.json"
    cloud_json = tmp_path / "cloud_store.json"
    users_json.write_text(json.dumps({
        "users": {
            "doc-1": {
                "id": "doc-1", "username": "dr_legacy", "name": "Legacy Doctor",
                "role": "doctor", "passwordHash": "hash-1", "disabled": False,
                "sessionVersion": 2, "createdAt": "2026-01-01T00:00:00+00:00",
                "updatedAt": "2026-01-02T00:00:00+00:00", "meta": {"note": "kept"},
            },
            "pat-1": {
                "id": "pat-1", "username": "patient_legacy", "name": "Legacy Patient",
                "role": "patient", "passwordHash": "hash-2", "disabled": True,
                "sessionVersion": 0, "primaryDoctorId": "doc-1", "patientId": "pat-1",
                "createdAt": "2026-01-03T00:00:00+00:00",
                "updatedAt": "2026-01-04T00:00:00+00:00", "meta": {},
            },
            "broken": {"id": "broken", "username": "", "role": "wizard"},
        },
        "assignments": [
            {"patientId": "pat-1", "doctorId": "doc-1", "assignedBy": "admin",
             "assignedAt": "2026-01-05T00:00:00+00:00"},
            {"patientId": "pat-1", "doctorId": "ghost", "assignedBy": "admin",
             "assignedAt": "2026-01-05T00:00:00+00:00"},
        ],
        "audit": [
            {"id": "a-new", "at": "2026-01-07T00:00:00+00:00", "actor": "admin",
             "actorRole": "admin", "action": "newest", "target": None, "detail": {}},
            {"id": "a-old", "at": "2026-01-06T00:00:00+00:00", "actor": "admin",
             "actorRole": "admin", "action": "oldest", "target": None, "detail": {}},
        ],
    }), encoding="utf-8")
    cloud_json.write_text(json.dumps({
        "patients": {
            "pat-1": {"patientId": "pat-1", "name": "Legacy Patient",
                      "currentStatus": "watch", "lastUpdated": "2026-01-08T00:00:00+00:00"},
        },
        "readings": {"pat-1": [
            {"id": "r-new", "timestamp": "2026-01-09T00:00:00+00:00", "hr": 88.0},
            {"id": "r-old", "timestamp": "2026-01-08T00:00:00+00:00", "hr": 77.0},
        ]},
        "assessments": {"pat-1": [
            {"id": "s-1", "timestamp": "2026-01-09T00:00:00+00:00", "label": "watch"},
        ]},
        "alerts": {"pat-1": [
            {"id": "al-1", "timestamp": "2026-01-09T00:00:00+00:00",
             "severity": "critical", "acknowledged": False},
        ]},
    }), encoding="utf-8")
    return users_json, cloud_json


@pytest.fixture
def legacy_stores(monkeypatch, tmp_path):
    users_json, cloud_json = _write_legacy_stores(tmp_path)
    monkeypatch.setenv("USERS_STORE_PATH", str(users_json))
    monkeypatch.setenv("CLOUD_STORE_PATH", str(cloud_json))
    return users_json, cloud_json


def test_migration_imports_accounts_and_monitoring_data(legacy_stores):
    outcome = import_legacy_stores()

    assert {entry["store"] for entry in outcome["imported"]} == {
        "users_store.json", "cloud_store.json"
    }
    doctor = users_store.get_by_username("dr_legacy")
    assert doctor["id"] == "doc-1"
    assert doctor["sessionVersion"] == 2
    assert doctor["meta"] == {"note": "kept"}
    assert users_store.get_user("pat-1")["disabled"] is True
    assert users_store.doctors_for_patient("pat-1") == ["doc-1"]
    assert cloud_store.get_patient("pat-1")["currentStatus"] == "watch"
    assert [r["id"] for r in cloud_store.list_readings("pat-1")] == ["r-new", "r-old"]
    assert cloud_store.list_alerts("pat-1")[0]["id"] == "al-1"


def test_migration_skips_invalid_rows_without_failing(legacy_stores):
    import_legacy_stores()

    assert users_store.get_user("broken") is None
    assert all(a["doctorId"] != "ghost" for a in users_store.list_assignments())


def test_migration_backs_up_json_and_keeps_originals(legacy_stores):
    users_json, cloud_json = legacy_stores

    outcome = import_legacy_stores()

    for entry in outcome["imported"]:
        assert Path(entry["backup"]).exists()
    assert users_json.exists() and cloud_json.exists()


def test_migration_is_idempotent(legacy_stores):
    import_legacy_stores()
    second = import_legacy_stores()

    assert second["imported"] == []
    with connection() as conn:
        assert conn.scalar(select(func.count()).select_from(users)) == 2
        assert conn.scalar(select(func.count()).select_from(readings)) == 2


def test_audit_history_order_is_preserved(legacy_stores):
    import_legacy_stores()

    assert [entry["id"] for entry in users_store.list_audit()] == ["a-new", "a-old"]


def test_bundle_rolls_back_completely_when_alert_insert_fails():
    cloud_store.save_monitoring_bundle(
        "pat-x", {"id": "r-1", "timestamp": "2026-02-01T00:00:00+00:00"}
    )
    cloud_store.add_alert("pat-x", {"id": "duplicate-alert"})

    with pytest.raises(Exception):
        cloud_store.save_monitoring_bundle(
            "pat-x",
            {"id": "r-2", "timestamp": "2026-02-02T00:00:00+00:00"},
            assessment={"id": "s-2", "label": "high_risk"},
            alert={"id": "duplicate-alert", "message": "conflicting payload"},  # id cannot be reused for different content
        )

    assert [r["id"] for r in cloud_store.list_readings("pat-x")] == ["r-1"]
    assert cloud_store.list_assessments("pat-x") == []
    assert cloud_store.get_patient("pat-x")["currentStatus"] is None


def test_bundle_persists_reading_assessment_alert_and_status():
    saved = cloud_store.save_monitoring_bundle(
        "pat-y",
        {"timestamp": "2026-02-03T00:00:00+00:00", "hr": 120.0},
        assessment={"label": "high_risk", "timestamp": "2026-02-03T00:00:00+00:00"},
        alert={"severity": "critical", "timestamp": "2026-02-03T00:00:00+00:00"},
    )

    assert saved["alert"]["recipients"] == ["patient", "caregiver", "doctor"]
    assert cloud_store.get_patient("pat-y")["currentStatus"] == "high_risk"
    assert len(cloud_store.list_readings("pat-y")) == 1


def test_concurrent_writes_do_not_lose_records():
    def write(index: int) -> None:
        cloud_store.save_monitoring_bundle(
            "pat-load",
            {"timestamp": f"2026-02-04T00:00:{index:02d}+00:00", "hr": 60.0 + index},
            assessment={"label": "stable"},
        )

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(write, range(24)))

    with connection() as conn:
        stored = conn.scalar(
            select(func.count()).select_from(readings).where(readings.c.patient_id == "pat-load")
        )
    assert stored == 24


def test_concurrent_assignment_requests_create_one_row():
    doctor = users_store.create_user(
        username="dr_race", name="Race", role="doctor", password_hash="x")
    patient = users_store.create_user(
        username="pat_race", name="Race Patient", role="patient", password_hash="x")

    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(
            lambda _: users_store.assign_patient(patient["id"], doctor["id"], by="admin"),
            range(6),
        ))

    assert users_store.doctors_for_patient(patient["id"]) == [doctor["id"]]


def test_duplicate_username_is_rejected_case_insensitively():
    users_store.create_user(
        username="Unique_Name", name="First", role="doctor", password_hash="x")

    with pytest.raises(ValueError):
        users_store.create_user(
            username="unique_name", name="Second", role="doctor", password_hash="x")


def test_disabling_user_invalidates_existing_sessions():
    user = users_store.create_user(
        username="session_user", name="Session", role="doctor", password_hash="x")

    disabled = users_store.set_disabled(user["id"], True)

    assert disabled["disabled"] is True
    assert disabled["sessionVersion"] == user["sessionVersion"] + 1


def test_deleting_user_removes_their_assignments():
    doctor = users_store.create_user(
        username="dr_gone", name="Gone", role="doctor", password_hash="x")
    patient = users_store.create_user(
        username="pat_kept", name="Kept", role="patient", password_hash="x")
    users_store.assign_patient(patient["id"], doctor["id"], by="admin")

    assert users_store.delete_user(doctor["id"]) is True
    assert users_store.doctors_for_patient(patient["id"]) == []


def test_reading_history_is_capped_per_patient():
    for index in range(505):
        cloud_store.add_reading("pat-cap", {"timestamp": f"t-{index}"})

    with connection() as conn:
        stored = conn.scalar(
            select(func.count()).select_from(readings).where(readings.c.patient_id == "pat-cap")
        )
    assert stored == 500
    assert cloud_store.list_readings("pat-cap", 1)[0]["timestamp"] == "t-504"


def test_acknowledging_alert_persists_actor():
    cloud_store.add_alert("pat-ack", {"id": "ack-1", "severity": "critical"})

    acked = cloud_store.ack_alert("pat-ack", "ack-1", "doctor-9")

    assert acked["acknowledged"] is True
    assert acked["acknowledgedBy"] == "doctor-9"
    assert cloud_store.ack_alert("pat-ack", "missing", "doctor-9") is None


def test_monitoring_rows_require_existing_patient():
    """Foreign keys must be enforced, otherwise orphan rows can accumulate."""
    from sqlalchemy.exc import IntegrityError

    from app.database import transaction

    with pytest.raises(IntegrityError):
        with transaction() as conn:
            conn.execute(insert(assessments).values(
                id="orphan", patient_id="does-not-exist",
                captured_at=None, label=None, payload_json="{}",
            ))

    with connection() as conn:
        assert conn.scalar(
            select(func.count()).select_from(patients).where(
                patients.c.patient_id == "does-not-exist")
        ) == 0


def test_monitoring_bundle_retry_preserves_acknowledgment_and_does_not_requeue():
    from app import alert_outbox
    bundle = dict(patient_id="retry-patient", reading={"id": "retry-reading"},
                  assessment={"id": "retry-assessment", "label": "watch"},
                  alert={"id": "retry-alert", "severity": "critical"})
    cloud_store.save_monitoring_bundle(**bundle)
    cloud_store.ack_alert("retry-patient", "retry-alert", "caregiver")
    cloud_store.save_monitoring_bundle(**bundle)
    assert len(cloud_store.list_readings("retry-patient")) == 1
    assert len(cloud_store.list_assessments("retry-patient")) == 1
    assert cloud_store.list_alerts("retry-patient")[0]["acknowledged"] is True
    assert len(alert_outbox.list_entries()) == 1


def test_monitoring_retry_never_returns_other_patient_data():
    cloud_store.add_reading("owner", {"id": "private-reading", "hr": 80})
    with pytest.raises(ValueError):
        cloud_store.add_reading("intruder", {"id": "private-reading", "hr": 80})
