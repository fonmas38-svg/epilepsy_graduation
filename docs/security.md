# تأمين الخدمة (Security Hardening)

> يغطّي هذا المستند المهمة السابعة: مصادقة JWT، تفعيل HTTPS، وتشفير قاعدة بيانات
> التطبيق. الكود المنفَّذ فعليًا موجود في `backend/app/auth.py` و
> `backend/app/routers/auth.py`؛ هذا الملف يشرح الاستخدام والنشر.

## 1) مصادقة JWT (منفّذة ومختبَرة)

استُبدل التوكن الثابت `headband-demo-token` بنظام JWT موقّع بانتهاء صلاحية وأدوار.

### إصدار توكن
```bash
curl -X POST http://localhost:8000/auth/token \
  -H "Content-Type: application/json" \
  -d '{"subject":"headband-01","role":"device","enrollment_secret":"enroll-device-demo"}'
# -> {"access_token":"eyJ...","token_type":"bearer","role":"device"}
```

### استخدام التوكن في الإدخال
```bash
curl -X POST http://localhost:8000/device/ingest \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  -d '{"patient_id":"p1","samples":[{"eeg":0.2,"ecg":0.5,"motion":0.01,"hr":80}]}'
```

### الأدوار (Roles)
- `device` — أجهزة الرأس (إدخال الإشارات فقط).
- `patient` / `caregiver` / `doctor` — واجهات التطبيق.
- `admin` — كل الصلاحيات.

نقطة `/device/ingest` تقبل دوري `device` و`admin` فقط؛ أي دور آخر يُرفض بـ 403
(مغطّى باختبار `test_auth_wrong_role_cannot_ingest`).

### متغيّرات البيئة للإنتاج
| المتغيّر | الافتراضي | ملاحظة |
|---|---|---|
| `JWT_SECRET` | `dev-only-change-me...` | **إلزامي التغيير** في الإنتاج (مفتاح عشوائي طويل) |
| `JWT_EXPIRE_MINUTES` | `60` | عمر التوكن |
| `AUTH_ALLOW_LEGACY_TOKEN` | `1` | **اجعله `0` في الإنتاج** لإيقاف التوكن الثابت القديم |
| `ENROLL_DEVICE_SECRET` وغيره | `enroll-*-demo` | أسرار التسجيل لكل دور |

توليد مفتاح آمن:
```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

> ⚠️ التوافق الخلفي مع التوكن الثابت مفعّل افتراضيًا **فقط** ليعمل المحاكي
> والاختبارات جاهزة. في أي نشر حقيقي: `AUTH_ALLOW_LEGACY_TOKEN=0`.

## 2) تفعيل HTTPS

### التطوير المحلي (شهادة موقّعة ذاتيًا)
```bash
# توليد شهادة تطوير
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout key.pem -out cert.pem -days 365 -subj "/CN=localhost"

# تشغيل uvicorn عبر TLS
uvicorn app.main:app --host 0.0.0.0 --port 8443 \
  --ssl-keyfile key.pem --ssl-certfile cert.pem
```

### الإنتاج (موصى به: عكس بروكسي + Let's Encrypt)
لا تُصدر TLS من uvicorn في الإنتاج؛ ضع Nginx/Caddy أمامه. مثال Caddy (يجدّد
الشهادة تلقائيًا):
```
api.example.com {
    reverse_proxy 127.0.0.1:8000
}
```
ثم شغّل uvicorn على `127.0.0.1:8000` خلف البروكسي.

### فرض HTTPS في FastAPI (middleware)
أضِف في `app/main.py` عند النشر خلف بروكسي موثوق:
```python
from starlette.middleware.httpsredirect import HTTPSRedirectMiddleware
# فعّل فقط في الإنتاج (لا في الاختبارات المحلية):
if os.getenv("ENFORCE_HTTPS") == "1":
    app.add_middleware(HTTPSRedirectMiddleware)
```
وحصر CORS (حاليًا `allow_origins=["*"]` للتطوير فقط) على نطاق التطبيق الفعلي.

## 3) تشفير قاعدة بيانات التطبيق (SQLite)

التطبيق يخزّن قراءات وتقييمات المريض محليًا في `epilepsy_monitor.db`
(`mobile/lib/services/local_database.dart`). لتشفيرها بالكامل استخدم
**SQLCipher** عبر حزمة `sqflite_sqlcipher`.

### الخطوات في Flutter
1. في `mobile/pubspec.yaml` استبدل `sqflite` بـ:
   ```yaml
   dependencies:
     sqflite_sqlcipher: ^3.1.0
   ```
2. في `local_database.dart` مرّر كلمة المرور عند الفتح:
   ```dart
   import 'package:sqflite_sqlcipher/sqflite.dart';

   Future<Database> _open() async {
     final dbPath = await getDatabasesPath();
     final path = p.join(dbPath, 'epilepsy_monitor.db');
     return openDatabase(
       path,
       password: await _dbPassword(),  // مفتاح التشفير
       version: 1,
       onCreate: (db, version) async { /* نفس الجداول الحالية */ },
     );
   }
   ```
3. **لا تكتب المفتاح في الكود.** خزّنه في المخزن الآمن للنظام:
   ```yaml
   dependencies:
     flutter_secure_storage: ^9.2.2
   ```
   ```dart
   final _secure = const FlutterSecureStorage();
   Future<String> _dbPassword() async {
     var key = await _secure.read(key: 'db_key');
     if (key == null) {
       key = base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
       await _secure.write(key: 'db_key', value: key);
     }
     return key;
   }
   ```
   `flutter_secure_storage` يستخدم Keychain (iOS) وKeystore/EncryptedSharedPreferences
   (Android) — فلا يُخزَّن المفتاح بنص صريح.

### ملاحظة
البيانات الصحية حساسة. عند مزامنتها للسحابة (Firestore)، طبّق قواعد
`docs/firestore.rules` وتأكد أن كل مسار مقيّد بـ `patient_id` المصادَق عليه.

## ملخّص حالة التنفيذ
| البند | الحالة |
|---|---|
| مصادقة JWT + أدوار | ✅ منفّذ ومختبَر (13/13 اختبار) |
| نقطة `/auth/token` | ✅ منفّذة |
| رفض الدور غير المصرّح | ✅ مختبَر |
| توجيهات HTTPS | ✅ موثّقة (تطوير + إنتاج) |
| تشفير SQLite (SQLCipher) | ✅ موثّق بخطوات جاهزة للتطبيق |
