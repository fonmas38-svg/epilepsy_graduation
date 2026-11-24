"""Opt-in PostgreSQL checks. TEST_DATABASE_URL MUST name a disposable database.

The existing suite fixture truncates this database. No production DATABASE_URL
is read by these tests. They skip on SQLite rather than claiming RLS was tested.
"""
import pytest
from sqlalchemy import text
from app.database import connection, metadata
from tests.conftest import TEST_DATABASE_URL

pytestmark = pytest.mark.skipif(not TEST_DATABASE_URL, reason="requires disposable TEST_DATABASE_URL")


def test_postgres_head_and_all_clinical_tables_have_rls():
    with connection() as conn:
        assert conn.dialect.name == "postgresql"
        assert conn.execute(text("SELECT version_num FROM alembic_version")).scalar_one() == "20261124_12"
        rows = conn.execute(text("SELECT relname, relrowsecurity FROM pg_class JOIN pg_namespace n ON n.oid = relnamespace WHERE n.nspname = 'public' AND relkind = 'r'"))
        enabled = dict(rows)
    for name in metadata.tables:
        assert enabled.get(name), f"RLS missing: {name}"


@pytest.mark.parametrize("role", ["anon", "authenticated"])
def test_postgrest_roles_cannot_access_backend_clinical_tables(role):
    with connection() as conn:
        if not conn.execute(text("SELECT 1 FROM pg_roles WHERE rolname = :role"), {"role": role}).first():
            pytest.skip(f"{role} is absent; use a Supabase-compatible test database")
        for name in metadata.tables:
            privileges = conn.execute(text("SELECT has_table_privilege(:role, :table, 'SELECT'), has_table_privilege(:role, :table, 'INSERT'), has_table_privilege(:role, :table, 'UPDATE'), has_table_privilege(:role, :table, 'DELETE')"),
                {"role": role, "table": f"public.{name}"}).one()
            assert not any(privileges), f"{role} has clinical table privileges on {name}"


def test_realtime_publication_contains_each_required_table():
    with connection() as conn:
        if not conn.execute(text("SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime'")).first():
            pytest.skip("Supabase Realtime publication is absent")
        tables = set(conn.execute(text("SELECT tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public'")).scalars())
    assert {"alerts", "messages", "medication_logs", "prescriptions"} <= tables
