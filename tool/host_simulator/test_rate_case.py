# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# Run: python -m pytest tool/host_simulator/test_rate_case.py
"""Reject startup errors and false successes as rate-limit mutation evidence."""

import json

import pytest

from processes import Result
from rate_case import require_rate_seed_failure


def seeded_observation() -> bytes:
    return (
        json.dumps(
            {
                "phase": "paused",
                "trusted": True,
                "sensor_reads": 4,
                "sequence": 4,
                "publication_ok": [True, True],
                "transport_attempts": {"a" * 32: 4, "b" * 32: 2},
                "wire_attempts": {"a" * 32: 4, "b" * 32: 2},
            }
        ).encode()
        + b"\n"
    )


def test_accepts_expected_early_publication_after_missing_retry_hint() -> None:
    # Given evidence of both streams publishing before the requested deadline.
    result = Result(1, seeded_observation() + b"Traceback\nAssertionError:\n", b"")
    # When the mutation checker examines its terminal outcome.
    require_rate_seed_failure(result)
    # Then it accepts this particular invariant failure (no exception).


@pytest.mark.parametrize(
    "result",
    [
        Result(127, b"", b"missing runtime"),
        Result(1, b"AssertionError:\n", b""),
        Result(1, seeded_observation(), b"ImportError"),
        Result(0, seeded_observation() + b"AssertionError:\n", b""),
        Result(1, seeded_observation() + b"FARMCTL_RATE_OK\nAssertionError:\n", b""),
        *[
            Result(
                1,
                seeded_observation().replace(before, after) + b"AssertionError:\n",
                b"",
            )
            for before, after in (
                (b'"phase": "paused"', b'"phase": "limited"'),
                (b'"trusted": true', b'"trusted": false'),
                (b'"sensor_reads": 4', b'"sensor_reads": 2'),
                (b'"sequence": 4', b'"sequence": 2'),
                (
                    b'"publication_ok": [true, true]',
                    b'"publication_ok": [false, false]',
                ),
                (
                    b'"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": 4',
                    b'"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": 2',
                ),
                (
                    b'"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": 2',
                    b'"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": 1',
                ),
            )
        ],
    ],
)
def test_rejects_unrelated_failures_and_false_successes(result: Result) -> None:
    # Given a startup, unrelated assertion, or success-shaped outcome.
    # When the checker considers it, then it must reject it as mutation evidence.
    with pytest.raises(RuntimeError, match="cooldown assertion"):
        require_rate_seed_failure(result)
