# Admin & Account-Management System

The account-management layer adds password login and role-based administration on
top of the existing monitoring API. It is **fully additive**: it introduces new
routes only and never changes the device / analyze / cloud endpoints or their
auth. Tokens minted here are the same JWTs used everywhere else in the API.

- Backend router: `backend/app/routers/accounts.py`
- Store: `backend/app/users_store.py` (file-backed JSON, thread-locked)
- Passwords: `backend/app/security.py` (stdlib PBKDF2-SHA256 — no new dependency)
- Web client: `admin-dashboard/` (React + Vite, REST only)

Base URL (local): `http://127.0.0.1:8000`

---

## Roles

Reuses the existing `Role` literal: `device | patient | caregiver | doctor | admin`.
The dashboard manages the four human roles; `device` is issued elsewhere.

| Role | Capability |
|---|---|
| `admin` | Full control of every account; create doctors, patients, and any-role users; assign/unassign ANY patient↔doctor; enable/disable/delete; reset passwords; read the audit log. |
| `doctor` | Create patient accounts (auto-assigned to self); view and manage ONLY assigned patients; reset an assigned patient's password. |
| `patient` / `caregiver` | Log in and read own profile via `/auth/me`. No administration rights. |

**Guardrails (enforced server-side):** unique usernames (409); only admins create
doctor/admin accounts; a doctor can never touch an unassigned patient (403); a user
cannot disable or delete their own account (400); passwords are always stored hashed.

---

## Data model — `data/users_store.json`

```json
{
  "users": {
    "<id>": {
      "id": "…", "username": "…", "name": "…",
      "role": "admin|doctor|patient|caregiver",
      "passwordHash": "pbkdf2_sha256$…",
      "disabled": false,
      "primaryDoctorId": null,
      "patientId": null,
      "createdBy": "…", "createdAt": "ISO", "updatedAt": "ISO",
      "meta": {}
    }
  },
  "assignments": [ { "patientId": "…", "doctorId": "…", "assignedBy": "…", "assignedAt": "ISO" } ],
  "audit":       [ { "id": "…", "at": "ISO", "actor": "…", "actorRole": "…", "action": "…", "target": "…", "detail": {} } ]
}
```

- For **patients**, `id == patientId`, so one identifier flows through the accounts
  store, the monitoring `cloud_store`, and the Flutter app.
- **Visibility rule:** a doctor sees exactly the patients that have an assignment
  row `(patientId, doctorId)`. `primaryDoctorId` is display-only (who created them).
  The admin can add/remove assignment rows for ANY pair. A patient may be assigned
  to more than one doctor.
- `passwordHash` is **never** returned by the API — `public_user()` strips it.

---

## REST contract

All responses are JSON. Authenticated routes require `Authorization: Bearer <jwt>`.

### Auth

| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/auth/login` | `{username, password}` | `{access_token, token_type, role, user}` |
| GET | `/auth/me` | — | `{user}` (or `{user:null, principal}` for non-stored subjects) |

`login` returns **401** on bad credentials, **403** if the account is disabled.

### Admin (`require_role("admin")`)

| Method | Path | Body / Query | Response |
|---|---|---|---|
| GET | `/admin/overview` | — | `{counts, recentAudit}` |
| GET | `/admin/users` | `?role&q&include_disabled` | `{users: [...]}` |
| GET | `/admin/users/{id}` | — | `{user}` (+`doctorIds` for patients, `patientIds` for doctors) |
| POST | `/admin/doctors` | `{username, name, password?}` | `{user, generatedPassword}` |
| POST | `/admin/patients` | `{username, name, password?, doctor_id?}` | `{user, generatedPassword}` |
| POST | `/admin/users` | `{username, name, role, password?, doctor_id?}` | `{user, generatedPassword}` |
| PATCH | `/admin/users/{id}` | `{name?, username?}` | `{user}` |
| POST | `/admin/users/{id}/password` | `{password?}` | `{ok, generatedPassword}` |
| POST | `/admin/users/{id}/disable` | — | `{ok}` |
| POST | `/admin/users/{id}/enable` | — | `{ok}` |
| DELETE | `/admin/users/{id}` | — | `{ok}` |
| GET | `/admin/assignments` | — | `{assignments: [...]}` |
| POST | `/admin/assignments` | `{patient_id, doctor_id}` | `{assignment}` |
| DELETE | `/admin/assignments` | `{patient_id, doctor_id}` | `{ok}` |
| GET | `/admin/audit` | `?limit` (1–1000, default 200) | `{audit: [...]}` |

### Doctor (`require_role("doctor","admin")`)

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/doctor/patients` | — | `{patients: [...]}` (doctor → assigned only; admin → all) |
| POST | `/doctor/patients` | `{username, name, password?, doctor_id?}` | `{user, generatedPassword}` |
| GET | `/doctor/patients/{id}` | — | `{user}` (403 if not assigned) |
| POST | `/doctor/patients/{id}/password` | `{password?}` | `{ok, generatedPassword}` |

For a doctor caller, `POST /doctor/patients` forces assignment to **self**
(any `doctor_id` in the body is ignored); an admin caller may target another doctor.

**One-time passwords.** When a create/reset request omits `password`, the server
generates one, stores only its hash, and returns the plaintext **once** as
`generatedPassword`. The dashboard shows it in a copy-to-clipboard modal. When a
`password` is supplied, `generatedPassword` is `null`.

### Enriched patient view

`_patient_view` (used by the doctor/patient endpoints) augments `public_user` with
live monitoring data pulled from `cloud_store`:

```json
{ "id": "…", "username": "…", "name": "…", "role": "patient", "disabled": false,
  "currentStatus": "stable|watch|high_risk|null", "lastUpdated": "ISO|null",
  "doctorIds": ["…"] }
```

A newly created patient is mirrored into `cloud_store` (`currentStatus: "stable"`),
so the monitoring pipeline and the Flutter app see them immediately.

---

## RBAC matrix

| Action | admin | doctor | patient / caregiver |
|---|:---:|:---:|:---:|
| Log in, read own profile | ✅ | ✅ | ✅ |
| Create **doctor** / **admin** | ✅ | ❌ | ❌ |
| Create **patient** | ✅ (any doctor) | ✅ (self-assigned) | ❌ |
| Create caregiver | ✅ | ❌ | ❌ |
| Assign / unassign ANY patient↔doctor | ✅ | ❌ | ❌ |
| View all patients | ✅ | ❌ | ❌ |
| View assigned patients | ✅ | ✅ | ❌ |
| Reset patient password | ✅ | ✅ (assigned) | ❌ |
| Rename / disable / enable / delete accounts | ✅ | ❌ | ❌ |
| Read audit log | ✅ | ❌ | ❌ |
| Disable/delete **own** account | ❌ (400) | ❌ | ❌ |

---

## Seeding the first admin

At startup `users_store.seed_admin()` runs (from the app lifespan). It is
idempotent — if any admin exists it does nothing. Otherwise it creates one from:

| Env var | Default | Notes |
|---|---|---|
| `ADMIN_USERNAME` | `admin` | |
| `ADMIN_PASSWORD` | `change-me-admin` | If unset, the default is used and a **loud security warning** is logged. Set a strong password in production. |
| `ADMIN_NAME` | `System Administrator` | |

---

## Security notes

- **Hashing:** PBKDF2-HMAC-SHA256, 200 000 iterations (override with
  `PBKDF2_ITERATIONS`), per-password random salt. Format
  `pbkdf2_sha256$<iters>$<salt_b64>$<hash_b64>`. Verification is constant-time
  (`hmac.compare_digest`) and returns `False` rather than raising. No third-party
  crypto dependency.
- **Tokens:** same JWT (`app.auth.create_token`, HS256) as the rest of the API;
  set a strong `JWT_SECRET` in production.
- **Least exposure:** password hashes never leave the server; generated one-time
  passwords are shown exactly once.
- **Store hygiene:** `users_store.json` (password hashes) and `cloud_store.json`
  (patient data) are git-ignored and recreated on first run.
- **Defence in depth:** the React routes guard by role, but every request is
  re-checked server-side — the UI never trusts the client alone.

Configurable env vars: `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `ADMIN_NAME`,
`USERS_STORE_PATH`, `PBKDF2_ITERATIONS`, `JWT_SECRET`.

---

## Verification checklist

Backend (`cd backend`):

1. `pip install -r requirements.txt`
2. `pytest` — existing monitoring tests **and** `tests/test_admin.py` (RBAC + flows) pass.
3. `uvicorn app.main:app --reload` — on first run the log shows the seeded admin
   (and a warning if the default password was used).

Dashboard (`cd admin-dashboard`):

4. `npm install` then `npm run dev`; open <http://localhost:5173>.
5. Log in as admin → **Overview** shows counts and recent activity.
6. **Doctors** → create a doctor → copy the one-time password → log in as that doctor
   in a private window → they land on **مرضاي** with an empty list.
7. As the doctor, create a patient → it appears in their list (auto-assigned).
8. As admin, **Assignments** → assign that patient to a second doctor → it appears
   in the second doctor's list too.
9. **Audit** shows `login`, `create_doctor`, `create_patient`, `assign` entries.
10. RBAC spot-checks: a doctor cannot open `/doctors` (redirected); disabling an
    account blocks its login (403).
