"""SQLAlchemy database boundary for accounts and monitoring data."""
from __future__ import annotations

import json
import os
from contextlib import contextmanager
from pathlib import Path
from threading import RLock
from typing import Iterator

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
)
from sqlalchemy.engine import Connection, Engine

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = ROOT / "data" / "epilepsy.db"

metadata = MetaData()

users = Table(
    "users",
    metadata,
    Column("id", String(64), primary_key=True),
    Column("username", String(128, collation="NOCASE"), nullable=False, unique=True),
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
    CheckConstraint(
        "outcome IN ('seizure', 'no_seizure', 'false_alarm', 'unknown')",
        name="ck_outcomes_outcome",
    ),
)
Index("ix_outcomes_patient_sequence", outcomes.c.patient_id, outcomes.c.sequence)
Index("ix_outcomes_assessment_id", outcomes.c.assessment_id)

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

store_imports = Table(
    "store_imports",
    metadata,
    Column("source_path", Text, primary_key=True),
    Column("checksum", String(64), nullable=False),
    Column("imported_at", String(64), nullable=False),
    Column("backup_path", Text, nullable=False),
)

_engines: dict[str, Engine] = {}
_engine_lock = RLock()
_initialized: set[str] = set()


def database_path() -> Path:
    """Resolve at call time so pytest and deployments can isolate databases."""
    configured = os.getenv("SQLITE_DB_PATH")
    if configured:
        return Path(configured).expanduser().resolve()
    legacy_test_path = os.getenv("USERS_STORE_PATH")
    if legacy_test_path:
        return (Path(legacy_test_path).expanduser().resolve().parent / "epilepsy.db")
    return DEFAULT_DB


def database_url(path: Path | None = None) -> str:
    return f"sqlite:///{(path or database_path()).as_posix()}"


def _configure_sqlite(dbapi_connection, _connection_record) -> None:
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA synchronous=NORMAL")
    cursor.execute("PRAGMA busy_timeout=5000")
    cursor.close()


def get_engine() -> Engine:
    path = database_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    key = str(path)
    with _engine_lock:
        engine = _engines.get(key)
        if engine is None:
            engine = create_engine(
                database_url(path),
                future=True,
                connect_args={"check_same_thread": False, "timeout": 5},
                pool_pre_ping=True,
            )
            event.listen(engine, "connect", _configure_sqlite)
            _engines[key] = engine
        return engine


def initialize_database() -> None:
    """Upgrade the selected database to the current Alembic revision once."""
    key = str(database_path())
    with _engine_lock:
        if key in _initialized:
            return
        from alembic import command
        from alembic.config import Config

        config = Config(str(ROOT / "alembic.ini"))
        config.set_main_option("sqlalchemy.url", database_url())
        command.upgrade(config, "head")
        _initialized.add(key)


@contextmanager
def transaction() -> Iterator[Connection]:
    initialize_database()
    with get_engine().begin() as connection:
        yield connection


@contextmanager
def connection() -> Iterator[Connection]:
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