import ctypes
import os
import re
import sys
import time
from pathlib import Path

import pytest

from processes import OwnedProcess, Result, run
from run import require_seed_failure


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
        status = Path(f"/proc/{descendant}/stat")

        def stopped() -> bool:
            try:
                return status.read_text().split()[2] == "Z"
            except FileNotFoundError:
                return True

        deadline = time.monotonic() + 2
        while not stopped() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert stopped()


@pytest.mark.skipif(os.name == "nt", reason="Linux /proc disappearance race")
@pytest.mark.parametrize(
    "failure", (FileNotFoundError, PermissionError), ids=("reaped", "permission-denied")
)
def test_proc_stat_disappearance_does_not_fail_or_hide_other_errors(
    monkeypatch: pytest.MonkeyPatch,
    failure: type[OSError],
) -> None:
    observed: list[Path] = []
    original_exists, original_read = Path.exists, Path.read_text

    def exists(path: Path) -> bool:
        return (
            True
            if re.fullmatch(r"/proc/\d+/stat", str(path))
            else original_exists(path)
        )

    def read(path: Path, *args, **kwargs) -> str:
        if re.fullmatch(r"/proc/\d+/stat", str(path)):
            observed.append(path)
            raise failure(str(path))
        return original_read(path, *args, **kwargs)

    monkeypatch.setattr(Path, "exists", exists)
    monkeypatch.setattr(Path, "read_text", read)
    if failure is FileNotFoundError:
        test_descendant_is_terminated_when_its_leader_exits_first()
    else:
        with pytest.raises(failure):
            test_descendant_is_terminated_when_its_leader_exits_first()
    assert observed, "the disappearing proc read must be exercised"
