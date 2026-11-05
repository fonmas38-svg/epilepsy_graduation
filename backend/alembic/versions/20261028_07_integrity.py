"""Scoped caregiver access, durable device streams, worker leases and prescriptions.

Revision ID: 20261028_07
Revises: 20260904_06
"""
import json

from alembic import op
import sqlalchemy as sa

revision = "20261028_07"
down_revision = "20260904_06"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("caregiver_links", sa.Column("disabled", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column("alert_outbox", sa.Column("lease_token", sa.String(64)))
    op.add_column("alert_outbox", sa.Column("lease_expires_at", sa.String(64)))
    op.create_table(
        "prescriptions",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column("patient_id", sa.String(64), sa.ForeignKey("patients.patient_id", ondelete="CASCADE"), nullable=False),
        sa.Column("doctor_id", sa.String(64)),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("dose", sa.String(100), nullable=False),
        sa.Column("schedule", sa.String(200), nullable=False),
        sa.Column("notes", sa.Text()),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
    )
    op.create_index("ix_prescriptions_patient", "prescriptions", ["patient_id"])
    op.create_table(
        "device_streams",
        sa.Column("patient_id", sa.String(64), sa.ForeignKey("patients.patient_id", ondelete="CASCADE"), primary_key=True),
        sa.Column("device_id", sa.String(128), primary_key=True),
        sa.Column("state_json", sa.Text(), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
    )
    op.create_table(
        "sso_codes",
        sa.Column("code_hash", sa.String(64), primary_key=True),
        sa.Column("user_id", sa.String(64), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("session_version", sa.Integer(), nullable=False),
        sa.Column("expires_at", sa.String(64), nullable=False),
    )
    # Quarantine invalid old links. Never change the target account's global
    # disabled flag: the old API may have linked an administrator as a caregiver.
    op.execute(sa.text("""
        UPDATE caregiver_links SET disabled = true
        WHERE patient_id NOT IN (SELECT id FROM users WHERE role = 'patient')
           OR caregiver_id NOT IN (SELECT id FROM users WHERE role = 'caregiver')
    """))
    # Copy valid legacy prescriptions; keep the original JSON as a migration
    # archive so malformed legacy entries are not silently destroyed.
    conn = op.get_bind()
    rx_table = sa.table("prescriptions", *[
        sa.column(name) for name in (
            "id", "patient_id", "doctor_id", "name", "dose", "schedule",
            "notes", "active", "created_at", "updated_at",
        )
    ])
    seen = set()
    for row in conn.execute(sa.text("SELECT patient_id, profile_json, updated_at FROM patients")):
        try:
            legacy = json.loads(row.profile_json).get("prescriptions", [])
        except (ValueError, TypeError, AttributeError):
            continue
        if not isinstance(legacy, list):
            continue
        for rx in legacy:
            if not isinstance(rx, dict) or not all(rx.get(k) for k in ("id", "name", "dose", "schedule")):
                continue
            if rx["id"] in seen:
                continue
            seen.add(rx["id"])
            conn.execute(rx_table.insert().values(
                id=rx["id"], patient_id=row.patient_id, doctor_id=rx.get("doctor_id"),
                name=rx["name"], dose=rx["dose"], schedule=rx["schedule"], notes=rx.get("notes"),
                active=bool(rx.get("active", True)), created_at=rx.get("created_at") or row.updated_at,
                updated_at=rx.get("updated_at") or row.updated_at,
            ))


def downgrade() -> None:
    # Preserve prescriptions added since upgrade in the old JSON representation.
    conn = op.get_bind()
    for row in conn.execute(sa.text("SELECT patient_id, profile_json FROM patients")):
        try:
            profile = json.loads(row.profile_json)
        except (ValueError, TypeError):
            profile = {}
        rx = [dict(r._mapping) for r in conn.execute(
            sa.text("SELECT * FROM prescriptions WHERE patient_id = :pid"), {"pid": row.patient_id},
        )]
        if rx:
            for item in rx:
                item["active"] = bool(item["active"])
            profile["prescriptions"] = rx
            conn.execute(sa.text("UPDATE patients SET profile_json = :profile WHERE patient_id = :pid"),
                         {"profile": json.dumps(profile, ensure_ascii=False), "pid": row.patient_id})
    op.drop_table("sso_codes")
    op.drop_table("device_streams")
    op.drop_index("ix_prescriptions_patient", table_name="prescriptions")
    op.drop_table("prescriptions")
    op.drop_column("alert_outbox", "lease_expires_at")
    op.drop_column("alert_outbox", "lease_token")
    op.drop_column("caregiver_links", "disabled")
