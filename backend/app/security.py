"""Password hashing for the account system (admin/doctor/patient logins).

Deliberately uses only the Python standard library (`hashlib.pbkdf2_hmac`,
`secrets`, `hmac`) so it adds NO new dependency to requirements.txt and cannot
break the existing import graph. The stored format is a single self-describing
string, the same shape passlib/Django use::

    pbkdf2_sha256$<iterations>$<salt_b64>$<hash_b64>

`verify_password` is constant-time (`hmac.compare_digest`) and tolerant: any
malformed/legacy value simply fails to verify instead of raising, so a corrupt
users store can never 500 the login endpoint.

Security notes for deployment:
  * Never commit real passwords. The seeded admin password comes from the
    ADMIN_PASSWORD env var; the built-in default is a throwaway for local demo
    only and the app logs a loud warning when it is used.
  * PBKDF2 iteration count is deliberately high; tune via PBKDF2_ITERATIONS if
    the host is slow, but never lower it in production.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets

ALGORITHM = "pbkdf2_sha256"
# OWASP-order magnitude for PBKDF2-HMAC-SHA256; overridable for slow hosts/tests.
_DEFAULT_ITERATIONS = 200000
_SALT_BYTES = 16


def _default_iterations() -> int:
    """Read PBKDF2_ITERATIONS at call time so tests/hosts can tune it via env."""
    try:
        return int(os.getenv("PBKDF2_ITERATIONS", str(_DEFAULT_ITERATIONS)))
    except (TypeError, ValueError):
        return _DEFAULT_ITERATIONS


def _b64e(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _b64d(text: str) -> bytes:
    return base64.b64decode(text.encode("ascii"))


def hash_password(password: str, *, iterations: int | None = None) -> str:
    """Return a self-describing PBKDF2 hash string for `password`."""
    if not isinstance(password, str) or password == "":
        raise ValueError("password must be a non-empty string")
    iters = iterations or _default_iterations()
    salt = secrets.token_bytes(_SALT_BYTES)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iters)
    return f"{ALGORITHM}${iters}${_b64e(salt)}${_b64e(digest)}"


def verify_password(password: str, stored: str) -> bool:
    """Constant-time verify. Returns False (never raises) on any bad input."""
    if not isinstance(password, str) or not isinstance(stored, str) or not password or not stored:
        return False
    try:
        algorithm, iters_s, salt_b64, hash_b64 = stored.split("$")
        if algorithm != ALGORITHM:
            return False
        iters = int(iters_s)
        if not 1 <= iters <= 10_000_000:
            return False
        salt = _b64d(salt_b64)
        expected = _b64d(hash_b64)
        candidate = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iters)
    except (ValueError, TypeError, OverflowError):
        return False
    return hmac.compare_digest(candidate, expected)


def needs_rehash(stored: str, *, iterations: int | None = None) -> bool:
    """True if `stored` was produced with a weaker/old iteration count."""
    try:
        algorithm, iters_s, _, _ = stored.split("$")
        return algorithm != ALGORITHM or int(iters_s) < (iterations or _default_iterations())
    except (ValueError, TypeError, AttributeError):
        return True


def generate_password(length: int = 12) -> str:
    """A readable one-time password for admin-created accounts.

    URL-safe, ambiguity-trimmed (no O/0/I/l), long enough to be safe as a
    first-login credential the admin/doctor hands to the account owner.
    """
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    return "".join(secrets.choice(alphabet) for _ in range(max(8, length)))
