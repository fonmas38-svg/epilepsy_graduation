# partners/hardware-sim — محاكي جهاز الرأس التفاعلي (Headband Device Simulator)

هذا المجلد يحتوي على **محاكي جهاز الرأس (Device Simulator)** الذي يعمل كعميل (Client) يرسل البيانات الحيوية المحاكاة إلى خادم المشروع الرئيسي (`FastAPI`).

---

## 📌 مميزات المحاكي
1. **بدون Datasets خارجية**: يولّد إشارات حيوية صناعية مترابطة زمنياً (EEG + ECG + Motion + Heart Rate) باستخدام معادلات رياضية دقيقة.
2. **المصادقة والتشفير**: يتكامل تلقائياً مع نقطة النهاية `POST /auth/token` للحصول على توكن JWT ورفاقه في جميع طلبات الإرسال.
3. **الأنماط الأربعة (Patterns)**:
   - `stable`: حالة مستقرة وهادئة للمريض.
   - `watch`: حالة تتطلب المراقبة والاحتياط.
   - `high_risk`: حالة خطر مرتفع/نوبة نشطة.
   - `ramp`: التدرج الزمني المستمر من الاستقرار إلى النوبة لتوضيح **التنبؤ المبكر (Prediction)** أمام اللجنة.
4. **تسلسل الدفعات (Idempotency & Deduplication)**: يتضمن `sequence_number` متزايداً لمنع تكرار المعالجة.
5. **اختبارات آلية**: يحتوي على اختبارات وحدة عبر `pytest`.

---

## 🚀 كيفية التشغيل

### 1. تشغيل السيرفر الرئيسي (في نافذة Terminal 1):
```bash
cd backend
python -m venv .venv
.venv\Scripts\activate          # على Windows
pip install -r requirements.txt
python data/build_dataset.py
python train_from_dataset.py
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### 2. تشغيل المحاكي (في نافذة Terminal 2):
```bash
cd partners/hardware-sim

# تشغيل نمط التدرج والتنبؤ بالنوبة (الموصى به للعرض)
python sim_client.py --pattern ramp

# تشغيل نمط المستقر
python sim_client.py --pattern stable --batches 10

# تشغيل نمط الخطر المرتفع بسرعة إرسال أعلى
python sim_client.py --pattern high_risk --interval 0.5
```

---

## 🧪 تشغيل اختبارات الوحدة (Unit Tests)
```bash
cd partners/hardware-sim
pytest -v
```

---

## 📁 الهيكل المعتمد
- `sim_client.py`: برنامج المحاكي الرئيسي (Client API Streamer).
- `test_sim_client.py`: اختبارات صحة البيانات ومدى الأرقام الفسيولوجية.
- `requirements.txt`: المكتبات المطلوبة (`httpx`, `pytest`).
