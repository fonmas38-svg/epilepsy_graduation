# Sources and integration scope

Research date: 2026-11-13 (audited and updated 2026-11-20 against Master Implementation Plan and authoritative external references). Complete selected upstream skill directories are bundled under vendor/, with only their root SKILL.md renamed GUIDE.md to expose one unified entry point. Original licenses/notices accompany the bundle. No upstream scripts are executed automatically. Read the relevant guide and inspect scripts before use. Helpers may still depend on separately available tools; bundling does not install runtimes, grant credentials or provide MCP servers.

The custom entrypoint and references adapt these resources to the existing project. They do not claim endorsement from Flutter, FastAPI, OpenAI or UI UX Pro Max. Upstream recommendations are conditional on installed versions and current user authorization. Preserve copied resources; updates need review and a new manifest.

Included sources:
- ui-ux-pro-max: https://github.com/nextlevelbuilder/ui-ux-pro-max-skill
- flutter: https://github.com/flutter/agent-plugins
- fastapi: https://github.com/fastapi/fastapi/tree/master/fastapi/.agents/skills/fastapi
- security-best-practices: https://github.com/openai/skills/tree/main/skills/.curated/security-best-practices
- security-threat-model: https://github.com/openai/skills/tree/main/skills/.curated/security-threat-model
- playwright: https://github.com/openai/skills/tree/main/skills/.curated/playwright
- render-deploy: https://github.com/openai/skills/tree/main/skills/.curated/render-deploy

Considered but not adopted as EEG validation: https://github.com/huggingface/skills — general Hub/LLM/vision workflows do not establish seizure-level prediction accuracy for the current model. Figma workflows were not bundled because the user has screenshot references, not a Figma source. Other apps, payments and unrelated cloud migrations are outside this skill.

Custom modules fill project-specific engineering gaps: clinical evidence boundaries, hardware simulation (`IEegHardwareDevice`), offline ownership, multi-device recovery, SMS/GNSS capability, alert delivery semantics, Supabase/Alembic schema alignment (`supabase-and-migrations.md`), and static analysis/MCP/SonarQube tooling (`static-analysis-and-tooling.md`). These remain procedures to implement and verify, not claims that the system already meets them.

## External Authoritative References (2026-11-20 Audit)
- Supabase PostgreSQL Connection Pooling & SQLAlchemy/Alembic (`NullPool` on port 6543, Direct port 5432 for DDL): https://supabase.com/docs/guides/database/connecting-to-postgres
- Render Free Web Services (15-min idle spin-down, ephemeral filesystem, persistent disk tier limits): https://render.com/docs/free
- W3C WCAG 2.2 Success Criterion 2.3.1 (Three Flashes or Below Threshold — photosensitive epilepsy safety): https://www.w3.org/WAI/WCAG22/Understanding/three-flashes-or-below-threshold.html
- Dart Static Analysis (`dart analyze`, `analysis_options.yaml`) & Flutter Lints: https://dart.dev/tools/dart-analyze and https://docs.flutter.dev/tools/lints
- Dart & Flutter MCP Server (`flutter_dart-mcp-server`): https://docs.flutter.dev/ai/mcp-server
- SonarQube Analysis Parameters (Dart/Flutter LCOV & Python/pytest): https://docs.sonarsource.com/sonarqube-server/latest/analyzing-source-code/analysis-parameters/
- SQLAlchemy Connection Pooling (`NullPool`, `QueuePool`, `pool_pre_ping`, `pool_recycle`): https://docs.sqlalchemy.org/en/20/core/pooling.html
- Flutter `device_info_plus` (`androidId` removal since 4.0.0) & `flutter_local_notifications` (Android exact alarm permissions & Windows support): https://pub.dev/packages/device_info_plus and https://pub.dev/packages/flutter_local_notifications
- Flutter `intl` (`DateFormat.jm` localized 12-hour formatting) & `AnimatedTheme`: https://api.flutter.dev/flutter/material/AnimatedTheme-class.html
