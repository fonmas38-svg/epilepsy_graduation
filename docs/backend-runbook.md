# دليل تشغيل وتسليم الـ Backend

هذا الدليل يغطي نسخة API `2.3.0`. وضع `demo` للعرض المحلي فقط، وليس للنشر على
الإنترنت أو للاستخدام الطبي.

## 1. التهيئة لأول مرة

من جذر المشروع على Windows CMD:

```cmd
cd backend
python -m venv .venv
.venv\Scripts\activate
python -m pip install --upgrade pip
pip install -r requirements.txt
copy .env.example .env
```

لا يقرأ المشروع `.env` تلقائيًا. حمّل القيم في بيئة التشغيل أو عرّفها من منصة
النشر. للعرض المحلي تكفي القيم الآتية بعد استبدال كلمة المرور والسر:

```cmd
set APP_ENV=demo
set SQLITE_DB_PATH=.\data\epilepsy.db
set JWT_SECRET=replace-with-at-least-32-random-characters
set ADMIN_PASSWORD=replace-this-password
set OUTBOX_WORKER_ENABLED=1
```

## 2. قاعدة البيانات والترحيلات

```cmd
cd backend
alembic upgrade head
alembic current
```

الترحيلات تنشئ الحسابات والمرضى والقراءات والتقييمات والتنبيهات وoutbox، إضافة
إلى سجل الأجهزة وروابط caregiver وإقرارات التنبيه والنتائج السريرية. عند أول
تشغيل، يستورد السيرفر مخازن JSON القديمة مرة واحدة ويضع نسخة احتياطية بجانبها.

لنسخة احتياطية محلية أوقف الخدمة ثم انسخ ملف SQLite:

```cmd
copy data\epilepsy.db data\epilepsy-backup.db
```

للاستعادة: أوقف الخدمة، احتفظ بنسخة من الملف الحالي، أعد الملف الاحتياطي إلى
المسار المحدد في `SQLITE_DB_PATH`، ثم شغّل `alembic upgrade head`.

## 3. فحص ما قبل التشغيل

```cmd
cd backend
set OUTBOX_WORKER_ENABLED=0
python startup_check.py
python -m pytest tests -q
```

النجاح يتطلب ظهور `STARTUP OK` و`SHUTDOWN OK` ونجاح جميع الاختبارات. تحذير
`StarletteDeprecationWarning` الحالي متعلق بتوافق TestClient ولا يغير النتيجة.

## 4. تشغيل العرض المحلي

```cmd
cd backend
set APP_ENV=demo
set ADMIN_PASSWORD=replace-this-password
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

نقاط التحقق:

- Swagger: `http://127.0.0.1:8000/docs`
- Liveness: `GET /health/live`
- Readiness: `GET /health/ready`
- لوحة الإدارة: شغل `npm run dev` داخل `admin-dashboard/`.

تسلسل عرض مقترح: دخول المدير، إنشاء طبيب ومريض وcaregiver، ربط العلاقات، تسجيل
جهاز للمريض، إصدار device JWT، إرسال نافذة، مشاهدة التقييم والتنبيه، تسجيل إقرار
من المريض وcaregiver، ثم تسجيل outcome مرتبط بالتقييم.

## 5. إعداد الإنتاج

يجب ضبط `APP_ENV=production` مع `JWT_SECRET` عشوائي بطول 32 محرفًا على الأقل،
`ADMIN_PASSWORD` قوي، `AUTH_ALLOW_LEGACY_TOKEN=0`، و`CORS_ORIGINS` صريح. تفشل
الخدمة عند البدء إذا بقيت إعدادات demo غير الآمنة.

شغّل SQLite بعملية API واحدة فقط. حالة `DeviceHub` والمقاييس وrate limiting داخل
العملية؛ النشر متعدد workers يحتاج Redis، وقاعدة PostgreSQL هي الترقية المناسبة
للنشر الفعلي متعدد العمليات.

لخطة الاستضافة الكاملة، مقارنة VPS مع Firebase وXAMPP، تقدير الموارد، وقوالب
`systemd` وNginx وربط Flutter ولوحة الإدارة، راجع `docs/backend-hosting.md`.

متطلبات الخادم الأساسية في `requirements.txt`. ملف `requirements-ml.txt` يضيف
PyTorch الاختياري فقط؛ إذا لم يثبت، يرجع المصنف تلقائيًا إلى `sklearn/rules`.

## 6. مراقبة التنبيهات

`GET /alerts/outbox` و`GET /metrics` للمدير يعرضان pending/failed/dead. افحص
السجلات التي تحمل `request_id` عند الخطأ. لا تحذف صفوف `dead` قبل توثيق السبب
وإعادة الإرسال يدويًا.

المسار الحالي يضمن التخزين وإعادة المحاولة، ويدعم مرسل Firebase Admin الفعلي عند
ضبط `NOTIFICATION_CHANNEL=fcm`. يسجل تطبيق Android الرموز في مخزن خاص مرتبط
بالحساب، ويحوّل backend المستلمين المصرح لهم إلى tokens، ويرسل من خلال
`messaging.send_each_for_multicast`، ويحذف الرموز غير الصالحة. راجع
`docs/firebase-setup.md` لإعداد بيانات الاعتماد واختبار جهاز فعلي. يبقى الاسم
`POST /alerts/fcm-stub` للتوافق مع العملاء القدامى ولا يعني أن الإرسال Stub عند
تفعيل قناة `fcm`.

## 7. حدود المسؤولية والحالة النهائية

الباكند يعلن بوضوح مصدر النتيجة ويفصل detection عن prediction، ويحفظ outcomes
لقياس معدل الإنذارات والاستجابة بدقة سريرية عالية عبر خط النماذج الهجين (Bonn + CHB-MIT).

المتبقي قبل نشر حقيقي: اختبار FCM على أجهزة Android فعلية، HTTPS وإدارة أسرار،
PostgreSQL/Redis عند تعدد العمليات، واختبارات حمل واستعادة على بيئة النشر. تلزم
Firebase rules آمنة فقط إذا استُخدم Firestore فعلًا؛ التخزين الحالي في SQLite.
هذه ليست عوائق لعرض MVP محلي مضبوط.