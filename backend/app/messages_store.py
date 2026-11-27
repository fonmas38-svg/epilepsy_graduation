"""SQL-backed message store for clinical and family communication channels."""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import NAMESPACE_URL, uuid4, uuid5
import json

from sqlalchemy import and_, func, or_, select, update

from app.database import message_receipts, messages, transaction, upsert

VALID_CHANNELS = (
    "doctor_patient",
    "patient_caregiver",
    "doctor_caregiver",
    "care_team_triage",
    "family_patient",
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _message(row) -> dict:
    r = row._mapping
    return {
        "id": r["id"],
        "patientId": r["patient_id"],
        "senderId": r["sender_id"],
        "senderName": r["sender_name"],
        "senderRole": r["sender_role"],
        "channelType": r["channel_type"],
        "peerUserId": r.get("peer_user_id"),
        "content": r["content"],
        "createdAt": r["created_at"],
        # Status is computed from per-recipient receipts (see _with_receipts):
        # until then "delivered" / "read" are unknown, never assumed.
        "acceptedAt": r.get("delivered_at"),
        "deliveredAt": None,
        "readAt": None,
        "deliveredCount": 0,
        "readCount": 0,
    }


def _with_receipts(conn, rows: list[dict]) -> list[dict]:
    """Attach delivery state from recipients (the sender's own receipt never
    counts): first delivery / first read time and how many received / read."""
    ids = [m["id"] for m in rows]
    if not ids:
        return rows
    stats = {
        r.message_id: r
        for r in conn.execute(
            select(
                message_receipts.c.message_id,
                func.min(message_receipts.c.delivered_at).label("delivered_at"),
                func.min(message_receipts.c.read_at).label("read_at"),
                func.count().label("delivered"),
                func.count(message_receipts.c.read_at).label("read"),
            )
            .select_from(message_receipts.join(messages, messages.c.id == message_receipts.c.message_id))
            .where(
                message_receipts.c.message_id.in_(ids),
                message_receipts.c.user_id != messages.c.sender_id,
            )
            .group_by(message_receipts.c.message_id)
        ).all()
    }
    for m in rows:
        st = stats.get(m["id"])
        if st is None:
            continue
        m["deliveredAt"] = st.delivered_at
        m["readAt"] = st.read_at
        m["deliveredCount"] = int(st.delivered or 0)
        m["readCount"] = int(st.read or 0)
    return rows


def _record_delivery(conn, rows: list[dict], viewer_id: str) -> None:
    """The viewer's app has now received these messages."""
    now = _now()
    for m in rows:
        if m["senderId"] == viewer_id:
            continue
        conn.execute(
            upsert(
                message_receipts,
                dict(message_id=m["id"], user_id=viewer_id, delivered_at=now, read_at=None),
            ).on_conflict_do_nothing(index_elements=["message_id", "user_id"])
        )


def create_message(
    *,
    patient_id: str,
    sender_id: str,
    sender_name: str,
    sender_role: str,
    channel_type: str,
    content: str,
    client_message_id: str | None = None,
    peer_user_id: str | None = None,
) -> dict:
    if channel_type not in VALID_CHANNELS:
        raise ValueError(f"Invalid channel_type: {channel_type}")
    content = (content or "").strip()
    if not content:
        raise ValueError("Message content cannot be empty")

    msg_id = (
        str(
            uuid5(
                NAMESPACE_URL,
                json.dumps([patient_id, sender_id, client_message_id]),
            )
        )
        if client_message_id
        else str(uuid4())
    )
    created_at = _now()
    clean_peer = (peer_user_id or "").strip() or None
    with transaction() as conn:
        conn.execute(
            upsert(
                messages,
                dict(
                    id=msg_id,
                    patient_id=patient_id,
                    sender_id=sender_id,
                    sender_name=sender_name,
                    sender_role=sender_role,
                    channel_type=channel_type,
                    peer_user_id=clean_peer,
                    content=content,
                    created_at=created_at,
                    delivered_at=created_at,
                    read_at=None,
                ),
            ).on_conflict_do_nothing(index_elements=["id"])
        )
        row = conn.execute(select(messages).where(messages.c.id == msg_id)).one()
        saved = _with_receipts(conn, [_message(row)])[0]
        if (saved["content"] != content or saved["channelType"] != channel_type
                or saved["peerUserId"] != clean_peer):
            raise ValueError("client_message_id already used for a different message")
        return saved


def _visibility(viewer_id: str, viewer_role: str):
    """Apply permissions before pagination, including unfiltered requests."""
    if viewer_role == "admin":
        return messages.c.channel_type.in_(VALID_CHANNELS)
    allowed = [messages.c.channel_type.in_(("family_patient", "care_team_triage"))]
    if viewer_role in ("patient", "doctor"):
        allowed.append(messages.c.channel_type == "doctor_patient")
    private = {
        "patient": ("patient_caregiver",),
        "doctor": ("doctor_caregiver",),
        "caregiver": ("patient_caregiver", "doctor_caregiver"),
    }.get(viewer_role, ())
    if private:
        predicate = messages.c.channel_type.in_(private)
        if viewer_role == "caregiver":
            predicate = and_(predicate, messages.c.peer_user_id == viewer_id)
        allowed.append(predicate)
    return or_(*allowed)


def list_messages(
    patient_id: str,
    channel_type: str | None = None,
    peer_user_id: str | None = None,
    limit: int = 100,
    offset: int = 0,
    latest: bool = False,
    viewer_id: str | None = None,
    viewer_role: str | None = None,
) -> list[dict]:
    query = select(messages).where(messages.c.patient_id == patient_id)
    if viewer_id is not None:
        query = query.where(_visibility(viewer_id, viewer_role or ""))
    if channel_type:
        query = query.where(messages.c.channel_type == channel_type)
    if peer_user_id:
        query = query.where(messages.c.peer_user_id == peer_user_id)
    ordering = (
        (messages.c.created_at.desc(), messages.c.id.desc())
        if latest
        else (messages.c.created_at.asc(), messages.c.id.asc())
    )
    query = query.order_by(*ordering).limit(limit).offset(offset)
    with transaction() as conn:
        rows = conn.execute(query).all()
        out = [_message(r) for r in (reversed(rows) if latest else rows)]
        if viewer_id is not None:
            _record_delivery(conn, out, viewer_id)
        return _with_receipts(conn, out)


def mark_messages_read(
    patient_id: str,
    reader_id: str,
    channel_type: str | None = None,
    peer_user_id: str | None = None,
    viewer_role: str | None = None,
) -> int:
    now = _now()
    scope = [
        messages.c.patient_id == patient_id,
        messages.c.sender_id != reader_id,
    ]
    if channel_type:
        scope.append(messages.c.channel_type == channel_type)
    if peer_user_id:
        scope.append(messages.c.peer_user_id == peer_user_id)
    if viewer_role is not None:
        scope.append(_visibility(reader_id, viewer_role))
    receipt_conditions = scope
    conditions = [*scope, messages.c.read_at.is_(None)]
    with transaction() as conn:
        # Per-reader receipts: this participant has read them.
        ids = [
            r.id
            for r in conn.execute(select(messages.c.id).where(*receipt_conditions)).all()
        ]
        for mid in ids:
            conn.execute(
                upsert(
                    message_receipts,
                    dict(message_id=mid, user_id=reader_id, delivered_at=now, read_at=now),
                ).on_conflict_do_update(
                    index_elements=["message_id", "user_id"],
                    set_={"read_at": func.coalesce(message_receipts.c.read_at, now)},
                )
            )
        # Legacy column (first reader), kept for older clients.
        res = conn.execute(
            update(messages)
            .where(*conditions)
            .values(read_at=now)
        )
        return int(res.rowcount or 0)
