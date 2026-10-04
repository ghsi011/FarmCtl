# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# Run through tool/host_simulator/run.py.
"""Bind the native deadline mutation to its reached stall assertion."""

import json
from typing import Final

from clock_case import Scenario
from processes import Result


def require_interrupted_seed_failure(result: Result) -> None:
    message = "deadline seed failed outside the expected stall assertion"
    try:
        observations = [
            json.loads(line)
            for line in result.stdout.splitlines()
            if line.startswith(b"{")
        ]
    except ValueError as error:
        raise RuntimeError(message) from error
    stalled = observations[-1] if observations else {}
    expected = {"a" * 32: 3, "b" * 32: 4}
    elapsed = stalled.get("elapsed_ms") if isinstance(stalled, dict) else None
    if (
        type(elapsed) is not int
        or not 2000 <= elapsed < 5000
        or result.code != 1
        or stalled.get("phase") != "stalled"
        or stalled.get("trusted") is not True
        or stalled.get("sensor_reads") != 4
        or stalled.get("sequence") != 4
        or stalled.get("publication_ok") != [False]
        or stalled.get("transport_attempts") != expected
        or stalled.get("wire_attempts") != expected
        or stalled.get("at_ms") != 905625
        or (result.stdout + result.stderr).strip().splitlines()[-1:]
        != [b"AssertionError:"]
        or b"FARMCTL_INTERRUPTED_OK" in result.stdout
    ):
        raise RuntimeError(message)


INTERRUPTED_SCENARIO: Final = Scenario(
    "interrupted",
    "interrupted_transport_test.dart",
    "FARMCTL_INTERRUPTED_DIRECTORY",
    b"FARMCTL_INTERRUPTED_OK",
    "# DEADLINE_MUTATION",
    "from native_https import NativeHttpsTransport; "
    "NativeHttpsTransport._remaining = lambda self, start: self.timeout_ms",
    ("initial", "dropped", "first_backoff"),
    require_interrupted_seed_failure,
    ("interrupted",),
)
