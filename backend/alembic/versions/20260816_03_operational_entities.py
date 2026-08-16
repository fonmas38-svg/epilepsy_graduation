"""Add registered devices, caregiver links, acknowledgments, and outcomes.

Revision ID: 20260816_03
Revises: 20260815_02
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "20260816_03"
down_revision: Union[str, Sequence[str], None] = "20260815_02"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "caregiver_links",
        sa.Column("patient_id", sa.String(64), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("caregiver_id", sa.String(64), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("linked_by", sa.String(64)),
        sa.Column("linked_at", sa.String(64), nullable=False),
    )
    op.create_index("ix_caregiver_links_caregiver_id", "caregiver_links", ["caregiver_id"])

    op.create_table(
        "devices",
        sa.Column("device_id", sa.String(128), primary_key=True),
        sa.Column("patient_id", sa.String(64), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(256), nullable=False),
        sa.Column("secret_hash", sa.Text(), nullable=False),
        sa.Column("credential_version", sa.Integer(), nullable=False),
        sa.Column("disabled", sa.Boolean(), nullable=False),
        sa.Column("created_by", sa.String(64)),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
        sa.Column("last_enrolled_at", sa.String(64)),
    )
    op.create_index("ix_devices_patient_id", "devices", ["patient_id"])

    op.create_table(
        "alert_acknowledgments",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column("alert_id", sa.String(64), sa.ForeignKey("alerts.id", ondelete="CASCADE"), nullable=False),
        sa.Column("patient_id", sa.String(64), nullable=False),
        sa.Column("actor_id", sa.String(64), nullable=False),
        sa.Column("actor_role", sa.String(32)),
        sa.Column("acknowledged_at", sa.String(64), nullable=False),
        sa.Column("note", sa.Text()),
    )
    op.create_index("ix_alert_acknowledgments_alert", "alert_acknowledgments", ["alert_id"])
    op.create_index("ix_alert_acknowledgments_patient", "alert_acknowledgments", ["patient_id"])
    op.create_index(
        "ux_alert_acknowledgments_actor",
        "alert_acknowledgments",
        ["alert_id", "actor_id"],
        unique=True,
    )

    op.create_table(
        "outcomes",
        sa.Column("sequence", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("id", sa.String(64), nullable=False, unique=True),
        sa.Column("patient_id", sa.String(64), sa.ForeignKey("patients.patient_id", ondelete="CASCADE"), nullable=False),
        sa.Column("assessment_id", sa.String(64), sa.ForeignKey("assessments.id", ondelete="SET NULL")),
        sa.Column("alert_id", sa.String(64), sa.ForeignKey("alerts.id", ondelete="SET NULL")),
        sa.Column("outcome", sa.String(32), nullable=False),
        sa.Column("occurred_at", sa.String(64), nullable=False),
        sa.Column("recorded_by", sa.String(64), nullable=False),
        sa.Column("recorded_at", sa.String(64), nullable=False),
        sa.Column("notes", sa.Text()),
        sa.Column("payload_json", sa.Text(), nullable=False),
        sa.CheckConstraint(
            "outcome IN ('seizure', 'no_seizure', 'false_alarm', 'unknown')",
            name="ck_outcomes_outcome",
        ),
    )
    op.create_index("ix_outcomes_patient_sequence", "outcomes", ["patient_id", "sequence"])
    op.create_index("ix_outcomes_assessment_id", "outcomes", ["assessment_id"])


def downgrade() -> None:
    op.drop_table("outcomes")
    op.drop_table("alert_acknowledgments")
    op.drop_table("devices")
    op.drop_table("caregiver_links")