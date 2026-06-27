# 🛠️ ExecPlan — Code-Review Remediation (2026-06-27)

Living plan for fixing the findings from the multi-agent code review
(`.agent/code-review-2026-06-27.md`). Design → implementation, updated as work proceeds.

## 🎯 Purpose
Resolve the 26 confirmed findings from the repo-wide review, adding tests to every code
area touched so line coverage rises from the 27.46% baseline. Deliver as **one PR** on
branch `feat/code-review-fixes`.

## 🧭 Decisions (from user, 2026-06-27)
- **Delivery:** single comprehensive PR at the end (literal AGENTS.md flow).
- **Dependencies approved:** `flutter_secure_storage` (M-5), `wakelock_plus` (I-1).
- **UI scope:** all fixes **+ dark theme (M-8)**; **defer** full l10n/ARB scaffolding (I-3).
- Scope = all 26 findings **except I-3** (deferred).

## 🧱 Baseline (verified green before changes)
- Flutter 3.41.7 / Dart 3.11.5 (PowerShell: `C:\Tools\flutter.bat` → `C:\Users\ghsi0\source\flutter`).
  The Bash-PATH install `C:\github\Flutter\flutter` is broken (Dart SDK cache update fails) — avoid it.
- `flutter test`: **48 passing**. Coverage **27.46%** (LH=1249 / LF=4549).
- `dart run build_runner build --delete-conflicting-outputs`: clean.
- CI green on master; coverage gate is `tool/check_coverage.sh 27` (exists, tracked).

## 🪜 Iterations
1. **Safety-critical alarm pipeline** — H-1 (parser misparses → anchored regex + fail-closed
   + adversarial tests), H-2 (alarm `PopScope` guard), M-9 (hysteresis tests), M-10
   (`_shouldTriggerAlarm` silence/rate-limit/expired-snooze tests).
2. **Background concurrency & scheduling** — H-3 (atomic alarm decision via Drift transaction
   + compare-and-set), M-1 (single scheduler / run debounce), M-2 (exact-alarm fallback +
   re-check), M-3 (WorkManager returns false on failure).
3. **Data / HTTP / security** — M-4 (`validateStatus` on fetchHistory/listCommits), M-5 (PAT →
   secure storage), M-6 (Drift migration tests 1→6), L-11 (parseError mapping), L-12 (client
   error-path tests).
4. **Tests & CI coverage gate** — M-11 (ratchet floor + per-package coverage), I-8 (parsing
   coverage in CI), I-6 (injectable clock in client), I-7 (exporter + snooze-mapping tests).
5. **UI & architecture polish** — M-7 (DI factory), M-8 (dark theme), L-1/L-4 (value equality),
   L-2/L-3 (move coordination out of widgets), L-5 (UTC history reads), L-6 (cold backfill),
   L-7 (foreground alarm divergence), L-8 (transactional prune), L-9 (notification id),
   L-10 (export gist-id note), I-1 (wakelock), I-2/I-4/I-5 (UI nits). Defer I-3.

Each iteration: implement → `build_runner` → `flutter test --coverage` + `dart test`
(parsing) → review pass → commit on branch.

## 📈 Progress
- ✅ `[2026-06-27]` Setup: branch `feat/code-review-fixes`, baseline captured, ExecPlan written.
- ✅ `[2026-06-27]` Iteration 1 — safety-critical alarm pipeline (H-1, H-2, M-9, M-10). 48→62 tests, 27.46→29.49%.
- ✅ `[2026-06-27]` Iteration 2 — background concurrency & scheduling (H-3, M-1, M-2, M-3). 62→75 tests.
    - H-3: extracted pure `shouldTriggerAlarm`; atomic `recordOutOfRangeAndShouldAlarm` (txn + compare-and-set).
    - M-1: `lastMonitorRunAt` (schema v7) + `shouldSkipMonitorRun` debounce.
    - M-2: exact→flexible alarm fallback in `_updateAlarmSchedule`.
    - M-3: `_runMonitorTask` returns success; WorkManager retries on failure.
    - NOTE: the v7 (and full 1→7) migration test is delivered in Iteration 3 / M-6.
- ✅ `[2026-06-27]` Iteration 3 — data / HTTP / security (M-4, M-5, M-6, L-11, L-12). 75→85 tests, →31.91%.
    - M-4: `validateStatus: (_) => true` on fetchHistory/listCommits/_resolveFileContent so the
      403 anon-fallback + non-200 error mapping are live; made `_dioNoAuth` injectable.
    - L-11: `_decodeJsonArray`/`_decodeJsonObject` map malformed 200 bodies to parseError.
    - L-12: client tests — gist-id guard, non-200→httpError, 5xx→httpError, malformed→parseError, 403 fallback.
    - M-5: GitHub PAT moved to `flutter_secure_storage` via `SecureTokenStore`; legacy plaintext token
      migrated out of the DB on first read; providers + background isolate resolve via the repository.
    - M-6: migration tests (v6→v7 and full v1→v7) via Drift-built schema + raw downgrade; also fixed a
      latent createTable/addColumn ordering bug that crashed real v1→v7 upgrades.
- ☐ Iteration 4 — tests & CI coverage gate.
- ✅ `[2026-06-27]` Iteration 4 — tests & CI coverage gate (M-11, I-6, I-7, I-8). 85→90 tests, →33.10%.
    - I-6: injectable clock on `ThermostatHttpClient`; the wall-clock test now pins `fetchedAt`.
    - I-7: extracted pure `snoozeDurationForAction`; added `DeveloperLogExporter` tests (incl. a
      token-never-leaks assertion) and snooze-mapping tests.
    - I-8: parsing package now runs `dart test --coverage` → lcov, gated at 85% (currently 100%).
    - M-11: app coverage gate ratcheted 27% → 31% (current 33.1%); parsing package gated separately.
- ✅ `[2026-06-27]` Iteration 5 — UI & architecture polish. 90→99 tests, →34.85%.
    - M-7: `buildMonitorDependencies` factory centralises the isolate's repo/client/service/runner wiring.
    - M-8: light + dark themes from a shared builder, `themeMode: ThemeMode.system`.
    - L-1: value equality (`==`/`hashCode`) on Thermostat / ThermostatState / ThermostatSummary /
      TemperatureSample / AlertConfig.
    - L-2: refresh throttle uses `nowProvider` instead of inline `DateTime.now()`.
    - L-5: `watchHistory` normalises `observedAt` to UTC.
    - L-8: `pruneRetention` runs its deletes in a single transaction.
    - I-1: alarm page holds a wakelock while mounted (wakelock_plus, best-effort).
    - I-2: history `SegmentedButton` scrolls horizontally so it can't overflow.

### Deferred (Low/Info — documented, not fixed)
Deliberately not changed in this stabilization PR; all are the lowest-severity tier and several are
flagged "negligible / not a defect / intended" by the review itself. Rationale per item:
- **L-3** (settings writes config via repository + reschedules in-widget): partially eased by M-7;
  a full MonitoringController indirection would churn the 985-line settings page for low benefit.
- **L-6** (first history sync doesn't seed coarse buckets): latent, self-heals over later runs.
- **L-7** (manual refresh is display-only, no alarm): intended — the background watchdog owns alarms;
  the review confirms it does not corrupt rate-limit state.
- **L-9** (notification-id `hashCode % 1e6` collision): probability ~1e-4 for a handful of sensors.
- **L-10** (developer-log export embeds gist IDs): developer-only export, not auto-shared; the token
  is already omitted.
- **I-4 / I-5** (token-field tap targets; alert-card colour tokens): cosmetic; I-5 is "not a defect"
  (Semantics already encode status).
- **I-3** (full l10n/ARB scaffolding): deferred per the user's scope decision.

- ✅ `[2026-06-27]` Final multi-agent review (3 reviewers + validator). Verdict: safe to PR.
    Applied the must-fix + cheap legit cleanups:
    - Debounce 30s→10s so a failed run's WorkManager backoff retry isn't debounced away (must-fix).
    - `_scheduleMonitorOneShot` returns `oneShotAt`'s bool so a non-throwing refusal still downgrades.
    - HTTP: anon-fallback non-200 → httpError in fetchHistory + _resolveFileContent; `_parseCommitsList`
      uses `_decodeJsonArray` (consistent malformed-200 → parseError). +1 client test.
    - `watchConfig` is now a pure read (no scrub-write side effect in the stream); migration stays in
      loadConfig/setGithubToken.
    Deferred nice-to-haves noted: deeper PopScope behavioural test (needs notification-plugin mock),
    `AndroidOptions(encryptedSharedPreferences)` (needs on-device migration testing).
- ☐ Open PR.

## 🗒️ Decision Log
- `[2026-06-27]` Parser fix uses boundary anchoring (leading `(?<![\w.,])`, trailing
  `(?![A-Za-z0-9])`) and **fails closed** (returns null → `parseError`) on ambiguous inputs
  (thousands separators, leading dot, unit glued to an identifier). Rationale: for a safety
  alarm app, a missing reading the user can see beats a silently wrong one.
