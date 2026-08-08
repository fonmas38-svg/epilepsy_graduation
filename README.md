# النظام الذكي لمراقبة مرضى الصرع والتنبؤ المبكر بالنوبات
## مشروع تخرج — MVP بدون جهاز (V2.1)

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
python data/build_dataset.py
python train_from_dataset.py
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
- `docs/mvp_without_hardware.md`
- `docs/hardware_integration.md`
- `docs/graduation_project.md`
