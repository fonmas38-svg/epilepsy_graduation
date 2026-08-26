# متطلبات المحاكي (Device Simulator) — مستند تسليم

**إلى:** المسؤول عن محاكي الجهاز
**المستودع:** `https://github.com/fonmas38-svg/epilepsy_graduation`
**مجلد عملك:** `partners/hardware-sim/`
**آخر تحديث:** 2026-08-26

---

## 0) الخلاصة في ثمانية أسطر (اقرأها قبل أي شيء)

1. المحاكي يقوم مقام **جهاز الرأس** الذي لم نشترِه بعد.
2. يقرأ الجهاز ثلاث إشارات: **EEG** (دماغ) + **ECG** (قلب) + **Motion** (حركة) + **HR** (نبض).
3. مهمتك: برنامج **بايثون واحد** يولّد هذه الأرقام ويرسلها إلى السيرفر الموجود.
4. ⛔ **لا تبنِ سيرفر FastAPI جديدًا.** السيرفر موجود وجاهز. أنت **ترسل إليه**.
5. الإرسال إلى نقطة واحدة: `POST /device/ingest`.
6. السيرفر يجمّع **128 عينة** ثم يعيد لك التقييم: `stable` أو `watch` أو `high_risk`.
7. اعمل **داخل `partners/hardware-sim/` فقط**، وارفع عملك عبر **Fork ثم Pull Request** (القسم 12).
8. عندك مثال كامل يعمل جاهز للنسخ في القسم 8، ومثال مرجعي في `backend/device_gateway_sim.py`.

---

## 1) ما هو المحاكي ولماذا نحتاجه

المشروع نظام يراقب مريض صرع ويتنبأ بالنوبة قبل حدوثها. المسار الكامل:

```
جهاز الرأس  ──►  السيرفر (FastAPI)  ──►  نموذج الذكاء الاصطناعي  ──►  تطبيق الهاتف
   ▲                                                                      │
   └── هذا هو مكانك: تكتب برنامجًا يقلّده                       تنبيه للمريض والأسرة والطبيب
```

الجهاز الحقيقي لم يُشترَ. بدونه لا نستطيع اختبار السيرفر ولا النموذج ولا التطبيق
ولا عرض المشروع أمام اللجنة. **المحاكي هو ما يجعل المشروع قابلًا للعرض.**

---

## 2) القاعدة الذهبية: أنت **عميل** (Client)، لا **خادم** (Server)

هذا أهم سطر في المستند، وهو الخطأ الذي وقع في المحاولة السابقة.

| ❌ خطأ | ✅ صواب |
|---|---|
| `app = FastAPI()` في كودك | `httpx.post(...)` أو `requests.post(...)` في كودك |
| `@app.get("/api/sensor")` ينتظر من يسأله | حلقة `while` ترسل بنفسها كل ثانية |
| `uvicorn main:app` | `python simulator.py` |
| تحكم أنت على البيانات: «سقوط = نعم» | ترسل الأرقام الخام، **والسيرفر** يحكم |

**السبب:** الحكم على الحالة وظيفة النموذج المدرَّب داخل السيرفر. لو حكمتَ أنت في
كودك، فأنت لم تختبر النموذج — اختبرتَ جملة `if` كتبتها بنفسك، والعرض أمام اللجنة
يصبح عرضًا لشيء لا يعمل.

---

## 3) التجهيز: شغّل السيرفر أولًا

نافذة طرفية (Terminal) أولى — اتركها مفتوحة:

```bash
cd backend
python -m venv .venv
.venv\Scripts\activate          # على ويندوز
pip install -r requirements.txt
python -m alembic upgrade head
python data/build_dataset.py
python train_from_dataset.py
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

تأكد أنه يعمل — افتح المتصفح على `http://127.0.0.1:8000/health`، يجب أن تظهر:

```json
{ "status": "ok", "service": "epilepsy-monitoring-api", "version": "2.3.0", "engine": "sklearn" }
```

> صفحة التوثيق التفاعلي: `http://127.0.0.1:8000/docs` — تستطيع تجربة أي نقطة نهاية
> منها بالضغط على **Try it out** قبل أن تكتب سطر كود واحدًا. ابدأ من هناك.

نافذة طرفية ثانية — هنا تشغّل محاكيك.

---

## 4) الخطوة 1 — احصل على توكن (Token)

السيرفر لا يقبل بيانات من مجهول. اطلب توكنًا مرة واحدة عند بدء البرنامج:

**الطلب**

```
POST http://127.0.0.1:8000/auth/token
Content-Type: application/json

{
  "subject": "headband-01",
  "role": "device",
  "enrollment_secret": "enroll-device-demo"
}
```

**الرد**

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR...",
  "token_type": "bearer",
  "role": "device"
}
```

خُذ قيمة `access_token` وضعها في ترويسة كل طلب بعدها:

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR...
```

| ملاحظة | التفصيل |
|---|---|
| `subject` | نفس `device_id` الذي سترسله لاحقًا. إن اختلفا → **403**. |
| `enrollment_secret` | `enroll-device-demo` في وضع العرض المحلي. لا تكتبه في مكان عام. |
| صلاحية التوكن | 60 دقيقة افتراضيًا. إن طال تشغيل محاكيك، اطلب توكنًا جديدًا. |
| بديل مؤقت | التوكن الثابت `headband-demo-token` يعمل محليًا فقط، ومرفوض في الإنتاج. اعتمد `/auth/token`. |

---

## 5) الخطوة 2 — أرسل العينات

**الطلب**

```
POST http://127.0.0.1:8000/device/ingest
Authorization: Bearer <التوكن>
Content-Type: application/json

{
  "patient_id": "patient-demo",
  "device_id": "headband-01",
  "sequence_number": 0,
  "samples": [
    { "eeg": 0.21, "ecg": 0.55, "motion": 0.02, "hr": 78 },
    { "eeg": 0.19, "ecg": 0.52, "motion": 0.01, "hr": 79 }
  ]
}
```

**الرد قبل امتلاء النافذة** (أقل من 128 عينة مجمّعة):

```json
{
  "ok": true,
  "accepted": 32,
  "buffered": 64,
  "window_ready": false,
  "assessment": null,
  "duplicate": false,
  "out_of_order": false
}
```

**الرد بعد امتلاء النافذة** (128 عينة أو أكثر):

```json
{
  "ok": true,
  "accepted": 32,
  "buffered": 128,
  "window_ready": true,
  "assessment": {
    "label": "watch",
    "confidence": 0.71,
    "features": {
      "hr_mean": 96.0, "hr_std": 4.2, "eeg_power": 1.0, "eeg_peak": 1.63,
      "motion_energy": 1.0, "motion_variance": 1.0, "ecg_variability": 1.0
    },
    "timestamp": "2026-08-26T10:15:03.412000+00:00",
    "engine": "sklearn",
    "deep_prob": null,
    "preictal_prob": 0.6486,
    "lead_time_min": 5.27,
    "horizon_min": 15.0,
    "predicted": true,
    "prediction_source": "simulated_heuristic",
    "preictal_trajectory": [0.4181, 0.4903, 0.5711, 0.6486]
  }
}
```

**معنى الحقول المهمة:**

| الحقل | المعنى |
|---|---|
| `accepted` | عدد العينات التي قُبلت من دفعتك |
| `buffered` | إجمالي العينات المخزّنة لهذا المريض (السعة القصوى 512، والأقدم يُزاح) |
| `window_ready` | `true` إذا صار المخزون ≥ 128 |
| `label` | `stable` (مستقر) · `watch` (يحتاج مراقبة) · `high_risk` (خطر مرتفع) |
| `confidence` | ثقة التصنيف من 0 إلى 1 |
| `preictal_prob` | احتمال أن المريض في مرحلة **ما قبل النوبة** (0 إلى 1) |
| `lead_time_min` | الدقائق المقدَّرة قبل النوبة. تنزل نحو 0 كلما ارتفع `preictal_prob` |
| `horizon_min` | الأفق الزمني المستخدم (15 دقيقة افتراضيًا) |
| `predicted` | `true` إذا تجاوز `preictal_prob` عتبة الإنذار المبكر (0.6) |
| `preictal_trajectory` | آخر 60 قيمة لـ`preictal_prob` — يرسمها التطبيق كخط بياني |

**قراءة الحالة في أي وقت** (لا تحتاج توكنًا في وضع العرض المحلي):

```
GET http://127.0.0.1:8000/device/status/patient-demo
```

---

## 6) عقد البيانات — القيم المسموحة (إلزامي)

أي خروج عن هذا الجدول يرجع **422 Unprocessable Entity**.

### الحقول الرئيسية

| الحقل | النوع | إلزامي؟ | القيد |
|---|---|---|---|
| `patient_id` | نص | ✅ نعم | حرف واحد على الأقل. استخدم `patient-demo` |
| `device_id` | نص | ❌ لا | افتراضيًا `headband-01`. **يجب أن يطابق `subject` في التوكن** |
| `samples` | مصفوفة | ✅ نعم | **من 1 إلى 512** عنصرًا. الموصى به: **32** |
| `batch_id` | نص | ❌ لا | من 1 إلى 128 حرفًا. معرّف فريد للدفعة (منع التكرار) |
| `sequence_number` | عدد صحيح | ❌ لا | **≥ 0** ويجب أن **يتزايد**. رقم مكرر أو أصغر → الدفعة تُهمَل |

### داخل كل عنصر من `samples`

| الحقل | النوع | إلزامي؟ | القيد |
|---|---|---|---|
| `eeg` | رقم عشري | ✅ نعم | رقم منتهٍ. **لا `NaN` ولا `Infinity`** |
| `ecg` | رقم عشري | ✅ نعم | رقم منتهٍ |
| `motion` | رقم عشري | ✅ نعم | رقم منتهٍ |
| `hr` | رقم عشري | ❌ لا | إن أرسلته: **من 20 إلى 240** فقط. أرسله في **كل** عينة |
| `ts` | نص | ❌ لا | ISO-8601 **مع المنطقة الزمنية**. مثال: `2026-08-26T10:15:03Z` |

**تحذيران يوقعان الكثيرين:**

- `hr = 0` أو `hr = 300` → **422**. المدى المقبول 20–240 فقط.
- `ts` بلا منطقة زمنية (`2026-08-26T10:15:03` بدون `Z`) → **422**.
  و`ts` أقدم من 7 أيام أو أكثر من 5 دقائق في المستقبل → **422**.
  **الأسهل: لا ترسل `ts` إطلاقًا** — السيرفر يضع الوقت تلقائيًا.

---

## 7) ⭐ أهم قسم: ما الذي يحرّك النتيجة فعلًا؟

قبل أن يصل الرقم إلى النموذج، يقوم السيرفر بخطوتين على كل قناة:

1. **تنعيم** (متوسط متحرك بنافذة 5)
2. **تطبيع** (Normalization): يطرح المتوسط ويقسم على الانحراف المعياري

**نتيجة الخطوة الثانية — احفظها:** التطبيع يمسح **حجم** الإشارة ويُبقي **شكلها**.

> ### ضرب كل أرقامك في 10 لا يغيّر النتيجة إطلاقًا.

لذلك أربع خصائص تبقى ثابتة عند 1.0 مهما فعلت: `eeg_power` و`motion_energy`
و`motion_variance` و`ecg_variability`. (لا تقلق منها، ولا تضيّع وقتك في محاولة
تحريكها.)

### الثلاثة التي تحرّك النتيجة فعلًا

| المفتاح | كيف تحرّكه | العتبات المؤثرة |
|---|---|---|
| **1. `hr` — الأقوى** | أرسل قيمة أعلى مباشرةً | ≥ 90 يرفع الخطر · ≥ 110 يرفعه كثيرًا · التنبؤ يصعد خطيًا من 80 إلى 125 |
| **2. شكل EEG (النبضات)** | أضف **قِمَمًا حادة قصيرة** فوق الموجة الأساسية | قمة نسبية ≥ 1.2 ترفع · ≥ 2.0 ترفع كثيرًا |
| **3. تردد ECG** | غيّر **سرعة** الموجة، لا ارتفاعها | يؤثر عبر تباعد النبضات (`hr_std`) |

### مثال يوضح الفكرة

```python
# ❌ لا يفيد: نفس الشكل بحجم أكبر — بعد التطبيع تصبح النتيجة متطابقة
eeg = 4.0 * math.sin(10 * t)

# ✅ يفيد: قمم حادة تغيّر الشكل نفسه
spike = 0.9 if math.sin(25 * t) > 0.6 else 0.0
eeg = math.sin(10 * t) + spike
```

**الخلاصة العملية:** لكي يرتفع الخطر، ارفع `hr` **وأضف قممًا حادة إلى EEG** معًا.
تغيير أحدهما وحده يعطي حركة ضعيفة.

---

## 8) مثال كامل يعمل — انسخه وابدأ منه

ثبّت المكتبة أولًا:

```bash
pip install httpx
```

احفظ الملف باسم `partners/hardware-sim/sim_client.py`:

```python
"""محاكي جهاز الرأس — عميل يرسل إلى السيرفر القائم.
التشغيل:  python sim_client.py
"""
import math
import random
import time

import httpx

API = "http://127.0.0.1:8000"
PATIENT_ID = "patient-demo"
DEVICE_ID = "headband-01"
SECRET = "enroll-device-demo"

BATCH_SIZE = 32      # عدد العينات في كل دفعة (الحد الأقصى 512)
TOTAL_BATCHES = 40   # 40 × 32 = 1280 عينة
INTERVAL_SEC = 1.0   # ثانية بين كل دفعة


def get_token() -> str:
    """يبدّل السر بتوكن JWT صالح."""
    r = httpx.post(
        f"{API}/auth/token",
        json={"subject": DEVICE_ID, "role": "device", "enrollment_secret": SECRET},
        timeout=5.0,
    )
    r.raise_for_status()
    return r.json()["access_token"]


def make_samples(progress: float, n: int = BATCH_SIZE) -> list[dict]:
    """يولّد دفعة عينات.

    progress = 0.0  ->  هادئ تمامًا (interictal)
    progress = 1.0  ->  بداية النوبة (onset)
    """
    p = min(max(progress, 0.0), 1.0)
    samples = []
    for i in range(n):
        t = i / n * 2 * math.pi

        # EEG: قمم حادة تزداد مع التقدم (الشكل هو ما يهم، لا الحجم)
        spike = (0.9 * p) if math.sin(25 * t) > 0.6 else 0.0
        eeg = math.sin(10 * t) + spike + random.uniform(-0.05, 0.05)

        # ECG: التردد يرتفع مع التقدم
        ecg = 0.9 * math.sin((6.0 + 2.0 * p) * t) + random.uniform(-0.05, 0.05)

        # Motion: من السكون إلى التململ
        motion = (0.2 + 1.0 * p) * abs(math.sin(8 * t)) + random.uniform(-0.1, 0.1)

        # HR: من 72 إلى 125 نبضة (يبقى دائمًا داخل المدى المسموح 20–240)
        hr = 72.0 + (125.0 - 72.0) * p + random.uniform(-3.0, 3.0)

        samples.append({
            "eeg": round(eeg, 4),
            "ecg": round(ecg, 4),
            "motion": round(motion, 4),
            "hr": round(hr, 1),
        })
    return samples


def main() -> None:
    token = get_token()
    headers = {"Authorization": f"Bearer {token}"}
    print(f"متصل بـ {API} — device={DEVICE_ID} patient={PATIENT_ID}")

    with httpx.Client(timeout=20.0) as client:
        for i in range(TOTAL_BATCHES):
            progress = (i + 1) / TOTAL_BATCHES
            body = {
                "patient_id": PATIENT_ID,
                "device_id": DEVICE_ID,
                "sequence_number": i,               # يتزايد -> يمنع تكرار الدفعة
                "samples": make_samples(progress),
            }
            r = client.post(f"{API}/device/ingest", json=body, headers=headers)
            r.raise_for_status()
            res = r.json()

            a = res.get("assessment") or {}
            label = a.get("label", "—")
            pp = a.get("preictal_prob")
            lt = a.get("lead_time_min")
            pp_txt = f"{pp:.3f}" if isinstance(pp, (int, float)) else "—"
            lt_txt = f"{lt:.1f}د" if isinstance(lt, (int, float)) else "—"
            warn = "  ⚠ إنذار مبكر" if a.get("predicted") else ""

            print(f"[{i + 1:>2}/{TOTAL_BATCHES}] تقدم={progress:.2f} "
                  f"مخزّن={res['buffered']:>3} حالة={label:<9} "
                  f"احتمال_ما_قبل_النوبة={pp_txt} زمن_الاستباق={lt_txt}{warn}")

            time.sleep(INTERVAL_SEC)

    status = httpx.get(f"{API}/device/status/{PATIENT_ID}", timeout=10.0).json()
    print("\nالحالة النهائية:", status.get("last_label"),
          "| متصل:", status.get("connected"))


if __name__ == "__main__":
    main()
```

**المخرجات المتوقعة** — لاحظ `مخزّن` يصل إلى 128 عند الدفعة الرابعة، ثم تبدأ
الحالة بالظهور وتتدرّج من `stable` إلى `watch` إلى `high_risk`:

```
متصل بـ http://127.0.0.1:8000 — device=headband-01 patient=patient-demo
[ 1/40] تقدم=0.03 مخزّن= 32 حالة=—         احتمال_ما_قبل_النوبة=— زمن_الاستباق=—
[ 2/40] تقدم=0.05 مخزّن= 64 حالة=—         احتمال_ما_قبل_النوبة=— زمن_الاستباق=—
[ 3/40] تقدم=0.08 مخزّن= 96 حالة=—         احتمال_ما_قبل_النوبة=— زمن_الاستباق=—
[ 4/40] تقدم=0.10 مخزّن=128 حالة=stable    احتمال_ما_قبل_النوبة=0.431 زمن_الاستباق=8.5د
...
[40/40] تقدم=1.00 مخزّن=512 حالة=high_risk احتمال_ما_قبل_النوبة=0.912 زمن_الاستباق=1.3د  ⚠ إنذار مبكر
```

> الأرقام التقريبية تختلف قليلًا بين تشغيل وآخر بسبب العشوائية — المهم **الاتجاه**:
> الحالة تتصاعد، و`زمن_الاستباق` ينزل.

---

## 9) الأنماط الأربعة المطلوبة منك

اجعل النمط قابلًا للاختيار من سطر الأوامر (استخدم `argparse`):

```bash
python sim_client.py --pattern stable
python sim_client.py --pattern watch
python sim_client.py --pattern high_risk
python sim_client.py --pattern ramp
```

| النمط | المطلوب | النتيجة المتوقعة من السيرفر |
|---|---|---|
| `stable` | `hr` حول 72، EEG هادئ بلا قمم، حركة قليلة | `label = "stable"` |
| `watch` | `hr` حول 95، قمم EEG متوسطة، حركة متوسطة | `label = "watch"` |
| `high_risk` | `hr` حول 125، قمم EEG قوية، حركة عالية | `label = "high_risk"` |
| `ramp` | تدرّج **سلس** من `stable` إلى `high_risk` عبر ~120 ثانية | تصاعد `preictal_prob` وتنازل `lead_time_min` |

**`ramp` هو الأهم للعرض أمام اللجنة** — لأنه وحده يُظهر **التنبؤ** (النظام يرى
النوبة قادمة) وليس **الكشف** فقط (النظام يرى النوبة وقعت). المثال في القسم 8 ينفّذ
`ramp` أصلًا؛ الأنماط الثلاثة الأخرى تُنفَّذ بتثبيت `progress` على قيمة واحدة
(‏0.0 و0.5 و1.0 تقريبًا).

---

## 10) منع التكرار (Deduplication) — لماذا يهم

عند إعادة إرسال دفعة بعد انقطاع شبكة، لا يجوز حسابها مرتين — وإلا صدر تنبيه طبي
مكرر. عندك أداتان، **استخدم واحدة منهما على الأقل**:

| الأداة | كيف تعمل | السلوك عند التكرار |
|---|---|---|
| `sequence_number` | عدد صحيح **يتزايد** مع كل دفعة (0، 1، 2، ...) | رقم مساوٍ للأخير → `duplicate: true` · أصغر منه → `out_of_order: true` |
| `batch_id` | نص فريد لكل دفعة (مثل `batch-0001`) | نفس المعرّف مرة ثانية → `duplicate: true` |

في الحالتين ترجع الاستجابة `"accepted": 0` — الدفعة تُهمَل بأمان وبلا خطأ.

> السيرفر يتذكّر آخر 256 `batch_id` لكل مريض. الأسهل والأخف: `sequence_number`.

---

## 11) معايير القبول — لن يُدمج عملك قبل تحقيقها كلها

راجع هذه القائمة بنفسك قبل فتح الـ Pull Request:

- [ ] **1.** كل ملفاتي داخل `partners/hardware-sim/` — ولا ملف واحد في جذر المستودع.
- [ ] **2.** لا يوجد `FastAPI` ولا `uvicorn` في كودي. برنامجي **عميل** فقط.
- [ ] **3.** أحصل على التوكن من `POST /auth/token` (لا أكتب التوكن الثابت في الكود).
- [ ] **4.** أرسل إلى `POST /device/ingest` بالعقد الموصوف في القسم 6 حرفيًا.
- [ ] **5.** الأنماط الأربعة تعمل (`stable`, `watch`, `high_risk`, `ramp`).
- [ ] **6.** `ramp` يُظهر `preictal_prob` **تصاعديًا** و`lead_time_min` **تنازليًا**.
- [ ] **7.** أستخدم `sequence_number` أو `batch_id`.
- [ ] **8.** كل قيم `hr` داخل المدى **20–240**، ولا `NaN` ولا `Infinity` في أي قناة.
- [ ] **9.** أطبع الاستجابة على الشاشة، ولا **أحكم** على الحالة داخل كودي.
- [ ] **10.** يوجد **اختبار واحد على الأقل** يعمل بلا سيرفر، يتحقق من أن مولّد
      البيانات يُخرج قيمًا داخل المدى المسموح (`pytest`).
- [ ] **11.** `requirements.txt` فيه ما أستورده فعلًا — لا أكثر (احذف `pandas` إن لم تستخدمه).
- [ ] **12.** `README.md` في مجلدي يشرح أمر التشغيل ولقطة من المخرجات.
- [ ] **13.** لا أسرار ولا مفاتيح ولا `.env` ولا `__pycache__/` في الـ PR.

**البند 10 مثال جاهز** — احفظه `partners/hardware-sim/test_sim_client.py`:

```python
from sim_client import make_samples


def test_hr_within_allowed_range():
    """أي hr خارج 20–240 يجعل السيرفر يرفض الدفعة بـ 422."""
    for progress in (0.0, 0.5, 1.0):
        for s in make_samples(progress):
            assert 20 <= s["hr"] <= 240, s


def test_all_channels_are_finite():
    """NaN أو Infinity في أي قناة يرفضه السيرفر."""
    import math
    for s in make_samples(1.0):
        for channel in ("eeg", "ecg", "motion"):
            assert math.isfinite(s[channel]), (channel, s)


def test_batch_size_within_limit():
    """الحد الأقصى المسموح 512 عينة في الدفعة."""
    assert 1 <= len(make_samples(0.5)) <= 512
```

التشغيل:

```bash
cd partners/hardware-sim
pytest -q
```

---

## 12) ⛔ أخطاء يجب ألا تتكرر

هذه ملاحظات مراجعة على المحاولة السابقة. الغرض منها ألا تُعاد، لا التقليل من الجهد.

| الخطأ | لماذا هو خطأ | الصواب |
|---|---|---|
| بناء سيرفر FastAPI ثانٍ | يتعارض مع السيرفر الحقيقي ويربك النشر والـ CI | برنامج عميل واحد |
| رفع ملفات في جذر المستودع | `main.py` و`requirements.txt` في الجذر تتعارض مع `backend/` | كل شيء في `partners/hardware-sim/` |
| عتبة لا تتحقق أبدًا | `if acceleration > 5` مع مولّد يُخرج محاورًا في `[-1.5, 1.5]` — أقصى محصلة رياضية ممكنة `√(3×1.5²) ≈ 2.60`، فالشرط **مستحيل** | ابنِ العتبة على مدى مولّدك فعليًا، واختبرها |
| نتيجة مكتوبة يدويًا | `return {"fall": True}` لا يختبر شيئًا | أرسل الأرقام، واطبع حكم السيرفر |
| `pandas` في `requirements.txt` بلا استيراد | يثقل التثبيت بلا فائدة | احذف ما لا تستورده |
| `heart_rate` عشوائي مستقل عن الحركة | لا ارتباط زمني، فلا يوجد نمط يتعلمه أي نموذج | اجعل النبض والحركة و EEG يتغيرون **معًا** مع `progress` |
| `WebSocket` بلا مصادقة ولا حد اتصالات | ثغرة أمنية في مشروع طبي | لا تحتاج WebSocket إطلاقًا |

**عن الارتباط الزمني تحديدًا:** لو أرسلت `hr` عشوائيًا و EEG عشوائيًا بلا رابط،
فأنت ترسل ضجيجًا. الجسم لا يعمل كذلك: قبل النوبة يرتفع النبض **و** يزداد نشاط
الدماغ **و** يبدأ التململ، **في الوقت نفسه**. هذا الترابط هو ما يجعل التنبؤ ممكنًا،
ولهذا يعتمد المثال في القسم 8 على متغيّر واحد `progress` يحرّك القنوات الأربع كلها.

---

## 13) الأخطاء الشائعة وحلولها

| ما تراه | السبب | الحل |
|---|---|---|
| `ConnectError` / `Connection refused` | السيرفر غير مشغَّل | شغّل `uvicorn` في نافذة أخرى (القسم 3) |
| `401 Invalid enrollment secret` | `enrollment_secret` خطأ | استخدم `enroll-device-demo` |
| `403 device_id does not match token` | `device_id` ≠ `subject` في التوكن | وحّدهما على `headband-01` |
| `403` عند `/device/ingest` | لا ترويسة `Authorization`، أو توكن منتهٍ | أضف `Bearer <token>`، واطلب توكنًا جديدًا بعد 60 دقيقة |
| `422` مع `hr must be finite and between 20 and 240 bpm` | قيمة `hr` خارج المدى | احصر النبض بين 20 و240 |
| `422` مع `must be a valid ISO-8601 timestamp` | `ts` بصيغة خاطئة أو بلا منطقة زمنية | **لا ترسل `ts`** ودع السيرفر يضعه |
| `422` مع `must include a timezone` | نفس السبب السابق | أضف `Z` في نهاية الوقت، أو احذف الحقل |
| `413 Request body is too large` | دفعة ضخمة (الحد 2 ميجابايت) | خفّض `BATCH_SIZE` إلى 32 |
| `429` | تجاوز حد المعدل | ارفع `INTERVAL_SEC`. (الحد معطّل في وضع العرض المحلي) |
| `assessment` يبقى `null` | لم تكتمل 128 عينة | أرسل 4 دفعات × 32 على الأقل |
| الحالة `stable` دائمًا مهما رفعتَ الأرقام | ضربتَ الأرقام في معامل بدل تغيير الشكل | راجع القسم 7: ارفع `hr` **وأضف قممًا** إلى EEG |

---

## 14) كيف ترفع عملك — خطوة بخطوة

### القاعدة

> تعمل **داخل `partners/hardware-sim/` فقط**. لا ملفات في جذر المستودع، ولا تعديل
> على `backend/` أو `mobile/` أو `admin-dashboard/` أو `docs/`.

فحص آلي على GitHub اسمه **Path guard** يرفض أي Pull Request يخالف ذلك تلقائيًا،
ولن يُدمج عملك. راجع `.github/workflows/path-guard.yml`.

### الطريقة الموصى بها: Fork ثم Pull Request

**مرة واحدة فقط — التجهيز:**

1. افتح `https://github.com/fonmas38-svg/epilepsy_graduation`.
2. اضغط **Fork** (أعلى اليمين) → **Create fork**. صارت لك نسخة على حسابك.
3. انسخ نسختك إلى جهازك (بدّل `<اسم-حسابك>` باسم مستخدمك على GitHub):

```bash
git clone https://github.com/<اسم-حسابك>/epilepsy_graduation.git
cd epilepsy_graduation
git remote add upstream https://github.com/fonmas38-svg/epilepsy_graduation.git
```

**في كل مرة تريد رفع عمل:**

```bash
# 1. حدّث نسختك من الأصل
git checkout main
git fetch upstream
git merge upstream/main

# 2. أنشئ فرعًا جديدًا للمهمة
git checkout -b sim/ramp-pattern

# 3. اعمل داخل مجلدك فقط
cd partners/hardware-sim
#    ... عدّل ملفاتك هنا ...
cd ../..

# 4. تأكد أن كل التغييرات داخل مجلدك — لا تتجاهل هذه الخطوة
git status

# 5. أضف مجلدك فقط (لا تستخدم "git add ." أبدًا)
git add partners/hardware-sim/

# 6. راجع ما ستحفظه فعلًا
git diff --cached --name-only

# 7. احفظ وارفع
git commit -m "sim: add ramp pattern and range tests"
git push origin sim/ramp-pattern
```

**ثم افتح الـ Pull Request:**

8. افتح نسختك على GitHub → يظهر شريط أخضر **Compare & pull request** → اضغطه.
9. تأكد من الاتجاه: `fonmas38-svg/epilepsy_graduation` ← `<اسم-حسابك>/...`، والفرع
   الهدف `main`.
10. في الوصف اكتب: ماذا أضفت، وأمر التشغيل، ولقطة من المخرجات.
11. انتظر الفحوص الآلية. **إن ظهرت ✗ حمراء، اضغط عليها واقرأ السبب وأصلحه** — لا
    تطلب المراجعة قبل أن تصير كل الفحوص ✓ خضراء.

### طريقة بديلة: من متصفح GitHub (بلا تثبيت git)

مناسبة لملف أو ملفين، وتعمل داخل **نسختك (fork)** لا في الأصل:

1. **Fork** كما في الخطوة 2 أعلاه.
2. في نسختك، اذهب إلى مجلد `partners` ثم `hardware-sim`.
3. **Add file** → **Create new file** (أو اضغط ✏️ لتعديل ملف موجود).
4. ⚠️ **مهم:** تأكد أن المسار أعلى الصفحة يبدأ بـ
   `partners/hardware-sim/` — إن لم يكن كذلك فأنت في المكان الخطأ، وسيُرفض عملك.
5. **Commit changes** → اختر **Create a new branch** وسمّه (مثلًا `sim/ramp`) →
   **Propose changes**.
6. **Create pull request** واختر الاتجاه إلى `fonmas38-svg/epilepsy_graduation` فرع `main`.

### ⛔ لا تفعل هذا أبدًا

| ❌ | ✅ |
|---|---|
| `git add .` أو `git add -A` | `git add partners/hardware-sim/` |
| `git push --force` | لا تستخدم force إطلاقًا |
| رفع ملف في جذر المستودع | كل شيء داخل مجلدك |
| تعديل `backend/` أو `mobile/` أو `docs/` | إن احتجت تعديلًا هناك، **اطلبه** ولا تنفّذه |
| رفع `.env` أو أي مفتاح أو `google-services.json` | لا أسرار في المستودع مطلقًا |
| رفع `__pycache__/` أو `.venv/` | يستثنيها `.gitignore` — لا تُجبرها |

---

## 15) أسئلة متكررة

**س: أستطيع استخدام `requests` بدل `httpx`؟**
نعم، الاثنان يعملان. `httpx` مستخدم في المشروع أصلًا فهو أقرب للاتساق.

**س: كم عينة في الثانية يرسل الجهاز الحقيقي؟**
النافذة 128 عينة، ومعدل ECG المفترَض في الكود 64 عينة/ثانية — أي النافذة ≈ ثانيتان
من الإشارة. للعرض: 32 عينة كل ثانية كافية ومريحة للمشاهدة.

**س: لماذا `assessment` يبقى `null` في أول ثلاث دفعات؟**
لأن السيرفر يحتاج 128 عينة مجمّعة قبل أول تحليل. 4 دفعات × 32 = 128. هذا سلوك سليم.

**س: أرسل `hr` في كل عينة أم في الأخيرة فقط؟**
أرسله في **كل** عينة. السيرفر يأخذ آخر قيمة غير فارغة في النافذة، وإرساله دائمًا
يمنع أي التباس.

**س: هل أضيف كشف السقوط (Fall detection)؟**
ليس الآن. أنجز الأنماط الأربعة أولًا. بعد قبولها نتفق على إضافة قناة IMU كحقل
جديد في العقد — لأن العقد الحالي لا يحتوي حقل تسارع، فإضافته تحتاج تعديلًا في
`backend/` يقوم به مالك المستودع.

**س: أحتاج تعديلًا في `backend/`، ماذا أفعل؟**
لا تعدّله. اكتب في وصف الـ Pull Request ما تحتاجه بالضبط ولماذا، ومالك المستودع
ينفّذه.

**س: هل أستخدم `/device/ingest-window` بدلًا من `/device/ingest`؟**
لا، إلا إذا طُلب منك. `/device/ingest` هو المسار الطبيعي للبثّ المتصل.
(`/device/ingest-window` يرسل نافذة كاملة دفعة واحدة: ثلاث مصفوفات `eeg` و`ecg`
و`motion` متساوية الطول، من 8 إلى 4096 قيمة.)

---

## 16) للمراجعة

| المصدر | الغرض |
|---|---|
| `backend/device_gateway_sim.py` | **المحاكي المرجعي المعتمد** — أفضل مثال أمامك. اقرأه |
| `docs/api.md` | مرجع كل نقاط النهاية |
| `docs/hardware_integration.md` | بروتوكول الجهاز الحقيقي / ESP32 |
| `docs/repo-governance-ar.md` | قواعد المستودع بالتفصيل |
| `http://127.0.0.1:8000/docs` | تجربة تفاعلية مباشرة للـ API |

تشغيل المحاكي المرجعي لترى النتيجة المتوقعة قبل أن تكتب كودك:

```bash
python backend/device_gateway_sim.py --patient-id patient-demo --pattern preictal_ramp
```

---

## 17) خطة عمل مقترحة

| # | المهمة | معيار الإتمام |
|---|---|---|
| 1 | شغّل السيرفر وافتح `/docs` | `/health` يرجع `status: ok` |
| 2 | شغّل المحاكي المرجعي بنمط `preictal_ramp` | ترى الحالة تتصاعد في الطرفية |
| 3 | انسخ مثال القسم 8 وشغّله | ترى `احتمال_ما_قبل_النوبة` يرتفع |
| 4 | أضف `argparse` والأنماط الأربعة | الأوامر الأربعة في القسم 9 تعمل |
| 5 | أضف ملف الاختبارات | `pytest -q` ينجح |
| 6 | اكتب `README.md` في مجلدك | فيه أمر التشغيل ولقطة مخرجات |
| 7 | راجع قائمة القسم 11 بندًا بندًا | 13 بندًا ✓ |
| 8 | افتح Pull Request | كل الفحوص ✓ خضراء |

بالتوفيق — وإن توقفت عند أي خطوة، أرسل **نص رسالة الخطأ كاملًا** وأمر التشغيل
الذي استخدمته. هذا يوفّر وقتًا على الجميع.
