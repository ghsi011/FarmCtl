# FarmCtl UI / Charts / Settings / Routing Bug-Hunt Report

**Date:** 2026-06-27
**Scope:** UI / chart / settings / routing / lifecycle code (v0.3.0, post-remediation). The data /
concurrency / networking / parsing layers (`thermostat_monitor`, `thermostat_repository`,
`thermostat_database`, `thermostat_client`, `temperature_parser`, `alert_config_repository`) were
covered by a prior merged hunt and were intentionally excluded.
**Method:** Read-only static analysis of the target files. Each candidate was independently re-read
against the live source, then run through a refute-by-default verifier that discarded false positives,
corrected over-stated mechanisms, and re-rated severity. Only bugs that survived verification are
listed as confirmed. Dismissed candidates are recorded in the appendix with one-line reasons.

---

## Executive Summary

Seven correctness bugs were confirmed across the alarm-launch path, the alarm navigation stack, the
edit-thermostat state path, the history chart's timestamp math, and two Settings-page handlers. No
critical (data-loss / guaranteed missed-or-false-alarm / crash) bugs were found in this layer. The two
highest-impact issues both concern the cold-launch / re-tap alarm acknowledgement flow, where tapping an
alarm notification can fail to open the in-app alarm screen (cold launch) or can stack duplicate alarm
screens with a premature wakelock release (re-tap). The chart downsampler systematically mis-positions the
trailing (most-recent) point in time on every multi-sample chart. The remaining issues are state-desync /
resource-hygiene / swallowed-error defects of low impact.

### Counts

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High     | 2 |
| Medium   | 2 |
| Low      | 3 |
| Dismissed | 4 |

---

## Confirmed Bugs

### HIGH

#### UI-01 — Alarm notification tap from a cold-killed app never opens the in-app alarm screen
- **File:** `app/lib/core/background/thermostat_monitor.dart:186-217, 743-808`
- **What:** The tap handler `_handleNotificationResponse` is wired only through
  `onDidReceiveNotificationResponse` in `_initializeNotifications`. In flutter_local_notifications that
  callback fires only while the Dart isolate is alive. A tap that *launches* the app from a terminated
  state is delivered only via `getNotificationAppLaunchDetails()` / `didNotificationLaunchApp`, which is
  never called anywhere in the repo (grep returns nothing). `main()` runs `initializeBackgroundMonitoring()`
  then `runApp` with no launch-detail query, the router's `initialLocation` is `/thermostats`, and
  `AndroidManifest.xml` gives MainActivity only a MAIN/LAUNCHER intent-filter (no deep link). So on a cold
  launch the body tap lands on `/thermostats` and the in-app `/alarm` acknowledgement screen never appears.
  The `_navigateToAlarm` 60-attempt retry loop — whose own comment cites "cold launch from a notification
  tap" — is dead code for that stated purpose because nothing reads the launch details to invoke it.
- **Trigger:** Phone sits overnight; OS kills the FarmCtl process. A thermostat goes out of range and the
  ongoing alarm notification is posted by the WorkManager background isolate. User taps it → app
  cold-launches to `/thermostats`, no alarm screen, no in-app path to acknowledge/snooze.
- **Fix:** In `main()` (or app bootstrap) after the plugin is initialized, call
  `FlutterLocalNotificationsPlugin().getNotificationAppLaunchDetails()`; if
  `didNotificationLaunchApp == true`, extract the stored `notificationResponse.payload` (thermostatId) and
  route to `AlarmRoute.pathFor(thermostatId)` once the router is ready (reusing the existing
  `_navigateToAlarm` retry machinery). Also register `onDidReceiveBackgroundNotificationResponse` so action
  buttons work from the background/terminated state.

#### UI-02 — Re-tapping a re-posted alarm notification stacks a duplicate AlarmFullScreenPage and drops the wakelock early
- **File:** `app/lib/core/background/thermostat_monitor.dart:786-808` (with
  `app/lib/features/thermostats/view/alarm_fullscreen_page.dart:31-34`)
- **Severity:** verifier adjusted high → **medium** (edge-case interaction path; no data loss / missed
  alarm). Reported under HIGH per the original candidate severity, but treat as medium impact.
- **What:** `_navigateToAlarm` unconditionally calls
  `GoRouter.of(context).push(AlarmRoute.pathFor(thermostatId))`. go_router's imperative `push` assigns a
  unique page key and does NOT deduplicate by location, so it stacks a second `AlarmFullScreenPage` for the
  same id. The alarm notification is `ongoing: true` / `autoCancel: false` and is re-posted each monitoring
  cycle while the reading stays out of range. Tapping the re-posted notification while alarm page A is still
  on top pushes page B atop A. Dismissing/snoozing B pops only B, leaving identical page A underneath (user
  believes they acknowledged). Worse, each `_AlarmFullScreenPageState.dispose()` calls
  `WakelockPlus.disable()`, so popping B disables the wakelock while page A is still mounted and visible.
- **Trigger:** Open alarm via notification tap (page A). Reading stays out of range → notification re-posted
  next cycle. Tap it again → page B pushed atop A. Dismiss B → page A still visible; wakelock disabled while
  an alarm screen is still on screen.
- **Fix:** Before pushing, check whether the current GoRouter location is already
  `AlarmRoute.pathFor(thermostatId)` (e.g. via `GoRouterState.of(context).matchedLocation` /
  `GoRouter.of(context).routerDelegate.currentConfiguration`); if so, skip the push (or `go` instead of
  `push` to replace). Alternatively add a router redirect that collapses duplicate `/alarm/<id>` entries.
  Re-enabling the wakelock in `AlarmFullScreenPage.initState` (already the case) combined with dedup avoids
  the premature-disable problem.

### MEDIUM

#### UI-03 — Aggregated history points are plotted at bucket midpoint, shifting the trailing/partial bucket into the future
- **File:** `app/lib/features/thermostats/utils/thermostat_history_downsampler.dart:94-101`
- **What:** Each bucket's representative timestamp is hard-coded to `bucketStart + bucketSeconds ~/ 2`
  (the bucket center), independent of the actual `observedAt` of the samples it contains. Buckets are
  anchored to the first sample's time (`first`, line 22), not a calendar boundary, with
  `bucketStart = first + bucketIndex*bucketSeconds`. A sample lies anywhere in
  `[bucketStart, bucketStart+bucketSeconds)`, so the plotted point is shifted by up to ±half the bucket
  width: 2.5 / 5 / 30 / 60 / 60 / 60 min for hour/day/week/month/year/all. For a partially-filled bucket —
  most importantly the trailing bucket that typically holds one just-arrived reading near `bucketStart` —
  the synthetic point is drawn up to half a bucket *later* than the reading occurred, and can land after
  `DateTime.now()`. The chart consumes this `observedAt` for x-position, tooltip timestamps, and bottom-axis
  labels (`thermostat_history_chart.dart` lines 45, 125, 100), so the visualized "when" is wrong for the
  newest point on every realistic multi-sample chart. Single-overall-sample charts are unaffected
  (`downsample` returns early at `length <= 1`).
- **Trigger:** Open a Week-range chart (60-min buckets). The latest reading arrived ~5 min ago and is the
  only sample in the trailing bucket; it is rendered ~30 min later (and ~25 min in the future), and the
  tooltip shows the midpoint time, not the reading's real timestamp.
- **Fix:** Use a data-driven representative timestamp instead of the bucket center — e.g. the mean (or max)
  of the contained samples' `observedAt`, or for a single-sample bucket the sample's own `observedAt`. Track
  the timestamps in `_SampleBucket.add` and compute the representative from them in `toSample`.

#### UI-04 — Editing a thermostat clears an active out-of-range state (transient UI/state desync)
- **File:** `app/lib/features/thermostats/data/thermostat_service.dart:69-77` (driven by `_editThermostat`
  in `app/lib/features/thermostats/view/thermostats_page.dart:41-71`)
- **Severity:** verifier adjusted high → **medium** (alarm pipeline self-corrects on next monitor tick; no
  actual missed/false alarm).
- **What:** `updateAndTest` unconditionally writes `status: ThermostatReadingStatus.ok` and message
  `'Fetched X°C'` after a successful test fetch, with NO out-of-range check against the new min/max — unlike
  `refresh()` (lines 87-124) which calls `isThermostatReadingOutOfRange` before saving. `_editThermostat`
  calls `updateAndTest` on every save. So editing a thermostat that is currently `outOfRange` (even just
  renaming it, or setting a range that still excludes the current value) overwrites the persisted state to
  `ok`, wiping the out-of-range flag/message. The card (derived from `summary.state.status`) flips from
  red/out-of-range to green/ok with a misleading "Fetched X°C" until the next monitor cycle re-evaluates.
  The alarm-firing path itself recovers on the next tick (the rate-limit suppression branch only fires when
  `previousState.status == outOfRange`, which the edit just cleared, so the alarm re-arms rather than being
  suppressed), and `silenceUntilOk` / `snoozedUntil` are left untouched — hence medium, not a missed alarm.
- **Trigger:** A thermostat reads 95°C with range 0-40 (status outOfRange, card red). Open Edit, change only
  the name (or set range 0-50, still below 95), tap Test & Save. State is overwritten to `ok` /
  `Fetched 95.00°C`; the card turns green and the out-of-range condition is visually silenced until the
  background monitor next runs.
- **Fix:** In `updateAndTest` (and `createAndTest`), evaluate `isThermostatReadingOutOfRange` against the
  *new* draft's min/max before saving, mirroring `refresh()`: persist `outOfRange` + the formatted message
  when the fetched value violates the new range, otherwise `ok`.

### LOW

#### UI-05 — `_testGithubToken` has no try/catch: a thrown `loadConfig()` makes "Test token" a silent no-op
- **File:** `app/lib/features/settings/view/settings_page.dart:442-450`
- **What:** Unlike every sibling handler in this file (`_setGithubToken` :421-440 and `_exportLogs` :406-419
  both catch and show a "Failed to…" snackbar), `_testGithubToken` has no error handling. `loadConfig()`
  does real async I/O (Drift `getAlertConfig()` + secure-storage `_resolveToken()`), both of which can throw
  — and the codebase itself guards `loadConfig()` with try/catch elsewhere
  (`thermostat_monitor.dart:178, :270`), confirming it is a known throwing path. `testToken()` wraps its own
  errors and returns a String, so it is not the throwing path. If `loadConfig()` throws on a transient
  DB/secure-storage error, the Future completes with an unhandled error, no snackbar fires, and the user gets
  zero feedback after tapping "Test token". (The candidate's additional web claim was refuted: the file hard-
  imports `dart:io`, so web is not a buildable target — the synchronous `Platform.environment`
  `UnsupportedError` never occurs in practice.)
- **Trigger:** Tap "Test token" while a transient DB/secure-storage read failure occurs → no snackbar, no
  feedback at all, in contrast to every other button on the page.
- **Fix:** Wrap the body in try/catch (matching `_setGithubToken`) and show a
  `'Failed to test GitHub token: $error'` snackbar (guarded by `if (!mounted) return;`).

#### UI-06 — Clear/visibility suffix-icon desyncs from the token field while typing (no listener / no setState)
- **File:** `app/lib/features/settings/view/settings_page.dart:707-745`
- **What:** The clear IconButton is conditionally rendered via `if (_tokenController.text.isNotEmpty)`
  (line 729), but `_tokenController` (created in `initState` line 499) has no `addListener`, and the
  TextField has no `onChanged` (only `onSubmitted`). Typing schedules no `setState` in the parent state, so
  `build()` is not re-run per keystroke. The Clear (×) button therefore does not appear when the first
  character is typed into an empty field, nor disappear when the field is cleared via backspace, until an
  unrelated rebuild (toggling the obscure eye icon at lines 722-726, or a provider re-emit driving
  `didUpdateWidget` at lines 503-508). The TextField repaints its own text because it internally listens to
  the controller; the parent's conditional suffix icon does not. Impact is limited to a missing/stale
  convenience Clear button — the field, Save token, and onSubmitted all work.
- **Trigger:** Open Settings with an empty token field, type `g`. The Clear button does not appear until an
  unrelated rebuild (e.g. tapping the show/hide eye).
- **Fix:** Add `_tokenController.addListener(() => setState(() {}))` in `initState` (remove it in
  `dispose`), or give the TextField an `onChanged: (_) => setState(() {})`, so the suffix icon re-evaluates
  on each keystroke.

#### UI-07 — Per-submit `ThermostatHttpClient` (two Dio instances) is never closed — socket/resource churn on every add/edit
- **File:** `app/lib/features/thermostats/data/thermostat_service.dart:32-37, 61-66` (invoked from
  `thermostats_page.dart` `_createThermostat`/`_editThermostat` onSubmit)
- **What:** When a GitHub token override is present, `createAndTest` and `updateAndTest` each construct a
  fresh `ThermostatHttpClient(githubToken: tokenOverride, allowAnonFallback: false)`. That constructor builds
  TWO Dio instances (`_dio` and `_dioNoAuth`, `thermostat_client.dart:34-41`), each owning an HttpClient with
  persistent connections and a RetryInterceptor. The client is used for one `fetchCurrent` and then dropped
  with no `close()`/`dispose()` (the class has no such method). Every add/edit while a token is configured
  allocates two un-closed Dio/HttpClient instances. Impact is short-lived churn rather than an unbounded leak
  — Dart's default HttpClient closes idle keep-alive sockets after its idleTimeout (~15s) and the Dio objects
  become GC-able once `network` goes out of scope — but it is still avoidable resource hygiene.
- **Trigger:** Configure a GitHub token, then repeatedly add/edit thermostats. Each Test & Save allocates a
  new two-Dio client that is never explicitly closed.
- **Fix:** Add a `close()`/`dispose()` to `ThermostatHttpClient` (closing both `_dio` and `_dioNoAuth`), and
  in `createAndTest`/`updateAndTest` call it in a `finally` block when the local override client was created
  (do not close the shared `_network`).

---

## Appendix: Dismissed Candidates

1. **Exact-alarm switch can stay visually ON after permission denied** —
   `settings_page.dart`. Refuted: Flutter's `SwitchListTile.adaptive` is a fully *controlled* widget whose
   thumb is derived purely from the `value` prop on each build. On deny the config never becomes true (early
   return), so the switch never renders ON in the first place. No displayed-vs-stored desync.

2. **Detail page range selection not updated after changing range in fullscreen chart** —
   `thermostat_detail_page.dart`. Refuted: each page is internally consistent (its SegmentedButton/dropdown
   and its chart read the same `_range`). Independent per-page selection is a deliberate design choice, not a
   widget-vs-data desync — a UX decision, not a logic defect.

3. **Min/Max fields lack form validators** — `thermostat_form_dialog.dart`. Refuted: empty/non-numeric and
   out-of-range inputs ARE caught and surfaced as field-specific errors within the same synchronous `_submit`
   (manual parse + `ThermostatValidator.validate`); `autovalidateMode` is disabled so all fields behave
   identically. No wrong result on any real path; the concern is hypothetical fragility (style/refactor).

4. **Fullscreen history page unconditionally resets orientation to all on dispose** —
   `thermostat_history_fullscreen_page.dart`. Refuted: there is no app-wide portrait lock anywhere, so
   restore-to-all on dispose is functionally identical to the platform default. No user-observable wrong
   behavior today; the only trigger requires first adding a lock that does not exist.
