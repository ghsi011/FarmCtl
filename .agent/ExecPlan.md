# 🧩 FarmCtl ExecPlan — Prototyping → Milestone Gate A

This ExecPlan is a living document spanning design through implementation. It consolidates scope and progress from the Spec and prior planning into one place and will be updated as the project evolves.

---

## 🎯 Purpose / Big Picture
Deliver a production-ready Android app that monitors multiple thermostats via GitHub Gist API, evaluates per‑thermostat operating ranges, and raises reliable audible alarms (Android alarm-like behavior) when out of range. Users can add/edit/remove thermostats, view current readings and historical graphs, configure watchdog cadence and alarm sound, and rely on background checks that continue across reboots. The milestone sequence validates a Flutter‑first approach with a decision gate (Gate A) to determine whether a minimal native shim is needed for reliability under Doze/lockscreen/OEM constraints.

---

## 🧱 Initial Requirements & Scope
- In-scope (Android only):
  - Thermostat CRUD with validation (GitHub Gist ID; tolerant parsing; °C only).
  - Current reading via GitHub Gist API (by Gist ID); history via Gist revisions; local caching.
  - Background watchdog with Foreground Service checks; out‑of‑range alarms with snooze/silence; optional exact alarms with permission.
  - Settings: poll interval, hysteresis toggle, global pause, sound picker with persisted URI permissions.
  - Accessibility and internationalization scaffolding; deterministic tests (unit, widget, integration), CI pipeline.
  - Targets: minSdk 26, targetSdk 34.
- Out of scope:
  - iOS/web/desktop; writing to physical devices; non‑GitHub data sources.

Assumptions and contracts align with `docs/Spec.md` (Sections 2–7, 8–18).

---

## 🪜 Milestones & Deliverables
High‑level milestones map to Iterations (see `docs/iterations.md`) and architecture in `docs/ImplementationPlan.md`.

1) Iterations 1–2: Workspace bootstrap + CI gates
   - Deliver: Flutter workspace under `app/`, Material 3 + Riverpod skeleton, bottom nav (Thermostats, Settings), analyzer/tests in CI.
   - Acceptance: App runs; CI green (analyze/test); at least one unit test.

2) Iteration 3: Domain & persistence foundation
   - Deliver: Drift schema (thermostats, alert_config), repositories, validation.
   - Acceptance: CRUD works locally; validation unit tests.

3) Iteration 4: Live fetching & current state UI
   - Deliver: HTTP client (timeouts/retries/headers); Test & Save on add/edit; last‑seen display.
   - Acceptance: Parse within 10s on save; clear error states.

4) Iteration 5: Background monitoring (Flutter‑first)
   - Deliver: WorkManager periodic checks; Foreground execution; caching; basic diagnostics.
   - Acceptance: Checks continue in background and across reboot with visible notification.

5) Iteration 6: Range evaluation & alarm surface
   - Deliver: Hysteresis/rate limiting; full‑screen alarm UI; snooze/silence.
   - Acceptance: Reliable alarms with actions; respects rate limiting.

6) Milestone Gate A: Validate Flutter‑only reliability
   - Deliver: Test matrix (API 34 emulator; stretch OEM devices) for exact alarms, Foreground behavior, full‑screen intents, reboot/force‑stop.
   - Decision: Proceed Flutter‑only or add minimal native plugin (Iteration 7A).

7) Iteration 7: History aggregation & graphs
   - Deliver: Revisions client, normalized storage, downsampling, interactive charts.
   - Acceptance: Incremental load; smooth rendering.

8) Iteration 8: Settings, sound picker, global controls
   - Deliver: Config UI; persisted sound URI permissions; developer log export.

9) Iteration 9: Exact alarms & advanced scheduling
   - Deliver: Permission UX; exact scheduling fallback strategy.

10) Iteration 10: Offline resilience, retention, a11y, final QA
   - Deliver: Offline flows; retention pruning; a11y/i18n; coverage ≥ targets; release docs.

---

## 📈 Progress
Use ☐/[-]/✅ with UTC timestamps to reflect real progress.

- ✅ `[2025-10-12 16:00Z]` Initialize ExecPlan; align scope with `Spec.md`.
- ✅ `[2025-10-12 16:30Z]` Bootstrap Flutter workspace under `app/` with Material 3 + Riverpod and bottom navigation.
- ✅ `[2025-10-12 17:30Z]` Configure CI pipeline (analyze/test/build); add a parsing unit test scaffold.
- ✅ `[2025-10-12 18:10Z]` Set Android targets minSdk 26, targetSdk 34; enable core library desugaring.
- ✅ `[2025-10-12 19:00Z]` Update documentation to reflect Flutter‑first approach and Gate A.
- ✅ `[2025-10-13 14:00Z]` Implement Drift schema (thermostats, alert_config) and repositories; wire validation; CRUD UI integrated.
- ✅ `[2025-10-13 20:00Z]` Implement background monitoring worker scaffold and unit tests; wire initial app entry.
- ✅ `[2025-10-13 20:10Z]` Normalize thermostat state timestamps to UTC for consistency across layers.
- ✅ `[2025-10-13 20:30Z]` Register plugins in WorkManager background isolate using DartPluginRegistrant; avoid native code.
- ✅ `[2025-10-13 20:40Z]` Switch data source to GitHub Gist API with Gist ID only; update validation/UI/tests.
- ☐ `[2025-10-14 16:00Z]` Implement HTTP client (timeouts/retries/headers) and Test & Save on add/edit.
- ☐ `[2025-10-15 16:00Z]` Background periodic checks with Foreground execution; diagnostics log.
- ✅ `[2025-10-16 16:00Z]` Range evaluation, alarm surface with snooze/silence; rate limiting.
- ☐ `[2025-10-17 16:00Z]` Gate A reliability validation and decision.
- ✅ `[2025-10-18 16:00Z]` Normalize revision history storage, add detail chart with downsampling for long ranges.
- ✅ `[2025-10-19 14:00Z]` Completed iteration 8 settings deliverables: system sound picker with persisted permissions and developer log export refinements.
- ✅ `[2025-10-20 16:00Z]` Hardened offline experience with connectivity heuristics, banner UX, and unit tests for status detection.
- ✅ `[2025-10-20 16:45Z]` Implemented history retention pruning (18-month window + entry cap) wired into foreground and background refresh paths.
- ✅ `[2025-10-20 17:15Z]` Added accessibility semantics, localization delegates, and release-ready documentation updates.

### Executive Summary (current)
- Created supported Flutter app under `app/` with Material 3 + Riverpod and bottom navigation.
- Set minSdk 26, targetSdk 34; aligned with Spec; enabled desugaring for plugin compatibility.
- Established CI (analyze/test/build) and seeded unit tests; build succeeds.
- Adopted Flutter‑first plan with Milestone Gate A; delayed any native work until after reliability validation.
- Standardized to Celsius; removed Fahrenheit references across parsing/tests/UI.
- Added Drift persistence for thermostats and alert config; integrated CRUD with validation and wired initial widget tests.
- Added background monitoring scaffold using WorkManager with entrypoint wiring and initial tests.
- Normalized thermostat timestamps to UTC to avoid device/timezone skew and simplify comparisons.
- Registered plugins in the background isolate (no native code) to enable notifications and path provider.
- Switched to GitHub Gist API with Gist ID–only configuration; simplified client and tests.
- Delivered offline-aware UI, retention pruning, and accessibility/localization polish to reach iteration 10 release readiness.

---

## 💡 Surprises & Discoveries
- Core library desugaring required to satisfy plugin dependencies (resolved with `desugar_jdk_libs 2.1.5`).
- Background reliability under OEM constraints remains a risk; mitigated via Gate A with a path to a minimal native shim if needed.

---

## 🧭 Decision Log
- `[2025-10-12]` Background reliability strategy — Chose Flutter‑first using mature plugins; defer minimal native shim until after Gate A validation; impact: faster delivery with explicit risk gate.
- `[2025-10-12]` Android SDK targets — Set minSdk 26, targetSdk 34 to match Spec; impact: modern APIs and consistency.
- `[2025-10-12]` Units — Standardize on Celsius only; impact: simpler parsing and consistent UI/tests.
- `[2025-10-12]` Build toolchain — Enable core library desugaring to satisfy dependencies; impact: unblocked builds.
- `[2025-10-13]` Persistence technology — Adopt Drift for typed schema and stream queries; impact: simpler migrations and reactive UI wiring.
- `[2025-10-13]` IDs — Use UUIDs for thermostats; impact: future‑proofing for potential sync and uniqueness guarantees.
- `[2025-10-13]` Time semantics — Normalize all stored/processed thermostat timestamps to UTC; impact: consistent comparisons, predictable testing, easier cross‑device behavior.
- `[2025-10-13]` Background isolate plugins — Use DartPluginRegistrant.ensureInitialized() to register plugins in WorkManager isolate; impact: avoids MissingPluginException without native code.
- `[2025-10-13]` Data source input — Prefer GitHub Gist ID only and fetch via Gist API, deprecating raw URL input; impact: simpler UX and more robust fetching.

---

## 🏁 Outcomes & Retrospectives
To be completed at milestone close:
- What was achieved vs acceptance criteria
- What went well / could be improved
- Links to retrospectives and any follow‑up work

---

## References
- Specification: `docs/Spec.md`
- Implementation architecture: `docs/ImplementationPlan.md`
- Working instructions for agents: `AGENTS.md`


