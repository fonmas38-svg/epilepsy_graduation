BEGIN;

CREATE TABLE alembic_version (
    version_num VARCHAR(32) NOT NULL, 
    CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
);

-- Running upgrade  -> 20260815_01

CREATE TABLE users (
    id VARCHAR(64) NOT NULL, 
    username VARCHAR(128) NOT NULL, 
    name VARCHAR(256) NOT NULL, 
    role VARCHAR(32) NOT NULL, 
    password_hash TEXT NOT NULL, 
    disabled BOOLEAN NOT NULL, 
    session_version INTEGER NOT NULL, 
    primary_doctor_id VARCHAR(64), 
    patient_id VARCHAR(64), 
    created_by VARCHAR(64), 
    created_at VARCHAR(64) NOT NULL, 
    updated_at VARCHAR(64) NOT NULL, 
    meta_json TEXT NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT ck_users_role CHECK (role IN ('admin', 'doctor', 'patient', 'caregiver')), 
    UNIQUE (username)
);

CREATE TABLE patients (
    patient_id VARCHAR(64) NOT NULL, 
    current_status VARCHAR(64), 
    last_updated VARCHAR(64), 
    updated_at VARCHAR(64) NOT NULL, 
    profile_json TEXT NOT NULL, 
    PRIMARY KEY (patient_id)
);

CREATE TABLE audit_logs (
    sequence SERIAL NOT NULL, 
    id VARCHAR(64) NOT NULL, 
    at VARCHAR(64) NOT NULL, 
    actor VARCHAR(64), 
    actor_role VARCHAR(32), 
    action VARCHAR(128) NOT NULL, 
    target VARCHAR(128), 
    detail_json TEXT NOT NULL, 
    PRIMARY KEY (sequence), 
    UNIQUE (id)
);

CREATE INDEX ix_audit_logs_at ON audit_logs (at);

CREATE INDEX ix_audit_logs_actor ON audit_logs (actor);

CREATE TABLE assignments (
    patient_id VARCHAR(64) NOT NULL, 
    doctor_id VARCHAR(64) NOT NULL, 
    assigned_by VARCHAR(64), 
    assigned_at VARCHAR(64) NOT NULL, 
    PRIMARY KEY (patient_id, doctor_id), 
    FOREIGN KEY(patient_id) REFERENCES users (id) ON DELETE CASCADE, 
    FOREIGN KEY(doctor_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX ix_assignments_doctor_id ON assignments (doctor_id);

CREATE TABLE readings (
    sequence SERIAL NOT NULL, 
    id VARCHAR(64) NOT NULL, 
    patient_id VARCHAR(64) NOT NULL, 
    captured_at VARCHAR(64), 
    payload_json TEXT NOT NULL, 
    PRIMARY KEY (sequence), 
    UNIQUE (id), 
    FOREIGN KEY(patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX ix_readings_patient_sequence ON readings (patient_id, sequence);

CREATE INDEX ix_readings_patient_captured ON readings (patient_id, captured_at);

CREATE TABLE assessments (
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

CREATE INDEX ix_assessments_patient_sequence ON assessments (patient_id, sequence);

CREATE INDEX ix_assessments_patient_captured ON assessments (patient_id, captured_at);

CREATE TABLE alerts (
    sequence SERIAL NOT NULL, 
    id VARCHAR(64) NOT NULL, 
    patient_id VARCHAR(64) NOT NULL, 
    captured_at VARCHAR(64), 
    severity VARCHAR(32), 
    acknowledged BOOLEAN NOT NULL, 
    payload_json TEXT NOT NULL, 
    PRIMARY KEY (sequence), 
    UNIQUE (id), 
    FOREIGN KEY(patient_id) REFERENCES patients (patient_id) ON DELETE CASCADE
);

CREATE INDEX ix_alerts_patient_sequence ON alerts (patient_id, sequence);

CREATE INDEX ix_alerts_patient_ack ON alerts (patient_id, acknowledged);

CREATE TABLE store_imports (
    source_path TEXT NOT NULL, 
    checksum VARCHAR(64) NOT NULL, 
    imported_at VARCHAR(64) NOT NULL, 
    backup_path TEXT NOT NULL, 
    PRIMARY KEY (source_path)
);

INSERT INTO alembic_version (version_num) VALUES ('20260815_01') RETURNING alembic_version.version_num;

-- Running upgrade 20260815_01 -> 20260815_02

CREATE TABLE alert_outbox (
    id VARCHAR(64) NOT NULL, 
    alert_id VARCHAR(64) NOT NULL, 
    patient_id VARCHAR(64) NOT NULL, 
    payload_json TEXT NOT NULL, 
    status VARCHAR(16) NOT NULL, 
    attempts INTEGER NOT NULL, 
    next_attempt_at VARCHAR(64) NOT NULL, 
    last_error TEXT, 
    created_at VARCHAR(64) NOT NULL, 
    updated_at VARCHAR(64) NOT NULL, 
    PRIMARY KEY (id), 
    CONSTRAINT ck_alert_outbox_status CHECK (status IN ('pending', 'sent', 'failed', 'dead')), 
    UNIQUE (alert_id)
);

CREATE INDEX ix_alert_outbox_due ON alert_outbox (status, next_attempt_at);

UPDATE alembic_version SET version_num='20260815_02' WHERE alembic_version.version_num = '20260815_01';

-- Running upgrade 20260815_02 -> 20260816_03

CREATE TABLE caregiver_links (
    patient_id VARCHAR(64) NOT NULL, 
    caregiver_id VARCHAR(64) NOT NULL, 
    linked_by VARCHAR(64), 
    linked_at VARCHAR(64) NOT NULL, 
    PRIMARY KEY (patient_id, caregiver_id), 
    FOREIGN KEY(patient_id) REFERENCES users (id) ON DELETE CASCADE, 
    FOREIGN KEY(caregiver_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX ix_caregiver_links_caregiver_id ON caregiver_links (caregiver_id);

CREATE TABLE devices (
    device_id VARCHAR(128) NOT NULL, 
    patient_id VARCHAR(64) NOT NULL, 
    name VARCHAR(256) NOT NULL, 
    secret_hash TEXT NOT NULL, 
    credential_version INTEGER NOT NULL, 
    disabled BOOLEAN NOT NULL, 
    created_by VARCHAR(64), 
    created_at VARCHAR(64) NOT NULL, 
    updated_at VARCHAR(64) NOT NULL, 
    last_enrolled_at VARCHAR(64), 
    PRIMARY KEY (device_id), 
    FOREIGN KEY(patient_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX ix_devices_patient_id ON devices (patient_id);

CREATE TABLE alert_acknowledgments (
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

CREATE INDEX ix_alert_acknowledgments_alert ON alert_acknowledgments (alert_id);

CREATE INDEX ix_alert_acknowledgments_patient ON alert_acknowledgments (patient_id);

CREATE UNIQUE INDEX ux_alert_acknowledgments_actor ON alert_acknowledgments (alert_id, actor_id);

CREATE TABLE outcomes (
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

CREATE INDEX ix_outcomes_patient_sequence ON outcomes (patient_id, sequence);

CREATE INDEX ix_outcomes_assessment_id ON outcomes (assessment_id);

UPDATE alembic_version SET version_num='20260816_03' WHERE alembic_version.version_num = '20260815_02';

-- Running upgrade 20260816_03 -> 20260816_04

CREATE TABLE push_tokens (
    id VARCHAR(64) NOT NULL, 
    user_id VARCHAR(64) NOT NULL, 
    token TEXT NOT NULL, 
    platform VARCHAR(32) NOT NULL, 
    created_at VARCHAR(64) NOT NULL, 
    updated_at VARCHAR(64) NOT NULL, 
    PRIMARY KEY (id), 
    FOREIGN KEY(user_id) REFERENCES users (id) ON DELETE CASCADE, 
    UNIQUE (token)
);

CREATE INDEX ix_push_tokens_user_id ON push_tokens (user_id);

UPDATE alembic_version SET version_num='20260816_04' WHERE alembic_version.version_num = '20260816_03';

-- Running upgrade 20260816_04 -> 20260817_05

CREATE UNIQUE INDEX ux_users_username_lower ON users (lower(username));

UPDATE alembic_version SET version_num='20260817_05' WHERE alembic_version.version_num = '20260816_04';

-- Running upgrade 20260817_05 -> 20260904_06

CREATE TABLE messages (
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

CREATE INDEX ix_messages_patient_channel ON messages (patient_id, channel_type);

CREATE INDEX ix_messages_created_at ON messages (created_at);

UPDATE alembic_version SET version_num='20260904_06' WHERE alembic_version.version_num = '20260817_05';

COMMIT;