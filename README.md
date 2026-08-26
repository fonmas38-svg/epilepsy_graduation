# النظام الذكي لمراقبة مرضى الصرع والتنبؤ المبكر بالنوبات
## مشروع تخرج — MVP بدون جهاز (V2.3)

## أين أكواد Flutter؟
`mobile/` — راجع أيضاً `mobile/README.md`

## ماذا يعمل بدون جهاز؟
- Dataset إشارات موسوم (stable / watch / high_risk)
- تحليل بالنموذج المدرَّب
- عرض حي + تنبيهات
- تخزين محلي (SQLite) + سحابة مبسطة على السيرفر
- مسار جاهز لجهاز الرأس لاحقاً

## التشغيل

### Backend
```bash
cd backend
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
alembic upgrade head
python data/build_dataset.py
python train_from_dataset.py
python startup_check.py
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### Mobile
```bash
cd mobile
flutter pub get
flutter run
```

حساب مريض → تبويب **الجهاز** → **تشغيل من Dataset**

حساب أسرة/طبيب → زر السحابة لتحديث التنبيهات المشتركة.

## توثيق

**ابدأ من `docs/README.md`** — فهرس يربط كل ملف بالفصل الذي يغذّيه في ملف التوثيق
النهائي، ويحدّد ما هو منفَّذ وما هو مخطَّط.

- `docs/README.md` — فهرس التوثيق (نقطة البداية)
- `docs/api.md` — مرجع الـ API
- `docs/data-model.md` — نموذج البيانات ومخطّط SQL
- `docs/BACKEND_ANALYSIS_REPORT_AR.md` — تحليل الـ backend الكامل
- `docs/security.md` — الأمن والخصوصية
- `docs/frontend-plan-ar.md` — خطة الواجهات (تصميم، لم يُنفَّذ)
- `docs/model-requirements-ar.md` — متطلبات نموذج الذكاء الاصطناعي
- `docs/simulator-requirements-ar.md` — متطلبات محاكي الجهاز
- `docs/background-alerts-ar.md` — التنبيهات في الخلفية
- `docs/hardware_integration.md` — بروتوكول جهاز الرأس
- `docs/ADMIN_SYSTEM.md` — نظام مدير النظام
- `docs/backend-runbook.md` — تشغيل الـ backend
- `docs/backend-hosting.md` — الاستضافة
- `docs/hosting-request-ar.md` — فصل خدمة النموذج
- `docs/supabase-migration-ar.md` — الانتقال إلى PostgreSQL/Supabase
- `docs/firebase-setup.md` — إعداد Firebase وFCM
- `docs/ml-eval.md` — تقييم النموذج
- `docs/repo-governance-ar.md` — حوكمة المستودع

