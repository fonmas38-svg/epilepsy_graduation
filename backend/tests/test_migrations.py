"""Verify the Alembic revision itself can upgrade, downgrade, and re-upgrade.

The app-level tests always start from `head`; this module protects the other
direction, so a broken `downgrade()` is caught before someone needs it.
"""
from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect

ROOT = Path(__file__).resolve().parents[1]
EXPECTED_TABLES = {
    "users", "assignments", "audit_logs", "patients",
    "readings", "assessments", "alerts", "store_imports",
    "alert_outbox", "caregiver_links", "devices",
    "alert_acknowledgments", "outcomes",
    "push_tokens",
    "care_records",
    "account_sessions",
    "prescriptions", "device_streams", "sso_codes",
    "doctor_profiles", "moh_registry", "idempotency_keys",
    "medication_logs",
}


def _config(db_path) -> Config:
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "alembic"))
    cfg.set_main_option("sqlalchemy.url", f"sqlite:///{db_path.as_posix()}")
    # These tests downgrade to `base`, i.e. drop every table. `explicit_url`
    # stops env.py from redirecting them to DATABASE_URL when the suite is run
    # against PostgreSQL (TEST_DATABASE_URL), which would wipe that database.
    cfg.attributes["explicit_url"] = True
    return cfg



@pytest.fixture
def db_path(tmp_path):
    return tmp_path / "migration_check.db"


def test_upgrade_creates_expected_schema(db_path):
    command.upgrade(_config(db_path), "head")

    tables = set(inspect(create_engine(f"sqlite:///{db_path.as_posix()}")).get_table_names())
    assert EXPECTED_TABLES <= tables
    assert "alembic_version" in tables


def test_downgrade_then_upgrade_round_trip(db_path):
    cfg = _config(db_path)

    command.upgrade(cfg, "head")
    command.downgrade(cfg, "base")
    remaining = set(inspect(create_engine(f"sqlite:///{db_path.as_posix()}")).get_table_names())
    assert not (EXPECTED_TABLES & remaining)

    command.upgrade(cfg, "head")
    tables = set(inspect(create_engine(f"sqlite:///{db_path.as_posix()}")).get_table_names())
    assert EXPECTED_TABLES <= tables


def test_upgrade_is_idempotent_when_already_at_head(db_path):
    cfg = _config(db_path)
    command.upgrade(cfg, "head")

    command.upgrade(cfg, "head")  # must be a no-op rather than an error

    with sqlite3.connect(db_path) as conn:
        revisions = conn.execute("SELECT version_num FROM alembic_version").fetchall()
    assert len(revisions) == 1


def test_schema_enforces_unique_username(db_path):
    command.upgrade(_config(db_path), "head")

    with sqlite3.connect(db_path) as conn:
        insert = (
            "INSERT INTO users (id, username, name, role, password_hash, disabled,"
            " session_version, created_at, updated_at, meta_json)"
            " VALUES (?, ?, 'N', 'doctor', 'h', 0, 0, 't', 't', '{}')"
        )
        conn.execute(insert, ("u1", "same_name"))
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(insert, ("u2", "same_name"))


def test_session_upgrade_preserves_legacy_push_rows_without_authorizing_them(db_path):
    cfg = _config(db_path)
    command.upgrade(cfg, "20261113_08")
    with sqlite3.connect(db_path) as conn:
        conn.execute("INSERT INTO users (id, username, name, role, password_hash, disabled, session_version, created_at, updated_at, meta_json) VALUES ('legacy-user', 'legacy-user', 'N', 'patient', 'h', 0, 0, 't', 't', '{}')")
        conn.execute("INSERT INTO push_tokens (id, user_id, token, platform, created_at, updated_at) VALUES ('legacy-push', 'legacy-user', 'old-registration-token', 'android', 't', 't')")
    command.upgrade(cfg, "head")
    with sqlite3.connect(db_path) as conn:
        assert conn.execute("SELECT token, session_id FROM push_tokens").fetchall() == [("old-registration-token", None)]
        assert conn.execute("SELECT COUNT(*) FROM account_sessions").fetchone()[0] == 0
        # SQLite batch reflection must not lose the unrelated username index.
        indexes = {row[1] for row in conn.execute("PRAGMA index_list(users)")}
        assert "ux_users_username_lower" in indexes
    command.downgrade(cfg, "20261113_08")
    with sqlite3.connect(db_path) as conn:
        assert conn.execute("SELECT token FROM push_tokens").fetchall() == [("old-registration-token",)]


def test_schema_enforces_partial_unique_email_and_preserves_username_index(db_path):
    command.upgrade(_config(db_path), "head")

    with sqlite3.connect(db_path) as conn:
        insert = (
            "INSERT INTO users (id, username, email, name, role, password_hash, disabled,"
            " session_version, created_at, updated_at, meta_json)"
            " VALUES (?, ?, ?, 'N', 'doctor', 'h', ?, 0, 't', 't', '{}')"
        )
        # Multiple NULL emails are allowed.
        conn.execute(insert, ("u1", "doc1", None, 0))
        conn.execute(insert, ("u2", "doc2", None, 0))
        # Active user email must be unique case-insensitively.
        conn.execute(insert, ("u3", "doc3", "Doctor@Clinic.org", 0))
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(insert, ("u4", "doc4", "doctor@clinic.org", 0))
        # Disabled accounts do not block re-using an email address.
        conn.execute(insert, ("u5", "doc5", "retired@clinic.org", 1))
        conn.execute(insert, ("u6", "doc6", "retired@clinic.org", 0))
        indexes = {row[1] for row in conn.execute("PRAGMA index_list(users)")}
        assert "ux_users_username_lower" in indexes
        assert "uq_users_email_active" in indexes


def test_messages_accepts_expanded_channels_and_rejects_invalid(db_path):
    command.upgrade(_config(db_path), "head")

    with sqlite3.connect(db_path) as conn:
        conn.execute("PRAGMA foreign_keys=ON")
        user_sql = (
            "INSERT INTO users (id, username, name, role, password_hash, disabled,"
            " session_version, created_at, updated_at, meta_json)"
            " VALUES (?, ?, 'N', ?, 'h', 0, 0, 't', 't', '{}')"
        )
        conn.execute(user_sql, ("p1", "p1", "patient"))
        conn.execute(user_sql, ("d1", "d1", "doctor"))
        conn.execute(user_sql, ("c1", "c1", "caregiver"))

        msg_sql = (
            "INSERT INTO messages (id, patient_id, sender_id, sender_name, sender_role,"
            " channel_type, peer_user_id, content, created_at)"
            " VALUES (?, 'p1', 'd1', 'Dr', 'doctor', ?, ?, 'hello', '2026-11-21T10:00:00Z')"
        )
        for idx, ch in enumerate(
            ["doctor_patient", "family_patient", "patient_caregiver", "doctor_caregiver", "care_team_triage"]
        ):
            peer = "c1" if ch in ("patient_caregiver", "doctor_caregiver") else None
            conn.execute(msg_sql, (f"m-{idx}", ch, peer))

        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(msg_sql, ("m-bad", "unknown_channel", None))


def test_outcomes_allows_multiple_null_alerts_but_blocks_duplicate_alert_adjudication(db_path):
    command.upgrade(_config(db_path), "head")

    with sqlite3.connect(db_path) as conn:
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute(
            "INSERT INTO patients (patient_id, current_status, updated_at, profile_json)"
            " VALUES ('p1', 'stable', 't', '{}')"
        )
        conn.execute(
            "INSERT INTO alerts (id, patient_id, captured_at, severity, acknowledged, payload_json)"
            " VALUES ('a1', 'p1', 't', 'critical', 0, '{}')"
        )
        out_sql = (
            "INSERT INTO outcomes (id, patient_id, alert_id, outcome, occurred_at, recorded_by, recorded_at, payload_json)"
            " VALUES (?, 'p1', ?, 'seizure', 't', 'd1', 't', '{}')"
        )
        # Multiple manual outcomes without an alert_id are allowed.
        conn.execute(out_sql, ("o1", None))
        conn.execute(out_sql, ("o2", None))
        # Only one adjudication outcome per (patient_id, alert_id).
        conn.execute(out_sql, ("o3", "a1"))
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute(out_sql, ("o4", "a1"))
