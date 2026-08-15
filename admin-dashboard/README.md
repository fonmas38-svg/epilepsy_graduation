# لوحة إدارة مراقبة الصرع — Admin Dashboard

لوحة تحكّم ويب (React + Vite، JavaScript) لإدارة حسابات نظام مراقبة مرضى الصرع.
تتصل بالكامل بخادم **FastAPI** عبر **REST**، وتُقدّم:

- **مدير النظام (admin):** تحكّم كامل بكل الحسابات — إنشاء الأطباء والمرضى (وأي دور)،
  تفعيل/تعطيل/حذف، إعادة تعيين كلمات المرور، و**إسناد أي مريض لأي طبيب**، وسجلّ نشاط كامل.
- **الطبيب (doctor):** يرى مرضاه المُسنَدين فقط، يُنشئ مرضى جدد (يُسنَدون إليه تلقائياً)،
  ويعيد تعيين كلمات مرورهم.

الواجهة عربية بالكامل (RTL) وتستخدم نفس لوحة ألوان تطبيق Flutter.

---

## المتطلّبات

- **Node.js ≥ 18** (يتضمّن npm).
- خادم الـ backend يعمل (FastAPI) — انظر `../backend`.

## التشغيل السريع (تطوير)

```bash
# 1) شغّل الـ backend أولاً (نافذة طرفية منفصلة)
cd ../backend
pip install -r requirements.txt
uvicorn app.main:app --reload            # يستمع على http://127.0.0.1:8000

# 2) شغّل لوحة الإدارة
cd ../admin-dashboard
npm install                              # أول مرة فقط
npm run dev                              # http://localhost:5173
```

افتح <http://localhost:5173> وسجّل الدخول بحساب المدير الذي يُنشأ تلقائياً عند أول
تشغيل للخادم (انظر «حساب المدير الأول» أدناه).

> **الوكيل (proxy):** في وضع التطوير تُمرّر Vite كل طلب `/api/*` إلى الـ backend
> (الوجهة الافتراضية `http://127.0.0.1:8000`)، فيصبح الطلب same-origin ولا توجد مشاكل CORS.

## حساب المدير الأول

عند أول إقلاع للخادم يُنشأ حساب مدير تلقائياً من متغيّرات البيئة:

| المتغيّر | الافتراضي | ملاحظة |
|---|---|---|
| `ADMIN_USERNAME` | `admin` | اسم دخول المدير |
| `ADMIN_PASSWORD` | `change-me-admin` ⚠️ | **غيّرها في الإنتاج** — يُطبع تحذير أمني صاخب في السجلّ عند استخدام الافتراضي |
| `ADMIN_NAME` | `System Administrator` | الاسم المعروض |

مثال (PowerShell) لتعيين كلمة مرور آمنة قبل التشغيل:

```powershell
$env:ADMIN_USERNAME = "admin"
$env:ADMIN_PASSWORD = "<كلمة-مرور-قوية>"
uvicorn app.main:app --reload
```

الإنشاء **idempotent**: إن وُجد مدير مسبقاً لا يحدث شيء.

## الإعداد (متغيّرات البيئة)

انسخ `.env.example` إلى `.env` عند الحاجة:

| المتغيّر | الوصف |
|---|---|
| `VITE_API_BASE_URL` | اتركه فارغاً محلياً (يُستخدم وكيل `/api`). عيّنه لعنوان مطلق عند نشر البناء ضد backend بعيد، مثل `http://192.168.1.20:8000`. |
| `VITE_PROXY_TARGET` | وجهة الوكيل أثناء `npm run dev` (الافتراضي `http://127.0.0.1:8000`). |

## البناء للإنتاج

```bash
npm run build      # يُخرج dist/
npm run preview    # معاينة محلية للبناء
```

عند خدمة `dist/` من مضيف ثابت، عيّن `VITE_API_BASE_URL` لعنوان الـ backend،
واضبط CORS في الـ backend للسماح بأصل اللوحة.

---

## البنية

```
src/
  api/            عميل REST رفيع (fetch) + نداءات auth/users/assignments
    client.js       غلاف fetch: يحقن JWT، يعالج الأخطاء، يسجّل الخروج عند 401
    auth.js         /auth/login, /auth/me
    users.js        نطاق admin + doctor لإدارة الحسابات
    assignments.js  إسناد/إلغاء إسناد المريض للطبيب
  context/
    AuthContext.jsx   الجلسة: التوكن في localStorage، bootstrap عبر /auth/me
    ToastContext.jsx  إشعارات خفيفة
  components/       مكوّنات مشتركة (جدول، نافذة، حقول، شارات، حماية المسار…)
  pages/           صفحات لكل مسار (Login, Overview, Doctors, Patients,
                   Assignments, Users, Audit, MyPatients, NotFound)
  lib/             تسميات الأدوار/الحالات + تنسيق التواريخ
  index.css        نظام تصميم RTL كامل
```

**الأمان طبقتان:** المسارات محميّة في الواجهة (`ProtectedRoute` + أدوار)، والـ backend
يفرض RBAC على **كل** طلب — الواجهة لا تثق بالعميل وحده. التوكن نفسه هو JWT الذي
يُصدره الـ backend، فيعمل في كامل الـ API.

للتفاصيل الكاملة لعقد REST ومصفوفة الصلاحيات ونموذج البيانات، انظر
[`../docs/ADMIN_SYSTEM.md`](../docs/ADMIN_SYSTEM.md).
