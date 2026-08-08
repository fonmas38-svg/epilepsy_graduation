# API Reference

Base URL (local): `http://127.0.0.1:8000`

## Health

`GET /health`

```json
{ "status": "ok", "service": "epilepsy-monitoring-api", "version": "1.0.0" }
```

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
- `POST /alerts/fcm-stub` — stub queue for FCM (production uses Firebase Admin)

## Head device (graduation)

- `POST /device/ingest` — streaming samples from headband (requires Bearer token)
- `POST /device/ingest-window` — full window upload
- `GET /device/status/{patient_id}` — latest connection + assessment for the app
- `GET /device/token-info` — demo token helper

Demo token: `headband-demo-token`
