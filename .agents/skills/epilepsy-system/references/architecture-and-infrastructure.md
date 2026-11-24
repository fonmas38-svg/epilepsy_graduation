# System Architecture, Services & Cloud Hosting

A unified, general-purpose architectural reference for the **Epilepsy Patient Monitoring System** across mobile/desktop clients, cloud APIs, AI inference, web administration, and cloud hosting infrastructure.

---

## 1. System Architecture (Multi-Tier Offline-First Topology)

The system is organized into four main components communicating over HTTPS/REST, real-time subscriptions, and local encrypted persistence:

1. **Client Application (`mobile/` — Flutter for Android & Windows):**
   - **Role & Benefit:** Primary user interface serving four distinct roles (**Patient**, **Caregiver**, **Doctor**, **System Admin**). Built with an **Offline-First** architecture so monitoring, emergency alerting, medication tracking, and local record storage remain operational even without internet connectivity.
   - **Core Stack:** Flutter/Dart (`Provider` state management via `AppState`), local encrypted `SQLite/SQLCipher` (`LocalDatabase`), `FlutterSecureStorage` for tokens and device keys, and `SyncService` + `Outbox` for reliable background synchronization.
2. **Backend API & AI Engine (`backend/` — FastAPI + Python):**
   - **Role & Benefit:** Central REST API service (mounted directly at `/`) responsible for authentication, role-based access control (RBAC), EEG/vital-sign signal classification and seizure forecasting, clinical record management, medication prescriptions, alert routing, and cloud synchronization.
   - **Core Stack:** FastAPI, Uvicorn, Pydantic v2, SQLAlchemy 2.0, Alembic migrations, `psycopg` 3, PyJWT, NumPy/SciPy/scikit-learn, and `firebase-admin`.
3. **Web Administration Portal (`admin-dashboard/` — React + Vite):**
   - **Role & Benefit:** Browser-based administrative console for managing doctor, patient, and caregiver accounts, handling doctor registry verification, managing patient-caregiver-doctor links, and reviewing system resources.
   - **Core Stack:** React 18, React Router DOM, Vite.
4. **Hardware Signal Simulator (`partners/hardware-sim/` & In-App Emulator):**
   - **Role & Benefit:** Generates multi-channel physiological telemetry (EEG, ECG, motion, heart rate at 256 Hz across `stable`, `watch`, `high_risk`, and `ramp` patterns) for end-to-end testing and demonstration in place of physical wearable EEG hardware.
   - **Core Stack:** Python simulator client (`sim_client.py` targeting `/device/ingest`) and in-app polymorphic device abstraction (`IEegHardwareDevice` / `SoftwareEmulatorEegDevice`).

---

## 2. Services Used & Purpose of Each

| Domain | Service / Module | Role & Functional Benefit |
|---|---|---|
| **Cloud AI & Seizure Analysis** | `RiskClassifier`, `DeepSeizureModel`, `risk_model.joblib` (`backend/app/ml/`) | Evaluates incoming physiological windows (`POST /analyze`) using deep EEG models fused with multimodal vitals (HR, ECG, motion), degrading gracefully to scikit-learn and rule-based evaluation to provide risk levels (`stable`, `watch`, `high_risk`) and pre-ictal forecasts. |
| **On-Device Edge AI** | `EdgeModelService` & bundled models (`mobile/assets/models/edge_seizure_model.onnx`, `dual_model_config.json`) | Performs local signal preprocessing, spectral/spike feature extraction, and pre-ictal scoring directly on the client device when cloud inference is unavailable. |
| **Local Encrypted Database & Sync** | `LocalDatabase` (`sqflite_sqlcipher`), `SyncService`, `Outbox` | Stores vitals, assessments, alerts, medications, intake logs, clinical notes, and emergency contacts locally with SQLCipher encryption, queuing mutations in an idempotent outbox for automatic synchronization once connectivity is restored. |
| **Cloud Relational Database** | Supabase PostgreSQL (`SQLAlchemy` + `Alembic` + `psycopg` 3) | Persistent multi-user relational data store for accounts, sessions, patient clinical records, prescriptions, alert outbox, event adjudications, and care messages, guarded by Row Level Security (RLS). |
| **Cloud File Storage** | Supabase Storage (`clinical-reports` bucket via `backend/app/supabase_storage.py`) | Stores generated clinical PDF and EEG reports in the cloud and provides shareable public/signed access URLs for patients and clinicians. |
| **Real-Time Event Streaming** | Supabase Realtime (`supabase_realtime` publication) | Broadcasts live database updates for `alerts`, `messages`, `medication_logs`, and `prescriptions` so connected clients reflect emergencies and clinical updates promptly. |
| **Push Notifications** | Firebase Cloud Messaging (`firebase-admin` / `firebase_messaging`) | Delivers asynchronous high-priority push notifications to registered caregiver and doctor devices when critical seizure alerts, pre-alerts, or SOS triggers occur. |
| **Local Alarms & Pre-Alert Lifecycle** | `flutter_local_notifications`, `timezone`, `PreAlertController` | Fires timezone-safe medication reminders independently of EEG streaming, surfaces local alerts, and manages the 30-second countdown cancel window for early seizure forecasts. |
| **Offline Emergency SMS** | `EmergencySmsService` (`url_launcher`) | Prepares and opens the native SMS composer pre-filled with patient identity, event timestamp, and GPS coordinates/map link to registered emergency contacts when internet delivery is unavailable. |
| **Geolocation & Positioning** | `LocationService` (`geolocator`) | Acquires patient coordinates via hardware GNSS satellites (`forceLocationManager: true` on Android) and platform location providers, filters coarse IP-based guesses, and attaches location to SOS/alert dispatches. |
| **Authentication & Device Security** | PyJWT, `account_sessions`, `FlutterSecureStorage`, `local_auth`, `InactivityWatcher` | Issues short-lived access JWTs paired with long-lived revocable sessions bound to a persistent installation `device_id`, alongside biometric authentication and idle auto-lock protection. |
| **Clinical & Reporting Tools** | `MedicationService`, `MessageService`, `CareService`, `ReportExportService` (`pdf`, `csv`, `excel`) | Manages prescriptions and adherence logs, 4-channel care-circle messaging, doctor event adjudication, and structured medical report exports. |

---

## 3. Hosting & Cloud Infrastructure

| Platform / Provider | Hosted Component | Purpose & Operational Function |
|---|---|---|
| **Render** (`render.yaml`) | FastAPI Backend Service (`epilepsy-backend`, Python Web Service) | Hosts the production Python API and AI inference server over HTTPS, runs `uvicorn`, manages environment configuration (`APP_ENV`, `DATABASE_URL`, `JWT_SECRET`, `NOTIFICATION_CHANNEL`, `CORS_ORIGINS`), and exposes `/health` and all application endpoints. |
| **Supabase** | Managed PostgreSQL + Connection Pooler + Storage + Realtime | Serves as the unified data platform: (1) persistent PostgreSQL storage via Supavisor/PgBouncer pooler and direct DDL port, (2) `clinical-reports` object storage bucket for medical PDFs, and (3) real-time database change broadcasting (`supabase_realtime`). |
| **Firebase (Google)** | Firebase Cloud Messaging (FCM) | Cloud messaging transport layer bridging the FastAPI alert outbox worker to Android/iOS caregiver and clinician devices for background alert delivery. |
| **GitHub & GitHub Actions** | Source Repository & `.github/workflows/render_keep_alive.yml` | Hosts the monorepo source code (`mobile/`, `backend/`, `admin-dashboard/`, `partners/`) and runs a scheduled 14-minute health-check cron workflow (`/health`) to keep the Render backend warm and minimize cold-start delays. |
