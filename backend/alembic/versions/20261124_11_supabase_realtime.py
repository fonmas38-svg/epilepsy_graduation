"""Enable Supabase Realtime publication on clinical alerts and messaging tables.

Revision ID: 20261124_11
Revises: 20261121_10
"""
from __future__ import annotations

from alembic import op


revision = "20261124_11"
down_revision = "20261121_10"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    if bind.dialect.name == "postgresql":
        # Enable Supabase Realtime on core clinical and family tables if publication exists
        op.execute(
            """
            DO $$
            BEGIN
                IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
                    BEGIN
                        ALTER PUBLICATION supabase_realtime ADD TABLE alerts, messages, medication_logs, prescriptions;
                    EXCEPTION
                        WHEN duplicate_object THEN
                            NULL;
                    END;
                END IF;
            END $$;
            """
        )


def downgrade() -> None:
    bind = op.get_bind()
    if bind.dialect.name == "postgresql":
        op.execute(
            """
            DO $$
            BEGIN
                IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
                    BEGIN
                        ALTER PUBLICATION supabase_realtime DROP TABLE alerts, messages, medication_logs, prescriptions;
                    EXCEPTION
                        WHEN undefined_object THEN
                            NULL;
                    END;
                END IF;
            END $$;
            """
        )
