# ExecPlan — UX Overhaul (fix/ux-overhaul)

Fixes the full set of findings from the 2026-06-28 comprehensive UX review.
User decisions: fix **everything**; alarm "Dismiss" → **Acknowledge (stay armed)**;
**leave the Gist-ID field as-is**; delete → **Undo + error-tint**.

## Shared helpers (Iter A)
- `core/format/semantics_text.dart` — `spokenTemperature` / normalize `°C`→"degrees Celsius", `•`→".".
- `core/format/error_messages.dart` — `humanizeError(Object)` → friendly, actionable copy (no raw exception dumps).
- `core/format/relative_time.dart` — shared `formatRelativeDuration` + `formatElapsed` (promote from card).
- `features/thermostats/models/thermostat_status_presentation.dart` — map each of the 6 `ThermostatReadingStatus`
  to (label word, icon, severity: ok|warning|danger|offline) so status is never color-only and out-of-range ≠ wifi blip.

## Iterations
- **B Alarm screen** — Semantics + `liveRegion` + announce on appear; `Acknowledge` replaces `Dismiss`
  (stops sound, stays armed, no permanent silence); full-width ≥56dp stacked actions ordered by escalation;
  elapsed "out of range for …" from `lastAlarmAt`; `SingleChildScrollView`; clamp name; spoken °C;
  announce snooze/silence outcome; "Silence until back in range"; humanized error.
- **C Card** — distinct icon+colour+word per status via presentation model; hero highlight driven by
  out-of-range (temperature) not connectivity; explicit status pill; staleness dim past threshold;
  `explicitChildNodes`; de-dup spoken temperature.
- **D Thermostats page** — pull-to-refresh + Retry on error; delete Undo (re-create) + error-tinted Delete;
  app-wide Pause banner w/ Resume; empty-state inline CTA; offline banner uses tertiary/error (not green)
  + distinguishes offline/degraded + `liveRegion`; humanized + consistently-styled snackbars; in-flight guard.
- **E Detail / fullscreen / chart** — not-found hides Refresh + adds "Back to thermostats"; shared range state
  across detail↔fullscreen; inline history Retry + drop duplicate indicator; no forced orientation;
  chart min/max safe-range band; Y-axis 1-dp + °C; explicit tooltip colour; consistent state heights.
- **F Settings** — persistent sub-15-min cadence note (honest freshness); poll-commit + test-alarm confirmations;
  token "optional/leave blank" + humanized test result + how-to + in-flight + unsaved hint; pause absolute time;
  `_formatDuration` one style; copy polish; slider semantics.
- **G Form dialog** — Min/Max inline validators + hints + range error on Max field; "Save without testing" on
  network failure + "Testing connection…"; strip trailing `.00`; `maxLength: 40`; spoken field labels. (Gist field untouched.)
- **H Router** — branded `errorBuilder` 404 w/ "Go to Thermostats"; delete dead `pathFor` helpers.
- **I Tests** — update tests the new behaviour breaks; add tests for new logic; keep ≥70% (gen + Drift decls excluded); analyze/format green.
- **J Reviews** — 2 review agents (correctness/logic + a11y/safety) + validator; fix real findings.
- **K PR**.

## Guardrails
- `dart run build_runner build --delete-conflicting-outputs` before analyze/test.
- No production-behaviour change to alarm *arming* — Acknowledge must still allow re-alert.
- Keep diffs focused; Material 3 via Theme/ColorScheme only.
