# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# Run under pinned MicroPython Unix via tool/host_simulator/run.py.
"""A wire Retry-After pauses both real publisher streams while sampling continues."""

import json
import sys

from clock_flow import CountingSensor, CountingTransport, checkpoint, wait_for_app
from firmware_flow import Clock


class RateTransport(CountingTransport):
    def fault(self, gist):
        return "429" if self.clock.now == 900000 and gist == "a" * 32 else ""

    def failure_headers(self, headers):
        return headers


def main():
    assert sys.implementation.name == "micropython"
    assert sys.implementation.version[:3] == (1, 29, 0)
    assert sys.platform == "linux"
    port, root, directory = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    sys.path.insert(0, root + "/firmware/pico")
    from gist_publisher import GistPublisher
    from runtime import Monitor

    clock = Clock()
    clock.trusted = True
    sensor = CountingSensor()
    publisher = GistPublisher(
        "a" * 32,
        "b" * 32,
        bytearray(b"synthetic-host-token"),
        b"synthetic-roots-not-used",
        None,
        None,
        None,
        clock,
        "127.0.0.1",
        time_is_trusted=lambda: True,
    )
    publisher.transport.close()
    transport = RateTransport(port, clock)
    publisher.transport = transport
    monitor = Monitor(sensor, publisher, clock, "rate-boot", "device-0", "host-test")
    try:
        initial = monitor.poll()
        checkpoint(directory, "initial", clock, sensor, monitor, transport, [initial])
        assert initial is True
        wait_for_app(directory, "initial")

        clock.now, sensor.value = 900000, 8.0
        limited = monitor.poll()
        checkpoint(directory, "limited", clock, sensor, monitor, transport, [limited])
        assert limited is False
        assert transport.wire_attempts() == {"a" * 32: 2, "b" * 32: 1}
        wait_for_app(directory, "limited")

        results = []
        for at, value in ((960000, 9.0), (1019999, 10.0)):
            clock.now, sensor.value = at, value
            results.append(monitor.poll())
            print(
                json.dumps(
                    {
                        "phase": "rate_poll",
                        "at_ms": at,
                        "sample_ok": results[-1],
                        "sequence": monitor.sequence,
                    }
                )
            )
        checkpoint(directory, "paused", clock, sensor, monitor, transport, results)
        assert results == [False, False]
        assert sensor.reads == monitor.sequence == 4
        assert transport.attempts == {"a" * 32: 2, "b" * 32: 1}
        assert transport.wire_attempts() == transport.attempts
        wait_for_app(directory, "paused")

        clock.now, sensor.value = 1020000, 6.5
        recovered = monitor.poll()
        print(
            json.dumps(
                {
                    "phase": "rate_poll",
                    "at_ms": clock.now,
                    "sample_ok": recovered,
                    "sequence": monitor.sequence,
                }
            )
        )
        checkpoint(
            directory, "recovered", clock, sensor, monitor, transport, [recovered]
        )
        assert recovered is True
        assert sensor.reads == monitor.sequence == 5
        assert transport.attempts == {"a" * 32: 3, "b" * 32: 2}
        assert transport.wire_attempts() == transport.attempts
    finally:
        publisher.close()
    print("FARMCTL_RATE_OK")


if __name__ == "__main__":
    main()
