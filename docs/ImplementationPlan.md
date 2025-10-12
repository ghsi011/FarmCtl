# Smart Thermostat Management App - Implementation Plan

This plan translates the executable specification into a concrete Flutter application architecture. It prioritizes early delivery of a running Android build, core telemetry flows, and a reliable background watchdog while keeping the project testable from the outset.

## 1. Architectural Overview

1. Presentation (Flutter UI + state)
   - Riverpod for dependency injection and state. Material 3 for accessibility and theming.
   - View models/providers expose immutable state and async controllers for CRUD, polling, and alarm state.
2. Domain
   - Entities (Thermostat, Reading, AlertConfig, ThermostatState) and use-cases (AddThermostat, EditThermostat, RemoveThermostat, FetchCurrent, BuildHistory, EvaluateRange, ScheduleNext, RaiseAlarm, AcknowledgeAlarm).
   - Validation rules, hysteresis logic, rate limiting, and scheduler math. Depends only on abstractions: Clock, Net, Audio, Scheduler, Store.
3. Data
   - Repositories and data sources:
     - dio HTTP client with retries/backoff/jitter and ETag handling.
     - GitHub Gist API wrapper for revisions/history. Central parser using the spec regex.
     - drift (SQLite) for persistence with indexes and migrations.
   - DTOs/mappers to domain entities; ETag cache per thermostat.
4. System Integration (Flutter-first)
   - Prefer a Flutter-only approach using mature plugins for background work, exact alarms, notifications, audio, and sound picking. Background checks must run in Foreground mode (visible ongoing notification) via plugin support:
     - Scheduling/Background: WorkManager via `workmanager` and exact alarms via `android_alarm_manager_plus`.
     - Notifications/alerts: `flutter_local_notifications` with full-screen intent support.
     - Audio: `audio_session` + `just_audio` configured for Android Alarm usage.
     - Sound picker: a ringtone/SAF picker plugin supporting `takePersistableUriPermission`.
   - A minimal native plugin ("farmctl_system") will be introduced only if the milestone gate (see Iterations) shows Flutter-only paths cannot meet alarm reliability requirements under Doze/lockscreen/OEM constraints.
   - Exposes SchedulerPort, AudioPort, and AlarmController abstractions for the domain.

Dependency direction: Presentation -> Domain -> Data. System interacts with Domain via use-cases.

## 2. Key Modules & Responsibilities

- Thermostat Manager Module: CRUD, validation, and caching of thermostats.
- Telemetry Poller Module: Configurable background worker that coordinates network fetches, writes to DB, and notifies UI.
- History Aggregator Module: Streams revision history with progressive loading and down-sampling for long ranges.
- Alarm & Notification Module: Range evaluation, audible alarms, snooze/silence, exact-alarm permissions.
- Settings & Preferences Module: Poll interval, hysteresis, pause-all, sound selection; developer log export.
- Diagnostics Module: Central EventLog and status reporting (network/parse/auth/rate-limit).

## 3. Data Model Snapshot (Drift)

Aligns with Spec Section 5. Field names are explicit and indexed where needed.

- thermostats
  - id (TEXT UUID PK), name (TEXT), rawUrl (TEXT),
  - minC (REAL), maxC (REAL), hysteresisEnabled (BOOL),
  - monitoringEnabled (BOOL), createdAt (INTEGER TS), updatedAt (INTEGER TS)

- readings
  - id (TEXT UUID PK), thermostatId (FK), source (TEXT: "current"|"revision"),
  - valueC (REAL), observedAt (INTEGER TS), sourceId (TEXT NULL) // revision sha or null

- alert_config (single row)
  - pollIntervalMin (INT), exactAlarmsEnabled (BOOL),
  - soundUri (TEXT NULL), vibrate (BOOL), volumeBoost (BOOL),
  - pauseAllUntil (INTEGER TS NULL)

- thermostat_state
  - thermostatId (FK), lastFetchAt (INTEGER TS NULL),
  - lastStatus (TEXT: "OK"|"OUT_OF_RANGE"|"NETWORK_ERROR"|"PARSE_ERROR"|"AUTH_ERROR"),
  - lastValueC (REAL NULL), lastAlarmAt (INTEGER TS NULL),
  - snoozedUntil (INTEGER TS NULL), silenceUntilOk (BOOL DEFAULT 0)

- event_log
  - id (INTEGER PK AUTOINCREMENT), thermostatId (TEXT NULL), time (INTEGER TS),
  - level (TEXT: "INFO"|"WARN"|"ERROR"), message (TEXT)

- Optional aggregation for long ranges
  - reading_agg_hourly: thermostatId, bucketStart (INTEGER TS), minC, avgC, maxC, count

Indexes: readings(thermostatId, observedAt DESC), thermostats(name), event_log(time DESC).

## 4. Background Watchdog Strategy

- Periodic checks: WorkManager (1-30 min; default 5). While fetching, run as a Foreground Service (short-lived) to satisfy background limits.
- Exact alarms: When user enables critical alarms, request SCHEDULE_EXACT_ALARM (Android 12+). Schedule setExactAndAllowWhileIdle follow-ups via AlarmManager; degrade gracefully when denied.
- Concurrency: Fetch enabled thermostats sequentially with per-host concurrency capped at 2 to avoid thundering herd.
- Rate limiting: Detect 403/429 and GitHub rate-limit headers; back off per-thermostat up to 30 min and surface a UI banner.
- Actions: Snooze 5/10/30 min and Silence-until-OK persist to thermostat_state and influence scheduling.
- Boot: Register boot receiver and re-schedule WorkManager and any exact alarms after reboot.
- Full-screen alert: High-priority notification with full-screen intent uses user-selected tone; respects device volume and vibrate preferences.

## 5. Networking & Caching Approach

- HTTP via dio with policies:
  - Headers: Accept: text/plain for raw; If-None-Match when ETag available.
  - Timeouts: connect 5s, read 10s. Retries: up to 2 with jittered exponential backoff.
  - ETag cache per thermostat; handle 304 to avoid quota usage.
- Parsing: Single tolerant regex from spec; first match only; device receive time for current; revision commit timestamp for history.
- History:
  - GET /gists/{gist_id}/commits to list revisions, then fetch raw per sha.
  - Pagination until requested range is filled; progressive rendering as data arrives.
- Offline:
  - Cache last values in DB; surface "Updated X min ago".
  - Status-specific error handling (network, parse, auth). Banner guidance for rate limiting.

## 6. UI & Navigation

- Bottom navigation with two tabs: Thermostats and Settings.
- Thermostats list: cards show name, colored status (green OK, red Out of Range, yellow Error), last value with relative time, range pill, monitor toggle, overflow (Edit, View history, Remove); FAB to add.
- Add/Edit thermostat: fields per spec; Test & Save performs live fetch/parse with inline errors; invalid save is blocked.
- Details: current panel (big value, range, last updated, Snooze/Silence); graph panel (1h/1d/1w/1m/1y/All) with pan/zoom/tooltips; diagnostics (last status + last 10 log lines).
- Settings: poll interval slider, exact alarms toggle with rationale, pause-all durations; choose sound (system picker), vibrate, test alarm; rebuild history, export CSV; About.

## 7. Performance & Retention

- Home list loads from cached DB in <300ms; heavy parsing/aggregation can use isolates if needed.
- Graph renders <500ms up to ~1k points; beyond that use pre-aggregated hourly buckets.
- Retention: keep raw readings for 1 year; keep hourly aggregates beyond; purge raw older than 18 months; cap EventLog to 5,000 entries.

## 8. Permissions & Compliance

- Permissions: INTERNET, POST_NOTIFICATIONS (13+), FOREGROUND_SERVICE (+ subtypes as required by target SDK), SCHEDULE_EXACT_ALARM (on opt-in), scoped storage/URI permission for chosen sound.
- Clear rationale dialogs and graceful degradation when permissions are denied.

## 9. Packages

- Core: flutter_riverpod, go_router, freezed, freezed_annotation, json_serializable.
- Data: dio, dio_smart_retry, drift, sqlite3_flutter_libs, path_provider.
- Background/Alarms/Notifications: workmanager, android_alarm_manager_plus, flutter_local_notifications.
- Audio: audio_session, just_audio (Alarm stream attributes), and a ringtone/SAF picker plugin with persisted URI permissions.
- UI: fl_chart, intl.
- Testing: flutter_test, integration_test, mocktail, clock.

Optional (post-milestone if required):
- Native: farmctl_system (custom minimal plugin) for tighter control over Foreground Service lifecycle, exact alarms, lockscreen presentation, and URI permissions.

## 10. Testing & CI Strategy

- Unit tests: parser variations, hysteresis/range boundaries, scheduler math (snooze/silence), repositories/retention, rate limiting.
- Widget tests: add/edit Test & Save flow, list cards (OK/ERROR/OUT_OF_RANGE), settings interactions, banners.
- Integration/instrumentation: alarm surface full-screen with actions; background service scheduling; reboot reschedule; history graph with large mocked datasets.
- CI: GitHub Actions runs flutter analyze, dart test, flutter test with coverage gates (>=90% core, >=80% overall), builds debug APK; optional emulator job for integration tests.

## 11. Tooling & Developer Experience

- Melos or simple scripts for a two-package workspace (app/ + farmctl_system/).
- Linting via flutter_lints; analysis_options.yaml with strict null-safety. Pre-commit hooks for format/analyze.
- Developer toggles for verbose logging and diagnostics export (local only; no analytics).

## 12. Incremental Delivery Principles

- Each iteration yields a runnable Android build.
- CI is introduced early and must remain green; coverage gates enforced as features land.
- Spec updates (Spec.md) are kept in sync with implementation decisions as needed.

Decision Gate (Flutter-only viability):
- After delivering background monitoring and alarm surface (see Iterations Milestone Gate), run a reliability test matrix (API 34+, Samsung/Xiaomi if possible):
  - Exact alarms under Doze and screen-off
  - Foreground Service promotion/demotion during checks
  - Full-screen intent over lockscreen with dismiss-keyguard
  - Behavior after swipe-away force-stop and after reboot
- If any critical gaps remain using plugins, proceed to implement the minimal native plugin (farmctl_system) focused only on the missing capabilities.

