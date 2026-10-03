"""Bounded output and explicit ownership for host-only subprocesses."""

import os
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from threading import Event, Thread
from types import TracebackType
from typing import BinaryIO, Final

OUTPUT_LIMIT: Final = 65536


@dataclass(frozen=True, slots=True)
class Result:
    code: int
    stdout: bytes
    stderr: bytes

    def require_success(self, marker: bytes | None = None) -> None:
        if self.code != 0 or self.stderr:
            raise RuntimeError(
                f"phase failed: exit={self.code}, stderr_bytes={len(self.stderr)}"
            )
        if marker is not None:
            lines = self.stdout.splitlines()
            if not lines or lines[-1] != marker or lines.count(marker) != 1:
                raise RuntimeError(
                    "phase lacks an exact unique terminal success marker"
                )


class OwnedProcess:
    """Mutable captures belong to one child; EOF stops the fixture service."""

    def __init__(
        self, argv: list[str], environment: dict[str, str] | None = None
    ) -> None:
        if os.name == "nt":
            argv = [
                sys.executable,
                str(Path(__file__).with_name("windows_job.py")),
                *argv,
            ]
        self.process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            env=environment,
            start_new_session=os.name != "nt",
        )
        self.stdout = bytearray()
        self.stderr = bytearray()
        self.first_line = Event()
        self.overflow = Event()
        self.readers: list[Thread] = []
        for stream, capture in (
            (self.process.stdout, self.stdout),
            (self.process.stderr, self.stderr),
        ):
            assert stream is not None
            reader = Thread(target=self._drain, args=(stream, capture), daemon=True)
            reader.start()
            self.readers.append(reader)

    def _drain(self, stream: BinaryIO, capture: bytearray) -> None:
        with stream:
            while chunk := stream.read(1024):
                room = OUTPUT_LIMIT - len(capture)
                capture.extend(chunk[:room])
                if capture is self.stdout and b"\n" in capture:
                    self.first_line.set()
                if len(chunk) > room:
                    self.overflow.set()
                    self.kill_tree()
                    return

    def kill_tree(self) -> None:
        if os.name == "nt":
            if self.process.poll() is not None:
                return  # Windows wrapper exit closes its owning Job Object.
            self.process.kill()  # Wrapper closure kills its entire Job Object.
        else:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def startup_line(self) -> bytes:
        if not self.first_line.wait(timeout=30):
            raise RuntimeError(
                "service startup deadline exceeded: "
                + bytes(self.stderr[:2048]).decode(errors="replace")
            )
        return bytes(self.stdout).splitlines()[0]

    def stop_input(self) -> None:
        assert self.process.stdin is not None
        if not self.process.stdin.closed:
            self.process.stdin.close()

    def finish(self, timeout: float) -> Result:
        try:
            code = self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.kill_tree()
            self.process.wait(timeout=5)
            raise RuntimeError("phase deadline exceeded") from None
        for reader in self.readers:
            reader.join(timeout=2)
        if any(reader.is_alive() for reader in self.readers):
            self.kill_tree()
            for reader in self.readers:
                reader.join(timeout=2)
            if any(reader.is_alive() for reader in self.readers):
                raise RuntimeError("phase output cleanup deadline exceeded")
        if self.overflow.is_set():
            raise RuntimeError("phase output limit exceeded")
        return Result(code, bytes(self.stdout), bytes(self.stderr))

    def __enter__(self) -> "OwnedProcess":
        return self

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.stop_input()
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.kill_tree()
                self.process.wait(timeout=5)
        self.kill_tree()
        for reader in self.readers:
            reader.join(timeout=2)
        if any(reader.is_alive() for reader in self.readers):
            raise RuntimeError("owned process output did not close")


def run(argv: list[str], timeout: float) -> Result:
    with OwnedProcess(argv) as child:
        child.stop_input()
        return child.finish(timeout)
