---
name: epilepsy-quality-gate
description: Run and audit static analysis (flutter/dart analyze, strict analysis_options.yaml, flutter_dart-mcp-server, SonarQube), Supabase/Alembic schema drift, RLS policies, and test baselines for epilepsy_graduation_project without triggering forbidden APK/EXE builds. Use for quality audits, pre-merge checks, and static analysis of this repository.
---
# Epilepsy Quality Gate

Focused static analysis, database integrity, and regression verification skill for `epilepsy_graduation_project`. Complements the unified [Epilepsy System](../epilepsy-system/SKILL.md) skill; never builds or exports distributable binaries (APK, AAB, EXE).

## 1. Pre-Flight Environment Check

Before claiming any tool result, verify what is actually installed and configured:
1. Check `mobile/analysis_options.yaml` (currently only `package:flutter_lints/flutter.yaml` is enabled).
2. Check whether `sonar` CLI (`where.exe sonar`) and a SonarQube MCP server (`~/.gemini/config/mcp_config.json`) are available, and whether `sonar-project.properties` exists at repository root.
3. Check whether `flutter_dart-mcp-server` is available for `analyze_files`, `run_tests`, `dart_fix`, and `dart_format`.
4. If SonarQube CLI/MCP is absent, report the tool gap explicitly and perform manual static/security checks instead of fabricating a Quality Gate pass.

## 2. Flutter / Dart Static Analysis & Theme/Safety Audit

- Run `flutter analyze --no-pub` (in `mobile/`) or `dart analyze --fatal-infos mobile/lib/` (when `--fatal-infos` gate is targeted).
- Audit for high-impact defects documented in the Master Implementation Plan & latest user UX mandates:
  - **Pointer identity session checks**: Flag `identical(..., ...)` comparisons on `AppUser` (`main.dart`, `app_router.dart`, screens).
  - **Auth/route transition races**: Flag any redirect or router evaluation that flashes Account Settings or a stale route during pending login.
  - **Hardcoded screen colors**: Flag `Colors.white`, `Colors.black`, `Color(0x...)` inside `mobile/lib/features/**` that break Light/Dark mode parity or risk WCAG 2.2 SC 2.3.1 (>3 flashes/sec / FOUC) photosensitivity hazards.
  - **24-hour clock literals**: Flag hardcoded `HH:mm` formatting instead of localized 12-hour `DateFormat.jm` (`ص`/`م`).
  - **Exposed internal/technical UI copy**: Flag end-user banners exposing server wake-up jargon (e.g., `"جاري إيقاظ الخادم السحابي"`), server URLs, or raw chat status prose (`"قبل الخادم الرسالة"` instead of WhatsApp-style checkmarks).
  - **Simulator / Virtual-Hardware continuity**: Flag patient monitoring paths that stall on `"لا توجد بيانات كافية"` when virtual hardware simulation is active, or fail to execute full severity-driven seizure escalation and local offline prediction parity.
  - **Unguarded secondary fetches**: Flag unguarded `await api.getList(...)` calls (e.g., `clinicalNotesFor`) or self-revocation `_load()` calls that crash screens on 404/401.

## 3. Backend, Supabase & Alembic Integrity Audit

- Compare `backend/alembic/versions/` against `backend/deploy/supabase_complete_production_schema.sql`: confirm revisions `20261028_07`, `20261113_08`, and `20261114_09` (plus planned `users.email`, `doctor_profiles`, `moh_registry`, `account_sessions.device_id`, `messages.channel_type`, `outcomes.version`) are aligned.
- Verify Supabase connection settings: Transaction Pooler (port `6543`) requires SQLAlchemy `NullPool` (and `statement_cache_size=0` for `asyncpg`); Alembic DDL migrations should use Direct port `5432` (or `NullPool`).
- Verify `ENABLE ROW LEVEL SECURITY` / `CREATE POLICY` coverage in Supabase SQL and absence of hardcoded default password hashes or `APP_ENV=production` SQLite fallbacks.
- Verify `backend/app/routers/device.py` has no duplicate route registrations (e.g. duplicate `@router.get('/contract')`).

## 4. Test Baselines (No Builds)

- Flutter baseline: `flutter test` in `mobile/` (181 baseline tests + targeted regression suites).
- Backend baseline: `python -m pytest` in `backend/tests/` (223 baseline tests + isolated test DB).
- Never run `flutter build apk`, `flutter build appbundle`, or `flutter build windows` unless explicitly requested by the user.
