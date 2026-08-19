from __future__ import annotations

from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.database import configured_database_url, database_url, metadata

config = context.config
if config.config_file_name is not None:
    # disable_existing_loggers=False: migrations run inside the API process at
    # startup, and the default (True) would silence the app's own JSON logging.
    fileConfig(config.config_file_name, disable_existing_loggers=False)

if configured_database_url() and not config.attributes.get("explicit_url"):
    # `alembic upgrade head` run by hand must target the same database as the
    # API. Without this the hardcoded sqlite URL in alembic.ini would silently
    # migrate a local file while production PostgreSQL stays on an old revision.
    #
    # `explicit_url` is set by callers that already chose a database on purpose
    # (the app's own migration step, and the migration tests that must stay on a
    # throwaway SQLite file even when the suite runs against PostgreSQL — those
    # tests downgrade to base, i.e. drop every table).
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
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
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