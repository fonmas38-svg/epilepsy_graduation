"""Regression coverage for production configuration and malformed stored hashes."""
from dataclasses import replace
from pathlib import Path
import asyncio
import importlib

import pytest
from fastapi import HTTPException
from app import security


@pytest.mark.parametrize("iterations", ["0", "-1", "bad", "100000000000000000000"])
def test_corrupt_password_hash_fails_closed(iterations):
    assert security.verify_password("password", f"pbkdf2_sha256${iterations}$YQ==$Yg==") is False


def test_corrupt_rehash_metadata_is_handled():
    assert security.needs_rehash("pbkdf2_sha256$bad$a$b") is True


def test_production_validation_cannot_be_disabled(monkeypatch):
    settings_module = importlib.import_module("app.settings")
    monkeypatch.setattr(settings_module, "settings", replace(settings_module.settings,
        environment="production", jwt_secret="dev-only-change-me-in-production"))
    monkeypatch.setenv("STRICT_PRODUCTION_VALIDATION", "0")
    with pytest.raises(RuntimeError, match="JWT_SECRET"):
        settings_module.validate_production_settings()


def test_admin_static_route_rejects_escape():
    module = importlib.import_module("app.main")
    if not hasattr(module, "serve_admin_dashboard"):
        pytest.skip("Dashboard dist is absent")
    with pytest.raises(HTTPException) as exc:
        asyncio.run(module.serve_admin_dashboard("../../backend/app/settings.py"))
    assert exc.value.status_code == 404
