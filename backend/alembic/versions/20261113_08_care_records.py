"""Patient-scoped care resources with retry-safe identifiers and tombstones."""
from alembic import op
import sqlalchemy as sa

revision = '20261113_08'
down_revision = '20261028_07'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('care_records',
        sa.Column('patient_id', sa.String(64), sa.ForeignKey('users.id', ondelete='CASCADE'), primary_key=True),
        sa.Column('kind', sa.String(32), primary_key=True),
        sa.Column('record_id', sa.String(64), primary_key=True),
        sa.Column('payload_json', sa.Text(), nullable=False),
        sa.Column('actor_id', sa.String(64), nullable=False),
        sa.Column('updated_at', sa.String(64), nullable=False),
        sa.Column('deleted', sa.Boolean(), nullable=False),
    )


def downgrade():
    op.drop_table('care_records')
