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

import os
import time
from typing import Literal

from fastapi import Depends, Header, HTTPException, status

try:
    import jwt  # PyJWT
except ImportError:  # pragma: no cover
    jwt = None

Role = Literal["device", "patient", "caregiver", "doctor", "admin"]

JWT_SECRET = os.getenv("JWT_SECRET", "dev-only-change-me-in-production")
JWT_ALG = "HS256"
JWT_EXPIRE_MINUTES = int(os.getenv("JWT_EXPIRE_MINUTES", "60"))
LEGACY_TOKEN = "headband-demo-token"
# Defaults ON so the demo gateway + existing tests keep working out of the box.
# !!! SECURITY: set AUTH_ALLOW_LEGACY_TOKEN=0 in any real deployment. A static
#     shared token is not real authentication.
ALLOW_LEGACY = os.getenv("AUTH_ALLOW_LEGACY_TOKEN", "1") == "1"


class AuthError(HTTPException):
    def __init__(self, detail: str, code: int = status.HTTP_401_UNAUTHORIZED):
        super().__init__(status_code=code, detail=detail)


def create_token(subject: str, role: Role, extra: dict | None = None) -> str:
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
        payload.update(extra)
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
        return {"sub": "legacy-device", "role": "device", "legacy": True}
    return decode_token(token)


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


# convenience dependencies
require_device = require_role("device", "admin")
require_clinician = require_role("doctor", "admin")
