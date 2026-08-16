"""Add the transactional alert outbox.

A notification intent is written in the same transaction as its alert, so a
stored alert can never silently lack a delivery attempt.

Revision ID: 20260815_02
Revises: 20260815_01
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "20260815_02"
down_revision: Union[str, Sequence[str], None] = "20260815_01"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "alert_outbox",
        sa.Column("id", sa.String(64), primary_key=True),
        # UNIQUE keeps enqueueing idempotent: one delivery record per alert.
        sa.Column("alert_id", sa.String(64), nullable=False, unique=True),
        sa.Column("patient_id", sa.String(64), nullable=False),
        sa.Column("payload_json", sa.Text(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.String(64), nullable=False),
        sa.Column("last_error", sa.Text()),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
        sa.CheckConstraint(
            "status IN ('pending', 'sent', 'failed', 'dead')",
            name="ck_alert_outbox_status",
        ),
    )
    # The worker's hot query is "due pending rows ordered by time".
    op.create_index(
        "ix_alert_outbox_due", "alert_outbox", ["status", "next_attempt_at"]
    )


def downgrade() -> None:
    op.drop_index("ix_alert_outbox_due", table_name="alert_outbox")
    op.drop_table("alert_outbox")
