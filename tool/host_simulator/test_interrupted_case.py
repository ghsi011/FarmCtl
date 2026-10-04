"""Deadline mutations must reach the real stalled request, never fail arbitrarily."""

import json

import pytest

from interrupted_case import require_interrupted_seed_failure
from processes import Result


def stalled_observation() -> bytes:
    return (
        json.dumps(
            {
                "phase": "stalled",
                "trusted": True,
                "sensor_reads": 4,
                "sequence": 4,
                "publication_ok": [False],
                "transport_attempts": {"a" * 32: 3, "b" * 32: 4},
                "wire_attempts": {"a" * 32: 3, "b" * 32: 4},
                "at_ms": 905625,
                "elapsed_ms": 2510,
            }
        ).encode()
        + b"\n"
    )


def test_accepts_only_the_reached_unbounded_native_request() -> None:
    # Given the deadline mutant reached the intended stall with correct counters.
    result = Result(1, stalled_observation() + b"Traceback\nAssertionError:\n", b"")
    # When the checker examines the real reached-phase invariant failure.
    require_interrupted_seed_failure(result)
    # Then only this bounded failing-first outcome is accepted as evidence.


@pytest.mark.parametrize(
    "result",
    [
        Result(127, b"", b"missing runtime"),
        Result(1, b"AssertionError:\n", b""),
        Result(1, b"{invalid\nAssertionError:\n", b""),
        Result(1, b'{"elapsed_ms": null}\nAssertionError:\n', b""),
        Result(1, stalled_observation(), b"ImportError"),
        Result(0, stalled_observation() + b"AssertionError:\n", b""),
        Result(
            1, stalled_observation() + b"FARMCTL_INTERRUPTED_OK\nAssertionError:\n", b""
        ),
        *[
            Result(
                1,
                stalled_observation().replace(before, after) + b"AssertionError:\n",
                b"",
            )
            for before, after in (
                (b'"phase": "stalled"', b'"phase": "dropped"'),
                (b'"trusted": true', b'"trusted": false'),
                (b'"sensor_reads": 4', b'"sensor_reads": 3'),
                (b'"sequence": 4', b'"sequence": 3'),
                (b'"publication_ok": [false]', b'"publication_ok": [true]'),
                (
                    b'"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": 3',
                    b'"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": 2',
                ),
                (
                    b'"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": 4',
                    b'"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": 3',
                ),
                (b'"at_ms": 905625', b'"at_ms": 905624'),
                (b'"elapsed_ms": 2510', b'"elapsed_ms": 650'),
                (b'"elapsed_ms": 2510', b'"elapsed_ms": "2510"'),
                (b'"elapsed_ms": 2510', b'"elapsed_ms": 5000'),
            )
        ],
    ],
)
def test_rejects_unrelated_failures_and_false_success(result: Result) -> None:
    # Given an unrelated error or a success-shaped/deadline-respecting outcome.
    # When checked, then it must not satisfy the intended mutation evidence.
    with pytest.raises(RuntimeError, match="stall assertion"):
        require_interrupted_seed_failure(result)
