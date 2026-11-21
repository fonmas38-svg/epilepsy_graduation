"""Phase 1 master schema alignment across Supabase PostgreSQL and SQLite.

Revision ID: 20261121_10
Revises: 20261114_09
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20261121_10"
down_revision = "20261114_09"
branch_labels = None
depends_on = None


_OLD_CHANNELS = "channel_type IN ('doctor_patient', 'family_patient')"
_NEW_CHANNELS = (
    "channel_type IN ("
    "'doctor_patient', 'family_patient', "
    "'patient_caregiver', 'doctor_caregiver', 'care_team_triage'"
    ")"
)


def upgrade() -> None:
    # Add column directly (never batch_alter_table on users) so SQLite retains
    # the functional index ux_users_username_lower on lower(username).
    op.add_column("users", sa.Column("email", sa.String(255), nullable=True))
    op.create_index(
        "uq_users_email_active",
        "users",
        [sa.text("lower(email)")],
        unique=True,
        sqlite_where=sa.text("email IS NOT NULL AND disabled = 0"),
        postgresql_where=sa.text("email IS NOT NULL AND disabled = FALSE"),
    )

    op.add_column("account_sessions", sa.Column("device_id", sa.String(128), nullable=True))
    op.add_column(
        "account_sessions",
        sa.Column(
            "is_hardware_bound",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )
    op.create_index(
        "ix_account_sessions_device_id",
        "account_sessions",
        ["user_id", "device_id"],
    )

    op.create_table(
        "doctor_profiles",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column(
            "user_id",
            sa.String(64),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
            unique=True,
        ),
        sa.Column("license_number", sa.String(64), nullable=False, unique=True),
        sa.Column("specialization", sa.String(120), nullable=False),
        sa.Column("hospital_affiliation", sa.String(180), nullable=False),
        sa.Column("national_id", sa.String(32), nullable=False, unique=True),
        sa.Column("phone", sa.String(32), nullable=False),
        sa.Column("moh_verified", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("moh_status", sa.String(32), nullable=True),
        sa.Column("moh_checked_at", sa.String(64), nullable=True),
        sa.Column("moh_override_by", sa.String(64), nullable=True),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
    )

    op.create_table(
        "moh_registry",
        sa.Column("license_number", sa.String(64), primary_key=True),
        sa.Column("national_id", sa.String(32), nullable=False),
        sa.Column("full_name_ar", sa.String(180), nullable=False),
        sa.Column("full_name_en", sa.String(180), nullable=False),
        sa.Column("specialization", sa.String(120), nullable=False),
        sa.Column("hospital_affiliation", sa.String(180), nullable=True),
        sa.Column("status", sa.String(32), nullable=False),
        sa.Column("expiration_date", sa.String(32), nullable=False),
        sa.CheckConstraint(
            "status IN ('active', 'suspended', 'expired')",
            name="ck_moh_registry_status",
        ),
    )
    op.create_index("ix_moh_registry_national_id", "moh_registry", ["national_id"])

    op.create_table(
        "idempotency_keys",
        sa.Column("key", sa.String(128), primary_key=True),
        sa.Column("actor_id", sa.String(64), nullable=False),
        sa.Column("endpoint", sa.String(128), nullable=False),
        sa.Column("response_status", sa.Integer(), nullable=False),
        sa.Column("response_json", sa.Text(), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
    )
    op.create_index("ix_idempotency_keys_created_at", "idempotency_keys", ["created_at"])

    op.add_column("prescriptions", sa.Column("period_context", sa.String(32), nullable=True))
    op.add_column("prescriptions", sa.Column("meal_context", sa.String(32), nullable=True))
    op.add_column("prescriptions", sa.Column("meal_type", sa.String(32), nullable=True))
    op.add_column("prescriptions", sa.Column("times_json", sa.Text(), nullable=True))

    op.create_table(
        "medication_logs",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column(
            "prescription_id",
            sa.String(64),
            sa.ForeignKey("prescriptions.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "patient_id",
            sa.String(64),
            sa.ForeignKey("patients.patient_id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("scheduled_time", sa.String(64), nullable=False),
        sa.Column("taken_at", sa.String(64), nullable=True),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("recorded_by", sa.String(64), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.CheckConstraint(
            "status IN ('taken', 'missed', 'skipped')",
            name="ck_medication_logs_status",
        ),
    )
    op.create_index(
        "ux_medication_logs_rx_slot",
        "medication_logs",
        ["prescription_id", "scheduled_time"],
        unique=True,
    )
    op.create_index(
        "ix_medication_logs_patient",
        "medication_logs",
        ["patient_id", "scheduled_time"],
    )

    op.add_column(
        "outcomes",
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
    )
    op.create_index(
        "uq_outcomes_patient_alert",
        "outcomes",
        ["patient_id", "alert_id"],
        unique=True,
        sqlite_where=sa.text("alert_id IS NOT NULL"),
        postgresql_where=sa.text("alert_id IS NOT NULL"),
    )

    with op.batch_alter_table("messages") as batch:
        batch.add_column(sa.Column("peer_user_id", sa.String(64), nullable=True))
        batch.add_column(sa.Column("delivered_at", sa.String(64), nullable=True))
        batch.create_foreign_key(
            "fk_messages_peer_user",
            "users",
            ["peer_user_id"],
            ["id"],
            ondelete="SET NULL",
        )
        batch.drop_constraint("ck_messages_channel_type", type_="check")
        batch.create_check_constraint("ck_messages_channel_type", _NEW_CHANNELS)
        batch.create_index(
            "ix_messages_peer_user_id",
            ["patient_id", "channel_type", "peer_user_id"],
        )


def downgrade() -> None:
    with op.batch_alter_table("messages") as batch:
        batch.drop_index("ix_messages_peer_user_id")
        batch.drop_constraint("ck_messages_channel_type", type_="check")
        batch.create_check_constraint("ck_messages_channel_type", _OLD_CHANNELS)
        batch.drop_constraint("fk_messages_peer_user", type_="foreignkey")
        batch.drop_column("delivered_at")
        batch.drop_column("peer_user_id")

    op.drop_index("uq_outcomes_patient_alert", table_name="outcomes")
    op.drop_column("outcomes", "version")

    op.drop_index("ix_medication_logs_patient", table_name="medication_logs")
    op.drop_index("ux_medication_logs_rx_slot", table_name="medication_logs")
    op.drop_table("medication_logs")

    op.drop_column("prescriptions", "times_json")
    op.drop_column("prescriptions", "meal_type")
    op.drop_column("prescriptions", "meal_context")
    op.drop_column("prescriptions", "period_context")

    op.drop_index("ix_idempotency_keys_created_at", table_name="idempotency_keys")
    op.drop_table("idempotency_keys")

    op.drop_index("ix_moh_registry_national_id", table_name="moh_registry")
    op.drop_table("moh_registry")

    op.drop_table("doctor_profiles")

    op.drop_index("ix_account_sessions_device_id", table_name="account_sessions")
    op.drop_column("account_sessions", "is_hardware_bound")
    op.drop_column("account_sessions", "device_id")

    op.drop_index("uq_users_email_active", table_name="users")
    op.drop_column("users", "email")
