"""Revocable human login sessions; never stores access tokens or passwords."""
from __future__ import annotations

import secrets
import time
from datetime import datetime, timezone

from sqlalchemy import delete, select, update

from app.database import account_sessions, connection, push_tokens, transaction, users


def stamp(epoch: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if epoch is None else epoch, timezone.utc).isoformat(timespec="microseconds")


def active_conditions(now: str | None = None):
    """Predicates for queries joining account_sessions and its owning user."""
    return (
        account_sessions.c.revoked_at.is_(None),
        account_sessions.c.expires_at > (now or stamp()),
        account_sessions.c.session_version == users.c.session_version,
        users.c.disabled.is_(False),
    )


def create(user_id: str, role: str, expires_epoch: int, *, device_name: str = "Unknown device",
           platform: str = "unknown", device_id: str | None = None, is_hardware_bound: bool = False,
           expected_version: int | None = None) -> dict:
    now = stamp()
    clean_device_id = device_id.strip()[:128] if (device_id and device_id.strip()) else None
    with transaction() as conn:
        # Serialize issuance with password/disable changes. The verified login
        # snapshot cannot become a fresh session after an intervening reset.
        user = conn.execute(select(users).where(users.c.id == user_id).with_for_update()).mappings().first()
        if not user or user["disabled"] or user["role"] != role:
            raise ValueError("Account is inactive")
        version = int(user["session_version"])
        if expected_version is not None and expected_version != version:
            raise ValueError("Account changed; sign in again")
        row = {
            "id": secrets.token_urlsafe(32), "user_id": user_id, "session_version": version,
            "device_name": device_name.strip()[:120] or "Unknown device",
            "platform": platform.strip().lower()[:32] or "unknown",
            "device_id": clean_device_id,
            "is_hardware_bound": bool(is_hardware_bound),
            "created_at": now, "last_seen_at": now, "expires_at": stamp(expires_epoch), "revoked_at": None,
        }
        conn.execute(account_sessions.insert().values(**row))
    return row


def get_active_session_on_other_device(user_id: str, device_id: str | None) -> dict | None:
    """Find an active session belonging to user_id on a device other than incoming device_id."""
    now = stamp()
    clean_device_id = device_id.strip()[:128] if (device_id and device_id.strip()) else None
    query = (
        select(account_sessions)
        .join(users, users.c.id == account_sessions.c.user_id)
        .where(
            account_sessions.c.user_id == user_id,
            *active_conditions(now),
        )
    )
    with connection() as conn:
        rows = conn.execute(query).mappings().all()
        for row in rows:
            existing_dev = row.get("device_id")
            if existing_dev:
                if clean_device_id is None or existing_dev != clean_device_id:
                    return dict(row)
            elif row.get("is_hardware_bound") and clean_device_id is not None:
                return dict(row)
    return None


def is_active(session_id: str, user_id: str, version: int, *, touch: bool = False) -> bool:
    now_epoch = time.time()
    now = stamp(now_epoch)
    query = select(account_sessions.c.id, account_sessions.c.last_seen_at).join(users, users.c.id == account_sessions.c.user_id).where(
        account_sessions.c.id == session_id, account_sessions.c.user_id == user_id,
        account_sessions.c.session_version == version, *active_conditions(now),
    )
    with transaction() if touch else connection() as conn:
        row = conn.execute(query).first()
        if row is None:
            return False
        if touch and row.last_seen_at < stamp(now_epoch - 60):
            # Coarse activity time avoids a write on every polling request.
            conn.execute(update(account_sessions).where(
                account_sessions.c.id == session_id,
                account_sessions.c.revoked_at.is_(None),
                account_sessions.c.last_seen_at < stamp(now_epoch - 60),
            ).values(last_seen_at=now))
    return True


def list_for_user(user_id: str, current_session_id: str, *, limit: int = 100) -> dict:
    now = stamp()
    with connection() as conn:
        rows = conn.execute(select(account_sessions, users.c.session_version.label("current_version"), users.c.disabled)
            .join(users, users.c.id == account_sessions.c.user_id)
            .where(account_sessions.c.user_id == user_id)
            .order_by((account_sessions.c.id == current_session_id).desc(),
                      account_sessions.c.created_at.desc(), account_sessions.c.id).limit(limit + 1)).mappings().all()
    return {
        "sessions": [{
            "id": row["id"], "deviceName": row["device_name"], "platform": row["platform"],
            "deviceId": row.get("device_id"),
            "isHardwareBound": bool(row.get("is_hardware_bound")),
            "createdAt": row["created_at"], "lastSeenAt": row["last_seen_at"],
            "expiresAt": row["expires_at"], "revokedAt": row["revoked_at"],
            "active": row["revoked_at"] is None and row["expires_at"] > now
                and row["session_version"] == row["current_version"] and not row["disabled"],
            "current": row["id"] == current_session_id,
        } for row in rows[:limit]],
        "currentSessionId": current_session_id, "hasMore": len(rows) > limit,
    }


def revoke(user_id: str, *, session_id: str | None = None, except_id: str | None = None) -> int | None:
    """Revoke owned sessions and their push routes in the same transaction.

    None means the specified session does not belong to this account. Locking
    session rows serializes this operation with push-token registration.
    """
    conditions = [account_sessions.c.user_id == user_id]
    if session_id is not None:
        conditions.append(account_sessions.c.id == session_id)
    if except_id is not None:
        conditions.append(account_sessions.c.id != except_id)
    with transaction() as conn:
        rows = conn.execute(select(account_sessions.c.id, account_sessions.c.revoked_at)
            .where(*conditions).with_for_update()).mappings().all()
        if session_id is not None and not rows:
            return None
        ids = [row["id"] for row in rows]
        if not ids:
            return 0
        result = conn.execute(update(account_sessions).where(
            account_sessions.c.id.in_(ids), account_sessions.c.revoked_at.is_(None),
        ).values(revoked_at=stamp()))
        conn.execute(delete(push_tokens).where(push_tokens.c.session_id.in_(ids)))
        return int(result.rowcount or 0)


def refresh_session(session_id: str, user_id: str, version: int, *, extension_seconds: int = 30 * 86400) -> dict | None:
    """Verify session is active, touch last_seen_at, extend expires_at, and return session row dict."""
    now_epoch = time.time()
    now = stamp(now_epoch)
    new_expiry = stamp(now_epoch + extension_seconds)
    query = select(account_sessions).join(
        users, users.c.id == account_sessions.c.user_id
    ).where(
        account_sessions.c.id == session_id,
        account_sessions.c.user_id == user_id,
        account_sessions.c.session_version == version,
        account_sessions.c.revoked_at.is_(None),
        account_sessions.c.expires_at > now,
        users.c.disabled.is_(False),
        users.c.session_version == version,
    )
    with transaction() as conn:
        row = conn.execute(query).mappings().first()
        if not row:
            return None
        conn.execute(update(account_sessions).where(
            account_sessions.c.id == session_id,
            account_sessions.c.revoked_at.is_(None),
        ).values(last_seen_at=now, expires_at=new_expiry))
        return dict(row)

