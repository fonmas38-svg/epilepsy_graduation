# Alerts, location, background work and operations

Model the chain separately: event -> recipient authorization/preferences -> persistent alert/outbox -> provider acceptance -> delivery/acknowledgment -> escalation. Track and surface **caregiver online connectivity and actual alert delivery/acknowledgment status** to the patient/emergency view when online. Use stable event/recipient/channel IDs, deduplication and bounded retries. Verify quiet-hour/emergency rules rather than silently suppressing urgent events.

FCM, backend polling, Android native SMS and SMS composer are different capabilities. Check platform permissions, available SIM/subscription, service restrictions and actual send/delivery callbacks. Windows must state its capability limits. When offline, ensure emergency alerts cleanly trigger the SMS fallback path with GNSS coordinates.

GNSS works without internet via satellite broadcast signals (`forceLocationManager: true` on Android). Verify location service, permission, freshness, uncertainty and acquisition failure separately from maps/network availability. **Do not blame healthy device OS location/internet settings** when telemetry or location fails—audit and fix the app/backend state machine, timeouts, and freshness pipeline directly.

Local/cloud switching needs a single unified orchestrator state machine (`Online` ↔ `Offline`) with healthy authenticated backend checks, catch-up synchronization before stopping local fallback, and zero data loss during flapping networks.

For latency measure DNS/TLS/connect, request round trip, API processing, database time, model load/inference, polling and cold/warm states. Coalesce overlapping health probes and poll only as needed, with backoff/jitter. **Never surface technical internal cold-start/infrastructure banners (such as "جاري إيقاظ الخادم السحابي") to end users.**

Use ../vendor/render-deploy/GUIDE.md only for authorized Render deployment/configuration work; diagnostics do not authorize deploys, new paid services, hostname changes or secret rotation. Preserve the current hosting unless the user authorizes migration. External status/runtime documentation may change; verify when relevant.

## Render Free-Tier & Database Persistence Rules

Per official Render documentation and `render.yaml`:
- **15-Minute Spin-Down & Ephemeral Filesystem**: Render free web services spin down after 15 minutes with no inbound traffic and use an ephemeral local filesystem across spin-downs, restarts, and redeploys (persistent disks require paid tiers).
- **Prevent Ephemeral Account Loss**: `render.yaml` sets `DATABASE_URL` with `sync: false`. If left unset in Render Dashboard, `backend/app/database.py` falls back to `sqlite:///data/epilepsy.db`, wiping all newly created doctor, patient, and caregiver accounts on spin-down. Enforce a fail-fast startup check in `backend/app/main.py`: when `APP_ENV=production` and the resolved DB URL starts with `sqlite://`, abort startup with an explicit configuration error.
- **Cold-Start Timeout Mismatch**: Free-tier cold starts take ~50–90s while hardcoded 8–15s Flutter timeouts abort requests mid-boot. Implement bounded exponential backoff (`2s, 5s, 12s, 25s` up to 90s ceiling) for idempotent reads and `idempotency_key`-protected writes on HTTP 502/503/504 or handshake timeout, plus a 15-second TTL cache on `api.health()`.
- **Batch Offline Sync**: Replace unbatched per-reading loops (`AppState.cloudSync()`) with `POST /cloud/sync-batch` (aligning with existing unprefixed `POST /cloud/sync` in `backend/app/routers/cloud_dataset.py`; Master Plan writes `/api/v1/cloud/sync-batch`) accepting up to 500 sensor readings and medication intake logs in one atomic transaction.

## Decoupled Medication Reminders (12-Hour & Timezone-Safe)

- **Never Couple Reminders to EEG Streaming**: Triggering medication reminders inside `monitoring.onUpdate` silently fails whenever the EEG headband is idle or disconnected.
- Schedule reminders via `flutter_local_notifications` / OS alarm schedulers independent of EEG streaming:
  - Store intervals with UTC/timezone-change recalculation so anti-epileptic drug (AED) pharmacokinetic windows do not drift across DST or timezone changes.
  - On Android 13+/14+ (`pub.dev` `flutter_local_notifications`), configure `POST_NOTIFICATIONS` and handle `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` permissions (`requestExactAlarmsPermission()`) gracefully; on Windows, ensure desktop AUMID setup for Action Center notifications.

## Hardware Satellite GNSS & Automatic Location Dispatch

- **Hardware GNSS Priority**: Enforce `AndroidSettings(forceLocationManager: true, accuracy: LocationAccuracy.best)` on Android in `location_service.dart`. This bypasses Google Play Services Fused Location Provider's cellular/IP geolocation fallback, eliminating international IP transit routing bugs (such as YemenNet/regional traffic resolving to Telecom Egypt gateways in Cairo/Alexandria).
- **Inaccuracy Filtering & Fallback**: Implement accuracy thresholds (>1000m coarse, >3000m suspicious IP guess). If fresh fix has poor accuracy, check recent high-accuracy (`< 500m`, `< 30min`) satellite fixes from `Geolocator.getLastKnownPosition()`. Surface visual warning banners when Android 12+ approximate location permission is granted.
- **Automatic Dispatch on Seizure Likelihood**: Wire `_shareLocationOnAlert` and `_shareLocationOnPreAlert` into `AppState`. Immediately upon detecting early pre-ictal forecasts or confirmed seizures, the patient's coordinates and Google Maps navigation URL are automatically published to the `family_patient` channel and `ActiveAlertScreen` without requiring manual patient taps.
- **Security & Diagnostics Secrecy**: Completely remove web portal launcher from Flutter admin screens. Conceal cloud server URLs, ping status, and connectivity diagnostics behind a secret 5-tap gesture on the app logo in `login_screen.dart`.

## Android Distribution & APK Build Standard (`arm64-v8a` Priority)

- **Explicit User Command Only**: Only execute build/export commands when explicitly instructed by the user (Rule 0).
- **Architecture Priority (`arm64-v8a`)**: Always build with `flutter build apk --split-per-abi` instead of a fat universal APK:
  - Deliver `app-arm64-v8a-release.apk` (typically ~25–35 MB, compared to ~85 MB universal), targeting 99% of modern 64-bit Android smartphones for optimal performance and smaller download footprints.
- **Version Code Incrementation Rule**: Before building, inspect `mobile/pubspec.yaml` `version: x.y.z+buildNumber`. Increment the build number (+N) so Android's Package Manager recognizes the update and avoids `INSTALL_FAILED_UPDATE_INCOMPATIBLE` ("الحزمة تبدو غير صالحة").
- **Signature Mismatch Resolution**: If a user encounters "الحزمة تبدو غير صالحة" when installing an updated APK over a previous testing copy, it indicates a signing certificate mismatch (e.g. earlier debug vs release keystore). The standard protocol is to uninstall the existing app copy first, then install the new release APK.
