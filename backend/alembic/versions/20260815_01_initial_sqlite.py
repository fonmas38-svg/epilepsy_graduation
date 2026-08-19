"""Create account and monitoring tables.

Revision ID: 20260815_01
Revises: none
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "20260815_01"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _username_type() -> sa.String:
    """`NOCASE` exists only in SQLite, so it is applied only there.

    Case-insensitive uniqueness is enforced for every backend by the
    `lower(username)` unique index added in revision 20260817_05.
    """
    if op.get_bind().dialect.name == "sqlite":
        return sa.String(128, collation="NOCASE")
    return sa.String(128)


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column("username", _username_type(), nullable=False, unique=True),

        sa.Column("name", sa.String(256), nullable=False),
        sa.Column("role", sa.String(32), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("disabled", sa.Boolean(), nullable=False),
        sa.Column("session_version", sa.Integer(), nullable=False),
        sa.Column("primary_doctor_id", sa.String(64)),
        sa.Column("patient_id", sa.String(64)),
        sa.Column("created_by", sa.String(64)),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
        sa.Column("meta_json", sa.Text(), nullable=False),
        sa.CheckConstraint(
            "role IN ('admin', 'doctor', 'patient', 'caregiver')",
            name="ck_users_role",
        ),
    )
    op.create_table(
        "patients",
        sa.Column("patient_id", sa.String(64), primary_key=True),
        sa.Column("current_status", sa.String(64)),
        sa.Column("last_updated", sa.String(64)),
        sa.Column("updated_at", sa.String(64), nullable=False),
        sa.Column("profile_json", sa.Text(), nullable=False),
    )
    op.create_table(
        "audit_logs",
        sa.Column("sequence", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("id", sa.String(64), nullable=False, unique=True),
        sa.Column("at", sa.String(64), nullable=False),
        sa.Column("actor", sa.String(64)),
        sa.Column("actor_role", sa.String(32)),
        sa.Column("action", sa.String(128), nullable=False),
        sa.Column("target", sa.String(128)),
        sa.Column("detail_json", sa.Text(), nullable=False),
    )
    op.create_index("ix_audit_logs_at", "audit_logs", ["at"])
    op.create_index("ix_audit_logs_actor", "audit_logs", ["actor"])
    op.create_table(
        "assignments",
        sa.Column("patient_id", sa.String(64), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("doctor_id", sa.String(64), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("assigned_by", sa.String(64)),
        sa.Column("assigned_at", sa.String(64), nullable=False),
    )
    op.create_index("ix_assignments_doctor_id", "assignments", ["doctor_id"])
    _create_monitoring_table("readings")
    _create_monitoring_table("assessments", label=True)
    _create_monitoring_table("alerts", alert=True)
    op.create_table(
        "store_imports",
        sa.Column("source_path", sa.Text(), primary_key=True),
        sa.Column("checksum", sa.String(64), nullable=False),
        sa.Column("imported_at", sa.String(64), nullable=False),
        sa.Column("backup_path", sa.Text(), nullable=False),
    )


def _create_monitoring_table(name: str, *, label: bool = False, alert: bool = False) -> None:
    columns = [
        sa.Column("sequence", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("id", sa.String(64), nullable=False, unique=True),
        sa.Column("patient_id", sa.String(64), sa.ForeignKey("patients.patient_id", ondelete="CASCADE"), nullable=False),
        sa.Column("captured_at", sa.String(64)),
    ]
    if label:
        columns.append(sa.Column("label", sa.String(64)))
    if alert:
        columns.extend(
            [
                sa.Column("severity", sa.String(32)),
                sa.Column("acknowledged", sa.Boolean(), nullable=False),
            ]
        )
    columns.append(sa.Column("payload_json", sa.Text(), nullable=False))
    op.create_table(name, *columns)
    op.create_index(f"ix_{name}_patient_sequence", name, ["patient_id", "sequence"])
    if name != "alerts":
        op.create_index(f"ix_{name}_patient_captured", name, ["patient_id", "captured_at"])
    else:
        op.create_index("ix_alerts_patient_ack", name, ["patient_id", "acknowledged"])


def downgrade() -> None:
    op.drop_table("store_imports")
    for table in ("alerts", "assessments", "readings"):
        op.drop_table(table)
    op.drop_table("assignments")
    op.drop_table("audit_logs")
    op.drop_table("patients")
    op.drop_table("users")