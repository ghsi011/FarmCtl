# Untrusted clock host simulator

## Scope and wayfinding

Start from master `9ecca320db5fe9eee11e32017440c1f8e4abf43b` in an isolated
worktree. Existing Unix/runtime, loopback API, Flutter client/service, and Drift
seams suffice. Use current dependencies; change only test infrastructure and
documentation. No devices, production source changes, credentials, live Gist
requests, network/authentication changes, or package installations. Commit,
push and PR creation were separately approved after tests and independent review;
merge remains with the parent.

## Acceptance criteria

1. Deliver a valid initial temperature and independent diagnostics.
2. Lose clock trust: real Monitor keeps sampling, real GistPublisher makes zero
   PATCH attempts for either stream (transport and wire counters agree).
3. While firmware is paused, real Flutter clients/service retain prior value and
   observation time, report stale with controlled app time, and create no history.
4. Restore trust after backoff and deliver a newly sampled value; history and
   reopened SQLite contain only delivered observations.
5. An always-trusted callback during the untrusted phase must fail at the pause
   assertion. Corrected repeated runs require strict outcomes, bounded diagnostics
   and owned cleanup. Production source is untouched even for mutation testing.

## Plan

Write the continuous coordinated test with the prior always-trusted harness
callback and capture its failure. Connect the callback to the controlled trust
state, retain the deliberate mutation, test counter/seed failure contracts,
repeat joined runs, and run existing coverage/lint/regression checks. Obtain
independent goal, QA, quality, security and context reviews plus a validator.
Reconcile stale issue-50 wording with its verified resolution and limits.

## Limits and evidence

Trust state, sensor, clock and HTTPS transport are synthetic boundaries. This
case tests the existing clock gate and application freshness semantics; it does
not test NTP, actual clock qualification, verified TLS, Pico peripherals/memory,
Wi-Fi, watchdogs, power loss, Android platform/UI, or live GitHub behavior.
Record failing-first, seeded, repeated and regression results below before PR.

## Validation (2026-10-03)

- Failing-first: the old always-trusted callback reached the paused checkpoint;
  the app rejected `[true, true]` publication results where `[false, false]` was
  required. The driver exited 1 without its success marker.
- Two corrected joined runs with both mutation checks passed in 23.420s and
  20.995s. The clock mutation reached untrusted pause with three sensor reads,
  sequence 3 and three attempts per stream, then failed the expected assertion.
  Corrected pause kept both transport/wire counts at 1; recovery advanced to 2
  with a newly sampled value and sequence 4. Both app suites and cleanup passed.
- Host checks: 37 pytest scenarios pass on Windows Python 3.14 and existing
  Linux Python 3.10. Scoped fixture/process coverage: 256/282 line-and-branch
  obligations (90.78%; 212 statements, 70 branches). Child entrypoints, the Job
  wrapper and actual MicroPython execution are outside this in-process denominator.
- Existing regressions: app 393 pass (three system tests skipped without driver),
  parsing 17, firmware 439, release manifest 16, offline-spare mock tests 18.
  App handwritten line coverage 4,961/6,122 (81.04%); parser 4/4 (100%).
  Publisher/runtime/telemetry CPython coverage: 89% combined (482 statements,
  162 branches). These are scoped host figures, not hardware qualification.
- Source generation, Dart formatting/analysis, Ruff and Python 3.10 basic type
  checking pass. Firmware suite was rerun from its documented directory after
  an initial root-directory invocation produced import-path errors. Windows
  CRLF prevented direct WSL execution of the coverage shell script; the identical
  handwritten-LH/LF calculation passed both unchanged coverage floors locally.
- Existing cached dependencies only; no lockfile or production-source changes.
- Independent first review accepted goal/context/QA, and caught two blockers:
  partial marker visibility and a child-owned SQLite cache outside parent cleanup.
  Ready/ack markers now close then atomically rename; the cache lives under the
  driver-owned temporary directory. A real forced child termination regression
  confirms the parent removes the unfinished cache directory without child teardown.
- After fixes: two joined runs with both mutations passed in 19.928s and 17.814s;
  38 host tests pass on Windows and Linux. Scoped fixture/process coverage remains
  256/282 (90.78%). Dart analysis/format, Ruff and Python type checks remain clean.
  The new cleanup regression uses a fresh stdlib temporary directory after pytest's
  shared Windows temporary root was inaccessible; no permission changes were made.
- Issue 50 state and canonical resolution comment were re-read through the
  authorized read-only GitHub connector: closed/completed, with the exact staged
  run and qualification limits recorded in README and the earlier plan.
