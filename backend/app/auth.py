"""
JWT authentication for device ingestion and clinician endpoints.

Upgrades the previous static shared token (`headband-demo-token`) to signed,
expiring JWTs with roles. Backward compatibility: if AUTH_ALLOW_LEGACY_TOKEN=1
the old static token is still accepted (useful during migration), but this
should be OFF in any real deployment.

Dependencies (add to backend/requirements.txt):
    pyjwt>=2.9.0
    passlib[bcrypt]>=1.7.4    # only if you add password login

Environment:
    JWT_SECRET             HMAC secret (REQUIRED in prod; dev fallback provided)
    JWT_EXPIRE_MINUTES     access-token lifetime (default 60)
    AUTH_ALLOW_LEGACY_TOKEN  '1' to also accept the old static device token
"""
from __future__ import annotations

import time
from typing import Literal

from fastapi import Depends, Header, HTTPException, status

from app.settings import settings

try:
    import jwt  # PyJWT
except ImportError:  # pragma: no cover
    jwt = None

Role = Literal["device", "patient", "caregiver", "doctor", "admin"]

JWT_SECRET = settings.jwt_secret
JWT_ALG = "HS256"
JWT_EXPIRE_MINUTES = settings.jwt_expire_minutes
LEGACY_TOKEN = "headband-demo-token"
# Defaults ON so the demo gateway + existing tests keep working out of the box.
# !!! SECURITY: set AUTH_ALLOW_LEGACY_TOKEN=0 in any real deployment. A static
#     shared token is not real authentication.
ALLOW_LEGACY = settings.allow_legacy_token


class AuthError(HTTPException):
    def __init__(self, detail: str, code: int = status.HTTP_401_UNAUTHORIZED):
        super().__init__(status_code=code, detail=detail)


def create_token(subject: str, role: Role, extra: dict | None = None, *,
                 session_context: dict | None = None, expected_session_version: int | None = None) -> str:
    """Issue a signed JWT. `subject` is e.g. device_id or user_id."""
    if jwt is None:
        raise RuntimeError("PyJWT not installed. pip install pyjwt")
    now = int(time.time())
    payload = {
        "sub": subject,
        "role": role,
        "iat": now,
        "exp": now + JWT_EXPIRE_MINUTES * 60,
    }
    if extra:
        # Callers may add device bindings/profile hints, never replace identity
        # or revocation claims with user-controlled values.
        payload.update({key: value for key, value in extra.items()
                        if key not in {"sub", "role", "iat", "exp", "sid", "session_version"}})
    if role in ("patient", "caregiver", "doctor", "admin"):
        from app import account_sessions_store

        session_lifetime = int(getattr(settings, "session_lifetime_seconds", 30 * 86400))
        session_expiry = now + session_lifetime
        try:
            session = account_sessions_store.create(subject, role, session_expiry,
                expected_version=expected_session_version, **(session_context or {}))
        except account_sessions_store.DeviceBindingConflict as exc:
            raise AuthError(str(exc), code=status.HTTP_409_CONFLICT) from exc
        except ValueError as exc:
            raise AuthError(str(exc)) from exc
        payload["session_version"] = session["session_version"]
        payload["sid"] = session["id"]
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)


def issue_access_token(subject: str, role: Role, sid: str, session_version: int, extra: dict | None = None) -> str:
    """Issue a new access token for an active session without inserting a new session row."""
    if jwt is None:
        raise RuntimeError("PyJWT not installed. pip install pyjwt")
    now = int(time.time())
    payload = {
        "sub": subject,
        "role": role,
        "iat": now,
        "exp": now + JWT_EXPIRE_MINUTES * 60,
        "sid": sid,
        "session_version": session_version,
    }
    if extra:
        payload.update({key: value for key, value in extra.items()
                        if key not in {"sub", "role", "iat", "exp", "sid", "session_version"}})
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)


def decode_token(token: str) -> dict:
    if jwt is None:
        raise RuntimeError("PyJWT not installed. pip install pyjwt")
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    except jwt.ExpiredSignatureError:
        raise AuthError("Token expired")
    except jwt.InvalidTokenError:
        raise AuthError("Invalid token")


def decode_token_for_refresh(token: str) -> dict:
    """Decode a JWT verifying signature, allowing expired access tokens for session refresh."""
    if jwt is None:
        raise RuntimeError("PyJWT not installed. pip install pyjwt")
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG], options={"verify_exp": False})
    except jwt.InvalidTokenError:
        raise AuthError("Invalid token")


def _extract_bearer(authorization: str | None) -> str:
    if not authorization:
        raise AuthError("Missing Authorization header")
    parts = authorization.split()
    if len(parts) == 2 and parts[0].lower() == "bearer":
        return parts[1]
    # tolerate a bare token
    return authorization.strip()


def get_current_principal(authorization: str | None = Header(default=None)) -> dict:
    """FastAPI dependency: returns the decoded principal ({sub, role, ...})."""
    token = _extract_bearer(authorization)
    if ALLOW_LEGACY and token == LEGACY_TOKEN:
        if settings.require_patient_auth:
            raise AuthError("Legacy device token is not allowed for patient-scoped access")
        return {"sub": "legacy-device", "role": "device", "legacy": True}
    principal = decode_token(token)
    role = principal.get("role")
    if role in ("patient", "caregiver", "doctor", "admin"):
        from app import account_sessions_store, users_store

        user = users_store.get_user(str(principal.get("sub", "")))
        if not user or user.get("disabled"):
            raise AuthError("Account is inactive")
        if int(principal.get("session_version", 0)) != int(user.get("sessionVersion", 0)):
            raise AuthError("Session has been revoked")
        session_id = principal.get("sid")
        # Explicit migration policy: unregistered legacy human JWTs require a
        # new login. Device JWTs keep their separate credential-version policy.
        if (user.get("role") != role or not isinstance(session_id, str) or not session_id
                or not account_sessions_store.is_active(session_id, user["id"], int(user["sessionVersion"]), touch=True)):
            raise AuthError("Session is inactive; sign in again")
    elif role == "device" and (settings.is_production or "credential_version" in principal):
        from app import device_store

        if not device_store.token_is_active(
            str(principal.get("sub", "")), principal.get("patient_id"),
            int(principal.get("credential_version", -1)),
        ):
            raise AuthError("Device credential has been revoked")
    return principal


def get_optional_principal(authorization: str | None = Header(default=None)) -> dict:
    """Return a principal for patient routes with demo-only compatibility.

    This exists for the local simulator and old clients that only read demo
    data. It is deliberately impossible to use anonymously in production.
    """
    if not authorization and not settings.require_patient_auth:
        return {"sub": "demo-user", "role": "admin", "demo": True}
    return get_current_principal(authorization)


def require_role(*allowed: Role):
    """Dependency factory enforcing that the caller has one of `allowed` roles."""

    def _dep(principal: dict = Depends(get_current_principal)) -> dict:
        if principal.get("role") not in allowed:
            raise AuthError(
                f"Role '{principal.get('role')}' not permitted; needs {allowed}",
                code=status.HTTP_403_FORBIDDEN,
            )
        return principal

    return _dep


def authorize_patient_access(patient_id: str, principal: dict, *, enforce: bool = False) -> None:
    """Authorize access to a patient-scoped resource.

    The demo profile intentionally keeps anonymous compatibility for the local
    presentation.  Production and ``REQUIRE_PATIENT_AUTH=1`` always use this
    policy, so a valid token alone is not enough to read another patient.
    """
    if not settings.require_patient_auth and not enforce:
        return
    role = principal.get("role")
    subject = str(principal.get("sub", ""))
    if role == "admin":
        return
    if role == "patient" and subject == patient_id:
        return
    if role == "device":
        bound_patient = principal.get("patient_id")
        if bound_patient == patient_id:
            return
    if role in ("doctor", "caregiver"):
        from app import users_store

        if role == "doctor" and users_store.is_assigned(patient_id, subject):
            return
        if role == "caregiver" and users_store.is_caregiver_linked(patient_id, subject):
            return
        # Persisted relationships are the authority. Profile metadata must not
        # bypass a revoked caregiver link or an unassigned doctor relationship.
    raise AuthError("Not authorized for this patient", code=status.HTTP_403_FORBIDDEN)


def require_patient_access(patient_id: str, principal: dict = Depends(get_current_principal)) -> dict:
    authorize_patient_access(patient_id, principal)
    return principal


# convenience dependencies
require_device = require_role("device", "admin")
require_clinician = require_role("doctor", "admin")
