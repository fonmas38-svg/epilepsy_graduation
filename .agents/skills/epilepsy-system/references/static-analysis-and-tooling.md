# Static Analysis, MCP & Quality Tooling Workflow

This module defines the project's static analysis, Dart/Flutter MCP, and SonarQube verification workflows grounded in the actual workspace configuration (`mobile/analysis_options.yaml`, `.gemini/config/mcp_config.json`, installed plugins) and official Dart/Flutter and SonarSource documentation.

---

## 1. Dart & Flutter Static Analysis (`dart analyze` / `flutter analyze`)

### Current Workspace State
- `mobile/analysis_options.yaml` currently includes only `package:flutter_lints/flutter.yaml` (no strict `analyzer.language` flags or extra clinical safety lints enabled).
- Baseline command (`flutter analyze --no-pub` or `dart analyze` inside `mobile/`) must stay clean.

### Target Quality Gate Standard
- Run `dart analyze --fatal-infos mobile/lib/` (or `flutter analyze --no-pub` in `mobile/`).
- When tightening `mobile/analysis_options.yaml` during planned quality phases, enforce:
  - `analyzer.language`: `strict-casts: true`, `strict-inference: true`, `strict-raw-types: true` (verify incremental impact before enabling globally).
  - `linter.rules`: `use_build_context_synchronously`, `unawaited_futures`, `discarded_futures`, `avoid_print`, `avoid_redundant_argument_values`.
- Always check `mobile/pubspec.yaml` and installed Dart/Flutter SDK versions (`sdk: ^3.10.4`) before applying `dart fix --apply`.

---

## 2. Dart & Flutter MCP Server Workflow (`flutter_dart-mcp-server`)

When the `flutter_dart-mcp-server` MCP server is available in the session:
- **Static checks**: Use `analyze_files` and `run_tests` (honoring the project's strict build prohibition—never trigger APK/EXE builds).
- **Automated mechanical fixes**: Use `dart_fix` and `dart_format` only on explicitly modified Dart files, never across untouched code during read-only audits.
- **Runtime / UI inspection** (only when user authorizes launching a debug session): Use `list_devices`, `get_runtime_errors`, `get_widget_tree`, `get_selected_widget`.
- Remember: Read the MCP tool schema file under `<appDataDir>\mcp\flutter_dart-mcp-server\` before calling lazy MCP tools via `call_mcp_tool`.

---

## 3. SonarQube Analysis & Configuration

### Actual Environment Reality Check
- `sonar-project.properties` does not yet exist at the repository root.
- Verify whether `sonar` CLI (`where.exe sonar`) and a SonarQube MCP server (`.gemini/config/mcp_config.json`) are actually configured in the current environment before claiming a Sonar scan passed.
- If `sonar` CLI / SonarQube MCP is unavailable (as verified during the 2026-11-20 audit where `mcp_config.json` was empty and `sonar` was absent), **explicitly report that gap** and perform targeted manual static/security inspection instead of fabricating a Quality Gate pass.

### Official `sonar-project.properties` Parameters (Polyglot Flutter + FastAPI Repo)
When configuring SonarQube per official SonarSource docs:
```properties
sonar.projectKey=epilepsy_graduation_project
sonar.sources=mobile/lib,backend/app,admin-dashboard/src
sonar.tests=mobile/test,backend/tests
sonar.sourceEncoding=UTF-8
sonar.exclusions=**/build/**,**/.dart_tool/**,**/node_modules/**,**/__pycache__/**,**/data/**

# Dart / Flutter coverage (from: flutter test --coverage)
sonar.dart.lcov.reportPaths=mobile/coverage/lcov.info

# Python / FastAPI version & coverage (from: pytest --cov=app --cov-report=xml)
sonar.python.version=3.11,3.12,3.13
sonar.python.coverage.reportPaths=backend/coverage.xml
```
- When SonarQube skills (`sonar-analyze`, `sonar-quality-gate`, `sonar-list-issues`, `sonar-coverage`) are callable and authenticated, target Quality Gate **Rating A** on Reliability and Security, zero Critical/Blocker issues, and zero hardcoded secrets/hashes.
