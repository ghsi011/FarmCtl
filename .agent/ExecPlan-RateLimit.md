# Shared rate-limit host coverage

Start from master e0c0aef937b6e71269bad029da5e00c3227ecbc3 in an isolated
local branch. Extend issue 51 with one bounded scenario: actual loopback HTTP 429
and Retry-After: 120, actual MicroPython header parser/Monitor/GistPublisher,
and actual Flutter clients/service/Drift persistence.

Deliver initially, reject a temperature PATCH at minute 15, suppress both streams
at +60s and +119999ms while sampling continues, resume at exactly +120s with a
new sample. Assert unchanged app value/observation age and delivered-only history
through the pause and after reopening SQLite. The header-omission mutation must
fail at the cooldown invariant, not at startup or an unrelated error.

Use failing-first tests, minimal adapter correction, existing fixture and owned
coordination helpers, repeated joined runs, aggregate regression/coverage/lint,
five independent review lanes and a finding validator. Preserve prior worktrees.
No commits, push, PR, production source edits, new dependencies, credentials,
devices, live Gists, authentication or network configuration changes.

Plaintext loopback sockets substitute native HTTPS. This proves rate-limit
header parsing and publisher/application behavior, not native TLS/DNS/deadlines,
Wi-Fi, Pico memory/peripherals, Android platform behavior or hardware qualification.

## Progress

- Read issue 51 and existing harness/plans. Verified current master read-only.
- Created isolated feat/host-rate-limit worktree; existing user work preserved.
- Fixture red: both streams returned 200 instead of 429; corrected fixed 120s
  wire hint rejects without mutating revisions. Both fixture cases then passed.
- An initial scenario incorrectly expected staleness at age 6m59s. Corrected
  controlled timing to age 16m59s before counting failing-first evidence.
- Valid joined red: header omission produced [true,true] at the two paused polls,
  wire counts temperature 4 / diagnostics 2. Both app and firmware rejected it.
- Minimal correction uses native_https._parse_headers on actual response headers
  and forwards them in HttpFailure. Two complete joined runs, including address,
  clock and header-omission mutations, passed in 29.707s and 30.590s. Corrected
  pause counts remained temperature 2 / diagnostics 1; exact +120s recovery
  advanced them to 3 / 2. Reads/sequence reached 5; only observations 1 and 5
  appeared in app history and reopened SQLite.
- Final host suites: Windows 151 pass + 2 Linux-only skips; WSL Python 3.10 153
  pass. Both coordinated cases pass real forced-child-termination cleanup.
- Regressions: app 393 pass + 4 system skips outside driver; parsing 17; Pico
  host 439; signed release manifest 16; offline-spare mock checks 18. No device
  operations ran. Code generation, Dart formatting/analysis, Ruff and Python
  3.10 basic typing (including coordinator/seed tests) passed.
- Scoped in-process fixture/seed-checker coverage: 129 statements + 36 branches,
  all covered. Actual MicroPython and Flutter subprocesses are outside that
  denominator. Existing app/parser coverage floors are checked separately.
- Offline setup used existing caches. Local SDK-cache access and WSL execution
  required approved sandbox escalations; no dependency additions or auth/network
  configuration changes occurred. No commits or external repository writes.
