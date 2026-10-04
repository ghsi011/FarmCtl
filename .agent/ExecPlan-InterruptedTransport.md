# Bounded interrupted-transport host integration

Implement locally from master `8b0b59d12f0ba57e7447bfca7a79b03632857175`
on isolated `feat/host-interrupted-transport`; preserve prior/user work. This slice
is not authorized for commits, push or PR publication. No hardware or rollout.

## Intended proof

- Actual MicroPython Unix 1.29.0 native HTTP request/read/poll/deadline logic runs
  over real loopback sockets with a test-only plaintext TLS context and numeric
  resolver. Production host/capabilities/request builder remain unchanged.
- A dropped partial response header and a held response before application fail
  within a bounded request budget; publisher retries only at controlled backoff
  boundaries and eventually delivers a fresh sample.
- Real Flutter clients/service and file-backed Drift preserve delivered value,
  observation age and history during faults, including reopening SQLite.
- Failing-first and strict reached-phase mutation evidence distinguish intended
  regressions from startup failures; all existing deterministic lanes stay green.

## Work and validation

1. Assess actual socket/runtime, fixture and delivery semantics; pin smallest scope.
2. Add failing fixture/joined tests, then minimal local infrastructure and recovery.
3. Run joined/mutation and existing host/app/parser/firmware/release/offline mock
   suites, code generation, format/analyze, typing and scoped coverage floors.
4. Review from a dedicated isolated checkout: five complementary lanes and an
   independent finding validator; resolve scoped findings and capture exact patch.

Native TLS/CA/hostname, Android, hardware, applied-write/lost-ack reconciliation,
DNS fault campaigns, full partial-write/EOF matrices and RP2350 resource behavior
remain separate qualifications. Issue51 stays open.

## Decisions and evidence

- Native wayfinding confirmed real poll/ticks/read/write, errno 115 handling,
  fragmented successful reads and a 650ms deadline at 651ms. Unix requires its
  packed numeric sockaddr; only the already-supported resolver seam substitutes
  production bounded DNS. No compatibility workaround or production edit needed.
- PATCH success requires complete headers, not a drained response body. Chosen
  faults therefore interrupt the header before application. An applied write
  with lost acknowledgement could legitimately appear in remote history and is
  a separate readback/reconciliation qualification.
- A dedicated fixture handler bridges only synthetic Bearer authentication and
  fixed-header observation times, reusing existing validation/revisions. It
  rejects EOF/stall requests through the validated pre-application failure path.
  Disconnect or a 2.5s safety guard releases the owned single-threaded service.
- Failing-first legacy-adapter joined run reached the stall and failed at 2522ms;
  native replacement passed at 669ms. A copied-source native `_remaining`
  mutation independently reached the same stall at 2522ms and was rejected.
  Strict checker tests reject unrelated/startup errors and false success.
- Joined aggregate passed five actual Flutter cases and rejected four mutations;
  the new run measured 661ms, preserved only two delivered observations, and
  proved exact 5625ms then 12000ms retry boundaries. Diagnostics keep delivered
  sample reference 1 during failures; recovery sample 6 is delivered separately.

Validation: five joined Flutter cases/four rejected mutations; app 393 passed
(five driver-only skips), firmware 439, parser 17, release 16 and offline mock 18.
App line coverage 81.04% exceeds 70%; parser 100% exceeds 85%. Code generation,
Dart formatting/analyze, Python Ruff/typing and whitespace checks passed.
Fixture/checker statement coverage is complete; host unit/cleanup checks cover
Windows and Linux. Exact source/patch identity, final host totals, scoped branch
coverage and dedicated-checkout review reports are recorded in the local
workspace handoff. Independent review uses five complementary leaf lanes and a
validator against that exact patch. No commits, push, PR, release or version
change is authorized for this slice.
