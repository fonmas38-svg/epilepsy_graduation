"""Notification delivery boundary: explicit local stub or Firebase Cloud Messaging."""
from __future__ import annotations

import logging
import os
from pathlib import Path
from threading import Lock

from app import push_tokens_store

log = logging.getLogger("epilepsy.notify")
_firebase_lock = Lock()


def channel() -> str:
    return os.getenv("NOTIFICATION_CHANNEL", "stub").strip().lower()


def validate_configuration() -> None:
    """Initialize the selected production adapter so bad credentials fail fast."""
    if channel() != "fcm":
        return
    _firebase_messaging()


def _firebase_messaging():
    """Initialize Firebase once, lazily, so demo/test installs need no SDK."""
    try:
        import firebase_admin
        from firebase_admin import credentials, messaging
    except ImportError as exc:  # pragma: no cover - depends on deployment extras
        raise RuntimeError(
            "firebase-admin is required when NOTIFICATION_CHANNEL=fcm"
        ) from exc

    with _firebase_lock:
        if not firebase_admin._apps:  # SDK's documented initialized-app registry
            credential_path = os.getenv("FIREBASE_CREDENTIALS")
            if credential_path:
                path = Path(credential_path).expanduser()
                if not path.is_file():
                    raise RuntimeError("FIREBASE_CREDENTIALS file does not exist")
                firebase_admin.initialize_app(credentials.Certificate(str(path)))
            else:
                # Application Default Credentials: suitable for Google Cloud or
                # GOOGLE_APPLICATION_CREDENTIALS without committing a JSON key.
                firebase_admin.initialize_app()
    return messaging


def _is_invalid_token_error(exc: Exception | None) -> bool:
    if exc is None:
        return False
    name = type(exc).__name__.lower()
    text = str(exc).lower()
    return any(marker in name or marker in text for marker in (
        "unregistered", "invalidargument", "invalid registration token",
        "registration-token-not-registered",
    ))


def deliver(payload: dict) -> dict:
    """Deliver one outbox payload or raise so the outbox retries it."""
    selected_channel = channel()
    patient_id = str(payload.get("patient_id") or payload.get("patientId") or "")
    if selected_channel == "stub":
        log.info("dispatching alert in stub mode", extra={
            "patient_id": patient_id, "severity": payload.get("severity"),
            "channel": "stub",
        })
        return {"channel": "stub", "success": 1, "failure": 0}
    if selected_channel != "fcm":
        raise RuntimeError(f"unsupported NOTIFICATION_CHANNEL: {selected_channel}")

    recipients = [str(item) for item in payload.get("recipients", [])]
    tokens = push_tokens_store.tokens_for_alert(patient_id, recipients)
    if not tokens:
        raise RuntimeError("no registered FCM tokens for alert recipients")

    messaging = _firebase_messaging()
    severity = str(payload.get("severity") or "critical")
    title = "Critical seizure alert" if severity == "critical" else "Patient alert"
    message = messaging.MulticastMessage(
        notification=messaging.Notification(
            title=title,
            body=str(payload.get("message") or "Patient requires attention."),
        ),
        data={
            "patient_id": patient_id,
            "alert_id": str(payload.get("id") or ""),
            "severity": severity,
        },
        tokens=tokens,
    )
    response = messaging.send_each_for_multicast(message)
    invalid = [
        token for token, item in zip(tokens, response.responses)
        if not item.success and _is_invalid_token_error(item.exception)
    ]
    if invalid:
        push_tokens_store.remove_tokens(invalid)
    transient_failures = response.failure_count - len(invalid)
    if transient_failures > 0:
        # Successful tokens may receive a duplicate on retry. The outbox is
        # intentionally at-least-once: duplicate medical alerts are safer than loss.
        raise RuntimeError(f"FCM transient failures: {transient_failures}")
    log.info("FCM alert dispatched", extra={
        "patient_id": patient_id, "severity": severity, "channel": "fcm",
        "success_count": response.success_count,
        "invalid_token_count": len(invalid),
    })
    return {
        "channel": "fcm", "success": response.success_count,
        "failure": response.failure_count, "invalid_tokens_removed": len(invalid),
    }