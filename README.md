# النظام الذكي لمراقبة مرضى الصرع والتنبؤ المبكر بالنوبات
## Smart Epileptic Patient Monitoring & Early Seizure Forecasting System
### مشروع تخرج أكاديمي متكامل (الهندسة وعلوم الحاسب — V2.3)

[![Backend API](https://img.shields.io/badge/Backend-FastAPI%20%7C%20Python%203.13-009688.svg)](file:///backend/)
[![Mobile App](https://img.shields.io/badge/Mobile-Flutter%203.x%20%7C%20Dart-02569B.svg)](file:///mobile/)
[![Admin Dashboard](https://img.shields.io/badge/Dashboard-React%2018%20%7C%20Vite-61DAFB.svg)](file:///admin-dashboard/)
[![AI Models](https://img.shields.io/badge/AI%20Engine-PyTorch%20%7C%20ONNX-EE4C2C.svg)](file:///research/)
[![License](https://img.shields.io/badge/Project-Graduation%202026-green.svg)](file:///docs/)

---

## 🌟 نظرة عامة على النظام (System Overview)

يهدف المشروع إلى حماية مرضى الصرع من مخاطر النوبات المفاجئة وحوادث السقوط والوفاة المفاجئة (SUDEP)، من خلال الانتقال من مجرد «الكشف اللاحق للنوبة» إلى **«التنبؤ المبكر والاستباقي» (Preictal Forecasting)**، مع ربط أطراف الرعاية الصحية الثلاثة (المريض، أسرته ومرافقيه، وطبيبه المشرف) في بيئة متزامنة وصامدة تعمل حتى عند انقطاع شبكة الإنترنت.

### حالة التنفيذ ونتائج التدقيق

راجع [التقييم الشامل بتاريخ 20 أكتوبر 2026](docs/SYSTEM_AUDIT_2026_10_20_AR.md) قبل الاعتماد على أرقام أو ادعاءات وردت في وثائق أقدم.

- تطبيق الهاتف ينفذ حاليًا قواعد حسابية محلية؛ وجود ملف ONNX في الأصول لا يعني تشغيله. تم تصحيح مصدر النتائج إلى `simulated_heuristic`.
- الخادم يدعم نماذج PyTorch وبدائل حسابية عند تعذر تحميلها. يجب التحقق من المحرك النشط ومطابقة معالجة الإشارة للتدريب.
- سكربت `research/train_seizure_cloud.py` يولد Dataset B صناعيًا؛ نتائجها لا تثبت أداءً سريريًا على مرضى CHB-MIT ولا أفق إنذار حقيقيًا من 15 إلى 30 دقيقة.
- صُحح اختيار عتبة الدمج ليستخدم مجموعة التحقق بدل مجموعة الاختبار. يلزم إعادة التدريب والتقييم لإنتاج أرقام جديدة؛ لم تُستبدل الأوزان الحالية.
- SMS يفتح محرر الرسائل ويتطلب إرسالًا من المستخدم؛ أما إشعارات FCM فتتطلب إعدادًا فعليًا وتجربة على جهاز.

---

## 📂 الهيكل المعماري للمشروع (Repository Layout)

```
epilepsy_graduation_project/
├── backend/                  # خادم FastAPI، نماذج SQLAlchemy، Alembic، ومحرك التنبؤ السحابي
│   ├── app/                  # مسارات الـ API (المصادقة، المرضى، التنبيهات، الرسائل، التحليل)
│   ├── models/               # أوزان النماذج السحابية (cloud_preictal_model.pt) والبيانات الوصفية
│   └── tests/                # حزمة الاختبارات الآلية للخادم
├── mobile/                   # تطبيق Flutter لثلاثة مستخدمين (المريض، الأسرة، الطبيب)
│   ├── lib/                  # المنطق البرمجي، إدارة الحالة Provider، والواجهات العربية الأصلية
│   ├── assets/models/        # نموذج الهاتف المدمج (edge_seizure_model.onnx)
│   └── test/                 # اختبارات التطبيق ووحدة الاستدلال الطرفي (EdgeModelService)
├── admin-dashboard/          # لوحة تحكم إدارة النظام الطبية (React 18 + Vite + Tailwind/CSS)
│   └── src/                  # صفحات إدارة المستخدمين وتعيين الأطباء وسجلات التدقيق
├── research/                 # الأبحاث، كود التدريب، ومجموعات البيانات السريرية
│   ├── DEFENSE_GUIDE_AR.md   # دليل الأسئلة والأجوبة النموذجية لمناقشة التخرج 🎓
│   ├── colab_seizure_detection.ipynb  # دفتر Google Colab التفاعلي للتدريب السحابي على GPU
│   ├── train_seizure_cloud.py # سكربت بايثون المستقل للتدريب
│   └── models/               # مخرجات الأوزان المصدرة (ONNX / PT)
├── partners/                 # محاكي عتاد أجهزة الرأس (Hardware Simulator)
│   └── hardware-sim/         # محاكاة فيزيائية لإشارات EEG, ECG, Motion, HR
├── docs/                     # التوثيق المعماري والأكاديمي الشامل للمشروع
└── README.md                 # هذا الملف (دليل التشغيل والنظرة العامة)
```

---

## 🚀 التشغيل السريع (Quick Start)

### 1. تشغيل الخادم الخلفي (Backend)
```bash
cd backend
python -m venv .venv
# على ويندوز:
.venv\Scripts\activate
pip install -r requirements.txt
alembic upgrade head
python startup_check.py
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```
* **واجهة التوثيق التفاعلية (Swagger UI):** افتح `http://localhost:8000/docs`

### 2. تشغيل تطبيق الهاتف (Mobile App)
```bash
cd mobile
flutter pub get
flutter run
```
* يدعم التطبيق التبديل بين ثلاثة أدوار: **المريض**، **المرافق/الأسرة**، و**الطبيب المعالج**.
* عند انقطاع الإنترنت، يعمل التقييم الحسابي التجريبي محليًا وتُحفظ التنبيهات لإعادة المزامنة؛ استمرار العمل عند إغلاق التطبيق يحتاج تحققًا منفصلًا على الأجهزة.

### 3. تشغيل لوحة الإدارة (Admin Dashboard)
```bash
cd admin-dashboard
npm install
npm run dev
```
* تفتح اللوحة على: `http://localhost:5173` لإدارة الحسابات وربط الأطباء بالمرضى ومراجعة سجلات الأمان.

### 4. تدريب النماذج على Google Colab
* افتح [Google Colab](https://colab.research.google.com/) وارفع الملف:
  [`research/colab_seizure_detection.ipynb`](file:///research/colab_seizure_detection.ipynb)
* اختر معالج `T4 GPU` وشغّل الخلايا لإعادة تدريب النموذجين وتصدير أوزانهما بالكامل.

---

## 📚 دليل التوثيق الأكاديمي (Documentation Index)

للاطلاع على التوثيق المفصل لكل فصل من فصول كتاب التخرج:
* 👉 **[`docs/README.md`](file:///docs/README.md):** الفهرس الشامل الذي يربط كل ملف بفصله المقابل في كتاب التخرج.
* 👉 **[`docs/PROJECT_FINAL_DOCUMENTATION_AR.md`](file:///docs/PROJECT_FINAL_DOCUMENTATION_AR.md):** الوثيقة الأكاديمية الشاملة الجاهزة للنسخ المباشر لكتاب المشروع (6 فصول).
* 👉 **[`research/DEFENSE_GUIDE_AR.md`](file:///research/DEFENSE_GUIDE_AR.md):** دليل الأسئلة والأجوبة المحرجة والمتوقعة من لجنة المناقشة الجامعية 🎓.
* 👉 **[`docs/api.md`](file:///docs/api.md):** المرجع الشامل لجميع نقاط نهاية واجهة برمجة التطبيقات (API Reference).
* 👉 **[`docs/data-model.md`](file:///docs/data-model.md):** النموذج العلائقي ومخطط قاعدة البيانات (SQL Schema).
* 👉 **[`docs/security.md`](file:///docs/security.md):** معايير التشفير والأمان والخصوصية الطبية.
* 👉 **[`docs/user-guide.md`](file:///docs/user-guide.md):** دليل المستخدم المصور للأدوار الأربعة.

---

## التحقق من الجودة

نتائج الاختبارات الفعلية وحدود التحقق موثقة في [تقرير التدقيق](docs/SYSTEM_AUDIT_2026_10_20_AR.md). نجاح الاختبارات البرمجية لا يثبت الدقة السريرية للنماذج أو وصول إشعارات إلى أجهزة حقيقية.
