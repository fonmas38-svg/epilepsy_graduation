"""Guards for the SQLite -> PostgreSQL copy plan.

The ETL itself needs a live PostgreSQL server, but its two silent-failure modes
can be caught without one:

  * a table added to `metadata` later but forgotten in `COPY_ORDER` would be
    skipped, and the migration would report success with missing data;
  * a wrong order would break foreign keys only on the real database, i.e.
    during the migration window.

The third test documents the refusal to run against SQLite, so a forgotten
`DATABASE_URL` cannot make the script "migrate" a file onto itself.
"""
from __future__ import annotations

import pytest

from app.database import metadata
from migrate_sqlite_to_postgres import COPY_ORDER, _target_url


def test_copy_order_covers_every_table():
    planned = {table.name for table in COPY_ORDER}
    defined = set(metadata.tables)
    assert planned == defined, (
        "COPY_ORDER is out of sync with the schema; missing="
        f"{sorted(defined - planned)} extra={sorted(planned - defined)}"
    )


def test_copy_order_respects_foreign_keys():
    position = {table.name: index for index, table in enumerate(COPY_ORDER)}
    for table in COPY_ORDER:
        for fk in table.foreign_keys:
            parent = fk.column.table.name
            if parent == table.name:
                continue  # self-reference: same INSERT batch order applies
            assert position[parent] <= position[table.name], (
                f"{table.name} is copied before its parent {parent}"
            )


def test_sqlite_target_is_refused(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "sqlite:///./data/epilepsy.db")
    with pytest.raises(SystemExit):
        _target_url()


def test_missing_target_is_refused(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(SystemExit):
        _target_url()


def test_hosted_connection_string_is_normalised(monkeypatch):
    # Hosting panels hand out `postgres://`; the driver must be pinned to psycopg 3.
    monkeypatch.setenv("DATABASE_URL", "postgres://u:p@db.example.net:5432/postgres")
    assert _target_url().startswith("postgresql+psycopg://")
