"""Durable, transactionally ordered head-device streams and derived events."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
import hashlib
from uuid import uuid4

from sqlalchemy import select, update

from app import cloud_store
from app.database import device_streams, dump_json, load_json, patients, transaction, upsert
from app.preprocessing import extract_features
from app.schemas import RiskLabel, VitalWindow

DEVICE_WINDOW_SAMPLES = 262
DEVICE_STALE_SECONDS = 30
ALERT_COOLDOWN_SECONDS = 120


@dataclass
class DeviceSample:
    eeg: float
    ecg: float
    motion: float
    hr: float | None = None
    ts: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


@dataclass
class DeviceStatus:
    patient_id: str
    device_id: str
    connected: bool
    last_seen: str
    samples_buffered: int
    last_label: RiskLabel | None = None
    last_confidence: float | None = None
    last_window: VitalWindow | None = None
    last_engine: str | None = None
    last_deep_prob: float | None = None
    source: str = "device"
    last_preictal_prob: float | None = None
    last_lead_time_min: float | None = None
    last_horizon_min: float | None = None
    last_predicted: bool | None = None
    last_prediction_source: str | None = None
    preictal_trajectory: list = field(default_factory=list)
    last_reading_id: str | None = None
    last_assessment_id: str | None = None
    last_sequence: int | None = None
    assessment_valid: bool = False


def _age(timestamp: str | None, now: datetime) -> float:
    try:
        return (now - datetime.fromisoformat(timestamp.replace("Z", "+00:00"))).total_seconds()
    except (AttributeError, TypeError, ValueError):
        return float("inf")


class DeviceHub:
    """One bounded buffer per patient/device, shared by every API worker.

    An acknowledged batch, replay markers, completed windows and alert outbox
    intents commit together. A failed classifier/store rolls everything back so
    the sender may safely retry the same batch. SQLite serializes local writes;
    PostgreSQL row locks serialize each stream and the patient's alert policy.
    """

    def __init__(self, window_size: int = DEVICE_WINDOW_SAMPLES):
        self.window_size = window_size

    def ingest(self, patient_id: str, device_id: str, samples: list[DeviceSample], classifier,
               batch_id: str | None = None, sequence_number: int | None = None,
               *, source: str = "device") -> dict:
        now = datetime.now(timezone.utc)
        key = f"batch:{batch_id}" if batch_id else (f"seq:{sequence_number}" if sequence_number is not None else None)
        # Server-generated arrival timestamps are intentionally excluded: they
        # change on retry even when the device retransmits the identical batch.
        digest = hashlib.sha256(dump_json([
            [s.eeg, s.ecg, s.motion, s.hr] for s in samples
        ]).encode()).hexdigest()
        with transaction() as conn:
            cloud_store._ensure_patient(conn, patient_id)
            conn.execute(upsert(device_streams, {
                "patient_id": patient_id, "device_id": device_id,
                "state_json": "{}", "updated_at": now.isoformat(),
            }).on_conflict_do_nothing(index_elements=["patient_id", "device_id"]))
            where = (device_streams.c.patient_id == patient_id, device_streams.c.device_id == device_id)
            row = conn.execute(select(device_streams).where(*where).with_for_update()).one()
            state = load_json(row._mapping["state_json"], {})
            seen = state.get("seen", [])
            previous = next((item for item in seen if key is not None and item["key"] == key), None)
            if previous:
                if previous["digest"] != digest:
                    raise ValueError("batch id already used with different samples")
                return {**previous["result"], "accepted": 0, "duplicate": True}
            last_sequence = state.get("last_sequence")
            if sequence_number is not None and last_sequence is not None and sequence_number <= last_sequence:
                return {"accepted": 0, "buffered": len(state.get("buffer", [])), "window_ready": False,
                        "assessment": None, "duplicate": sequence_number == last_sequence,
                        "out_of_order": sequence_number < last_sequence}

            buffer = state.get("buffer", [])
            # Never construct a seemingly continuous window across a long gap
            # or known missing batches.
            if (_age(state.get("last_seen"), now) > DEVICE_STALE_SECONDS or
                (sequence_number is not None and last_sequence is not None and sequence_number != last_sequence + 1)):
                buffer = []
            buffer.extend(asdict(s) for s in samples)
            latest = state.get("latest")
            trajectory = state.get("trajectory", [])
            assessment = None
            while len(buffer) >= self.window_size:
                chunk, buffer = buffer[:self.window_size], buffer[self.window_size:]
                window = VitalWindow(
                    patient_id=patient_id, timestamp=chunk[-1]["ts"],
                    eeg=[s["eeg"] for s in chunk], ecg=[s["ecg"] for s in chunk],
                    motion=[s["motion"] for s in chunk],
                    hr=next((s["hr"] for s in reversed(chunk) if s["hr"] is not None), None),
                )
                assessment = self._assess(window, classifier, source)
                reading = {**window.model_dump(), "id": str(uuid4()), "source": source}
                assessment["reading_id"] = reading["id"]
                # Serialize the current-state projection/cooldown across devices
                # for the same patient, not just across batches of one device.
                conn.execute(select(patients.c.patient_id).where(
                    patients.c.patient_id == patient_id,
                ).with_for_update()).one()
                alert = None
                valid = assessment["components"].get("assessment_valid", True)
                fresh = 0 <= _age(window.timestamp, now) <= DEVICE_STALE_SECONDS
                if source == "device" and valid and fresh and assessment["label"] == "high_risk":
                    from app.detection_context import detection_context
                    details = detection_context(conn, patient_id, assessment, device_id, window)
                    assessment['features']['detection_event'] = details
                    recent = cloud_store.list_alerts(patient_id, 1)
                    if not recent or _age(recent[0].get("timestamp"), now) >= ALERT_COOLDOWN_SECONDS:
                        alert = {
                            "id": str(uuid4()), "timestamp": window.timestamp, "severity": "critical",
                            "message": "رُصدت مؤشرات خطر تجريبية؛ يرجى التحقق من حالة المريض.",
                            "recipients": ["patient", "caregiver", "doctor"],
                            "source": source, "assessment_id": assessment["id"],
                            "details": details,
                        }
                cloud_store.save_monitoring_bundle(patient_id, reading, assessment, alert)
                latest = {"reading": reading, "assessment": assessment}
                prob = assessment.get("preictal_prob")
                trajectory = (trajectory + [prob])[-60:] if prob is not None and valid else []

            result = {"accepted": len(samples), "buffered": len(buffer), "window_ready": assessment is not None,
                      "assessment": assessment, "duplicate": False, "out_of_order": False}
            if key:
                seen = (seen + [{"key": key, "digest": digest, "result": result}])[-256:]
            state.update(buffer=buffer, latest=latest, trajectory=trajectory, seen=seen,
                         source=source, last_seen=now.isoformat())
            if sequence_number is not None:
                state["last_sequence"] = sequence_number
            conn.execute(update(device_streams).where(*where).values(
                state_json=dump_json(state), updated_at=now.isoformat(),
            ))
            return result

    @staticmethod
    def _assess(window: VitalWindow, classifier, source: str) -> dict:
        if hasattr(classifier, "predict_window"):
            res = classifier.predict_window(window)
            label, confidence, features = res.label, res.confidence, res.features
            extras = {name: getattr(res, name, None) for name in (
                "engine", "deep_prob", "preictal_prob", "lead_time_min", "horizon_min", "predicted", "prediction_source",
            )}
            components = dict(getattr(res, "components", None) or {})
        else:
            features = extract_features(window)
            label, confidence = classifier.predict(features)
            extras, components = {"engine": "features"}, {}
        features = features.model_dump()
        features.update({k: v for k, v in extras.items() if v is not None})
        features["components"] = components
        return {"id": str(uuid4()), "timestamp": window.timestamp, "label": label, "confidence": confidence,
                "features": features, "components": components, "processingMs": 0, "source": source, **extras}

    def status(self, patient_id: str) -> DeviceStatus | None:
        from app.database import connection
        with connection() as conn:
            row = conn.execute(select(device_streams).where(
                device_streams.c.patient_id == patient_id,
            ).order_by(device_streams.c.updated_at.desc()).limit(1)).first()
        if row is None:
            return None
        state = load_json(row._mapping["state_json"], {})
        latest = state.get("latest") or {}
        reading, assessment = latest.get("reading"), latest.get("assessment") or {}
        now = datetime.now(timezone.utc)
        connected = 0 <= _age(state.get("last_seen"), now) <= DEVICE_STALE_SECONDS
        valid = bool(reading) and connected and assessment.get("components", {}).get("assessment_valid", True)
        valid = valid and 0 <= _age(assessment.get("timestamp"), now) <= DEVICE_STALE_SECONDS
        return DeviceStatus(
            patient_id=patient_id, device_id=row._mapping["device_id"], connected=connected,
            last_seen=state["last_seen"], samples_buffered=len(state.get("buffer", [])),
            last_window=VitalWindow.model_validate(reading) if reading else None,
            last_label=assessment.get("label"), last_confidence=assessment.get("confidence"),
            last_engine=assessment.get("engine"), last_deep_prob=assessment.get("deep_prob"),
            source=state.get("source", "device"), assessment_valid=valid,
            last_reading_id=reading.get("id") if reading else None, last_assessment_id=assessment.get("id"),
            last_sequence=state.get("last_sequence"),
            last_preictal_prob=assessment.get("preictal_prob") if valid else None,
            last_lead_time_min=assessment.get("lead_time_min") if valid else None,
            last_horizon_min=assessment.get("horizon_min") if valid else None,
            last_predicted=assessment.get("predicted") if valid else None,
            last_prediction_source=assessment.get("prediction_source") if valid else None,
            preictal_trajectory=state.get("trajectory", []) if valid else [],
        )
