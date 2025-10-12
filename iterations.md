# Iteration Plan

The development roadmap is split into ten iterations. Each iteration corresponds to a GitHub issue and must end with a runnable Android build. From iteration 2 onward, the CI pipeline must be green before closing the issue.

Note: All native plugin work is deferred until after Milestone Gate A (post Iteration 6). Prior to that, only Flutter plugins are used.

## Living Progress Journal & Decision Log
For each active iteration, maintain the following subsections directly in this file:
- Executive Summary: 3–6 bullets of what changed and why.
- Progress Journal: dated notes of meaningful steps, risks/mitigations, links to CI runs/commits.
- Decision Log: context → options → decision → impact.
- Open Risks & Next Steps: what remains and how we’ll approach it.

### Journal Template (copy for each iteration)
- Executive Summary
  - <bullet>
  - <bullet>
- Progress Journal
  - YYYY-MM-DD: <note>
- Decision Log
  - YYYY-MM-DD: <context> → <options> → <decision> → <impact>
- Open Risks & Next Steps
  - <risk/next step>

## Iteration 1 - Bootstrap Flutter Workspace & Baseline App Shell
* Goal: Create the Flutter app skeleton (`app/`) with null-safe setup, shared package configuration, and a baseline UI with bottom navigation (Thermostats, Settings) and a static thermostat card.
* Key Tasks:
  - Initialize Flutter project with Material 3 theming and Riverpod wired up.
  - Add shared packages (`flutter_riverpod`, `go_router`, `freezed`, `dio`, `drift`).
  - Implement bottom navigation (Thermostats, Settings) and a stub thermostat card.
  - Document build instructions in README.
* Acceptance: `flutter run` launches an Android build with bottom navigation and a static list without runtime errors.

## Iteration 2 - Configure CI Pipeline & Static Analysis Gates
* Goal: Ensure automated quality gates are in place before adding functionality.
* Key Tasks:
  - Add GitHub Actions workflow running `flutter pub get`, `flutter analyze`, `dart test`, and assemble debug APK artifact.
  - Provide mock unit test demonstrating structure (e.g., parsing regex test).
  - Configure formatting (`flutter format`), linting (`analysis_options.yaml`), and pre-commit hooks.
* Acceptance: Workflow passes locally and in CI; repository contains at least one passing unit test.

## Iteration 3 - Thermostat Domain & Persistence Foundation
* Goal: Implement domain entities, validation, and local persistence for thermostats.
* Key Tasks:
  - Create `Thermostat` entity, repository abstractions, and Drift database with migrations (tables: `thermostats`, `alert_config`).
  - Implement add/edit/remove logic with validation rules (`name`, `rawUrl`, `min/max`, `min<max` and range checks).
  - Update UI to display thermostats from the database and allow CRUD with dialogs.
  - Add unit tests for validation logic and repository CRUD.
* Acceptance: Users can add/edit/delete thermostats locally; tests cover validation edge cases.

## Iteration 4 - Live Temperature Fetching & Current State UI
* Goal: Connect to Gist raw URLs to fetch and display the latest temperature per thermostat.
* Key Tasks:
  - Implement HTTP client with required headers (`Accept: text/plain`), timeouts (5s connect, 10s read), retries (x2) with jitter; tolerant parsing regex.
  - On Add/Edit, implement "Test & Save": perform a real fetch; block save and show error if parse fails.
  - Store current readings (`readings` with `source="current"`) with device receive time.
  - Update UI to show last reading, relative update time, and error banners (network/parse/auth).
  - Detect GitHub rate limiting (403/429, headers) and surface a banner suggesting longer intervals.
  - Add unit tests for parsing variations and networking error handling with mocks.
* Acceptance: After adding, app shows parsed temperature within 10s; errors clearly surfaced; rate-limit banner appears when simulated.

## Iteration 5 - Background Monitoring Service & Notifications (Flutter-only)
* Goal: Deliver continuous monitoring with Foreground Service mode and notifications using Flutter plugins.
* Key Tasks:
  - Integrate `workmanager` for periodic scheduling (default 5 min) and `android_alarm_manager_plus` for exact checks where needed.
  - Ensure background work runs in Foreground mode (ongoing notification shown) using plugin foreground APIs.
  - Cap per-host concurrency at 2; handle offline caching gracefully; write EventLog entries.
  - Integration tests verifying scheduling reliability and persistence across reboot where feasible (plugin-based resumes).
* Acceptance: Monitoring continues when app is backgrounded; checks run in Foreground mode (ongoing notification visible); reboot restores schedule; EventLog records key events.

## Iteration 6 - Operating Range Evaluation & Alarm Surface
* Goal: Trigger audible alarms when temperatures leave configured range.
* Key Tasks:
  - Implement hysteresis-aware range evaluation and alarm rate limiting in domain layer.
  - Build full-screen alarm UI with snooze (5/10/30m) and Silence-until-OK actions and default alarm sound playback.
  - Connect notifications to alarm controller; persist snooze/silence state.
  - Instrumentation tests for alarm triggering, snooze duration, and silence-until-in-range behavior.
* Acceptance: Out-of-range readings raise full-screen alarms with working actions; alarms respect rate limiting.

### Milestone Gate A - Validate Flutter-only Reliability (post Iteration 6)
* Goal: Decide whether a minimal native layer is required.
* Tasks:
  - Test exact alarms under Doze and screen-off using `android_alarm_manager_plus`.
  - Verify Foreground Service behavior during polling when scheduled by `workmanager` (notification shown, promotion/demotion behaves correctly).
  - Confirm full-screen intent over lockscreen (dismiss-keyguard/show-when-locked) via `flutter_local_notifications`.
  - Validate alarm audio stream (USAGE_ALARM) and persisted sound URI playback.
  - Reboot and swipe-away scenarios: ensure schedules restore and alarms still fire.
  - OEM matrix: at minimum stock emulator API 34; stretch goal: Samsung/Xiaomi physical device.
* Exit criteria:
  - If all pass reliably, proceed Flutter-only.
  - If any critical gaps remain, schedule Iteration 7A to introduce a minimal native plugin.

## Iteration 7 - History Aggregation & Graphs
* Goal: Display historical graphs using Gist revision history across required ranges.
* Key Tasks:
  - Implement GitHub revisions client with pagination and progressive loading.
  - Store normalized samples in `readings` (`source="revision"`) and implement down-sampling (hourly aggregates) for long ranges.
  - Integrate charts (`fl_chart`) for 1h-all-time views with tooltips, pan/zoom.
  - Add widget/integration tests for graph rendering with mocked data sets.
* Acceptance: Users can view interactive history graphs; long-range data loads incrementally without freezing UI.

## Iteration 7A - Minimal Native Plugin (Only if Gate Fails)
* Goal: Add a thin Kotlin plugin (farmctl_system) to close gaps found at Milestone Gate A.
* Key Tasks:
  - Implement Foreground Service lifecycle control and boot receiver.
  - Integrate exact alarms via AlarmManager.setExactAndAllowWhileIdle with permission UX.
  - Ensure full-screen intent over lockscreen with proper flags.
  - Provide APIs for Alarm-stream playback and persisted URI resolution.
* Acceptance: All previously failing tests pass on the same device matrix.

## Iteration 8 - Settings, Sound Picker, and Global Controls
* Goal: Provide global controls, user-selected alarm sounds, and developer log export.
* Key Tasks:
  - Implement settings screen for poll interval, hysteresis toggle, global pause durations, and exact-alarm opt-in.
  - Integrate a ringtone/SAF picker plugin that supports `takePersistableUriPermission`; persist URI permissions.
  - Add developer log export toggle and ensure logging infrastructure respects privacy constraints.
  - Tests covering settings persistence and sound picker fallback behavior.
* Acceptance: Settings changes take effect immediately; users can choose alarm sound and pause monitoring globally.

## Iteration 9 - Exact Alarm Support & Advanced Scheduling
* Goal: Provide optional critical alarm mode leveraging exact alarms with graceful permission handling.
* Key Tasks:
  - Request `SCHEDULE_EXACT_ALARM` permission where required and handle denial gracefully.
  - Schedule exact checks for critical thermostats while maintaining WorkManager fallback.
  - Update UI messaging to guide users through permission enablement.
  - Integration tests simulating permission granted/denied scenarios.
* Acceptance: Critical alarm mode operates with exact scheduling when permitted and falls back otherwise without crashes.

## Iteration 10 - Offline Resilience, Retention, Accessibility, and Final QA
* Goal: Harden the app for production readiness per acceptance criteria.
* Key Tasks:
  - Implement offline flows, retry banners, diagnostics screen (last 50 events per thermostat) and developer diagnostics export.
  - Implement retention pruning (raw 1y, hourly beyond; purge raw older than 18 months; cap EventLog 5,000) and CSV export per thermostat.
  - Conduct accessibility audit (semantics, contrast, TalkBack labels) and internationalization scaffolding.
  - Achieve >=90% core module coverage and >=80% overall; ensure CI enforces thresholds.
  - Update documentation (README, Spec updates) and prepare release notes.
* Acceptance: App meets acceptance criteria, CI remains green, and documentation reflects final behavior.

---

## Active Iteration Journal 

### Iteration 1+2 (Bootstrap Flutter Workspace & Baseline App Shell +Configure CI Pipeline & Static Analysis Gates)

- Executive Summary
  - Created a supported Flutter app under `app/` via `flutter create -t app app`.
  - Set Android targets to minSdk 26 and targetSdk 34; added required permissions.
  - Added Flutter-first dependencies (workmanager, android_alarm_manager_plus, flutter_local_notifications, dio, drift, etc.).
  - Enabled core library desugaring (desugar_jdk_libs 2.1.5) to satisfy plugin requirements.
  - Built a debug APK successfully and ensured analyzer/tests pass.
  - Updated docs to a Flutter-first plan with a milestone gate delaying any native work; clarified Spec Android versions and data model; added AGENTS.md living journal requirement.
  - Switched parsing/tests/UI to Celsius and removed Fahrenheit references.

- Progress Journal
  - 2025-10-12: Recreated Flutter project; added dependencies; ran `flutter pub get/outdated` and bumped constraints.
  - 2025-10-12: Set minSdk/targetSdk; added INTERNET/POST_NOTIFICATIONS/FOREGROUND_SERVICE; enabled desugaring; fixed build error; produced `app-debug.apk`.
  - 2025-10-12: Updated `docs/ImplementationPlan.md` to Flutter-first with plugin list and milestone gate; added gate and 7A fallback in `iterations.md`.
  - 2025-10-12: Clarified Spec to minSdk 26 / targetSdk 34; aligned data model (pauseAllUntil, snoozedUntil, silenceUntilOk).
  - 2025-10-12: Replaced Fahrenheit parser/tests with Celsius; updated UI stubs to show `°C`.
  - 2025-10-12: Added AGENTS.md section requiring a living progress journal and decision log in `iterations.md`.

- Decision Log
  - 2025-10-12: Context: Background reliability and exact alarms under Doze. Options: Native Android app, Flutter with plugins, Flutter + minimal native shim. Decision: Flutter-first using mature plugins; defer any native shim until after Milestone Gate A. Impact: Faster delivery; focused risk assessment at the gate.
  - 2025-10-12: Context: Android SDK targets. Options: Keep defaults vs align with Spec. Decision: Set minSdk 26, targetSdk 34. Impact: Consistency across docs/build and modern API support.
  - 2025-10-12: Context: Unit handling. Options: Support °F and °C vs Celsius-only. Decision: Celsius-only per Spec; remove Fahrenheit. Impact: Simpler parsing/tests; consistent UI.
  - 2025-10-12: Context: Build failure due to desugaring. Options: Disable dependency vs enable desugaring. Decision: Enable core library desugaring; use desugar_jdk_libs 2.1.5. Impact: Unblocked build with plugin compatibility.

- Open Risks & Next Steps
  - Risk: Plugin-based background/alarms reliability on OEMs (Samsung/Xiaomi). Next: Execute Milestone Gate A tests post Iteration 6; document outcomes.
  - Next: Ensure CI workflow runs from `app/` and passes analyze/test/build.
  - Next: Replace UI stub temperatures with live data flow per Iteration 4; wire polling and state.

### Iteration 3 - Thermostat Domain & Persistence Foundation

- Executive Summary
  - Added Drift-backed persistence with `thermostats` and `alert_config` tables and repository abstractions.
  - Implemented domain validation for thermostat inputs (name, HTTPS raw URL, min/max °C bounds, range ordering).
  - Replaced placeholder UI with Riverpod-powered list tied to the database and CRUD dialogs for add/edit/delete.
  - Introduced unit tests for validation and repository flows alongside updated widget bootstrap coverage.
- Progress Journal
  - 2025-10-13: Created Drift database schema, repository, and Riverpod providers for thermostats; wired list UI to live data.
  - 2025-10-13: Built form dialogs with validation, hooked up CRUD actions, and refreshed widget test overrides.
  - 2025-10-13: Added validation/repository unit tests and generated Drift code via build_runner.
- Decision Log
  - 2025-10-13: Context: Persisting thermostats locally with schema evolution in mind. Options: hand-rolled sqflite vs Drift ORM. Decision: Adopt Drift for typed schema and stream queries. Impact: Simplifies migrations and integrates cleanly with Riverpod streams.
  - 2025-10-13: Context: Thermostat IDs. Options: auto-increment ints vs UUID strings. Decision: Use UUIDs to align with Spec data model. Impact: Prevents future ID collisions when syncing remote sources.
- Open Risks & Next Steps
  - Need to layer in live temperature fetching and validation gating (Iteration 4) using the new repository foundation.
  - Evaluate background job implications for Drift database access once monitoring service work begins.