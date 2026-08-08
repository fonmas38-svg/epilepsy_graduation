# ربط جهاز الرأس بمشروع التخرج

## الفكرة
جهاز يُركَّب على رأس المريض يقرأ:
- EEG (نشاط الدماغ)
- ECG / HR (القلب)
- Motion (حركة الرأس/الجسم عبر IMU)

ثم يرسل الأرقام عبر WiFi إلى السيرفر، والنموذج المدرَّب يُخرج:
`stable` / `watch` / `high_risk` مع نسبة ثقة (احتمال).

## مسار البيانات

```
Head Device  --HTTP JSON-->  FastAPI /device/ingest
                                |
                         تجميع نافذة 128 عينة
                                |
                         Preprocess + ML Model
                                |
                    /device/status/{patient_id}
                                |
                         تطبيق Flutter (تبويب الجهاز)
                                |
                         تنبيه عند high_risk
```

## بروتوكول الإرسال (للجهاز الحقيقي / ESP32)

`POST /device/ingest`

Header:
```
Authorization: Bearer headband-demo-token
Content-Type: application/json
```

Body مثال:
```json
{
  "patient_id": "patient-demo",
  "device_id": "headband-01",
  "samples": [
    {"eeg": 0.21, "ecg": 0.55, "motion": 0.02, "hr": 78},
    {"eeg": 0.19, "ecg": 0.52, "motion": 0.01, "hr": 79}
  ]
}
```

عند اكتمال نافذة التحليل يرجع السيرفر `assessment` فيه `label` و `confidence`.

بديل: إرسال نافذة كاملة دفعة واحدة عبر `/device/ingest-window`.

## محاكي الجهاز (بدون هاردوير)

```bash
python backend/device_gateway_sim.py --patient-id patient-demo --pattern high_risk
```

## ملاحظات مشروع التخرج
- حالياً التوكن تجريبي موحّد؛ في النسخة النهائية يُفضّل مفتاح لكل جهاز.
- يمكن استبدال WiFi بـ BLE إلى الهاتف ثم رفع البيانات من التطبيق.
- النموذج الحالي مدرَّب على بيانات محاكاة؛ عند توفر بيانات سريرية يُعاد التدريب بنفس خط الأنابيب.
