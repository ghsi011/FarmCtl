# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# Run through tool/host_simulator/run.py.
"""A missing Retry-After must fail specifically at the shared cooldown checkpoint."""

import json
from typing import Final

from clock_case import Scenario
from processes import Result


def require_rate_seed_failure(result: Result) -> None:
    observations = [
        json.loads(line) for line in result.stdout.splitlines() if line.startswith(b"{")
    ]
    paused = observations[-1] if observations else {}
    expected = {"a" * 32: 4, "b" * 32: 2}
    if (
        result.code != 1
        or paused.get("phase") != "paused"
        or paused.get("trusted") is not True
        or paused.get("sensor_reads") != 4
        or paused.get("sequence") != 4
        or paused.get("publication_ok") != [True, True]
        or paused.get("transport_attempts") != expected
        or paused.get("wire_attempts") != expected
        or (result.stdout + result.stderr).strip().splitlines()[-1:]
        != [b"AssertionError:"]
        or b"FARMCTL_RATE_OK" in result.stdout
    ):
        raise RuntimeError("rate seed failed outside the expected cooldown assertion")


RATE_SCENARIO: Final = Scenario(
    "rate",
    "rate_limit_test.dart",
    "FARMCTL_RATE_DIRECTORY",
    b"FARMCTL_RATE_OK",
    "return headers",
    "return {}",
    ("initial", "limited"),
    require_rate_seed_failure,
)
