## Unreleased

- ESP32-C6 flasher stub (esp-flasher-stub v0.7.0, MIT OR Apache-2.0), so
  a C6 gets the stub chip erase (0xD0) instead of the slow ROM fallback.
  Before the upload the C6's USB-Serial/JTAG watchdogs are disabled with its
  own LP_WDT registers (the S3's RTC_CNTL addresses do not exist on a C6).
- **Licensing fix:** the embedded ESP32-S3 flasher stub was esptool's legacy
  stub (GPL-2.0-or-later, from esptool 4.8.1 `stub_flasher/1/`) but was
  labelled MIT. It is replaced by Espressif's esp-flasher-stub v0.7.0
  (MIT OR Apache-2.0), the same project as the new ESP32-S2 stub. License
  texts and binary hashes: `third_party/esp-flasher-stub/`; the MIT notice
  is appended to `LICENSE` so it reaches apps' `NOTICES`.
- ESP32-S2 flasher stub; `eraseRegionRom` attaches SPI once, sends no
  FLASH_END and reports progress; `DirectSerialPort` resumes a timed-out
  read instead of racing it.

## 0.1.5

- Fixed blocking FFI serial reads: moved CPU-bound serial I/O off the UI
  isolate to prevent frame drops on Windows and macOS.
- Removed debug-only file logging (`/tmp/esp_debug.log`) from
  `EspTransport` that caused `PathNotFoundException` on Windows and
  `StreamSink` state errors in multi-test suites.
- Configured GitVersion (`GitVersion.yml`) for automatic semantic
  versioning with conventional-commit bump rules across the full
  gitflow pipeline (feat/fix/hotfix → dev → test → stable → main).
- Rewrote release workflow with GitVersion integration: version is now
  computed automatically from git history on every merge to `main`,
  `pubspec.yaml` is patched in CI, and a version-bump PR is opened
  automatically to keep the repository in sync.
- Extended auto-approve/merge workflow to handle bot-opened
  version-bump PRs (`chore/release-*`) without manual intervention.

## 0.1.4

- Added `topics` to `pubspec.yaml` for pub.dev discoverability
  (esp32, esp8266, serial, iot, embedded).
- Rewrote `README.md` with badges, platform support table,
  quick-start example, and API reference links.
- Completed dartdoc coverage on all public library symbols
  (models, transport, resilience, infrastructure layers).
- Added `CONTRIBUTING.md` and `SECURITY.md`.
- New CI jobs: coverage report (lcov, ≥70% threshold),
  PR auto-labeler, PR notification with checklist.
- Added Dependabot for weekly pub and GitHub Actions updates.
- Added GitHub Copilot review instructions and
  professional 7-section PR template.
- Added cross-platform git hooks
  (pre-commit, commit-msg, pre-push, post-merge)
  with sh and PowerShell installers.
- Added Docker analysis container with pana, semgrep, lcov,
  and a full-analysis orchestration script.
- Added GitHub label bootstrap one-shot workflow.
- Changed repository default branch to `main`;
  added maintainer bypass actor to all branch rulesets.

- Updated `platform_serial` dependency to `^0.1.2` (latest published version).
- Hardened package metadata for pub.dev (`description`, `homepage`, `repository`, `issue_tracker`).
- Strengthened PR quality gates with scoped unit/integration/e2e jobs and owner-only auto-approve/merge on green.
- Updated release workflow for trusted publishing with OIDC and no long-lived pub.dev token secret.
- Expanded project guidance assets (instructions, skills, agents, and MCP configuration) for testing, vulnerability triage, and security workflows.
- Added metadata tests to enforce pubspec dependency and URL consistency.

## 0.1.2

- Renamed the demo app to `esptool_ui`.
- Switched the demo to use `platform_serial` for real serial port access.
- Added flags in the language selector.
- Fixed padding for the last flash block during writes.

## 0.1.1

- Prepared package for pub.dev publishing metadata and MIT licensing.
- Added professional GitHub project automation (CI, release, and publish workflows).
- Added Copilot project assets (instructions, skills, agents, and MCP server configuration).
- Added professional multilingual demo app under `example/esptool_ui`.
- Added editor and repository standards files (`.editorconfig`, `.gitattributes`, `.gitignore`, `GitVersion.yml`).

## 0.1.0

- Initial workspace package with ESP protocol models, services, transport, parsers, and tests.
