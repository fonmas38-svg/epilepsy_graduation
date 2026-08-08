# تطبيق Flutter — مشروع مراقبة الصرع

## أين الأكواد؟

كل أكواد التطبيق هنا:

```
f:\end\mobile\
  lib\
    main.dart
    features\     الشاشات (مريض / أسرة / طبيب / جهاز)
    services\     محاكاة، قاعدة محلية، API، مراقبة
    providers\    حالة التطبيق
```

## التشغيل

```bash
cd f:\end\mobile
flutter pub get
flutter run
```

تأكد أن الـ Backend يعمل على المنفذ 8000.

## ربط جهاز الرأس

1. من التطبيق (حساب مريض) افتح تبويب **الجهاز**
2. اختر **استقبال من الجهاز**
3. من الكمبيوتر شغّل محاكي الجهاز:
```bash
cd f:\end\backend
python device_gateway_sim.py --patient-id patient-demo --pattern high_risk
```

الجهاز الحقيقي لاحقاً يرسل نفس JSON إلى:
`POST /device/ingest` مع الهيدر:
`Authorization: Bearer headband-demo-token`
