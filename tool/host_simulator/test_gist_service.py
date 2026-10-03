"""Wire contracts required by the shared synthetic API fixture."""

import json
from collections.abc import Iterator
from contextlib import closing
from http.client import HTTPConnection
from threading import Thread

import pytest

from gist_service import MAX_REVISIONS, GistService

PATH = "/gists/" + "a" * 32
HEADERS = {
    "Content-Type": "application/json",
    "Authorization": "token synthetic-host-token",
    "X-Simulator-At": "2026-01-02T03:01:00Z",
}


@pytest.fixture
def client() -> Iterator[HTTPConnection]:
    with GistService() as server:
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with closing(
                HTTPConnection("127.0.0.1", server.server_port, timeout=2)
            ) as connection:
                yield connection
        finally:
            server.shutdown()
            worker.join(timeout=2)
            assert not worker.is_alive()


def request(
    client: HTTPConnection,
    method: str,
    path: str = PATH,
    body: str | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, object]:
    client.request(method, path, body, HEADERS if headers is None else headers)
    response = client.getresponse()
    return response.status, json.loads(response.read())


def publish(
    client: HTTPConnection, content: str, headers: dict[str, str] | None = None
) -> tuple[int, object]:
    return request(
        client,
        "PATCH",
        body=json.dumps({"files": {"thermostat.txt": {"content": content}}}),
        headers=headers,
    )


def test_fresh_markers_create_history_but_identical_retry_does_not(
    client: HTTPConnection,
) -> None:
    # Equal values still represent distinct observations; retries keep their age.
    for sequence in (1, 2):
        assert (
            publish(
                client,
                f"4.25°C\nSample: host-boot:{sequence}",
                HEADERS | {"X-Simulator-At": f"2026-01-02T03:0{sequence}:00Z"},
            )[0]
            == 200
        )
    assert publish(client, "4.25°C\nSample: host-boot:2")[0] == 200
    status, commits = request(client, "GET", PATH + "/commits")
    assert status == 200
    assert isinstance(commits, list)
    assert [entry["committed_at"] for entry in commits] == [
        "2026-01-02T03:02:00Z",
        "2026-01-02T03:01:00Z",
    ]
    assert request(client, "GET", PATH + "/commits?page=2&per_page=1")[1] == commits[1:]
    status, snapshot = request(client, "GET", PATH + "/" + commits[1]["version"])
    assert status == 200
    assert snapshot["updated_at"] == "2026-01-02T03:01:00Z"
    assert "host-boot:1" in snapshot["files"]["thermostat.txt"]["content"]


def test_injected_faults_never_mutate_observation(client: HTTPConnection) -> None:
    assert request(client, "GET")[0] == 404
    assert publish(client, "first")[0] == 200
    assert publish(client, "lost", HEADERS | {"X-Simulator-Fault": "503"})[0] == 503
    assert request(client, "GET", PATH + "?fixture_error=503")[0] == 503
    status, snapshot = request(client, "GET")
    assert status == 200
    assert snapshot["files"]["thermostat.txt"]["content"] == "first"
    assert len(request(client, "GET", PATH + "/commits")[1]) == 1


@pytest.mark.parametrize(
    "method,path,body,headers,status",
    [
        ("PATCH", PATH, None, {}, 401),
        ("PATCH", "/gists/unknown", None, HEADERS, 404),
        # Reject the declared size before reading a body; sending unread excess
        # bytes can legitimately reset TCP when the bounded server closes early.
        ("PATCH", PATH, None, HEADERS | {"Content-Length": "32769"}, 413),
        ("PATCH", PATH, "{", HEADERS, 400),
        ("PATCH", PATH, "{}", HEADERS, 400),
        ("PATCH", PATH, '{"files":{"thermostat.txt":{"content":1}}}', HEADERS, 400),
        (
            "PATCH",
            PATH,
            '{"files":{"thermostat.txt":{"content":"x"}}}',
            HEADERS | {"X-Simulator-At": "bad"},
            400,
        ),
        ("GET", "/gists/unknown", None, HEADERS, 404),
    ],
    ids=[
        "auth",
        "unknown",
        "oversized",
        "malformed",
        "missing-files",
        "wrong-content",
        "bad-time",
        "missing-gist",
    ],
)
def test_rejects_invalid_wire_input(
    client: HTTPConnection,
    method: str,
    path: str,
    body: str | None,
    headers: dict[str, str],
    status: int,
) -> None:
    assert request(client, method, path, body, headers)[0] == status
    assert request(client, "GET")[0] == 404


@pytest.mark.parametrize(
    "suffix",
    ["/commits?page=0", "/commits?per_page=101", "/commits?page=x", "/" + "0" * 40],
)
def test_rejects_invalid_history_lookup(client: HTTPConnection, suffix: str) -> None:
    assert publish(client, "first")[0] == 200
    assert request(client, "GET", PATH + suffix)[0] == (
        404 if suffix == "/" + "0" * 40 else 400
    )


def test_caps_retained_revisions(client: HTTPConnection) -> None:
    for sequence in range(MAX_REVISIONS):
        assert publish(client, str(sequence))[0] == 200
    assert publish(client, "overflow")[0] == 507
    assert len(request(client, "GET", PATH + "/commits")[1]) == MAX_REVISIONS
