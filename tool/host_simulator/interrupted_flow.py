# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
# Run under pinned MicroPython Unix via tool/host_simulator/run.py.
"""Pre-application failures, exact publisher retries and delivered app history."""

import sys
import time

from clock_flow import CountingSensor, checkpoint, wait_for_app
from firmware_flow import Clock


def main():
    assert sys.implementation.name == "micropython"
    assert sys.implementation.version[:3] == (1, 29, 0)
    assert sys.platform == "linux"
    port, root, directory = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    sys.path.insert(0, root + "/firmware/pico")
    from gist_publisher import GistPublisher

    # DEADLINE_MUTATION
    from runtime import Monitor

    from native_loopback import (
        NativeLoopbackTransport,
        PlaintextTLS,
        numeric_resolver,
        select,
        socket,
    )

    clock, sensor = Clock(), CountingSensor()
    clock.trusted = True
    publisher = GistPublisher(
        "a" * 32,
        "b" * 32,
        "synthetic-host-token",
        b"synthetic-unused-ca",
        PlaintextTLS,
        select,
        socket,
        clock,
        "127.0.0.1",
        resolver=numeric_resolver(port),
        time_is_trusted=lambda: True,
        timeout_ms=650,
    )
    # Retry scheduling remains deterministic; request deadlines use real ticks.
    publisher.transport.clock = time
    transport = NativeLoopbackTransport(port, publisher.transport)
    publisher.transport = transport
    monitor = Monitor(
        sensor, publisher, clock, "interrupted-boot", "device-0", "host-test"
    )
    try:
        initial = monitor.poll()
        checkpoint(directory, "initial", clock, sensor, monitor, transport, [initial])
        assert initial is True
        wait_for_app(directory, "initial")

        for phase, at, value, expected_attempts in (
            ("dropped", 900000, 8.0, 2),
            ("first_backoff", 905624, 9.0, 2),
            ("stalled", 905625, 10.0, 3),
            ("second_backoff", 917624, 11.0, 3),
        ):
            clock.now, sensor.value = at, value
            started = time.ticks_ms()
            result = monitor.poll()
            elapsed = time.ticks_diff(time.ticks_ms(), started)
            checkpoint(
                directory,
                phase,
                clock,
                sensor,
                monitor,
                transport,
                [result],
                {"elapsed_ms": elapsed, "at_ms": at},
            )
            assert result is False
            assert transport.attempts["a" * 32] == expected_attempts
            assert transport.wire_attempts() == transport.attempts
            assert elapsed < 1500
            if phase == "stalled":
                assert elapsed >= 500
            wait_for_app(directory, phase)

        clock.now, sensor.value = 917625, 6.5
        result = monitor.poll()
        checkpoint(
            directory,
            "recovered",
            clock,
            sensor,
            monitor,
            transport,
            [result],
            {"at_ms": clock.now},
        )
        assert result is True
        assert sensor.reads == monitor.sequence == 6
        assert transport.attempts == {"a" * 32: 4, "b" * 32: 5}
        assert transport.wire_attempts() == transport.attempts
    finally:
        publisher.close()
    print("FARMCTL_INTERRUPTED_OK")


if __name__ == "__main__":
    main()
