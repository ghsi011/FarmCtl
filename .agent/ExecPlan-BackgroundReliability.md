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
- ☐ Implement scheduler swap, manifest/gradle changes, Settings UI cleanup,
  DB migration.
- ☐ Update/extend unit + widget tests; run `build_runner`, `analyze`, `test`.
- ☐ Code review pass.
