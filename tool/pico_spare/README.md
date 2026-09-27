# Pico spare offline preflight

This standard-library-only command checks the format of an independently authorized,
operator-supplied spare-board inventory. It is **offline only**: it does not open the
port, inspect a board, derive an identity, or authorize a probe. The inventory must be
a regular file outside this repository and no larger than 4096 bytes. Do not put
inventory files, credentials, or other secrets in the repository.

Example inventory (the digest is synthetic and is not a real board identity):

```json
{
  "schema_version": 1,
  "purpose": "authorized_spare",
  "uid_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "board": "RPI_PICO2_W",
  "runtime": "v1.29.0",
  "authorization_reference": "ISSUE-43"
}
```

Run with an explicit literal Windows COM port (syntax is validated only; no connection
is made):

```text
python tool/pico_spare/harness.py preflight --inventory <external-json> --port <COMn>
```

`OFFLINE_PREFLIGHT_PASS` means only that the external inventory has the required
format and the explicit port string has accepted syntax. `BLOCKED` means validation
failed. Neither result qualifies a board or signals that a hardware action is safe.
This preflight does not pass or resolve issue #43. There is no probe command and no
device runner.

Before any later probe is considered, obtain owner approval, physically isolate the
device, and independently confirm a complete UID inventory against the authorized
spare identity. Be aware that official MicroPython v1.29 `mpremote connect ... exec`
enters raw REPL and can interrupt a running program and automatically soft-reset the
board. In particular, this harness makes **no COM4 interaction**. Keep production
auto-updates disabled during spare qualification.
