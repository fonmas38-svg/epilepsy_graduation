"""Environment-aware settings used by security and integration boundaries.

The project keeps a deliberately permissive ``demo`` profile for the local
graduation presentation.  Production must opt into the strict profile and
cannot silently inherit demo authentication or wildcard CORS.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


def _csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


@dataclass(frozen=True)
class Settings:
    environment: str
    jwt_secret: str
    jwt_expire_minutes: int
    allow_legacy_token: bool
    cors_origins: tuple[str, ...]
    require_patient_auth: bool
    max_request_body_bytes: int
    rate_limit_requests: int
    rate_limit_window_seconds: int
    timestamp_max_future_seconds: int
    timestamp_max_age_seconds: int
    session_lifetime_seconds: int = 30 * 86400

    @property
    def is_production(self) -> bool:
        return self.environment in {"production", "prod"}


def load_settings() -> Settings:
    environment = os.getenv("APP_ENV", "demo").strip().lower()
    is_production = environment in {"production", "prod"}
    secret = os.getenv("JWT_SECRET", "dev-only-change-me-in-production")
    origins = tuple(_csv(os.getenv("CORS_ORIGINS", "")))
    if not origins and not is_production:
        origins = ("*",)

    def positive_int(name: str, default: int, minimum: int = 1) -> int:
        try:
            return max(minimum, int(os.getenv(name, str(default))))
        except (TypeError, ValueError):
            return default

    # A zero rate limit explicitly disables the guard. It is useful for the
    # local demo, while production gets a conservative default.
    configured_rate_limit = os.getenv("RATE_LIMIT_REQUESTS")
    if configured_rate_limit is None:
        rate_limit_requests = 120 if is_production else 0
    else:
        try:
            rate_limit_requests = max(0, int(configured_rate_limit))
        except ValueError:
            rate_limit_requests = 120 if is_production else 0

    return Settings(
        environment=environment,
        jwt_secret=secret,
        jwt_expire_minutes=max(1, int(os.getenv("JWT_EXPIRE_MINUTES", "60"))),
        # Legacy auth is a demo-only compatibility bridge, never a production
        # default even when the variable is absent.
        allow_legacy_token=(
            os.getenv("AUTH_ALLOW_LEGACY_TOKEN", "0" if is_production else "1") == "1"
        ),
        cors_origins=origins,
        require_patient_auth=(
            is_production or os.getenv("REQUIRE_PATIENT_AUTH", "0") == "1"
        ),
        max_request_body_bytes=positive_int(
            "MAX_REQUEST_BODY_BYTES", 8 * 1024 * 1024
        ),
        rate_limit_requests=rate_limit_requests,
        rate_limit_window_seconds=positive_int("RATE_LIMIT_WINDOW_SECONDS", 60),
        timestamp_max_future_seconds=positive_int(
            "TIMESTAMP_MAX_FUTURE_SECONDS", 300
        ),
        timestamp_max_age_seconds=positive_int(
            "TIMESTAMP_MAX_AGE_SECONDS", 7 * 24 * 60 * 60
        ),
        session_lifetime_seconds=positive_int(
            "SESSION_LIFETIME_SECONDS", 30 * 86400, minimum=300
        ),
    )


settings = load_settings()


def validate_production_settings() -> None:
    """Fail fast when a production process is configured with demo secrets."""
    if not settings.is_production:
        return
    from app.database import database_url, is_sqlite_url

    errors: list[str] = []
    if is_sqlite_url(database_url()):
        errors.append(
            "DATABASE_URL must point to persistent PostgreSQL (e.g. Supabase) in production; ephemeral SQLite is forbidden when APP_ENV=production"
        )
    if len(settings.jwt_secret) < 32 or settings.jwt_secret == "dev-only-change-me-in-production":
        errors.append("JWT_SECRET must be a random value of at least 32 characters")
    if settings.allow_legacy_token:
        errors.append("AUTH_ALLOW_LEGACY_TOKEN must be 0 in production")
    if not settings.cors_origins or "*" in settings.cors_origins:
        errors.append("CORS_ORIGINS must contain explicit origins in production")
    if not os.getenv("ADMIN_PASSWORD"):
        errors.append("ADMIN_PASSWORD is required in production")
    if os.getenv("SEED_DEMO_ACCOUNTS", "0") == "1":
        errors.append("SEED_DEMO_ACCOUNTS must be 0 in production")
    notification_channel = os.getenv("NOTIFICATION_CHANNEL", "stub").strip().lower()
    if notification_channel != "fcm":
        errors.append("NOTIFICATION_CHANNEL must be fcm in production")
    if errors:
        raise RuntimeError("Invalid production settings: " + "; ".join(errors))
