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
- [-] `[2026-06-27]` Iteration 1 — safety-critical alarm pipeline (in progress).
- ☐ Iteration 2 — background concurrency & scheduling.
- ☐ Iteration 3 — data / HTTP / security.
- ☐ Iteration 4 — tests & CI coverage gate.
- ☐ Iteration 5 — UI & architecture polish.
- ☐ Final — deep review, coverage check, PR.

## 🗒️ Decision Log
- `[2026-06-27]` Parser fix uses boundary anchoring (leading `(?<![\w.,])`, trailing
  `(?![A-Za-z0-9])`) and **fails closed** (returns null → `parseError`) on ambiguous inputs
  (thousands separators, leading dot, unit glued to an identifier). Rationale: for a safety
  alarm app, a missing reading the user can see beats a silently wrong one.
