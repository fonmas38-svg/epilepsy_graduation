"""Per-recipient message receipts (delivered / read).

Revision ID: 20261127_13
Revises: 20261124_12
"""
import sqlalchemy as sa
from alembic import op

revision = "20261127_13"
down_revision = "20261124_12"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "message_receipts",
        sa.Column(
            "message_id",
            sa.String(64),
            sa.ForeignKey("messages.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "user_id",
            sa.String(64),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("delivered_at", sa.String(64), nullable=False),
        sa.Column("read_at", sa.String(64)),
    )
    op.create_index("ix_message_receipts_user", "message_receipts", ["user_id"])
    if op.get_bind().dialect.name == "postgresql":
        # Backend-only like every clinical table (see 20261124_12).
        op.execute("ALTER TABLE public.message_receipts ENABLE ROW LEVEL SECURITY")
        op.execute("REVOKE ALL ON public.message_receipts FROM PUBLIC")
        op.execute(
            """DO $$ BEGIN
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
                REVOKE ALL ON public.message_receipts FROM anon; END IF;
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
                REVOKE ALL ON public.message_receipts FROM authenticated; END IF;
            END $$;"""
        )


def downgrade() -> None:
    op.drop_index("ix_message_receipts_user", table_name="message_receipts")
    op.drop_table("message_receipts")
