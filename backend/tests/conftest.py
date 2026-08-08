"""Shared pytest fixtures.

The account system seeds an admin during app startup (lifespan) and persists
users to a JSON file. To keep the suite hermetic we point USERS_STORE_PATH at a
unique temp file for every test and pin deterministic admin credentials, so:
  * the real backend/data/users_store.json is never touched by tests, and
  * each test starts from a freshly seeded, known-password admin.

This fixture is autouse, so it also protects the pre-existing test_api.py tests
(which enter the same lifespan) without any change to that file.
"""
import os

import pytest

TEST_ADMIN_USERNAME = "admin"
TEST_ADMIN_PASSWORD = "admin-test-pass-123"


@pytest.fixture(autouse=True)
def _isolate_stores(monkeypatch, tmp_path):
    monkeypatch.setenv("USERS_STORE_PATH", str(tmp_path / "users_store.json"))
    monkeypatch.setenv("ADMIN_USERNAME", TEST_ADMIN_USERNAME)
    monkeypatch.setenv("ADMIN_PASSWORD", TEST_ADMIN_PASSWORD)
    monkeypatch.setenv("JWT_SECRET", "test-secret")
    # keep PBKDF2 fast so the suite doesn't pay 200k iterations per hash
    monkeypatch.setenv("PBKDF2_ITERATIONS", "1000")
    yield
