"""Shared pytest fixtures.

Startup (lifespan) seeds an admin and may import legacy JSON stores. To keep the
suite hermetic every storage location is redirected into a per-test tmp dir:
  * SQLITE_DB_PATH  -> a fresh database per test,
  * USERS_STORE_PATH / CLOUD_STORE_PATH -> temp paths, so the real files in
    backend/data are never read, written, or backed up by the test run,
  * cached engines are disposed afterwards so no test leaks a connection.

This fixture is autouse, so it also protects the pre-existing tests that enter
the same lifespan without any change to those files.

Running the suite against PostgreSQL
------------------------------------
Set `TEST_DATABASE_URL` (a *separate* variable from `DATABASE_URL`) to run every
test against a real PostgreSQL/Supabase database instead of SQLite. This is the
only way to prove portability: dialect differences (booleans, `ON CONFLICT`,
`lower(username)` uniqueness, sequences) simply do not appear on SQLite.

The database is TRUNCATEd before each test, so it must be a throwaway one. The
opt-in is deliberately a different variable name: a `DATABASE_URL` left in a
developer's shell is *removed* below and can never be truncated by accident.
"""
import os

import pytest

from app.database import metadata, reset_engine_cache
from app.metrics import metrics

TEST_ADMIN_USERNAME = "admin"
TEST_ADMIN_PASSWORD = "admin-test-pass-123"

TEST_DATABASE_URL = (os.getenv("TEST_DATABASE_URL") or "").strip()


def _reset_external_database() -> None:
    """Bring a real database to a clean, migrated state for the next test.

    `RESTART IDENTITY` matters: several tests assert on ordering that comes from
    the autoincrement `sequence` columns, which would keep growing otherwise.
    """
    from sqlalchemy import text

    from app.database import initialize_database, transaction

    initialize_database()  # alembic upgrade head; a no-op after the first test
    names = ", ".join(f'"{table.name}"' for table in metadata.sorted_tables)
    with transaction() as conn:
        conn.execute(text(f"TRUNCATE {names} RESTART IDENTITY CASCADE"))


@pytest.fixture(autouse=True)
def _isolate_stores(monkeypatch, tmp_path):
    # Removed first: a DATABASE_URL left in the developer's shell would point the
    # suite at a real PostgreSQL/Supabase database and destroy live data.
    monkeypatch.delenv("DATABASE_URL", raising=False)
    if TEST_DATABASE_URL:
        # Explicit opt-in only (see the module docstring).
        monkeypatch.setenv("DATABASE_URL", TEST_DATABASE_URL)
    monkeypatch.setenv("SQLITE_DB_PATH", str(tmp_path / "epilepsy.db"))

    monkeypatch.setenv("USERS_STORE_PATH", str(tmp_path / "users_store.json"))
    monkeypatch.setenv("CLOUD_STORE_PATH", str(tmp_path / "cloud_store.json"))
    monkeypatch.setenv("ADMIN_USERNAME", TEST_ADMIN_USERNAME)
    monkeypatch.setenv("ADMIN_PASSWORD", TEST_ADMIN_PASSWORD)
    monkeypatch.setenv("JWT_SECRET", "test-secret")
    # keep PBKDF2 fast so the suite doesn't pay 200k iterations per hash
    monkeypatch.setenv("PBKDF2_ITERATIONS", "1000")
    # Tests drain the outbox explicitly; a timer-driven worker would make
    # delivery assertions racy.
    monkeypatch.setenv("OUTBOX_WORKER_ENABLED", "0")
    reset_engine_cache()
    if TEST_DATABASE_URL:
        # SQLite gets a brand-new file per test; a shared server cannot, so the
        # previous test's rows are cleared explicitly instead.
        _reset_external_database()
    metrics.reset()
    yield
    reset_engine_cache()
