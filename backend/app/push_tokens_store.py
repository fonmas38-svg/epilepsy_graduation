"""Private persistence and recipient resolution for push notifications."""
from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import delete, func, select

from app import users_store
from app.database import connection, push_tokens, transaction, upsert, users


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def register(user_id: str, token: str, platform: str = "unknown") -> None:
    """Upsert a token and transfer it exclusively to the current account.

    Cross-account isolation guarantee: a physical device token belongs to
    exactly one user_id at a time.  When account A logs out and account B logs
    in on the same handset, the FCM token is the same; we must move it from A
    to B so that B's alerts are delivered and A's are not.  The upsert already
    does this via on_conflict_do_update, but we make the intent explicit by
    first removing any *other* user's association with this token inside the
    same transaction.
    """
    now = _now()
    with transaction() as conn:
        # Step 1: remove association of this token from every OTHER user so the
        # physical device cannot receive alerts for a previous session's patient.
        conn.execute(
            delete(push_tokens).where(
                push_tokens.c.token == token,
                push_tokens.c.user_id != user_id,
            )
        )
        # Step 2: upsert for the current user (insert or update timestamp).
        conn.execute(upsert(push_tokens, {
            "id": str(uuid4()), "user_id": user_id, "token": token,
            "platform": platform, "created_at": now, "updated_at": now,
        }).on_conflict_do_update(
            index_elements=["token"],
            set_={"user_id": user_id, "platform": platform, "updated_at": now},
        ))



def unregister(user_id: str, token: str) -> bool:
    with transaction() as conn:
        result = conn.execute(delete(push_tokens).where(
            push_tokens.c.user_id == user_id,
            push_tokens.c.token == token,
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
        return int(conn.scalar(select(func.count()).select_from(push_tokens).where(
            push_tokens.c.user_id == user_id
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
            .join(users, users.c.id == push_tokens.c.user_id)
            .where(push_tokens.c.user_id.in_(user_ids), users.c.disabled.is_(False))
        ).scalars()
        return list(dict.fromkeys(rows))