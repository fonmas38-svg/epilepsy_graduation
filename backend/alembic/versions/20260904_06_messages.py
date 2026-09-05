"""Add messages table for private doctor-patient and family care channels.

Revision ID: 20260904_06
Revises: 20260817_05
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "20260904_06"
down_revision: Union[str, Sequence[str], None] = "20260817_05"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "messages",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column(
            "patient_id",
            sa.String(64),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "sender_id",
            sa.String(64),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("sender_name", sa.String(256), nullable=False),
        sa.Column("sender_role", sa.String(32), nullable=False),
        sa.Column("channel_type", sa.String(32), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("read_at", sa.String(64), nullable=True),
        sa.CheckConstraint(
            "channel_type IN ('doctor_patient', 'family_patient')",
            name="ck_messages_channel_type",
        ),
    )
    op.create_index(
        "ix_messages_patient_channel",
        "messages",
        ["patient_id", "channel_type"],
    )
    op.create_index(
        "ix_messages_created_at",
        "messages",
        ["created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_messages_created_at", table_name="messages")
    op.drop_index("ix_messages_patient_channel", table_name="messages")
    op.drop_table("messages")
