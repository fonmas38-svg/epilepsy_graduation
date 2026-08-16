"""Prove the service can actually boot, not just that unit tests pass.

The test suite runs against an in-memory database with the background worker
disabled. That leaves a real gap: a broken Alembic migration, or a dependency
that is unreachable at startup, would pass every test and still fail the moment
the API is launched for the demo.

This script performs a real startup against a real database file and asserts
that readiness reports every dependency as healthy.

Usage (from the backend/ directory):
    python startup_check.py
"""
from __future__ import annotations

import sys
from pathlib import Path

# Allow running as a plain script: `python startup_check.py`.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402


def main() -> int:
    # Entering the context manager triggers lifespan: migrations, model
    # loading, and the outbox worker.
    with TestClient(app) as client:
        live = client.get("/health/live")
        if live.status_code != 200:
            print(f"FAIL liveness: {live.status_code} {live.text}")
            return 1

        ready = client.get("/health/ready")
        if ready.status_code != 200:
            print(f"FAIL readiness: {ready.status_code} {ready.text}")
            return 1

        checks = ready.json().get("checks", {})
        broken = [name for name, ok in checks.items() if not ok]
        if broken or not checks:
            print(f"FAIL dependencies not healthy: {checks}")
            return 1

        print(f"STARTUP OK: {checks}")
    # Exiting the context manager must shut down cleanly (worker cancelled).
    print("SHUTDOWN OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
