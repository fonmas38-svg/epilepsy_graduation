from __future__ import annotations

import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.database import (
    configured_database_url,
    database_url,
    is_supabase_transaction_pooler_url,
    metadata,
    normalize_database_url,
)

config = context.config
if config.config_file_name is not None:
    # disable_existing_loggers=False: migrations run inside the API process at
    # startup, and the default (True) would silence the app's own JSON logging.
    fileConfig(config.config_file_name, disable_existing_loggers=False)

if not config.attributes.get("explicit_url"):
    # Prefer direct DDL URL when supplied (`ALEMBIC_DATABASE_URL`, e.g. Supabase
    # direct port 5432); otherwise fall back to `DATABASE_URL`.
    alembic_url = (os.getenv("ALEMBIC_DATABASE_URL") or "").strip()
    if alembic_url:
        config.set_main_option("sqlalchemy.url", normalize_database_url(alembic_url))
    elif configured_database_url():
        config.set_main_option("sqlalchemy.url", database_url())



target_metadata = metadata


def run_migrations_offline() -> None:
    context.configure(
        url=config.get_main_option("sqlalchemy.url"),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    resolved_url = config.get_main_option("sqlalchemy.url") or ""
    extra_kwargs = (
        {"connect_args": {"prepare_threshold": None}}
        if is_supabase_transaction_pooler_url(resolved_url)
        else {}
    )
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
        **extra_kwargs,
    )
    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=True,
            render_as_batch=connection.dialect.name == "sqlite",
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()