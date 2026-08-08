"""
محاكي جهاز الرأس (Headband Gateway Simulator)
---------------------------------------------
يمثل الجهاز الحقيقي الذي يُركَّب على رأس المريض ويرسل عينات EEG/ECG/Motion
إلى السيرفر عبر /device/ingest ثم يُحلّلها النموذج المدرَّب.

الاستخدام:
  python device_gateway_sim.py --patient-id patient-demo --pattern high_risk
"""
from __future__ import annotations

import argparse
import math
import random
import time

import httpx

API = "http://127.0.0.1:8000"
# Legacy fallback token; the simulator now prefers a real JWT via /auth/token.
LEGACY_TOKEN = "headband-demo-token"
ENROLL_DEVICE_SECRET = "enroll-device-demo"


def get_token(api: str, device_id: str = "headband-01") -> str:
    """Exchange the enrollment secret for a JWT; fall back to the legacy token."""
    try:
        r = httpx.post(
            f"{api}/auth/token",
            json={"subject": device_id, "role": "device",
                  "enrollment_secret": ENROLL_DEVICE_SECRET},
            timeout=5.0,
        )
        if r.status_code == 200:
            print("auth: obtained JWT via /auth/token")
            return r.json()["access_token"]
        print(f"auth: /auth/token returned {r.status_code}, using legacy token")
    except Exception as e:  # noqa: BLE001
        print(f"auth: could not reach /auth/token ({e}); using legacy token")
    return LEGACY_TOKEN


def make_batch(pattern: str, n: int = 32, hr: float = 72.0):
    samples = []
    for i in range(n):
        t = i / n * 2 * math.pi
        if pattern == "stable":
            eeg = 0.4 * math.sin(8 * t) + random.uniform(-0.1, 0.1)
            ecg = 0.8 * math.sin(5 * t) + random.uniform(-0.05, 0.05)
            motion = random.uniform(-0.15, 0.15)
            hr = random.gauss(72, 3)
        elif pattern == "watch":
            eeg = 0.7 * math.sin(12 * t) + random.uniform(-0.25, 0.25)
            ecg = 0.9 * math.sin(6.5 * t) + random.uniform(-0.1, 0.1)
            motion = 0.45 * math.sin(3 * t) + random.uniform(-0.2, 0.2)
            hr = random.gauss(95, 6)
        else:
            burst = 0.8 if math.sin(25 * t) > 0.6 else 0.0
            eeg = 1.4 * math.sin(20 * t) + burst + random.uniform(-0.35, 0.35)
            ecg = 1.1 * math.sin(8 * t) + random.uniform(-0.3, 0.3)
            motion = 1.2 * abs(math.sin(10 * t)) + random.uniform(-0.5, 0.5)
            hr = random.gauss(125, 10)
        samples.append({"eeg": eeg, "ecg": ecg, "motion": motion, "hr": hr})
    return samples


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def make_trajectory_batch(progress: float, n: int = 32):
    """One batch on a continuous interictal→preictal→onset ramp.

    ``progress`` in [0,1] blends the calm ``stable`` morphology into the
    ``high_risk`` morphology so the signal statistics that ``extract_features``
    reads (EEG power/peak, HR, motion) climb smoothly. This is what lets the
    forecast probability rise gradually and the lead-time count down — i.e. the
    device *predicting* an approaching seizure rather than only detecting one.
    """
    p = min(max(progress, 0.0), 1.0)
    samples = []
    for i in range(n):
        t = i / n * 2 * math.pi
        # EEG: amplitude, frequency and pre-onset bursts all grow with progress.
        eeg_amp = _lerp(0.4, 1.4, p)
        eeg_freq = _lerp(8.0, 20.0, p)
        burst = (0.8 * p) if math.sin(25 * t) > 0.6 else 0.0
        eeg = eeg_amp * math.sin(eeg_freq * t) + burst + random.uniform(-0.1 - 0.25 * p, 0.1 + 0.25 * p)
        # ECG: mild rise in amplitude/variability.
        ecg = _lerp(0.8, 1.1, p) * math.sin(_lerp(5.0, 8.0, p) * t) + random.uniform(-0.05 - 0.25 * p, 0.05 + 0.25 * p)
        # Motion: from near-still to pre-onset restlessness.
        motion = _lerp(0.0, 1.2, p) * abs(math.sin(_lerp(3.0, 10.0, p) * t)) + random.uniform(-0.15 - 0.35 * p, 0.15 + 0.35 * p)
        # HR: tachycardia builds toward onset.
        hr = random.gauss(_lerp(72.0, 125.0, p), _lerp(3.0, 10.0, p))
        samples.append({"eeg": eeg, "ecg": ecg, "motion": motion, "hr": hr})
    return samples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--api", default=API)
    parser.add_argument("--patient-id", default="patient-demo")
    parser.add_argument("--device-id", default="headband-01")
    parser.add_argument("--pattern", default="stable",
                        choices=["stable", "watch", "high_risk", "preictal_ramp"])
    parser.add_argument("--interval", type=float, default=1.0, help="seconds between batches")
    parser.add_argument("--batches", type=int, default=8, help="how many batches to send")
    # --- Prediction (preictal_ramp) controls ---
    parser.add_argument("--horizon-min", type=float, default=15.0,
                        help="SPH / prediction horizon in minutes (display only; backend uses PREICTAL_HORIZON_MIN)")
    parser.add_argument("--ramp-sec", type=float, default=120.0,
                        help="seconds to climb from interictal (progress 0) to onset (progress 1)")
    parser.add_argument("--onset-hold", type=int, default=3,
                        help="extra batches to keep sending at full onset after the ramp completes")
    args = parser.parse_args()

    token = get_token(args.api, args.device_id)
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    print(f"Sending to {args.api} as device={args.device_id} patient={args.patient_id}")

    if args.pattern == "preictal_ramp":
        _run_preictal_ramp(args, headers)
        return

    with httpx.Client(timeout=20) as client:
        for i in range(args.batches):
            # cycle patterns a bit for demo realism
            pattern = args.pattern
            if args.pattern == "stable" and i >= args.batches - 2:
                pattern = "high_risk"
            payload = {
                "patient_id": args.patient_id,
                "device_id": args.device_id,
                "samples": make_batch(pattern),
            }
            r = client.post(f"{args.api}/device/ingest", json=payload, headers=headers)
            r.raise_for_status()
            body = r.json()
            print(f"batch {i+1}/{args.batches} buffered={body.get('buffered')} assessment={body.get('assessment')}")
            time.sleep(args.interval)

        st = client.get(f"{args.api}/device/status/{args.patient_id}").json()
        print("final status:", st.get("last_label"), st.get("last_confidence"), "connected=", st.get("connected"))


def _run_preictal_ramp(args, headers):
    """Stream a continuous interictal→preictal→onset trajectory and print the
    forecast (preictal probability + lead-time) the backend returns for each
    batch — the device 'predicting' an approaching seizure."""
    print(f"preictal_ramp: horizon={args.horizon_min}min ramp={args.ramp_sec}s "
          f"interval={args.interval}s (progress 0→1 then hold {args.onset_hold})")
    ramp_batches = max(1, int(math.ceil(args.ramp_sec / max(args.interval, 0.001))))
    total = ramp_batches + max(0, args.onset_hold)
    with httpx.Client(timeout=20) as client:
        for i in range(total):
            progress = min(1.0, (i + 1) / ramp_batches)
            payload = {
                "patient_id": args.patient_id,
                "device_id": args.device_id,
                "samples": make_trajectory_batch(progress),
            }
            r = client.post(f"{args.api}/device/ingest", json=payload, headers=headers)
            r.raise_for_status()
            body = r.json()
            a = body.get("assessment") or {}
            pp = a.get("preictal_prob")
            lt = a.get("lead_time_min")
            pp_s = f"{pp:.3f}" if isinstance(pp, (int, float)) else "—"
            lt_s = f"{lt:.1f}min" if isinstance(lt, (int, float)) else "—"
            flag = "  ⚠ PRE-ALERT" if a.get("predicted") else ""
            print(f"batch {i+1}/{total} progress={progress:.2f} "
                  f"label={a.get('label')} preictal={pp_s} lead_time={lt_s} "
                  f"src={a.get('prediction_source')}{flag}")
            time.sleep(args.interval)

        st = client.get(f"{args.api}/device/status/{args.patient_id}").json()
        print("final status:", st.get("last_label"),
              "preictal=", st.get("last_preictal_prob"),
              "lead_time=", st.get("last_lead_time_min"),
              "predicted=", st.get("last_predicted"),
              "connected=", st.get("connected"))


if __name__ == "__main__":
    main()
