# API Reference

Base URL (local): `http://127.0.0.1:8000`

## Health & operations

`GET /health` — quick status (never fails, reports the active ML engine).

```json
{ "status": "ok", "service": "epilepsy-monitoring-api", "version": "2.3.0", "engine": "sklearn" }
```

`GET /health/live` — **liveness**. Process-only; must not touch the database, or
a transient storage issue would trigger pointless restart loops.

`GET /health/ready` — **readiness**. Verifies the classifier, the device hub, and
executes a real `SELECT 1` against the database. Returns **503** with
`status: "degraded"` and an `errors` object when a dependency is unusable, so a
load balancer stops sending traffic that is guaranteed to fail.

```json
{
  "status": "ready",
  "version": "2.3.0",
  "checks": { "classifier": true, "device_hub": true, "database": true }
}
```

`GET /metrics` — **admin only** (latency and alert volumes reveal patient
activity patterns). Request/inference counters, p50/p95/max latency, and
notification-delivery health.

```json
{
  "uptime_seconds": 1842.5,
  "counters": { "inference_total": 12, "http_requests_total": 30, "http_status_2xx": 29 },
  "latency": { "inference": { "count": 12, "avg_ms": 3.4, "p50_ms": 3.1, "p95_ms": 6.2, "max_ms": 7.0 } },
  "alert_outbox": { "pending": 0, "sent": 4, "failed": 0, "dead": 0, "total": 4 }
}
```

Metrics are **in-process**: with multiple workers each reports its own numbers.
Moving to Redis or a real metrics backend is the documented upgrade path.

### Request tracing

Every response carries an `X-Request-ID` header (an inbound one is preserved), and
each request is logged as a single JSON line with `request_id`, `method`, `path`,
`status`, and `duration_ms` — so a report of "my alert failed at 10:42" maps to
one request. Set `LOG_FORMAT=text` for a human-readable local console.

## Analyze

`POST /analyze`

Request body (`VitalWindow`):

```json
{
  "timestamp": "2026-07-20T12:00:00Z",
  "eeg": [0.1, 0.2],
  "ecg": [0.5, 0.4],
  "motion": [0.01, 0.02],
  "hr": 78,
  "patient_id": "p1"
}
```

Response:

```json
{
  "label": "stable",
  "confidence": 0.91,
  "features": {
    "hr_mean": 78.0,
    "hr_std": 3.1,
    "eeg_power": 0.2,
    "eeg_peak": 0.5,
    "motion_energy": 0.05,
    "motion_variance": 0.04,
    "ecg_variability": 0.3
  },
  "processing_ms": 2.5
}
```

Labels: `stable` | `watch` | `high_risk`

## Simulate

- `POST /simulate/stream` — body `{ "pattern": "high_risk", "samples": 128, "seed": 1 }`
- `GET /simulate/window?pattern=watch&samples=128`

## Alerts

- `POST /alerts/evaluate` — analyze + build alert payload
- `POST /alerts/fcm-stub` — durably queue a notification (production uses Firebase Admin)
  - Writes to the **transactional outbox**, so a delivery failure is retried, not lost.
  - Response keeps `status: "queued"` for backwards compatibility and adds
    `outbox_id` + `delivery_status` (`pending` | `sent` | `failed` | `dead`).
- `GET /alerts/outbox?status=&limit=` — **admin only**; queued/failed notifications
  with per-status counts, so an undelivered alert is visible instead of silent.

### Alert delivery guarantees

| Property | Behaviour |
| --- | --- |
| Atomicity | The outbox row is written in the *same transaction* as the alert. |
| Retries | 5 attempts with exponential backoff (10s → 20s → 40s …, capped at 10 min). |
| Exhaustion | The row becomes `dead` and is **kept** for review — never deleted. |
| Duplicates | At-least-once: a crash after sending may redeliver. For a medical alert a duplicate is safer than a miss. |
| Idempotency | `alert_id` is UNIQUE, so a replayed ingestion cannot double-notify. |

Only alerts with `severity: "critical"` (or an explicit `shouldNotify`) are queued;
informational alerts are stored without notifying.

Worker settings: `OUTBOX_WORKER_ENABLED` (default `1`), `OUTBOX_POLL_SECONDS` (default `10`).

## Head device (graduation)

- `POST /device/ingest` — streaming samples from headband (requires Bearer token)
- `POST /device/ingest-window` — full window upload
- `GET /device/status/{patient_id}` — latest connection + assessment for the app
- `GET /device/token-info` — demo token helper

Demo token: `headband-demo-token`

في `production` لا يقبل السيرفر هذا التوكن. يسجل المدير الجهاز أولًا عبر
`POST /admin/devices`، ثم يستبدل الجهاز `device_id + patient_id + enrollment_secret`
بتوكن من `POST /auth/token`. تدوير السر أو تعطيل الجهاز يبطل التوكنات السابقة.

## Authentication and accounts

- `POST /auth/login` — username/password login for human accounts.
- `GET /auth/me` — current active account or device principal.
- `GET /admin/users` — admin account listing and filtering.
- `POST /admin/users` — create admin, doctor, patient, or caregiver.
- `POST /admin/users/{id}/disable|enable` — account lifecycle; disabling revokes sessions.
- `POST /admin/users/{id}/password` — reset password and revoke previous sessions.
- `POST /admin/assignments` / `DELETE /admin/assignments` — doctor-patient links.
- `POST /admin/caregiver-links` / `DELETE /admin/caregiver-links` — caregiver-patient links.

Patient access in production is relationship-based: patient=self, doctor=assigned,
caregiver=linked, device=registered patient, and admin=all patients.

## Registered devices

- `GET /admin/devices?patient_id=` — list devices without secret hashes.
- `POST /admin/devices` — register one device and bind it to one patient.
- `POST /admin/devices/{device_id}/secret` — rotate enrollment secret and revoke old JWTs.
- `POST /admin/devices/{device_id}/disable|enable` — revoke or restore enrollment.

The plaintext enrollment secret is returned only when the server generates it.
Stored secrets use PBKDF2 hashes and are never returned by the API.

## Clinical feedback

- `POST /patients/{patient_id}/alerts/{alert_id}/acknowledgments` — authenticated,
  patient-authorized acknowledgment with optional note.
- `GET /patients/{patient_id}/alerts/{alert_id}/acknowledgments` — independent
  acknowledgments by patient, caregiver, doctor, or admin.
- `POST /patients/{patient_id}/outcomes` — record `seizure`, `no_seizure`,
  `false_alarm`, or `unknown`, optionally linked to an assessment/alert.
- `GET /patients/{patient_id}/outcomes?limit=` — newest observed outcomes.

An assessment or alert link is accepted only when it belongs to the same patient.
These records support later false-alarm and lead-time evaluation; they do not by
themselves validate the model clinically.
