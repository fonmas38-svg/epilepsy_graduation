# MASTER ARCHITECTURAL AUDIT & IMPLEMENTATION PLAN (v2.1.0)
## Epilepsy Patient Monitoring System (Flutter • FastAPI • Supabase • Render)

> **Latest verification — 2026-11-24:** The phase results below are historical checkpoints, not a declaration that all requirements are complete. See [the current verification and repair report](IMPLEMENTATION_VERIFICATION_2026-11-24.md) for reproduced defects, implemented repairs, current test evidence, and outstanding work. The source request has 19 numbered items because #12 was omitted.

**Document Version**: 2.1.0 — Phase 1, Phase 2 & Phase 3 Completed & Verified; Phases 4–6 Core Checkpoint Saved  
**Status**: **Phase 1 Completed & Verified** (Backend 231/231 -> 239/239) | **Phase 2 Completed & Verified** (Backend targeted 33/33, Mobile `dart analyze` 0 issues, Mobile `flutter test` 189/189) | **Phase 3 Completed & Verified** (Backend sync-batch & contract 7/7, Mobile hardware emulator & resilience tests all passed) | **Phases 4–6 Core Checkpoint Saved** (Backend MOH/5-channel messaging/optimistic locking/prescriptions tests 6/6 passed, Mobile `dart analyze --fatal-infos lib` 0 issues, onboarding/scope/messaging tests 26/26 passed)  
**Governing Project Skills**:
- Core Engineering Skill: [epilepsy-system](../.agents/skills/epilepsy-system/SKILL.md) (with domain modules under `.agents/skills/epilepsy-system/references/`)
- Static Analysis & Integrity Skill: [epilepsy-quality-gate](../.agents/skills/epilepsy-quality-gate/SKILL.md)

**Target Environments**:
- **Frontend**: Flutter Multi-platform (`mobile/` — Android Mobile & Windows Desktop, Dart SDK `^3.10.4`)
- **Backend Services**: FastAPI (`backend/app/` — mounted at `/` with no `/api/v1` prefix, `psycopg[binary]>=3.1,<4.0`, hosted on Render)
- **Database Layer**: PostgreSQL on Supabase (`backend/alembic/versions/` & `backend/deploy/supabase_complete_production_schema.sql`)
- **Hardware & Model Simulator**: EEG Stream Simulator (`partners/hardware-sim/sim_client.py`) & Edge ONNX Model (`mobile/assets/models/`)

---

## Mandatory Project Skills Usage (استخدام مهارات المشروع الإلزامي)

> [!IMPORTANT]
> **إلزامي لكل مطوّر أو وكيل ذكاء اصطناعي (Developer / AI Agent) يكمل المراحل (Phases 3–6):**
> يجب قراءة والالتزام التام بمهارتي المشروع المعتمدتين داخل `.agents/skills/` قبل تعديل أي كود أو إغلاق أي مرحلة:
>
> 1. **`.agents/skills/epilepsy-system/SKILL.md`** — المرجع الهندسي الشامل للنظام، ويشمل وحدات التوجيه المتخصصة تحت `.agents/skills/epilepsy-system/references/`:
>    - `contracts-and-sessions.md` (عقود الـ API، إدارة الجلسات، قفل تجديد التوكنات، وربط الجهاز الواحد HTTP 409)
>    - `offline-hybrid-sync.md` (التشفير المحلي SQLCipher، جدول `user_credentials`، الطابور المحلي Outbox والمزامنة)
>    - `supabase-and-migrations.md` (توافق Alembic مع Supabase Transaction Pooler وسياسات RLS)
>    - `ui-and-roles.md` و `design-system.md` (عزل الأدوار الأربعة، نظام التصميم والسمات، منع الشاشة السوداء)
>    - `static-analysis-and-tooling.md` و `verification.md` (أدوات التحليل الثابت ومعايير التحقق)
> 2. **`.agents/skills/epilepsy-quality-gate/SKILL.md`** — بوابة الجودة الإلزامية قبل إنهاء أي مرحلة أو الدمج والرفع إلى GitHub:
>    - تشغيل التحليل الثابت الصارم (`dart analyze --fatal-infos lib`, `flutter analyze --no-pub`).
>    - فحص تطابق مخططات SQLAlchemy / Alembic / Supabase وسياسات RLS.
>    - الحفاظ على خطوط الأساس للاختبارات دون انحدار (Backend pytest & Flutter test).
>    - **حظر البناء الصارم (Strict Build Prohibition)**: يُمنع منعاً باتاً تشغيل أوامر بناء الحزم التوزيعية (`flutter build apk`, `appbundle`, `windows`, إلخ) ما لم يطلب المستخدم ذلك صراحة.

---

## User Review Required

> [!NOTE]
> **Confirmed Design Decision — Single-Device Binding Policy (Point 19)**:
> Confirmed by User: **Option A — Strict Block**. When a **Patient** or **Caregiver** already has an active session on Device A (not logged out) and attempts to log in from Device B, Device B is rejected with **HTTP 409 Conflict** (*"هذا الحساب مسجل ونشط حالياً على جهاز آخر. يرجى تسجيل الخروج من الجهاز السابق أولاً."*), keeping Device A bound until explicit logout (with an Admin force-revoke escape hatch in case Device A is lost/damaged). — **Implemented & Verified in Phase 2**.
>
> **Completed Execution**: Phase 1 & Phase 2 completed & verified. **Next**: Phase 3 (Hardware Emulator Abstraction & Network Resilience).

> [!WARNING]
> **Production Hardening Notes (`render.yaml` & `AndroidManifest.xml`)**:
> 1. `backend/app/settings.py:91–110` (`validate_production_settings()`) checks **`APP_ENV=production`** and aborts startup if `CORS_ORIGINS` contains `*`, `NOTIFICATION_CHANNEL` != `fcm`, `ADMIN_PASSWORD` is missing, or `JWT_SECRET` < 32 chars. Currently `render.yaml` sets `CORS_ORIGINS: "*"`, `NOTIFICATION_CHANNEL: stub`, `JWT_EXPIRE_MINUTES: "60"`, `DATABASE_URL: sync: false`, and omits `ADMIN_PASSWORD`.
> 2. `mobile/android/app/src/main/AndroidManifest.xml:12` sets `android:usesCleartextTraffic="true"` (needed only for local `http://` dev testing); disable or gate via build flavor / network security config before production release.

---

## 1. Complete Traceability Matrix (All 20 User Points & 4 Screenshots)

*(Note: In the user's original prompt numbering, #12 was omitted, jumping from #11 to #13. Every point `1–11` and `13–20` is preserved with its exact original number below.)*

| User Point | Topic & Screenshot Ref | Verified Primary Files | Phase |
|---|---|---|---|
| **#1** | Offline login shows error instead of offline access | `mobile/lib/providers/app_state.dart:705,787–799`, `auth_service.dart`, `token_provider.dart`, `local_database.dart` | **Phase 2** |
| **#2** | Single unified simulator standing in for missing hardware | `partners/hardware-sim/sim_client.py`, `backend/app/routers/device.py:107,240`, `mobile/lib/services/monitoring_service.dart`, `signal_simulator.dart` | **Phase 3** |
| **#3** | Slow server connection / Render latency bottlenecks | `mobile/lib/services/api_client.dart:185,266,342–380`, `backend/app/database.py:475–498`, `cloud_dataset.py:99` | **Phase 1 & 3** |
| **#4** | Home dashboard screens for all 4 roles | `patient_home_screen.dart:373,706–712`, `doctor_home_screen.dart:93–116`, `caregiver_home_screen.dart:127`, `admin_home_screen.dart:554` | **Phase 4 & 6** |
| **#5** | Doctor adding patient -> **Black Screen (Screenshot 1)** | `mobile/lib/main.dart:219–238` (`identical()`), `doctor_home_screen.dart:735`, `auth_service.dart:200`, + 31 `AppUser` `identical()` sites | **Phase 4** |
| **#6** | Optional email + auto-generated editable username (all roles) | `backend/app/database.py:43–66`, `accounts.py:128–165,815`, `create_doctor_dialog.dart`, `doctor_home_screen.dart:673,844` | **Phase 1 & 4** |
| **#7** | Mandatory profile data for Doctor account creation | `backend/app/routers/accounts.py:128`, `create_doctor_dialog.dart:84–165`, `admin-dashboard/src/pages/DoctorsPage.jsx` | **Phase 1 & 4** |
| **#8** | Ministry of Health (MOH) doctor verification + admin override/cancel | `backend/app/routers/accounts.py`, `database.py`, `create_doctor_dialog.dart`, `admin-dashboard/src/pages/DoctorsPage.jsx` | **Phase 1 & 4** |
| **#9** | Mandatory patient fields + **Profile 404 (Screenshot 2)** + sequential error dialogs | `doctor_home_screen.dart:644–747,872–933`, `failure.dart:107–108`, `patient_file_screen.dart:141–144`, `care.py:58–62,146–149` | **Phase 4** |
| **#10** | Messaging: "دار الرعاية" meaning + 1-on-1 & group chats (Patient/Caregiver/Doctor) | `mobile/lib/features/shared/clinical_messages_screen.dart:411`, `backend/app/routers/messages.py`, `database.py:382–410`, `20260904_06_messages.py` | **Phase 5** |
| **#11** | Medication role separation (Patient cannot add; adherence/taken only for Patient) | `mobile/lib/features/patient/medication_screen.dart:307–360,413–480`, `backend/app/routers/prescriptions.py`, `medication_service.dart` | **Phase 6** |
| **#13** | 12-hour clock (`ص`/`م`) app-wide + meal/period medication scheduling | `mobile/lib/core/utils/time_ago.dart:54`, `account_sessions_screen.dart:141`, `medication_screen.dart`, `app_state.dart` | **Phase 3 & 6** |
| **#14** | Doctor Event Review screen clinical purpose & redesign | `mobile/lib/features/doctor/adjudication_screen.dart:42–120`, `backend/app/routers/clinical.py`, `database.py:265–290` | **Phase 5** |
| **#15** | Doctor title `"د."`/`"الدكتور"` everywhere + **Biometric Toast (Screenshot 3)** | `patient_settings_screen.dart:575,603,783`, `account_screen.dart:126`, `MainActivity.kt`, `AndroidManifest.xml`, `biometric_service.dart:187` | **Phase 4 & 6** |
| **#16** | Login once for app lifetime until explicit logout | `mobile/lib/services/auth_service.dart:23–33`, `token_provider.dart:131–184,230`, `backend/app/auth.py:36,69` | **Phase 2** |
| **#17** | Login Sessions & Devices failure — **"تعذر تأكيد حالة الجلسات" (Screenshot 4)** | `account_sessions_screen.dart:26,51–62,128,181`, `backend/alembic/versions/20261114_09_account_sessions.py`, `auth.py:151` | **Phase 1 & 2** |
| **#18** | Accounts created today disappear the next day | `render.yaml:13–19`, `backend/app/database.py:430–498`, `backend/app/settings.py:37,91`, `supabase_complete_production_schema.sql:328` | **Phase 1** |
| **#19** | Patient & Caregiver bound to one device while logged in | `mobile/pubspec.yaml`, `mobile/lib/services/api_client.dart`, `backend/app/database.py:92–103`, `accounts.py:254–305` | **Phase 1 & 2** |
| **#20** | Dark/Light theme consistency across all screens | `mobile/lib/core/theme/app_theme.dart`, `app_colors.dart`, **587** color literals (**139** theme-breaking across 19 screens), `AnimatedTheme` | **Phase 6** |

---

## 2. Executive Diagnosis & Systemic Root Causes

1. **Infrastructure Ephemerality & Schema Drift (Points #17, #18)**:
   - `render.yaml` declares `DATABASE_URL` with `sync: false`. Without `DATABASE_URL` configured in the Render dashboard, `backend/app/database.py:450–454` silently falls back to `sqlite:///data/epilepsy.db` on Render's **ephemeral container filesystem**. Free-tier Render web services spin down after 15 minutes of inactivity and destroy local disk state on wake/redeploy, wiping all created doctor/patient/caregiver accounts by the next day.
   - `backend/deploy/supabase_complete_production_schema.sql` stops at Alembic revision `20260904_06` (line 328), missing `20261028_07_integrity.py`, `20261113_08_care_records.py`, and `20261114_09_account_sessions.py`. Furthermore, existing deploy SQL has **0 RLS policies** and ships a hardcoded default `'admin'` bcrypt hash (`lines 309–324`).
2. **State-Router Pointer Equality Crash — Screenshot 1 (Point #5)**:
   - `mobile/lib/main.dart:222` checks `if (identical(owner, _sessionOwner) && origin == _sessionOrigin) return;`. Because `AppUser` is immutable, `auth.addDoctorPatient` (`auth_service.dart:200`) creates a new `AppUser` instance with updated `linkedPatientIds`. Pointer equality fails (`false`), triggering `pushNamedAndRemoveUntil(Routes.doctor, (_) => false)` (`main.dart:234`), which resets the stack to a single root route. `AddPatientDialog._submit()` (`doctor_home_screen.dart:735`) then executes `Navigator.pop(context, true)`, popping the sole remaining route and rendering an **empty black canvas**. In total, **31 `AppUser` `identical()` checks** exist across `mobile/lib/` (out of 33 total `identical()` calls).
3. **Android Biometric Host Misconfiguration & Unformatted Titles — Screenshot 3 (Point #15)**:
   - Screenshot 3 (`mobile/lib/features/patient/patient_settings_screen.dart:575, 783`) exposes two combined bugs:
     1. `mobile/android/.../MainActivity.kt` extends `FlutterActivity` instead of `FlutterFragmentActivity` (required by `local_auth: ^3.0.2`), and `AndroidManifest.xml` omits `USE_BIOMETRIC`. `BiometricService.authenticate()` (`biometric_service.dart:187–205`) swallows the resulting `PlatformException` and returns `false`, displaying `"لم يتم التحقق من البصمة عبر المستشعر"`.
     2. Line `783` renders `'${user.name} ($roleName)'` (`"مطهر (طبيب)"`) without applying a doctor title prefix `"د."` / `"الدكتور"`.
4. **Sequential Creation Errors & Unhandled 404 — Screenshot 2 (Point #9)**:
   - `PatientFileScreen._load()` (`patient_file_screen.dart:141`) calls `app.care.clinicalNotesFor(pid, refreshRemote: app.apiOnline)` unguarded inside an outer `try-catch`. Any HTTP 404 from `backend/app/routers/care.py:58–62` maps to `FailureKind.notFound` (`failure.dart:107`) -> `"العنصر المطلوب غير موجود."` (Screenshot 2), aborting the whole screen.
   - During `AddPatientDialog` submission, a Render cold-start timeout displays a server error on Attempt 1 even though the PostgreSQL transaction committed. Attempt 2 resends the same username without an `idempotency_key`, receives **HTTP 409 Conflict**, and `failure.dart:108` maps `409 => FailureKind.validation` (*"بعض البيانات غير مكتملة أو غير صحيحة"*).
5. **Session Wipe, Self-Revocation 401 & Missing Device Binding — Screenshot 4 (Points #16, #17, #19)**:
   - `AuthService.init()` (`auth_service.dart:23–33`) explicitly wipes `currentUser = null` and clears `prefs` on every cold launch, and `TokenProvider.cachedSessionContext()` (`token_provider.dart:230–238`) invalidates cached context after the 60-minute access JWT expires.
   - `AccountSessionsScreen._revoke()` (`account_sessions_screen.dart:128`) calls `_load()` even after self-revocation, sending the revoked token and receiving HTTP 401 (`auth.py:151`), displaying Screenshot 4's error card (`line 182`).
   - `account_sessions` lacks `device_id`, and `device_info_plus` (>= 4.0.0) no longer provides `androidId`, requiring a secure persisted installation UUID strategy.

---

## 3. Deep Technical Specifications by Point (1–11, 13–20)

### Point #1: Offline Login Behavior & Graceful Offline Access
- **Affected Files**: `mobile/lib/providers/app_state.dart:705, 787–799`, `mobile/lib/services/auth_service.dart`, `mobile/lib/services/token_provider.dart:153–160`, `mobile/lib/services/local_database.dart`, `mobile/lib/features/auth/login_screen.dart`.
- **Root Cause**: `AppState.signInWithPassword()` clears `api.tokens.clear()` at line 705 **before** attempting any network call. When offline (`SocketException` / timeout), lines `787–799` only permit hardcoded demo credentials (`doctor`/`patient`/`caregiver`/`admin`) when `AppConfig.demoMode` is active; real accounts get signed out and hit `FailureKind.offline`.
- **Solution**:
  1. Remove premature `await api.tokens.clear()` at `app_state.dart:705`; only clear tokens after confirmed 401/403 rejection or explicit user switch.
  2. Create encrypted SQLCipher table `user_credentials` storing `(user_id, username_lower, role, salt, pbkdf2_hash, profile_json, updated_at)` on every successful online login.
  3. On network/timeout exception during login, verify password locally via PBKDF2-HMAC-SHA256 against `user_credentials`. If verified, restore user + local SQLite patients/meds/notes/contacts, set `AppState.isOfflineWorkspace = true`, enable local ONNX edge monitoring and emergency SMS (`EmergencySmsService`), and show an amber status banner: *"وضع عدم الاتصال — يتم العمل على البيانات المحلية وستتم المزامنة تلقائياً عند عودة الشبكة"*.
  4. If the account has never logged in online on this device, display an accurate actionable message (*"يرجى الاتصال بالإنترنت لتسجيل الدخول لأول مرة على هذا الجهاز"*).

---

### Point #2: Single Unified Hardware Simulator Standing In for Physical Devices
- **Affected Files**: `partners/hardware-sim/sim_client.py`, `backend/app/routers/device.py:107, 240`, `mobile/lib/services/monitoring_service.dart`, `mobile/lib/services/signal_simulator.dart`, `mobile/lib/features/patient/device_link_screen.dart`.
- **Root Cause**: Ingestion is coupled directly to `SignalSimulator` or HTTP polling (`POST /device/ingest`, `GET /device/status/{patient_id}`, `POST /simulate/stream`). Furthermore, `backend/app/routers/device.py` declares `@router.get("/contract")` **twice** (at line `107` and line `240` — FastAPI silently shadows the schema).
- **Solution**:
  1. Remove duplicate `@router.get("/contract")` at `device.py:240` so line `107` serves the canonical contract.
  2. Introduce a single polymorphic interface `IEegHardwareDevice` in `mobile/lib/services/eeg_hardware_device.dart`:
     ```dart
     abstract class IEegHardwareDevice {
       String get deviceId;
       bool get isSimulated;
       Stream<EegPacket> get packetStream;
       Stream<DeviceConnectionState> get connectionStateStream;
       Future<void> connect();
       Future<void> disconnect();
       Future<DeviceDiagnostics> getDiagnostics();
     }
     ```
  3. Implement **one unified `SoftwareEmulatorEegDevice`** now (consuming the Render/local simulator HTTP/planned WS stream with deterministic offline synthetic rhythm fallback), and leave clean adapter interfaces/stubs for future `BleEegHardwareDevice` and `UsbSerialEegHardwareDevice` **without** adding unused BLE/USB packages to `mobile/pubspec.yaml` prematurely.
  4. Route `MonitoringService`, `EdgeModelService`, and UI charts exclusively through `IEegHardwareDevice` + a background Isolate ring-buffer for 256Hz cadence, so future physical headbands plug in with zero UI or inference redesign.

---

### Point #3: Server Connection Latency & Render Bottlenecks
- **Affected Files**: `mobile/lib/services/api_client.dart:185, 266, 342–380`, `mobile/lib/providers/app_state.dart`, `backend/app/database.py:475–498`, `backend/app/routers/cloud_dataset.py:99`.
- **Root Cause**:
  1. Render free-tier instances sleep after 15 minutes idle and take **50–90 seconds** for cold start, while Flutter timeouts are `8–15s`, causing premature failures.
  2. `AppState.cloudSync()` pushes pending readings sequentially (`for` loop over `POST /cloud/sync`), creating hundreds of HTTP round trips.
  3. Frequent uncached `api.health()` calls add extra latency.
  4. **Pooler Alignment (`psycopg` 3 + Supabase)**: `backend/requirements.txt` uses **`psycopg[binary]>=3.1,<4.0`** (synchronous `postgresql+psycopg://`, NOT `asyncpg`). On Supabase Transaction Pooler (`port 6543`), stacking a client `QueuePool` causes connection exhaustion/broken sockets, and `psycopg` 3 prepared statements fail in PgBouncer transaction mode unless `prepare_threshold` is disabled.
- **Solution**:
  1. **Database Pooling (`backend/app/database.py:_create_engine()`)**:
     - If `DATABASE_URL` targets Supabase Transaction Pooler (`:6543` or `pooler.supabase.com`), configure **`poolclass=NullPool`** and **`connect_args={"prepare_threshold": None}`** (disables server-side prepared statements in `psycopg` 3).
     - If targeting direct PostgreSQL / Session mode (`:5432`), use `QueuePool(pool_size=10, max_overflow=10, pool_pre_ping=True, pool_recycle=300)`.
  2. **Cold-Start Tolerant Retry (`ApiClient`)**: Add bounded exponential backoff (`2s, 5s, 12s, 25s`, ceiling `90s`) for idempotent `GET`s and `idempotency_key`-protected `POST`s on `502/503/504`/connect timeouts, showing a reassuring *"جاري إيقاظ الخادم السحابي..."* indicator instead of failing.
  3. **Batch Sync Endpoint**: Add `POST /cloud/sync-batch` in `backend/app/routers/cloud_dataset.py` (matching unprefixed `POST /cloud/sync`) accepting up to 500 readings/assessments/alerts/intake logs in a single atomic transaction.
  4. **Health Probe Cache**: Add a 15-second TTL cache for `api.health()`.

---

### Point #4: Home Dashboard Workflows & Responsiveness (All 4 Roles)
- **Affected Files**: `patient_home_screen.dart` (2,191 lines), `doctor_home_screen.dart` (1,234 lines), `caregiver_home_screen.dart`, `admin_home_screen.dart`, `workspace_scaffold.dart`.
- **Root Causes & Fixes**:
  1. **Patient (`patient_home_screen.dart`)**:
     - `_DashboardTab` (`line 373`) nests an **inner `Scaffold`** with no `drawer`, breaking `_DashboardTopHeader` (`line 385`) `Scaffold.maybeOf(context)?.openDrawer()`. **Fix**: Remove the inner `Scaffold`; rely on the single outer `WorkspaceScaffold`.
     - `_SeizureProbabilityCard` (`lines 706–712`) fabricates fake probabilities (`0.88`, `0.45`, `0.12`) when `latestPrediction == null`. **Fix**: Display an explicit *"جاري المعايرة / لا توجد قراءات بعد"* state whenever `probability == null`.
     - `_PastelQuickActionsRow` (`line 418`) overflows horizontally on `<360dp` screens or high text scale. **Fix**: Refactor to responsive `Wrap` / `LayoutBuilder` grid and split the 2,191-line monolith into modular files.
  2. **Doctor (`doctor_home_screen.dart`)**:
     - `_load()` (`lines 94–116`) executes $4N$ sequential SQLite queries (`assessmentsFor`, `alertsFor`, `adjudicatedAlertIds`, `adherence`) in a loop, freezing the UI frame rate, and centers an `850px` column on wide Windows screens.
     - **Fix**: Replace with a single aggregated SQLite query + `GET /doctor/dashboard-summary`; render a responsive **2-pane Master-Detail layout** on desktop (`width >= 900dp`: patient roster left, selected patient summary/EEG right) with badge counters (pending reviews, sub-80% adherence, critical alerts).
  3. **Caregiver (`caregiver_home_screen.dart`)**:
     - Tab switches and patient opens push repeated routes (`Navigator.push`) and lack direct medication adherence cards. **Fix**: Adopt `WorkspaceScaffold` + `IndexedStack`, add read-only medication adherence progress + 1-tap emergency dial + live location timestamp (`12h`).
  4. **Admin (`admin_home_screen.dart`)**:
     - Conflicting dual navigation: `DefaultTabController` + `TabBar` (`lines 554–579`) nested inside `WorkspaceScaffold`'s `NavigationRail`. **Fix**: Unify Admin views directly under `NavigationRail` / bottom bar sections cleanly.

---

### Point #5: Doctor Adding Patient -> Black Screen (Screenshot 1)
- **Affected Files**: `mobile/lib/main.dart:219–238`, `mobile/lib/core/router/app_router.dart:323`, `mobile/lib/services/auth_service.dart:198–209`, `mobile/lib/features/doctor/doctor_home_screen.dart:735`, plus **31 `AppUser` `identical()` comparison sites** across 19 files.
- **Root Cause**: `auth.addDoctorPatient` creates a new `AppUser` instance (`auth_service.dart:200`). `_AppOverlayState._syncSession` (`main.dart:222`) tests `identical(owner, _sessionOwner)`, gets `false`, schedules `pushNamedAndRemoveUntil(Routes.doctor, (_) => false)` resetting the `Navigator` stack to 1 route, and `AddPatientDialog._submit()` (`doctor_home_screen.dart:735`) runs `Navigator.pop(context, true)` — popping the only route and leaving **0 routes** (pure black screen).
- **Solution**:
  1. Add semantic equality helper `AppUser.sameSessionOwner(AppUser? a, AppUser? b)` (`a?.uid == b?.uid && a?.role == b?.role`).
  2. Replace all **31 `AppUser` `identical()` sites** across `mobile/lib/` (`main.dart:222,230`, `app_router.dart:323`, `session_actions.dart:66`, `admin_home_screen.dart`, `admin_links_screen.dart`, `alert_response_screen.dart`, `adjudication_screen.dart`, `patient_file_screen.dart:84`, `patient_caregivers_screen.dart`, `patient_entry_screen.dart`, `account_sessions_screen.dart:26`, `active_alert_screen.dart`, `clinical_messages_screen.dart`, `privacy_requests_screen.dart`, `message_service.dart`, `care_sync_status_card.dart`, `inactivity_watcher.dart`, `patient_location_card.dart`) with semantic owner checks — **preserving the 2 legitimate non-user `identical()` checks** in `app_router.dart:453` (`ModalRoute`) and `api_client.dart:266` (`Future` in `_healthRequests`).
  3. In `AddPatientDialog._submit()` (`doctor_home_screen.dart:735`), check `Navigator.canPop(context)` before popping and keep dialog lifecycle independent of background state updates.

---

### Point #6: Optional Email & Auto-Generated Editable Username (Doctor, Patient, Caregiver)
- **Affected Files**: `backend/app/database.py:43–66`, `backend/app/routers/accounts.py:128–165, 815`, `mobile/lib/models/models.dart`, `mobile/lib/services/auth_service.dart:130`, `mobile/lib/features/admin/create_doctor_dialog.dart`, `mobile/lib/features/doctor/doctor_home_screen.dart:673, 844`, `mobile/lib/features/patient/patient_caregivers_screen.dart`.
- **Root Cause**: `users` table lacks an `email` column (`auth_service.dart:130` copies `username` into `email`). Usernames require full manual typing, and caregiver username in `AddPatientDialog` (`doctor_home_screen.dart:673`) is hardcoded as `'cg_$patUser'` with no edit field.
- **Solution**:
  1. **Schema**: Add `email VARCHAR(255)` to `users` (Alembic 10) with partial unique index `CREATE UNIQUE INDEX uq_users_email_active ON users (LOWER(email)) WHERE email IS NOT NULL`.
  2. **Backend**: Add `email: EmailStr | None = None` to `CreateDoctorRequest`, `CreatePatientRequest`, `CreateUserRequest`, and `CreateCaregiverRequest`. Return real `email` in `public_user()` instead of faking it from `username`.
  3. **Arabic-to-Latin Auto-Username (`UsernameGenerator`)**: Implement transliteration mapping Arabic characters (e.g., `"مطهر علي"`) into clean ASCII slugs (`dr_mtahr_ali_482`, `pat_ahmed_319`, `cg_fatima_705`) rather than falling back to generic `user_482`, auto-filling the editable `TextEditingController` as the creator types the name until the creator manually edits the username field. Add an explicit editable caregiver username field in `AddPatientDialog`.

---

### Point #7 & #8: Doctor Mandatory Fields & Ministry of Health (MOH) Verification
- **Affected Files**: `backend/app/routers/accounts.py:128, 470`, `backend/app/database.py`, `mobile/lib/features/admin/create_doctor_dialog.dart`, `admin-dashboard/src/pages/DoctorsPage.jsx`.
- **Root Cause**: `CreateDoctorRequest` accepts only `username`, `name`, `password`. No `doctor_profiles` or `moh_registry` tables or verification endpoints exist.
- **Solution**:
  1. **New Tables (Alembic 10)**:
     - `doctor_profiles`: `id` PK, `user_id` UNIQUE FK -> `users(id)`, `license_number` UNIQUE NOT NULL, `specialization` NOT NULL, `hospital_affiliation` NOT NULL, `national_id` UNIQUE NOT NULL, `phone` NOT NULL, `moh_verified` BOOLEAN DEFAULT FALSE, `moh_status` VARCHAR(32), `moh_checked_at` VARCHAR(64), `moh_override_by` VARCHAR(64).
     - `moh_registry` (seeded realistic test registry representing Ministry of Health records): `license_number` PK, `national_id`, `full_name_ar`, `full_name_en`, `specialization`, `hospital_affiliation`, `status` (`active`, `suspended`, `expired`), `expiration_date`.
  2. **Mandatory Doctor Form & Flexible Regional Validation**:
     - Required fields: Full Name, Auto/Editable Username, Password (or auto-generated), **Medical License Number**, **Specialization**, **Hospital/Clinic**, **National ID/Passport**, **Phone** (flexible international/Arab format `^\+?[0-9]{8,15}$` — supporting `+967`, `+966`, etc.), and **Optional Email**.
  3. **Automated MOH Verification Flow (`POST /admin/doctors/verify-moh`)**:
     - Before final creation, Admin submits/verifies doctor data against `moh_registry`.
     - Displays clear verification result card to Admin:
       - **Case A (Accredited / موجود ومعتمد)**: Green verified badge showing MOH name, specialty, status `active`, and expiry -> Admin can **[إكمال الإنشاء]** or **[إلغاء العملية]**.
       - **Case B (Not Found / Suspended / Mismatch / غير موجود أو غير معتمد)**: Warning card showing exact MOH status (`غير مسجل في بيانات وزارة الصحة` / `الترخيص منتهي أو موقوف`) -> Admin can still explicitly choose **[إلغاء العملية]** OR **[إكمال الإنشاء على مسؤولية المدير]** (persisting `moh_verified=False`, `moh_override_by=admin_id` in `audit_logs` & `doctor_profiles`).

---

### Point #9: Patient Mandatory Fields, Sequential Error Dialogs & Profile 404 (Screenshot 2)
- **Affected Files**: `mobile/lib/features/doctor/doctor_home_screen.dart:644–747, 872–933`, `mobile/lib/core/errors/failure.dart:107–108`, `mobile/lib/features/doctor/patient_file_screen.dart:141–144`, `backend/app/routers/accounts.py:134–150, 719–766`, `backend/app/routers/care.py:58–62, 146–149`.
- **Root Causes**:
  1. `AddPatientDialog` hides `phone`, `age`, `diagnosis`, `notes` under an `"اختيارية"` `ExpansionTile` (`line 872`), and omits `gender` and `emergency_contact`.
  2. **Sequential Dialogs**: Attempt 1 times out during Render spin-down (`_error = errServer` / timeout) while the backend commits the patient row; Attempt 2 retries with the same username, backend throws **HTTP 409**, and `failure.dart:108` maps `409 => FailureKind.validation` (*"بعض البيانات غير مكتملة أو غير صحيحة"*).
  3. **Screenshot 2 (`"العنصر المطلوب غير موجود"`)**: `PatientFileScreen._load()` calls `clinicalNotesFor()` at line `141` outside `try-catch`. If `care_records` is missing or the backend returns 404 (`care.py:62`), `failure.dart:107` aborts the entire patient profile view.
- **Solution**:
  1. **Mandatory Patient Creation Form**: Promote `age` (0–130), `gender` (`ذكر` / `أنثى`), `phone` (`^\+?[0-9]{8,15}$`), `emergency_contact`, and `diagnosis` to visible required fields (with `email` optional) in `AddPatientDialog` and `CreatePatientRequest`.
  2. **Idempotency & Accurate Error Mapping**:
     - Generate a form-scoped UUID `idempotency_key` when opening `AddPatientDialog`; send it on `POST /doctor/patients` and deduplicate server-side in `users_store` (returning HTTP 200 with the existing patient on identical retry instead of 409).
     - Add `FailureKind.conflict` in `failure.dart` mapping HTTP **409** to *"اسم المستخدم أو البريد مسجل مسبقاً، يرجى تعديله"* instead of `FailureKind.validation` (422).
  3. **Fix Screenshot 2**: Guard `clinicalNotesFor` in `patient_file_screen.dart:141` inside `try-catch` falling back to cached SQLCipher notes; ensure `care_records` migration `20261113_08` is deployed on Supabase; and return `[]` in `care.py:149` for valid assigned patients with zero notes.

---

### Point #10: Messaging & "دار الرعاية / دائرة الرعاية" Clarification & Chat Topologies
- **Affected Files**: `mobile/lib/features/shared/clinical_messages_screen.dart:411`, `mobile/lib/services/message_service.dart:32`, `mobile/lib/models/message_model.dart:25`, `backend/app/routers/messages.py:17–79`, `backend/app/messages_store.py`, `backend/app/database.py:382–410`, `backend/alembic/versions/20260904_06_messages.py`.
- **Clarification ("ما هو دار الرعاية؟")**:
  - In `clinical_messages_screen.dart:411`, the label is **"دائرة الرعاية"** (*Care Circle* — often misread as "دار الرعاية"), representing the **patient's home care circle** (Patient + Linked Family Caregiver(s) + Attending Doctor), **NOT** an elderly nursing home institution.
- **Root Cause**: `messages` table enforces `CHECK (channel_type IN ('doctor_patient', 'family_patient'))`, `messages.py:18` rejects any other channel, and there is no `peer_user_id` column to target a specific 1-on-1 caregiver vs the full care group.
- **Solution — 4 Complete Topologies**:
  1. Expand `messages` schema (Alembic 10):
     - Drop/replace `ck_messages_channel_type` -> `CHECK (channel_type IN ('doctor_patient', 'patient_caregiver', 'doctor_caregiver', 'care_team_triage', 'family_patient'))`
     - Add `peer_user_id VARCHAR(64) NULL` (for 1-on-1 caregiver threads) and `delivered_at VARCHAR(64) NULL` (keeping existing `read_at VARCHAR(64)`).
  2. **Supported Channels & Permissions**:
     - `doctor_patient`: Private 1-on-1 Doctor ↔ Patient (caregivers blocked with HTTP 403).
     - `patient_caregiver` (`peer_user_id = caregiver_id`): Private 1-on-1 Patient ↔ specific linked Caregiver.
     - `doctor_caregiver` (`peer_user_id = caregiver_id`): Private 1-on-1 Doctor ↔ specific linked Caregiver.
     - `care_team_triage` / upgraded `family_patient` (`peer_user_id IS NULL`): **Full Group Chat** uniting Patient + all linked Caregivers + Attending Doctor.
  3. Update `clinical_messages_screen.dart` with clear Arabic channel titles, explanatory tooltip (*"دائرة الرعاية تجمع المريض ومرافقيه وطبيبه المعالج لمتابعة الحالة"*), delivery/read ticks, and real-time sync.

---

### Point #11: Medication Management Role Segregation
- **Affected Files**: `mobile/lib/features/patient/medication_screen.dart:307–368, 413–480`, `mobile/lib/features/doctor/patient_file_screen.dart:824`, `mobile/lib/services/medication_service.dart`, `backend/app/routers/prescriptions.py`, `backend/app/database.py:319–332`.
- **Root Cause**:
  1. `MedicationScreen` exposes AppBar `+` (`line 307`), FAB `إضافة دواء` (`line 319`), and `_addOrEdit` (`line 349`) to **patients**, while exposing `_AdherenceSection` (`shareWithDoctor` button at `line 473`) and `_TodaySection` (`onTaken` dose logging at `line 359`) to **doctors**.
  2. **Storage & Sync Disconnect**: `prescriptions.py` writes prescriptions inside `patients.profile_json` (`cloud_store`), whereas `database.py:319` defines a separate SQL `prescriptions` table (unused by router). Patient dose logs (`medication_logs` in local SQLCipher) are **never pushed to backend**, leaving doctor adherence at 0%.
- **Solution**:
  1. **Strict Role UI Segregation in `MedicationScreen`**:
     - **Doctor (`isDoctor`)**: Sees prescribed medications, add/edit/pause/cancel buttons (`POST/PATCH/DELETE /doctor/patients/{id}/prescriptions`), and read-only adherence analytics. **Hide** `"تناولته"` / `onTaken` action and **hide** `"مشاركة نسبة الالتزام"`.
     - **Patient (`isPatient`)**: **Hide** AppBar add icon, FAB `"إضافة دواء"`, and edit/delete actions completely; display synced doctor prescriptions, today's schedule, `"تناولته"` button, personal adherence %, and `"مشاركة نسبة الالتزام مع الطبيب"`.
     - **Caregiver (`isCaregiver`)**: Read-only adherence & schedule view + `"إرسال تذكير بالجرعة"` action.
  2. **Unified Backend Storage & Dose Sync**: Create `medication_logs` table (Alembic 10), add `POST /patient/prescriptions/{rx_id}/intake-log` & `GET /doctor/patients/{patient_id}/adherence` in `prescriptions.py`, reconcile `prescriptions` SQL table with `cloud_store`, and sync prescriptions down & intake logs up via SQLCipher outbox.

---

### Point #13: 12-Hour Clock System (`ص`/`م`) & Meal/Period Medication Scheduling
- **Affected Files**: `mobile/lib/core/utils/time_ago.dart:52–62`, `mobile/lib/features/shared/account_sessions_screen.dart:141–144`, `mobile/lib/features/patient/medication_screen.dart`, `mobile/lib/providers/app_state.dart`, `backend/app/routers/prescriptions.py`.
- **Root Cause**:
  - `TimeAgo.clock()` (`time_ago.dart:54`) formats raw `HH:mm` (24-hour), and `account_sessions_screen.dart:143` prints raw `date.toLocal().toString()`.
  - Medication schedules use raw `"HH:mm"` strings without period/meal clinical context, and reminders are pumped from `monitoring.onUpdate` (failing silently whenever the EEG stream is stopped).
- **Solution**:
  1. **App-Wide 12-Hour Formatter (`TimeAgo.clock12h`)**: Standardize all timestamps, charts, alerts, messages, sessions, and schedules across `mobile/lib/` using `DateFormat.jm('ar')` / explicit 12h formatter (`ص` / `م` in Arabic, `AM` / `PM` in English) and configure `MediaQueryData(alwaysUse24HourFormat: false)` on time pickers.
  2. **Intuitive Doctor Meal & Period Selector**: Add structured fields to prescriptions (`period_context`: `'morning'` صباحاً / `'noon'` ظهراً / `'evening'` مساءً / `'bedtime'` قبل النوم; `meal_context`: `'before_meal'` قبل الوجبة / `'with_meal'` مع الوجبة / `'after_meal'` بعد الوجبة / `'independent'` غير مرتبط بوجبة; `meal_type`: `'breakfast'` الإفطار / `'lunch'` الغداء / `'dinner'` العشاء), presenting quick preset chips for doctors and clear Arabic phrasing for patients (e.g., `"8:00 صباحاً — بعد وجبة الإفطار"`).
  3. **Decoupled OS Alarms (`flutter_local_notifications`)**: Add `flutter_local_notifications` to `mobile/pubspec.yaml`, configure Android 13+/14+ `SCHEDULE_EXACT_ALARM` / `POST_NOTIFICATIONS` and Windows desktop AUMID notifications, store schedule slots in UTC + local timezone offset, and recalculate alarms independently of `monitoring.onUpdate`.

---

### Point #14: Doctor Event Review Screen (`AdjudicationScreen`) Purpose & Redesign
- **Affected Files**: `mobile/lib/features/doctor/adjudication_screen.dart:42–260`, `backend/app/routers/clinical.py`, `backend/app/outcomes_store.py`, `backend/app/database.py:265–290`.
- **Clinical Utility Answer ("ما فائدة صفحة مراجعة الأحداث وكيف يستفيد منها الدكتور؟")**:
  - The AI model triggers seizure/pre-ictal alerts automatically, which inevitably include false alarms caused by movement/muscle artifacts. **Event Review is the clinical validation & diagnosis workspace** where the neurologist inspects the raw evidence of each flagged alert, confirms true seizures vs non-epileptic artifacts, classifies seizure semiology, updates the patient's clinical record/treatment plan, and measures real-world false-alarm rates (without auto-retraining the frozen model).
- **Current Gaps & Solution**:
  - Currently displays only patient name, timestamp, and severity text with 3 basic radio options (`valid`/`invalid`/`uncertain`).
  - **Redesign**: Embed 4-channel `SignalChart` (`10s` pre-event & post-event window with zoom/pan), AI probability gauge, episode duration, synchronized HR & motion telemetry, structured seizure type classification (`Generalized Tonic-Clonic`, `Focal`, `Absence`, `Atonic`, `Artifact`), artifact cause tags (`Muscle`, `Electrode Pop`, `Motion`), and clinical action notes.
  - **Concurrency Guard**: Add `UNIQUE(patient_id, alert_id)` + `version INTEGER DEFAULT 1` to `outcomes` for optimistic locking so concurrent mobile/web reviews cannot silently overwrite each other.

---

### Point #15: Doctor Title Formatting (`"د."` / `"الدكتور"`) + Android Biometrics Fix (Screenshot 3)
- **Affected Files**: `mobile/lib/features/patient/patient_settings_screen.dart:575,603,783`, `mobile/lib/features/shared/account_screen.dart:126`, `mobile/lib/features/doctor/doctor_home_screen.dart`, `mobile/lib/features/patient/patient_file_screen.dart`, `mobile/lib/features/shared/clinical_messages_screen.dart`, `mobile/android/.../MainActivity.kt`, `mobile/android/app/src/main/AndroidManifest.xml`, `mobile/lib/services/biometric_service.dart:187–205`.
- **Solution**:
  1. Create `DoctorTitleFormatter.format(String? name, {UserRole? role, bool formal = false, bool isArabic = true})` stripping duplicate prefixes (`د.`, `دكتور`, `الدكتور`, `Dr.`) idempotently before prepending `'د. '` or `'الدكتور '` (or `'Dr. '`). Apply everywhere doctor names appear (Home, Account, Settings, Biometric Toast, Patient File, Prescriptions, Chat).
  2. Fix Screenshot 3 Biometric failure: Change `MainActivity.kt` from `FlutterActivity` to **`FlutterFragmentActivity`**, add `<uses-permission android:name="android.permission.USE_BIOMETRIC"/>` to `AndroidManifest.xml`, and expose specific error feedback in `BiometricService.authenticate()` (no hardware vs not enrolled vs user cancelled) instead of swallowing `PlatformException`.

---

### Point #16: Persistent Single Login for App Lifetime
- **Affected Files**: `mobile/lib/services/auth_service.dart:23–33`, `mobile/lib/services/token_provider.dart:131–250`, `backend/app/auth.py:36, 69`, `backend/app/settings.py:64`.
- **Root Cause**: `AuthService.init()` (`line 25`) explicitly sets `currentUser = null` and clears `prefs` on every startup. `TokenProvider.cachedSessionContext()` (`line 236`) rejects restoration once the 60-minute JWT expires (`JWT_EXPIRE_MINUTES=60`).
- **Solution**:
  1. Remove startup wipe in `AuthService.init()`; restore cached authenticated context from `FlutterSecureStorage` on cold boot.
  2. Separate short-lived access JWT (60 min) from **sliding long-lived `account_sessions`** (e.g., 365-day sliding expiration refreshed on `/auth/refresh`), so `cachedSessionContext()` restores offline/cold-boot sessions as long as the session is not explicitly logged out or revoked.
  3. Add a single-flight `Completer<bool>` mutex in `TokenProvider._refreshTokenRaw()` to eliminate **thundering-herd token refresh races** when multiple dashboard widgets initialize simultaneously.
  4. Only clear tokens and route to `LoginScreen` on explicit `signOut()` or verified backend HTTP `401` (`session revoked/disabled`).

---

### Point #17: Login Sessions & Devices Screen Error (Screenshot 4)
- **Affected Files**: `mobile/lib/features/shared/account_sessions_screen.dart:26, 51–62, 128, 181`, `backend/alembic/versions/20261114_09_account_sessions.py`, `backend/app/auth.py:151`.
- **Root Causes**:
  1. `account_sessions` migration `20261114_09` was missing from `supabase_complete_production_schema.sql`, causing HTTP 500 on `GET /auth/sessions`.
  2. Revoking the current session at `line 128` calls `_load()`, sending the revoked JWT and failing with HTTP 401 (`"تعذر تأكيد حالة الجلسات"`).
  3. `line 26` uses `identical(_app.auth.currentUser, _owner)` and `line 143` formats timestamps in 24h raw strings.
- **Solution**: Apply migration `09` to Supabase; if revoked row has `current == true`, clear local tokens and navigate directly to `LoginScreen` without calling `_load()`; switch `line 26` to semantic `uid/role` check; format timestamps in 12h AM/PM.

---

### Point #18: Accounts Disappearing the Next Day (Render & Supabase Persistence)
- **Affected Files**: `render.yaml:13–19`, `backend/app/database.py:430–498`, `backend/app/settings.py:37, 91–110`, `backend/deploy/supabase_complete_production_schema.sql:309–329`.
- **Root Cause**: Render free tier has an ephemeral disk (`render.com/docs/free`). Because `render.yaml` has `DATABASE_URL` `sync: false`, unconfigured deploys fall back to local `sqlite:///data/epilepsy.db` (`database.py:454`), wiping all accounts whenever Render spins down after 15 minutes idle.
- **Solution**:
  1. Set `DATABASE_URL` in Render Environment Variables to Supabase Connection Pooler (`port 6543`, `?sslmode=require`) with `NullPool` + `prepare_threshold=None`, and run Alembic migrations via Direct `port 5432` (or `NullPool`).
  2. Update `backend/app/settings.py:validate_production_settings()` to **fail fast** (`raise RuntimeError`) if `settings.is_production` (`APP_ENV=production`) and `is_sqlite_url(database_url())`.
  3. Realign `supabase_complete_production_schema.sql` through Alembic `07`, `08`, `09`, `10`, enable **Row Level Security (`ENABLE ROW LEVEL SECURITY`)** on all tables, and remove the hardcoded `'admin'` bcrypt hash at `lines 309–324`.

---

### Point #19: Single-Device Binding for Patient & Caregiver Accounts
- **Affected Files**: `mobile/pubspec.yaml`, `mobile/lib/services/api_client.dart`, `backend/app/database.py:92–103`, `backend/app/routers/accounts.py:254–305`.
- **Root Cause**: `account_sessions` lacks `device_id` and `is_hardware_bound`. Per official `pub.dev` docs for `device_info_plus` (>= 4.0.0), **`androidId` was removed** for Google Play Store privacy compliance — relying on `androidInfo.id` alone returns build fingerprint instead of a unique device identifier.
- **Solution**:
  1. Generate and store a persistent cryptographically random `device_installation_id` UUID inside `FlutterSecureStorage` (backed by Android Keystore / Windows DPAPI), paired with `device_info_plus` hardware model for human-readable `device_name` (and `windowsInfo.deviceId` on Windows).
  2. Add `device_id VARCHAR(128)` and `is_hardware_bound BOOLEAN DEFAULT FALSE` to `account_sessions` (Alembic 10).
  3. On `POST /auth/login` for `patient` and `caregiver`, check existing active non-revoked sessions with a different `device_id`: enforce **Option A — Strict Block** (HTTP 409 Conflict until explicit logout on the bound device, or Admin force-revoke if the bound device is lost/damaged). Clear device binding cleanly on `/auth/logout`.

---

### Point #20: Dark / Light Theme Consistency & Photosensitive Safety
- **Affected Files**: `mobile/lib/core/theme/app_theme.dart`, `app_colors.dart`, and 19 feature files under `mobile/lib/features/**`.
- **Root Cause**: Static scan of `mobile/lib/` identified **587 total color literals** (`508` in `features/**`, `73` in `core/**`, `6` in `widgets/**`), with **139 theme-breaking literals** (`Colors.white`, `Colors.black`, `Color(0xFFF6F9FD)`, `Color(0xFF0D253C)`) across 19 screens (`account_screen.dart`, `medication_screen.dart`, `patient_home_screen.dart`, `clinical_messages_screen.dart`, etc.). Switching to Dark Mode produces illegible contrast and sudden bright flashes.
- **Solution**:
  1. Replace all 139 theme-breaking color literals with semantic `Theme.of(context).colorScheme` / `Theme.of(context).cardTheme.color` / `AppColors.of(context, ...)` tokens.
  2. Enforce **WCAG AA ≥ 4.5:1** contrast in both `AppTheme.lightTheme` (`#F6F9FD` / `#FFFFFF` / `#0D253C`) and `AppTheme.darkTheme` (`#101A2B` / `#172338` / `#F1F5F9`).
  3. Enforce **W3C WCAG 2.2 SC 2.3.1** (photosensitive epilepsy safety: zero components flashing > 3 times/sec, wrap theme switches in `AnimatedTheme` honoring `MediaQuery.disableAnimations`, eliminate white FOUC flashes during route transitions).

---

## 4. System-Wide Secondary Edge Cases Identified

| Edge Case | Trigger | Risk | Defense |
|---|---|---|---|
| **Thundering-Herd Token Refresh** | 4 home tabs fire requests simultaneously as 60m access token expires | Concurrent refresh calls rotate/collide -> 401 -> accidental logout | Single-flight `Completer<bool>` mutex in `TokenProvider` |
| **AED Pharmacokinetic Shift (DST/TZ)** | Device crosses timezones or DST changes | Medication reminder fires 1h off schedule | Store UTC/offset schedule + recalculate local alarms on TZ change |
| **Offline Outbox Burst** | Multi-day offline EEG & intake logs synced together | Sequential loop exhausts connections or drops records | Atomic transactional `POST /cloud/sync-batch` (500/batch) + outbox cursor |
| **High-Rate 256Hz UI Freeze** | Emulator/BLE streams while UI rebuilds or backend cold-starts | Circular buffer drops packets or causes false AI alerts | Decouple `IEegHardwareDevice` ingestion into background Isolate |
| **Concurrent Adjudication Race** | Two doctors adjudicate same alert simultaneously (mobile + web) | Silent last-write-wins overwrite | `UNIQUE(patient_id, alert_id)` + `version` optimistic lock on `outcomes` |
| **Photosensitive Flash (FOUC)** | Unstyled white route scaffold flashes before Dark Theme applies | > 3Hz luminance shock hazard for photosensitive epilepsy | Root `AnimatedTheme` + matte dark `LaunchTheme` & scaffold defaults |

---

## 5. Phased Execution Roadmap (Zero Regressions)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ [COMPLETED & VERIFIED] Phase 1: Supabase Schema, Pooling & Persistence   │
│ • Applied Alembic 07/08/09 + new 10 (email, doctor_profiles, moh_registry│
│   device_id, message channels/peer, medication_logs, outcomes.version)   │
│ • NullPool + prepare_threshold=None on Transaction Pooler (:6543)        │
│ • Enabled Supabase RLS policies & removed hardcoded admin hash           │
│ • Fail-fast SQLite guard in validate_production_settings() (`APP_ENV`)   │
│ ✔ Verified: Backend 231/231 tests passed; schema parity green            │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ [COMPLETED & VERIFIED] Phase 2: Lifetime SSO, Offline Login & HTTP 409   │
│ • Preserved real sessions on cold start in AuthService.init()            │
│ • Completer<bool> single-flight mutex + session context decoupling (#16) │
│ • SQLCipher v7 `user_credentials` + `PasswordHasher` offline login (#1)  │
│ • Persisted SecureStore UUID v4 + Option A strict HTTP 409 binding (#19) │
│ • Fixed AccountSessionsScreen self-revocation 401 & 12h ص/م format (#17) │
│ ✔ Verified: Backend 33/33 targeted (239 total), Mobile analyze 0 issues, │
│   Mobile flutter test 189/189 passed                                     │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Phase 3: Hardware Emulator Abstraction & Network Resilience (#2, #3, #13)│
│ • Define IEegHardwareDevice + unified SoftwareEmulatorEegDevice          │
│ • Remove duplicate @router.get('/contract') in device.py:240             │
│ • 90s cold-start retry backoff, 15s /health TTL cache, /cloud/sync-batch │
│ • Decouple medication reminders via flutter_local_notifications (TZ-safe)│
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Phase 4: Black Screen, Onboarding, MOH Verify & Home UIs (#4,#5,#6,#7,#8,#9)│
│ • Fix all 31 AppUser identical() sites (keep 2 legitimate Route/Future)  │
│ • Guard AddPatientDialog Navigator.canPop; fix PatientFileScreen 404     │
│ • Arabic->Latin auto editable usernames + optional email + idempotency   │
│ • Mandatory doctor fields + POST /admin/doctors/verify-moh (both choices)│
│ • Fix Screenshot 3 MainActivity.kt (FlutterFragmentActivity)+USE_BIOMETRIC│
│ • Fix Patient inner Scaffold/dummy prob; Doctor 2-pane summary; Admin rail│
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Phase 5: Care Circle Topologies & Event Review Redesign (#10, #14)       │
│ • Support 4 chat channels (1-on-1 patient/doctor/caregiver + care group) │
│ • Clarify "دائرة الرعاية", delivery/read receipts, real-time messaging   │
│ • Redesign AdjudicationScreen: 4-ch EEG waveforms, HR/motion, semiology  │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Phase 6: Med Segregation, 12h/Meal Schedule, Titles & Themes (#11,#13,#15,#20)│
│ • Strict Doctor vs Patient vs Caregiver MedicationScreen segregation     │
│ • Bidirectional prescription & intake-log sync                           │
│ • Global 12-hour ص/م formatter + meal/period selector + DoctorTitleFormatter│
│ • Replace 139 theme-breaking color literals + WCAG 2.2 SC 2.3.1 audit    │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Verification & Tooling Strategy

1. **Static Analysis & Quality Gates** (per [epilepsy-quality-gate](../.agents/skills/epilepsy-quality-gate/SKILL.md)):
   - Run `flutter analyze --no-pub` and `dart analyze --fatal-infos lib` inside `mobile/` (Target: **0 errors, 0 warnings, 0 infos** — verified after Phase 2), plus `flutter_dart-mcp-server` `analyze_files` / `run_tests`.
   - **SonarQube Honesty Note**: `sonar` CLI, `sonar-project.properties`, and SonarQube MCP (`mcp_config.json` empty) are currently not provisioned in this workspace. When configured per `static-analysis-and-tooling.md`, create root `sonar-project.properties` (`sonar.sources=mobile/lib,backend/app,admin-dashboard/src`) and enforce Rating A Reliability/Security. Until then, run manual security/lint audits explicitly without fabricating Sonar passes.
2. **Baseline + New Targeted Regression Tests** (Never trigger `flutter build apk`/`aab`/`windows` unless user explicitly asks):
   - Preserve and grow test suites: **189/189** Flutter tests (`flutter test --no-pub`, up from 181 baseline) and **239** FastAPI tests (up from 223 baseline; Phase 2 targeted `test_account_sessions.py` + `test_phase1_persistence.py` **33/33 passed**).
   - Add remaining targeted suites across Phases 3–6 covering: doctor patient-creation stack preservation (no black screen), patient file clinical-notes 404 fallback, medication role boundaries & intake-log sync, MOH verify + both-case admin choice, and `/cloud/sync-batch` atomicity.
3. **4-Screenshot Acceptance Checklist**:
   - **Screenshot 1**: Doctor adds patient -> returns cleanly to Doctor Home with patient listed (zero black screen) -> *Phase 4*.
   - **Screenshot 2**: Doctor opens newly created/unnoted patient file -> profile renders without `"العنصر المطلوب غير موجود"` -> *Phase 4*.
   - **Screenshot 3**: Doctor opens Settings & toggles Biometrics -> name displays `"د. مطهر"`, biometric prompt invokes native sensor cleanly on Android (`FlutterFragmentActivity`) -> *Phase 4/6*.
   - **Screenshot 4**: Any role opens `"جلسات الدخول"` -> active sessions load with 12h ص/م timestamps; revoking another session refreshes list; revoking current session cleanly signs out to `LoginScreen` -> **Resolved in Phase 2** (verified by unit/widget tests).
