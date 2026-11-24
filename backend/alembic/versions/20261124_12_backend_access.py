"""Align backend-only RLS, view privileges, and partial Realtime publications.

Revision ID: 20261124_12
Revises: 20261124_11
"""
from alembic import op

revision = "20261124_12"
down_revision = "20261124_11"
branch_labels = None
depends_on = None

ACCESS_SQL = r"""-- Backend-only clinical access. Browser/phone traffic must go through FastAPI RBAC.
DO $$
DECLARE
    tbl text;
    role_name text;
BEGIN
    FOREACH tbl IN ARRAY ARRAY['alembic_version', 'users', 'doctor_profiles', 'moh_registry', 'idempotency_keys', 'account_sessions', 'patients', 'assignments', 'caregiver_links', 'devices', 'audit_logs', 'care_records', 'readings', 'assessments', 'alerts', 'alert_acknowledgments', 'outcomes', 'alert_outbox', 'prescriptions', 'medication_logs', 'device_streams', 'sso_codes', 'push_tokens', 'messages', 'store_imports']
    LOOP
        IF to_regclass(format('public.%I', tbl)) IS NULL THEN CONTINUE; END IF;
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', tbl);
        FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
                EXECUTE format('REVOKE ALL ON public.%I FROM %I', tbl, role_name);
            END IF;
        END LOOP;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') AND NOT EXISTS (
            SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = tbl
                AND policyname = 'backend_service_only'
        ) THEN
            EXECUTE format('CREATE POLICY backend_service_only ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)', tbl);
        END IF;
    END LOOP;
    FOREACH tbl IN ARRAY ARRAY['v_active_alerts', 'v_patient_summary', 'v_unread_messages'] LOOP
        IF to_regclass(format('public.%I', tbl)) IS NULL THEN CONTINUE; END IF;
        IF current_setting('server_version_num')::integer >= 150000 THEN
            EXECUTE format('ALTER VIEW public.%I SET (security_invoker = true)', tbl);
        END IF;
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', tbl);
        FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated'] LOOP
            IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
                EXECUTE format('REVOKE ALL ON public.%I FROM %I', tbl, role_name);
            END IF;
        END LOOP;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        FOREACH tbl IN ARRAY ARRAY['alerts', 'messages', 'medication_logs', 'prescriptions'] LOOP
            IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = tbl) THEN
                EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', tbl);
            END IF;
        END LOOP;
    END IF;
END $$;
"""


def upgrade():
    if op.get_bind().dialect.name == "postgresql":
        op.execute(ACCESS_SQL)


def downgrade():
    # Keep access controls on rollback: downgrading must not re-expose patient data.
    pass
