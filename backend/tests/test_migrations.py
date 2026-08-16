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
}


def _config(db_path) -> Config:
    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "alembic"))
    cfg.set_main_option("sqlalchemy.url", f"sqlite:///{db_path.as_posix()}")
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
