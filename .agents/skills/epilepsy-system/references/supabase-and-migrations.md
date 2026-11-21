# Supabase, Alembic Schema Drift, Pooling & RLS

This module aligns database maintenance with the actual repository state (`backend/alembic/versions/`, `backend/deploy/`, `backend/app/database.py`), the Master Implementation Plan, and official Supabase/SQLAlchemy documentation.

---

## 1. Schema Drift Audit (`supabase_complete_production_schema.sql` vs Alembic)

`backend/deploy/supabase_complete_production_schema.sql` currently stamps `alembic_version` at `20260904_06` (line 328), omitting three existing Alembic migrations under `backend/alembic/versions/`:

| Revision | File | Missing Tables / Columns in Deploy SQL | Runtime Symptom When Unapplied |
|---|---|---|---|
| `20261028_07` | `20261028_07_integrity.py` | `prescriptions`, `device_streams`, `sso_codes`, `caregiver_links.disabled`, `alert_outbox.lease_token` | Broken prescriptions, device streaming, SSO codes |
| `20261113_08` | `20261113_08_care_records.py` | `care_records` | Patient clinical records / care notes errors |
| `20261114_09` | `20261114_09_account_sessions.py` | `account_sessions`, `push_tokens.session_id` FK | HTTP 500 on `GET /auth/sessions` ("تعذر تأكيد حالة الجلسات") |

### Planned Master Plan Schema Additions (Alembic 10+)
Execute DDL strictly via sequential Alembic revisions after `20261114_09`:
1. `users.email VARCHAR(255)` + partial unique index `uq_users_email_active ON users (LOWER(email)) WHERE email IS NOT NULL AND disabled = false`.
2. `doctor_profiles` (`user_id` FK, `license_number` UNIQUE, `specialization`, `hospital_affiliation`, `national_id` UNIQUE, `phone`, `moh_verified`, `moh_verified_at`).
3. `moh_registry` (simulated Ministry of Health verification registry: `license_number` PK, `national_id`, `full_name_ar`, `full_name_en`, `specialization`, `status`, `expiration_date`).
4. `account_sessions.device_id VARCHAR(128)` and `is_hardware_bound BOOLEAN DEFAULT FALSE`.
5. `messages.channel_type` check constraint expanded to `('doctor_patient', 'family_patient', 'doctor_caregiver', 'care_team_triage')`, plus `delivered_at` and `read_at` timestamps.
6. `outcomes`: `CONSTRAINT uq_outcomes_alert UNIQUE(patient_id, alert_id)` and `version INTEGER` for optimistic concurrency (`WHERE version = :expected`).

Never leave `backend/deploy/supabase_complete_production_schema.sql` out of sync with Alembic `head`, and never ship hardcoded default `'admin'` bcrypt hashes in production DDL scripts (`supabase_complete_production_schema.sql:309–324`).

---

## 2. Supabase Connection Pooling vs. Alembic DDL (Official Rules)

Per official Supabase and SQLAlchemy documentation:
- **Runtime FastAPI traffic on Transaction Pooler (Port `6543`, `*.pooler.supabase.com` with `?sslmode=require`)**:
  - Supavisor/PgBouncer manages connection pooling externally per transaction.
  - Use `poolclass=NullPool` in SQLAlchemy `create_engine()` (do **not** stack a client `QueuePool(pool_size=20, max_overflow=10)` on top of Transaction Mode port `6543`, as that causes connection starvation and closed-socket errors).
  - If using `asyncpg` on port `6543`, disable prepared statement caches (`statement_cache_size=0`, `prepared_statement_cache_size=0`).
  - Only use `QueuePool` (`pool_pre_ping=True`, `pool_recycle=<below DB idle timeout>`) when connecting directly to PostgreSQL or a Session-mode endpoint, not Transaction Mode port `6543`.
- **Alembic Migrations**:
  - Prefer **Direct Connection (Port `5432`)** for Alembic DDL (`CREATE TABLE`, `ALTER TABLE`, schema locks), or enforce `poolclass=pool.NullPool` in `alembic/env.py` if network constraints require port `6543`.

---

## 3. Row Level Security (RLS) Baseline

`backend/deploy/supabase_complete_production_schema.sql`, `supabase_schema.sql`, and `supabase_schema_postgres.sql` currently contain **0** `ENABLE ROW LEVEL SECURITY` statements or `CREATE POLICY` rules.
- If Supabase PostgREST exposes the `public` schema, any holder of the Supabase `anon` key could read/mutate clinical tables directly unless RLS is enabled.
- Enable `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;` on all clinical/user tables in Supabase (denying `anon` access to clinical tables and restricting authenticated/service-role access cleanly), and use a dedicated least-privilege database role for backend migrations vs runtime.
- Keep isolated test databases for `pytest`; never point tests or Alembic experiments at a live patient Supabase instance.
