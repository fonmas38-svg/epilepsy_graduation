# Verification and honest delivery

Choose checks for the changed behavior: pure model/serialization tests, Flutter widget interactions, backend RBAC/transaction tests, race/failure tests and device-level scenarios where needed. Do not add tests that only mirror implementation wording. Use cached dependencies when possible and respect no-build instructions. Never launch a forbidden build under the name of verification.

For static analysis, Dart/Flutter MCP (`flutter_dart-mcp-server`), and SonarQube workflows, read [Static analysis and tooling](static-analysis-and-tooling.md). For database migration and RLS checks, read [Supabase and migrations](supabase-and-migrations.md).

For Flutter use ../vendor/flutter-add-widget-test/GUIDE.md. Exercise narrow/short/wide sizes, Arabic/English, RTL, large text, keyboard and light/dark where the change warrants it. Verify actual rendered content and button results; screenshots alone do not prove services work.

For web admin only, ../vendor/playwright/GUIDE.md provides browser interaction workflow. Its browser tooling cannot validate native Windows/Android background/SMS/EEG behavior. When unavailable, state the limit instead of installing browser dependencies or substituting unrelated app tests without authorization.

For API changes test valid/invalid/unauthorized/forbidden, status codes, rollback, duplicate submission, lost responses, account switch and stale completions. Test credentials must be isolated. Apply current repository review rules; unavailable tools remain an explicit gap. Do not report a running check as passed or count mocked send results as provider delivery.

### Master Plan Baseline & Target Regression Checklist
- **Baseline preservation**: Preserve passing `flutter test` (181 baseline tests) and `pytest backend/tests/` (223 baseline tests) plus `dart analyze --fatal-infos mobile/lib/`.
- **Targeted regression suites** (per Master Implementation Plan §5.2):
  1. Offline login credential fallback & online re-sync
  2. Single-active-device binding (`patient` / `caregiver`)
  3. Doctor patient-creation route stack preservation (no black screen)
  4. Patient file clinical-notes 404 graceful fallback
  5. Medication role segregation (doctor prescribe vs patient log intake)
  6. Simulated MOH verification & admin override flow
  7. Atomic outbox batch sync (`POST /cloud/sync-batch`; Master Plan writes `/api/v1/cloud/sync-batch`)
- **Screenshot regression flows**: (1) Doctor adds patient -> returns to Doctor Home without black screen; (2) Patient profile with missing/404 notes -> renders gracefully without "العنصر المطلوب غير موجود"; (3) Doctor account/biometric screen -> displays formatted `د.` title; (4) Login Sessions & Devices -> loads without 500 error, revoking other session updates list, revoking current session clears tokens and routes cleanly to `LoginScreen`.

Delivery: summarize changed behavior, reproducible evidence, unverified runtime/deployment/device/clinical aspects, and remaining service-ledger rows. Preserve existing modifications and do not push/deploy merely because tests pass. A skill package validation checks its structure; it does not certify the application or clinical model.
