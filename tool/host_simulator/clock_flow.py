"""Continuous MicroPython clock pause/recovery, coordinated with the real app."""

import json
import os
import sys
import time

from firmware_flow import Clock, LoopbackTransport, Sensor


class CountingSensor(Sensor):
    reads = 0

    def read_celsius(self):
        self.reads += 1
        return super().read_celsius()


class CountingTransport(LoopbackTransport):
    def __init__(self, port, clock):
        super().__init__(port, clock)
        self.attempts = {"a" * 32: 0, "b" * 32: 0}

    def patch_gist(self, gist, body, service=None):
        self.attempts[gist] += 1
        return super().patch_gist(gist, body, service)

    def wire_attempts(self):
        response = self.exchange(
            b"GET /simulator/stats HTTP/1.1\r\nHost: localhost\r\n"
            b"Connection: close\r\n\r\n"
        )
        assert response.split(b"\r\n", 1)[0].split()[1] == b"200"
        return json.loads(response.split(b"\r\n\r\n", 1)[1])


def checkpoint(directory, phase, clock, sensor, monitor, transport, results):
    evidence = {
        "phase": phase,
        "trusted": clock.trusted,
        "sensor_reads": sensor.reads,
        "sequence": monitor.sequence,
        "publication_ok": results,
        "transport_attempts": transport.attempts,
        "wire_attempts": transport.wire_attempts(),
    }
    text = json.dumps(evidence)
    with open(directory + "/" + phase + ".json", "w") as stream:
        stream.write(text)
    marker = directory + "/" + phase + ".ready"
    with open(marker + ".tmp", "w") as stream:
        stream.write(phase)
    os.rename(marker + ".tmp", marker)
    print(text)
    return evidence


def wait_for_app(directory, phase):
    started = time.ticks_ms()
    while time.ticks_diff(time.ticks_ms(), started) < 120000:
        try:
            with open(directory + "/" + phase + ".ack") as stream:
                assert stream.read(32) == phase + "\n"
                return
        except OSError:
            time.sleep_ms(20)
    raise AssertionError("app acknowledgement deadline: " + phase)


def main():
    assert sys.implementation.name == "micropython"
    assert sys.implementation.version[:3] == (1, 29, 0)
    assert sys.platform == "linux"
    root, directory = sys.argv[2:4]
    sys.path.insert(0, root + "/firmware/pico")
    from gist_publisher import GistPublisher
    from runtime import Monitor

    clock, sensor = Clock(), CountingSensor()
    clock.trusted = True
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
        time_is_trusted=lambda: clock.trusted,
    )
    publisher.transport.close()
    transport = CountingTransport(int(sys.argv[1]), clock)
    publisher.transport = transport
    monitor = Monitor(sensor, publisher, clock, "clock-boot", "device-0", "host-test")
    try:
        result = monitor.poll()
        initial = checkpoint(
            directory, "initial", clock, sensor, monitor, transport, [result]
        )
        assert result is True and monitor.sequence == sensor.reads == 1
        assert (
            initial["transport_attempts"]
            == initial["wire_attempts"]
            == {"a" * 32: 1, "b" * 32: 1}
        )
        wait_for_app(directory, "initial")

        clock.trusted = False
        results = []
        for milliseconds, value in ((300000, 8.0), (900000, 9.0)):
            clock.now, sensor.value = milliseconds, value
            results.append(monitor.poll())
        paused = checkpoint(
            directory, "paused", clock, sensor, monitor, transport, results
        )
        assert results == [False, False] and monitor.sequence == sensor.reads == 3
        assert (
            paused["transport_attempts"]
            == paused["wire_attempts"]
            == {"a" * 32: 1, "b" * 32: 1}
        )
        wait_for_app(directory, "paused")

        clock.trusted = True
        clock.now, sensor.value = 1200000, 6.5
        result = monitor.poll()
        recovered = checkpoint(
            directory, "recovered", clock, sensor, monitor, transport, [result]
        )
        assert result is True and monitor.sequence == sensor.reads == 4
        assert (
            recovered["transport_attempts"]
            == recovered["wire_attempts"]
            == {"a" * 32: 2, "b" * 32: 2}
        )
    finally:
        publisher.close()
    print("FARMCTL_CLOCK_OK")


if __name__ == "__main__":
    main()
