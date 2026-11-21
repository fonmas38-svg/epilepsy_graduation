# Alerts, location, background work and operations

Model the chain separately: event -> recipient authorization/preferences -> persistent alert/outbox -> provider acceptance -> delivery/acknowledgment -> escalation. Use stable event/recipient/channel IDs, deduplication and bounded retries. Provider acceptance is not user receipt, and an acknowledgment is not proof the patient is safe. A manual report does not automatically establish a missed prediction; record source and evidence. Verify quiet-hour/emergency rules rather than silently suppressing urgent events.

FCM, backend polling, Android native SMS and SMS composer are different capabilities. Check platform permissions, available SIM/subscription, service restrictions and actual send/delivery callbacks. A composer that requires a person to tap Send is not automatic SMS. Windows must state its capability limits. Use test adapters/recipients unless live delivery is explicitly authorized.

GNSS may work without internet and is not dependent on a special satellite SIM. Verify location service, permission, freshness, uncertainty and acquisition failure separately from maps/network availability. Display last shared fix with timestamp/accuracy and distinguish it from live tracking; inform the user when no fix is available instead of inventing coordinates. Do not promise emergency satellite/SMS capability based on phone age.

Local/cloud switching needs an explicit state machine, healthy authenticated backend, source ownership and catch-up checkpoint before stopping redundant inference. Preserve acquisition, required emergency handling and pending records; stopping all local work on internet detection is not safe synchronization. Test flapping networks, process death/background limits, battery saver and server failure during handover on actual devices before claiming continuity.

For latency measure DNS/TLS/connect, request round trip, API processing, database time, model load/inference, polling and cold/warm states. Record operation and status without secrets. Coalesce overlapping health probes and poll only as needed, with backoff/jitter. Do not infer a Render cold start merely from timeout logs or describe a /health success as model/database readiness. Never retry a timed-out creation blindly or call a larger timeout a root-cause fix.

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
