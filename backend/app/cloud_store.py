"""Simple cloud store for MVP (file-backed). Replace with Firebase/Postgres later."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Any
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "data" / "cloud_store.json"
_lock = Lock()


def _empty() -> dict:
    return {"patients": {}, "readings": {}, "assessments": {}, "alerts": {}}


def _load() -> dict:
    if not STORE.exists():
        return _empty()
    try:
        return json.loads(STORE.read_text(encoding="utf-8"))
    except Exception:
        return _empty()


def _save(data: dict) -> None:
    STORE.parent.mkdir(parents=True, exist_ok=True)
    STORE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def upsert_patient(patient_id: str, profile: dict[str, Any]) -> dict:
    with _lock:
        db = _load()
        cur = db["patients"].get(patient_id, {})
        cur.update(profile)
        cur["patientId"] = patient_id
        cur["updatedAt"] = datetime.now(timezone.utc).isoformat()
        db["patients"][patient_id] = cur
        _save(db)
        return cur


def add_reading(patient_id: str, reading: dict[str, Any]) -> dict:
    with _lock:
        db = _load()
        rid = reading.get("id") or str(uuid4())
        reading = {**reading, "id": rid, "patientId": patient_id}
        db["readings"].setdefault(patient_id, [])
        db["readings"][patient_id].insert(0, reading)
        db["readings"][patient_id] = db["readings"][patient_id][:500]
        _save(db)
        return reading


def add_assessment(patient_id: str, assessment: dict[str, Any]) -> dict:
    with _lock:
        db = _load()
        aid = assessment.get("id") or str(uuid4())
        assessment = {**assessment, "id": aid, "patientId": patient_id}
        db["assessments"].setdefault(patient_id, [])
        db["assessments"][patient_id].insert(0, assessment)
        db["assessments"][patient_id] = db["assessments"][patient_id][:500]
        # update patient status
        p = db["patients"].setdefault(patient_id, {"patientId": patient_id})
        p["currentStatus"] = assessment.get("label")
        p["lastUpdated"] = assessment.get("timestamp")
        _save(db)
        return assessment


def add_alert(patient_id: str, alert: dict[str, Any]) -> dict:
    with _lock:
        db = _load()
        aid = alert.get("id") or str(uuid4())
        alert = {
            **alert,
            "id": aid,
            "patientId": patient_id,
            "recipients": alert.get("recipients")
            or ["patient", "caregiver", "doctor"],
            "acknowledged": False,
        }
        db["alerts"].setdefault(patient_id, [])
        db["alerts"][patient_id].insert(0, alert)
        db["alerts"][patient_id] = db["alerts"][patient_id][:200]
        _save(db)
        return alert


def list_patients() -> list[dict]:
    with _lock:
        return list(_load()["patients"].values())


def get_patient(patient_id: str) -> dict | None:
    with _lock:
        return _load()["patients"].get(patient_id)


def list_readings(patient_id: str, limit: int = 50) -> list[dict]:
    with _lock:
        return _load()["readings"].get(patient_id, [])[:limit]


def list_assessments(patient_id: str, limit: int = 50) -> list[dict]:
    with _lock:
        return _load()["assessments"].get(patient_id, [])[:limit]


def list_alerts(patient_id: str, limit: int = 50) -> list[dict]:
    with _lock:
        return _load()["alerts"].get(patient_id, [])[:limit]


def ack_alert(patient_id: str, alert_id: str, by: str) -> dict | None:
    with _lock:
        db = _load()
        alerts = db["alerts"].get(patient_id, [])
        for a in alerts:
            if a.get("id") == alert_id:
                a["acknowledged"] = True
                a["acknowledgedBy"] = by
                _save(db)
                return a
        return None
