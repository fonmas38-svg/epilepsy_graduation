"""
محاكي جهاز الرأس التفاعلي (Headband Device Simulator Client)
============================================================
مشروع التخرج: النظام الذكي لمراقبة مرضى الصرع والتنبؤ المبكر بالنوبات.

وصف المحاكي:
-----------
يقوم هذا البرنامج بمحاكاة جهاز الرأس المستقبلي (Wearable Headband) عبر توليد إشارات
صناعية دقيقة (EEG + ECG + Motion + Heart Rate) دون الحاجة لتحميل أي Dataset خارجية.
يعمل المحاكي كعميل (Client) يرسل العينات المجمعة إلى خادم FastAPI عبر نقطة النهاية:
`POST /device/ingest` باستخدام توكن JWT صالح يتم إصداره ديناميكياً من `POST /auth/token`.

الأنماط المدعومة (Patterns):
--------------------------
1. stable: حالة مستقرة وهادئة (نبض ~72 bpm، إشارة EEG منتظمة ونقية).
2. watch: حالة متوسطة تتطلب المراقبة (نبض ~95 bpm، قمم متوسطة في EEG).
3. high_risk: حالة خطر مرتفع / نوبة نشطة (نبض ~125 bpm، قمم حادة ونشاط صرعي متزايد في EEG).
4. ramp: نمط التدرج المستمر (Interictal -> Preictal -> Seizure Onset) لاختبار مسار التنبيهات ببيانات صناعية؛ لا يثبت القدرة على التنبؤ عند المرضى.

الاستخدام:
--------
  python sim_client.py --pattern ramp
  python sim_client.py --pattern stable --batches 10
  python sim_client.py --pattern high_risk --interval 0.5
"""
from __future__ import annotations

import argparse
import math
import random
import sys
import time
from typing import Any, Dict, List, Optional

import httpx

DEFAULT_API_URL = "http://127.0.0.1:8000"
DEFAULT_PATIENT_ID = "patient-demo"
DEFAULT_DEVICE_ID = "headband-01"
DEFAULT_ENROLLMENT_SECRET = "enroll-device-demo"
DEFAULT_BATCH_SIZE = 256
SAMPLE_RATE_HZ = 256


class DeviceSimulator:
    """محاكي إشارات جهاز الرأس وطبقة الاتصال بالخادم."""

    def __init__(
        self,
        api_url: str = DEFAULT_API_URL,
        patient_id: str = DEFAULT_PATIENT_ID,
        device_id: str = DEFAULT_DEVICE_ID,
        secret: str = DEFAULT_ENROLLMENT_SECRET,
        seed: int | None = None,
    ) -> None:
        self.api_url = api_url.rstrip("/")
        self.patient_id = patient_id
        self.device_id = device_id
        self.secret = secret
        self.access_token: Optional[str] = None
        self.sequence_number: int = 0
        self.sample_index = 0
        self.rng = random.Random(seed)

    def fetch_token(self) -> str:
        """طلب توكن JWT جديد من الخادم عبر نقطة /auth/token."""
        url = f"{self.api_url}/auth/token"
        payload = {
            "subject": self.device_id,
            "role": "device",
            "patient_id": self.patient_id,
            "enrollment_secret": self.secret,
        }
        try:
            response = httpx.post(url, json=payload, timeout=5.0)
            if response.status_code == 200:
                data = response.json()
                self.access_token = data.get("access_token")
                return self.access_token  # type: ignore[return-value]
            else:
                raise RuntimeError(
                    f"فشل الحصول على التوكن (الكود {response.status_code}): {response.text}"
                )
        except Exception as e:
            raise RuntimeError(f"تعذر الاتصال بالخادم عند طلب التوكن ({url}): {e}") from e

    def generate_samples(self, pattern: str, progress: float = 0.0, n: int = DEFAULT_BATCH_SIZE) -> List[Dict[str, float]]:
        """توليد دفعة من عينات الإشارات الفسيولوجية دون استخدام أي Dataset.

        المعادلات تبني موجات حيوية متناسقة زمنياً (EEG, ECG, Motion, HR).
        """
        if not isinstance(n, int) or not 1 <= n <= 512:
            raise ValueError("Batch size must be between 1 and 512")
        if not math.isfinite(progress):
            raise ValueError("Progress must be finite")
        p = min(max(progress, 0.0), 1.0)
        samples = []

        for i in range(n):
            t = (self.sample_index + i) / SAMPLE_RATE_HZ * 2.0 * math.pi

            if pattern == "flatline":
                eeg, ecg, motion, hr = 0.0, 0.0, 0.0, 72.0
            elif pattern == "mains_noise":
                eeg, ecg, motion, hr = math.sin(50 * t), 0.0, 0.0, 72.0
            elif pattern == "clipping":
                eeg, ecg, motion, hr = (2.0 if math.sin(8 * t) >= 0 else -2.0), 0.0, 0.0, 72.0
            elif pattern == "stable":
                # EEG هادئ بلا قمم صرعية
                eeg = 0.35 * math.sin(8.0 * t) + self.rng.uniform(-0.08, 0.08)
                # ECG منتظم
                ecg = 0.8 * math.sin(5.0 * t) + self.rng.uniform(-0.04, 0.04)
                # حركة هادئة جداً
                motion = abs(self.rng.uniform(-0.08, 0.08))
                # نبض قلب طبيعي ~72 bpm
                hr = self.rng.gauss(72.0, 2.5)

            elif pattern == "watch":
                # EEG قمم متوسطة الارتفاع والتردد
                eeg = 0.65 * math.sin(12.0 * t) + self.rng.uniform(-0.2, 0.2)
                ecg = 0.9 * math.sin(6.5 * t) + self.rng.uniform(-0.08, 0.08)
                motion = 0.4 * abs(math.sin(3.0 * t)) + self.rng.uniform(-0.15, 0.15)
                hr = self.rng.gauss(95.0, 4.0)

            elif pattern == "high_risk":
                # EEG قمم حادة ونشاط صرعي كباقي نوبات الصرع (Spikes/Bursts)
                spike = 0.95 if math.sin(25.0 * t) > 0.55 else 0.0
                eeg = 1.35 * math.sin(20.0 * t) + spike + self.rng.uniform(-0.3, 0.3)
                ecg = 1.15 * math.sin(8.5 * t) + self.rng.uniform(-0.2, 0.2)
                motion = 1.1 * abs(math.sin(9.0 * t)) + self.rng.uniform(-0.3, 0.3)
                hr = self.rng.gauss(125.0, 6.0)

            elif pattern in ("ramp", "preictal_ramp"):
                # التدرج المستمر: تزيد سعة وتردد EEG وتظهر القمم الحادة تدريجياً
                eeg_amp = 0.35 + (1.35 - 0.35) * p
                eeg_freq = 8.0 + (20.0 - 8.0) * p
                spike = (0.95 * p) if math.sin(25.0 * t) > (0.8 - 0.25 * p) else 0.0
                eeg = eeg_amp * math.sin(eeg_freq * t) + spike + self.rng.uniform(-0.08 - 0.2 * p, 0.08 + 0.2 * p)

                ecg = (0.8 + 0.35 * p) * math.sin((5.0 + 3.5 * p) * t) + self.rng.uniform(-0.04 - 0.15 * p, 0.04 + 0.15 * p)
                motion = (0.05 + 1.1 * p) * abs(math.sin((2.0 + 7.0 * p) * t)) + self.rng.uniform(-0.08 - 0.2 * p, 0.08 + 0.2 * p)
                hr = 72.0 + (125.0 - 72.0) * p + self.rng.uniform(-2.5, 2.5)

            else:
                raise ValueError(f"نمط غير معروف: {pattern}. الأنماط المتاحة: stable, watch, high_risk, ramp")

            # ضمان القيود الفسيولوجية والمدى المسموح لخادم API
            hr_clamped = round(min(max(hr, 20.0), 240.0), 1)

            sample = {
                "eeg": round(float(eeg), 4),
                "ecg": round(float(ecg), 4),
                "motion": round(float(motion), 4),
                "hr": hr_clamped,
            }

            # التحقق من أن القيم أعداد حقيقية منتهية (ليست NaN أو Infinity)
            for k, val in sample.items():
                if not math.isfinite(val):
                    raise ValueError(f"قيمة غير حاسوبية ({k}={val}) تم توليدها!")

            samples.append(sample)

        self.sample_index += n
        return samples

    def send_batch(
        self,
        samples: List[Dict[str, float]],
        client: httpx.Client,
    ) -> Dict[str, Any]:
        """إرسال دفعة عينات إلى السيرفر وتلقي التقييم والتنبؤ."""
        if not self.access_token:
            self.fetch_token()

        url = f"{self.api_url}/device/ingest"
        headers = {
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": "application/json",
        }
        payload = {
            "patient_id": self.patient_id,
            "device_id": self.device_id,
            "sequence_number": self.sequence_number,
            "samples": samples,
            "sample_rate_hz": SAMPLE_RATE_HZ,
            "signal_units": "normalized_demo",
        }

        response = client.post(url, json=payload, headers=headers)
        if response.status_code == 401:
            # تجديد التوكن عند انتهاء الصلاحية
            self.fetch_token()
            headers["Authorization"] = f"Bearer {self.access_token}"
            response = client.post(url, json=payload, headers=headers)

        response.raise_for_status()
        result = response.json()
        if result.get("out_of_order"):
            raise RuntimeError("Sequence rejected: use a new device session after restart")
        self.sequence_number += 1
        return result


def run_simulation(args: argparse.Namespace) -> None:
    """تشغيل عملية المحاكاة بطباعة منسقة وتفاعلية."""
    if args.batches < 1 or not 1 <= args.batch_size <= 512:
        raise ValueError("Positive batches and batch size 1..512 are required")
    if args.interval is None:
        # Keep headroom under the production API's per-minute request quota.
        # 256 samples/packet at 256 Hz requires 60 requests/minute, not 480.
        args.interval = args.batch_size / SAMPLE_RATE_HZ
    if not math.isfinite(args.interval) or args.interval <= 0:
        raise ValueError("Interval must be finite and positive")
    simulator = DeviceSimulator(
        api_url=args.api,
        patient_id=args.patient_id,
        device_id=args.device_id,
        secret=args.secret,
        seed=args.seed,
    )

    print("=" * 70)
    print("      محاكي جهاز الرأس الذكي لمراقبة مرضى الصرع (Simulator Client)")
    print("=" * 70)
    print(f"🔗 رابط السيرفر : {args.api}")
    print(f"👤 معرف المريض  : {args.patient_id}")
    print(f"📟 معرف الجهاز   : {args.device_id}")
    print(f"📊 النمط المحدد : {args.pattern}")
    print(f"⏱️  الفاصل الزمني : {args.interval} ثانية")
    print("-" * 70)

    # محاولة الحصول على التوكن
    try:
        simulator.fetch_token()
        print("✅ تم المصادقة مع السيرفر واستلام توكن JWT بنجاح.")
    except Exception as e:
        print(f"❌ خطأ في المصادقة: {e}")
        print("💡 تأكد من تشغيل السيرفر أولاً عبر: uvicorn app.main:app --reload")
        sys.exit(1)

    print("-" * 70)

    total_batches = args.batches
    pattern = args.pattern

    with httpx.Client(timeout=20.0) as client:
        for b in range(total_batches):
            progress = (b + 1) / total_batches if total_batches > 1 else 1.0

            # توليد عينات النمط
            samples = simulator.generate_samples(pattern=pattern, progress=progress, n=args.batch_size)

            try:
                res = simulator.send_batch(samples, client=client)
            except Exception as ex:
                print(f"❌ فشل إرسال الدفعة [{b + 1}/{total_batches}]: {ex}")
                time.sleep(args.interval)
                continue

            buffered = res.get("buffered", 0)
            window_ready = res.get("window_ready", False)
            assessment = res.get("assessment") or {}

            label = assessment.get("label", "جاري التجميع...")
            preictal = assessment.get("preictal_prob")
            lead_time = assessment.get("lead_time_min")
            predicted = assessment.get("predicted", False)

            preictal_str = f"{preictal:.3f}" if isinstance(preictal, (int, float)) else "—"
            lead_time_str = f"{lead_time:.1f} دقيقة" if isinstance(lead_time, (int, float)) else "—"
            alert_tag = " 🚨 [تنبيه مبكر بالنوبة!]" if predicted else ""

            if pattern in ("ramp", "preictal_ramp"):
                print(
                    f"[{b + 1:>2}/{total_batches}] التقدم={progress * 100:>3.0f}% | "
                    f"المخزن={buffered:>3}/262 | "
                    f"الحالة={label:<9} | "
                    f"درجة تجريبية={preictal_str:<5} | "
                    f"الزمن المتوقع={lead_time_str}{alert_tag}"
                )
            else:
                print(
                    f"[{b + 1:>2}/{total_batches}] الدفعة المكتملة | "
                    f"المخزن={buffered:>3}/262 | "
                    f"الحالة={label:<9} | "
                    f"درجة تجريبية={preictal_str:<5}{alert_tag}"
                )

            if b < total_batches - 1:
                time.sleep(args.interval)

        # جلب حالة المريض النهائية من السيرفر
        try:
            status_res = client.get(f"{args.api}/device/status/{args.patient_id}", timeout=10.0).json()
            print("-" * 70)
            print("📈 **الملخص النهائي من الخادم:**")
            print(f"   • حالة المريض الحالية : {status_res.get('last_label', 'غ/م')}")
            print(f"   • درجة الثقة         : {status_res.get('last_confidence', 'غ/م')}")
            print(f"   • درجة تجريبية       : {status_res.get('last_preictal_prob', 'غ/م')}")
            print(f"   • زمن الاستباق       : {status_res.get('last_lead_time_min', 'غ/م')} دقيقة")
            print(f"   • حالة الاتصال      : {'متقاطع' if status_res.get('connected') else 'منقطع'}")
            print("=" * 70)
        except Exception as err:
            print(f"⚠️ تعذر جلب ملخص الحالة النهائية: {err}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="محاكي جهاز الرأس الذكي لإرسال إشارات EEG/ECG/Motion إلى خادم مراقبة الصرع."
    )
    parser.add_argument("--api", default=DEFAULT_API_URL, help="رابط خادم FastAPI (Default: http://127.0.0.1:8000)")
    parser.add_argument("--patient-id", default=DEFAULT_PATIENT_ID, help="معرف المريض (Default: patient-demo)")
    parser.add_argument("--device-id", default=DEFAULT_DEVICE_ID, help="معرف الجهاز (Default: headband-01)")
    parser.add_argument("--secret", default=DEFAULT_ENROLLMENT_SECRET, help="سر التسجيل لطلب توكن JWT")
    parser.add_argument(
        "--pattern",
        default="ramp",
        choices=["stable", "watch", "high_risk", "ramp", "flatline", "mains_noise", "clipping"],
        help="نمط المحاكاة: stable (مستقر), watch (مراقبة), high_risk (خطر), ramp (تدرج للتنبؤ بالنوبة)",
    )
    parser.add_argument("--batches", type=int, default=20, help="عدد الدفعات المراد إرسالها (Default: 20)")
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE, help="عدد العينات لكل دفعة (Default: 256)")
    parser.add_argument("--seed", type=int, default=42, help="Reproducible synthetic signals")
    parser.add_argument("--interval", type=float, default=None, help="الزمن بالثواني بين كل دفعة وأخرى (Default: batch-size / 256)")
    return parser


if __name__ == "__main__":
    cli_parser = build_parser()
    cli_args = cli_parser.parse_args()
    run_simulation(cli_args)
