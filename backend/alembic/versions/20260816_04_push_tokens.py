"""Add private FCM registration-token storage.

Revision ID: 20260816_04
Revises: 20260816_03
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "20260816_04"
down_revision: Union[str, Sequence[str], None] = "20260816_03"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "push_tokens",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column(
            "user_id",
            sa.String(64),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("token", sa.Text(), nullable=False, unique=True),
        sa.Column("platform", sa.String(32), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
    )
    op.create_index("ix_push_tokens_user_id", "push_tokens", ["user_id"])


def downgrade() -> None:
    op.drop_table("push_tokens")