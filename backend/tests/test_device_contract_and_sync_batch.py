"""Regression tests for F2 (/device/contract dedup) and F3 (POST /cloud/sync-batch)."""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app import cloud_store, prescriptions_store, security, users_store
from app.auth import create_token
from app.database import (
    alert_outbox,
    alerts,
    assessments,
    connection,
    medication_logs,
    readings,
)
from app.main import app
from app.routers import device as device_router


@pytest.fixture
def client():
    with TestClient(app) as instance:
        yield instance


def _create_user(username: str, role: str) -> dict:
    return users_store.create_user(
        username=username,
        name=username,
        role=role,
        password_hash=security.hash_password("test-password"),
    )


def _auth_headers(user: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {create_token(user['id'], user['role'])}"}


def _table_count(table, patient_id: str | None = None) -> int:
    with connection() as conn:
        stmt = select(func.count()).select_from(table)
        if patient_id is not None and hasattr(table.c, "patient_id"):
            stmt = stmt.where(table.c.patient_id == patient_id)
        return int(conn.scalar(stmt) or 0)


def _collect_api_routes(routes, prefix: str = "") -> list[tuple[str, set[str]]]:
    collected: list[tuple[str, set[str]]] = []
    for route in routes:
        if isinstance(route, APIRoute):
            collected.append((prefix + route.path, set(route.methods or ())))
        elif hasattr(route, "original_router"):
            ctx_prefix = ""
            if hasattr(route, "include_context") and getattr(route.include_context, "prefix", None):
                ctx_prefix = route.include_context.prefix
            collected.extend(
                _collect_api_routes(route.original_router.routes, prefix + ctx_prefix)
            )
    return collected


def test_device_contract_single_canonical_route_and_symbol(client):
    all_routes = _collect_api_routes(app.routes)
    matching_routes = [
        (path, methods)
        for path, methods in all_routes
        if path == "/device/contract" and "GET" in methods
    ]
    assert len(matching_routes) == 1
    assert sum(1 for r in device_router.router.routes if r.path == "/device/contract") == 1

    http_contract = client.get("/device/contract").json()
    direct_contract = device_router.device_contract()
    assert http_contract == direct_contract
    assert http_contract["signal_units"] == "normalized_demo"
    assert http_contract["sample_rate_hz"] == 256
    assert http_contract["analysis_window_samples"] == 262
    assert http_contract["max_batch_samples"] == 512
    assert http_contract["channels"] == ["eeg", "ecg", "motion", "hr"]
    assert http_contract["physical_device_compatible"] is False


def test_sync_batch_mounted_at_root_not_api_v1(client):
    patient = _create_user("batch-root-patient", "patient")
    headers = _auth_headers(patient)
    payload = {"patient_id": patient["id"], "readings": []}

    prefixed = client.post("/api/v1/cloud/sync-batch", json=payload, headers=headers)
    assert prefixed.status_code == 404

    root = client.post("/cloud/sync-batch", json=payload, headers=headers)
    assert root.status_code == 200
    assert root.json()["ok"] is True


def test_sync_batch_enforces_500_item_limit(client):
    import json

    patient = _create_user("batch-limit-patient", "patient")
    headers = _auth_headers(patient)
    ts = datetime.now(timezone.utc).isoformat()

    # 500 items (350 full 262-sample readings + 150 assessments) -> >2 MiB body, <=8 MiB limit -> 200 OK
    sample_wave = [0.1234567] * 262
    payload_500 = {
        "patient_id": patient["id"],
        "readings": [
            {
                "id": f"lim-r-{i}",
                "timestamp": ts,
                "hr": 72,
                "eeg": sample_wave,
                "ecg": sample_wave,
                "motion": sample_wave,
            }
            for i in range(350)
        ],
        "assessments": [
            {"id": f"lim-a-{i}", "timestamp": ts, "label": "stable", "confidence": 0.9}
            for i in range(150)
        ],
    }
    assert len(json.dumps(payload_500).encode("utf-8")) > 2 * 1024 * 1024
    resp_ok = client.post("/cloud/sync-batch", json=payload_500, headers=headers)
    assert resp_ok.status_code == 200, resp_ok.text
    body_ok = resp_ok.json()
    assert body_ok["processed"]["readings"] == 350
    assert body_ok["processed"]["assessments"] == 150
    assert len(body_ok["synced_reading_ids"]) == 350
    assert _table_count(readings, patient["id"]) == 350
    assert _table_count(assessments, patient["id"]) == 150

    # 501 items -> 422 and 0 rows persisted for a fresh patient
    patient_over = _create_user("batch-over-patient", "patient")
    headers_over = _auth_headers(patient_over)
    payload_501 = {
        "patient_id": patient_over["id"],
        "readings": [
            {"id": f"over-r-{i}", "timestamp": ts, "hr": 70}
            for i in range(501)
        ],
    }
    resp_over = client.post("/cloud/sync-batch", json=payload_501, headers=headers_over)
    assert resp_over.status_code == 422
    assert _table_count(readings, patient_over["id"]) == 0

    # Mixed 300 bundles + 201 intake_logs = 501 -> 422
    rx = prescriptions_store.create(
        patient_over["id"],
        "doc-1",
        {"name": "Levetiracetam", "dose": "500mg", "schedule": "BID"},
    )
    mixed_501 = {
        "patient_id": patient_over["id"],
        "items": [
            {"reading": {"id": f"mix-r-{i}", "timestamp": ts, "hr": 70}}
            for i in range(300)
        ],
        "intake_logs": [
            {
                "prescription_id": rx["id"],
                "scheduled_time": f"2026-11-22T08:{i:02d}:00+00:00",
                "status": "taken",
            }
            for i in range(201)
        ],
    }
    resp_mixed_over = client.post(
        "/cloud/sync-batch", json=mixed_501, headers=headers_over
    )
    assert resp_mixed_over.status_code == 422
    assert _table_count(readings, patient_over["id"]) == 0
    assert _table_count(medication_logs, patient_over["id"]) == 0


def test_sync_batch_atomic_rollback_on_partial_failure(client):
    patient = _create_user("batch-rollback-patient", "patient")
    other_patient = _create_user("batch-other-patient", "patient")
    headers = _auth_headers(patient)
    ts = datetime.now(timezone.utc).isoformat()

    cloud_store.add_alert(
        patient["id"],
        {"id": "conflict-alert", "severity": "warning", "message": "initial"},
    )
    rx = prescriptions_store.create(
        patient["id"],
        "doc-1",
        {"name": "Valproate", "dose": "500mg", "schedule": "BID"},
    )
    other_rx = prescriptions_store.create(
        other_patient["id"],
        "doc-1",
        {"name": "Lamotrigine", "dose": "100mg", "schedule": "QD"},
    )

    assert _table_count(alerts, patient["id"]) == 1
    assert _table_count(alert_outbox, patient["id"]) == 0

    # 1) Conflict on existing alert id ("conflict-alert") -> 409 + full rollback
    conflict_payload = {
        "patient_id": patient["id"],
        "readings": [
            {"id": "rb-r1", "timestamp": ts, "hr": 75},
            {"id": "rb-r2", "timestamp": ts, "hr": 78},
        ],
        "assessments": [
            {"id": "rb-a1", "timestamp": ts, "label": "high_risk", "confidence": 0.95}
        ],
        "intake_logs": [
            {
                "prescription_id": rx["id"],
                "scheduled_time": "2026-11-22T08:00:00+00:00",
                "status": "taken",
            }
        ],
        "alerts": [
            {
                "id": "rb-ok-critical",
                "timestamp": ts,
                "severity": "critical",
                "message": "should roll back",
            },
            {
                "id": "conflict-alert",
                "severity": "critical",
                "message": "conflicting content",
            },
        ],
    }
    conflict_resp = client.post(
        "/cloud/sync-batch", json=conflict_payload, headers=headers
    )
    assert conflict_resp.status_code == 409
    assert _table_count(readings, patient["id"]) == 0
    assert _table_count(assessments, patient["id"]) == 0
    assert _table_count(medication_logs, patient["id"]) == 0
    assert _table_count(alert_outbox, patient["id"]) == 0
    assert _table_count(alerts, patient["id"]) == 1
    assert cloud_store.get_patient(patient["id"])["currentStatus"] is None

    # 2) Non-existent prescription_id -> 422 + full rollback
    missing_rx_payload = {
        "patient_id": patient["id"],
        "bundles": [
            {
                "reading": {"id": "rb-b-r1", "timestamp": ts, "hr": 80},
                "assessment": {
                    "id": "rb-b-a1",
                    "timestamp": ts,
                    "label": "high_risk",
                    "confidence": 0.91,
                },
                "alert": {
                    "id": "rb-b-al1",
                    "timestamp": ts,
                    "severity": "critical",
                    "message": "critical",
                },
            }
        ],
        "intake_logs": [
            {
                "prescription_id": "non-existent-rx",
                "scheduled_time": "2026-11-22T09:00:00+00:00",
                "status": "taken",
            }
        ],
    }
    missing_rx_resp = client.post(
        "/cloud/sync-batch", json=missing_rx_payload, headers=headers
    )
    assert missing_rx_resp.status_code == 422
    assert _table_count(readings, patient["id"]) == 0
    assert _table_count(assessments, patient["id"]) == 0
    assert _table_count(medication_logs, patient["id"]) == 0
    assert _table_count(alert_outbox, patient["id"]) == 0
    assert _table_count(alerts, patient["id"]) == 1

    # 3) Cross-patient prescription_id -> 422 + full rollback
    cross_rx_payload = {
        "patient_id": patient["id"],
        "readings": [{"id": "rb-cross-r1", "timestamp": ts, "hr": 74}],
        "intake_logs": [
            {
                "prescription_id": other_rx["id"],
                "scheduled_time": "2026-11-22T10:00:00+00:00",
                "status": "taken",
            }
        ],
    }
    cross_rx_resp = client.post(
        "/cloud/sync-batch", json=cross_rx_payload, headers=headers
    )
    assert cross_rx_resp.status_code == 422
    assert _table_count(readings, patient["id"]) == 0
    assert _table_count(medication_logs, patient["id"]) == 0


def test_sync_batch_is_idempotent_on_retry_including_intake_logs(client):
    patient = _create_user("batch-idem-patient", "patient")
    headers = _auth_headers(patient)
    ts = datetime.now(timezone.utc).isoformat()
    rx = prescriptions_store.create(
        patient["id"],
        "doc-1",
        {"name": "Carbamazepine", "dose": "200mg", "schedule": "BID"},
    )

    payload = {
        "patient_id": patient["id"],
        "idempotency_key": "batch-retry-key-001",
        "items": [
            {
                "reading": {"id": "idem-r1", "timestamp": ts, "hr": 112},
                "assessment": {
                    "id": "idem-a1",
                    "timestamp": ts,
                    "label": "high_risk",
                    "confidence": 0.92,
                },
                "alert": {
                    "id": "idem-al1",
                    "timestamp": ts,
                    "severity": "critical",
                    "message": "High seizure risk",
                },
            }
        ],
        "medication_logs": [
            {
                "id": "idem-log-1",
                "medicationId": rx["id"],
                "scheduledFor": "2026-11-22T08:00:00+00:00",
                "takenAt": ts,
                "status": "taken",
            }
        ],
    }

    first = client.post("/cloud/sync-batch", json=payload, headers=headers)
    assert first.status_code == 200, first.text
    first_body = first.json()
    assert first_body["synced_reading_ids"] == ["idem-r1"]
    assert len(first_body["intake_logs"]) == 1
    assert first_body["intake_logs"][0]["prescription_id"] == rx["id"]

    replay = client.post("/cloud/sync-batch", json=payload, headers=headers)
    assert replay.status_code == 200, replay.text
    replay_body = replay.json()
    assert replay_body["synced_reading_ids"] == ["idem-r1"]

    assert _table_count(readings, patient["id"]) == 1
    assert _table_count(assessments, patient["id"]) == 1
    assert _table_count(alerts, patient["id"]) == 1
    assert _table_count(alert_outbox, patient["id"]) == 1
    assert _table_count(medication_logs, patient["id"]) == 1


def test_sync_batch_rbac_enforces_patient_and_link_ownership(client):
    patient_a = _create_user("rbac-patient-a", "patient")
    patient_b = _create_user("rbac-patient-b", "patient")
    assigned_doc = _create_user("rbac-doc-assigned", "doctor")
    unassigned_doc = _create_user("rbac-doc-unassigned", "doctor")
    linked_cg = _create_user("rbac-cg-linked", "caregiver")
    unlinked_cg = _create_user("rbac-cg-unlinked", "caregiver")

    users_store.assign_patient(patient_a["id"], assigned_doc["id"], "admin")
    users_store.link_caregiver(patient_a["id"], linked_cg["id"])
    ts = datetime.now(timezone.utc).isoformat()

    # 1) Unauthenticated -> 401
    unauth = client.post(
        "/cloud/sync-batch",
        json={"patient_id": patient_a["id"], "readings": [{"id": "unauth-r1", "timestamp": ts}]},
    )
    assert unauth.status_code == 401

    # 2) Missing patient_id -> 422
    missing_pid = client.post(
        "/cloud/sync-batch",
        json={"readings": [{"id": "no-pid-r1", "timestamp": ts}]},
        headers=_auth_headers(patient_a),
    )
    assert missing_pid.status_code == 422

    # 3) Patient A submitting for Patient B -> 403
    cross_patient = client.post(
        "/cloud/sync-batch",
        json={"patient_id": patient_b["id"], "readings": [{"id": "cross-r1", "timestamp": ts}]},
        headers=_auth_headers(patient_a),
    )
    assert cross_patient.status_code == 403
    assert _table_count(readings, patient_b["id"]) == 0

    # 4) Patient A submitting mixed batch [Patient A, Patient B] -> 403 and zero rows persisted for A or B
    mixed_batch = client.post(
        "/cloud/sync-batch",
        json={
            "readings": [
                {"id": "mix-a", "patient_id": patient_a["id"], "timestamp": ts},
                {"id": "mix-b", "patient_id": patient_b["id"], "timestamp": ts},
            ]
        },
        headers=_auth_headers(patient_a),
    )
    assert mixed_batch.status_code == 403
    assert _table_count(readings, patient_a["id"]) == 0
    assert _table_count(readings, patient_b["id"]) == 0

    # 5) Unassigned doctor -> 403
    doc_denied = client.post(
        "/cloud/sync-batch",
        json={"patient_id": patient_a["id"], "readings": [{"id": "doc-no", "timestamp": ts}]},
        headers=_auth_headers(unassigned_doc),
    )
    assert doc_denied.status_code == 403

    # 6) Unlinked caregiver -> 403
    cg_denied = client.post(
        "/cloud/sync-batch",
        json={"patient_id": patient_a["id"], "readings": [{"id": "cg-no", "timestamp": ts}]},
        headers=_auth_headers(unlinked_cg),
    )
    assert cg_denied.status_code == 403

    # 7) Matching patient, assigned doctor, linked caregiver -> 200
    for idx, actor in enumerate((patient_a, assigned_doc, linked_cg)):
        ok_resp = client.post(
            "/cloud/sync-batch",
            json={
                "patient_id": patient_a["id"],
                "readings": [{"id": f"rbac-ok-{idx}", "timestamp": ts, "hr": 72}],
            },
            headers=_auth_headers(actor),
        )
        assert ok_resp.status_code == 200, ok_resp.text

    assert _table_count(readings, patient_a["id"]) == 3


def test_legacy_cloud_sync_remains_backward_compatible(client):
    ts = datetime.now(timezone.utc).isoformat()
    resp = client.post(
        "/cloud/sync",
        json={
            "patient_id": "legacy-sync-patient",
            "reading": {"id": "leg-r1", "timestamp": ts, "hr": 76},
            "assessment": {"id": "leg-a1", "timestamp": ts, "label": "stable", "confidence": 0.9},
            "alert": {"id": "leg-al1", "timestamp": ts, "severity": "warning", "message": "notice"},
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["ok"] is True
    assert body["reading"]["id"] == "leg-r1"
    assert body["assessment"]["id"] == "leg-a1"
    assert body["alert"]["id"] == "leg-al1"
