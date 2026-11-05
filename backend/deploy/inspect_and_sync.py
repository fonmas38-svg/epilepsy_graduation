"""Compatibility entry point for the transactional SQLite → PostgreSQL migrator.

The former REST synchronizer embedded a server credential and deleted the admin
account before copying. It must no longer be used. Rotate the previously exposed
Supabase key in the provider console; removing it from source does not revoke it.

Use --dry-run to inspect the source. A real migration requires DATABASE_URL and
an empty, Alembic-migrated destination; replacement requires explicit --truncate.
No credentials or production URLs are supplied by this script.
"""
from pathlib import Path
import sys

BACKEND = Path(__file__).resolve().parents[1]
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))


def main() -> int:
    from migrate_sqlite_to_postgres import main as migrate_main

    return migrate_main()


if __name__ == "__main__":
    raise SystemExit(main())
