"""Phase 1 tests: Supabase pooling, Render persistence guard, and schema parity."""
from __future__ import annotations

from dataclasses import replace
import importlib
from pathlib import Path
import re

import pytest
from sqlalchemy.pool import NullPool

from app import database


ROOT = Path(__file__).resolve().parents[1]


def test_is_supabase_transaction_pooler_url_detection(monkeypatch):
    monkeypatch.delenv("DB_USE_NULL_POOL", raising=False)
    assert database.is_supabase_transaction_pooler_url(
        "postgresql+psycopg://postgres.proj:pw@aws-0-eu-central-1.pooler.supabase.com:6543/postgres"
    ) is True
    assert database.is_supabase_transaction_pooler_url(
        "postgresql+psycopg://postgres.proj:pw@aws-0-eu-central-1.pooler.supabase.com/postgres"
    ) is True
    assert database.is_supabase_transaction_pooler_url(
        "postgresql+psycopg://postgres:pw@db.proj.supabase.co:5432/postgres"
    ) is False
    assert database.is_supabase_transaction_pooler_url("sqlite:///data/epilepsy.db") is False

    monkeypatch.setenv("DB_USE_NULL_POOL", "1")
    assert database.is_supabase_transaction_pooler_url(
        "postgresql+psycopg://postgres:pw@db.example.com:5432/postgres"
    ) is True
    monkeypatch.setenv("DB_USE_NULL_POOL", "0")
    assert database.is_supabase_transaction_pooler_url(
        "postgresql+psycopg://postgres.proj:pw@aws-0-eu-central-1.pooler.supabase.com:6543/postgres"
    ) is False


def test_normalize_database_url_adds_sslmode_for_supabase_only():
    pooler = "postgresql://u:p@aws-0-eu-central-1.pooler.supabase.com:6543/postgres"
    assert database.normalize_database_url(pooler) == (
        "postgresql+psycopg://u:p@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require"
    )
    direct = "postgres://u:p@db.abcd.supabase.co:5432/postgres?sslmode=verify-full"
    assert database.normalize_database_url(direct) == (
        "postgresql+psycopg://u:p@db.abcd.supabase.co:5432/postgres?sslmode=verify-full"
    )
    generic = "postgres://u:p@db.example.net:5432/postgres"
    assert database.normalize_database_url(generic) == (
        "postgresql+psycopg://u:p@db.example.net:5432/postgres"
    )


def test_create_engine_uses_null_pool_for_supabase_transaction_pooler(monkeypatch):
    captured: dict[str, object] = {}

    class DummyEngine:
        pass

    def fake_create_engine(url, **kwargs):
        captured["url"] = url
        captured["kwargs"] = kwargs
        return DummyEngine()

    monkeypatch.delenv("DB_USE_NULL_POOL", raising=False)
    monkeypatch.setenv(
        "DATABASE_URL",
        "postgresql://u:p@aws-0-eu-central-1.pooler.supabase.com:6543/postgres",
    )
    monkeypatch.setattr(database, "create_engine", fake_create_engine)

    database._create_engine()

    assert captured["url"] == (
        "postgresql+psycopg://u:p@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require"
    )
    kwargs = captured["kwargs"]
    assert isinstance(kwargs, dict)
    assert kwargs["poolclass"] is NullPool
    assert kwargs["connect_args"] == {"prepare_threshold": None}
    assert "pool_size" not in kwargs


def test_validate_production_settings_rejects_sqlite_and_accepts_postgres(monkeypatch):
    settings_module = importlib.import_module("app.settings")
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.setenv("ADMIN_PASSWORD", "StrongAdminPass!2026")
    monkeypatch.setattr(
        settings_module,
        "settings",
        replace(
            settings_module.settings,
            environment="production",
            jwt_secret="x" * 40,
            allow_legacy_token=False,
            cors_origins=("https://app.epilepsy.example",),
        ),
    )

    with pytest.raises(RuntimeError, match="DATABASE_URL"):
        settings_module.validate_production_settings()

    monkeypatch.setenv(
        "DATABASE_URL",
        "postgresql://u:p@aws-0-eu-central-1.pooler.supabase.com:6543/postgres",
    )
    monkeypatch.setenv("NOTIFICATION_CHANNEL", "fcm")
    settings_module.validate_production_settings()


def test_supabase_production_sql_parity_rls_and_no_hardcoded_admin_hash():
    sql_path = ROOT / "deploy" / "supabase_complete_production_schema.sql"
    sql = sql_path.read_text(encoding="utf-8")

    assert "20261121_10" in sql
    assert "$2b$" not in sql  # No hardcoded default admin bcrypt hashes
    assert "u.patient_id" not in sql  # Fixed broken view joins to u.id
    assert "LEFT JOIN users u ON a.patient_id = u.id" in sql
    assert "LEFT JOIN users u ON p.patient_id = u.id" in sql

    for table_name in database.metadata.tables:
        assert re.search(
            rf"CREATE TABLE IF NOT EXISTS\s+{re.escape(table_name)}\b",
            sql,
        ), f"Missing table in production SQL: {table_name}"
        assert f"'{table_name}'" in sql, f"Missing RLS enablement entry for: {table_name}"

    upgrade_sql = (ROOT / "deploy" / "supabase_upgrade_06_to_10.sql").read_text(encoding="utf-8")
    assert "20261121_10" in upgrade_sql
    assert "$2b$" not in upgrade_sql
    assert "ENABLE ROW LEVEL SECURITY" in upgrade_sql
