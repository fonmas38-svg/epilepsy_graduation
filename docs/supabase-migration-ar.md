# استخدام خدمة Supabase بدل Firebase

## الخلاصة قبل التنفيذ

الخدمة الظاهرة في الصور هي مشروع Supabase مستضاف على Sohobcom. يمكن استخدامها
كقاعدة PostgreSQL مركزية، وRealtime، وStorage، ويمكن لاحقًا استخدام Supabase Auth.
لكنها ليست خادم Linux عامًا لتشغيل تطبيق FastAPI أو نموذج Python، وليست خدمة
Android Push بديلة لـ Firebase Cloud Messaging.

في هذا المشروع، Firebase الحقيقي مستخدم حاليًا فقط لتسليم Push إلى Android:

- Flutter يحصل على FCM registration token.
- backend يخزن token ويرسل التنبيه عبر `firebase-admin`.
- البيانات والمصادقة والمنطق الطبي موجودة أصلًا في FastAPI وSQLite، وليست في
  Firestore أو Firebase Auth رغم وجود حزم Flutter غير مستخدمة لهما.

لذلك يوجد قراران عمليان:

1. **الموصى به:** FastAPI يبقى على VPS، Supabase يستبدل SQLite بـ PostgreSQL،
   ويُحتفظ بـ FCM فقط لإيقاظ الهاتف عند إغلاق التطبيق.
2. **دون Firebase نهائيًا:** استخدم Supabase Realtime للتنبيه أثناء فتح التطبيق.
   عند إغلاق التطبيق لن يصل Push موثوق. لتجاوز ذلك يلزم بناء Foreground Service
   دائم على Android أو تركيب مزود UnifiedPush ذاتي؛ Supabase وحده لا يحقق ذلك.

بالنسبة لنظام تنبيه طبي، لا يُنصح باعتماد Realtime وحده كقناة طوارئ. كما أن هذا
المشروع الأكاديمي لا ينبغي تقديمه كجهاز طبي معتمد أو كبديل لخدمة إسعاف.

## المعمارية الموصى بها

```text
Flutter / Admin Dashboard
          |
          | HTTPS + JWT
          v
FastAPI على VPS  --------->  FCM (Push فقط)
          |
          | اتصال PostgreSQL مشفر
          v
Supabase PostgreSQL
```

لا توصل Flutter مباشرة بجداول المرضى في المرحلة الأولى. FastAPI يحتوي حاليًا
على الصلاحيات، علاقات الطبيب/المريض/مقدم الرعاية، التدقيق، التحقق، outbox والمنطق
السريري. تجاوزه والاتصال المباشر بـ Supabase يكرر هذه القواعد في RLS ويزيد سطح
الخطأ. استخدم Supabase كقاعدة مُدارة خلف FastAPI أولًا.

## المرحلة 1: جمع بيانات الاتصال من Supabase

1. افتح المشروع ثم اضغط **Connect** كما يظهر في الصورة.
2. اختر **ORM** أو **Direct connection**.
3. سجّل داخليًا، ولا ترسل في المحادثة أو Git:
   - Host.
   - Port.
   - Database name.
   - User.
   - Password.
   - SSL requirement.
4. إن كان VPS يدعم IPv6 استخدم Direct connection. إن لم يدعمها، أو أوصت لوحة
   الخدمة بذلك، استخدم **Session pooler** لتطبيق FastAPI طويل العمر.
5. لا تستخدم Transaction pooler مع جلسات طويلة أو عمليات migration إلا بعد
   التحقق من توافقه. نفّذ Alembic عبر Direct أو Session connection.
6. دوّر كلمة مرور قاعدة البيانات فورًا إذا ظهرت في صورة أو مستند مشترك.

صيغة SQLAlchemy المطلوبة غالبًا:

```text
postgresql+psycopg://USER:PASSWORD@HOST:PORT/DBNAME?sslmode=require
```

`postgresql://` المعروض في اللوحة يكفي أيضًا؛ `database.py` يطبّعه إلى
`postgresql+psycopg://` تلقائيًا. أضف `?sslmode=require` بنفسك إن لم تضفه اللوحة.

إذا احتوت كلمة المرور على `@` أو `:` أو `/` أو `?` أو `#` أو `%` فيجب URL-encode
لها، وإلا فسيُقرأ ما بعد الرمز كمضيف أو مسار وتفشل المصادقة برسالة مضلّلة. لا
تكتب القيمة الحقيقية في `.env.example`؛ ضعها فقط في ملف أسرار الخادم.

### قراءة بيانات الاتصال المعروضة في اللوحة

اللوحة تعرض حاليًا:

```text
host: supabase-3446.service.sohobcom.ye
port: 5432
database: postgres
user: postgres.[POOLER_TENANT_ID]
```

النقطة المهمة: صيغة المستخدم `postgres.<tenant>` هي صيغة **Supavisor pooler**، لا
اتصال مباشر، حتى لو كان المنفذ 5432 (نمط session pooler). لذلك:

- ضع الـ tenant id الحقيقي مكان `[POOLER_TENANT_ID]` كما هو في اللوحة؛ النقطة جزء
  من اسم المستخدم ولا تُحذف.
- استخدم هذا الاتصال (session) للترحيلات وFastAPI. لا تستخدم منفذ transaction
  pooler (6543 عادةً) مع Alembic، فهو لا يدعم PREPARE/جلسات طويلة بشكل موثوق.
- percent-encode كلمة المرور قبل تركيبها في السلسلة.

القالب بعد التعويض (ضعه في أسرار الخادم فقط):

```text
DATABASE_URL=postgresql://postgres.TENANT:ENCODED_PASSWORD@supabase-3446.service.sohobcom.ye:5432/postgres?sslmode=require
```


### تحقق من أن العنوان الذي بيدك هو قاعدة بيانات فعلًا

عنوان مثل `https://supabase-<id>.service.sohobcom.ye` هو **لوحة التحكم**، وليس
منفذ PostgreSQL. افحص قبل أي محاولة ترحيل:

```cmd
python backend\deploy\check_db_connectivity.py supabase-3446.service.sohobcom.ye
```

نتيجة الفحص الفعلي لهذا المضيف، وأُعيد التحقق منها بعد استلام بيانات الاتصال
أعلاه (18 أغسطس 2026):

```text
DNS supabase-3446.service.sohobcom.ye -> 195.94.24.216
port 5432: closed/filtered (TimeoutError)
port 6543: closed/filtered (TimeoutError)
port 443: OPEN
```

أي أن المنفذين 5432 (اتصال مباشر) و6543 (pooler) غير متاحين من الخارج، و443 فقط
مفتوح للوحة. **لا يمكن تنفيذ الترحيل أو ETL بهذه الحالة**، حتى مع صحة صيغة
`postgres.TENANT` وكلمة المرور: الفشل شبكي (TCP) وليس فشل مصادقة، فسيظهر كـ
timeout عند `alembic upgrade head` لا كخطأ كلمة مرور. المطلوب أحد التالي:

1. الحصول من لوحة **Connect** على مضيف قاعدة فعلي مختلف إن وُجد (مثل نمط
   `db.<ref>...` أو مضيف pooler منفصل)، ثم إعادة الفحص بعد تعيين `DATABASE_URL`:

   ```cmd
   set DATABASE_URL=postgresql://postgres.TENANT:ENCODED_PASSWORD@HOST:5432/postgres?sslmode=require
   python backend\deploy\check_db_connectivity.py --url
   ```

2. أو مطالبة Sohobcom بفتح 5432/6543 للوصول الخارجي لعنوان IP الخادم.
3. أو تنفيذ الترحيل من داخل شبكة المزود نفسها (نفس الخادم الذي سيشغّل FastAPI).

لا تتقدّم إلى المرحلة 4 قبل أن يعرض السكربت `Database port reachable`.


حتى ذلك الحين يبقى إثبات توافق PostgreSQL عبر job **Backend tests (PostgreSQL)**
في CI، وهو يشغّل الترحيلات والاختبارات وETL على PostgreSQL حقيقي.


## المرحلة 2: تجهيز Supabase

1. من **SQL Editor** لا تنشئ الجداول يدويًا؛ ستنشئها Alembic من مخطط المشروع.
2. من **Database > Extensions** تأكد فقط من توفر الإضافات القياسية التي تحتاجها
   الخدمة. المخطط الحالي لا يحتاج امتدادًا خاصًا.
3. من **Database > Roles** لا تستخدم حساب `postgres` الدائم للتطبيق إن كانت
   الخدمة تسمح بإنشاء role محدود. أنشئ role للـ API بصلاحيات على schema المشروع.
4. فعّل النسخ الاحتياطي أو اعرف سياسة النسخ في الخطة المجانية. كلمة “Free” تعني
   غالبًا حدود سعة/اتصالات واحتمال إيقاف المشروع الخامل؛ راجع تفاصيل Sohobcom.
5. تحقق من مكان استضافة البيانات وسياسة الخصوصية قبل إدخال بيانات مرضى حقيقية.

ملاحظة: مفاتيح `anon` و`service_role` تخص Supabase HTTP APIs. اتصال SQLAlchemy
يحتاج connection string وكلمة مرور قاعدة البيانات، لا مفتاح `anon`.

## المرحلة 3: جعل backend يدعم PostgreSQL

**هذه المرحلة منفّذة في الكود.** لم يبق منها إعداد بيئة فقط. ما تم تعديله:

1. `backend/requirements.txt` يضم driver PostgreSQL (`psycopg[binary]`). لا يُستخدم
   إلا عند تعيين `DATABASE_URL`، فالـ demo على SQLite لا يتأثر.
2. `backend/app/database.py`:
   - يقرأ `DATABASE_URL` ويستخدمه لكل الاتصالات، وإلا يعود إلى `SQLITE_DB_PATH`.
   - يطبّع `postgres://` و`postgresql://` إلى `postgresql+psycopg://`، لأن
     SQLAlchemy يفترض psycopg2 وهو غير مثبَّت هنا؛ بدون ذلك يفشل الاتصال.
   - يحصر `check_same_thread`، إنشاء المجلد، وأوامر PRAGMA على SQLite فقط.
   - يفهرس cache المحركات بالـ URL، فلا تختلط قاعدتان في نفس العملية.
   - يوفّر `upsert()` يختار insert الخاص باللهجة (PostgreSQL/SQLite) مع الحفاظ
     على `on_conflict_*`، فلم يعد أي ملف يستورد SQLite insert مباشرة:
     `cloud_store.py`, `alert_outbox.py`, `push_tokens_store.py`.
3. الترحيلات:
   - `collation="NOCASE"` صار مقيّدًا بـ SQLite لأنه لا وجود له في PostgreSQL.
   - الترحيل `20260817_05` يضيف فهرسًا فريدًا على `lower(username)` ليمنع وجود
     `Admin` و`admin` كحسابين مختلفين على أي قاعدة، ويرفض الترقية إذا وُجد تعارض
     مسبق بدلاً من إسقاط حساب بصمت.
   - `alembic/env.py` يستخدم `DATABASE_URL` عند وجوده، وإلا فإن
     `alembic upgrade head` يُرقّي ملف SQLite محليًا بينما تبقى قاعدة الإنتاج
     على نسخة قديمة.
4. `conftest.py` يحذف `DATABASE_URL` من بيئة الاختبار، حتى لا تُشغّل الاختبارات
   على قاعدة حقيقية وتُدمّر بياناتها.

يتبقى عليك:

1. ضع `DATABASE_URL` في أسرار الخادم (لا في Git).
2. اضبط `RUN_MIGRATIONS_ON_STARTUP=0` في الإنتاج ونفّذ الترحيل كخطوة نشر واحدة،
   حتى لا تتسابق عدة عمليات على تغيير المخطط.
3. اضبط حجم pool بما يناسب حدود الخطة: `DB_POOL_SIZE`, `DB_MAX_OVERFLOW`,
   `DB_POOL_RECYCLE_SECONDS`.

أمر migration بعد وضع المتغير في بيئة آمنة:

```bash
cd backend
alembic upgrade head
```

ثم افحص من **Table Editor** ظهور الجداول، ومنها `users`, `patients`, `readings`,
`alerts`, `alert_outbox`, `push_tokens` و`alembic_version`.

## المرحلة 4: نقل بيانات SQLite الحالية

لا تنقل ملف `epilepsy.db` نفسه إلى Supabase. الأداة جاهزة:
`backend/migrate_sqlite_to_postgres.py`. تقرأ عبر SQLAlchemy ومخطط الجداول نفسه
الذي أنشأ القاعدة، لا CSV يدويًا، لأن booleans (0/1 في SQLite) وsequences وطريقة
الاقتباس تختلف بين المحركين فلا يُحمَّل dump خام بنجاح.

ما يضمنه السكربت:

- ينسخ الجداول بترتيب المفاتيح الأجنبية: `users` ثم `patients`، ثم
  `assignments`/`caregiver_links`/`devices`/`push_tokens`، ثم
  `audit_logs`/`readings`/`assessments`/`alerts`، ثم acknowledgments/outcomes/
  outbox/store_imports.
- النسخ كله داخل transaction واحدة: أي فشل في المنتصف لا يترك قاعدة نصف ممتلئة.
- يفتح SQLite بوضع `mode=ro`، فلا يمكن أن يُتلف المصدر.
- يرفض العمل إذا كان الهدف غير فارغ إلا مع `--truncate` صريح، حتى لا تُخلط
  مجموعتا بيانات.
- يقارن عدد الصفوف لكل جدول بعد الـcommit ويخرج بكود غير صفري عند أي اختلاف.
- يعيد ضبط sequences بـ `setval`؛ بدونها يفشل أول INSERT جديد بتعارض مفتاح لأن
  الصفوف المنسوخة تحمل قيم `sequence` صريحة.

الخطوات:

1. أوقف الكتابة على النظام القديم أو فعّل نافذة صيانة.
2. خذ SQLite backup متسقًا (انظر runbook).
3. أنشئ schema الهدف بواسطة Alembic (`alembic upgrade head` مع `DATABASE_URL`).
4. اعرض الأعداد قبل النقل:

   ```cmd
   python backend\migrate_sqlite_to_postgres.py --dry-run
   ```

5. نفّذ النقل:

   ```cmd
   set DATABASE_URL=postgresql://USER:PASSWORD@HOST:5432/DBNAME?sslmode=require
   python backend\migrate_sqlite_to_postgres.py --sqlite backend\data\epilepsy.db
   ```

6. لا تنقل `push_tokens` إذا قررت حذف FCM نهائيًا (احذف الجدول من `COPY_ORDER`).
7. تحقق من رسالة `OK: ... all row counts match`، وافحص عيّنة صفوف من Table Editor.
8. بعد القبول، اجعل `DATABASE_URL` هو المصدر الوحيد في الإنتاج واحتفظ بالنسخة
   القديمة للرجوع المؤقت فقط.

مسار ETL نفسه مغطى في CI: وظيفة **Backend tests (PostgreSQL)** تُنشئ قاعدة SQLite
جديدة ثم تنسخها إلى PostgreSQL حقيقي وتتحقق من الأعداد.


## المرحلة 5: Realtime عبر Supabase

هذه المرحلة اختيارية لتحسين التحديث أثناء فتح التطبيق، وليست بديل Push كاملًا.

### الخيار الأبسط والأكثر اتساقًا

اترك Flutter يتصل بـ FastAPI ويعمل polling كما يفعل الآن. انتقال قاعدة البيانات
إلى Supabase لا يجبرك على إدخال SDK Supabase في التطبيق، ويظل كل authorization في
مكان واحد.

### خيار Realtime المباشر

إذا أردت أن يستقبل Flutter إدراج alert فورًا:

1. أضف جدولًا أو view عامًا محدود الحقول للتنبيهات؛ لا تبث payload الخام كله.
2. فعّل Realtime replication لهذا الجدول من لوحة Supabase.
3. فعّل RLS قبل السماح للعميل المباشر.
4. أضف `supabase_flutter` إلى Flutter، وهيئه باستخدام Project URL و`anon key` فقط.
5. اشترك في INSERT للتنبيهات المسموح بها، واعرض in-app banner أو local
   notification عند وصول الحدث.
6. ألغ الاشتراك عند logout، وتعامل مع reconnect وجلب الأحداث الفائتة عبر API.

العائق الحالي أن JWT الصادر من FastAPI ليس Supabase Auth JWT. سياسات RLS لن تعرف
علاقات المستخدم تلقائيًا. الحل المحافظ هو أحد التالي:

- تمرير Realtime عبر endpoint WebSocket في FastAPI واستخدام JWT الحالي.
- أو نقل المصادقة كاملة إلى Supabase Auth وإعادة تصميم mapping للأدوار والسياسات.
- أو إصدار JWT متوافق مع Supabase بعناية، وهذا يحتاج إدارة مفاتيح وclaims وسياسات
  دقيقة ولا يوصى به كاختصار.

لذلك لا تستخدم `service_role key` داخل Flutter مطلقًا؛ إنه يتجاوز RLS ويكشف كل
البيانات عند استخراج APK.

## المرحلة 6: إذا كان المطلوب حذف Firebase فقط

يمكن حذف Firebase مع إبقاء FastAPI وSupabase، لكن يجب قبول أن التنبيه يصل أثناء
تشغيل التطبيق فقط:

1. backend:
   - اجعل `NOTIFICATION_CHANNEL=stub` أو أضف قناة `realtime`.
   - احذف شرط الإنتاج الذي يجبر القناة على `fcm`.
   - اجعل outbox يكتب/يبث حدثًا، ثم يعتبره “منشورًا”، لا “شاهده الهاتف”.
   - احذف `firebase-admin` و`FIREBASE_CREDENTIALS` بعد إزالة adapter واختباراته.
2. Flutter:
   - احذف `firebase_core`, `firebase_auth`, `cloud_firestore`,
     `firebase_messaging` من `pubspec.yaml`.
   - احذف `Firebase.initializeApp()` من `main.dart`.
   - استبدل `NotificationService` باشتراك Realtime/WebSocket وبـ
     `flutter_local_notifications` لعرض event وصل والتطبيق حي.
   - احذف تسجيل `/notifications/device-token` وإلغاء التسجيل.
3. Android:
   - احذف Google Services plugin من `settings.gradle.kts` و`build.gradle.kts`.
   - احذف `google-services.json` محليًا.
   - أبقِ `POST_NOTIFICATIONS` إذا كنت تعرض local notifications.
4. قاعدة البيانات:
   - احذف جدول `push_tokens` بترحيل Alembic جديد فقط بعد التأكد من عدم الرجوع.
   - لا تحذف `alert_outbox`؛ يبقى مفيدًا لإعادة بث الأحداث ومراقبة الفشل.

**السلوك الناتج:** عندما يكون التطبيق مفتوحًا واتصاله حيًا يظهر التنبيه. عندما
يكون التطبيق مغلقًا أو قتله Android، لا يوجد مكوّن يوقظه، وقد لا يصل شيء حتى فتحه
وجلب التنبيهات الفائتة.

## المرحلة 7: حذف Firebase مع تنبيه والخلفية

Supabase وحده لا يكفي. أمامك حلان، وكلاهما أعلى مخاطرة من FCM:

### A. Android Foreground Service دائم

1. أنشئ خدمة Android أصلية/Flutter background service تبدأ بعد موافقة المستخدم.
2. اعرض إشعارًا دائمًا؛ Android يفرض ذلك على foreground service.
3. أبقِ WebSocket إلى FastAPI، لا اتصالًا مباشرًا بصلاحيات واسعة إلى القاعدة.
4. أضف reconnect مع backoff، heartbeat، وتجديد JWT.
5. اطلب استثناء battery optimization من المستخدم عند الحاجة.
6. أعد تشغيل الخدمة بعد boot وفق سياسات Android والجهاز.
7. عند وصول alert، تحقق من idempotency ثم أنشئ local notification عالية الأهمية.

هذا يستهلك بطارية وبيانات، وقد تغلقه بعض الشركات المصنّعة، ولا يعطي موثوقية FCM.

### B. UnifiedPush ذاتي الاستضافة

1. استضف موزعًا متوافقًا مثل ntfy/UnifiedPush على خادم مستقل.
2. أضف connector متوافقًا إلى تطبيق Android وسجل endpoint لدى backend.
3. خزّن endpoints بسرية مثل push tokens.
4. أضف adapter جديدًا إلى `notification_delivery.py` مع retries وinvalid endpoint
   cleanup واختبارات.
5. يجب أن يوجد distributor متوافق على كل هاتف؛ هذه تجربة نشر أعقد للمستخدم.

هذا يحقق استقلالًا أكبر عن Google، لكنه ليس ميزة توفرها خدمة Supabase في الصور.

## المرحلة 8: نقل المصادقة إلى Supabase Auth (اختياري ولا يبدأ به)

المشروع يملك مصادقة JWT وأدوارًا وإدارة جلسات. نقلها ليس مطلوبًا لاستخدام قاعدة
Supabase. إذا تقرر النقل مستقبلًا:

1. أنشئ users في Supabase Auth، وخزّن domain profiles في جداول منفصلة مرتبطة بـ
   `auth.users.id`.
2. اكتب RLS لكل role وعلاقة doctor/patient/caregiver.
3. اجعل FastAPI يتحقق من Supabase JWT بدل إصدار JWT الخاص به.
4. انقل refresh/logout/session invalidation، ثم عدّل Flutter وadmin dashboard.
5. اختبر منع كل وصول عرضي بين مرضى مختلفين قبل تشغيل Realtime.

لا تجمع نظامي مصادقة للإنتاج دون خطة انتقال واضحة؛ سيصبح تعريف هوية المستخدم
ومصدر الصلاحية ملتبسًا.

## ترتيب التنفيذ الموصى به للمشروع

1. تأكد من حدود خطة Sohobcom ومنحك connection string كاملًا وSSL.
2. ~~عدّل FastAPI لدعم PostgreSQL~~ — منفّذ؛ يكفي تعيين `DATABASE_URL`.
3. شغّل جميع migrations والاختبارات على مشروع Supabase تجريبي فارغ.
4. انقل نسخة بيانات تجريبية وتحقق من العدّ والعلاقات.
5. انشر FastAPI على VPS واربطه بـ Supabase PostgreSQL.
6. اربط Flutter وadmin dashboard بعنوان FastAPI HTTPS؛ لا تربطهما بالقاعدة مباشرة.
7. اختبر التسجيل، الصلاحيات، sync، alert outbox، restart وفقد الشبكة.
8. أبقِ FCM لقناة Push في النسخة الأولى. احذف حزم Firebase Auth/Firestore غير
   المستخدمة فقط بعد فحص imports.
9. إن كان “لا Google إطلاقًا” شرطًا رسميًا، نفّذ proof of concept لـ UnifiedPush
   أو foreground service واختبر على الأجهزة المستهدفة قبل حذف FCM.

## اختبارات القبول

- Alembic ينشئ قاعدة Supabase فارغة من الصفر ويصل إلى `head`.
- كل اختبارات backend تنجح مع PostgreSQL، وليس SQLite فقط. الطريقة:

  ```cmd
  set TEST_DATABASE_URL=postgresql://USER:PASSWORD@HOST:5432/scratch_db
  python -m pytest backend/tests -q
  ```

  `TEST_DATABASE_URL` متغير منفصل عن `DATABASE_URL` عن قصد: الاختبارات تنفّذ
  `TRUNCATE` بين كل اختبار، فيجب أن تكون القاعدة للاستهلاك فقط. أي `DATABASE_URL`
  في الصدفة يُحذف تلقائيًا ولا يمكن أن يُفرّغ بالخطأ.
  ويوجد أيضًا job في CI باسم **Backend tests (PostgreSQL)** يشغّل الترحيلات ثم
  المجموعة نفسها ثم سكربت ETL على PostgreSQL 16 حقيقي في كل push.

- لا يوجد `service_role`, DB password أو connection string داخل Git/APK/Vite.
- مريض لا يستطيع قراءة مريض آخر، ومقدم رعاية يرى المرتبطين فقط.
- alert وoutbox يُكتبان في transaction واحدة.
- إعادة تشغيل FastAPI لا تفقد pending outbox.
- انقطاع Supabase لا يجعل التطبيق يعلن نجاح مزامنة وهميًا.
- التنبيه يصل في foreground، background، وبعد force-stop وفق القناة المختارة.
- يتم قياس زمن وصول التنبيه وفقد الرسائل على شبكة ضعيفة، لا الاكتفاء بتجربة واحدة.

## Supabase Agent Skills (اختياري)

لوحة Supabase تعرض أمرًا لتثبيت مهارات مساعدة لأدوات الذكاء الاصطناعي:

```cmd
npx skills add supabase/agent-skills
```

### ما نُفّذ فعلًا

نُفّذ الأمر على فرع معزول `chore/supabase-agent-skills` (لا على `main`) وبقيت
تعديلات العمل الجارية دون مساس. النتيجة المرصودة:

- ثبّت مهارتين: `supabase` و`supabase-postgres-best-practices`.
- المصدر الوحيد المُلتزَم هو `.agents/skills/` (40 ملف Markdown) مع
  `skills-lock.json` الذي يثبّت hash لكل مهارة.
- `.claude/skills/` وما شابهه ليست نسخًا بل junctions تشير إلى `.agents/skills`،
  ولذلك أُضيفت إلى `.gitignore`: التزامها يضاعف كل ملف أو يتعطّل على أنظمة أخرى.
- **المحتوى توثيقي بالكامل**: لا سكربت `.sh`/`.py`/`.js` ولا خطوة post-install،
  والملف الوحيد غير Markdown هو `skills-lock.json`. أي `curl` داخل النص هو مثال
  في التعليمات لا أمر يُنفّذ تلقائيًا. تقييم المصدر: `0 alerts` من Socket.

### ما يجب الانتباه إليه

- المهارات تُقرأ بصلاحيات الوكيل الكاملة؛ راجعها قبل الدمج إلى `main`، ولا تمنحها
  أو أي أداة `service_role key` أو كلمة مرور القاعدة.
- **لا تفتح المنفذ المحجوب** ولا تغيّر شيئًا في الشبكة، فهي لا تحل العقبة الحالية
  (5432/6543 مغلقان). قيمتها استشارية فقط.
- المهارات موجّهة لمشاريع Supabase السحابية الرسمية (CLI، MCP، Edge Functions،
  RLS، Data API). هذا المشروع يستخدم Supabase كـ PostgreSQL مُدار خلف FastAPI ولا
  يستخدم Data API، فالنافع منها عمليًا هو
  `supabase-postgres-best-practices` (الفهارس، pooling، القفل، upsert، pagination).
- تحذير مهم من مهارة `supabase`: أي جدول في schema مكشوف قد يُقرأ عبر Data API؛
  لذلك إن فُعّل Data API لاحقًا على هذا المشروع فيجب تفعيل RLS على كل الجداول أو
  إبقاء الجداول في schema غير مكشوف. حاليًا الحماية كلها في FastAPI.

الحكم العملي: مقبولة كمرجع على الفرع. لا تدمجها إلى `main` قبل مراجعتها، وابدأ
أولًا بحل حجب المنافذ؛ فهو ما يمنع الترحيل فعلًا.


## ما يلزم قبل بدء التعديل الفعلي


لا ترسل كلمة مرور أو `service_role key`. المعلومات غير السرية الكافية هي:

- هل نافذة **Connect** توفر Direct أم Session pooler أم كليهما؟
- هل الخطة توفر Realtime وEdge Functions أم Database فقط؟
- هل الشرط هو الاستغناء عن Firebase كله، أم الاستغناء عن Firestore/Auth مع إبقاء
  FCM؟
- هل يجب أن يصل الإنذار والهاتف مغلق، أم يكفي أثناء فتح التطبيق للعرض الجامعي؟
