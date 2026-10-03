# Host simulator

This initial slice of [issue 51](https://github.com/ghsi011/FarmCtl/issues/51)
joins actual MicroPython Unix firmware logic to actual Flutter clients, services,
and file-backed Drift storage through an owned loopback HTTP fixture. Shipped
firmware and app code are unchanged.

## Run

Prerequisites: Linux (or an existing WSL distribution), Python 3.10+, GCC, make,
curl, xz/tar, and Flutter 3.41.7 / Dart 3.11.5. The runtime builder downloads the
official MicroPython 1.29.0 source archive and verifies its SHA-256 before build.
It installs no system packages. Use a Linux filesystem for the build directory.

```bash
bash tool/host_simulator/build_micropython.sh /tmp/farmctl-micropython
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs
cd ..
python3 tool/host_simulator/run.py \
  --micropython /tmp/farmctl-micropython/micropython-1.29.0/ports/unix/build-standard/micropython \
  --verify-regression
```

On Windows, build in WSL, keep the resulting binary in a persistent location,
prepare the app with Windows Flutter, and pass its Linux path:

```powershell
python tool/host_simulator/run.py --wsl Ubuntu-22.04 `
  --micropython /mnt/c/path/to/micropython --verify-regression
```

The driver owns the service, temporary fixture, and subprocesses. Each run uses
a new ephemeral port and in-memory revision log; stdin EOF stops the service.
Output is bounded to 64 KiB per stream. Firmware, app, and cleanup have explicit
deadlines. Windows tools run inside a kill-on-close Job Object; Linux tools use
owned process groups, including when their leader exits first. Success requires
zero exit status, empty stderr, and unique terminal
firmware/cleanup markers; the driver prints `FARMCTL_SYSTEM_OK` last. The seeded
Unix address regression must fail at its first publication assertion. The clock
mutation must reach the paused phase, keep sampling, attempt both streams, and
fail there with no clock success marker. Startup failures do not satisfy either seed.

Normal `flutter test` skips the three system tests when no shared fixture is supplied.
Use the driver to execute them. No real credentials are needed. Only the two
synthetic Gist IDs are accepted; the app adapter restricts requests to their
allowlisted GitHub paths and rewrites them to loopback without redirects/proxies.

Fixture/process unit checks use pytest (validated with 9.1.1):

```bash
python3 -m pytest -q -p no:cacheprovider tool/host_simulator
python3 -m ruff check tool/host_simulator
python3 -m ruff format --check tool/host_simulator
basedpyright -p tool/host_simulator/pyrightconfig.json
```

## Assertions

- Actual fleet parser accepts the same semantically full 65,536-byte fixture in
  37-byte and 1,024-byte chunks, rejects 65,537 bytes, malformed/truncated JSON,
  and duplicate keys, and reports bounded progress.
- Actual Monitor, telemetry, and GistPublisher publish two fresh equal readings
  and a changed reading. Two failed conversions create no fresh temperature.
- A diagnostics PATCH fault is independent of successful temperature delivery;
  a later heartbeat recovers and exposes the last successful sample reference.
- Actual app clients consume snapshot, commit, and revision endpoints; the real
  service preserves observation age, stale status, cached value on HTTP failure,
  and revision identity through SQLite reopen.
- Negative subprocess tests reject early, duplicated, missing, or trailing
  success markers, nonzero exit, stderr, output overflow, and deadline failure.
- A separate continuous Monitor/GistPublisher run publishes a known sample,
  loses clock trust while sampling twice, and attempts zero temperature or
  diagnostics PATCHes during the pause. Counters at the transport boundary and
  loopback service must agree. The app consumes the original observation during
  the pause: cached value/time survive, controlled app time makes it stale, and
  history contains only delivered observations. Trust restoration after backoff
  publishes a newly sampled value and independent diagnostics; app history and
  SQLite reopen retain only the initial and recovered observations.

The clock case uses a private temporary directory for bounded phase snapshots
and acknowledgements. Firmware waits for app assertions at initial and paused
checkpoints before advancing. Both markers are closed then atomically renamed
before readers see them. SQLite cache files live under the parent-owned directory
so forced child termination still allows parent cleanup. A ready file means evidence is available; success
still requires both test processes and service cleanup to pass. The deliberate
mutation supplies an always-trusted callback while the test clock is untrusted;
production code is never modified, including for the seed. Existing CI runs both
cases and both mutations with `--verify-regression`.

## Build identity and limits

Source archive SHA-256:
`d925a7c664e79a2bdf3dfcb285ba5e2237041cc35a0bd4ee573b6c5711efeca0`.
Build: Unix **standard** variant, `MICROPY_PY_FFI=0`, default frozen manifest;
the builder reports the interpreter version and binary SHA-256. Default frozen
modules are argparse, requests, mip, ssl, asyncio, and uasyncio. FarmCtl modules
are loaded from source. The fixture hash is
`207dfc10f8ac65c56f38999358b08d2300315a56abb05242105ed3e5eb1ac997`.

Sensor, clock, and native HTTPS transport are test substitutions. The transport
uses actual Unix socket addresses from getaddrinfo; this compatibility code
lives entirely in the harness. This lane makes no claim about verified TLS,
DNS timing, Wi-Fi/CYW43, Pico memory/stack, peripherals, watchdogs, power loss,
Android UI/platform behavior, or live GitHub semantics. Host GC figures are
diagnostic host figures only. Native readback reconciliation is not exercised.

Android integration_test, the broader fault/TLS matrix, and hardware qualification
remain separate work. Issue 51 stays open, as do hardware qualification issues
43 and 45. [Issue 50 was resolved by staged offline delivery](https://github.com/ghsi011/FarmCtl/issues/50#issuecomment-5970793168):
the original 110,586-byte command hit MemoryError before top-level execution;
the precise allocator/size cause was not established. One persistent connection
then completed 125 staged commands and all six assertions over the complete
65,536-byte fixture, with exit 0, no host stderr, `COMBINED_RESULT:PASS`, and
`OWNED_CLEANUP_PASS` (all five owned files removed and directory absent).
This is offline delivery evidence, not a product parser defect or a native
qualification pass. `native.UNQUALIFIED`, sensor/Wi-Fi/TLS/watchdog/durability/
timing qualification, and the separate hardware gates remain unchanged.
