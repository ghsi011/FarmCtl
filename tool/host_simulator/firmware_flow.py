# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# Run under pinned MicroPython Unix via tool/host_simulator/run.py.
"""Portable assertion harness; physical hardware and native TLS are substituted."""

import gc
import io
import json
import socket
import sys


class Chunked:
    def __init__(self, stream, size):
        self.stream = stream
        self.size = size
        self.extra = b""

    def read(self, size):
        block = self.stream.read(min(size, self.size))
        if not block:
            block, self.extra = self.extra, b""
        return block


class Clock:
    now = 0

    def ticks_ms(self):
        return self.now

    def ticks_diff(self, current, previous):
        return current - previous


class Sensor:
    """Synthetic fresh readings; None represents failed conversion."""

    value = 4.25

    def read_celsius(self):
        if self.value is None:
            raise OSError("synthetic conversion failure")
        return self.value


class LoopbackTransport:
    """Actual host HTTP sockets, replacing native HTTPS only in this harness."""

    def __init__(self, port, clock):
        self.port = port
        self.clock = clock

    def patch_gist(self, gist, body, service=None):
        from native_https import HttpFailure

        at = "2026-01-02T03:%02d:00Z" % (self.clock.now // 60000)
        fault = self.clock.now == 900000 and gist == "b" * 32
        request = (
            "PATCH /gists/%s HTTP/1.1\r\nHost: api.github.com\r\n"
            "Authorization: token synthetic-host-token\r\n"
            "Content-Type: application/json\r\nContent-Length: %d\r\n"
            "X-Simulator-At: %s\r\nX-Simulator-Fault: %s\r\n"
            "Connection: close\r\n\r\n" % (gist, len(body), at, "503" if fault else "")
        ).encode() + body
        response = self.exchange(request)
        status = int(response.split(b"\r\n", 1)[0].split()[1])
        if status != 200:
            raise HttpFailure(status, {})

    def exchange(self, request):
        connection = socket.socket()
        try:
            connection.settimeout(3)
            address = socket.getaddrinfo(
                "127.0.0.1", self.port, socket.AF_INET, socket.SOCK_STREAM
            )[0][-1]
            connection.connect(address)
            sent = 0
            while sent < len(request):
                count = connection.send(memoryview(request)[sent:])
                if count <= 0:
                    raise OSError("loopback write ended early")
                sent += count
            response = bytearray()
            while True:
                chunk = connection.recv(1024)
                if not chunk:
                    break
                response.extend(chunk)
                if len(response) > 32768:
                    raise OSError("loopback response exceeded bound")
            return bytes(response)
        finally:
            connection.close()

    def close(self):
        return


def parser_checks(fixture):
    from fleet_config import FleetConfigError, parse_fleet

    for chunk_size in (37, 1024):
        progress = []
        with open(fixture, "rb") as stream:
            result = parse_fleet(
                Chunked(stream, chunk_size), "device-0", service=progress.append
            )
        assert result.device.logical_id == "monitor-0"
        assert progress[0] == 0 and progress[-1] == 65536
        assert all(
            0 <= current - previous <= 1024
            for previous, current in zip(progress, progress[1:])
        )
    with open(fixture, "rb") as stream:
        oversized = Chunked(stream, 37)
        oversized.extra = b" "
        try:
            parse_fleet(oversized, "device-0")
        except FleetConfigError:
            pass
        else:
            raise AssertionError("65537-byte fleet accepted")
    for malformed in (
        b'{"schema_version":',
        b'{"schema_version":1,"schema_version":1}',
    ):
        try:
            parse_fleet(io.BytesIO(malformed), "device-0")
        except FleetConfigError:
            pass
        else:
            raise AssertionError("malformed fleet accepted")
    print(
        json.dumps(
            {
                "phase": "parser",
                "bytes": 65536,
                "chunk_sizes": [37, 1024],
                "over_limit_rejected": True,
            }
        )
    )


def main():
    assert sys.implementation.name == "micropython"
    assert sys.implementation.version[:3] == (1, 29, 0)
    assert sys.platform == "linux"
    root = sys.argv[3]
    sys.path.insert(0, root + "/firmware/pico")
    from gist_publisher import GistPublisher
    from runtime import Monitor

    parser_checks(sys.argv[2])
    clock, sensor = Clock(), Sensor()
    publisher = GistPublisher(
        "a" * 32,
        "b" * 32,
        "synthetic-host-token",
        b"synthetic-unused-ca",
        None,
        None,
        None,
        clock,
        "127.0.0.1",
        time_is_trusted=lambda: True,
    )
    # Existing capability validation still runs; no native network method runs.
    publisher.transport.close()
    publisher.transport = LoopbackTransport(int(sys.argv[1]), clock)
    monitor = Monitor(sensor, publisher, clock, "host-boot", "device-0", "host-test")
    try:
        for milliseconds, value, expected in (
            (0, 4.25, True),
            (300000, 4.25, True),
            (600000, None, False),
            (900000, 6.5, True),
            (1200000, None, False),
        ):
            clock.now, sensor.value = milliseconds, value
            actual = monitor.poll()
            print(
                json.dumps(
                    {
                        "phase": "poll",
                        "at_ms": milliseconds,
                        "sample_ok": actual,
                        "sequence": monitor.sequence,
                    }
                )
            )
            assert actual is expected
        assert monitor.sequence == 3
    finally:
        publisher.close()
    gc.collect()
    print(
        json.dumps(
            {
                "phase": "runtime",
                "implementation": sys.implementation.name,
                "version": list(sys.implementation.version[:3]),
                "platform": sys.platform,
                "machine": sys.implementation._machine,
                "host_gc_free": gc.mem_free(),
                "substituted": ["sensor", "clock", "native_https_transport"],
            }
        )
    )
    print("FARMCTL_HOST_OK")


if __name__ == "__main__":
    main()
