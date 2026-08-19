# تقرير تحليل وتطوير الـ Backend

**المشروع:** النظام الذكي لمراقبة مرضى الصرع والتنبؤ المبكر بالنوبات  
**تاريخ التحليل:** 16 أغسطس 2026  
**نطاق التقرير:** FastAPI، المصادقة والصلاحيات، تخزين البيانات، استقبال الجهاز، التنبيهات، تكامل الذكاء الاصطناعي، الاختبارات، والتكامل مع Flutter ولوحة الإدارة.  
**حالة التنفيذ:** تم تنفيذ المراحل **P0 → P3** ونصيب backend من P4 وP5. أضيف
سجل أجهزة قابل للإبطال، روابط caregiver، إقرارات متعددة الفاعلين، outcomes، CI،
وrunbook، كما نُفذ مسار FCM البرمجي وتسجيل رموز الأجهزة. نتيجة التحقق الحالية
وقائمة الأعمال المتبقية موثقتان في **القسمين 14 و16**.

هذا الملف بدأ كتقرير خط أساس (قبل أي تعديل)، ثم يُحدَّث بعد كل دفعة. لذلك أقسام
5–8 تصف المشاكل **كما كانت عند الاكتشاف** مع وسم حالتها الآن، وليست قائمة عيوب
حالية. القسم 3 يعرض نتيجة تحقّق خط الأساس التاريخية (32 اختبارًا) وتُركت للمقارنة.

> هذا النظام مشروع تعليمي وليس جهازًا طبيًا معتمدًا. لا يجوز وصف نتائج نموذج Bonn الحالي على أنها تنبؤ سريري مبكر دون نموذج preictal مدرب ومختبر على بيانات مناسبة.

## 1. الملخص التنفيذي

المشروع يملك backend مكتمل الوظائف الأساسية لعرض مشروع تخرج: API مبني بـ
FastAPI، مصادقة وصلاحيات متعددة الأدوار، استقبال بيانات الجهاز، تخزين معاملاتي،
تنبيهات بصندوق صادر، تكامل FCM، تطبيق Flutter، لوحة إدارة، واختبارات. البنية
الحالية مناسبة لـMVP محلي أو خادم واحد مضبوط. لا تُعد جاهزة تلقائيًا لنشر صحي
فعلي أو لتعدد عمليات الخادم قبل تنفيذ اختبارات البيئة الحقيقية ومتطلبات التشغيل
الموضحة في القسم 16.

أهم نتيجة في تحليل خط الأساس كانت أن وجود JWT وحده لم يحقق الحماية المطلوبة. تم
إغلاق الجزء الأكبر من هذه المخاطر في الدفعة الحالية: أضيفت إعدادات بيئية، تحقق
من الحساب والجلسة، سياسة وصول للمريض، ربط `device_id` بتوكن الجهاز، تحقق من
الإشارات، ومنع التكرار. أضيف لاحقًا سجل أجهزة دائم وrate limiting وSQLite مع
Alembic، ثم Firebase Admin وتسجيل FCM tokens وحل المستلمين. بقي **اختبار FCM على
هاتف حقيقي** وقيود النشر متعدد العمليات؛ تنفيذ المحول البرمجي لا يساوي إثبات
التسليم على جهاز فعلي.

الترتيب الصحيح للتطوير هو:

1. توحيد الهوية والصلاحيات وحماية بيانات المريض.
2. تقوية عقود الإدخال وربط الجهاز بالمريض وإصلاح أخطاء البيانات.
3. نقل التخزين إلى قاعدة بيانات مناسبة أو تقوية التخزين الحالي للعرض المحلي.
4. إضافة المراقبة التشغيلية والاختبارات الأمنية واختبارات التكامل.
5. توضيح الفصل بين **اكتشاف النوبة** و**التنبؤ المبكر بها** في الكود والواجهات والتوثيق.

## 2. ما تم فحصه

- نقطة تشغيل FastAPI وجميع الـ routers وعددها الحالي 41 endpoint تقريبًا.
- JWT، تسجيل الدخول بكلمة المرور، الأسرار المشتركة، RBAC، وتعطيل الحسابات.
- `cloud_store` و`users_store` وقواعد Firestore المقترحة.
- استقبال عينات الجهاز وتجميع النوافذ وحالة الاتصال.
- التنبيهات، مسارات dataset، ومحاكيات البيانات والجهاز.
- مصنف المخاطر، نموذج Bonn العميق، والنموذج preictal الاختياري.
- عميل Flutter للـ API وإدارة التوكن والجلسة المحلية.
- لوحة الإدارة وعقود حسابات المدير والطبيب.
- التوثيق، إعدادات التشغيل، dependencies، واختبارات backend.

## 3. التحقق العملي

تم تنفيذ اختبارات المشروع من جذر المستودع مع ضبط مسار Python:

```cmd
set PYTHONPATH=backend&& python -m pytest backend/tests -q
```

النتيجة الحالية:

```text
91 passed, 1 warning in 133.47s
```

التحذير ناتج عن توافق `fastapi.testclient` مع إصدار `httpx` الحالي. كما نجح
`backend/startup_check.py` على SQLite حقيقي وظهرت `STARTUP OK` و`SHUTDOWN OK`.
نجاح الاختبارات مفيد، لكنه لا يغطي الثغرات التالية التي تم إثباتها يدويًا:

| السيناريو المختبر | النتيجة الفعلية |
|---|---|
| بيانات patient-scoped في وضع production دون توكن | مرفوضة عبر `REQUIRE_PATIENT_AUTH` |
| الوصول إلى مريض غير مرتبط به | مرفوض عبر `authorize_patient_access` |
| استخدام توكن حساب بعد التعطيل أو تغيير كلمة المرور | مرفوض عبر `sessionVersion` |
| توكن جهاز مع `device_id` مختلف | مرفوض |
| إعادة إرسال `batch_id` أو sequence قديم | لا يعيد إدخال العينات |
| إرسال قنوات بأطوال مختلفة إلى `/device/ingest-window` | `422` بدل `500` |
| كشف التوكن التجريبي من `/device/token-info` في production | لا يظهر |
| تشغيل مجموعة اختبارات backend الكاملة | 96 اختبارًا ناجحًا (SQLite)، وتُشغَّل نفسها على PostgreSQL 16 في CI |


كما أثبت سجل بدء التشغيل أن:

- نموذج `cnn_lstm_bonn.pt` للكشف متاح ويعمل.
- نموذج `cnn_lstm_chbmit.pt` الخاص بالـ preictal غير موجود.
- التنبؤ المبكر الحي يعود حاليًا إلى heuristic وليس نموذج CHB-MIT مدربًا.
- إعداد المدير الافتراضي قد يستخدم كلمة المرور `change-me-admin` عند غياب متغير البيئة.

## 4. نقاط القوة الحالية

1. فصل جيد نسبيًا بين routers، schemas، التصنيف، الجهاز، التخزين، والأمان.
2. نماذج Pydantic مستخدمة في معظم عقود الإدخال بدل التعامل المباشر مع JSON.
3. كلمات المرور مخزنة باستخدام PBKDF2 مع salt ومقارنة ثابتة الزمن، ولا تعاد hashes في الاستجابات.
4. لوحة الإدارة تملك قيود RBAC واضحة لمساراتها الإدارية.
5. النموذج العميق يُحمّل مع fallback ولا يمنع تشغيل الخدمة عند غياب weights.
6. توجد اختبارات جيدة للمسارات الأساسية، الإدارة، المصادقة، ingestion، والجودة.
7. توجد محاكاة متكاملة للجهاز والـ dataset، وهذا مناسب جدًا للعرض أمام اللجنة.
8. توجد مراعاة للحالة offline في Flutter وتخزين محلي وتنبيهات أولية.
9. ملفات البيانات الحساسة المحلية مستثناة من Git بحسب التصميم الحالي.
10. التوثيق يغطي المعمارية والجهاز وواجهات API ولوحة الإدارة، حتى لو احتاج إلى توحيد وتحديث.

## 5. النتائج الحرجة

### C-01: كشف بيانات المرضى دون مصادقة (أُغلق جزئيًا حسب البيئة)

**الخطورة:** حرجة  
**المواضع:** `backend/app/routers/cloud_dataset.py`، `backend/app/routers/device.py`، `backend/app/routers/alerts.py`

في خط الأساس كانت مسارات cloud، حالة الجهاز، وتقييم التنبيه تسمح بالتوافق
المجهول في demo. أضيفت الآن dependency موحدة وسياسة وصول للمريض. في production
تُفرض المصادقة، أما demo فيبقي التوافق المجهول عمدًا للعرض المحلي؛ لذلك لا يجوز
اعتبار demo نشرًا آمنًا على الإنترنت.

**الأثر المحتمل:**

- كشف بيانات صحية وإشارات وتنبيهات.
- تعداد المرضى ومعرفاتهم.
- إنشاء تنبيهات كاذبة أو إفساد حالة المريض.
- عدم تطابق الحماية بين FastAPI وقواعد Firestore المكتوبة في التوثيق.

**الحالة الحالية:** تحققت هذه السياسة عبر `get_optional_principal` و
`authorize_patient_access` في المسارات الحالية. ما زال مطلوبًا توسيع اختبار
مصفوفة الصلاحيات لكل endpoint جديد عند إضافته.

### C-02: انتحال أدوار بشرية عبر سر enrollment مشترك (أُغلق في production، باقٍ في demo)

**الخطورة:** حرجة  
**المواضع:** `backend/app/routers/auth.py`، `mobile/lib/core/config.dart`، `mobile/lib/services/token_provider.dart`

يقبل `/auth/token` قيمة `subject` يختارها العميل مع دور `patient/caregiver/doctor` إذا أرسل سر الدور المشترك. الأسرار الافتراضية موجودة داخل تطبيق Flutter، وأي سر داخل تطبيق عميل يمكن استخراجه. لا يتحقق endpoint من وجود الحساب أو كونه مفعلًا.

تم إثبات إصدار توكن لـ `not-a-real-user` بدور طبيب، ثم استخدامه لإنشاء حساب مريض بنجاح.

**الحالة الحالية والحل المتبقي:**

- production يمنع enrollment للأدوار البشرية ويشترط `/auth/login` وحسابًا فعالًا.
- demo ما زال يسمح بالمسار القديم لتوافق العرض والاختبارات؛ يجب إبقاءه محليًا فقط.
- enrollment الجهاز ما زال يعتمد سرًا مشتركًا؛ المرحلة التالية تحتاج device registry
  وكود تهيئة أحادي الاستخدام أو mTLS، ولا ينبغي وضع السر الدائم داخل تطبيق عميل.

### C-03: تعطيل أو حذف الحساب لا يبطل التوكن (أُغلق)

**الخطورة:** حرجة  
**المواضع:** `backend/app/security.py`، `backend/app/auth.py`، `backend/app/routers/accounts.py`

تمت إضافة إعادة فحص الحساب بعد فك التوكن، ورفض الحساب المعطل أو المحذوف، مع
`sessionVersion` يزداد عند تغيير كلمة المرور أو التعطيل. التوكن القديم يصبح
مرفوضًا في هذه الحالات.

**اختبار الحالة:** تغطي اختبارات المصادقة ومسارات الإدارة هذا العقد، ويجب إضافة
اختبار صريح للحذف والتعطيل في أي تغيير لاحق على مخزن المستخدمين.

### C-04: قواعد Firestore تسمح برفع الصلاحية ذاتيًا (أُغلق في ملف القواعد)

**الخطورة:** حرجة عند تفعيل Firebase الحقيقي  
**الموضع:** `docs/firestore.rules`

في خط الأساس كانت قاعدة `/users/{userId}` تسمح للمستخدم بتحديث مستنده كاملًا،
وبالتالي تغيير `role` أو `linkedPatientIds`. أصبحت القواعد الحالية تمنع إنشاء
وحذف الهوية من العميل، وتقصر تعديل الملف الشخصي على `name/phone/fcmToken`، وتمنع
كتابة البيانات السريرية من SDK العميل. جهة الكتابة الموثوقة هي FastAPI/Firebase
Admin، الذي يتجاوز rules بحكم تصميم Firebase.

**الحالة الحالية:** تم استخدام `diff().affectedKeys().hasOnly(...)` وإضافة deny
افتراضي. يجب اختبار القواعد بمحاكي Firebase قبل نشرها، وربط claims أو مستندات
الحسابات من السيرفر عند تفعيل Firebase الحقيقي.

### C-05: الجهاز غير مربوط بهوية جهاز أو مريض محدد (تحسين جزئي)

**الخطورة:** حرجة في النشر الحقيقي  
**المواضع:** `backend/app/routers/device.py`، `backend/device_gateway_sim.py`

أصبح هناك تحقق ملزم من تطابق `sub` مع `device_id`، ويمكن لتوكن الجهاز حمل
`patient_id` واستخدام سياسة الوصول عند تفعيلها. كما أن legacy token مرفوض عندما
تُطلب مصادقة المريض، ومخفي من معلومات التوكن في production. أضيف سجل أجهزة دائم
يفرض الارتباط بالمريض وحالة التعطيل و`credential_version`؛
تدوير السر أو التعطيل يبطل التوكن السابق.
**الحالة الحالية:** منفذ ومغطى باختبار تكامل. legacy auth معطل افتراضيًا في
production. يبقى provisioning بمفتاح عتادي أو mTLS ترقية اختيارية لنشر أقوى.

## 6. النتائج عالية الخطورة

### H-01: اختلاف أطوال القنوات يؤدي إلى خطأ 500 (أُغلق)

**الموضع:** `backend/app/routers/device.py`  
تفرض `VitalWindow` و`BatchWindowRequest` تساوي أطوال EEG/ECG/Motion قبل الوصول
إلى منطق الفهرسة. المدخل غير الصحيح يعيد خطأ validation من فئة `4xx` بدل `500`.

**الحالة:** validator على مستوى النموذج يفرض التساوي، مع حد أدنى وأقصى واضح
وقيم finite وHR ضمن نطاق منطقي، وتغطي الاختبارات عقد الإدخال الأساسي.

### H-02: حدود أحجام الطلبات غير كافية (أُغلق للـMVP)

**المواضع:** `backend/app/schemas.py` ومسارات ingestion/analyze/dataset  
أضيفت حدود للقوائم: نافذة الإشارات حتى `4096`، ودفعة العينات حتى `512`،
مع تحقق finite وHR، ثم أضيف middleware لحد HTTP body وrate limiting مع
`Retry-After`. تبقى اختبارات الحمل وضبط القيم على بيئة النشر عملًا تشغيليًا.

**الحل المتبقي:** اختبارات حمل وضبط الحدود ومخزن rate limit مشترك عند تشغيل عدة
workers؛ التنفيذ الحالي داخل العملية ومناسب لعرض worker واحد.

### H-03: أسرار وإعدادات إنتاجية بقيم افتراضية ضعيفة

**المواضع:** `backend/app/auth.py`، `backend/app/users_store.py`، `mobile/lib/core/config.dart`

تشمل القيم الافتراضية JWT secret، أسرار enrollment، legacy device token، وكلمة مرور المدير. التحذير في log مفيد لكنه لا يمنع نشرًا خاطئًا.

**الحل:** `Settings` مركزية؛ في `APP_ENV=production` تفشل الخدمة عند الأسرار الافتراضية أو CORS غير المحدد أو legacy auth؛ وتبقى defaults متاحة فقط في `APP_ENV=demo`.

### H-04: لا توجد حماية من brute force أو إساءة الاستخدام (تحسين منفذ)

**المواضع:** `/auth/login`، `/auth/token`، ingestion، analyze، dataset  
أضيف rate limiting موحد يعيد `429`، وحد لحجم body. لا يوجد lockout دائم موزع حسب
الحساب، لأن المخزن الحالي داخل العملية؛ يلزم Redis أو gateway عند النشر المتعدد.

**الحل:** rate limits حسب IP والحساب والجهاز، lockout متدرج لتسجيل الدخول، سجلات أمنية، وحدود concurrency للاستدلال.

### H-05: التخزين بملفات JSON غير مناسب للتعدد أو الاعتمادية (أُغلق للـMVP المحلي)

**المواضع:** `backend/app/cloud_store.py`، `backend/app/users_store.py`

القفل الحالي داخل process واحد فقط. تشغيل أكثر من worker أو تعطل الكتابة قد يسبب فقد تحديثات أو تلف ملف. لا توجد معاملات تربط إضافة reading وassessment وalert، ولا migration/versioning/backup واضح.

**الحالة الحالية:** نُقل التخزين التشغيلي إلى SQLite مع SQLAlchemy/Alembic،
ومعاملة ذرية تربط القراءة والتقييم والتنبيه وoutbox، مع استيراد JSON قديم ونسخة
احتياطية. PostgreSQL ما زال مطلوبًا عند نشر متعدد العمليات.

### H-06: ادعاء التنبؤ أوسع من النموذج المتاح حاليًا

**المواضع:** `backend/app/ml/deep_model.py`، `backend/app/ml/preictal_model.py`، التوثيق والواجهات  
النموذج النشط العميق مدرب على Bonn لمهمة ictal vs non-ictal، أي **كشف** نوبة ضمن النافذة. ملف CHB-MIT preictal غير موجود، لذلك مسار التنبؤ الحي heuristic. هذا مقبول كـ MVP إذا عُرض بوضوح، لكنه ليس دليلًا على تنبؤ سريري مبكر.

**الحل:** تسمية النتائج `detection` و`forecast` بوضوح، إظهار `prediction_source`, `modelVersion`, `dataset`, `threshold`, و`available`، وعدم عرض lead time كناتج نموذج مدرب عندما يكون heuristic.

## 7. النتائج متوسطة الخطورة

### M-01: سياسة تفويض المريض تحتاج توسيع مصفوفة الاختبارات

تمت إضافة سياسة مركزية للمسارات التي جرى تقويتها، وتحدد ما إذا كان الفاعل مريضًا
نفسه، طبيبًا مرتبطًا، caregiver مرتبطًا، admin، أو جهازًا. المطلوب المتبقي هو
توسيع مصفوفة الاختبارات لتغطي كل endpoint patient-scoped عند إضافة مسارات جديدة.

### M-02: حالة الجهاز داخل الذاكرة

إعادة تشغيل السيرفر تفقد buffers والحالة الحالية، وتشغيل عدة workers يقسم المرضى بين نسخ مختلفة من `DeviceHub`. هذا قد يعطي status غير صحيح أو يمنع اكتمال النافذة.

**الحل:** في MVP يشغل worker واحد ويوثق ذلك. لاحقًا تستخدم Redis للبفر والحالة أو خدمة ingestion مستقلة.

### M-03: idempotency وتسلسل العينات (أُضيفت للـ ingestion)

مسار device ingestion يدعم الآن `batch_id` و`sequence_number` ويرفض إعادة معالجة
الحزمة نفسها أو الحزم الأقدم. ما زال `Idempotency-Key` العام غير مطبق على كل
المسارات، كما أن كشف الحزم المفقودة يحتاج سياسة خاصة بمعدل أخذ العينات.

### M-04: timestamps يثق بها النظام أكثر من اللازم

يجب توحيد UTC، التحقق من timezone، رفض المستقبل البعيد والقديم جدًا حسب السيناريو، وتسجيل `receivedAt` من السيرفر منفصلًا عن `capturedAt` من الجهاز.

### M-05: alert acknowledgment واسع وغير مضبوط (أُغلق)

أصبح الإقرار مسارًا مستقلاً يأخذ الهوية من JWT، ويطبق سياسة المريض، ويسجل وقتًا
وملاحظة اختيارية وسجلًا مستقلاً لكل فاعل مع idempotency للمحاولة المكررة.

### M-06: CORS واسع

إعداد `allow_origins=["*"]` مناسب لتجربة محلية فقط. يجب تحديد أصل لوحة الإدارة وتطبيقات الويب حسب البيئة.

### M-07: health لا يفرق بين liveness وreadiness (أُغلق)

أضيف `/health/live` للعملية و`/health/ready` للتخزين والنموذج والإعدادات، مع
حالة `degraded` وHTTP `503` عند فشل dependency. يبقى `/health` مسارًا سريعًا
للتوافق ولا يُستخدم بدل readiness.

### M-08: الاستدلال والتخزين غير مراقبين تشغيليًا (أُغلق للـMVP)

أضيف `X-Request-ID` وتسجيل منظم ومقاييس latency/error counters وqueue depth
وحالة إرسال التنبيهات. تبقى المقاييس داخل العملية ولا تشمل backend metrics
موحدًا متعدد العمال.

### M-09: نمو البيانات والسجلات (أُغلق جزئيًا للـMVP)

أضيفت pagination وحدود استرجاع وسياسة retention لمسارات البيانات التشغيلية.
يبقى archive طويل الأمد وتخزين الإشارات الكبير قرار نشر/بيانات لاحقًا.

### M-10: رسائل الأخطاء والإخفاقات الصامتة (تحسين جزئي)

في Flutter توجد عدة `catch (_) {}`، وفي backend توجد fallbacks واسعة. أضيفت
استجابات readiness وlogging وoutbox للحالات التشغيلية، لكن معالجة أخطاء Flutter
وتصنيف كل حالات المزامنة خارج نطاق مسؤول backend.

## 8. نتائج منخفضة الخطورة وجودة المشروع (خط الأساس التاريخي)

البنود التالية سُجلت عند التحليل الأول. أُغلق منها توحيد الإصدار وCI والترحيلات
وrunbook؛ بقي تحذير TestClient وبعض تحديثات الوثائق القديمة غير الحرجة.

1. تشغيل `pytest` من جذر المستودع ليس موحدًا؛ `smoke_test.py` يُجمع بطريقة غير مناسبة ومسار `app` لا يضبط تلقائيًا.
2. يوجد warning متعلق بإصدار `httpx` و`TestClient` ويجب تثبيت نسخ متوافقة.
3. الإصدارات غير موحدة: README يشير إلى V2.1 بينما health يعيد 2.2.0.
4. `docs/graduation_project.md` يحتوي مسارًا قديمًا `f:\end\mobile`.
5. توثيق hardware يقول إن النموذج مدرب على المحاكاة، بينما الخدمة الحالية تحمل Bonn فعليًا.
6. التوثيق يصف Firebase، بينما مسار التشغيل المحلي يعتمد بدرجة كبيرة على JSON/in-memory؛ يجب وصف deployment profiles بوضوح.
7. لا توجد CI ظاهرة لتشغيل اختبارات backend وFlutter وبناء dashboard تلقائيًا.
8. لا توجد migrations رسمية لنماذج البيانات أو versioning لعقد الجهاز والـ API.

## 9. السيناريوهات التي يجب تصميم النظام لها

### الهوية والصلاحيات

- مريض يحاول قراءة مريض آخر.
- طبيب يحاول الوصول إلى مريض غير معين له.
- caregiver أزيل ارتباطه بينما توكنه ما زال صالحًا.
- حساب معطل أو محذوف أو تغير دوره أثناء جلسة مفتوحة.
- جهاز مسروق أو token مسرب يحتاج إلى إبطال فوري.
- admin يغير كلمة مرور مستخدم ويجب إنهاء جلساته السابقة.

### الجهاز والشبكة

- حزم مكررة، متأخرة، خارج الترتيب، أو ناقصة.
- قناة واحدة أقصر أو قيم `NaN/Infinity` أو HR غير منطقي.
- انقطاع الجهاز في منتصف النافذة ثم اتصاله مجددًا.
- جهازان يرسلان للمريض نفسه.
- تغير sampling rate أو firmware أو calibration.
- ضغط إرسال أعلى من قدرة الاستدلال.

### البيانات والتنبيه

- تكرار الطلب بعد timeout دون إنشاء تنبيه مكرر.
- وصول assessment بعد alert أو فشل أحد التخزينين.
- إقرار متزامن من طبيب وcaregiver.
- عدم توفر FCM أو token منتهي.
- retention للإشارات الخام مع بقاء ملخصات التقارير.

### الذكاء الاصطناعي

- weights مفقودة أو تالفة أو metadata غير متوافقة.
- إشارة من جهاز مختلف عن domain التدريب.
- confidence غير معايرة أو drift في الإشارات.
- تعارض deep model مع heuristic أو multimodal fusion.
- false positive متكرر أو false negative دون آلية audit ومراجعة.

### التشغيل

- restart أثناء كتابة البيانات.
- تشغيل workerين على ملفات JSON.
- امتلاء القرص.
- إعداد production بأسرار demo.
- فشل جزئي: API حي لكن التخزين أو النموذج غير جاهز.

## 10. المعمارية المستهدفة المقترحة

لنسخة مشروع التخرج القابلة للدفاع عنها دون تعقيد زائد:

```text
Flutter / Admin Dashboard / Head Device
                  |
          HTTPS + JWT / Device JWT
                  |
              FastAPI
       +----------+-----------+
       |          |           |
   Auth/RBAC   Monitoring   Admin API
       |          |           |
       +------ Service Layer --+
                  |
          Repository Interfaces
                  |
       SQLite (demo) / PostgreSQL
                  |
       Alert Dispatcher + FCM outbox
                  |
        Versioned AI Inference Service
```

المبادئ:

- router رقيق: validation، dependency، وتحويل الاستجابة فقط.
- service layer يطبق use cases والمعاملات.
- repositories تمنع ارتباط المنطق بملف JSON.
- authorization policy مركزية لكل patient-scoped resource.
- outbox للتنبيهات حتى لا يضيع الإرسال عند فشل FCM.
- عقود versioned للجهاز والـ API والنموذج.

## 11. خطة التطوير المقترحة للموافقة

### المرحلة P0: إغلاق الثغرات الحرجة

**الأولوية:** فورية  
**النتيجة المطلوبة:** لا يمكن الوصول إلى بيانات مريض أو تنفيذ فعل حساس دون هوية وعلاقة صحيحة.

1. إضافة إعدادات بيئية مركزية بوضعين `demo` و`production`.
2. إلغاء توكنات enrollment البشرية وربط Flutter بتسجيل دخول الحساب الحقيقي.
3. الإبقاء على enrollment جهاز فقط، ثم ربط device بالمريض.
4. بناء dependencies موحدة: `require_principal`, `require_active_user`, `require_patient_access`.
5. حماية cloud/device status/alerts/analyze/dataset mutation حسب مصفوفة صلاحيات واضحة.
6. إبطال الجلسات عند disable/delete/password reset بواسطة `tokenVersion`.
7. تعطيل legacy token افتراضيًا خارج demo.
8. إصلاح قواعد Firestore ومنع تعديل الدور والروابط من العميل.
9. تقييد CORS وفرض أسرار قوية في production.
10. إضافة اختبارات authorization matrix لكل endpoint.

**تأثير متوقع:** يحتاج تنسيقًا مع زميل Flutter لأن تسجيل الدخول التجريبي الحالي سيستبدل بجلسة حساب حقيقية. يمكن الحفاظ على `DEMO_MODE` محليًا لتجنب تعطيل العرض.

### المرحلة P1: صحة البيانات واعتمادية ingestion

1. فرض تساوي أطوال القنوات وحدود الأحجام والقيم finite والنطاقات.
2. إضافة `capturedAt`, `receivedAt`, `sequenceNumber`, `batchId`, `sampleRateHz`, `firmwareVersion`.
3. إضافة idempotency ومنع التكرار.
4. إرجاع أخطاء `4xx` منظمة بدل `500` للمدخلات الخاطئة.
5. تقييد حجم body وعدد الطلبات ووقت الاستدلال.
6. اختبارات fuzz/property للحزم والقنوات والقيم الحدية.

### المرحلة P2: قاعدة البيانات والمعاملات

1. تعريف entities وجداول users, assignments, devices, readings, assessments, alerts, acknowledgments, audit, notification_outbox.
2. استخدام SQLite للعرض المحلي مع SQLAlchemy وAlembic.
3. معاملات ذرية لمسار القراءة ثم assessment ثم alert/outbox.
4. pagination وفهارس وسياسة retention.
5. migration اختياري من JSON الحالي مع نسخة احتياطية.
6. إبقاء repository interface يسمح بالانتقال إلى PostgreSQL لاحقًا.

### المرحلة P3: التنبيهات والتشغيل

1. FCM حقيقي عبر outbox مع retry وحالة delivery. **منفذ برمجيًا؛ بقي اختبار جهاز فعلي.**
2. request IDs وstructured logging مع إخفاء البيانات الحساسة.
3. liveness/readiness وحالة degraded للنموذج والتخزين.
4. metrics للـ latency، الأخطاء، ingestion، inference، والتنبيهات.
5. global exception handlers واستجابات خطأ موحدة.
6. backup/restore وتجربة فشل التخزين.

### المرحلة P4: حوكمة الذكاء الاصطناعي

1. فصل API وUI بين detection وprediction.
2. تسجيل model version، dataset، threshold، calibration، وsource مع كل assessment.
3. منع تفعيل claim التنبؤ عندما يكون preictal model غير متاح.
4. اختبارات contract بين preprocessing البحثي وproduction inference.
5. تقارير sensitivity, specificity, FPR/hour، ومعايرة threshold على validation patient-independent.
6. سجل outcomes يسمح بقياس false alarms وlead time الفعلي مستقبلًا.

### المرحلة P5: الجودة والتوثيق وCI

1. إصلاح اكتشاف pytest وتثبيت إصدارات dependencies.
2. CI: backend tests، lint/type checks، Flutter analyze/test، dashboard build.
3. توحيد version ومعلومات البيئة.
4. تحديث architecture/data model/API/security/hardware docs.
5. OpenAPI examples وعقد مشترك versioned مع Flutter والجهاز.
6. runbook للعرض أمام اللجنة ووضع demo قابل لإعادة الضبط.

## 12. الاختبارات المطلوبة قبل اعتبار الـ backend جاهزًا

### اختبارات أمنية إلزامية

- كل مسار patient-scoped: بدون توكن `401`، دور غير مسموح `403`، ارتباط صحيح `2xx`.
- لا يمكن إصدار دور بشري من enrollment endpoint.
- الحساب المعطل والمحذوف وتوكنه القديم مرفوضان.
- تغيير كلمة المرور يبطل الجلسات السابقة.
- الجهاز لا يرسل لغير المريض المربوط به.
- لا يستطيع مستخدم تعديل دوره أو assignments.

### اختبارات صحة البيانات

- أطوال القنوات المختلفة تعيد `422` ولا تنتج `500`.
- رفض القيم غير المحدودة والأحجام الكبيرة والنطاقات غير المنطقية.
- retry بنفس idempotency key لا يكرر القراءة أو التنبيه.
- timestamps القديمة/المستقبلية وسياسات clock skew.

### اختبارات اعتمادية

- transaction rollback عند فشل assessment أو alert.
- restart واستعادة البيانات.
- إرسال متزامن لعدة مرضى وأجهزة.
- load test بمعدل الإرسال المتوقع مع قياس p95 latency.
- فشل FCM ينتقل إلى retry ولا يفقد التنبيه.

### معيار الإنجاز

- لا توجد ثغرة حرجة أو عالية معروفة غير موثقة ومقبولة صراحة.
- جميع الاختبارات الحالية والجديدة ناجحة.
- لا ينتج `500` عن مدخل عميل غير صالح.
- كل بيانات مريض محمية بسياسة وصول واختبار مقابل.
- وضع production يرفض البدء بإعدادات demo.
- واجهة المستخدم تعرض بصدق إن كانت النتيجة detection، model prediction، أو heuristic.

## 13. ترتيب مقترح يناسب فريقًا من ثلاثة طلاب

**مسؤول backend:** الهوية والصلاحيات، قاعدة البيانات، ingestion، التنبيهات، العقود، الاختبارات، والمراقبة.  
**مسؤول Flutter/frontend:** استبدال demo login، تمرير JWT، التعامل مع 401/403، حالات offline/degraded، وعرض مصدر التنبؤ.  
**مسؤول AI:** تثبيت preprocessing contract، تدريب/تقييم preictal model، model metadata/versioning، والمعايير السريرية.  

ينبغي الاتفاق أولًا على عقدين مشتركين:

1. `Auth + Patient Access Contract` بين backend وFlutter/dashboard.
2. `Signal + Model Output Contract` بين backend وAI والجهاز.

## 14. حالة التنفيذ وقرار الدفعة التالية

تم تنفيذ **P0 وP1 وP2 وP3 وP5**، ونصيب backend المطلوب من P4. نتيجة التحقق
النهائية محليًا: `91 passed, 1 warning`، إضافة إلى نجاح startup check على SQLite
حقيقي. هذا يثبت مسارات الكود المحلية، ولا يثبت Firebase الخارجي أو PostgreSQL أو
بيئة HTTPS؛ لكل منها اختبار قبول منفصل في القسم 16.

| المرحلة | الحالة | ما تم فعليًا |
| --- | --- | --- |
| **P0** أمان حرج | ✅ منفّذ | فصل demo/production، `authorize_patient_access`، إبطال التوكن عند تعطيل/حذف الحساب أو تغيير كلمة المرور، ربط `device_id` بتوكن الجهاز، إخفاء توكن demo في production. |
| **P1** صحة البيانات | ✅ منفّذ | تحقق أطوال القنوات (`422` لا `500`)، رفض NaN/Infinity، حد حجم الطلب (`413`)، rate limiting (`429` + `Retry-After`)، توحيد timestamps ورفض clock skew، منع replay عبر `batch_id`/`sequence_number`. |
| **P2** قاعدة البيانات | ✅ منفّذ / ⚠️ PostgreSQL غير مختبر خارجيًا | SQLAlchemy، ترحيلات Alembic، `save_monitoring_bundle` كمعاملة ذرّية واحدة، pagination، وretention. أضيف دعم PostgreSQL/Supabase عبر `DATABASE_URL` وupsert مستقل عن اللهجة؛ بقي تشغيل الترحيلات والاختبارات على قاعدة PostgreSQL فعلية. |
| **P3** التنبيهات والتشغيل | ✅ منفّذ برمجيًا / ⚠️ اختبار خارجي متبقٍ | صندوق صادر معاملاتي، Firebase Admin، مخزن FCM tokens خاص، حل المستلمين حسب علاقات الرعاية، حذف الرموز غير الصالحة، retries، health/readiness، metrics، وتسجيل منظم. بقي اختبار Android فعلي ببيانات اعتماد حقيقية. |
| **P4** حوكمة الذكاء الاصطناعي | ⚠️ نصيب backend منفّذ | فصل **detection** عن **prediction**، إعلان `prediction_source` وmetadata، و`/model/info`، وإضافة outcomes مرتبطة بالتقييم/التنبيه لقياس false alarms وlead time لاحقًا. المتبقي لمسؤول AI: تدريب preictal على بيانات مناسبة وتقييم patient-independent. |
| **P5** الجودة وCI | ✅ منفّذ للـMVP | `.github/workflows/ci.yml` يشغّل backend tests + startup check ويبني dashboard ويحلل/يختبر Flutter، مع lint استشاري. أضيف `docs/backend-runbook.md` ووُحّد API version إلى `2.3.0`. |

**ملاحظات صريحة على ما لم يُغلق بعد (مهمة قبل المناقشة):**

- **FCM منفذ ولم يُثبت على هاتف حقيقي بعد:** يحتاج `google-services.json` لتطبيق
  Android، وبيانات اعتماد Firebase Admin للـbackend، ثم اختبار foreground وbackground
  ومراجعة انتقال outbox إلى `sent`. لا تحفظ أي مفتاح داخل Git.
- **دعم Supabase/PostgreSQL منفّذ في الكود ولم يُختبر على قاعدة حقيقية:**
  `database.py` يقرأ `DATABASE_URL`، وعمليات upsert صارت مستقلة عن اللهجة،
  و`NOCASE` استُبدل بفهرس فريد على `lower(username)`، و`alembic/env.py` يستهدف
  القاعدة نفسها. المتبقي تشغيلي: تنفيذ الترحيلات على مشروع Supabase فارغ، تشغيل
  مجموعة الاختبارات مقابل PostgreSQL، ثم ETL للبيانات. نجاح SQLite لا يثبت
  PostgreSQL. مجرد إنشاء المشروع في لوحة الخدمة لا ينقل البيانات ولا يشغّل FastAPI.

- **المتبقي من P4 ليس دور الـ backend** بل دور مسؤول AI: تدريب preictal والتقييم
  patient-independent. إعلان المصدر والعتبات وسجل outcomes منجز في backend.
- **المقاييس وrate limiting وDeviceHub داخل العملية:** عند تشغيل عدة workers يجب
  نقل الحالة المشتركة إلى Redis أو خدمة مناسبة. للـMVP يجب تثبيت Uvicorn على worker
  واحد.
- **التسليم at-least-once:** تعطّل بعد الإرسال قد يكرر الإشعار. هذا عقد مقصود
  وموثق، ويجب أن تتعامل الواجهة مع `alert_id` لمنع الإظهار المكرر قدر الإمكان.

**القرار الحالي:** لا توجد ميزة backend أساسية ناقصة تمنع عرض MVP محليًا بقاعدة
SQLite وقناة `stub`. العرض الذي يدعي Push حقيقي يحتاج اختبار FCM الفعلي أولًا.
النشر العام يحتاج HTTPS وأسرارًا ونسخًا احتياطيًا واختبار استعادة. أما PostgreSQL
وRedis فهما مشروطان بقرار Supabase أو تعدد العمليات، وليسَا شرطًا لعرض خادم واحد.

## 15. الملفات التي شملتها الدفعة الحالية والملفات المتوقعة لاحقًا

### دفعة P0/P1 (الأمان وصحة البيانات)

- `backend/app/auth.py`
- `backend/app/security.py`
- `backend/app/schemas.py`
- `backend/app/routers/auth.py`
- `backend/app/routers/accounts.py`
- `backend/app/routers/device.py`
- `backend/app/routers/cloud_dataset.py`
- `backend/app/routers/alerts.py`
- `backend/app/routers/model_info.py`
- `backend/app/users_store.py`
- `backend/app/cloud_store.py`
- `backend/app/device_hub.py`
- `backend/app/main.py`
- `backend/tests/test_api.py`
- `docs/BACKEND_ANALYSIS_REPORT_AR.md`

### دفعة P2 (قاعدة البيانات والمعاملات)

- `backend/app/database.py` — المحرك والجداول و`session_scope`
- `backend/app/repositories.py` — `save_monitoring_bundle` كمعاملة ذرّية
- `backend/alembic/` + `backend/alembic.ini` — الترحيلات
- `backend/tests/test_persistence.py`

### دفعة P3 (التنبيهات والتشغيل)

- `backend/app/alert_outbox.py` — صندوق الصادر مع backoff وحالة `dead`
- `backend/app/notification_delivery.py` — محولا `stub` وFirebase Admin FCM
- `backend/app/push_tokens_store.py` — تسجيل الرموز وحل مستلمي المريض والأدوار
- `backend/app/routers/notifications.py` — register/delete لتوكن المستخدم المصادق
- `backend/alembic/versions/20260816_04_push_tokens.py` — جدول وفهارس FCM tokens
- `backend/app/observability.py` — المقاييس والتسجيل المنظم
- `backend/app/middleware.py` — `X-Request-ID` وسجل الطلبات
- `backend/app/routers/alerts.py` — `/alerts/outbox`
- `backend/app/routers/health.py` — `live`/`ready` + `/metrics`
- `backend/app/main.py` — عامل التصريف في `lifespan`
- `backend/tests/test_operations.py` + `backend/tests/test_outbox_worker.py`
- `docs/api.md`

### ملفات P5 المنفذة

- `.github/workflows/ci.yml` — backend tests وstartup check وdashboard وFlutter.
- `docs/backend-runbook.md` — التشغيل والترحيل والنسخ الاحتياطي وحدود النشر.
- `backend/.env.example` — مرجع متغيرات التشغيل دون أسرار حقيقية.

## 16. قائمة العمل المتبقي لمسؤول الـbackend

القائمة التالية هي الحكم التنفيذي بعد فحص الكود والوثائق. البنود ليست بدرجة
واحدة؛ بعضها شرط للعرض، وبعضها شرط فقط إذا تغيرت بنية النشر.

### A. مطلوب قبل ادعاء أن Push يعمل فعليًا

1. ينشئ مسؤول Flutter/Firebase تطبيق Android مطابقًا لـ`applicationId` الحالي
   ويضع `mobile/android/app/google-services.json` محليًا.
2. يجهز مسؤول backend بيانات اعتماد Firebase Admin خارج المستودع، ويضبط
   `NOTIFICATION_CHANNEL=fcm` و`FIREBASE_CREDENTIALS` على الخادم.
3. يسجل دخول مستخدم فعلي من Flutter، ويتأكد من نجاح
   `POST /notifications/device-token` ومن وجود صف فعال في `push_tokens`.
4. يولد تنبيه `high_risk` ويتأكد من: وصول الإشعار في foreground وbackground،
   وتحول outbox إلى `sent`، وحذف token غير الصالح تلقائيًا.
5. يعيد الاختبار على شبكة ضعيفة وبعد restart للخادم. المسؤولية هنا مشتركة بين
   backend وFlutter؛ لا يمكن إغلاقها باختبار unit فقط.

### B. مطلوب قبل نشر FastAPI على الإنترنت

1. يضبط `APP_ENV=production` وأسرار JWT/enrollment والمدير و`CORS_ORIGINS` من Secret
   Manager أو متغيرات الخادم، ويمنع legacy device auth.
2. ينشر FastAPI خلف HTTPS، ويشغل Alembic قبل الخدمة، ويستخدم worker واحد ما دامت
   `DeviceHub` وrate limits والمقاييس داخل العملية.
3. ينفذ فحص قبول لـ`/health/live` و`/health/ready` ونسخة احتياطية ثم restore،
   ويراقب outbox و`dead` entries ومساحة القرص.
4. ينفذ load test بمعدل الجهاز المتوقع ويثبت p95 latency وحد الطلبات المناسبين.

### C. مطلوب فقط عند اعتماد Supabase/PostgreSQL

**منفّذ في الكود:**

1. ~~استبدال محرك SQLite~~ — `database.py` يقرأ `DATABASE_URL` مع pooling
   (`DB_POOL_SIZE`, `DB_MAX_OVERFLOW`, `DB_POOL_RECYCLE_SECONDS`)، ويحصر PRAGMA
   وconnection args على SQLite، ويبقي SQLite للاختبارات والـdemo.
2. ~~إزالة collation `NOCASE`~~ — صار مقيّدًا بـSQLite، وأضيف فهرس فريد على
   `lower(username)` في الترحيل `20260817_05` يعمل على القاعدتين.
3. ~~استبدال `sqlalchemy.dialects.sqlite.insert`~~ — أضيف `upsert()` مركزي يختار
   لهجة الـINSERT، ويستخدمه `cloud_store` و`alert_outbox` و`push_tokens_store`.
4. ~~إضافة driver~~ — `psycopg[binary]` في `requirements.txt`، مع تطبيع
   `postgres(ql)://` إلى `postgresql+psycopg://`. يبقى تمرير `DATABASE_URL` كسر
   خارج Git واشتراط `sslmode=require` وفق connection string من Sohobcom.
5. ~~تشغيل Alembic من قاعدة فارغة ثم مجموعة الاختبارات عليها~~ — أضيف
   `TEST_DATABASE_URL` (متغير منفصل عن `DATABASE_URL` لأن الاختبارات تنفّذ

   `TRUNCATE`)، ووظيفة CI **Backend tests (PostgreSQL)** تشغّل `alembic upgrade
   head` ثم المجموعة نفسها ثم startup check على PostgreSQL 16 حقيقي في كل push.
   كذلك `explicit_url` يمنع اختبارات الترحيل — التي تنفّذ `downgrade base` — من
   إسقاط جداول القاعدة الحقيقية عند تشغيل المجموعة على PostgreSQL.
7. ~~تنفيذ ETL~~ — `backend/migrate_sqlite_to_postgres.py`: نسخ بترتيب المفاتيح
   الأجنبية داخل transaction واحدة، مصدر SQLite مفتوح `mode=ro`، تحويل booleans،
   إعادة ضبط sequences بـ `setval` (وإلا فشل أول INSERT بتعارض مفتاح)، ومقارنة
   عدد الصفوف مع خروج غير صفري عند أي اختلاف. مغطى في CI وبـ`--dry-run` محليًا.

**متبقٍ (تشغيلي، يحتاج قاعدة الجهة المستضيفة):**

6. اختبار transaction الخاصة بـreading/assessment/alert/outbox، التزامن، restart،
   النسخ الاحتياطي والاستعادة على قاعدة الجهة المستضيفة قبل نقل بيانات حقيقية.
   (ما يقابله على PostgreSQL معزول في CI؛ المتبقي هو الحدود الفعلية للمزود:
   عدد الاتصالات، زمن الشبكة، وسياسة النسخ الاحتياطي في الخطة.)
8. **الوصول إلى Supabase على Sohobcom غير متاح حاليًا.** فحص

   `backend/deploy/check_db_connectivity.py` لمضيف
   `supabase-3446.service.sohobcom.ye` أظهر أن 5432 و6543 مغلقان/محجوبان و443
   فقط مفتوح، أي أن العنوان لوحة تحكم لا نقطة اتصال قاعدة. يلزم connection string
   الحقيقي من زر **Connect**، أو فتح المنافذ، أو تنفيذ الترحيل من داخل شبكة
   المزود. حتى ذلك الحين إثبات PostgreSQL يأتي من CI لا من هذا المضيف.


> Supabase في هذه المعمارية قاعدة PostgreSQL مستضافة. لا يستضيف عملية FastAPI،
> ولا يلزم أن يتصل Flutter بها مباشرة، ولا يلغي FCM تلقائيًا. تفاصيل القرار وخطة
> الترحيل في `docs/supabase-migration-ar.md`، وخطة استضافة FastAPI في
> `docs/backend-hosting.md`.

### D. ليس ضمن مسؤول backend الحالية

- تدريب نموذج preictal حقيقي ونتائج patient-independent مسؤولية AI.
- المحاكي/الجهاز الفيزيائي مسؤولية زميل الجهاز، باستثناء عقد API وتوكن الجهاز.
- UI وحالات الإشعار في Flutter مسؤولية Flutter، مع بقاء endpoint وعامل الإرسال
  والـoutbox ومسح tokens ضمن backend.

### E. تعريف «منجز» حسب سيناريو التسليم

| السيناريو | حكم backend |
| --- | --- |
| عرض محلي: SQLite + stub + worker واحد | **جاهز وظيفيًا** بعد تشغيل الاختبارات وrunbook |
| عرض Push حقيقي على Android | **غير مغلق** حتى نجاح اختبار FCM الفعلي أعلاه |
| نشر عام على خادم واحد + SQLite | **ممكن تقنيًا** بعد بنود الإنتاج والنسخ الاحتياطي والحمل؛ SQLite ليس خيار التوسع |
| نشر على Sohobcom Supabase/PostgreSQL | **مدعوم ومُختبر على PostgreSQL 16 في CI** (ترحيلات + كل الاختبارات + ETL)؛ متوقف على المزود: منافذ 5432/6543 للمضيف الحالي محجوبة (بند C8) |
| عدة FastAPI workers | **غير جاهز** قبل Redis/حالة مشتركة أو إعادة تصميم الأجزاء داخل العملية |


