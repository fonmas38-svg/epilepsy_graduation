"""The background worker path, which the rest of the suite deliberately disables.

Without this file the worker started in lifespan would ship untested: a mistake
there would mean alerts are queued forever and never delivered.

These tests drive the loop with asyncio.run instead of pytest-asyncio, to avoid
adding a test dependency for three tests.
"""
from __future__ import annotations

import asyncio

from app import alert_outbox, cloud_store
from app.main import _drain_outbox_forever, deliver_notification

CRITICAL_ALERT = {
    "id": "worker-alert-1",
    "severity": "critical",
    "message": "High seizure risk",
}


async def _run_worker_until(predicate, timeout: float = 3.0) -> bool:
    """Run the worker until `predicate()` holds, then cancel it cleanly.

    Returns whether the worker was still alive when the condition was met.
    """
    worker = asyncio.create_task(_drain_outbox_forever(0.01))
    satisfied = False
    deadline = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < deadline:
        await asyncio.sleep(0.01)
        if predicate():
            satisfied = True
            break
    alive = not worker.done()
    worker.cancel()
    try:
        await worker
    except asyncio.CancelledError:
        pass
    return satisfied and alive


def test_worker_drains_pending_alerts_and_cancels_cleanly():
    cloud_store.add_alert("p-worker", CRITICAL_ALERT)
    assert alert_outbox.stats()["pending"] == 1

    delivered_and_alive = asyncio.run(
        _run_worker_until(lambda: alert_outbox.stats()["sent"] == 1)
    )

    assert delivered_and_alive
    stats = alert_outbox.stats()
    assert stats["sent"] == 1
    assert stats["pending"] == 0


def test_worker_survives_a_failing_delivery_cycle(monkeypatch):
    """A failing cycle must not kill the loop, or later alerts would stall."""
    calls = {"count": 0}

    def always_failing(_payload):
        calls["count"] += 1
        raise ConnectionError("FCM unreachable")

    monkeypatch.setattr("app.main.deliver_notification", always_failing)
    cloud_store.add_alert("p-worker", CRITICAL_ALERT)

    still_alive = asyncio.run(_run_worker_until(lambda: calls["count"] >= 1))

    assert still_alive
    # The alert is retained as failed for a later retry — never dropped.
    assert alert_outbox.stats()["failed"] == 1


def test_default_sender_is_safe_to_call():
    # The stub must not raise, otherwise every delivery would be retried forever.
    deliver_notification({"patient_id": "p1", "severity": "critical"})
