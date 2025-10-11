# Smart Thermostat Management App — Implementation Plan

This plan translates the executable specification into a concrete Flutter application architecture. It prioritises early delivery of a running Android build, core telemetry flows, and the background watchdog while keeping the project testable from the outset.

## 1. Architectural Overview

The app will follow a clean architecture variant with four layers to match the spec’s dependency rules:

1. **Presentation (Flutter UI + state)**
   * Uses Riverpod for dependency injection and state management. Widgets are composed with Material 3 components for accessibility and theming.
   * View models expose immutable state classes and async controllers for CRUD operations, polling, and alarm status.
2. **Domain**
   * Defines entities (`Thermostat`, `ThermostatReading`, `AlarmConfig`, etc.) and use-cases (`AddThermostat`, `FetchCurrentTemperature`, `BuildHistory`, `EvaluateOperatingRange`, `ScheduleMonitoring`, `AcknowledgeAlarm`).
   * Applies validation rules, hysteresis logic, and range evaluation policies. Domain layer depends only on abstractions.
3. **Data**
   * Implements repositories and data sources on top of:
     * `dio` HTTP client with retry/jitter middleware and offline caching (via `dio_cache_interceptor`).
     * GitHub Gist API wrapper for revisions/history. Parsing implemented centrally with regex from the spec.
     * `drift` (sqlite) for local persistence of thermostats, readings, history, and app preferences.
   * Provides DTOs and mappers to the domain entities.
4. **System Integration**
   * Android platform channels for foreground service, alarm scheduling, boot receiver, audio playback, and notification handling. Uses a dedicated Flutter plugin module (`farmctl_system`) sharing Kotlin code.
   * Exposes `SchedulerPort`, `AudioPort`, and `AlarmController` abstractions consumed by the domain layer.

Dependency direction: Presentation → Domain → Data; System layer interacts with Domain via use-case facade injected using Riverpod.

## 2. Key Modules & Responsibilities

* **Thermostat Manager Module**: Handles CRUD, validation, and caching of thermostats.
* **Telemetry Poller Module**: Configurable background worker that coordinates network fetches, writes to DB, and notifies UI.
* **History Aggregator Module**: Streams revision history with progressive loading and down-sampling for long ranges.
* **Alarm & Notification Module**: Coordinates range evaluation, triggers audible alarms, manages snooze/silence, and exact-alarm permissions.
* **Settings & Preferences Module**: Manages global toggles (poll interval, hysteresis, pause duration, sound selection) and exports developer logs.

## 3. Data Model Snapshot

* `thermostats` table: `id`, `name`, `rawUrl`, `minC`, `maxC`, `monitoringEnabled`, `hysteresisEnabled`, `createdAt`, `updatedAt`.
* `readings` table: `id`, `thermostatId`, `capturedAt`, `temperature`, `source` (current/polled/manual test), `status`.
* `history_samples` table: `thermostatId`, `sampleAt`, `temperature`, `revisionSha`, aggregated fields for down-sampled buckets.
* `app_preferences`: poll interval, default sound URI, vibrate, exact alarm flag, global pause state, developer log flag.
* `alarm_states`: `thermostatId`, `lastAlarmAt`, `snoozedUntil`, `silenceUntilInRange`.

## 4. Background Watchdog Strategy

* Use Android’s `WorkManager` (periodic work) for baseline polling, integrating with a Kotlin foreground service that displays the monitoring notification while work executes.
* For critical alarms, expose Kotlin APIs to request `SCHEDULE_EXACT_ALARM` permission and schedule `AlarmManager` exact triggers when enabled.
* The Flutter layer receives callbacks via platform channels to update UI, persist alarm acknowledgements, and handle snooze/silence actions.

## 5. Networking & Caching Approach

* HTTP requests executed with `dio` and resilient policies (timeout 10s, exponential backoff, jittered intervals).
* History fetching uses GitHub REST API `GET /gists/{gist_id}/commits`, followed by raw content fetch per revision. Implemented with pagination and cached ETags to respect rate limits.
* Latest reading stored locally so UI can operate offline; errors surface as banner states with retry actions.

## 6. Testing & CI Strategy

* **Unit tests**: Validate parsing, range evaluation, scheduler maths, repository CRUD, and alarm rate limiting using Dart’s `test` package.
* **Widget tests**: Cover add/edit flows, thermostat list states, alarm banners, and settings interactions using `flutter_test` with fake repositories.
* **Integration tests (Android)**: Use `integration_test` + `mockito` + Kotlin instrumentation harness for alarm service, verifying notification intents and sound playback through fake audio provider.
* **CI Pipeline**: GitHub Actions workflow running `flutter analyze`, `dart test`, `flutter test`, integration tests on Android emulator, and building signed debug APK artifact. Pipeline introduced by iteration 2.

## 7. Tooling & Developer Experience

* Use Melos or simple scripts to manage multi-package workspace (`app/` Flutter module + `farmctl_system/` plugin).
* Linting via `flutter_lints` plus custom rules (no forbidden APIs, enforce null-safety). Pre-commit hooks for formatting and static analysis.

## 8. Incremental Delivery Principles

* Each iteration produces a runnable Flutter app module that compiles for Android.
* Early iterations focus on project scaffolding, build pipeline, and minimal thermostat display.
* Subsequent iterations expand functionality while maintaining passing tests and CI.

