-- =============================================================================
-- Idempotent Upgrade Script for Existing Supabase PostgreSQL Instances
-- Upgrades an existing 20260904_06 schema -> 20261121_10 without dropping data
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Revision 20261028_07_integrity
-- ---------------------------------------------------------------------------
ALTER TABLE caregiver_links ADD COLUMN IF NOT EXISTS disabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE alert_outbox ADD COLUMN IF NOT EXISTS lease_token VARCHAR(64);
ALTER TABLE alert_outbox ADD COLUMN IF NOT EXISTS lease_expires_at VARCHAR(64);

CREATE TABLE IF NOT EXISTS prescriptions (
    id VARCHAR(64) PRIMARY KEY,
    patient_id VARCHAR(64) NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    doctor_id VARCHAR(64),
    name VARCHAR(200) NOT NULL,
    dose VARCHAR(100) NOT NULL,
    schedule VARCHAR(200) NOT NULL,
    notes TEXT,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_prescriptions_patient ON prescriptions (patient_id);

CREATE TABLE IF NOT EXISTS device_streams (
    patient_id VARCHAR(64) NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    device_id VARCHAR(128) NOT NULL,
    state_json TEXT NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (patient_id, device_id)
);

CREATE TABLE IF NOT EXISTS sso_codes (
    code_hash VARCHAR(64) PRIMARY KEY,
    user_id VARCHAR(64) NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    session_version INTEGER NOT NULL,
    expires_at VARCHAR(64) NOT NULL
);

UPDATE caregiver_links SET disabled = TRUE
WHERE patient_id NOT IN (SELECT id FROM users WHERE role = 'patient')
   OR caregiver_id NOT IN (SELECT id FROM users WHERE role = 'caregiver');

-- ---------------------------------------------------------------------------
-- Revision 20261113_08_care_records
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS care_records (
    patient_id VARCHAR(64) NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    kind VARCHAR(32) NOT NULL,
    record_id VARCHAR(64) NOT NULL,
    payload_json TEXT NOT NULL,
    actor_id VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    deleted BOOLEAN NOT NULL,
    PRIMARY KEY (patient_id, kind, record_id)
);

-- ---------------------------------------------------------------------------
-- Revision 20261114_09_account_sessions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS account_sessions (
    id VARCHAR(64) PRIMARY KEY,
    user_id VARCHAR(64) NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    session_version INTEGER NOT NULL,
    device_name VARCHAR(120) NOT NULL,
    platform VARCHAR(32) NOT NULL,
    created_at VARCHAR(64) NOT NULL,
    last_seen_at VARCHAR(64) NOT NULL,
    expires_at VARCHAR(64) NOT NULL,
    revoked_at VARCHAR(64)
);
CREATE INDEX IF NOT EXISTS ix_account_sessions_user_id ON account_sessions (user_id);

ALTER TABLE push_tokens ADD COLUMN IF NOT EXISTS session_id VARCHAR(64);
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_push_tokens_session'
    ) THEN
        ALTER TABLE push_tokens
            ADD CONSTRAINT fk_push_tokens_session
            FOREIGN KEY (session_id) REFERENCES account_sessions (id) ON DELETE CASCADE;
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS ix_push_tokens_session_id ON push_tokens (session_id);

-- ---------------------------------------------------------------------------
-- Revision 20261121_10_phase1_master_schema
-- ---------------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS email VARCHAR(255);
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_email_active
    ON users (lower(email))
    WHERE email IS NOT NULL AND disabled = FALSE;

ALTER TABLE account_sessions ADD COLUMN IF NOT EXISTS device_id VARCHAR(128);
ALTER TABLE account_sessions ADD COLUMN IF NOT EXISTS is_hardware_bound BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS ix_account_sessions_device_id ON account_sessions (user_id, device_id);

CREATE TABLE IF NOT EXISTS doctor_profiles (
    id VARCHAR(64) PRIMARY KEY,
    user_id VARCHAR(64) NOT NULL UNIQUE REFERENCES users (id) ON DELETE CASCADE,
    license_number VARCHAR(64) NOT NULL UNIQUE,
    specialization VARCHAR(120) NOT NULL,
    hospital_affiliation VARCHAR(180) NOT NULL,
    national_id VARCHAR(32) NOT NULL UNIQUE,
    phone VARCHAR(32) NOT NULL,
    moh_verified BOOLEAN NOT NULL DEFAULT FALSE,
    moh_status VARCHAR(32),
    moh_checked_at VARCHAR(64),
    moh_override_by VARCHAR(64),
    created_at VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL
);

CREATE TABLE IF NOT EXISTS moh_registry (
    license_number VARCHAR(64) PRIMARY KEY,
    national_id VARCHAR(32) NOT NULL,
    full_name_ar VARCHAR(180) NOT NULL,
    full_name_en VARCHAR(180) NOT NULL,
    specialization VARCHAR(120) NOT NULL,
    hospital_affiliation VARCHAR(180),
    status VARCHAR(32) NOT NULL,
    expiration_date VARCHAR(32) NOT NULL,
    CONSTRAINT ck_moh_registry_status CHECK (status IN ('active', 'suspended', 'expired'))
);
CREATE INDEX IF NOT EXISTS ix_moh_registry_national_id ON moh_registry (national_id);

CREATE TABLE IF NOT EXISTS idempotency_keys (
    key VARCHAR(128) PRIMARY KEY,
    actor_id VARCHAR(64) NOT NULL,
    endpoint VARCHAR(128) NOT NULL,
    response_status INTEGER NOT NULL,
    response_json TEXT NOT NULL,
    created_at VARCHAR(64) NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_idempotency_keys_created_at ON idempotency_keys (created_at);

ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS period_context VARCHAR(32);
ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS meal_context VARCHAR(32);
ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS meal_type VARCHAR(32);
ALTER TABLE prescriptions ADD COLUMN IF NOT EXISTS times_json TEXT;

CREATE TABLE IF NOT EXISTS medication_logs (
    id VARCHAR(64) PRIMARY KEY,
    prescription_id VARCHAR(64) NOT NULL REFERENCES prescriptions (id) ON DELETE CASCADE,
    patient_id VARCHAR(64) NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    scheduled_time VARCHAR(64) NOT NULL,
    taken_at VARCHAR(64),
    status VARCHAR(16) NOT NULL,
    recorded_by VARCHAR(64) NOT NULL,
    created_at VARCHAR(64) NOT NULL,
    CONSTRAINT ck_medication_logs_status CHECK (status IN ('taken', 'missed', 'skipped'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_medication_logs_rx_slot
    ON medication_logs (prescription_id, scheduled_time);
CREATE INDEX IF NOT EXISTS ix_medication_logs_patient
    ON medication_logs (patient_id, scheduled_time);

ALTER TABLE outcomes ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 1;
CREATE UNIQUE INDEX IF NOT EXISTS uq_outcomes_patient_alert
    ON outcomes (patient_id, alert_id)
    WHERE alert_id IS NOT NULL;

ALTER TABLE messages ADD COLUMN IF NOT EXISTS peer_user_id VARCHAR(64);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS delivered_at VARCHAR(64);
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_messages_peer_user'
    ) THEN
        ALTER TABLE messages
            ADD CONSTRAINT fk_messages_peer_user
            FOREIGN KEY (peer_user_id) REFERENCES users (id) ON DELETE SET NULL;
    END IF;
END $$;
ALTER TABLE messages DROP CONSTRAINT IF EXISTS ck_messages_channel_type;
ALTER TABLE messages ADD CONSTRAINT ck_messages_channel_type CHECK (
    channel_type IN (
        'doctor_patient',
        'family_patient',
        'patient_caregiver',
        'doctor_caregiver',
        'care_team_triage'
    )
);
CREATE INDEX IF NOT EXISTS ix_messages_peer_user_id
    ON messages (patient_id, channel_type, peer_user_id);

-- Fix view joins (u.id instead of u.patient_id)
CREATE OR REPLACE VIEW v_active_alerts AS
SELECT
    a.id AS alert_id,
    a.patient_id,
    u.name AS patient_name,
    a.severity,
    a.captured_at,
    a.acknowledged,
    a.payload_json
FROM alerts a
LEFT JOIN users u ON a.patient_id = u.id
WHERE a.acknowledged = FALSE
ORDER BY a.sequence DESC;

CREATE OR REPLACE VIEW v_patient_summary AS
SELECT
    p.patient_id,
    u.name AS patient_name,
    p.current_status,
    p.last_updated,
    COUNT(DISTINCT a.id) FILTER (WHERE a.acknowledged = FALSE) AS active_alerts_count,
    COUNT(DISTINCT r.id) AS total_readings_count
FROM patients p
LEFT JOIN users u ON p.patient_id = u.id
LEFT JOIN alerts a ON p.patient_id = a.patient_id
LEFT JOIN readings r ON p.patient_id = r.patient_id
GROUP BY p.patient_id, u.name, p.current_status, p.last_updated;

-- Enable Row Level Security across all tables
DO $$
DECLARE
    tbl TEXT;
BEGIN
    FOREACH tbl IN ARRAY ARRAY[
        'alembic_version',
        'users',
        'doctor_profiles',
        'moh_registry',
        'idempotency_keys',
        'account_sessions',
        'patients',
        'assignments',
        'caregiver_links',
        'devices',
        'audit_logs',
        'care_records',
        'readings',
        'assessments',
        'alerts',
        'alert_acknowledgments',
        'outcomes',
        'alert_outbox',
        'prescriptions',
        'medication_logs',
        'device_streams',
        'sso_codes',
        'push_tokens',
        'messages',
        'store_imports'
    ]
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
        IF NOT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = 'public' AND tablename = tbl AND policyname = 'backend_service_only'
        ) THEN
            EXECUTE format(
                'CREATE POLICY backend_service_only ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)',
                tbl
            );
        END IF;
    END LOOP;
END $$;

-- Update Alembic revision stamp cleanly
DELETE FROM alembic_version;
INSERT INTO alembic_version (version_num) VALUES ('20261121_10');

COMMIT;
