# Host simulator integration

## Destination and scope

Implement the smallest deterministic host-only slice of [Add MicroPython Unix and Flutter system-integration CI](https://github.com/ghsi011/FarmCtl/issues/51), starting from master `7ac89d7b6a749357096f39232b1694239241ffa8`. Use official MicroPython v1.29.0 Unix, synthetic samples, one loopback Gist-compatible service, and real Flutter client/service/storage assertions. Preserve existing checkouts and production behavior. Publication is approved only after local checks and independent review pass; the deliverable is a draft PR, with merge left to the parent.

## Wayfinding gap assessment

- The existing map, issue 51, and private simulation research agree on Unix first and separate hardware qualification. No new architectural decision blocks this tracer bullet.
- Monitor already accepts sensor, publisher, and clock dependencies. GistPublisher has inspectable transport state; the host harness can replace that boundary without editing shipped firmware.
- App clients accept Dio but use absolute GitHub URLs. A test-only adapter must reject all unsupported destinations and route allowed requests to a loopback socket. Changing baseUrl alone cannot work.
- Existing CPython and Flutter suites do not join firmware publication to app parsing and persistence. The initial lane will do this without an Android emulator or production API.
- WSL Ubuntu 22.04 and Flutter 3.41.7/Dart 3.11.5 are installed. WSL has make/Python/binutils but no compiler or development headers. Download and extract official Ubuntu build packages locally; do not install system packages or change authentication/network settings.
- Issue 50 was unresolved at initial inspection; it is now closed by verified staged offline delivery. See the dated correction below. Exercise the host byte envelope independently; do not read devices or retry the blocked Pico transport operation.

## Pre-agreed public test seams

The requested parser-to-Monitor-to-publisher and real app consumption flow defines the seams: parse_fleet input/result; Monitor.poll publication semantics; GistPublisher file payloads and delivery results; HTTP Gist snapshot/revision contracts; ThermostatHttpClient and DeviceDiagnosticsHttpClient results; ThermostatService and repository persistence.

## Iterations

1. Pin/build/probe Unix runtime and document exact build/frozen modules. Create a small failing host flow, then implement the loopback fixture and portable firmware harness.
2. Join real app clients and storage to the same service. Cover unchanged fresh temperature, failed sampling, independent diagnostics, and history with controlled time. Add strict subprocess outcome checks and one seeded regression.
3. Run source generation, format/analyze, existing suites and scoped coverage. Repeat clean runs. Obtain correctness and security reviews plus a finding validator. Repair and recheck before commit/push/draft PR; verify exact-head CI.

## Evidence and limits

Record commands, base/build/fixture identity, phase results, measured coverage denominator, and substituted boundaries. Loopback HTTP proves host socket/application behavior. It does not prove native verified TLS, DNS deadlines, RP2350 heap/stack, CYW43/Wi-Fi, peripherals, watchdog/power loss, Android platform behavior, or live GitHub semantics. TLS/fault expansion and Android integration_test remain later slices; issues 43, 45 and the unimplemented issue-51 criteria stay open.

## Progress

- 2026-10-03 correction: [issue 50's staged offline run](https://github.com/ghsi011/FarmCtl/issues/50#issuecomment-5970793168) completed 125 commands through one persistent connection, all six complete-fixture assertions, exit 0/no host stderr, `COMBINED_RESULT:PASS`, and `OWNED_CLEANUP_PASS` with five files removed and the directory absent. The original 110,586-byte source command failed before top-level execution with MemoryError; the precise allocator/size cause was not established. This resolves the delivery investigation, without establishing a parser defect or advancing `native.UNQUALIFIED` / issues 43 and 45 / sensor, Wi-Fi, TLS, watchdog, durability or timing gates. No device access occurs in this host extension.

- 2026-10-03: read-only source/research/guidance inspection completed; isolated bare clone and worktree created; runtime/build prerequisite assessment completed.
- Built official MicroPython Unix 1.29.0 standard with FFI disabled using workspace-only Ubuntu compiler/header packages. No system package installation or configuration changes. Binary SHA-256: `e476be4f6d857d71254849a35ee2bcb253e2018233950cb961389b659369d3d2`; default frozen modules contain no FarmCtl code.
- Joined parser, Monitor, telemetry, GistPublisher and actual Flutter client/service/SQLite assertions through the shared loopback fixture. Two clean joined runs and independent QA passed; the seeded Unix address regression fails at the expected first publication assertion. No production source changes.
- Existing regression suites passed: Flutter 393 (two system tests skipped without the driver), parsing 17, Pico host 439, release-manifest 16, offline-spare mock tests 18. Handwritten app coverage is 4,961/6,122 lines (81.04%); parser 4/4 (100%). Selected Pico modules have 1,250 statements and 508 branches, 86% combined coverage.
- New fixture/process tests pass 27 scenarios. In-process fixture/process coverage measured 91% combined (207 statements, 68 branches); child entrypoints, Windows Job wrapper and real MicroPython execution are exercised as subprocesses and excluded from that CPython coverage denominator. These figures are scoped, not whole-tool coverage.
- Source generation, Dart format/analyze, Ruff and Python 3.10 basic type checks passed. Independent goal/context review passed. Quality/security review found an exited-leader ownership bug; fixed with Windows kill-on-close Job Objects and POSIX process groups, including a real descendant regression. Final validation and exact committed-head CI evidence accompany the handoff.
