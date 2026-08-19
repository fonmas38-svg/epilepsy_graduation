# استضافة وربط الـ Backend

## القرار المناسب للمشروع الحالي

البنية الحالية هي `FastAPI + SQLite + Alembic + JWT + Firebase Admin + worker`
مع حالة لحظية للأجهزة داخل عملية الخادم. الخيار المباشر للعرض عبر الإنترنت هو
VPS Linux صغير يعمل عليه `uvicorn` بعملية واحدة خلف Nginx وHTTPS.

لا يلزم أن يكون الخادم محليًا. بعد النشر يتصل تطبيق Flutter ولوحة الإدارة بعنوان
HTTPS عام، بينما يستخدم backend Firebase Admin لإرسال FCM إلى أجهزة Android.

## مقارنة الخيارات

| الخيار | هل يلائم الكود الحالي؟ | الملاحظة |
|---|---|---|
| VPS Linux | نعم، دون إعادة كتابة | الاختيار الموصى به للنسخة الحالية |
| Render/Railway/Fly ونحوها | ممكن | يلزم قرص دائم لـ SQLite؛ القرص المؤقت يفقد البيانات |
| Google Cloud Run | ممكن بعد تغيير التخزين | الحاوية مؤقتة وتعدد النسخ لا يناسب SQLite/حالة DeviceHub الحالية |
| Firebase Hosting | لا يشغل Python | يستضيف الواجهة الثابتة فقط |
| Firebase Cloud Functions | ليس نقلًا مباشرًا | يحتاج تكييف التطبيق والتخزين، وله cold starts وحدود تنفيذ |
| Firestore | قاعدة بيانات بديلة فقط | الانتقال إليه إعادة كتابة لطبقة SQLAlchemy/Alembic، وليس مجرد إعداد |
| XAMPP | غير مناسب | Apache/PHP/MySQL لا يشغّل FastAPI؛ سيظل Python خدمة منفصلة |
| دمج backend داخل Flutter | غير صحيح معماريًا | لا يوجد خادم مركزي أو outbox/إدارة/صلاحيات مشتركة، وتنكشف الأسرار |

Firebase لا يستبدل backend هنا. دوره الحالي FCM فقط، وهو متكامل مع الخادم عبر
`firebase-admin`. يمكن نقل النظام مستقبلًا إلى خدمات Firebase، لكن ذلك مشروع
إعادة تصميم للمصادقة والتخزين والـ API والـ worker، لا طريقة استضافة للكود الحالي.

إذا كانت لديك خدمة Supabase وتريد استخدامها بدل SQLite أو تريد تقييم حذف Firebase
كاملًا، راجع الخطة التفصيلية في `docs/supabase-migration-ar.md`. Supabase يمكن أن
يوفر PostgreSQL وRealtime، لكنه لا يوفر Android Push مكافئًا لـ FCM بمفرده.

الكود يدعم PostgreSQL الآن: عيّن `DATABASE_URL` فيستخدمه الخادم والترحيلات معًا،
وبدونه يعود إلى SQLite. هذا يرفع قيد «عملية واحدة» المرتبط بـ SQLite، لكن حالة
`DeviceHub` والمقاييس وrate limiting ما زالت داخل العملية، فلا تزد عدد workers قبل
نقل تلك الحالة إلى مخزن مشترك. في الإنتاج اجعل `RUN_MIGRATIONS_ON_STARTUP=0`
ونفّذ `alembic upgrade head` كخطوة نشر مستقلة.


## السعة التقريبية

- كود backend ونموذجه المباشر صغيران؛ القياس المحلي دون بيانات التشغيل أقل من
  `1 MiB` تقريبًا، بينما بيانات المشروع الحالية تقارب `51 MiB`.
- بيئة Python الأساسية واعتماديات NumPy/SciPy/scikit-learn/Firebase عادة تحتاج
  مئات MB إلى نحو `1-2 GB` على القرص حسب نظام التشغيل والـ wheels.
- PyTorch هو الجزء الأكبر. ثبّت `requirements-ml.txt` فقط إذا كان تشغيل نموذج
  CNN-LSTM على الخادم مطلوبًا. بدونه يعمل النظام بمحرك `sklearn/rules` كما صُمم.
- بداية عملية واحدة مناسبة: `1-2 vCPU` و`2 GB RAM` و`10-20 GB SSD` دون PyTorch.
  مع PyTorch استخدم `4 GB RAM` على الأقل، وراقب الاستهلاك الفعلي قبل العرض.
- SQLite مناسب لـ MVP وعشرات المستخدمين/الأجهزة بحمل معتدل وعملية واحدة. لا يوجد
  رقم مستخدمين مضمون دون اختبار حمل؛ نوافذ الإشارات وتواترها أهم من عدد الحسابات.
- عند الحاجة إلى عدة workers أو ضغط كتابة متزامن، انتقل إلى PostgreSQL وRedis
  لحالة DeviceHub والـ rate limit والـ worker قبل التوسع الأفقي.

لا ترفع ملفات datasets (`bonn.h5` وCSV) إلى خادم التشغيل إلا إذا كان endpoint
يحتاجها صراحة. التدريب والبيانات البحثية ليست متطلبات لخدمة API الإنتاجية.

## نشر VPS (Ubuntu/Debian)

القوالب الجاهزة موجودة في `backend/deploy/`. القيم والمسارات أمثلة ويجب تعديلها.

1. أنشئ مستخدم خدمة باسم `epilepsy` وانسخ المستودع إلى `/opt/epilepsy`.
2. أنشئ virtual environment في `/opt/epilepsy/venv` وثبّت
   `backend/requirements.txt`. لتشغيل deep model ثبّت `requirements-ml.txt` بدلًا منه.
3. أنشئ `/etc/epilepsy-api/` بصلاحيات مقيدة، وضع فيه `backend.env` وملف حساب
   خدمة Firebase. اجعل الملف قابلًا للقراءة من مستخدم `epilepsy` فقط، ولا تضع
   المفتاح داخل Git أو مجلد الويب.
4. أنشئ مجلد `backend/data` بصلاحية كتابة لمستخدم الخدمة، وحمّل متغيرات البيئة،
   ثم نفّذ `alembic upgrade head` من داخل `backend/` قبل أول تشغيل وبعد كل تحديث
   يحتوي migration جديدًا.
5. انسخ `epilepsy-api.service.example` إلى
   `/etc/systemd/system/epilepsy-api.service`، ثم فعّل الخدمة.
6. انسخ إعداد Nginx، استبدل النطاق، ثم أصدر شهادة HTTPS عبر Certbot.
7. اترك Uvicorn على `127.0.0.1:8000` ولا تفتح المنفذ للعامة؛ افتح فقط `80/443`.
8. تحقق من `https://api.example.com/health/live` و`/health/ready`.

يجب تشغيل worker واحد فقط مع SQLite. قالب systemd يثبت `--workers 1` لهذا السبب.
تتحقق الخدمة عند بدء الإنتاج من JWT وCORS وكلمة مرور المدير وقناة FCM، وتحاول
تهيئة Firebase؛ أي مسار مفتاح أو credential غير صالح يمنع بدء خدمة تبدو سليمة.

## ربط العملاء بعد النشر

تطبيق Android يجب بناؤه بعنوان HTTPS العام، وليس عنوان الحاسوب المحلي:

```bash
flutter build apk --release \
  --dart-define=DEMO_MODE=false \
  --dart-define=API_BASE_URL=https://api.example.com
```

لوحة الإدارة يمكن بناؤها بأحد أسلوبين:

- نطاق مستقل: `VITE_API_BASE_URL=https://api.example.com`، وأضف نطاق اللوحة إلى
  `CORS_ORIGINS` في backend.
- النطاق نفسه عبر Nginx ومسار `/api`: اترك `VITE_API_BASE_URL` فارغًا واضبط
  Nginx لخدمة ملفات اللوحة وتمرير `/api` إلى Uvicorn. هذا يلغي احتياج CORS.

لا تضع `JWT_SECRET` أو مفتاح Firebase أو كلمة مرور المدير في Flutter أو Vite.
`google-services.json` إعداد عميل Android وليس مفتاح backend سريًا، لكنه يبقى
خارج Git وفق إعدادات المستودع.

## النسخ الاحتياطي والمراقبة

- خزّن قاعدة SQLite على قرص دائم وخذ نسخة دورية باستخدام SQLite backup API أو
  بعد إيقاف الخدمة؛ لا تنسخ ملفًا نشطًا عشوائيًا أثناء الكتابة.
- احتفظ بنسخة مشفرة خارج الخادم واختبر الاستعادة قبل العرض.
- راقب `systemctl status epilepsy-api` و`journalctl -u epilepsy-api`، إضافة إلى
  `/health/ready` و`/metrics` وحالة `/alerts/outbox`.
- لا ترسل بيانات مرضى حقيقية قبل مراجعة الخصوصية، مدة الاحتفاظ، وإدارة الوصول.
