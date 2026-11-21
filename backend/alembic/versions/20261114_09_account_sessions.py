"""Independently revocable human sessions and session-bound push registration.

Existing human JWTs without a session ID must sign in again after deployment.
Existing push rows deliberately remain unbound and are ineligible for delivery
until an authenticated client re-registers them under its new session.
"""
from alembic import op
import sqlalchemy as sa

revision = '20261114_09'
down_revision = '20261113_08'
branch_labels = None
depends_on = None


def upgrade():
    op.create_table('account_sessions',
        sa.Column('id', sa.String(64), primary_key=True),
        sa.Column('user_id', sa.String(64), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False),
        sa.Column('session_version', sa.Integer(), nullable=False),
        sa.Column('device_name', sa.String(120), nullable=False),
        sa.Column('platform', sa.String(32), nullable=False),
        sa.Column('created_at', sa.String(64), nullable=False),
        sa.Column('last_seen_at', sa.String(64), nullable=False),
        sa.Column('expires_at', sa.String(64), nullable=False),
        sa.Column('revoked_at', sa.String(64)),
    )
    op.create_index('ix_account_sessions_user_id', 'account_sessions', ['user_id'])
    with op.batch_alter_table('push_tokens') as batch:
        batch.add_column(sa.Column('session_id', sa.String(64)))
        batch.create_foreign_key('fk_push_tokens_session', 'account_sessions', ['session_id'], ['id'], ondelete='CASCADE')
        batch.create_index('ix_push_tokens_session_id', ['session_id'])


def downgrade():
    with op.batch_alter_table('push_tokens') as batch:
        batch.drop_index('ix_push_tokens_session_id')
        batch.drop_constraint('fk_push_tokens_session', type_='foreignkey')
        batch.drop_column('session_id')
    op.drop_index('ix_account_sessions_user_id', table_name='account_sessions')
    op.drop_table('account_sessions')
