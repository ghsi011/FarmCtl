# Iteration Plan

The development roadmap is split into ten iterations. Each iteration corresponds to a GitHub issue and must end with a runnable Android build. From iteration 2 onward, the CI pipeline must be green before closing the issue.

## Iteration 1 — Bootstrap Flutter Workspace & Baseline App Shell
* **Goal**: Create the Flutter application skeleton (`app/`) with null-safe setup, shared package configuration, and placeholder UI showing a static thermostat list.
* **Key Tasks**:
  * Initialise Flutter project with Material 3 theming and Riverpod wired up.
  * Add shared packages (`flutter_riverpod`, `go_router`, `freezed`, `dio`, `drift`).
  * Implement placeholder home screen with navigation drawer and stub thermostat card.
  * Document build instructions in README.
* **Acceptance**: `flutter run` launches a placeholder app on Android without runtime errors.

## Iteration 2 — Configure CI Pipeline & Static Analysis Gates
* **Goal**: Ensure automated quality gates are in place before adding functionality.
* **Key Tasks**:
  * Add GitHub Actions workflow running `flutter pub get`, `flutter analyze`, `dart test`, and assemble debug APK artifact.
  * Provide mock unit test demonstrating structure (e.g., parsing regex test).
  * Configure formatting (`flutter format`), linting (`analysis_options.yaml`), and pre-commit hooks.
* **Acceptance**: Workflow passes locally and in CI; repository contains at least one passing unit test.

## Iteration 3 — Thermostat Domain & Persistence Foundation
* **Goal**: Implement domain entities, validation, and local persistence for thermostats.
* **Key Tasks**:
  * Create `Thermostat` entity, repository abstractions, and Drift database with migrations.
  * Implement add/edit/remove logic with validation rules (`name`, `rawUrl`, `min/max`).
  * Update UI to display thermostats from the database and allow CRUD with dialogs.
  * Add unit tests for validation logic and repository CRUD.
* **Acceptance**: Users can add/edit/delete thermostats locally; tests cover validation edge cases.

## Iteration 4 — Live Temperature Fetching & Current State UI
* **Goal**: Connect to Gist raw URLs to fetch and display the latest temperature per thermostat.
* **Key Tasks**:
  * Implement HTTP client with timeout, jitter scheduling, and tolerant parsing regex.
  * Store current readings in the database with timestamps.
  * Update UI to show last reading, relative update time, and error banners when fetch fails.
  * Add unit tests for parsing variations and networking error handling with mocks.
* **Acceptance**: App polls configured thermostats on demand and after adding; UI reflects success/error states.

## Iteration 5 — Background Monitoring Service & Notifications
* **Goal**: Deliver continuous monitoring with Android-compliant foreground service and notifications.
* **Key Tasks**:
  * Create Kotlin plugin (`farmctl_system`) exposing foreground service, WorkManager integration, and boot receiver.
  * Implement background polling schedule (default 5 min) calling domain use-case to fetch readings.
  * Display ongoing monitoring notification; handle offline caching gracefully.
  * Integration tests verifying service scheduling and persistence across reboot (where feasible).
* **Acceptance**: Monitoring continues when app is backgrounded; reboot restores schedule.

## Iteration 6 — Operating Range Evaluation & Alarm Surface
* **Goal**: Trigger audible alarms when temperatures leave configured range.
* **Key Tasks**:
  * Implement hysteresis-aware range evaluation and alarm rate limiting in domain layer.
  * Build full-screen alarm UI with snooze/silence actions and default alarm sound playback.
  * Connect notifications to alarm controller; persist snooze/silence state.
  * Instrumentation tests for alarm triggering, snooze duration, and silence-until-in-range behavior.
* **Acceptance**: Out-of-range readings raise full-screen alarms with working actions; alarms respect rate limiting.

## Iteration 7 — History Aggregation & Graphs
* **Goal**: Display historical graphs using Gist revision history across required ranges.
* **Key Tasks**:
  * Implement GitHub revisions client with pagination and progressive loading.
  * Store normalized samples and implement down-sampling for long ranges.
  * Integrate charts (e.g., `syncfusion_flutter_charts`) for 1h–all-time views with tooltips.
  * Add widget/integration tests for graph rendering with mocked data sets.
* **Acceptance**: Users can view interactive history graphs; long-range data loads incrementally without freezing UI.

## Iteration 8 — Settings, Sound Picker, and Global Controls
* **Goal**: Provide global controls, user-selected alarm sounds, and developer log export.
* **Key Tasks**:
  * Implement settings screen for poll interval, hysteresis toggle, global pause durations, and exact-alarm opt-in.
  * Integrate Android sound picker via platform channel; persist URI permissions.
  * Add developer log export toggle and ensure logging infrastructure respects privacy constraints.
  * Tests covering settings persistence and sound picker fallback behavior.
* **Acceptance**: Settings changes take effect immediately; users can choose alarm sound and pause monitoring globally.

## Iteration 9 — Exact Alarm Support & Advanced Scheduling
* **Goal**: Provide optional critical alarm mode leveraging exact alarms with graceful permission handling.
* **Key Tasks**:
  * Request `SCHEDULE_EXACT_ALARM` permission where required and handle denial gracefully.
  * Schedule exact checks for critical thermostats while maintaining WorkManager fallback.
  * Update UI messaging to guide users through permission enablement.
  * Integration tests simulating permission granted/denied scenarios.
* **Acceptance**: Critical alarm mode operates with exact scheduling when permitted and falls back otherwise without crashes.

## Iteration 10 — Offline Resilience, Accessibility, and Final QA
* **Goal**: Harden the app for production readiness per acceptance criteria.
* **Key Tasks**:
  * Implement offline caching flows, retry banners, and developer diagnostics export.
  * Conduct accessibility audit (semantics, contrast, TalkBack labels) and internationalisation scaffolding.
  * Achieve ≥90% core module coverage and ≥80% overall coverage; ensure CI enforces thresholds.
  * Update documentation (README, Spec updates) and prepare release notes.
* **Acceptance**: App meets acceptance criteria, CI remains green, and documentation reflects final behavior.

