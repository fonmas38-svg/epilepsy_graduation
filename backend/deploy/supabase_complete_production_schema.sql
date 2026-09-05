-- =============================================================================
-- Smart Epilepsy Monitoring & Seizure Prediction System
-- Master PostgreSQL Production Schema for Supabase (Sohobcom)
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

-- 3. Patient Clinical Profiles
CREATE TABLE IF NOT EXISTS patients (
    patient_id VARCHAR(64) NOT NULL, 
    current_status VARCHAR(64), 
    last_updated VARCHAR(64), 
    updated_at VARCHAR(64) NOT NULL, 
    profile_json TEXT NOT NULL DEFAULT '{}', 
    PRIMARY KEY (patient_id)
);

-- 4. Doctor-Patient Clinical Assignments
CREATE TABLE IF NOT EXISTS assignments (
    patient_id VARCHAR(64) NOT NULL, 
    doctor_id VARCHAR(64) NOT NULL, 
    assigned_by VARCHAR(64), 
    assigned_at VARCHAR(64) NOT NULL, 
    PRIMARY KEY (patient_id, doctor_id), 
    FOREIGN KEY(patient_id) REFERENCES users (id) ON DELETE CASCADE, 
    FOREIGN KEY(doctor_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_assignments_doctor_id ON assignments (doctor_id);

-- 5. Family & Caregiver Consents / Links
CREATE TABLE IF NOT EXISTS caregiver_links (
    patient_id VARCHAR(64) NOT NULL, 
    caregiver_id VARCHAR(64) NOT NULL, 
    linked_by VARCHAR(64), 
    linked_at VARCHAR(64) NOT NULL, 
    PRIMARY KEY (patient_id, caregiver_id), 
    FOREIGN KEY(patient_id) REFERENCES users (id) ON DELETE CASCADE, 
    FOREIGN KEY(caregiver_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_caregiver_links_caregiver_id ON caregiver_links (caregiver_id);

-- 6. Enrolled Headset Devices
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
    FOREIGN KEY(patient_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_devices_patient_id ON devices (patient_id);

-- 7. Security & Administrative Audit Logs
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

-- 8. Raw Physiological Vital Readings (EEG, ECG, Motion, HR)
CREATE TABLE IF NOT EXISTS readings (
    sequence SERIAL NOT NULL, 
    id VARCHAR(64) NOT NULL, 
    patient_id VARCHAR(64) NOT NULL, 
    captured_at VARCHAR(64), 
    payload_json TEXT NOT NULL, 
    PRIMARY KEY (sequence), 
    UNIQUE (id), 
    FOREIGN KEY(patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_readings_patient_sequence ON readings (patient_id, sequence);
CREATE INDEX IF NOT EXISTS ix_readings_patient_captured ON readings (patient_id, captured_at);

-- 9. AI Risk Assessments & Forecasts
CREATE TABLE IF NOT EXISTS assessments (
    sequence SERIAL NOT NULL, 
    id VARCHAR(64) NOT NULL, 
    patient_id VARCHAR(64) NOT NULL, 
    captured_at VARCHAR(64), 
    label VARCHAR(64), 
    payload_json TEXT NOT NULL, 
    PRIMARY KEY (sequence), 
    UNIQUE (id), 
    FOREIGN KEY(patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_assessments_patient_sequence ON assessments (patient_id, sequence);
CREATE INDEX IF NOT EXISTS ix_assessments_patient_captured ON assessments (patient_id, captured_at);

-- 10. Emergency Alerts
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
    FOREIGN KEY(patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_alerts_patient_sequence ON alerts (patient_id, sequence);
CREATE INDEX IF NOT EXISTS ix_alerts_patient_ack ON alerts (patient_id, acknowledged);

-- 11. Multi-party Alert Acknowledgments
CREATE TABLE IF NOT EXISTS alert_acknowledgments (
    id VARCHAR(64) NOT NULL, 
    alert_id VARCHAR(64) NOT NULL, 
    patient_id VARCHAR(64) NOT NULL, 
    actor_id VARCHAR(64) NOT NULL, 
    actor_role VARCHAR(32), 
    acknowledged_at VARCHAR(64) NOT NULL, 
    note TEXT, 
    PRIMARY KEY (id), 
    FOREIGN KEY(alert_id) REFERENCES alerts (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_alert_acknowledgments_alert ON alert_acknowledgments (alert_id);
CREATE INDEX IF NOT EXISTS ix_alert_acknowledgments_patient ON alert_acknowledgments (patient_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_alert_acknowledgments_actor ON alert_acknowledgments (alert_id, actor_id);

-- 12. Clinical Seizure Adjudication Outcomes
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
    payload_json TEXT NOT NULL, 
    PRIMARY KEY (sequence), 
    CONSTRAINT ck_outcomes_outcome CHECK (outcome IN ('seizure', 'no_seizure', 'false_alarm', 'unknown')), 
    UNIQUE (id), 
    FOREIGN KEY(patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE, 
    FOREIGN KEY(assessment_id) REFERENCES assessments (id) ON DELETE SET NULL, 
    FOREIGN KEY(alert_id) REFERENCES alerts (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS ix_outcomes_patient_sequence ON outcomes (patient_id, sequence);
CREATE INDEX IF NOT EXISTS ix_outcomes_assessment_id ON outcomes (assessment_id);

-- 13. Transactional Outbox Worker
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
    PRIMARY KEY (id), 
    CONSTRAINT ck_alert_outbox_status CHECK (status IN ('pending', 'sent', 'failed', 'dead')), 
    UNIQUE (alert_id)
);

CREATE INDEX IF NOT EXISTS ix_alert_outbox_due ON alert_outbox (status, next_attempt_at);

-- 14. Private Mobile Push Notification Tokens
CREATE TABLE IF NOT EXISTS push_tokens (
    id VARCHAR(64) NOT NULL, 
    user_id VARCHAR(64) NOT NULL, 
    token TEXT NOT NULL, 
    platform VARCHAR(32) NOT NULL DEFAULT 'unknown', 
    created_at VARCHAR(64) NOT NULL, 
    updated_at VARCHAR(64) NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(user_id) REFERENCES users (id) ON DELETE CASCADE, 
    UNIQUE (token)
);

CREATE INDEX IF NOT EXISTS ix_push_tokens_user_id ON push_tokens (user_id);

-- 15. Private Doctor-Patient-Caregiver Clinical Messaging
CREATE TABLE IF NOT EXISTS messages (
    id VARCHAR(64) NOT NULL, 
    patient_id VARCHAR(64) NOT NULL, 
    sender_id VARCHAR(64) NOT NULL, 
    sender_name VARCHAR(256) NOT NULL, 
    sender_role VARCHAR(32) NOT NULL, 
    channel_type VARCHAR(32) NOT NULL, 
    content TEXT NOT NULL, 
    created_at VARCHAR(64) NOT NULL, 
    read_at VARCHAR(64), 
    PRIMARY KEY (id), 
    CONSTRAINT ck_messages_channel_type CHECK (channel_type IN ('doctor_patient', 'family_patient')), 
    FOREIGN KEY(patient_id) REFERENCES users (id) ON DELETE CASCADE, 
    FOREIGN KEY(sender_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_messages_patient_channel ON messages (patient_id, channel_type);
CREATE INDEX IF NOT EXISTS ix_messages_created_at ON messages (created_at);

-- 16. Store Imports Tracking
CREATE TABLE IF NOT EXISTS store_imports (
    source_path TEXT NOT NULL, 
    checksum VARCHAR(64) NOT NULL, 
    imported_at VARCHAR(64) NOT NULL, 
    backup_path TEXT NOT NULL, 
    PRIMARY KEY (source_path)
);

-- =============================================================================
-- 17. Analytical Database Views (for Dashboards & Supabase Studio)
-- =============================================================================

-- View 1: Active and Critical Alerts with Patient Info
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
LEFT JOIN users u ON a.patient_id = u.patient_id
WHERE a.acknowledged = FALSE
ORDER BY a.sequence DESC;

-- View 2: Patient Clinical Summary Overview
CREATE OR REPLACE VIEW v_patient_summary AS
SELECT 
    p.patient_id,
    u.name AS patient_name,
    p.current_status,
    p.last_updated,
    COUNT(DISTINCT a.id) FILTER (WHERE a.acknowledged = FALSE) AS active_alerts_count,
    COUNT(DISTINCT r.id) AS total_readings_count
FROM patients p
LEFT JOIN users u ON p.patient_id = u.patient_id
LEFT JOIN alerts a ON p.patient_id = a.patient_id
LEFT JOIN readings r ON p.patient_id = r.patient_id
GROUP BY p.patient_id, u.name, p.current_status, p.last_updated;

-- View 3: Unread Clinical Messages
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
-- 18. Default Administrative Superuser Seed
-- =============================================================================
-- Default Login: admin / admin (bcrypt hashed)
INSERT INTO users (
    id, username, name, role, password_hash, disabled, session_version, 
    created_at, updated_at, meta_json
) VALUES (
    'usr-admin-system-001',
    'admin',
    'مدير النظام الطبي الموحد',
    'admin',
    '$2b$12$KkQ0QkGqGfMhYQxJv7Gj8u9C0Y9uKxRkQ0QkGqGfMhYQxJv7Gj8u.',
    FALSE,
    1,
    NOW()::TEXT,
    NOW()::TEXT,
    '{"initial_seed": true}'
) ON CONFLICT (username) DO NOTHING;

-- Record Alembic Schema Migration Version
INSERT INTO alembic_version (version_num) 
VALUES ('20260904_06')
ON CONFLICT (version_num) DO NOTHING;

