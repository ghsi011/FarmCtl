# Pico spare inventory and identity harness

The default `preflight` command is offline: it validates an operator-supplied external
inventory and explicit literal Windows COM-port syntax. It does not open a port, inspect
a board, derive an identity, or authorize a probe. Inventory files must be regular files
outside this repository and no larger than 4096 bytes. Do not put inventory files,
credentials, or other secrets in the repository.

Version 1 inventories retain the original schema. Version 2 adds exact expected
`uname()` machine and release strings for identity comparison:

```json
{
  "schema_version": 2,
  "purpose": "authorized_spare",
  "uid_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "board": "RPI_PICO2_W",
  "runtime": "v1.29.0",
  "authorization_reference": "CHANGE-123",
  "expected_uname_machine": "synthetic-machine",
  "expected_uname_release": "synthetic-release"
}
```

All sample identity values are synthetic. The required exact v2 `uname()` machine and
release values are **unknown** here and must come from an independently verified owner
inventory; do not infer or guess them. The authorization reference is bounded metadata,
not evidence of authorization. In particular, issue #43 supplies no permission, and
neither it nor any reference string in this file grants permission.

Offline preflight (accepts v1 or v2):

```text
python tool/pico_spare/harness.py preflight --inventory <external-json> --port <COMn>
```

`OFFLINE_PREFLIGHT_PASS` means only that the inventory format and explicit port syntax
were accepted. `BLOCKED` means validation failed. Neither result qualifies a board or
signals that a hardware action is safe.

An optional, tightly scoped identity probe accepts **only v2** and requires explicit
interruption acknowledgement:

```text
python tool/pico_spare/harness.py probe --inventory <external-json> --port <COMn> --ack-interruption
```

`--ack-interruption` acknowledges the risk; it is not owner approval or permission. The
probe executes one fixed `mpremote connect port:<COMn> resume exec ...` command and
follows output from only the fixed query, with a 10-second host timeout; it does not
retry, scan ports, or perform follow-on operations. `resume` suppresses the automatic
soft reset, but entering raw REPL sends Ctrl-C and can interrupt running
board code. It may therefore disrupt a device. The command reads the UID and `uname()`
identity only, compares the full SHA-256 UID digest and both exact expected strings, and
prints only `IDENTITY_MATCH` on a match; failures print only `BLOCKED`. A match is not
physical-spare authentication, owner approval, permission, or an issue #43 pass.

## Source-only spare session module

`firmware/pico/spare_session.py` adds an import-inert, credential-free callable
`run_spare_session`; it is source for a future explicitly invoked session, not a command
or currently runnable telemetry path. Each invocation checks the full UID SHA-256
digest and exact `uname()` identity supplied by its identity reader before calling
the supplied monitor factory. The optional board identity reader imports hardware
modules lazily. If admitted, the session calls the existing `Monitor.step(10, 60)`
under a 70-second, 72-iteration cooperative bound. It attempts cleanup after
construction on every exit and returns a constant status. Importing the module
does not access a device.

This callable is distinct from the offline `preflight` above and the optional
identity-only probe: it is not yet an authorized or validated live runner. It does not
accept credentials, scan ports, or establish permission. An identity match is neither
attestation nor authorization. No live telemetry, TLS/Gist behavior, or five-minute
healthy-interruption result is established; automatic flags remain disabled, production
`main.py` is absent, and #43 remains OPEN. Any operational use needs separate approval,
an independently verified exact inventory, confirmed wiring and recovery/stop controls,
and test-account-owned disposable Gists with that account's locally supplied test token.
The previously created host-owned synthetic Gists are not writable with a test-account
token. Never place credentials in source or this repository.

Run the deterministic host-only checks from `firmware/pico` with:

```text
python -m unittest discover -s tests -p test_spare_session.py -v
python -m unittest discover -s tests -p test_telemetry.py -v
```

The rehearsal invokes the real `run_spare_session` and `Monitor` with synthetic identity,
sensor, clock, and in-memory transport adapters. It opens no serial port and makes no
network connection. The `test_telemetry.py` fake-clock regressions exercise the real
`Monitor.step` heartbeat boundary: baseline at 0 ms, no heartbeat at 299,999 ms, and
one at 300,000 ms while sampling and temperature publication are not due (including
a steady sensor-failure case). That synthetic 300-second scheduler PASS is separate from
the coordinator's 70-second session limit, which cannot establish a five-minute
heartbeat. Physical hardware qualification is **NOT RUN**; no TLS/Gist or physical-board
behavior is established.

The command behavior described here was reviewed against host `mpremote` v1.29.0; other
host CLI versions are not qualified. An operator must confirm the host CLI version
before any separately authorized live use. `mpremote` is not installed in this
development environment. No live command may be run during development. In particular,
COM4 cannot prove that a connected board is the spare. All tests mock the subprocess
boundary; no device, serial connection, or production `main.py` operation is needed.
Keep production `main.py` and auto flags untouched, with automatic updates disabled
during any separately authorized spare qualification.
