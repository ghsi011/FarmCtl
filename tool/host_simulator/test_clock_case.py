"""The clock mutation must fail at its publication invariant, never arbitrarily."""

import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

import clock_case
from clock_case import require_clock_seed_failure
from processes import Result
from rate_case import RATE_SCENARIO


def seeded_observation() -> bytes:
    return (
        json.dumps(
            {
                "phase": "paused",
                "trusted": False,
                "sensor_reads": 3,
                "sequence": 3,
                "publication_ok": [True, True],
                "transport_attempts": {"a" * 32: 3, "b" * 32: 3},
                "wire_attempts": {"a" * 32: 3, "b" * 32: 3},
            }
        ).encode()
        + b"\n"
    )


def test_accepts_only_the_intended_clock_mutation_failure() -> None:
    require_clock_seed_failure(
        Result(1, seeded_observation() + b"Traceback\nAssertionError:\n", b"")
    )


@pytest.mark.parametrize(
    "result",
    [
        Result(127, b"", b"missing runtime"),
        Result(1, b"AssertionError:\n", b""),
        Result(1, seeded_observation(), b"ImportError"),
        Result(0, seeded_observation() + b"AssertionError:\n", b""),
        Result(1, seeded_observation() + b"FARMCTL_CLOCK_OK\nAssertionError:\n", b""),
        Result(
            1,
            seeded_observation().replace(b'"sensor_reads": 3', b'"sensor_reads": 1')
            + b"AssertionError:\n",
            b"",
        ),
        Result(
            1,
            seeded_observation().replace(b'"trusted": false', b'"trusted": true')
            + b"AssertionError:\n",
            b"",
        ),
        Result(
            1,
            seeded_observation().replace(
                b'"publication_ok": [true, true]', b'"publication_ok": [false, false]'
            )
            + b"AssertionError:\n",
            b"",
        ),
    ],
)
def test_rejects_unrelated_failure_or_false_success(result: Result) -> None:
    with pytest.raises(RuntimeError):
        require_clock_seed_failure(result)


@pytest.mark.parametrize("scenario", [clock_case.CLOCK_SCENARIO, RATE_SCENARIO])
def test_forced_app_termination_removes_parent_owned_cache(
    monkeypatch: pytest.MonkeyPatch,
    scenario: clock_case.Scenario,
) -> None:
    # Real subprocess deadline kills a child before its own teardown can run.
    with TemporaryDirectory(prefix="farmctl-clock-evidence-") as temporary:
        record = Path(temporary) / "created-directory.txt"
        script = (
            "import os,pathlib,time; "
            "directory=pathlib.Path(os.environ[" + repr(scenario.directory_env) + "]); "
            "cache=directory/'cache'; cache.mkdir(); "
            "(cache/'cache.sqlite').write_bytes(b'unfinished'); "
            "pathlib.Path(" + repr(str(record)) + ").write_text(str(directory)); "
            "time.sleep(60)"
        )
        monkeypatch.setattr(clock_case, "APP_TIMEOUT", 2)
        root = Path(__file__).resolve().parents[2]
        with pytest.raises(RuntimeError, match="phase deadline"):
            clock_case.coordinated_case(
                root,
                [],
                sys.executable,
                sys.executable,
                [sys.executable, "-c", script],
                lambda path: str(path.resolve()),
                scenario,
            )
        assert record.exists(), "child must create the cache before termination"
        assert not Path(record.read_text()).exists()
