"""Dedicated native-request fixture profile; all values and tokens are synthetic."""

import select
import time
from enum import Enum
from typing import Final

from gist_service import GISTS, GistHandler, GistService

TIMES: Final = {
    "a" * 32: ("03:00:00", "03:15:00", "03:15:05", "03:15:17"),
    "b" * 32: ("03:00:00", "03:15:00", "03:15:05", "03:15:05", "03:15:17"),
}
PARTIAL_ACK: Final = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
STALL_GUARD_SECONDS: Final = 2.5


class Fault(Enum):
    NONE = 0
    EOF = 1
    STALL = 2


class InterruptedHandler(GistHandler):
    """Translate only the two synthetic auth forms into the existing validator."""

    def setup(self) -> None:
        self._fault = Fault.NONE
        super().setup()

    def do_PATCH(self) -> None:
        if self.headers.get("Authorization") in (
            "Bearer synthetic-host-token",
            "token synthetic-host-token",
        ):
            self.headers.replace_header("Authorization", "token synthetic-host-token")
            gist = self.path.removeprefix("/gists/")
            if self.path == "/gists/" + gist and gist in GISTS:
                index = min(self.fixture.patch_attempts[gist], len(TIMES[gist]) - 1)
                at = "2026-01-02T" + TIMES[gist][index] + "Z"
                if "X-Simulator-At" in self.headers:
                    self.headers.replace_header("X-Simulator-At", at)
                else:
                    self.headers["X-Simulator-At"] = at
                if gist == "a" * 32:
                    self._fault = {1: Fault.EOF, 2: Fault.STALL}.get(index, Fault.NONE)
                if self._fault is not Fault.NONE:
                    # The inherited 503 path validates but never appends a revision.
                    if "X-Simulator-Fault" in self.headers:
                        self.headers.replace_header("X-Simulator-Fault", "503")
                    else:
                        self.headers["X-Simulator-Fault"] = "503"
        super().do_PATCH()

    def respond(self, status: int, body: bytes, retry_after: int | None = None) -> None:
        if status != 503 or self._fault is Fault.NONE:
            super().respond(status, body, retry_after)
            return
        self.connection.sendall(PARTIAL_ACK)
        self.close_connection = True
        if self._fault is Fault.STALL:
            self.wait_for_disconnect()

    def wait_for_disconnect(self) -> None:
        """Release the single-threaded service on EOF, with a mutant safety guard."""
        deadline = time.monotonic() + STALL_GUARD_SECONDS
        while (remaining := deadline - time.monotonic()) > 0:
            readable, _, _ = select.select([self.connection], [], [], remaining)
            if not readable:
                return
            try:
                if not self.connection.recv(1):
                    return
            except ConnectionResetError:
                return


class InterruptedService(GistService):
    """Same loopback revision service with a case-specific request handler."""

    def __init__(self) -> None:
        super().__init__()
        self.RequestHandlerClass = InterruptedHandler
