# 🧩 ExecPlan — Background Monitoring Reliability (Pixel 9 / Android 15+)

## 🎯 Purpose
User report: the background monitoring watchdog fails to run reliably on a
Pixel 9. This resolves the ExecPlan.md "Gate A" decision (Flutter-only vs.
minimal native shim) by adopting a true Android **Foreground Service**
(`flutter_foreground_task`), which is exempt from Doze/App Standby deferral
while alive — unlike the previous `WorkManager` (15-min floor, still
Doze-deferrable) + `android_alarm_manager_plus` (exact-alarm permission
dependent) combination.

## 🧱 Scope
- In scope: background scheduler architecture, targetSdk bump (34 → 35),
  Settings UI cleanup for the retired exact-alarm toggle, DB migration to
  drop the now-unused `exact_alarms_enabled` column.
- Out of scope: alarm UX changes, new Settings features, iOS (not supported).

## 🧭 Decision Log
- **Foreground-service plugin over a hand-rolled native shim** — user chose
  this explicitly (`flutter_foreground_task`) over writing a bespoke Kotlin
  service. No native code to maintain; matches the ExecPlan's original
  Flutter-first preference.
- **`specialUse` foreground service type**, not `dataSync` — `dataSync` caps
  at 6h/24h on Android 15 and can't be launched from `BOOT_COMPLETED` on
  Android 15+; `specialUse` has neither restriction. The app is sideloaded
  (GitHub release APK, not Play Store), so `specialUse`'s Play Console
  review requirement for the subtype string doesn't block distribution.
- **Single scheduler as source of truth.** The live foreground service now
  drives every poll (`onRepeatEvent` at the user's configured interval, down
  to 1 minute, no 15-min floor, no exact-alarm permission needed).
  `android_alarm_manager_plus` and its one-shot self-reschedule chain are
  removed entirely — keeping it alongside a live service would double-poll
  (both independently reschedule at the same nominal interval, drifting
  apart and roughly doubling GitHub API calls). `workmanager` is demoted
  from "run the full monitor" to a **watchdog**: fixed 15-minute floor,
  restarts the foreground service if it isn't running, never fetches itself.
  This directly resolves the M-1/M-2 findings from `.agent/code-review-2026-06-27.md`
  (dual-scheduler race, non-exact fallback silently missing intervals)
  by deletion rather than further patching.
- **Removed the "Allow exact alarms" Settings toggle** and its permission
  flow — nothing schedules via `AlarmManager` anymore, so the toggle would be
  dead UI. Kept the "Allow background activity" (ignore battery
  optimizations) button — still relevant since Android can still restrict
  service starts/notifications for a non-exempt app.
- **DB migration v8 → v9** drops `exact_alarms_enabled` from
  `alert_config_entries` (`ALTER TABLE ... DROP COLUMN`, supported by the
  bundled SQLite). Left as a real migration rather than an inert unused
  field, per repo convention of not carrying dead code/columns.

## ⚠️ Known limitation of this session
No physical device or Android emulator is available in this sandboxed
environment (network policy also blocks the Android SDK/emulator images).
All Dart-level logic is covered by `flutter analyze` + `flutter test`
(including new migration/unit tests), but the actual foreground-service
lifecycle (persistent notification, boot restart, Doze exemption, OEM
kill-and-restart behavior) has **not** been verified on real hardware.
Recommend testing on the reporter's Pixel 9 before relying on it:
1. Grant "Allow background activity" in Settings.
2. Confirm the persistent "FarmCtl monitoring" notification appears and
   survives screen-off for an extended period (30+ min).
3. Reboot the device and confirm the notification/service comes back.
4. Force-stop the app from Android system settings and confirm the
   15-minute WorkManager watchdog brings the service back.

## 📈 Progress
- ✅ Investigated current dual-scheduler implementation and prior code-review
  findings (`.agent/code-review-2026-06-27.md`, `.agent/ExecPlan.md` Gate A).
- ✅ Confirmed `flutter_foreground_task` v9.2.2 API (fetched real source: task
  handler signatures, `ForegroundTaskOptions`, `specialUse` service type,
  Android 15 restrictions) directly from the plugin's GitHub repo.
- ✅ Implemented scheduler swap, manifest/gradle changes, Settings UI cleanup,
  DB migration (v8 -> v9, drops `exact_alarms_enabled`).
- ✅ Updated/extended unit + widget tests; `build_runner`, `analyze`, `test`
  (211/211) all green; coverage 72.75% (threshold 70%); `dart format` clean.
- ✅ Two independent review passes (scheduler correctness; Android
  manifest/plugin-API correctness against the real v9.2.2 source):
  - **Fixed**: `onStart` + `onRepeatEvent` (the only two callers of
    `_runMonitorTask`, both in the foreground service's own isolate) could
    both pass the DB-backed debounce check before either wrote
    `lastMonitorRunAt` back (check-then-write across separate `await`s),
    letting two runs execute concurrently. Closed with a synchronous
    in-isolate lock (`_monitorRunInProgress`) around `_runMonitorTask`,
    which can't race the same way since the check-and-set has no `await`
    between them. The DB-backed debounce is kept as a secondary safety net.
  - **No other real bugs found.** Manifest/service declaration, permissions,
    and every `flutter_foreground_task` call site were verified against the
    plugin's actual v9.2.2 source (not training-data assumptions).
  - **Open, non-blocking nit**: `compileSdk = flutter.compileSdkVersion` is
    auto-resolved from the Flutter SDK; if the developer's installed Flutter
    version resolves a `compileSdkVersion` below 35, the Gradle build would
    fail (`targetSdk > compileSdk`). Not introduced by this change (the app
    already relied on `flutter.compileSdkVersion` before), but worth a
    one-line `flutter --version` sanity check when building for real.
- ✅ Full "reviewer + skeptic" pass: 7 independent finder agents (line-by-line,
  removed-behavior, cross-file tracing, reuse, simplification, efficiency,
  altitude, CLAUDE.md/AGENTS.md conventions) plus a skeptic verifier on the
  fixes themselves.
  - **Fixed**: duplicated `ForegroundTaskOptions` construction between
    `init()`/`updateService()` extracted into one `_foregroundTaskOptions()`
    helper; `FlutterForegroundTask.init()` no longer runs on every call when
    the service is already running (only needed on the cold-start path —
    verified against the real plugin source that `updateService()`/
    `isRunningService` never read `init()`-populated static state); the
    `thermostatMonitorTask`/`thermostatMonitorUniqueName` constants (now
    watchdog-only) renamed to `thermostatWatchdogTask`/
    `thermostatWatchdogUniqueName` for clarity (string *values* unchanged, so
    WorkManager still targets the same persisted periodic work on upgrade);
    stale comment referencing "WorkManager retry backoff" (no longer
    applicable — the watchdog doesn't call `_runMonitorTask`) rewritten;
    added a comment on `_runWatchdogTask` explaining why it isn't redundant
    with the plugin's own `allowAutoRestart`/`autoRunOnBoot` (it survives an
    OEM process kill, which those don't — the actual Pixel 9 failure mode).
  - **Declined, with rationale**: merging the 3 "open DB → load config →
    close" sites (`initializeBackgroundMonitoring`, `_runWatchdogTask`,
    `_runMonitorTaskLocked`) into one shared helper — on inspection they have
    genuinely different, intentional error-handling shapes (swallow-and-close
    vs. propagate-and-close vs. swallow-and-keep-open for the rest of the
    run), so a shared helper would need parameters for each axis and not
    actually reduce complexity. Removing the WorkManager watchdog in favor of
    the plugin's native restart-only mechanisms — it's the only thing that
    survives an OEM battery-manager process kill (see the new code comment).
    Making pause immediately drop the service's tick cadence to the pause end
    — real but low-severity (a few extra cheap DB reads per tick during a
    pause window, no missed/incorrect behavior); would need to touch
    pause-start/resume/duration-change call sites for a UX-only, non-bug win.
    Escalating repeated `_runMonitorTask` failures beyond a debug log — a
    genuine observability gap (a permanently-failing DB wouldn't get any
    watchdog attention since `isRunningService` stays true) but is a new
    diagnostics feature, not a bug fix, out of scope for this pass.
  - **Refuted**: `pollIntervalMillis`'s 30s floor removing the old "0 =
    monitoring off" state (unreachable — Settings clamps 1–30 min, DB default
    is 5 min, no write path produces 0); poll-interval-vs-alarm-rate-limit
    ratio (by design per `docs/Spec.md`: 1–30 min poll range, fixed 5 min
    rate limit, pre-existing whenever exact alarms were previously enabled);
    `BootCompletedReceiver`'s removed synchronous notification (a net
    improvement — it used to show "Monitoring active" unconditionally even
    on total scheduling failure); the v8→v9 `dropColumn` "old SQLite"
    concern (`sqlite3_flutter_libs` bundles its own recent SQLite, not the
    OS/WebView one — DROP COLUMN has been supported since SQLite 3.35, 2021);
    the iOS/non-Android no-op path (iOS is explicitly out of scope per
    AGENTS.md).
  - Re-ran `flutter analyze` (clean), `flutter test` (211/211), and
    `dart format` (clean) after applying fixes.
- ☐ Manual verification on the reporter's Pixel 9 (see the limitation note
  above) — could not be done in this sandboxed session.
