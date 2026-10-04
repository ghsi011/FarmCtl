"""Loopback-only synthetic Gist fixture; never a production backend."""

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Final, cast
from urllib.parse import parse_qs, urlsplit

GISTS: Final = {"a" * 32: "thermostat.txt", "b" * 32: "diagnostics.json"}
MAX_BODY: Final = 32768
MAX_REVISIONS: Final = 32


@dataclass(frozen=True, slots=True)
class Revision:
    version: str
    content: str
    observed_at: str

    def snapshot(self, filename: str) -> bytes:
        return json.dumps(
            {
                "updated_at": self.observed_at,
                "files": {filename: {"content": self.content, "truncated": False}},
            }
        ).encode()


class GistHandler(BaseHTTPRequestHandler):
    """Only the two synthetic Gists exist; state is private to this server."""

    @property
    def fixture(self) -> "GistService":
        return cast("GistService", self.server)

    def log_message(self, format: str, *args: str) -> None:
        # Fixture requests/headers may carry synthetic tokens; keep logs silent.
        return

    def respond(self, status: int, body: bytes, retry_after: int | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if retry_after is not None:
            self.send_header("Retry-After", str(retry_after))
        self.end_headers()
        self.wfile.write(body)

    def do_PATCH(self) -> None:
        if self.headers.get("Authorization") != "token synthetic-host-token":
            self.respond(401, b"{}")
            return
        path = urlsplit(self.path).path
        gist = path.removeprefix("/gists/")
        if path != "/gists/" + gist or gist not in GISTS:
            self.respond(404, b"{}")
            return
        self.fixture.patch_attempts[gist] += 1
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                self.respond(413, b"{}")
                return
            raw = json.loads(self.rfile.read(length))
            filename = GISTS[gist]
            if (
                not isinstance(raw, dict)
                or set(raw) != {"files"}
                or not isinstance(raw["files"], dict)
                or set(raw["files"]) != {filename}
            ):
                self.respond(400, b"{}")
                return
            file = raw["files"][filename]
            if (
                not isinstance(file, dict)
                or set(file) != {"content"}
                or not isinstance(file["content"], str)
            ):
                self.respond(400, b"{}")
                return
            at = self.headers.get("X-Simulator-At", "")
            datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (ValueError, UnicodeError):
            self.respond(400, b"{}")
            return
        if self.headers.get("X-Simulator-Fault") == "503":
            self.respond(503, b"{}")
            return
        if self.headers.get("X-Simulator-Fault") == "429":
            self.respond(429, b"{}", retry_after=120)
            return
        content = file["content"]
        revisions = self.fixture.revisions[gist]
        if not revisions or revisions[-1].content != content:
            if len(revisions) >= MAX_REVISIONS:
                self.respond(507, b"{}")
                return
            version = hashlib.sha256(
                (gist + str(len(revisions)) + content).encode(),
            ).hexdigest()[:40]
            revisions.append(Revision(version, content, at))
        self.respond(200, revisions[-1].snapshot(filename))

    def do_GET(self) -> None:
        url = urlsplit(self.path)
        if url.path == "/simulator/stats" and not url.query:
            self.respond(200, json.dumps(self.fixture.patch_attempts).encode())
            return
        match = re.fullmatch(r"/gists/([ab]{32})(?:/(commits|[0-9a-f]{40}))?", url.path)
        if match is None or match[1] not in GISTS:
            self.respond(404, b"{}")
            return
        if parse_qs(url.query).get("fixture_error") == ["503"]:
            self.respond(503, b"{}")
            return
        gist, suffix = match.groups()
        revisions = self.fixture.revisions[gist]
        if not revisions:
            self.respond(404, b"{}")
            return
        if suffix == "commits":
            query = parse_qs(url.query)
            try:
                page = int(query.get("page", ["1"])[0])
                per_page = int(query.get("per_page", ["100"])[0])
                if page < 1 or not 1 <= per_page <= 100:
                    raise ValueError
            except ValueError:
                self.respond(400, b"{}")
                return
            selected = list(reversed(revisions))[
                (page - 1) * per_page : page * per_page
            ]
            self.respond(
                200,
                json.dumps(
                    [
                        {"version": entry.version, "committed_at": entry.observed_at}
                        for entry in selected
                    ]
                ).encode(),
            )
            return
        entry = (
            revisions[-1]
            if suffix is None
            else next(
                (entry for entry in revisions if entry.version == suffix),
                None,
            )
        )
        if entry is None:
            self.respond(404, b"{}")
            return
        self.respond(200, entry.snapshot(GISTS[gist]))


class GistService(HTTPServer):
    """Mutable in-memory revision log, owned by one loopback service."""

    def __init__(self) -> None:
        self.revisions: dict[str, list[Revision]] = {gist: [] for gist in GISTS}
        self.patch_attempts: dict[str, int] = dict.fromkeys(GISTS, 0)
        super().__init__(("127.0.0.1", 0), GistHandler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(3)
        return connection, address
