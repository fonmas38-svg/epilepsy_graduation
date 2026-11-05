"""Device durability, clock safety and concurrent-worker regressions."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from threading import Event
from types import SimpleNamespace

import pytest

from app import alert_outbox, cloud_store
from app.device_hub import DeviceHub, DeviceSample
from app.preprocessing import extract_features


class HighRiskClassifier:
    def predict_window(self, window):
        return SimpleNamespace(label="high_risk", confidence=0.9, features=extract_features(window),
                               engine="rules", components={"assessment_valid": True})


def samples(n=262):
    return [DeviceSample(eeg=0.1 + i % 7, ecg=0.2 + i % 3, motion=0.1, hr=120) for i in range(n)]


def test_device_event_survives_restart_and_retry_without_a_phone():
    classifier = HighRiskClassifier()
    assert DeviceHub().ingest("p1", "d1", samples(128), classifier,
                              batch_id="first", sequence_number=1)["assessment"] is None
    rest = samples(134)
    result = DeviceHub().ingest("p1", "d1", rest, classifier, batch_id="second", sequence_number=2)
    assert result["assessment"]["label"] == "high_risk"
    assert len(cloud_store.list_readings("p1")) == 1
    assert len(cloud_store.list_assessments("p1")) == 1
    assert len(cloud_store.list_alerts("p1")) == 1
    assert alert_outbox.stats()["pending"] == 1
    replay = DeviceHub().ingest("p1", "d1", rest, classifier, batch_id="second", sequence_number=2)
    assert replay["duplicate"] and replay["accepted"] == 0
    assert replay["assessment"]["id"] == result["assessment"]["id"]
    assert alert_outbox.stats()["total"] == 1
    assert DeviceHub().status("p1").last_assessment_id == result["assessment"]["id"]


def test_failed_device_commit_does_not_consume_batch(monkeypatch):
    batch = samples()
    with monkeypatch.context() as patch:
        patch.setattr(cloud_store, "save_monitoring_bundle", lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("storage failed")))
        with pytest.raises(RuntimeError, match="storage failed"):
            DeviceHub().ingest("p1", "d1", batch, HighRiskClassifier(), batch_id="retry", sequence_number=1)
    assert DeviceHub().status("p1") is None
    result = DeviceHub().ingest("p1", "d1", batch, HighRiskClassifier(), batch_id="retry", sequence_number=1)
    assert result["accepted"] == 262
    assert alert_outbox.stats()["pending"] == 1


def test_device_buffers_do_not_mix_devices_and_reject_changed_replay():
    hub = DeviceHub()
    batch = samples(131)
    hub.ingest("p1", "d1", batch, HighRiskClassifier(), batch_id="one")
    hub.ingest("p1", "d2", batch, HighRiskClassifier(), batch_id="one")
    assert cloud_store.list_assessments("p1") == []
    with pytest.raises(ValueError, match="different samples"):
        hub.ingest("p1", "d1", samples(132), HighRiskClassifier(), batch_id="one")


def test_device_status_expires(monkeypatch):
    import app.device_hub as module
    hub = DeviceHub()
    hub.ingest("p1", "d1", samples(), HighRiskClassifier(), batch_id="one")
    later = datetime.now(timezone.utc) + timedelta(minutes=1)
    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return later
    monkeypatch.setattr(module, "datetime", Clock)
    status = DeviceHub().status("p1")
    assert not status.connected
    assert not status.assessment_valid
    assert status.last_preictal_prob is None


def test_historical_assessment_cannot_rewind_status():
    now = datetime.now(timezone.utc)
    cloud_store.add_assessment("p1", {"id": "new", "timestamp": now.isoformat(), "label": "high_risk"})
    cloud_store.add_assessment("p1", {"id": "old", "timestamp": (now - timedelta(days=1)).isoformat(), "label": "stable"})
    assert cloud_store.get_patient("p1")["currentStatus"] == "high_risk"


def test_outbox_workers_claim_exclusively_and_recover_abandoned_leases(monkeypatch):
    cloud_store.add_alert("p1", {"id": "one", "severity": "critical"})
    entered, release = Event(), Event()
    sent = []
    def send(payload):
        sent.append(payload["id"])
        entered.set()
        assert release.wait(timeout=10)
    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(alert_outbox.process_once, send)
        try:
            assert entered.wait(timeout=10)
            second = pool.submit(alert_outbox.process_once, send).result(timeout=10)
            assert second["processed"] == 0
        finally:
            release.set()
        assert first.result(timeout=10)["sent"] == 1
    assert sent == ["one"]
    cloud_store.add_alert("p1", {"id": "abandoned", "severity": "critical"})
    entry = alert_outbox.due_entries()[0]
    assert alert_outbox._claim(entry["id"])
    assert alert_outbox.due_entries() == []
    later = alert_outbox._now() + timedelta(seconds=alert_outbox.LEASE_SECONDS + 1)
    monkeypatch.setattr(alert_outbox, "_now", lambda: later)
    assert alert_outbox.process_once(lambda payload: sent.append(payload["id"]))["sent"] == 1
    assert sent == ["one", "abandoned"]
