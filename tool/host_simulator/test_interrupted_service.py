"""Wire behavior for the native request shape and pre-application fault profile."""

import json
import socket
import struct
import sys
import time
from collections.abc import Iterator
from contextlib import closing
from http.client import HTTPConnection
from pathlib import Path
from threading import Thread

import pytest

from gist_service import GistService
from interrupted_service import InterruptedService
from processes import run

PATH = "/gists/" + "a" * 32
NATIVE_HEADERS = {"Authorization": "Bearer synthetic-host-token"}


@pytest.fixture
def native_fixture() -> Iterator[tuple[GistService, HTTPConnection]]:
    with InterruptedService() as server:
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with closing(
                HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            ) as client:
                yield server, client
        finally:
            server.shutdown()
            worker.join(timeout=3)
            assert not worker.is_alive()


def publish(client: HTTPConnection, content: str) -> bytes:
    body = json.dumps({"files": {"thermostat.txt": {"content": content}}})
    client.request("PATCH", PATH, body, NATIVE_HEADERS)
    response = client.getresponse()
    assert response.status == 200
    return response.read()


def test_native_fixed_request_publishes_without_test_headers(
    native_fixture: tuple[GistService, HTTPConnection],
) -> None:
    # Given a real native request shape, with no configurable production headers.
    server, client = native_fixture
    # When the synthetic native token authenticates a valid fixed PATCH.
    snapshot = json.loads(publish(client, "initial"))
    # Then the fixture records a controlled observation for the actual app.
    assert snapshot["updated_at"] == "2026-01-02T03:00:00Z"
    assert server.patch_attempts == {"a" * 32: 1, "b" * 32: 0}
    assert [revision.content for revision in server.revisions["a" * 32]] == ["initial"]


def raw_patch(server: GistService, extra_headers: bytes = b"") -> socket.socket:
    body = json.dumps(
        {"files": {"thermostat.txt": {"content": "undelivered"}}}
    ).encode()
    connection = socket.create_connection(("127.0.0.1", server.server_port), timeout=2)
    connection.sendall(
        (
            "PATCH " + PATH + " HTTP/1.1\r\nHost: api.github.com\r\n"
            "Authorization: Bearer synthetic-host-token\r\nContent-Length: "
            + str(len(body))
            + "\r\nConnection: close\r\n"
        ).encode()
        + extra_headers
        + b"\r\n"
        + body
    )
    return connection


def test_dropped_header_ends_before_acknowledgement_without_revision(
    native_fixture: tuple[GistService, HTTPConnection],
) -> None:
    # Given one previously delivered observation.
    server, client = native_fixture
    publish(client, "initial")
    # When a full valid native request meets the next dropped-header fault.
    with closing(raw_patch(server)) as connection:
        response = bytearray()
        while piece := connection.recv(1024):
            response.extend(piece)
    # Then the apparent 200 lacks its header terminator and was never applied.
    assert response == b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
    assert len(server.revisions["a" * 32]) == 1
    assert server.patch_attempts["a" * 32] == 2


def test_stall_releases_on_client_disconnect_and_recovery_can_publish(
    native_fixture: tuple[GistService, HTTPConnection],
) -> None:
    # Given an initial success and a consumed dropped-header attempt.
    server, client = native_fixture
    publish(client, "initial")
    with closing(raw_patch(server)) as connection:
        while connection.recv(1024):
            pass
    # When the stalled response is held open until its client disconnects.
    started = time.monotonic()
    with closing(raw_patch(server)) as connection:
        prefix = bytearray()
        while len(prefix) < 36:
            piece = connection.recv(36 - len(prefix))
            assert piece
            prefix.extend(piece)
        assert prefix == b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
        connection.settimeout(0.1)
        with pytest.raises(TimeoutError):
            connection.recv(1)
    # Then closure releases the single-threaded service before its guard bound.
    publish(client, "recovered")
    assert time.monotonic() - started < 1.5
    assert [revision.content for revision in server.revisions["a" * 32]] == [
        "initial",
        "recovered",
    ]
    assert server.patch_attempts["a" * 32] == 4


@pytest.mark.parametrize(
    "path,headers,body,status",
    [
        (PATH, {"Authorization": "Bearer invalid-token"}, "", 401),
        ("/gists/" + "c" * 32, NATIVE_HEADERS, "", 404),
        (PATH, NATIVE_HEADERS, "{}", 400),
        (PATH, NATIVE_HEADERS, "{invalid", 400),
    ],
)
def test_profile_keeps_auth_path_and_payload_validation(
    native_fixture: tuple[GistService, HTTPConnection],
    path: str,
    headers: dict[str, str],
    body: str,
    status: int,
) -> None:
    # Given a request outside the synthetic profile's valid native shape.
    server, client = native_fixture
    # When processed, then the inherited validator rejects without a revision.
    client.request("PATCH", path, body, headers)
    response = client.getresponse()
    assert response.status == status
    assert response.read() == b"{}"
    assert server.revisions == {"a" * 32: [], "b" * 32: []}


def test_old_adapter_headers_cannot_bypass_profile_fault(
    native_fixture: tuple[GistService, HTTPConnection],
) -> None:
    # Given the legacy adapter's existing test headers.
    server, client = native_fixture
    publish(client, "initial")
    # When it attempts the dropped response, then the profile replaces headers.
    with closing(
        raw_patch(server, b"X-Simulator-At: invalid\r\nX-Simulator-Fault: \r\n")
    ) as connection:
        response = bytearray()
        while piece := connection.recv(1024):
            response.extend(piece)
    assert response == b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
    assert len(server.revisions["a" * 32]) == 1


def test_diagnostics_requests_remain_independent_and_profile_stays_bounded(
    native_fixture: tuple[GistService, HTTPConnection],
) -> None:
    # Given diagnostics outlive the profile's finite observation-time table.
    server, client = native_fixture
    # When six native requests publish independent synthetic heartbeat payloads.
    for sequence in range(6):
        body = json.dumps({"files": {"diagnostics.json": {"content": str(sequence)}}})
        client.request("PATCH", "/gists/" + "b" * 32, body, NATIVE_HEADERS)
        response = client.getresponse()
        assert response.status == 200
        snapshot = json.loads(response.read())
    # Then there is no transport fault and time clamps to the last fixture value.
    assert snapshot["updated_at"] == "2026-01-02T03:15:17Z"
    assert server.patch_attempts == {"a" * 32: 0, "b" * 32: 6}
    assert [entry.content for entry in server.revisions["b" * 32]] == list(
        map(str, range(6))
    )


@pytest.mark.parametrize("reset", [False, True])
def test_fixture_guard_or_reset_releases_stalled_service(
    native_fixture: tuple[GistService, HTTPConnection],
    reset: bool,
) -> None:
    # Given initial delivery and a consumed dropped response.
    server, client = native_fixture
    publish(client, "initial")
    with closing(raw_patch(server)) as connection:
        while connection.recv(1024):
            pass
    # When a stalled client resets, or never closes because its deadline is faulty.
    with closing(raw_patch(server)) as connection:
        prefix = bytearray()
        while len(prefix) < 36:
            piece = connection.recv(36 - len(prefix))
            assert piece
            prefix.extend(piece)
        if reset:
            connection.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
            )
        else:
            connection.settimeout(3.5)
            connection.sendall(b"unexpected bytes")
            assert connection.recv(1) == b""
    # Then both paths permit a bounded fresh recovery request.
    publish(client, "recovered")
    assert [entry.content for entry in server.revisions["a" * 32]] == [
        "initial",
        "recovered",
    ]


def test_unknown_fixture_profile_cannot_start_a_service() -> None:
    # Given a misspelled profile, when started, then it must fail before startup.
    result = run(
        [sys.executable, str(Path(__file__).with_name("serve.py")), "unknown"], 5
    )
    assert result.code == 1
    assert not result.stdout
    assert b"unsupported fixture profile" in result.stderr
