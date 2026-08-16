# Data Model

The backend stores accounts and monitoring data in **SQLite** (SQLAlchemy Core +
Alembic). The JSON documents below remain the API/client contract; the SQL
schema that persists them is described in "Backend SQL schema" at the end.

## User
| Field | Type | Notes |
|-------|------|-------|
| uid | string | Firebase Auth uid |
| name | string | |
| role | string | `patient` \| `caregiver` \| `doctor` |
| phone | string | optional |
| email | string | |
| linkedPatientIds | string[] | for caregiver/doctor |
| fcmToken | string | optional |

## PatientProfile
| Field | Type | Notes |
|-------|------|-------|
| patientId | string | equals user uid for patient role |
| diagnosis | string | |
| medications | string[] | |
| caregivers | string[] | uids |
| doctors | string[] | uids |
| currentStatus | string | last risk label |
| lastUpdated | timestamp | |

## VitalReading
| Field | Type | Notes |
|-------|------|-------|
| id | string | |
| patientId | string | |
| timestamp | timestamp | |
| eeg | number[] | |
| ecg | number[] | |
| motion | number[] | |
| hr | number | |
| synced | bool | local SQLite flag |

## RiskAssessment
| Field | Type | Notes |
|-------|------|-------|
| id | string | |
| patientId | string | |
| timestamp | timestamp | |
| label | string | stable/watch/high_risk |
| confidence | number | |
| features | map | feature vector |
| processingMs | number | |

## Alert
| Field | Type | Notes |
|-------|------|-------|
| id | string | |
| patientId | string | |
| timestamp | timestamp | |
| severity | string | info/warning/critical |
| message | string | |
| recipients | string[] | roles or uids |
| acknowledged | bool | |
| acknowledgedBy | string | optional |

---

## Backend SQL schema (SQLite)

Location: `backend/data/epilepsy.db` (override with `SQLITE_DB_PATH`).
Schema is owned by Alembic — never edit tables by hand.

| Table | Purpose | Key constraints |
|-------|---------|-----------------|
| `users` | accounts for all roles | `username` UNIQUE **NOCASE**; `role` CHECK in (admin, doctor, patient, caregiver) |
| `assignments` | doctor ⇄ patient links | composite PK (patient_id, doctor_id) → no duplicates; FK CASCADE on user delete |
| `audit_logs` | admin action trail | `sequence` autoincrement preserves true order; capped at 1000 rows |
| `patients` | monitoring profile | PK `patient_id`; `current_status` / `last_updated` always present (nullable) |
| `readings` | raw signal windows | FK → `patients` CASCADE; capped at 500 newest per patient |
| `assessments` | model outputs | FK → `patients` CASCADE; capped at 500 per patient |
| `alerts` | notifications | FK → `patients` CASCADE; capped at 200 per patient |
| `store_imports` | legacy-import ledger | PK `source_path` makes the JSON import idempotent |

Flexible/rarely queried fields are kept in a `*_json` column, while fields used
for filtering and ordering are real indexed columns.

### Guarantees relied upon by clients
- **Atomic ingestion** — `/cloud/sync` and `/dataset/next` write the reading,
  assessment, alert, and patient status in ONE transaction, so a partial failure
  leaves no half-saved record.
- **Concurrency-safe** — patient rows are created with SQLite `UPSERT`, and WAL
  mode plus `busy_timeout` allows parallel device writes.
- **Referential integrity** — `PRAGMA foreign_keys=ON` is enabled per connection,
  so monitoring rows cannot reference a missing patient.

### Migration from the old JSON stores
On startup the backend imports `users_store.json` / `cloud_store.json` **once**:
a timestamped `.bak` copy is taken, the originals are left untouched, and the
import is skipped if the database already has data or was imported before.

Operations:
```bash
cd backend
python -m alembic upgrade head      # apply schema
python -m alembic current           # show revision
python -m alembic downgrade base    # roll back (verified by tests)
```
