"""SQL-backed message store for clinical and family communication channels."""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import desc, insert, select, update

from app.database import connection, messages, transaction


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
) -> dict:
    if channel_type not in ("doctor_patient", "family_patient"):
        raise ValueError(f"Invalid channel_type: {channel_type}")
    content = (content or "").strip()
    if not content:
        raise ValueError("Message content cannot be empty")

    msg_id = str(uuid4())
    created_at = _now()
    with transaction() as conn:
        conn.execute(
            insert(messages).values(
                id=msg_id,
                patient_id=patient_id,
                sender_id=sender_id,
                sender_name=sender_name,
                sender_role=sender_role,
                channel_type=channel_type,
                content=content,
                created_at=created_at,
                read_at=None,
            )
        )
    return {
        "id": msg_id,
        "patientId": patient_id,
        "senderId": sender_id,
        "senderName": sender_name,
        "senderRole": sender_role,
        "channelType": channel_type,
        "content": content,
        "createdAt": created_at,
        "readAt": None,
    }


def list_messages(
    patient_id: str,
    channel_type: str | None = None,
    limit: int = 100,
    offset: int = 0,
) -> list[dict]:
    query = select(messages).where(messages.c.patient_id == patient_id)
    if channel_type:
        query = query.where(messages.c.channel_type == channel_type)
    query = query.order_by(messages.c.created_at.asc()).limit(limit).offset(offset)
    with connection() as conn:
        rows = conn.execute(query).all()
        return [_message(r) for r in rows]
