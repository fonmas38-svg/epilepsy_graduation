"""Enforce case-insensitive usernames on every backend.

Revision 20260815_01 relied on SQLite's `NOCASE` column collation, which has no
PostgreSQL equivalent. A unique index on `lower(username)` expresses the same
rule portably, so hosted PostgreSQL deployments cannot end up with `Admin` and
`admin` as two separate accounts.

Revision ID: 20260817_05
Revises: 20260816_04
"""
from typing import Sequence, Union

from alembic import context, op
import sqlalchemy as sa

revision: str = "20260817_05"
down_revision: Union[str, Sequence[str], None] = "20260816_04"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

INDEX_NAME = "ux_users_username_lower"


def upgrade() -> None:
    if not context.is_offline_mode():
        bind = op.get_bind()
        if bind is not None and getattr(bind, "dialect", None) and bind.dialect.name == "postgresql":
            # Existing rows must be collapsed before a unique index can be created;
            # failing loudly beats silently dropping an account's login.
            res = bind.execute(sa.text(
                "SELECT lower(username) FROM users GROUP BY lower(username) HAVING count(*) > 1"
            ))
            if res is not None:
                duplicates = res.scalars().all()
                if duplicates:
                    raise RuntimeError(
                        "cannot enforce case-insensitive usernames; resolve duplicates first: "
                        + ", ".join(duplicates)
                    )
    op.create_index(
        INDEX_NAME, "users", [sa.text("lower(username)")], unique=True
    )


def downgrade() -> None:
    op.drop_index(INDEX_NAME, table_name="users")
