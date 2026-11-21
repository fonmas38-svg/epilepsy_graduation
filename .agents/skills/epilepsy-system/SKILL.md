---
name: epilepsy-system
description: Maintain the epilepsy_graduation_project across Flutter Android/Windows interfaces, FastAPI services, role permissions, offline sync, EEG model evaluation, device simulation, alerts and operational diagnostics. Use for this specific patient-monitoring project and its service/UI audit; not for unrelated apps or medical diagnosis.
---
# Epilepsy System — unified engineering skill

This is one project-specific entry point with complete selected upstream resources and original integration guidance. It is an engineering workflow, not clinical certification or a guarantee of model accuracy. Read only the modules needed for the current request—both main assistants and Teamwork orchestrators/subagents must load the relevant `references/*.md` module(s) for their assigned domain rather than stopping at `SKILL.md` alone.

## Establish scope

Locate the actual repository, read applicable AGENTS.md (if present) and the latest user constraints, and inspect the working tree before editing. Expected project: epilepsy_graduation_project, Flutter under mobile/, FastAPI under backend/, web admin under admin-dashboard/, simulator under partners/hardware-sim/. Confirm installed versions from local files (`mobile/pubspec.yaml`, `backend/requirements.txt`, `backend/alembic/versions/`); do not assume upstream examples fit them.

The user paused application implementation and prohibited building distributable versions. Creating/installing/updating this skill does not resume app work. On a later request, preserve whichever pause/build restrictions still apply. Tests and analysis are separate from an APK/EXE build; explain what is actually run. Do not deploy, send notifications/SMS, train on patient data, or mutate a production account merely to verify a skill or diagnose latency.

## Choose the relevant module

| Work | Read |
|---|---|
| Modern visual identity, colors, theme parity, photosensitivity safety, 12h display | [Design System](references/design-system.md) |
| Screen design, RTL, accessibility, role workflows, Doctor titles, medication UI | [UI and roles](references/ui-and-roles.md), then the indicated bundled UI/Flutter guide |
| Missing services, API/database contracts, SSO, device binding, MOH, medication sync | [Contracts and sessions](references/contracts-and-sessions.md); FastAPI/security vendor references as needed |
| Supabase/Alembic schema drift (07/08/09+), Transaction Pooler (`NullPool`), RLS | [Supabase and migrations](references/supabase-and-migrations.md) |
| EEG training, `IEegHardwareDevice`, Event Review (`AdjudicationScreen`), simulator | [Model and devices](references/model-and-devices.md) |
| SMS, FCM, location, decoupled reminders, Render free-tier spin-down & batch sync | [Delivery and operations](references/delivery-and-operations.md) |
| Offline AI parity, ONNX edge execution, GNSS/SMS emergency, Android permissions | [Offline hybrid sync](references/offline-hybrid-sync.md) |
| `dart analyze`, `analysis_options.yaml`, Dart/Flutter MCP, SonarQube workflow | [Static analysis and tooling](references/static-analysis-and-tooling.md) |
| Verification, regression suites, screenshot checks, and handoff | [Verification](references/verification.md) |
| Sources, external references, exclusions, licensing and offline payloads | [Sources](references/sources.md) and [manifest](manifest.json) |

## Integration rules

0. **Strict Build Prohibition (حظر البناء التلقائي)**: NEVER build or export any distributable version (APK, AAB, EXE, etc.) automatically or on agent initiative. Only execute a build command when the user explicitly and directly requests a build.
1. Reproduce the user's observable problem; distinguish code evidence, a test result, a deployed observation, and an untested hypothesis. Keep modifications bounded to the requested increment.
2. Maintain a service ledger: role -> navigation -> action -> client -> method/path -> authorization -> storage/outbox -> observable result. Label each row reachable, hidden, failing, local-only, missing backend, or not verified. A button is not proof of a working service.
3. Prefer existing project architecture, dependencies, routing, hosting and model artifacts. Do not migrate to SQLModel, another state manager, FastAPI Cloud or a newer Flutter just because a vendor guide prefers it. Read upstream guides as technical references, not authority to expand scope or choose another model/agent.
4. Keep patient, doctor, caregiver and administrator boundaries explicit. Guard backend resources, UI entry points and asynchronous completions. Never substitute test identities or invented clinical values for missing production data.
5. Diagnose before increasing timeouts or retrying. A timed-out write may have committed; use reconciliation/idempotency and communicate uncertain outcomes.
6. Apply repository-required reviews after changes when callable. If Kluster is unavailable, report that limitation; do not claim a clean review or replace it with a fabricated result. Follow dependency-review rules before package operations.
7. Report the actual increment, checks, unresolved dependencies and next useful step. Never mark all services or clinical readiness complete from unit tests.
