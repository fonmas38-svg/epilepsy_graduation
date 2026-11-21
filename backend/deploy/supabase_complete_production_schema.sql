-- =============================================================================
-- Smart Epilepsy Monitoring & Seizure Prediction System
-- Master PostgreSQL Production Schema for Supabase (Aligned with Alembic 20261121_10)
-- =============================================================================

-- 1. Alembic Version Tracking
CREATE TABLE IF NOT EXISTS alembic_version (
    version_num VARCHAR(32) NOT NULL,
    CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
);

-- 2. Users & RBAC Identity Table
CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(64) NOT NULL,
    username VARCHAR(128) NOT NULL,
    email VARCHAR(255),
    name VARCHAR(256) NOT NULL,
    role VARCHAR(32) NOT NULL,
    password_hash TEXT NOT NULL,
    disabled BOOLEAN NOT NULL DEFAULT FALSE,
    session_version INTEGER NOT NULL DEFAULT 0,
    primary_doctor_id VARCHAR(64),
    patient_id VARCHAR(64),
    created_by VARCHAR(64),
    created_at VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    meta_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (id),
    CONSTRAINT ck_users_role CHECK (role IN ('admin', 'doctor', 'patient', 'caregiver')),
    UNIQUE (username)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_users_username_lower ON users (lower(username));
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_email_active
    ON users (lower(email))
    WHERE email IS NOT NULL AND disabled = FALSE;

-- 3. Doctor Clinical Profiles (Alembic 20261121_10)
CREATE TABLE IF NOT EXISTS doctor_profiles (
    id VARCHAR(64) NOT NULL,
    user_id VARCHAR(64) NOT NULL,
    license_number VARCHAR(64) NOT NULL,
    specialization VARCHAR(120) NOT NULL,
    hospital_affiliation VARCHAR(180) NOT NULL,
    national_id VARCHAR(32) NOT NULL,
    phone VARCHAR(32) NOT NULL,
    moh_verified BOOLEAN NOT NULL DEFAULT FALSE,
    moh_status VARCHAR(32),
    moh_checked_at VARCHAR(64),
    moh_override_by VARCHAR(64),
    created_at VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (id),
    UNIQUE (user_id),
    UNIQUE (license_number),
    UNIQUE (national_id),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

-- 4. Simulated Ministry of Health Registry (Alembic 20261121_10)
CREATE TABLE IF NOT EXISTS moh_registry (
    license_number VARCHAR(64) NOT NULL,
    national_id VARCHAR(32) NOT NULL,
    full_name_ar VARCHAR(180) NOT NULL,
    full_name_en VARCHAR(180) NOT NULL,
    specialization VARCHAR(120) NOT NULL,
    hospital_affiliation VARCHAR(180),
    status VARCHAR(32) NOT NULL,
    expiration_date VARCHAR(32) NOT NULL,
    PRIMARY KEY (license_number),
    CONSTRAINT ck_moh_registry_status CHECK (status IN ('active', 'suspended', 'expired'))
);

CREATE INDEX IF NOT EXISTS ix_moh_registry_national_id ON moh_registry (national_id);

-- 5. Idempotency Keys (Alembic 20261121_10)
CREATE TABLE IF NOT EXISTS idempotency_keys (
    key VARCHAR(128) NOT NULL,
    actor_id VARCHAR(64) NOT NULL,
    endpoint VARCHAR(128) NOT NULL,
    response_status INTEGER NOT NULL,
    response_json TEXT NOT NULL,
    created_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (key)
);

CREATE INDEX IF NOT EXISTS ix_idempotency_keys_created_at ON idempotency_keys (created_at);

-- 6. Revocable Login Sessions & Device Binding (Alembic 20261114_09 + 20261121_10)
CREATE TABLE IF NOT EXISTS account_sessions (
    id VARCHAR(64) NOT NULL,
    user_id VARCHAR(64) NOT NULL,
    session_version INTEGER NOT NULL,
    device_name VARCHAR(120) NOT NULL,
    platform VARCHAR(32) NOT NULL,
    device_id VARCHAR(128),
    is_hardware_bound BOOLEAN NOT NULL DEFAULT FALSE,
    created_at VARCHAR(64) NOT NULL,
    last_seen_at VARCHAR(64) NOT NULL,
    expires_at VARCHAR(64) NOT NULL,
    revoked_at VARCHAR(64),
    PRIMARY KEY (id),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_account_sessions_user_id ON account_sessions (user_id);
CREATE INDEX IF NOT EXISTS ix_account_sessions_device_id ON account_sessions (user_id, device_id);

-- 7. Patient Clinical Profiles
CREATE TABLE IF NOT EXISTS patients (
    patient_id VARCHAR(64) NOT NULL,
    current_status VARCHAR(64),
    last_updated VARCHAR(64),
    updated_at VARCHAR(64) NOT NULL,
    profile_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (patient_id)
);

-- 8. Doctor-Patient Clinical Assignments
CREATE TABLE IF NOT EXISTS assignments (
    patient_id VARCHAR(64) NOT NULL,
    doctor_id VARCHAR(64) NOT NULL,
    assigned_by VARCHAR(64),
    assigned_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (patient_id, doctor_id),
    FOREIGN KEY (patient_id) REFERENCES users (id) ON DELETE CASCADE,
    FOREIGN KEY (doctor_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_assignments_doctor_id ON assignments (doctor_id);

-- 9. Family & Caregiver Consents / Links (Alembic 20261028_07)
CREATE TABLE IF NOT EXISTS caregiver_links (
    patient_id VARCHAR(64) NOT NULL,
    caregiver_id VARCHAR(64) NOT NULL,
    linked_by VARCHAR(64),
    linked_at VARCHAR(64) NOT NULL,
    disabled BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (patient_id, caregiver_id),
    FOREIGN KEY (patient_id) REFERENCES users (id) ON DELETE CASCADE,
    FOREIGN KEY (caregiver_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_caregiver_links_caregiver_id ON caregiver_links (caregiver_id);

-- 10. Enrolled Headset Devices
CREATE TABLE IF NOT EXISTS devices (
    device_id VARCHAR(128) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    name VARCHAR(256) NOT NULL,
    secret_hash TEXT NOT NULL,
    credential_version INTEGER NOT NULL DEFAULT 0,
    disabled BOOLEAN NOT NULL DEFAULT FALSE,
    created_by VARCHAR(64),
    created_at VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    last_enrolled_at VARCHAR(64),
    PRIMARY KEY (device_id),
    FOREIGN KEY (patient_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_devices_patient_id ON devices (patient_id);

-- 11. Security & Administrative Audit Logs
CREATE TABLE IF NOT EXISTS audit_logs (
    sequence SERIAL NOT NULL,
    id VARCHAR(64) NOT NULL,
    at VARCHAR(64) NOT NULL,
    actor VARCHAR(64),
    actor_role VARCHAR(32),
    action VARCHAR(128) NOT NULL,
    target VARCHAR(128),
    detail_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (sequence),
    UNIQUE (id)
);

CREATE INDEX IF NOT EXISTS ix_audit_logs_at ON audit_logs (at);
CREATE INDEX IF NOT EXISTS ix_audit_logs_actor ON audit_logs (actor);

-- 12. Patient-Scoped Care Records (Alembic 20261113_08)
CREATE TABLE IF NOT EXISTS care_records (
    patient_id VARCHAR(64) NOT NULL,
    kind VARCHAR(32) NOT NULL,
    record_id VARCHAR(64) NOT NULL,
    payload_json TEXT NOT NULL,
    actor_id VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    deleted BOOLEAN NOT NULL,
    PRIMARY KEY (patient_id, kind, record_id),
    FOREIGN KEY (patient_id) REFERENCES users (id) ON DELETE CASCADE
);

-- 13. Raw Physiological Vital Readings (EEG, ECG, Motion, HR)
CREATE TABLE IF NOT EXISTS readings (
    sequence SERIAL NOT NULL,
    id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    captured_at VARCHAR(64),
    payload_json TEXT NOT NULL,
    PRIMARY KEY (sequence),
    UNIQUE (id),
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_readings_patient_sequence ON readings (patient_id, sequence);
CREATE INDEX IF NOT EXISTS ix_readings_patient_captured ON readings (patient_id, captured_at);

-- 14. AI Risk Assessments & Forecasts
CREATE TABLE IF NOT EXISTS assessments (
    sequence SERIAL NOT NULL,
    id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    captured_at VARCHAR(64),
    label VARCHAR(64),
    payload_json TEXT NOT NULL,
    PRIMARY KEY (sequence),
    UNIQUE (id),
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_assessments_patient_sequence ON assessments (patient_id, sequence);
CREATE INDEX IF NOT EXISTS ix_assessments_patient_captured ON assessments (patient_id, captured_at);

-- 15. Emergency Alerts
CREATE TABLE IF NOT EXISTS alerts (
    sequence SERIAL NOT NULL,
    id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    captured_at VARCHAR(64),
    severity VARCHAR(32),
    acknowledged BOOLEAN NOT NULL DEFAULT FALSE,
    payload_json TEXT NOT NULL,
    PRIMARY KEY (sequence),
    UNIQUE (id),
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_alerts_patient_sequence ON alerts (patient_id, sequence);
CREATE INDEX IF NOT EXISTS ix_alerts_patient_ack ON alerts (patient_id, acknowledged);

-- 16. Multi-party Alert Acknowledgments
CREATE TABLE IF NOT EXISTS alert_acknowledgments (
    id VARCHAR(64) NOT NULL,
    alert_id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    actor_id VARCHAR(64) NOT NULL,
    actor_role VARCHAR(32),
    acknowledged_at VARCHAR(64) NOT NULL,
    note TEXT,
    PRIMARY KEY (id),
    FOREIGN KEY (alert_id) REFERENCES alerts (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_alert_acknowledgments_alert ON alert_acknowledgments (alert_id);
CREATE INDEX IF NOT EXISTS ix_alert_acknowledgments_patient ON alert_acknowledgments (patient_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_alert_acknowledgments_actor ON alert_acknowledgments (alert_id, actor_id);

-- 17. Clinical Seizure Adjudication Outcomes (Alembic 20261121_10)
CREATE TABLE IF NOT EXISTS outcomes (
    sequence SERIAL NOT NULL,
    id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    assessment_id VARCHAR(64),
    alert_id VARCHAR(64),
    outcome VARCHAR(32) NOT NULL,
    occurred_at VARCHAR(64) NOT NULL,
    recorded_by VARCHAR(64) NOT NULL,
    recorded_at VARCHAR(64) NOT NULL,
    notes TEXT,
    payload_json TEXT NOT NULL DEFAULT '{}',
    version INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (sequence),
    CONSTRAINT ck_outcomes_outcome CHECK (outcome IN ('seizure', 'no_seizure', 'false_alarm', 'unknown')),
    UNIQUE (id),
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE,
    FOREIGN KEY (assessment_id) REFERENCES assessments (id) ON DELETE SET NULL,
    FOREIGN KEY (alert_id) REFERENCES alerts (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_outcomes_patient_sequence ON outcomes (patient_id, sequence);
CREATE INDEX IF NOT EXISTS ix_outcomes_assessment_id ON outcomes (assessment_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_outcomes_patient_alert
    ON outcomes (patient_id, alert_id)
    WHERE alert_id IS NOT NULL;

-- 18. Transactional Outbox Worker (Alembic 20261028_07)
CREATE TABLE IF NOT EXISTS alert_outbox (
    id VARCHAR(64) NOT NULL,
    alert_id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    payload_json TEXT NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at VARCHAR(64) NOT NULL,
    last_error TEXT,
    created_at VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    lease_token VARCHAR(64),
    lease_expires_at VARCHAR(64),
    PRIMARY KEY (id),
    CONSTRAINT ck_alert_outbox_status CHECK (status IN ('pending', 'sent', 'failed', 'dead')),
    UNIQUE (alert_id)
);

CREATE INDEX IF NOT EXISTS ix_alert_outbox_due ON alert_outbox (status, next_attempt_at);

-- 19. Prescriptions & Medication Logs (Alembic 20261028_07 + 20261121_10)
CREATE TABLE IF NOT EXISTS prescriptions (
    id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    doctor_id VARCHAR(64),
    name VARCHAR(200) NOT NULL,
    dose VARCHAR(100) NOT NULL,
    schedule VARCHAR(200) NOT NULL,
    notes TEXT,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    period_context VARCHAR(32),
    meal_context VARCHAR(32),
    meal_type VARCHAR(32),
    times_json TEXT,
    created_at VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (id),
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_prescriptions_patient ON prescriptions (patient_id);

CREATE TABLE IF NOT EXISTS medication_logs (
    id VARCHAR(64) NOT NULL,
    prescription_id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    scheduled_time VARCHAR(64) NOT NULL,
    taken_at VARCHAR(64),
    status VARCHAR(16) NOT NULL,
    recorded_by VARCHAR(64) NOT NULL,
    created_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT ck_medication_logs_status CHECK (status IN ('taken', 'missed', 'skipped')),
    FOREIGN KEY (prescription_id) REFERENCES prescriptions (id) ON DELETE CASCADE,
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_medication_logs_rx_slot
    ON medication_logs (prescription_id, scheduled_time);
CREATE INDEX IF NOT EXISTS ix_medication_logs_patient
    ON medication_logs (patient_id, scheduled_time);

-- 20. Device Signal Streams & Single-Use SSO Codes (Alembic 20261028_07)
CREATE TABLE IF NOT EXISTS device_streams (
    patient_id VARCHAR(64) NOT NULL,
    device_id VARCHAR(128) NOT NULL,
    state_json TEXT NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (patient_id, device_id),
    FOREIGN KEY (patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS sso_codes (
    code_hash VARCHAR(64) NOT NULL,
    user_id VARCHAR(64) NOT NULL,
    session_version INTEGER NOT NULL,
    expires_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (code_hash),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

-- 21. Private Mobile Push Notification Tokens (Alembic 20261114_09)
CREATE TABLE IF NOT EXISTS push_tokens (
    id VARCHAR(64) NOT NULL,
    user_id VARCHAR(64) NOT NULL,
    token TEXT NOT NULL,
    platform VARCHAR(32) NOT NULL DEFAULT 'unknown',
    session_id VARCHAR(64),
    created_at VARCHAR(64) NOT NULL,
    updated_at VARCHAR(64) NOT NULL,
    PRIMARY KEY (id),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
    FOREIGN KEY (session_id) REFERENCES account_sessions (id) ON DELETE CASCADE,
    UNIQUE (token)
);

CREATE INDEX IF NOT EXISTS ix_push_tokens_user_id ON push_tokens (user_id);
CREATE INDEX IF NOT EXISTS ix_push_tokens_session_id ON push_tokens (session_id);

-- 22. Clinical & Care-Circle Messaging (Alembic 20260904_06 + 20261121_10)
CREATE TABLE IF NOT EXISTS messages (
    id VARCHAR(64) NOT NULL,
    patient_id VARCHAR(64) NOT NULL,
    sender_id VARCHAR(64) NOT NULL,
    sender_name VARCHAR(256) NOT NULL,
    sender_role VARCHAR(32) NOT NULL,
    channel_type VARCHAR(32) NOT NULL,
    peer_user_id VARCHAR(64),
    content TEXT NOT NULL,
    created_at VARCHAR(64) NOT NULL,
    delivered_at VARCHAR(64),
    read_at VARCHAR(64),
    PRIMARY KEY (id),
    CONSTRAINT ck_messages_channel_type CHECK (
        channel_type IN (
            'doctor_patient',
            'family_patient',
            'patient_caregiver',
            'doctor_caregiver',
            'care_team_triage'
        )
    ),
    FOREIGN KEY (patient_id) REFERENCES users (id) ON DELETE CASCADE,
    FOREIGN KEY (sender_id) REFERENCES users (id) ON DELETE CASCADE,
    FOREIGN KEY (peer_user_id) REFERENCES users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_messages_patient_channel ON messages (patient_id, channel_type);
CREATE INDEX IF NOT EXISTS ix_messages_created_at ON messages (created_at);
CREATE INDEX IF NOT EXISTS ix_messages_peer_user_id
    ON messages (patient_id, channel_type, peer_user_id);

-- 23. Store Imports Tracking
CREATE TABLE IF NOT EXISTS store_imports (
    source_path TEXT NOT NULL,
    checksum VARCHAR(64) NOT NULL,
    imported_at VARCHAR(64) NOT NULL,
    backup_path TEXT NOT NULL,
    PRIMARY KEY (source_path)
);

-- =============================================================================
-- 24. Analytical Database Views (for Dashboards & Supabase Studio)
-- =============================================================================

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

CREATE OR REPLACE VIEW v_unread_messages AS
SELECT
    m.id AS message_id,
    m.patient_id,
    m.sender_name,
    m.sender_role,
    m.channel_type,
    m.content,
    m.created_at
FROM messages m
WHERE m.read_at IS NULL
ORDER BY m.created_at DESC;

-- =============================================================================
-- 25. Row Level Security (Deny direct PostgREST anon/public access; backend uses service role)
-- =============================================================================

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

-- =============================================================================
-- 26. Administrative Bootstrapping Note & Alembic Revision Stamp
-- =============================================================================
-- NOTE: Never embed static/default admin password hashes in production DDL.
-- On first FastAPI boot, lifespan() runs users_store.seed_admin() using the
-- runtime ADMIN_PASSWORD environment variable.

INSERT INTO alembic_version (version_num)
VALUES ('20261121_10')
ON CONFLICT (version_num) DO UPDATE SET version_num = EXCLUDED.version_num;
