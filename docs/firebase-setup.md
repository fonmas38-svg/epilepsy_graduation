# ملاحظات إعداد Firebase (الإصدار الأول)

## المشروع المعتمد لهذا المستودع

- معرّف مشروع Firebase: `epilepsy-graduation-project`
- معرّف تطبيق Android: `com.epilepsy.monitor.epilepsy_monitor`
- النطاق الحالي: Firebase Cloud Messaging (FCM) لإشعارات الدفع على Android.

يستمر تطبيق الهاتف في المصادقة من خلال backend الخاص بالمشروع.
لا تتطلب آلية العمل الحالية استخدام Firebase Authentication أو Firestore.

## الخدمات المطلوبة فعليًا

- **Cloud Messaging (FCM): مطلوب.** يصبح متاحًا تلقائيًا عند إنشاء مشروع
  Firebase وإضافة تطبيق Android إليه. لا توجد قاعدة بيانات أو نموذج منفصل يجب
  إنشاؤه من أجل FCM.
- **Authentication: غير مطلوب حاليًا.** مصادقة التطبيق منفذة في backend
  باستخدام JWT، لذلك لا تفعّل Email/Password في Firebase إلا إذا تقرر لاحقًا
  استبدال نظام المصادقة الحالي. مزودات Authentication لا تُفعّل افتراضيًا؛ كل
  مزود يحتاج تفعيلًا يدويًا.
- **Cloud Firestore: غير مطلوب حاليًا.** يخزن backend البيانات في SQLite، وليس
  في Firestore. قاعدة Firestore لا تُنشأ تلقائيًا، ويجب إنشاؤها يدويًا فقط إذا
  أصبح التطبيق يستخدمها لاحقًا.

وجود Authentication أو Firestore مفعّلين لا يمنع FCM من العمل، لكنه ليس شرطًا
لهذا المشروع ولا يحتاجهما مسار الإشعارات الحالي.

## قواعد Firestore (اختيارية حاليًا)

لا تؤثر هذه القواعد في FCM. لا تنشرها إلا إذا أنشأت قاعدة Firestore وبدأ المشروع
يستخدمها فعليًا.

```bash
firebase deploy --only firestore:rules
```

ملف القواعد: `docs/firestore.rules`

## ربط تطبيق الهاتف (Android)

1. افتح مشروع `epilepsy-graduation-project` في Firebase Console.
2. افتح **Project settings** > **Your apps** > **Add app** > Android.
3. أدخل القيمة `com.epilepsy.monitor.epilepsy_monitor` تمامًا باعتبارها اسم حزمة Android.
4. نزّل الملف `google-services.json` وضعه في المسار
   `mobile/android/app/google-services.json`.
5. من داخل مجلد `mobile/`، نزّل الاعتمادات وشغّل التطبيق بالأوامر التالية:
```bash
flutter pub get
flutter run --dart-define=DEMO_MODE=false
```

تم إعداد تعريف Google Services plugin وصلاحية إشعارات Android مسبقًا.
يُطبّق plugin فقط عند وجود الملف `google-services.json`، ولذلك تبقى عمليات
البناء دون اتصال أو في وضع العرض التجريبي ممكنة. لا ترفع هذا الملف إلى Git.

لا يحتاج FCM على Android إلى SHA-1 أو SHA-256. يمكن ترك حقلي App nickname
وDebug signing certificate فارغين؛ الاسم المستعار اختياري، وبصمات التوقيع مطلوبة
لخدمات أخرى مثل Google Sign-In وليست مطلوبة لإشعارات FCM الحالية.

## تفعيل Cloud Messaging والتحقق منه

1. افتح Firebase Console ثم مشروع `epilepsy-graduation-project`.
2. افتح **Project settings** > **Cloud Messaging**.
3. تحقق من ظهور **Firebase Cloud Messaging API (V1)** بحالة Enabled. تكون
   مفعّلة تلقائيًا في المشاريع الحديثة. إذا ظهرت Disabled، افتح رابط إدارة API
   وفعّلها في Google Cloud Console للمشروع نفسه.
4. لا تنشئ Legacy server key ولا تضعه في المشروع. يستخدم backend ملف حساب الخدمة
   مع Firebase Admin SDK وواجهة HTTP v1.
5. اترك إعدادات Apple/APNs وWeb Push/VAPID فارغة؛ هذه الإعدادات ليست مطلوبة
   لتطبيق Android الحالي.

## مسار FCM
1. أعد إعداد مشروع Firebase الخاص بـ Android ثم شغّل التطبيق باستخدام `DEMO_MODE=false`.
2. يحصل تطبيق الهاتف على رمز FCM ويسجّله عبر مسار backend المصادق عليه
   `POST /notifications/device-token`؛ ولا يخزّن الرمز في الملف العام للمستخدم.
3. يحافظ المسار `POST /alerts/fcm-stub` في backend على اسمه القديم من أجل التوافق،
   بينما يستخدم transactional outbox القيمة `NOTIFICATION_CHANNEL=fcm` وFirebase
   Admin لإرسال الرسائل الفعلية.
4. وفّر بيانات الاعتماد من خلال `FIREBASE_CREDENTIALS` أو Google Application
   Default Credentials. لا ترفع ملف JSON الخاص بحساب الخدمة إلى Git.
5. تتم معالجة الإشعارات أثناء تشغيل التطبيق في الواجهة من خلال
   `NotificationService`. رسائل FCM التي تحمل `notification` يعرضها Android عند
   وجود التطبيق في الخلفية؛ الإضافة المحلية المنفصلة تلزم فقط لإشعارات محلية
   مجدولة أو لتحكم أوسع في القنوات والمظهر.

## استخدام ملف المفتاح الخاص في Backend

ملف حساب الخدمة الذي نُزّل من **Service accounts** يخص backend فقط. لا تضعه في
`mobile/`، ولا ترفعه إلى Git، ولا ترسله لأي شخص. خزّنه خارج المستودع، مثل:

```text
C:\Users\tc\.secrets\epilepsy-firebase-admin.json
```

تحقق من أن قيمة `project_id` داخله هي `epilepsy-graduation-project`، من دون نسخ
محتوى الملف إلى التوثيق أو المحادثات.

### تشغيل Backend من Windows CMD

نفّذ المتغيرات في نافذة CMD نفسها التي ستشغّل منها `uvicorn`:

```cmd
cd C:\Users\tc\AndroidStudioProjects\epilepsy_graduation_project\backend
.venv\Scripts\activate
set "NOTIFICATION_CHANNEL=fcm"
set "FIREBASE_CREDENTIALS=C:\Users\tc\.secrets\epilepsy-firebase-admin.json"
set "OUTBOX_WORKER_ENABLED=1"
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

استبدل مسار المثال بالمسار الحقيقي للملف. الأمر `set` صالح للنافذة الحالية فقط؛
عند فتح نافذة جديدة يجب تعريف المتغيرات مرة أخرى أو تعريفها في منصة النشر.

### تشغيل Backend من PowerShell

```powershell
cd C:\Users\tc\AndroidStudioProjects\epilepsy_graduation_project\backend
.\.venv\Scripts\Activate.ps1
$env:NOTIFICATION_CHANNEL = "fcm"
$env:FIREBASE_CREDENTIALS = "C:\Users\tc\.secrets\epilepsy-firebase-admin.json"
$env:OUTBOX_WORKER_ENABLED = "1"
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

لا يقرأ المشروع ملف `backend/.env` تلقائيًا. مجرد كتابة القيم فيه لا يكفي؛ يجب
تمريرها إلى بيئة عملية backend كما في الأوامر السابقة.

يمكن التحقق من صلاحية المسار وبنية المفتاح، من النافذة نفسها، قبل تشغيل الخادم:

```cmd
python -c "import os; import firebase_admin; from firebase_admin import credentials; firebase_admin.initialize_app(credentials.Certificate(os.environ['FIREBASE_CREDENTIALS'])); print('Firebase Admin OK')"
```

ظهور `Firebase Admin OK` يعني أن SDK استطاع قراءة ملف حساب الخدمة. لا يثبت ذلك
وحده وصول إشعار إلى الهاتف؛ اختبار الهاتف موضح أدناه.

## تشغيل تطبيق Android لاستقبال FCM

على Android Emulator، يستخدم التطبيق `10.0.2.2:8000` للوصول إلى backend تلقائيًا:

```cmd
cd C:\Users\tc\AndroidStudioProjects\epilepsy_graduation_project\mobile
flutter run --dart-define=DEMO_MODE=false
```

على هاتف Android حقيقي، اجعل الهاتف والحاسوب على الشبكة نفسها، وافتح المنفذ
`8000` في جدار الحماية عند الحاجة، ثم مرر عنوان IPv4 للحاسوب:

```cmd
flutter run --dart-define=DEMO_MODE=false --dart-define=API_BASE_URL=http://192.168.1.20:8000
```

استبدل `192.168.1.20` بعنوان الحاسوب الناتج من `ipconfig`. وافق على صلاحية
الإشعارات عند طلبها، ثم سجّل الدخول بحساب backend. بعد تسجيل الدخول، يسجل التطبيق
FCM token تلقائيًا في `POST /notifications/device-token`.

للتحقق من التسجيل من دون كشف الرمز، استدعِ المسار المصادق عليه:

```text
GET /notifications/device-token/status
```

يجب أن تكون `registered_devices` أكبر من صفر.

## اختبار رسالة من Firebase Console

لاختبار جهاز محدد، افتح **Messaging** ثم **Create campaign** أو
**Create your first campaign**، واختر **Firebase Notification messages**. قد
تختلف أسماء الأزرار قليلًا حسب إصدار واجهة Firebase.

املأ الحقول كالتالي:

| الحقل | القيمة المقترحة |
|---|---|
| Notification name | `Android FCM Test`، اسم داخلي اختياري |
| Notification title | `اختبار تنبيه الصرع` |
| Notification text | `تم إعداد إشعارات Firebase بنجاح` |
| Notification image | اتركه فارغًا |
| Target / App | تطبيق Android ذو الحزمة `com.epilepsy.monitor.epilepsy_monitor` |
| Scheduling | `Now` |
| Android notification channel | اترك القيمة الافتراضية |
| Custom data | اختياري؛ لا يلزم للاختبار الأول |

اضغط **Send test message** ثم ألصق FCM registration token للجهاز. الرمز ليس
المفتاح الخاص وليس محتوى `google-services.json`. للحصول عليه محليًا بعد تسجيل
الدخول وظهور `registered_devices > 0`، يمكن قراءة أحدث رمز من قاعدة التطوير:

```cmd
cd C:\Users\tc\AndroidStudioProjects\epilepsy_graduation_project\backend
sqlite3 data\epilepsy.db "SELECT token FROM push_tokens ORDER BY updated_at DESC LIMIT 1;"
```

استخدم هذا فقط للاختبار المحلي، ولا تنشر الرمز أو تحفظه في مستند عام. ألصق الرمز
في **Add an FCM registration token** ثم أرسل الرسالة. في الواجهة الأمامية للتطبيق
تظهر الرسالة كشريط داخل التطبيق؛ وعندما يكون التطبيق في الخلفية تظهر رسالة
notification التي أرسلها Firebase عبر نظام Android.

## اختبار المسار الكامل من Backend

بعد نجاح رسالة Firebase Console:

1. اترك backend يعمل مع `NOTIFICATION_CHANNEL=fcm` و`OUTBOX_WORKER_ENABLED=1`.
2. افتح تطبيق Android في `DEMO_MODE=false` وسجّل الدخول حتى يسجّل token.
3. ولّد تنبيهًا فعليًا من تدفق التطبيق أو أرسل payload صالحًا إلى
   `POST /alerts/fcm-stub`. الاسم `fcm-stub` قديم ومحفوظ للتوافق، لكن الرسالة
   توضع في outbox ثم يرسلها Firebase Admin فعليًا.
4. راقب سجل backend. نجاح الإرسال يظهر برسالة `FCM alert dispatched`.
5. يمكن للمدير مراجعة `GET /alerts/outbox`؛ يجب أن ينتقل السجل إلى `sent`. إذا
   بقي `failed`، افحص `last_error` وسجل الخادم.

## قيد Windows

لا توفر إضافة Flutter الرسمية `firebase_messaging` دعم FCM لتطبيقات Windows
desktop. لذلك لا يهيّئ التطبيق FCM ولا يستدعيه على Windows، مع بقائه قابلًا
للاستخدام من خلال مسار تحديث backend/cloud. لإشعارات الدفع على Windows، استخدم
نسخة الويب مع إشعارات المتصفح أو أضف لاحقًا محوّل إشعارات مستقلًا لـ Windows.
لا يمكن لـ Windows استخدام ملف Android `google-services.json` باعتباره إعداد
عميل FCM.

## متغيرات Backend في بيئة الإنتاج

```text
NOTIFICATION_CHANNEL=fcm
FIREBASE_CREDENTIALS=C:\\secure\\firebase-service-account.json
```

يحذف backend الرموز غير الصالحة أو غير المسجّلة. تبقى أخطاء الإرسال المؤقتة
في outbox وتُعاد محاولة إرسالها؛ وقد صُمّم التسليم وفق ضمان at-least-once.
في وضع `APP_ENV=production` تهيئ الخدمة Firebase عند البدء وتفشل مبكرًا إذا كان
ملف بيانات الاعتماد مفقودًا أو غير قابل للقراءة.

## أخطاء شائعة

- `FIREBASE_CREDENTIALS file does not exist`: المسار غير صحيح أو المتغير عُرّف
  في نافذة مختلفة عن نافذة تشغيل backend.
- `no registered FCM tokens for alert recipients`: التطبيق لم يسجّل الدخول إلى
  backend بعد الحصول على token، أو لا توجد علاقة وصول بين المريض والمستلم.
- `SenderId mismatch`: ملف `google-services.json` أو مفتاح حساب الخدمة تابع
  لمشروع Firebase مختلف.
- لا تصل رسالة Firebase Console: تأكد أن الحزمة المختارة صحيحة، وأن token حديث،
  وأن صلاحية الإشعارات ممنوحة للتطبيق في إعدادات Android.
- يعمل الاختبار من Console ولا يعمل من backend: راجع `NOTIFICATION_CHANNEL`،
  ومسار المفتاح، وحالة outbox، وسجل `uvicorn`.
