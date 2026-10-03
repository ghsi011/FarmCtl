import ctypes
import errno
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable
from contextlib import nullcontext
from pathlib import Path

import pytest

from processes import OwnedProcess, Result, run
from run import require_seed_failure


def _proc_is_terminated(read_stat: Callable[[], str]) -> bool:
    """Observe an initially visible owned task; preserve unrelated read failures."""
    try:
        contents = read_stat()
    except (FileNotFoundError, ProcessLookupError):
        return True
    command, separator, fields = contents.rpartition(")")
    assert separator and re.fullmatch(r"\d+ \(.*", command, re.DOTALL)
    status = re.fullmatch(r" ([RSDTtXZPI]) \d+(?: .*)?\n?", fields, re.DOTALL)
    assert status is not None, "invalid process stat"
    return status[1] in ("Z", "X")


def _assert_proc_terminated(read_stat: Callable[[], str]) -> None:
    """Allow a final deadline observation and retain the first terminal result."""
    deadline = time.monotonic() + 2
    while True:
        if _proc_is_terminated(read_stat):
            return
        assert time.monotonic() < deadline, "descendant remains alive"
        time.sleep(0.01)


@pytest.mark.parametrize(
    "result",
    [
        Result(1, b"FARMCTL_HOST_OK\n", b""),
        Result(0, b"FARMCTL_HOST_OK\n", b"failure"),
        Result(0, b"earlier FARMCTL_HOST_OK\n", b""),
        Result(0, b"FARMCTL_HOST_OK\nlater failure\n", b""),
        Result(0, b"FARMCTL_HOST_OK\nFARMCTL_HOST_OK\n", b""),
        Result(0, b"", b""),
    ],
)
def test_rejects_false_success_when_terminal_outcome_is_invalid(result: Result) -> None:
    # Given/When/Then: earlier success must never hide the terminal failure.
    with pytest.raises(RuntimeError):
        result.require_success(b"FARMCTL_HOST_OK")


def test_accepts_success_when_marker_is_unique_and_terminal() -> None:
    Result(0, b'{"phase":"parser"}\nFARMCTL_HOST_OK\n', b"").require_success(
        b"FARMCTL_HOST_OK"
    )


def test_seed_requires_expected_poll_and_terminal_assertion() -> None:
    poll = b'{"phase":"poll","at_ms":0,"sample_ok":false,"sequence":1}\n'
    require_seed_failure(Result(1, poll + b"Traceback\nAssertionError: \n", b""))
    for invalid in (
        Result(127, b"", b"missing interpreter"),
        Result(1, poll, b"ImportError"),
        Result(1, b"AssertionError:\n", b""),
    ):
        with pytest.raises(RuntimeError):
            require_seed_failure(invalid)


def test_caps_output_when_child_floods_stdout() -> None:
    with pytest.raises(RuntimeError, match="output limit"):
        run([sys.executable, "-c", "print('x' * 100000)"], 5)


def test_kills_owned_child_when_phase_deadline_expires() -> None:
    with OwnedProcess([sys.executable, "-c", "import sys; sys.stdin.read()"]) as child:
        with pytest.raises(RuntimeError, match="phase deadline"):
            child.finish(0.05)
        assert child.process.poll() is not None


def test_reads_startup_and_stops_owned_service_when_stdin_closes() -> None:
    command = (
        "import sys; print('ready', flush=True); sys.stdin.read(); print('stopped')"
    )
    with OwnedProcess([sys.executable, "-c", command]) as child:
        assert child.startup_line() == b"ready"
        child.stop_input()
        child.finish(5).require_success(b"stopped")


def test_descendant_is_terminated_when_its_leader_exits_first() -> None:
    command = (
        "import subprocess,sys; "
        "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
        "print(child.pid, flush=True)"
    )
    with OwnedProcess([sys.executable, "-c", command]) as leader:
        descendant = int(leader.startup_line())
        if os.name != "nt":
            assert not _proc_is_terminated(Path(f"/proc/{descendant}/stat").read_text)
        leader.finish(10).require_success()
    if os.name == "nt":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        handle = kernel.OpenProcess(0x100000, False, descendant)
        if handle:
            kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            try:
                assert kernel.WaitForSingleObject(handle, 2000) == 0
            finally:
                kernel.CloseHandle(handle)
    else:
        # A terminated orphan may remain a zombie until its host init reaps it.
        _assert_proc_terminated(Path(f"/proc/{descendant}/stat").read_text)


@pytest.fixture
def proc_clock(monkeypatch: pytest.MonkeyPatch) -> Callable[[], float]:
    elapsed = 0.0

    def monotonic() -> float:
        return elapsed

    def sleep(_delay: float) -> None:
        nonlocal elapsed
        elapsed += 1

    monkeypatch.setattr(time, "monotonic", monotonic)
    monkeypatch.setattr(time, "sleep", sleep)
    return monotonic


@pytest.mark.parametrize(
    "state, terminated",
    [(state, False) for state in "RSDTtPI"] + [("X", True), ("Z", True)],
)
@pytest.mark.parametrize(
    "comm",
    (
        "python",
        "worker name",
        "worker ) name",
        "worker ( ) name",
        "worker Z name",
        "worker\nname",
    ),
)
def test_proc_observer_classifies_state_after_complete_command_name(
    state: str, terminated: bool, comm: str
) -> None:
    assert _proc_is_terminated(lambda: f"123 ({comm}) {state} 1 0\n") is terminated


@pytest.mark.parametrize("observation", (0, 1, 2), ids=("first", "poll", "deadline"))
@pytest.mark.parametrize(
    "error, disappeared",
    (
        (errno.ENOENT, True),
        (errno.ESRCH, True),
        (errno.EPERM, False),
        (errno.EACCES, False),
        (errno.EIO, False),
        (errno.ENOTDIR, False),
        (errno.EBADF, False),
        (errno.EINTR, False),
        (errno.EAGAIN, False),
    ),
)
def test_proc_observer_accepts_only_disappearance_errors_at_every_observation(
    proc_clock: Callable[[], float], observation: int, error: int, disappeared: bool
) -> None:
    fault = OSError(error, "proc read failed")
    calls = 0

    def read() -> str:
        nonlocal calls
        calls += 1
        if calls == observation + 1:
            raise fault
        return "123 (python) S 1 0\n"

    if disappeared:
        _assert_proc_terminated(read)
    else:
        with pytest.raises(OSError) as raised:
            _assert_proc_terminated(read)
        assert raised.value is fault
    assert calls == observation + 1
    assert proc_clock() == observation


@pytest.mark.parametrize("state", ("Z", "X"))
def test_proc_observer_accepts_termination_at_deadline_without_reading_again(
    proc_clock: Callable[[], float], state: str
) -> None:
    calls = 0

    def read() -> str:
        nonlocal calls
        calls += 1
        return f"123 (python) {state if calls == 3 else 'S'} 1 0\n"

    _assert_proc_terminated(read)
    assert calls == 3
    assert proc_clock() == 2


def test_proc_observer_rejects_a_live_descendant_at_deadline(
    proc_clock: Callable[[], float],
) -> None:
    with pytest.raises(AssertionError):
        _assert_proc_terminated(lambda: "123 (python) S 1 0\n")
    assert proc_clock() == 2


@pytest.mark.parametrize(
    "contents",
    (
        "",
        "123",
        "123 (python)",
        "123 (python) Z",
        "bad (python) Z 1",
        "123 python Z 1",
        "123 (python) Q 1",
        "123 (python) ZZ 1",
        "123 (w ) Z 1 x) Q 1 0\n",
        "123 (w ) Z 1 x) ZZ 1 0\n",
        "123 (w ) Z 1 x)  1 0\n",
        "123 (w ) Z 1 x)Q 1 0\n",
    ),
)
def test_proc_observer_rejects_empty_or_malformed_status(contents: str) -> None:
    with pytest.raises(AssertionError):
        _proc_is_terminated(lambda: contents)


def test_proc_observer_preserves_decode_failures() -> None:
    fault = UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid")

    def read() -> str:
        raise fault

    with pytest.raises(UnicodeDecodeError) as raised:
        _proc_is_terminated(read)
    assert raised.value is fault


@pytest.mark.skipif(os.name == "nt", reason="Linux /proc lifecycle")
@pytest.mark.parametrize(
    "open_before_exit", (False, True), ids=("before-open", "after-open")
)
def test_proc_observer_handles_reaped_owned_child_with_real_kernel(
    open_before_exit: bool,
) -> None:
    with subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"]
    ) as child:
        try:
            status = Path(f"/proc/{child.pid}/stat")
            assert not _proc_is_terminated(status.read_text)
            opened = (
                status.open(encoding="utf-8") if open_before_exit else nullcontext(None)
            )
            with opened as stream:
                child.terminate()
                child.wait(timeout=3)
                reader = stream.read if stream is not None else status.read_text
                observed: list[int | None] = []

                def read() -> str:
                    try:
                        return reader()
                    except OSError as failure:
                        observed.append(failure.errno)
                        raise

                _assert_proc_terminated(read)
                assert observed == [errno.ESRCH if open_before_exit else errno.ENOENT]
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=3)
