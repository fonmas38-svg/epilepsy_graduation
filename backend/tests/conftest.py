"""Shared pytest fixtures.

Startup (lifespan) seeds an admin and may import legacy JSON stores. To keep the
suite hermetic every storage location is redirected into a per-test tmp dir:
  * SQLITE_DB_PATH  -> a fresh database per test,
  * USERS_STORE_PATH / CLOUD_STORE_PATH -> temp paths, so the real files in
    backend/data are never read, written, or backed up by the test run,
  * cached engines are disposed afterwards so no test leaks a connection.

This fixture is autouse, so it also protects the pre-existing tests that enter
the same lifespan without any change to those files.
"""
import pytest

from app.database import reset_engine_cache
from app.metrics import metrics

TEST_ADMIN_USERNAME = "admin"
TEST_ADMIN_PASSWORD = "admin-test-pass-123"


@pytest.fixture(autouse=True)
def _isolate_stores(monkeypatch, tmp_path):
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
    metrics.reset()
    yield
    reset_engine_cache()
