"""Transactional outbox for alert notifications.

Why this exists
---------------
Persisting an alert (our database) and delivering a push notification (an
external service) cannot share one transaction: a sent notification cannot be
rolled back. Writing the *intent* to the same database in the same transaction
can be atomic, so we do that and let a worker perform the delivery.

Guarantees
    * atomic     — an alert and its delivery record commit together,
    * retried    — transient failures back off exponentially instead of hammering,
    * observable  — exhausted rows stay as ``dead`` and surface in /metrics,
    * at-least-once — a crash after sending may redeliver. For a medical alert a
      duplicate is far safer than a miss, and exactly-once is unachievable
      against a third-party service.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Callable
from uuid import uuid4

from sqlalchemy import func, select, update
from sqlalchemy.engine import Connection

from app.database import (
    alert_outbox,
    connection,
    dump_json,
    load_json,
    transaction,
    upsert,
)


log = logging.getLogger("epilepsy.outbox")

MAX_ATTEMPTS = 5
BASE_BACKOFF_SECONDS = 10
PENDING, SENT, FAILED, DEAD = "pending", "sent", "failed", "dead"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(value: datetime) -> str:
    return value.isoformat()


def backoff_seconds(attempts: int) -> int:
    """10s, 20s, 40s, ... capped so a long outage cannot push retries too far."""
    return min(BASE_BACKOFF_SECONDS * (2 ** max(0, attempts - 1)), 600)


def _row_to_dict(row) -> dict:
    data = dict(row._mapping)
    data["payload"] = load_json(data.pop("payload_json", None), {})
    return data


def enqueue(conn: Connection, patient_id: str, alert: dict[str, Any]) -> dict:
    """Record a delivery intent. MUST be called inside the alert's transaction.

    Idempotent per alert id, so a retried ingestion cannot double-notify.
    """
    alert_id = str(alert.get("id") or uuid4())
    now = _now()
    values = {
        "id": str(uuid4()),
        "alert_id": alert_id,
        "patient_id": patient_id,
        "payload_json": dump_json(alert),
        "status": PENDING,
        "attempts": 0,
        "next_attempt_at": _iso(now),
        "last_error": None,
        "created_at": _iso(now),
        "updated_at": _iso(now),
    }
    conn.execute(
        upsert(alert_outbox, values).on_conflict_do_nothing(index_elements=["alert_id"])
    )

    row = conn.execute(
        select(alert_outbox).where(alert_outbox.c.alert_id == alert_id)
    ).first()
    return _row_to_dict(row)


def enqueue_standalone(patient_id: str, alert: dict[str, Any]) -> dict:
    """Enqueue outside an existing transaction (used by the /alerts endpoint)."""
    with transaction() as conn:
        return enqueue(conn, patient_id, alert)


def due_entries(limit: int = 20) -> list[dict]:
    now = _iso(_now())
    with connection() as conn:
        rows = conn.execute(
            select(alert_outbox)
            .where(alert_outbox.c.status.in_([PENDING, FAILED]))
            .where(alert_outbox.c.next_attempt_at <= now)
            .order_by(alert_outbox.c.next_attempt_at)
            .limit(limit)
        ).all()
    return [_row_to_dict(row) for row in rows]


def mark_sent(entry_id: str) -> None:
    now = _iso(_now())
    with transaction() as conn:
        conn.execute(
            update(alert_outbox)
            .where(alert_outbox.c.id == entry_id)
            .values(status=SENT, updated_at=now, last_error=None)
        )


def mark_failure(entry_id: str, error: str) -> str:
    """Record a failed attempt and return the resulting status."""
    now = _now()
    with transaction() as conn:
        row = conn.execute(
            select(alert_outbox.c.attempts).where(alert_outbox.c.id == entry_id)
        ).first()
        if row is None:
            return DEAD
        attempts = int(row._mapping["attempts"]) + 1
        exhausted = attempts >= MAX_ATTEMPTS
        status = DEAD if exhausted else FAILED
        conn.execute(
            update(alert_outbox)
            .where(alert_outbox.c.id == entry_id)
            .values(
                status=status,
                attempts=attempts,
                # Keep a due date even when dead so ordering stays well-defined.
                next_attempt_at=_iso(
                    now + timedelta(seconds=backoff_seconds(attempts))
                ),
                last_error=error[:500],
                updated_at=_iso(now),
            )
        )
    return status


def process_once(sender: Callable[[dict], None], limit: int = 20) -> dict[str, int]:
    """Attempt delivery for every due entry. Never raises: a bad sender must not
    kill the worker loop."""
    result = {"processed": 0, "sent": 0, "failed": 0, "dead": 0}
    for entry in due_entries(limit):
        result["processed"] += 1
        try:
            sender(entry["payload"])
        except Exception as exc:  # noqa: BLE001 - failure is an expected path
            status = mark_failure(entry["id"], f"{type(exc).__name__}: {exc}")
            result["dead" if status == DEAD else "failed"] += 1
            log.warning(
                "alert delivery failed (attempt recorded, status=%s) alert_id=%s: %s",
                status, entry["alert_id"], exc,
            )
            continue
        mark_sent(entry["id"])
        result["sent"] += 1
    return result


def stats() -> dict[str, int]:
    """Counts per status — consumed by /metrics and readiness reporting."""
    counts = {PENDING: 0, SENT: 0, FAILED: 0, DEAD: 0}
    with connection() as conn:
        rows = conn.execute(
            select(alert_outbox.c.status, func.count().label("total"))
            .group_by(alert_outbox.c.status)
        ).all()
    for row in rows:
        counts[row._mapping["status"]] = int(row._mapping["total"])
    # Sum the statuses before adding the aggregate key, or total counts itself.
    total = sum(counts.values())
    counts["total"] = total
    return counts


def list_entries(status: str | None = None, limit: int = 50) -> list[dict]:
    query = select(alert_outbox).order_by(alert_outbox.c.created_at.desc()).limit(limit)
    if status:
        query = query.where(alert_outbox.c.status == status)
    with connection() as conn:
        return [_row_to_dict(row) for row in conn.execute(query).all()]
