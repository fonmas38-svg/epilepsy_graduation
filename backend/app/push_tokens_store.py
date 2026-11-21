"""Private persistence and recipient resolution for push notifications."""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import delete, func, or_, select

from app import account_sessions_store, users_store
from app.database import account_sessions, connection, push_tokens, transaction, upsert, users


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def register(user_id: str, token: str, platform: str = "unknown", *, session_id: str) -> None:
    """Upsert a token and transfer it exclusively to the current account.

    One registration token belongs to exactly one login session at a time.
    A delayed registration from a previously issued session cannot reclaim
    the token after a later-issued session registered it. Device labels are
    descriptions, not attested physical hardware identities.
    """
    now = _now()
    with transaction() as conn:
        active = conn.execute(select(account_sessions.c.id, account_sessions.c.created_at)
            .join(users, users.c.id == account_sessions.c.user_id).where(
                account_sessions.c.id == session_id, account_sessions.c.user_id == user_id,
                *account_sessions_store.active_conditions(),
            ).with_for_update()).first()
        if active is None:
            raise ValueError("Session is inactive; sign in again")
        previous_issued_at = select(account_sessions.c.created_at).where(
            account_sessions.c.id == push_tokens.c.session_id,
        ).correlate(push_tokens).scalar_subquery()
        result = conn.execute(upsert(push_tokens, {
            "id": str(uuid4()), "user_id": user_id, "token": token,
            "platform": platform, "session_id": session_id, "created_at": now, "updated_at": now,
        }).on_conflict_do_update(
            index_elements=["token"],
            set_={"user_id": user_id, "platform": platform, "session_id": session_id, "updated_at": now},
            where=or_(push_tokens.c.session_id.is_(None), push_tokens.c.session_id == session_id,
                      previous_issued_at <= active.created_at),
        ))
        if not result.rowcount:
            raise ValueError("A newer session owns this notification route")



def unregister(user_id: str, token: str, *, session_id: str) -> bool:
    with transaction() as conn:
        result = conn.execute(delete(push_tokens).where(
            push_tokens.c.user_id == user_id,
            push_tokens.c.token == token,
            push_tokens.c.session_id == session_id,
        ))
        return bool(result.rowcount)


def remove_tokens(tokens: list[str]) -> int:
    if not tokens:
        return 0
    with transaction() as conn:
        result = conn.execute(delete(push_tokens).where(push_tokens.c.token.in_(tokens)))
        return int(result.rowcount or 0)


def count_for_user(user_id: str) -> int:
    with connection() as conn:
        return int(conn.scalar(select(func.count()).select_from(push_tokens)
            .join(account_sessions, account_sessions.c.id == push_tokens.c.session_id)
            .join(users, users.c.id == account_sessions.c.user_id).where(
                push_tokens.c.user_id == user_id, push_tokens.c.user_id == users.c.id,
                *account_sessions_store.active_conditions(),
            )) or 0)


def _recipient_user_ids(patient_id: str, recipients: list[str]) -> set[str]:
    """Resolve role names and authorized explicit IDs; ignore unrelated IDs."""
    requested = {str(value) for value in recipients}
    allowed = {patient_id}
    caregivers = set(users_store.caregivers_for_patient(patient_id))
    doctors = set(users_store.doctors_for_patient(patient_id))
    allowed.update(caregivers)
    allowed.update(doctors)

    selected: set[str] = set()
    if "patient" in requested:
        selected.add(patient_id)
    if "caregiver" in requested:
        selected.update(caregivers)
    if "doctor" in requested:
        selected.update(doctors)
    if "admin" in requested:
        selected.update(u["id"] for u in users_store.list_users(
            role="admin", include_disabled=False
        ))
    # Explicit UIDs are accepted only if they already belong to this patient's
    # authorized care graph. This prevents a client-controlled payload from
    # becoming an arbitrary push-message relay.
    selected.update(requested & allowed)
    return selected


def tokens_for_alert(patient_id: str, recipients: list[str]) -> list[str]:
    user_ids = _recipient_user_ids(patient_id, recipients)
    if not user_ids:
        return []
    with connection() as conn:
        rows = conn.execute(
            select(push_tokens.c.token)
            .join(account_sessions, account_sessions.c.id == push_tokens.c.session_id)
            .join(users, users.c.id == account_sessions.c.user_id)
            .where(push_tokens.c.user_id.in_(user_ids), push_tokens.c.user_id == users.c.id,
                   *account_sessions_store.active_conditions())
        ).scalars()
        return list(dict.fromkeys(rows))
