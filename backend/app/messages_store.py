"""SQL-backed message store for clinical and family communication channels."""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import NAMESPACE_URL, uuid4, uuid5
import json

from sqlalchemy import select

from app.database import connection, messages, transaction, upsert


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
        "content": r["content"],
        "createdAt": r["created_at"],
        "readAt": r["read_at"],
    }


def create_message(
    *,
    patient_id: str,
    sender_id: str,
    sender_name: str,
    sender_role: str,
    channel_type: str,
    content: str,
    client_message_id: str | None = None,
) -> dict:
    if channel_type not in ("doctor_patient", "family_patient"):
        raise ValueError(f"Invalid channel_type: {channel_type}")
    content = (content or "").strip()
    if not content:
        raise ValueError("Message content cannot be empty")

    msg_id = str(uuid5(NAMESPACE_URL, json.dumps(
        [patient_id, sender_id, client_message_id]
    ))) if client_message_id else str(uuid4())
    created_at = _now()
    with transaction() as conn:
        conn.execute(
            upsert(messages, dict(
                id=msg_id,
                patient_id=patient_id,
                sender_id=sender_id,
                sender_name=sender_name,
                sender_role=sender_role,
                channel_type=channel_type,
                content=content,
                created_at=created_at,
                read_at=None,
            )).on_conflict_do_nothing(index_elements=["id"])
        )
        row = conn.execute(select(messages).where(messages.c.id == msg_id)).one()
        saved = _message(row)
        if saved["content"] != content or saved["channelType"] != channel_type:
            raise ValueError("client_message_id already used for a different message")
        return saved



def list_messages(
    patient_id: str,
    channel_type: str | None = None,
    limit: int = 100,
    offset: int = 0,
    latest: bool = False,
) -> list[dict]:
    query = select(messages).where(messages.c.patient_id == patient_id)
    if channel_type:
        query = query.where(messages.c.channel_type == channel_type)
    ordering = (messages.c.created_at.desc(), messages.c.id.desc()) if latest else (
        messages.c.created_at.asc(), messages.c.id.asc()
    )
    query = query.order_by(*ordering).limit(limit).offset(offset)
    with connection() as conn:
        rows = conn.execute(query).all()
        return [_message(r) for r in (reversed(rows) if latest else rows)]
