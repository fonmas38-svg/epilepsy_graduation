# Contracts, security and offline behavior

Use ../vendor/fastapi/GUIDE.md and its references for relevant backend work, checking local FastAPI/Pydantic versions first. For a requested security review read ../vendor/security-best-practices/GUIDE.md and ../vendor/security-best-practices/references/python-fastapi-web-server-security.md. For an explicit threat model read ../vendor/security-threat-model/GUIDE.md. This integration does not trigger a full security audit for every cosmetic edit or claim Dart is covered by Python guidance.

Match the client to actual schemas/status codes; 201 is a successful creation response. Keep validation and password requirements consistent. Responses must not echo passwords, enrollment secrets or tokens. Verify patient-level access before reads/writes, not only role names. Redact secrets in errors, telemetry, screenshots and artifacts.

Bind request start and completion to account identity, session generation and server origin. Logout invalidates outstanding work and caches even if the same account later returns. A 401 from an old request must not retry under a new account. Scope last-route, drafts, queued writes and cached clinical data by owner, resource and origin; test two users with identical roles and account-switch races.

Differentiate close/background/back navigation, explicit logout, expiry, remote revocation and local lock. Explain logout effects and confirm it. Multi-device support requires real per-device sessions/revocation and notification-token ownership; a global password change is not a full device-session feature. Lost-device recovery needs a verified alternate channel and audit; never promise instant revocation/wipe while offline.

Offline writes need a durable owner/origin snapshot before awaiting, stable event IDs, atomic local record/outbox transaction, idempotent server processing, bounded retries/backoff, and visible failed/exhausted status. Preserve order for dependent operations; one unsupported independent endpoint should not block the whole queue. Never move unsent records into another account/server or mark sync complete before acceptance. Reconcile timestamps in UTC and display local time. Document conflict policy and retention rather than silently overwriting records.

Migration changes need compatibility/rollback, [Supabase and Alembic alignment](supabase-and-migrations.md), and isolated tests. Never point tests at a patient database or production account.

## Project-Specific Session, Device Binding, MOH & Medication Contracts

1. **Persistent SSO Lifecycle & Thundering-Herd Refresh**:
   - Do not clear `currentUser` or cached tokens on cold app launch (`AuthService.init()`). Separate the 60-minute JWT access expiry from the 30-day refresh session lifetime (`TokenProvider.cachedSessionContext()`).
   - Guard concurrent 401/expiring-token refreshes with a single-flight `Completer` mutex so parallel widget requests await one `POST /auth/refresh` instead of triggering token rotation races that log the user out.
   - Only redirect to `LoginScreen` on explicit user logout or an authoritative revoked/expired refresh response (401).

2. **Offline Credential Fallback (`isOfflineWorkspace`)**:
   - Never call `api.tokens.clear()` before attempting network login (`AppState.signInWithPassword()`).
   - Cache a salted password verifier (PBKDF2/Argon2) in SQLCipher `user_credentials` on successful online login; on `SocketException` or timeout, verify locally and transition into `AppState.isOfflineWorkspace` with local emergency/EEG/medication access and a non-intrusive offline banner.

3. **Self-Revocation & Session Screen Safety**:
   - In `AccountSessionsScreen`, if the revoked session has `current == true`, immediately clear local tokens/session state and navigate to `LoginScreen` rather than calling `_load()` (which sends the just-revoked token and triggers HTTP 401 `"تعذر تأكيد حالة الجلسات"`).

4. **Single-Active-Device Binding (`patient` & `caregiver`)**:
   - Enforce `account_sessions.device_id` + `is_hardware_bound` during `POST /auth/login` for `patient` and `caregiver` roles (revoke prior session or return HTTP 409 conflict with clear Arabic guidance; unbind on explicit logout).
   - Note on `device_info_plus`: per official `pub.dev` docs, `androidId` was removed from `device_info_plus` (>=4.0.0) for Google Play Store privacy compliance. Use `windowsInfo.deviceId` on Windows and either the `android_id` package or a persisted app-install UUID in `FlutterSecureStorage` on Android.

5. **Creation Validation, Idempotency & 409 vs 422 Mapping**:
   - Include a client-generated UUID `idempotency_key` on `POST /doctor/patients` so cold-start timeouts that committed server-side return the existing record (HTTP 200) on retry instead of creating duplicate-username conflicts.
   - Map HTTP 409 to `FailureKind.conflict` (duplicate username/email/device) rather than `FailureKind.validation` (422 incomplete data).
   - Guard secondary clinical endpoints (`GET /patients/{id}/clinical-notes` -> `[]` for valid assigned patients with no notes; client `try-catch` fallback to SQLCipher in `CareService.clinicalNotesFor` so 404 never crashes `PatientFileScreen`).

6. **MOH Verification & Mandatory Profile Contracts**:
   - Doctor creation requires `license_number`, `specialization`, `hospital_affiliation`, `national_id`, `phone`, and optional `email` (`doctor_profiles`).
   - Support `POST /admin/doctors/verify-moh` against `moh_registry` (or authorized gateway), allowing admin confirmation or explicit test-account override when unverified/mismatched. (Note: `backend/app/main.py` mounts all routers at root `/` with no `/api/v1` prefix; while the Master Implementation Plan mentions `/api/v1/...`, follow existing `/admin/*` router conventions unless a global `/api/v1` mount is explicitly introduced.)
   - Patient creation requires `age`, `gender`, `phone`, and `emergency_contact` (optional `email`); support auto-generated editable usernames (`dr_`, `pat_`, `cg_`).

7. **Medication Role Boundaries & Bidirectional Sync**:
   - Prescriptions are authored by doctors via `POST /doctor/patients/{patient_id}/prescriptions` (`backend/app/routers/prescriptions.py`) and synced down to patient SQLCipher on startup/refresh (`GET /patient/prescriptions` / `GET /patients/{patient_id}/prescriptions`).
   - Patients log doses (`POST /patient/prescriptions/{id}/intake-log`; Master Plan writes `/api/v1/prescriptions/{id}/intake-log`—align with unprefixed `prescriptions.py` routes) with idempotent server upserts keyed by `(prescription_id, scheduled_time)`; doctors cannot mark doses taken and patients cannot create/edit/delete prescriptions.

8. **Care Home Messaging Topologies**:
   - "Care Home" denotes the patient's domestic care circle (Patient + Primary Companion + Neurologist), not a nursing home. Support `doctor_patient`, `family_patient`, `doctor_caregiver`, and `care_team_triage` channels with `delivered_at` and `read_at` receipts.
