"""SQLAlchemy database boundary for accounts and monitoring data.

Two backends are supported deliberately: SQLite for the local demo and the test
suite, and PostgreSQL (e.g. a hosted Supabase project) for real deployments.
`DATABASE_URL` selects PostgreSQL; without it the SQLite file path is used, so
existing local workflows and `SQLITE_DB_PATH` isolation keep working unchanged.
"""
from __future__ import annotations

import json
import os
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from threading import RLock
from typing import Iterator
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Column,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    String,
    Table,
    Text,
    create_engine,
    event,
    false,
    func,
    text,
)
from sqlalchemy.engine import Connection, Engine
from sqlalchemy.pool import NullPool
from sqlalchemy.sql.expression import Insert


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / "data" / "epilepsy.db"

metadata = MetaData()

users = Table(
    "users",
    metadata,
    Column("id", String(64), primary_key=True),
    # No column collation: `NOCASE` is SQLite-only. Case-insensitive usernames
    # are enforced portably by the unique index on `lower(username)` below, and
    # lookups must therefore compare on `lower(...)` as well.
    Column("username", String(128), nullable=False, unique=True),
    Column("email", String(255)),
    Column("name", String(256), nullable=False),
    Column("role", String(32), nullable=False),
    Column("password_hash", Text, nullable=False),
    Column("disabled", Boolean, nullable=False, default=False),
    Column("session_version", Integer, nullable=False, default=0),
    Column("primary_doctor_id", String(64)),
    Column("patient_id", String(64)),
    Column("created_by", String(64)),
    Column("created_at", String(64), nullable=False),
    Column("updated_at", String(64), nullable=False),
    Column("meta_json", Text, nullable=False, default="{}"),
    CheckConstraint(
        "role IN ('admin', 'doctor', 'patient', 'caregiver')",
        name="ck_users_role",
    ),
)

assignments = Table(
    "assignments",
    metadata,
    Column(
        "patient_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    ),
    Column(
        "doctor_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    ),
    Column("assigned_by", String(64)),
    Column("assigned_at", String(64), nullable=False),
)
# Portable case-insensitive uniqueness: works on both SQLite and PostgreSQL,
# unlike a NOCASE column collation.
Index("ux_users_username_lower", func.lower(users.c.username), unique=True)
Index(
    "uq_users_email_active",
    func.lower(users.c.email),
    unique=True,
    sqlite_where=text("email IS NOT NULL AND disabled = 0"),
    postgresql_where=text("email IS NOT NULL AND disabled = FALSE"),
)

doctor_profiles = Table(
    "doctor_profiles",
    metadata,
    Column("id", String(64), primary_key=True),
    Column(
        "user_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    ),
    Column("license_number", String(64), nullable=False, unique=True),
    Column("specialization", String(120), nullable=False),
    Column("hospital_affiliation", String(180), nullable=False),
    Column("national_id", String(32), nullable=False, unique=True),
    Column("phone", String(32), nullable=False),
    Column("moh_verified", Boolean, nullable=False, default=False, server_default=false()),
    Column("moh_status", String(32)),
    Column("moh_checked_at", String(64)),
    Column("moh_override_by", String(64)),
    Column("created_at", String(64), nullable=False),
    Column("updated_at", String(64), nullable=False),
)

moh_registry = Table(
    "moh_registry",
    metadata,
    Column("license_number", String(64), primary_key=True),
    Column("national_id", String(32), nullable=False),
    Column("full_name_ar", String(180), nullable=False),
    Column("full_name_en", String(180), nullable=False),
    Column("specialization", String(120), nullable=False),
    Column("hospital_affiliation", String(180)),
    Column("status", String(32), nullable=False),
    Column("expiration_date", String(32), nullable=False),
    CheckConstraint(
        "status IN ('active', 'suspended', 'expired')",
        name="ck_moh_registry_status",
    ),
)
Index("ix_moh_registry_national_id", moh_registry.c.national_id)

idempotency_keys = Table(
    "idempotency_keys",
    metadata,
    Column("key", String(128), primary_key=True),
    Column("actor_id", String(64), nullable=False),
    Column("endpoint", String(128), nullable=False),
    Column("response_status", Integer, nullable=False),
    Column("response_json", Text, nullable=False),
    Column("created_at", String(64), nullable=False),
)
Index("ix_idempotency_keys_created_at", idempotency_keys.c.created_at)

# Each human login is independently revocable. Tokens contain only the random
# session ID; the raw JWT is never persisted in this registry.
account_sessions = Table(
    "account_sessions", metadata,
    Column("id", String(64), primary_key=True),
    Column("user_id", String(64), ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("session_version", Integer, nullable=False),
    Column("device_name", String(120), nullable=False),
    Column("platform", String(32), nullable=False),
    Column("device_id", String(128)),
    Column("is_hardware_bound", Boolean, nullable=False, default=False, server_default=false()),
    Column("created_at", String(64), nullable=False),
    Column("last_seen_at", String(64), nullable=False),
    Column("expires_at", String(64), nullable=False),
    Column("revoked_at", String(64)),
)
Index("ix_account_sessions_user_id", account_sessions.c.user_id)
Index("ix_account_sessions_device_id", account_sessions.c.user_id, account_sessions.c.device_id)

Index("ix_assignments_doctor_id", assignments.c.doctor_id)

caregiver_links = Table(
    "caregiver_links",
    metadata,
    Column(
        "patient_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    ),
    Column(
        "caregiver_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    ),
    Column("linked_by", String(64)),
    Column("linked_at", String(64), nullable=False),
    Column("disabled", Boolean, nullable=False, default=False, server_default=false()),
)
Index("ix_caregiver_links_caregiver_id", caregiver_links.c.caregiver_id)

devices = Table(
    "devices",
    metadata,
    Column("device_id", String(128), primary_key=True),
    Column(
        "patient_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("name", String(256), nullable=False),
    Column("secret_hash", Text, nullable=False),
    Column("credential_version", Integer, nullable=False, default=0),
    Column("disabled", Boolean, nullable=False, default=False),
    Column("created_by", String(64)),
    Column("created_at", String(64), nullable=False),
    Column("updated_at", String(64), nullable=False),
    Column("last_enrolled_at", String(64)),
)
Index("ix_devices_patient_id", devices.c.patient_id)

audit_logs = Table(
    "audit_logs",
    metadata,
    Column("sequence", Integer, primary_key=True, autoincrement=True),
    Column("id", String(64), nullable=False, unique=True),
    Column("at", String(64), nullable=False),
    Column("actor", String(64)),
    Column("actor_role", String(32)),
    Column("action", String(128), nullable=False),
    Column("target", String(128)),
    Column("detail_json", Text, nullable=False, default="{}"),
)
Index("ix_audit_logs_at", audit_logs.c.at)
Index("ix_audit_logs_actor", audit_logs.c.actor)

patients = Table(
    "patients",
    metadata,
    Column("patient_id", String(64), primary_key=True),
    Column("current_status", String(64)),
    Column("last_updated", String(64)),
    Column("updated_at", String(64), nullable=False),
    Column("profile_json", Text, nullable=False, default="{}"),
)

care_records = Table(
    "care_records", metadata,
    Column("patient_id", String(64), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
    Column("kind", String(32), primary_key=True),
    Column("record_id", String(64), primary_key=True),
    Column("payload_json", Text, nullable=False),
    Column("actor_id", String(64), nullable=False),
    Column("updated_at", String(64), nullable=False),
    Column("deleted", Boolean, nullable=False),
)

readings = Table(
    "readings",
    metadata,
    Column("sequence", Integer, primary_key=True, autoincrement=True),
    Column("id", String(64), nullable=False, unique=True),
    Column(
        "patient_id",
        String(64),
        ForeignKey("patients.patient_id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("captured_at", String(64)),
    Column("payload_json", Text, nullable=False),
)
Index("ix_readings_patient_sequence", readings.c.patient_id, readings.c.sequence)
Index("ix_readings_patient_captured", readings.c.patient_id, readings.c.captured_at)

assessments = Table(
    "assessments",
    metadata,
    Column("sequence", Integer, primary_key=True, autoincrement=True),
    Column("id", String(64), nullable=False, unique=True),
    Column(
        "patient_id",
        String(64),
        ForeignKey("patients.patient_id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("captured_at", String(64)),
    Column("label", String(64)),
    Column("payload_json", Text, nullable=False),
)
Index("ix_assessments_patient_sequence", assessments.c.patient_id, assessments.c.sequence)
Index("ix_assessments_patient_captured", assessments.c.patient_id, assessments.c.captured_at)

alerts = Table(
    "alerts",
    metadata,
    Column("sequence", Integer, primary_key=True, autoincrement=True),
    Column("id", String(64), nullable=False, unique=True),
    Column(
        "patient_id",
        String(64),
        ForeignKey("patients.patient_id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("captured_at", String(64)),
    Column("severity", String(32)),
    Column("acknowledged", Boolean, nullable=False, default=False),
    Column("payload_json", Text, nullable=False),
)
Index("ix_alerts_patient_sequence", alerts.c.patient_id, alerts.c.sequence)
Index("ix_alerts_patient_ack", alerts.c.patient_id, alerts.c.acknowledged)

alert_acknowledgments = Table(
    "alert_acknowledgments",
    metadata,
    Column("id", String(64), primary_key=True),
    Column(
        "alert_id",
        String(64),
        ForeignKey("alerts.id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("patient_id", String(64), nullable=False),
    Column("actor_id", String(64), nullable=False),
    Column("actor_role", String(32)),
    Column("acknowledged_at", String(64), nullable=False),
    Column("note", Text),
)
Index("ix_alert_acknowledgments_alert", alert_acknowledgments.c.alert_id)
Index("ix_alert_acknowledgments_patient", alert_acknowledgments.c.patient_id)
Index(
    "ux_alert_acknowledgments_actor",
    alert_acknowledgments.c.alert_id,
    alert_acknowledgments.c.actor_id,
    unique=True,
)

outcomes = Table(
    "outcomes",
    metadata,
    Column("sequence", Integer, primary_key=True, autoincrement=True),
    Column("id", String(64), nullable=False, unique=True),
    Column(
        "patient_id",
        String(64),
        ForeignKey("patients.patient_id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("assessment_id", String(64), ForeignKey("assessments.id", ondelete="SET NULL")),
    Column("alert_id", String(64), ForeignKey("alerts.id", ondelete="SET NULL")),
    Column("outcome", String(32), nullable=False),
    Column("occurred_at", String(64), nullable=False),
    Column("recorded_by", String(64), nullable=False),
    Column("recorded_at", String(64), nullable=False),
    Column("notes", Text),
    Column("payload_json", Text, nullable=False, default="{}"),
    Column("version", Integer, nullable=False, default=1, server_default="1"),
    CheckConstraint(
        "outcome IN ('seizure', 'no_seizure', 'false_alarm', 'unknown')",
        name="ck_outcomes_outcome",
    ),
)
Index("ix_outcomes_patient_sequence", outcomes.c.patient_id, outcomes.c.sequence)
Index("ix_outcomes_assessment_id", outcomes.c.assessment_id)
Index(
    "uq_outcomes_patient_alert",
    outcomes.c.patient_id,
    outcomes.c.alert_id,
    unique=True,
    sqlite_where=text("alert_id IS NOT NULL"),
    postgresql_where=text("alert_id IS NOT NULL"),
)

# Transactional outbox: a notification intent is written in the SAME
# transaction as its alert, so an alert can never exist without a delivery
# record. A background worker drains it with exponential backoff.
alert_outbox = Table(
    "alert_outbox",
    metadata,
    Column("id", String(64), primary_key=True),
    Column("alert_id", String(64), nullable=False, unique=True),
    Column("patient_id", String(64), nullable=False),
    Column("payload_json", Text, nullable=False),
    Column("status", String(16), nullable=False, default="pending"),
    Column("attempts", Integer, nullable=False, default=0),
    Column("next_attempt_at", String(64), nullable=False),
    Column("last_error", Text),
    Column("created_at", String(64), nullable=False),
    Column("updated_at", String(64), nullable=False),
    CheckConstraint(
        "status IN ('pending', 'sent', 'failed', 'dead')",
        name="ck_alert_outbox_status",
    ),
)
Index("ix_alert_outbox_due", alert_outbox.c.status, alert_outbox.c.next_attempt_at)

# Leases prevent healthy concurrent workers from delivering the same pending row.
alert_outbox.append_column(Column("lease_token", String(64)))
alert_outbox.append_column(Column("lease_expires_at", String(64)))

prescriptions = Table(
    "prescriptions", metadata,
    Column("id", String(64), primary_key=True),
    Column("patient_id", String(64), ForeignKey("patients.patient_id", ondelete="CASCADE"), nullable=False),
    Column("doctor_id", String(64)),
    Column("name", String(200), nullable=False),
    Column("dose", String(100), nullable=False),
    Column("schedule", String(200), nullable=False),
    Column("notes", Text),
    Column("active", Boolean, nullable=False, default=True),
    Column("period_context", String(32)),
    Column("meal_context", String(32)),
    Column("meal_type", String(32)),
    Column("times_json", Text),
    Column("created_at", String(64), nullable=False),
    Column("updated_at", String(64), nullable=False),
)
Index("ix_prescriptions_patient", prescriptions.c.patient_id)

medication_logs = Table(
    "medication_logs",
    metadata,
    Column("id", String(64), primary_key=True),
    Column(
        "prescription_id",
        String(64),
        ForeignKey("prescriptions.id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column(
        "patient_id",
        String(64),
        ForeignKey("patients.patient_id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("scheduled_time", String(64), nullable=False),
    Column("taken_at", String(64)),
    Column("status", String(16), nullable=False),
    Column("recorded_by", String(64), nullable=False),
    Column("created_at", String(64), nullable=False),
    CheckConstraint(
        "status IN ('taken', 'missed', 'skipped')",
        name="ck_medication_logs_status",
    ),
)
Index(
    "ux_medication_logs_rx_slot",
    medication_logs.c.prescription_id,
    medication_logs.c.scheduled_time,
    unique=True,
)
Index(
    "ix_medication_logs_patient",
    medication_logs.c.patient_id,
    medication_logs.c.scheduled_time,
)

# Persist bounded signal buffers and replay protection with the derived events.
# PostgreSQL locks one stream row; SQLite serializes writes in the local profile.
device_streams = Table(
    "device_streams", metadata,
    Column("patient_id", String(64), ForeignKey("patients.patient_id", ondelete="CASCADE"), primary_key=True),
    Column("device_id", String(128), primary_key=True),
    Column("state_json", Text, nullable=False),
    Column("updated_at", String(64), nullable=False),
)

sso_codes = Table(
    "sso_codes", metadata,
    Column("code_hash", String(64), primary_key=True),
    Column("user_id", String(64), ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    Column("session_version", Integer, nullable=False),
    Column("expires_at", String(64), nullable=False),
)

# FCM registration tokens are credentials-like routing data. Keep them outside
# users.meta_json so /auth/me and admin profile responses can never expose them.
push_tokens = Table(
    "push_tokens",
    metadata,
    Column("id", String(64), primary_key=True),
    Column(
        "user_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("token", Text, nullable=False, unique=True),
    Column("platform", String(32), nullable=False, default="unknown"),
    Column("session_id", String(64), ForeignKey("account_sessions.id", ondelete="CASCADE")),
    Column("created_at", String(64), nullable=False),
    Column("updated_at", String(64), nullable=False),
)
Index("ix_push_tokens_user_id", push_tokens.c.user_id)
Index("ix_push_tokens_session_id", push_tokens.c.session_id)

store_imports = Table(
    "store_imports",
    metadata,
    Column("source_path", Text, primary_key=True),
    Column("checksum", String(64), nullable=False),
    Column("imported_at", String(64), nullable=False),
    Column("backup_path", Text, nullable=False),
)

messages = Table(
    "messages",
    metadata,
    Column("id", String(64), primary_key=True),
    Column(
        "patient_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column(
        "sender_id",
        String(64),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    ),
    Column("sender_name", String(256), nullable=False),
    Column("sender_role", String(32), nullable=False),
    Column("channel_type", String(32), nullable=False),
    Column("peer_user_id", String(64), ForeignKey("users.id", ondelete="SET NULL")),
    Column("content", Text, nullable=False),
    Column("created_at", String(64), nullable=False),
    Column("delivered_at", String(64)),
    Column("read_at", String(64)),
    CheckConstraint(
        "channel_type IN ('doctor_patient', 'family_patient', 'patient_caregiver', 'doctor_caregiver', 'care_team_triage')",
        name="ck_messages_channel_type",
    ),
)
Index("ix_messages_patient_channel", messages.c.patient_id, messages.c.channel_type)
Index("ix_messages_created_at", messages.c.created_at)
Index(
    "ix_messages_peer_user_id",
    messages.c.patient_id,
    messages.c.channel_type,
    messages.c.peer_user_id,
)


_engines: dict[str, Engine] = {}
_engine_lock = RLock()
_initialized: set[str] = set()
_active_transaction: ContextVar[Connection | None] = ContextVar("db_transaction", default=None)


def database_path() -> Path:
    """Resolve at call time so pytest and deployments can isolate databases."""
    configured = os.getenv("SQLITE_DB_PATH")
    if configured:
        return Path(configured).expanduser().resolve()
    legacy_test_path = os.getenv("USERS_STORE_PATH")
    if legacy_test_path:
        return (Path(legacy_test_path).expanduser().resolve().parent / "epilepsy.db")
    return DEFAULT_DB


def configured_database_url() -> str | None:
    """Return an explicit `DATABASE_URL` (PostgreSQL/Supabase) if configured."""
    value = (os.getenv("DATABASE_URL") or "").strip()
    return value or None


def normalize_database_url(url: str) -> str:
    """Accept the connection strings hosting panels hand out verbatim.

    Supabase and similar dashboards show `postgres://` / `postgresql://`, which
    SQLAlchemy maps to the psycopg2 driver. This project installs psycopg 3, so
    the driver is pinned explicitly instead of failing at connect time. For
    Supabase hosts, `sslmode=require` is added automatically when omitted.
    """
    normalized = url
    if normalized.startswith("postgres://"):
        normalized = "postgresql+psycopg://" + normalized[len("postgres://"):]
    elif normalized.startswith("postgresql://"):
        normalized = "postgresql+psycopg://" + normalized[len("postgresql://"):]

    parsed = urlsplit(normalized)
    host = (parsed.hostname or "").lower()
    if host.endswith(".supabase.com") or host.endswith(".supabase.co"):
        query = dict(parse_qsl(parsed.query, keep_blank_values=True))
        if "sslmode" not in query:
            pairs = parse_qsl(parsed.query, keep_blank_values=True)
            pairs.append(("sslmode", "require"))
            normalized = urlunsplit(
                (parsed.scheme, parsed.netloc, parsed.path, urlencode(pairs), parsed.fragment)
            )
    return normalized


def is_supabase_transaction_pooler_url(url: str) -> bool:
    """Detect Supabase Transaction Pooler (Supavisor/PgBouncer port 6543)."""
    if is_sqlite_url(url):
        return False
    override = (os.getenv("DB_USE_NULL_POOL") or "").strip().lower()
    if override in {"1", "true", "yes"}:
        return True
    if override in {"0", "false", "no"}:
        return False
    parsed = urlsplit(url)
    host = (parsed.hostname or "").lower()
    if parsed.port == 6543:
        return True
    return host.endswith(".pooler.supabase.com") and parsed.port != 5432


def database_url(path: Path | None = None) -> str:
    configured = configured_database_url()
    if configured:
        return normalize_database_url(configured)
    return f"sqlite:///{(path or database_path()).as_posix()}"


def is_sqlite_url(url: str) -> bool:
    return url.startswith("sqlite")


def _engine_key() -> str:
    url = database_url()
    return url if not is_sqlite_url(url) else str(database_path())


def _configure_sqlite(dbapi_connection, _connection_record) -> None:
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA synchronous=NORMAL")
    cursor.execute("PRAGMA busy_timeout=5000")
    cursor.close()


def _create_engine() -> Engine:
    url = database_url()
    if is_sqlite_url(url):
        # Only SQLite needs a writable parent directory, thread-check opt-out,
        # and the PRAGMA tuning applied on every new file handle.
        database_path().parent.mkdir(parents=True, exist_ok=True)
        engine = create_engine(
            url,
            future=True,
            connect_args={"check_same_thread": False, "timeout": 5},
            pool_pre_ping=True,
        )
        event.listen(engine, "connect", _configure_sqlite)
        return engine
    # Supavisor Transaction Mode (port 6543) handles pooling externally and
    # disallows server-side prepared statements across pooled transactions.
    if is_supabase_transaction_pooler_url(url):
        return create_engine(
            url,
            future=True,
            poolclass=NullPool,
            connect_args={"prepare_threshold": None},
        )
    # Direct PostgreSQL / Session mode: keep a bounded SQLAlchemy pool.
    return create_engine(
        url,
        future=True,
        pool_pre_ping=True,
        pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
        max_overflow=int(os.getenv("DB_MAX_OVERFLOW", "5")),
        pool_recycle=int(os.getenv("DB_POOL_RECYCLE_SECONDS", "300")),
    )


def get_engine() -> Engine:
    key = _engine_key()
    with _engine_lock:
        engine = _engines.get(key)
        if engine is None:
            engine = _create_engine()
            _engines[key] = engine
        return engine


def dialect_name() -> str:
    return get_engine().dialect.name


def upsert(table: Table, values: dict[str, object]) -> Insert:
    """Dialect-aware INSERT that supports `on_conflict_*` clauses.

    A SELECT-then-INSERT alternative would race whenever two devices report for
    the same patient, so the conflict handling stays in the database.
    """
    if dialect_name() == "postgresql":
        from sqlalchemy.dialects.postgresql import insert as postgresql_insert

        return postgresql_insert(table).values(**values)
    from sqlalchemy.dialects.sqlite import insert as sqlite_insert

    return sqlite_insert(table).values(**values)


def initialize_database() -> None:
    """Upgrade the selected database to the current Alembic revision once."""
    if os.getenv("RUN_MIGRATIONS_ON_STARTUP", "1") != "1":
        # Production deployments run `alembic upgrade head` as a separate step so
        # concurrent processes never race on schema changes.
        return
    key = _engine_key()
    with _engine_lock:
        if key in _initialized:
            return
        from alembic import command
        from alembic.config import Config

        config = Config(str(ROOT / "alembic.ini"))
        config.set_main_option("sqlalchemy.url", database_url())
        # The URL above is already the resolved one; tell env.py not to re-derive
        # it, so its DATABASE_URL fallback stays reserved for the Alembic CLI.
        config.attributes["explicit_url"] = True
        command.upgrade(config, "head")

        _initialized.add(key)


@contextmanager
def transaction() -> Iterator[Connection]:
    """A unit of work; nested store calls join the caller's transaction.

    Context-local rather than global/thread-local so unrelated requests cannot
    share a connection. Exceptions must propagate to the outermost scope, which
    commits or rolls back the complete business operation.
    """
    active = _active_transaction.get()
    if active is not None:
        yield active
        return
    initialize_database()
    with get_engine().begin() as db_connection:
        token = _active_transaction.set(db_connection)
        try:
            yield db_connection
        finally:
            _active_transaction.reset(token)


@contextmanager
def connection() -> Iterator[Connection]:
    active = _active_transaction.get()
    if active is not None:
        yield active
        return
    initialize_database()
    with get_engine().connect() as db_connection:
        yield db_connection


def dump_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def load_json(value: str | None, default):
    if not value:
        return default
    try:
        return json.loads(value)
    except (TypeError, json.JSONDecodeError):
        return default


def reset_engine_cache() -> None:
    """Dispose cached engines; intended for tests and maintenance commands."""
    with _engine_lock:
        for engine in _engines.values():
            engine.dispose()
        _engines.clear()
        _initialized.clear()
