"""Copy the local SQLite database into a PostgreSQL/Supabase database.

Why a dedicated script instead of `pg_dump`/`sqlite3 .dump`: the two engines
disagree on booleans, autoincrement sequences and quoting, so a raw SQL dump
does not load cleanly. Reading through SQLAlchemy's table metadata lets the
same column definitions that created the schema also drive the copy.

Guarantees:
  * The target schema is created by Alembic first (`alembic upgrade head`), so
    this script never invents DDL that could drift from the migrations.
  * Tables are copied in foreign-key order, and the whole copy runs in ONE
    transaction: a failure halfway leaves the target untouched instead of
    half-populated.
  * The source is opened read-only; nothing here can damage the SQLite file.
  * Row counts are compared per table afterwards, and PostgreSQL identity
    sequences are re-synced so the next INSERT does not collide with copied ids.

Usage (PowerShell/cmd, from the repo root):

    set DATABASE_URL=postgresql://user:pass@host:5432/postgres?sslmode=require
    python backend\\migrate_sqlite_to_postgres.py --sqlite backend\\data\\epilepsy.db

Add `--dry-run` to only report source counts, or `--truncate` to clear the
target tables first (refused unless explicitly passed).
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Iterable, Iterator, Sequence

BACKEND_ROOT = Path(__file__).resolve().parent
if str(BACKEND_ROOT) not in sys.path:
    # Allows `python backend/migrate_sqlite_to_postgres.py` from the repo root.
    sys.path.insert(0, str(BACKEND_ROOT))

from sqlalchemy import Table, create_engine, delete, func, insert, select
from sqlalchemy.engine import Connection, Engine

from app.database import (  # noqa: E402  (import after sys.path fix)
    alert_acknowledgments,
    alert_outbox,
    alerts,
    assessments,
    assignments,
    audit_logs,
    caregiver_links,
    database_path,
    devices,
    is_sqlite_url,
    messages,
    normalize_database_url,
    outcomes,
    patients,
    push_tokens,
    readings,
    store_imports,
    users,
)

# Parents before children: every FK target must already exist when a child row
# is inserted, because the copy runs with foreign keys enforced (the default).
COPY_ORDER: tuple[Table, ...] = (
    users,
    patients,
    assignments,
    caregiver_links,
    devices,
    push_tokens,
    audit_logs,
    readings,
    assessments,
    alerts,
    alert_acknowledgments,
    outcomes,
    alert_outbox,
    store_imports,
    messages,
)

BATCH_SIZE = 500


def _target_url() -> str:
    raw = (os.getenv("DATABASE_URL") or "").strip()
    if not raw:
        raise SystemExit(
            "DATABASE_URL is required and must point at the PostgreSQL target.\n"
            "Never hardcode it: pass it as an environment variable."
        )
    url = normalize_database_url(raw)
    if is_sqlite_url(url):
        raise SystemExit("DATABASE_URL points at SQLite; expected a PostgreSQL target.")
    return url


def _source_engine(path: Path) -> Engine:
    if not path.exists():
        raise SystemExit(f"source SQLite database not found: {path}")
    # mode=ro: the source is treated as a read-only artefact during migration.
    uri = f"sqlite:///file:{path.as_posix()}?mode=ro&uri=true"
    return create_engine(uri, future=True)


def _rows(conn: Connection, table: Table) -> Iterator[list[dict[str, object]]]:
    """Stream the table in batches so a large readings table fits in memory."""
    result = conn.execution_options(stream_results=True).execute(select(table))
    while True:
        chunk = result.fetchmany(BATCH_SIZE)
        if not chunk:
            return
        yield [dict(row._mapping) for row in chunk]


def _count(conn: Connection, table: Table) -> int:
    return int(conn.scalar(select(func.count()).select_from(table)) or 0)


def _coerce(table: Table, batch: list[dict[str, object]]) -> list[dict[str, object]]:
    """SQLite stores booleans as 0/1; psycopg needs real bools."""
    bool_columns = [c.name for c in table.columns if c.type.python_type is bool]
    if not bool_columns:
        return batch
    for row in batch:
        for name in bool_columns:
            if row.get(name) is not None:
                row[name] = bool(row[name])
    return batch


def _resync_sequences(target: Connection, tables: Iterable[Table]) -> list[str]:
    """Realign identity sequences with the copied primary keys.

    Copied rows carry explicit `sequence` values, which leaves PostgreSQL's
    sequence at 1 and makes the first new insert fail with a duplicate key.
    """
    from sqlalchemy import text

    resynced: list[str] = []
    for table in tables:
        for column in table.primary_key.columns:
            if column.autoincrement is not True:
                continue
            seq = target.scalar(
                text("SELECT pg_get_serial_sequence(:t, :c)"),
                {"t": table.name, "c": column.name},
            )
            if not seq:
                continue
            target.execute(text(
                f"SELECT setval('{seq}', COALESCE((SELECT MAX({column.name}) "
                f"FROM {table.name}), 0) + 1, false)"
            ))
            resynced.append(f"{table.name}.{column.name}")
    return resynced


def _assert_empty(target: Connection, tables: Sequence[Table], truncate: bool) -> None:
    populated = [t.name for t in tables if _count(target, t)]
    if not populated:
        return
    if not truncate:
        raise SystemExit(
            "target is not empty: " + ", ".join(populated) + "\n"
            "Re-run with --truncate to replace its contents, or migrate into a "
            "fresh database. Refusing to mix two datasets."
        )
    # Children first so FK constraints hold at every step.
    for table in reversed(tables):
        target.execute(delete(table))


def migrate(sqlite_path: Path, *, truncate: bool, dry_run: bool) -> int:
    source = _source_engine(sqlite_path)
    with source.connect() as src:
        source_counts = {t.name: _count(src, t) for t in COPY_ORDER}

    print(f"source: {sqlite_path}")
    for name, count in source_counts.items():
        print(f"  {name:<24} {count:>8}")
    if dry_run:
        print("dry-run: nothing written")
        return 0

    target_engine = create_engine(_target_url(), future=True, pool_pre_ping=True)
    copied: dict[str, int] = {}
    with source.connect() as src, target_engine.begin() as dst:
        _assert_empty(dst, COPY_ORDER, truncate)
        for table in COPY_ORDER:
            written = 0
            for batch in _rows(src, table):
                dst.execute(insert(table), _coerce(table, batch))
                written += len(batch)
            copied[table.name] = written
            print(f"copied {table.name:<24} {written:>8}")
        resynced = _resync_sequences(dst, COPY_ORDER)

    # Verify against the committed target, not the in-transaction view.
    mismatches: list[str] = []
    with target_engine.connect() as dst:
        for table in COPY_ORDER:
            expected = source_counts[table.name]
            actual = _count(dst, table)
            if expected != actual:
                mismatches.append(f"{table.name}: source={expected} target={actual}")

    if resynced:
        print("resynced sequences: " + ", ".join(resynced))
    if mismatches:
        print("ROW COUNT MISMATCH:")
        for line in mismatches:
            print("  " + line)
        return 1
    print(f"OK: {sum(copied.values())} rows copied, all row counts match")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sqlite",
        type=Path,
        default=None,
        help="source SQLite file (default: the path the backend itself resolves)",
    )
    parser.add_argument("--truncate", action="store_true",
                        help="delete existing rows in the target before copying")
    parser.add_argument("--dry-run", action="store_true",
                        help="only print source row counts")
    args = parser.parse_args()
    # Resolve the default the same way the app does, so both read one database.
    sqlite_path = args.sqlite.expanduser().resolve() if args.sqlite else database_path()
    return migrate(sqlite_path, truncate=args.truncate, dry_run=args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
