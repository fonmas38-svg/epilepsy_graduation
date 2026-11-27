---
name: epilepsy-system
description: Engineering reference and maintenance guide for the epilepsy_graduation_project across Flutter Android/Windows clients (including integrated mobile/desktop administration), FastAPI backend, Supabase database/storage/realtime, Render hosting, AI models, and device simulation.
---
# Epilepsy System — Engineering Skill

Unified architectural and engineering guide for the **Epilepsy Patient Monitoring System**. Read this overview for system architecture, services, and hosting infrastructure, and consult the specialized `references/*.md` module(s) for domain-specific rules.

---

## 1. System Architecture Overview

The project is a multi-tier, **Offline-First** health monitoring platform composed of three active modules (with all administration consolidated directly inside the Flutter application under maximum security hardening, and no standalone web admin portal):

1. **Client & Administration Application (`mobile/` — Flutter for Android & Windows):**
   - Multi-role application supporting **Patient**, **Caregiver**, **Doctor**, and **Admin** workspaces in a single hardened native client.
   - Operates offline-first using encrypted local `SQLite/SQLCipher` (`LocalDatabase`) paired with an idempotent `Outbox` synchronization queue (`SyncService`), `Provider` state management (`AppState`), biometric verification (`local_auth`), idle auto-lock (`InactivityWatcher`), and device-bound sessions.
2. **Backend API & AI Service (`backend/` — FastAPI + Python):**
   - Central REST backend (mounted at `/`) handling authentication, RBAC permissions, EEG/vital-sign analysis, seizure risk forecasting, clinical care workflows, messaging, administrative governance, and background notification dispatch.
3. **Hardware Signal Simulator (`partners/hardware-sim/` & In-App Emulator):**
   - Simulates wearable headband streams (EEG, ECG, motion, heart rate at 256 Hz) for testing and evaluation via Python (`sim_client.py` -> `/device/ingest`) and an in-app polymorphic interface (`IEegHardwareDevice`).

---

## 2. Core Services & Responsibilities

* **AI Seizure Analysis & Forecasting (`backend/app/ml/`, `EdgeModelService`):**
  * Cloud engine (`RiskClassifier`, `DeepSeizureModel`, `risk_model.joblib`) classifies risk (`stable`, `watch`, `high_risk`) and pre-ictal probability from EEG + vitals (`POST /analyze`).
  * Edge module (`EdgeModelService` + bundled `assets/models/edge_seizure_model.onnx` / `dual_model_config.json`) provides local on-device scoring when offline.
* **Encrypted Storage & Sync (`LocalDatabase`, `SyncService`, `AlertOutbox`):**
  * Persists telemetry, assessments, alerts, medications, intake logs, clinical notes, and emergency contacts locally in SQLCipher and reconciles pending writes with the backend upon reconnection.
* **Cloud Storage (`backend/app/supabase_storage.py`):**
  * Integrates with Supabase Storage (`clinical-reports` bucket) to store generated clinical PDF/EEG reports and issue retrieval URLs.
* **Real-Time Sync (`supabase_realtime`):**
  * Streams live updates for `alerts`, `messages`, `medication_logs`, and `prescriptions` across connected sessions.
* **Notifications & Emergency Delivery (`notification_delivery.py`, `EmergencySmsService`, `flutter_local_notifications`):**
  * Routes urgent server alerts via Firebase Cloud Messaging (FCM), manages timezone-safe local medication alarms, handles 30-second pre-alert countdowns (`PreAlertController`), and opens pre-filled emergency SMS drafts with coordinates when offline.
* **Geolocation (`LocationService` via `geolocator`):**
  * Captures patient coordinates using hardware GNSS (`forceLocationManager: true` on Android) and platform location providers, filtering inaccurate IP-based results for SOS and alert sharing.
* **Security, Auth & Biometrics (`PyJWT`, `account_sessions`, `FlutterSecureStorage`, `local_auth`, `InactivityWatcher`):**
  * Enforces JWT authentication, device-bound long-lived sessions (`device_id`), role isolation, biometric unlock, and idle screen locking.
* **Clinical Workflows & Reporting (`CareService`, `MedicationService`, `MessageService`, `ReportExportService`):**
  * Supports prescriptions and adherence tracking, 4-channel care-circle messaging, doctor event review (`AdjudicationScreen`), and PDF/CSV/Excel report exports.

---

## 3. Hosting & Cloud Infrastructure

| Platform | Hosted Component | Role & Purpose |
|---|---|---|
| **Render** (`render.yaml`) | FastAPI Backend Web Service | Hosts the Python/Uvicorn API and cloud AI inference engine over HTTPS with environment-based configuration (`APP_ENV`, `DATABASE_URL`, `JWT_SECRET`, `NOTIFICATION_CHANNEL`, `CORS_ORIGINS`). |
| **Supabase** | Managed PostgreSQL, Storage & Realtime | Provides persistent PostgreSQL database (via Supavisor Pooler and direct DDL port) with Row Level Security (RLS), `clinical-reports` object storage for medical PDFs, and real-time event streaming. |
| **Firebase (Google)** | Firebase Cloud Messaging (FCM) | Delivers background push notifications from the backend alert outbox worker to caregiver and clinician mobile devices. |
| **GitHub & GitHub Actions** | Source Code & `render_keep_alive.yml` | Hosts the project repository and runs a periodic 14-minute `/health` ping workflow to maintain backend readiness and reduce cold-start delays. |

For complete architectural details, refer to [Architecture and Infrastructure](references/architecture-and-infrastructure.md).

---

## 4. Reference Modules

| Domain | Reference Module |
|---|---|
| System architecture, services, and cloud hosting | [Architecture & Infrastructure](references/architecture-and-infrastructure.md) |
| Visual identity, themes, photosensitivity safety, 12h formatting | [Design System](references/design-system.md) |
| Screen design, RTL, accessibility, role workflows, clinical UI | [UI and Roles](references/ui-and-roles.md) |
| API/database contracts, sessions, device binding, verification | [Contracts and Sessions](references/contracts-and-sessions.md) |
| Supabase schema, Alembic migrations, connection pooling, RLS | [Supabase and Migrations](references/supabase-and-migrations.md) |
| EEG inference, `IEegHardwareDevice`, event review, simulator | [Model and Devices](references/model-and-devices.md) |
| Alerts, SMS, FCM, geolocation, Render operations, APK standards | [Delivery and Operations](references/delivery-and-operations.md) |
| Offline-first hybrid parity, edge inference, GNSS/SMS fallback | [Offline Hybrid Sync](references/offline-hybrid-sync.md) |
| Static analysis, Dart/Flutter MCP, linting workflows | [Static Analysis and Tooling](references/static-analysis-and-tooling.md) |
| Verification, regression tests, and handoff checks | [Verification](references/verification.md) |
| External sources, licensing, and manifest | [Sources](references/sources.md) and [manifest](manifest.json) |

---

## 5. General Engineering Rules

0. **Explicit Build Rule**: Only build or export distributable binaries (APK, AAB, EXE, etc.) when explicitly requested.
1. **Verify Local Versions**: Confirm dependency and schema state from `mobile/pubspec.yaml`, `backend/requirements.txt`, and `backend/alembic/versions/` before making changes.
2. **Preserve Architecture & Virtual-Hardware-First Mandate**: Respect existing frameworks, security boundaries, and strict isolation across patient, caregiver, doctor, and admin roles. Because physical wearable EEG hardware is not yet attached, the **in-app/cloud Signal Simulator acts as the active virtual hardware stream** across all patient UI, local Edge AI inference, and cloud AI inference (to be swapped cleanly to real hardware drivers later via `IEegHardwareDevice`). Do not block live monitoring or prediction flows with artificial "no data" dead-ends when virtual hardware is active; tag virtual telemetry cleanly in internal metadata rather than exposing raw technical jargon to end users.
3. **Unified Online/Offline Failover & Resilience**: Maintain a single unified connectivity/orchestration state machine (`Online` ↔ `Offline`) with zero-loss local SQLite/Outbox persistence, idempotency keys, and full local functional parity (local simulator, active local prediction, offline SMS SOS, offline GNSS location). Never surface internal server cold-start/infrastructure messages (such as "waking cloud server") to patients.
4. **Honest Reporting**: Base technical statements strictly on verified code and executed checks/tests; distinguish static analysis/tests from distributable builds.
