"""SQL-backed monitoring store with backwards-compatible public functions."""
from __future__ import annotations

from datetime import datetime, timezone
import os
from typing import Any
from uuid import uuid4

from sqlalchemy import delete, insert, select, update
from sqlalchemy.engine import Connection

from app.database import (
    alerts,
    alert_acknowledgments,
    assessments,
    connection,
    dump_json,
    load_json,
    medication_logs,
    patients,
    prescriptions,
    readings,
    transaction,
    upsert,
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _patient(row) -> dict | None:
    if row is None:
        return None
    r = row._mapping
    profile = load_json(r["profile_json"], {})
    # These keys are always present (possibly null) so clients can rely on a
    # stable patient shape instead of probing for missing fields.
    profile.update({
        "patientId": r["patient_id"],
        "updatedAt": r["updated_at"],
        "currentStatus": r["current_status"],
        "lastUpdated": r["last_updated"],
    })
    return profile


def _payload(row) -> dict:
    return load_json(row._mapping["payload_json"], {})


def _upsert_patient(conn: Connection, patient_id: str, profile: dict[str, Any]) -> dict:
    _ensure_patient(conn, patient_id)
    row = conn.execute(select(patients).where(
        patients.c.patient_id == patient_id,
    ).with_for_update()).one()
    current = _patient(row)
    if not profile:
        return current
    current.update(profile)
    now = _now()
    current.update({"patientId": patient_id, "updatedAt": now})
    values = {
        "updated_at": now,
        "profile_json": dump_json({
            key: value for key, value in current.items()
            if key not in {"patientId", "updatedAt", "currentStatus", "lastUpdated"}
        }),
    }
    # Unrelated profile edits must never write an old status back over a fresh
    # assessment. Only explicit administrative status edits touch these fields.
    if "currentStatus" in profile:
        values["current_status"] = profile["currentStatus"]
    if "lastUpdated" in profile:
        values["last_updated"] = profile["lastUpdated"]
    conn.execute(update(patients).where(patients.c.patient_id == patient_id).values(**values))
    return current


def upsert_patient(patient_id: str, profile: dict[str, Any]) -> dict:
    with transaction() as conn:
        return _upsert_patient(conn, patient_id, profile)


def _ensure_patient(conn: Connection, patient_id: str) -> None:
    """Create the patient row if absent, without racing concurrent writers."""
    conn.execute(
        upsert(patients, {
            "patient_id": patient_id, "current_status": None, "last_updated": None,
            "updated_at": _now(), "profile_json": dump_json({}),
        })
        .on_conflict_do_nothing(index_elements=[patients.c.patient_id])
    )


def _trim(conn: Connection, table, patient_id: str, keep: int) -> None:
    # Circular demo history is not a medical retention policy. Production keeps
    # records until an explicit archive/erasure process acts on them.
    if os.getenv("APP_ENV", "demo").strip().lower() in {"production", "prod"}:
        return
    stale = select(table.c.sequence).where(table.c.patient_id == patient_id).order_by(
        table.c.sequence.desc()).offset(keep)
    conn.execute(delete(table).where(table.c.sequence.in_(stale)))


def _persist_monitoring_row(conn: Connection, table, values: dict) -> tuple[dict, bool]:
    """Retry-safe insert; never disclose or overwrite another patient's row."""
    inserted = conn.execute(upsert(table, values).on_conflict_do_nothing(index_elements=["id"]))
    row = conn.execute(select(table).where(table.c.id == values["id"])).one()
    if row._mapping["patient_id"] != values["patient_id"]:
        raise ValueError("Monitoring id is already in use")
    saved = _payload(row)
    incoming = load_json(values["payload_json"], {})
    ignored = {"synced", "acknowledged", "acknowledgedBy", "acknowledgments"}
    if any(saved.get(key) != value for key, value in incoming.items() if key not in ignored):
        raise ValueError("Monitoring id is already in use with different content")
    return saved, inserted.rowcount == 1


def _add_reading(
    conn: Connection,
    patient_id: str,
    reading: dict[str, Any],
    *,
    _trim_after: bool = True,
) -> dict:
    _ensure_patient(conn, patient_id)
    result = {**reading, "id": reading.get("id") or str(uuid4()), "patientId": patient_id}
    result, _ = _persist_monitoring_row(conn, readings, dict(
        id=result["id"], patient_id=patient_id,
        captured_at=result.get("timestamp"), payload_json=dump_json(result),
    ))
    if _trim_after:
        _trim(conn, readings, patient_id, 500)
    return result


def add_reading(patient_id: str, reading: dict[str, Any]) -> dict:
    with transaction() as conn:
        return _add_reading(conn, patient_id, reading)


def _add_assessment(
    conn: Connection,
    patient_id: str,
    assessment: dict[str, Any],
    *,
    _trim_after: bool = True,
) -> dict:
    _ensure_patient(conn, patient_id)
    result = {
        **assessment, "id": assessment.get("id") or str(uuid4()),
        "patientId": patient_id,
    }
    result, inserted = _persist_monitoring_row(conn, assessments, dict(
        id=result["id"], patient_id=patient_id,
        captured_at=result.get("timestamp"), label=result.get("label"),
        payload_json=dump_json(result),
    ))
    raw_features = result.get('features')
    features = raw_features if isinstance(raw_features, dict) else {}
    raw_components = result.get('components') or features.get('components')
    components = raw_components if isinstance(raw_components, dict) else {}
    valid_projection = ((raw_features is None or isinstance(raw_features, dict))
                        and (raw_components is None or isinstance(raw_components, dict))
                        and features.get('assessment_valid', True)
                        and components.get('assessment_valid', True)
                        and result.get('source') not in ('dataset', 'bonn', 'simulation'))
    if inserted and valid_projection:
        # Compare actual instants (legacy rows may use Z or an offset). The
        # caller holds the patient row while advancing this projection.
        row = conn.execute(select(patients.c.last_updated).where(
            patients.c.patient_id == patient_id,
        ).with_for_update()).one()
        def instant(value):
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                return parsed.astimezone(timezone.utc) if parsed.tzinfo else None
            except (AttributeError, TypeError, ValueError):
                return None
        incoming_at, current_at = instant(result.get("timestamp")), instant(row[0])
        if incoming_at is not None and (current_at is None or incoming_at > current_at):
            conn.execute(update(patients).where(patients.c.patient_id == patient_id).values(
                current_status=result.get("label"), last_updated=incoming_at.isoformat(), updated_at=_now(),
            ))
    if _trim_after:
        _trim(conn, assessments, patient_id, 500)
    return result


def add_assessment(patient_id: str, assessment: dict[str, Any]) -> dict:
    with transaction() as conn:
        return _add_assessment(conn, patient_id, assessment)


def _add_alert(
    conn: Connection,
    patient_id: str,
    alert: dict[str, Any],
    *,
    _trim_after: bool = True,
) -> dict:
    _ensure_patient(conn, patient_id)
    result = {
        **alert, "id": alert.get("id") or str(uuid4()), "patientId": patient_id,
        "recipients": alert.get("recipients") or ["patient", "caregiver", "doctor"],
        "acknowledged": False,
    }
    result, _ = _persist_monitoring_row(conn, alerts, dict(
        id=result["id"], patient_id=patient_id,
        captured_at=result.get("timestamp"), severity=result.get("severity"),
        acknowledged=False, payload_json=dump_json(result),
    ))
    # Same transaction as the alert: an alert can never be stored without a
    # delivery record, so a notification cannot be silently lost.
    if result.get("severity") == "critical" or result.get("shouldNotify"):
        from app.alert_outbox import enqueue

        enqueue(conn, patient_id, result)
    if _trim_after:
        _trim(conn, alerts, patient_id, 200)
    return result


def add_alert(patient_id: str, alert: dict[str, Any]) -> dict:
    with transaction() as conn:
        return _add_alert(conn, patient_id, alert)


def _add_medication_log(
    conn: Connection,
    patient_id: str,
    log_item: dict[str, Any],
    *,
    recorded_by: str,
) -> dict[str, Any]:
    _ensure_patient(conn, patient_id)
    prescription_id = str(log_item["prescription_id"])
    scheduled_time = str(log_item["scheduled_time"])
    status = str(log_item.get("status") or "taken")
    taken_at = log_item.get("taken_at")
    log_recorded_by = str(log_item.get("recorded_by") or recorded_by)
    log_id = str(log_item.get("id") or str(uuid4()))

    rx = conn.execute(
        select(prescriptions.c.id, prescriptions.c.patient_id).where(
            prescriptions.c.id == prescription_id
        )
    ).first()
    if rx is None or rx._mapping["patient_id"] != patient_id:
        raise LookupError("prescription not found for patient")

    existing_by_id = conn.execute(
        select(medication_logs).where(medication_logs.c.id == log_id)
    ).first()
    if existing_by_id is not None:
        m = existing_by_id._mapping
        if (
            m["patient_id"] != patient_id
            or m["prescription_id"] != prescription_id
            or m["scheduled_time"] != scheduled_time
        ):
            raise ValueError("Medication log id is already in use")

    values = {
        "id": log_id,
        "prescription_id": prescription_id,
        "patient_id": patient_id,
        "scheduled_time": scheduled_time,
        "taken_at": taken_at,
        "status": status,
        "recorded_by": log_recorded_by,
        "created_at": _now(),
    }
    conn.execute(
        upsert(medication_logs, values).on_conflict_do_update(
            index_elements=[
                medication_logs.c.prescription_id,
                medication_logs.c.scheduled_time,
            ],
            set_={
                "status": values["status"],
                "taken_at": values["taken_at"],
                "recorded_by": values["recorded_by"],
            },
        )
    )
    row = conn.execute(
        select(medication_logs).where(
            medication_logs.c.prescription_id == prescription_id,
            medication_logs.c.scheduled_time == scheduled_time,
        )
    ).one()
    r = row._mapping
    return {
        "id": r["id"],
        "prescriptionId": r["prescription_id"],
        "prescription_id": r["prescription_id"],
        "patientId": r["patient_id"],
        "patient_id": r["patient_id"],
        "scheduledTime": r["scheduled_time"],
        "scheduled_time": r["scheduled_time"],
        "takenAt": r["taken_at"],
        "taken_at": r["taken_at"],
        "status": r["status"],
        "recordedBy": r["recorded_by"],
        "recorded_by": r["recorded_by"],
        "createdAt": r["created_at"],
        "created_at": r["created_at"],
    }


def add_medication_log(
    patient_id: str,
    log_item: dict[str, Any],
    *,
    recorded_by: str,
) -> dict[str, Any]:
    with transaction() as conn:
        return _add_medication_log(conn, patient_id, log_item, recorded_by=recorded_by)


def list_medication_logs(patient_id: str, limit: int = 200) -> list[dict[str, Any]]:
    with connection() as conn:
        rows = conn.execute(
            select(medication_logs)
            .where(medication_logs.c.patient_id == patient_id)
            .order_by(medication_logs.c.scheduled_time.desc(), medication_logs.c.created_at.desc())
            .limit(limit)
        ).all()
    out = []
    for row in rows:
        r = row._mapping
        out.append({
            "id": r["id"],
            "prescriptionId": r["prescription_id"],
            "prescription_id": r["prescription_id"],
            "patientId": r["patient_id"],
            "patient_id": r["patient_id"],
            "scheduledTime": r["scheduled_time"],
            "scheduled_time": r["scheduled_time"],
            "takenAt": r["taken_at"],
            "taken_at": r["taken_at"],
            "status": r["status"],
            "recordedBy": r["recorded_by"],
            "recorded_by": r["recorded_by"],
            "createdAt": r["created_at"],
            "created_at": r["created_at"],
        })
    return out


def upsert_sql_prescription(rx: dict[str, Any]) -> dict[str, Any]:
    patient_id = str(rx["patient_id"])
    now = _now()
    row = {
        "id": str(rx["id"]),
        "patient_id": patient_id,
        "doctor_id": rx.get("doctor_id"),
        "name": str(rx["name"]),
        "dose": str(rx["dose"]),
        "schedule": str(rx["schedule"]),
        "notes": rx.get("notes"),
        "active": bool(rx.get("active", True)),
        "period_context": rx.get("period_context"),
        "meal_context": rx.get("meal_context"),
        "meal_type": rx.get("meal_type"),
        "times_json": dump_json(rx.get("times") or []) if rx.get("times") is not None else rx.get("times_json"),
        "created_at": str(rx.get("created_at") or now),
        "updated_at": str(rx.get("updated_at") or now),
    }
    with transaction() as conn:
        _ensure_patient(conn, patient_id)
        conn.execute(
            upsert(prescriptions, row).on_conflict_do_update(
                index_elements=["id"],
                set_={k: v for k, v in row.items() if k not in ("id", "patient_id", "created_at")},
            )
        )
    return row


def _prescription(row) -> dict:
    result = dict(row._mapping)
    result["times"] = load_json(result.pop("times_json", None), [])
    return result


def list_sql_prescriptions(patient_id: str) -> list[dict]:
    # Import legacy profile entries once without overwriting authoritative rows.
    legacy = (get_patient(patient_id) or {}).get("prescriptions") or []
    with transaction() as conn:
        for rx in legacy:
            if not isinstance(rx, dict) or not rx.get("id"):
                continue
            values = {key: rx.get(key) for key in (
                "doctor_id", "name", "dose", "schedule", "notes", "period_context", "meal_context", "meal_type")}
            values.update(id=str(rx["id"]), patient_id=patient_id,
                active=bool(rx.get("active", True)), times_json=dump_json(rx.get("times") or []),
                created_at=rx.get("created_at") or _now(), updated_at=rx.get("updated_at") or _now())
            conn.execute(upsert(prescriptions, values).on_conflict_do_nothing(index_elements=["id"]))
        return [_prescription(row) for row in conn.execute(select(prescriptions).where(
            prescriptions.c.patient_id == patient_id).order_by(prescriptions.c.created_at, prescriptions.c.id)).all()]


def update_sql_prescription(patient_id: str, rx_id: str, changes: dict) -> dict | None:
    list_sql_prescriptions(patient_id)
    values = dict(changes)
    if "times" in values:
        values["times_json"] = dump_json(values.pop("times") or [])
    values["updated_at"] = _now()
    with transaction() as conn:
        result = conn.execute(update(prescriptions).where(
            prescriptions.c.patient_id == patient_id, prescriptions.c.id == rx_id).values(**values))
        if result.rowcount != 1:
            return None
        return _prescription(conn.execute(select(prescriptions).where(
            prescriptions.c.patient_id == patient_id, prescriptions.c.id == rx_id)).one())


def save_monitoring_bundle(
    patient_id: str,
    reading: dict[str, Any],
    assessment: dict[str, Any] | None = None,
    alert: dict[str, Any] | None = None,
    patient_profile: dict[str, Any] | None = None,
) -> dict:
    """Atomically persist one ingestion result and all derived records."""
    with transaction() as conn:
        _upsert_patient(conn, patient_id, patient_profile or {})
        saved_reading = _add_reading(conn, patient_id, reading)
        saved_assessment = (
            _add_assessment(conn, patient_id, assessment) if assessment is not None else None
        )
        saved_alert = _add_alert(conn, patient_id, alert) if alert is not None else None
        return {
            "reading": saved_reading,
            "assessment": saved_assessment,
            "alert": saved_alert,
        }


def save_monitoring_batch(
    *,
    bundles: list[tuple[str, dict[str, Any], dict[str, Any] | None, dict[str, Any] | None]] | None = None,
    readings_items: list[tuple[str, dict[str, Any]]] | None = None,
    assessments_items: list[tuple[str, dict[str, Any]]] | None = None,
    alerts_items: list[tuple[str, dict[str, Any]]] | None = None,
    intake_logs_items: list[tuple[str, dict[str, Any]]] | None = None,
    recorded_by: str = "system",
) -> dict[str, Any]:
    """Atomically persist a batch of monitoring records and medication intake logs."""
    with transaction() as conn:
        saved_readings: list[dict[str, Any]] = []
        saved_assessments: list[dict[str, Any]] = []
        saved_alerts: list[dict[str, Any]] = []
        saved_intake_logs: list[dict[str, Any]] = []
        synced_reading_ids: list[str] = []

        reading_patients: set[str] = set()
        assessment_patients: set[str] = set()
        alert_patients: set[str] = set()

        for pid, reading, assessment, alert in bundles or []:
            saved_reading = _add_reading(conn, pid, reading, _trim_after=False)
            saved_readings.append(saved_reading)
            synced_reading_ids.append(str(saved_reading["id"]))
            reading_patients.add(pid)
            if assessment is not None:
                saved_assessments.append(
                    _add_assessment(conn, pid, assessment, _trim_after=False)
                )
                assessment_patients.add(pid)
            if alert is not None:
                saved_alerts.append(
                    _add_alert(conn, pid, alert, _trim_after=False)
                )
                alert_patients.add(pid)

        for pid, reading in readings_items or []:
            saved_reading = _add_reading(conn, pid, reading, _trim_after=False)
            saved_readings.append(saved_reading)
            synced_reading_ids.append(str(saved_reading["id"]))
            reading_patients.add(pid)

        for pid, assessment in assessments_items or []:
            saved_assessments.append(
                _add_assessment(conn, pid, assessment, _trim_after=False)
            )
            assessment_patients.add(pid)

        for pid, alert in alerts_items or []:
            saved_alerts.append(_add_alert(conn, pid, alert, _trim_after=False))
            alert_patients.add(pid)

        for pid, log_item in intake_logs_items or []:
            saved_intake_logs.append(
                _add_medication_log(conn, pid, log_item, recorded_by=recorded_by)
            )

        for pid in reading_patients:
            _trim(conn, readings, pid, 500)
        for pid in assessment_patients:
            _trim(conn, assessments, pid, 500)
        for pid in alert_patients:
            _trim(conn, alerts, pid, 200)

        return {
            "synced_reading_ids": synced_reading_ids,
            "readings": saved_readings,
            "assessments": saved_assessments,
            "alerts": saved_alerts,
            "intake_logs": saved_intake_logs,
        }


def list_patients() -> list[dict]:
    with connection() as conn:
        return [_patient(row) for row in conn.execute(
            select(patients).order_by(patients.c.updated_at.desc()))]


def get_patient(patient_id: str) -> dict | None:
    with connection() as conn:
        return _patient(conn.execute(select(patients).where(
            patients.c.patient_id == patient_id)).first())


def _list_payloads(table, patient_id: str, limit: int) -> list[dict]:
    with connection() as conn:
        rows = conn.execute(select(table).where(table.c.patient_id == patient_id).order_by(
            table.c.sequence.desc()).limit(limit))
        return [_payload(row) for row in rows]


def list_readings(patient_id: str, limit: int = 50) -> list[dict]:
    return _list_payloads(readings, patient_id, limit)


def list_assessments(patient_id: str, limit: int = 50) -> list[dict]:
    return _list_payloads(assessments, patient_id, limit)


def list_alerts(patient_id: str, limit: int = 50) -> list[dict]:
    return _list_payloads(alerts, patient_id, limit)


def get_alert(patient_id: str, alert_id: str) -> dict | None:
    with connection() as conn:
        row = conn.execute(select(alerts).where(
            alerts.c.patient_id == patient_id, alerts.c.id == alert_id,
        )).first()
        return _payload(row) if row is not None else None


def _acknowledgment(row) -> dict:
    r = row._mapping
    return {
        "id": r["id"], "alertId": r["alert_id"], "patientId": r["patient_id"],
        "actorId": r["actor_id"], "actorRole": r["actor_role"],
        "acknowledgedAt": r["acknowledged_at"], "note": r["note"],
    }


def list_alert_acknowledgments(patient_id: str, alert_id: str) -> list[dict]:
    with connection() as conn:
        rows = conn.execute(select(alert_acknowledgments).where(
            alert_acknowledgments.c.patient_id == patient_id,
            alert_acknowledgments.c.alert_id == alert_id,
        ).order_by(alert_acknowledgments.c.acknowledged_at))
        return [_acknowledgment(row) for row in rows]


def ack_alert(patient_id: str, alert_id: str, by: str,
              actor_role: str | None = None, note: str | None = None) -> dict | None:
    with transaction() as conn:
        row = conn.execute(select(alerts).where(
            alerts.c.patient_id == patient_id, alerts.c.id == alert_id,
        )).first()
        if row is None:
            return None
        acknowledged_at = _now()
        # Naming the conflict target keeps this idempotent on PostgreSQL, where a
        # bare DO NOTHING would also swallow unrelated constraint violations.
        conn.execute(upsert(alert_acknowledgments, {
            "id": str(uuid4()), "alert_id": alert_id, "patient_id": patient_id,
            "actor_id": by, "actor_role": actor_role,
            "acknowledged_at": acknowledged_at, "note": note,
        }).on_conflict_do_nothing(index_elements=[
            alert_acknowledgments.c.alert_id, alert_acknowledgments.c.actor_id,
        ]))

        payload = _payload(row)
        payload.update({
            "acknowledged": True,
            "acknowledgedBy": payload.get("acknowledgedBy") or by,
            "acknowledgedAt": payload.get("acknowledgedAt") or acknowledged_at,
        })
        conn.execute(update(alerts).where(alerts.c.sequence == row._mapping["sequence"]).values(
            acknowledged=True, payload_json=dump_json(payload),
        ))
    payload["acknowledgments"] = list_alert_acknowledgments(patient_id, alert_id)
    return payload
