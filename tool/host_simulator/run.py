# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# Run: python tool/host_simulator/run.py --micropython /absolute/path/micropython
"""One owned local service joins real Unix firmware and real Flutter app logic."""

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from pathlib import Path
from tempfile import TemporaryDirectory

from fixture import fleet_bytes
from processes import OwnedProcess, Result, run


def linux_path(path: Path) -> str:
    resolved = path.resolve()
    if os.name == "nt":
        return "/mnt/" + resolved.drive[0].lower() + resolved.as_posix()[2:]
    return str(resolved)


def require_seed_failure(result: Result) -> None:
    observations = [
        json.loads(line) for line in result.stdout.splitlines() if line.startswith(b"{")
    ]
    failed_poll = {"phase": "poll", "at_ms": 0, "sample_ok": False, "sequence": 1}
    terminal = (result.stdout + result.stderr).strip().splitlines()[-1:]
    if (
        result.code != 1
        or observations[-1:] != [failed_poll]
        or terminal != [b"AssertionError:"]
        or b"FARMCTL_HOST_OK" in result.stdout
    ):
        raise RuntimeError("seed failed outside the expected publication assertion")


def main() -> None:
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--micropython", required=True)
    parser.add_argument("--wsl", help="Existing WSL distribution for the Unix lane")
    parser.add_argument(
        "--verify-regression",
        action="store_true",
        help="Prove a seeded Unix sockaddr regression is rejected",
    )
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    scripts = Path(__file__).resolve().parent
    prefix = ["wsl.exe", "--distribution", options.wsl, "--"] if options.wsl else []
    interpreter = "python3" if options.wsl else sys.executable
    flutter = shutil.which("flutter")
    if flutter is None:
        raise RuntimeError("Flutter SDK is required")
    flutter_command = [flutter]
    if os.name == "nt":
        flutter_command = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", flutter]
    identity = run(
        [
            "git",
            "-c",
            "safe.directory=" + str(root),
            "-C",
            str(root),
            "rev-parse",
            "HEAD",
        ],
        5,
    )
    identity.require_success()
    binary_hash = run(prefix + ["sha256sum", "--", options.micropython], 10)
    binary_hash.require_success()
    print(
        json.dumps(
            {
                "phase": "identity",
                "commit": identity.stdout.decode().strip(),
                "micropython_sha256": binary_hash.stdout.decode().split()[0],
            }
        ),
        flush=True,
    )
    with TemporaryDirectory(prefix="farmctl-host-") as temporary:
        fixture = Path(temporary) / "fleet.json"
        content = fleet_bytes()
        fixture.write_bytes(content)
        print(
            json.dumps(
                {
                    "phase": "fixture",
                    "bytes": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                }
            ),
            flush=True,
        )
        with OwnedProcess(
            prefix + [interpreter, linux_path(scripts / "serve.py")]
        ) as service:
            startup = json.loads(service.startup_line())
            port = startup["port"]
            if type(port) is not int or not 0 < port < 65536:
                raise RuntimeError("invalid loopback service startup")
            source = scripts / "firmware_flow.py"
            if options.verify_regression:
                seeded = Path(temporary) / "wrong-address.py"
                original_source = source.read_text(encoding="utf-8")
                needle = "connection.connect(address)"
                if original_source.count(needle) != 1:
                    raise RuntimeError("regression seed no longer matches the harness")
                seeded.write_text(
                    original_source.replace(
                        needle, 'connection.connect(("127.0.0.1", self.port))'
                    ),
                    encoding="utf-8",
                )
                rejected = run(
                    prefix
                    + [
                        options.micropython,
                        linux_path(seeded),
                        str(port),
                        linux_path(fixture),
                        linux_path(root),
                    ],
                    30,
                )
                try:
                    require_seed_failure(rejected)
                except RuntimeError:
                    print(rejected.stdout.decode(), end="", flush=True)
                    print(rejected.stderr.decode(), end="", file=sys.stderr, flush=True)
                    raise
                print(
                    json.dumps(
                        {
                            "phase": "seeded_regression",
                            "exit": rejected.code,
                            "rejected": True,
                        }
                    ),
                    flush=True,
                )
            firmware = run(
                prefix
                + [
                    options.micropython,
                    linux_path(scripts / "firmware_flow.py"),
                    str(port),
                    linux_path(fixture),
                    linux_path(root),
                ],
                30,
            )
            print(firmware.stdout.decode(), end="", flush=True)
            if firmware.stderr:
                print(firmware.stderr.decode(), end="", file=sys.stderr, flush=True)
            firmware.require_success(b"FARMCTL_HOST_OK")
            environment = dict(os.environ)
            for credential in ("GITHUB_TOKEN", "FARMCTL_GITHUB_TOKEN", "GH_TOKEN"):
                environment.pop(credential, None)
            environment["FARMCTL_SIMULATOR_PORT"] = str(port)
            argv = flutter_command + [
                "test",
                "--no-pub",
                "--reporter",
                "expanded",
                "test/system/host_simulator_test.dart",
            ]
            original = Path.cwd()
            try:
                os.chdir(root / "app")
                with OwnedProcess(argv, environment) as app:
                    app.stop_input()
                    app_result = app.finish(120)
                print(app_result.stdout.decode(), end="", flush=True)
                if app_result.stderr:
                    print(
                        app_result.stderr.decode(), end="", file=sys.stderr, flush=True
                    )
                app_result.require_success()
            finally:
                os.chdir(original)
                service.stop_input()
                service.finish(5).require_success(b"FARMCTL_SERVICE_STOPPED")
    print(
        json.dumps(
            {
                "phase": "complete",
                "elapsed_seconds": round(time.monotonic() - started, 3),
            }
        ),
        flush=True,
    )
    print("FARMCTL_SYSTEM_OK", flush=True)


if __name__ == "__main__":
    main()
