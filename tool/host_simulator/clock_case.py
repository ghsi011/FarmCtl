"""Own the additional clock case and reject only its intended mutation failure."""

import json
import os
import sys
from collections.abc import Callable
from pathlib import Path
from tempfile import TemporaryDirectory

from processes import OwnedProcess, Result, run

APP_TIMEOUT = 120


def show(result: Result) -> None:
    print(result.stdout.decode(), end="", flush=True)
    if result.stderr:
        print(result.stderr.decode(), end="", file=sys.stderr, flush=True)


def require_clock_seed_failure(result: Result) -> None:
    observations = [
        json.loads(line) for line in result.stdout.splitlines() if line.startswith(b"{")
    ]
    paused = observations[-1] if observations else {}
    expected = {"a" * 32: 3, "b" * 32: 3}
    if (
        result.code != 1
        or paused.get("phase") != "paused"
        or paused.get("trusted") is not False
        or paused.get("sensor_reads") != 3
        or paused.get("sequence") != 3
        or paused.get("publication_ok") != [True, True]
        or paused.get("transport_attempts") != expected
        or paused.get("wire_attempts") != expected
        or (result.stdout + result.stderr).strip().splitlines()[-1:]
        != [b"AssertionError:"]
        or b"FARMCTL_CLOCK_OK" in result.stdout
    ):
        raise RuntimeError("clock seed failed outside the expected pause assertion")


def clock_case(
    root: Path,
    prefix: list[str],
    interpreter: str,
    micropython: str,
    flutter: list[str],
    path: Callable[[Path], str],
    seeded: bool = False,
) -> None:
    scripts = root / "tool" / "host_simulator"
    with TemporaryDirectory(prefix="farmctl-clock-") as temporary:
        directory = Path(temporary)
        source = scripts / "clock_flow.py"
        if seeded:
            text = source.read_text(encoding="utf-8")
            needle = "time_is_trusted=lambda: clock.trusted"
            if text.count(needle) != 1:
                raise RuntimeError("clock seed no longer matches the harness")
            source = directory / "clock-seed.py"
            source.write_text(
                text.replace(needle, "time_is_trusted=lambda: True"), encoding="utf-8"
            )
            (directory / "initial.ack").write_bytes(b"initial\n")
        with OwnedProcess(
            prefix + [interpreter, path(scripts / "serve.py")]
        ) as service:
            port = json.loads(service.startup_line())["port"]
            if type(port) is not int or not 0 < port < 65536:
                raise RuntimeError("invalid clock service startup")
            command = prefix + [
                micropython,
                "-c",
                "import sys; sys.path.insert(0, "
                + repr(path(scripts))
                + "); exec(open("
                + repr(path(source))
                + ").read())",
                str(port),
                path(root),
                path(directory),
            ]
            try:
                if seeded:
                    result = run(command, 30)
                    try:
                        require_clock_seed_failure(result)
                    except RuntimeError:
                        show(result)
                        raise
                    print(
                        json.dumps(
                            {
                                "phase": "clock_seed",
                                "exit": result.code,
                                "rejected": True,
                            }
                        ),
                        flush=True,
                    )
                else:
                    environment = dict(os.environ)
                    for credential in (
                        "GITHUB_TOKEN",
                        "FARMCTL_GITHUB_TOKEN",
                        "GH_TOKEN",
                    ):
                        environment.pop(credential, None)
                    environment["FARMCTL_SIMULATOR_PORT"] = str(port)
                    environment["FARMCTL_CLOCK_DIRECTORY"] = str(directory)
                    original = Path.cwd()
                    try:
                        with OwnedProcess(command) as firmware:
                            firmware.stop_input()
                            os.chdir(root / "app")
                            with OwnedProcess(
                                flutter
                                + [
                                    "test",
                                    "--no-pub",
                                    "--reporter",
                                    "expanded",
                                    "test/system/clock_guard_test.dart",
                                ],
                                environment,
                            ) as app:
                                app.stop_input()
                                app_result = app.finish(APP_TIMEOUT)
                            show(app_result)
                            firmware_result = firmware.finish(10)
                            show(firmware_result)
                            app_result.require_success()
                            firmware_result.require_success(b"FARMCTL_CLOCK_OK")
                    finally:
                        os.chdir(original)
            finally:
                service.stop_input()
                service.finish(5).require_success(b"FARMCTL_SERVICE_STOPPED")
