"""Opt-in, bounded spare-device session coordinator.

Importing this module has no hardware or runtime side effects. Device wiring is
provided by the caller after the expected device identity has been checked.
"""

import binascii


DURATION_MS = 70000
MAX_STEPS = 72
SLEEP_MS = 1000

_BLOCKED_IDENTITY = 'BLOCKED_IDENTITY'
_BLOCKED_CLOCK = 'BLOCKED_CLOCK'


def _valid_uname(value):
    if type(value) is not str or not value or len(value) > 256:
        return False
    for character in value:
        code = ord(character)
        if code < 32 or code > 126:
            return False
    return True


def run_spare_session(expected_uid_sha256, expected_uname_machine,
                      expected_uname_release, *, read_identity,
                      monitor_factory, clock, sleep_ms, stop_requested):
    """Run a single cooperative session, returning only a fixed status string."""
    try:
        valid_arguments = (
            type(expected_uid_sha256) is str and
            len(expected_uid_sha256) == 64 and
            all(character in '0123456789abcdef'
                for character in expected_uid_sha256) and
            _valid_uname(expected_uname_machine) and
            _valid_uname(expected_uname_release) and
            callable(read_identity) and callable(monitor_factory) and
            callable(sleep_ms) and callable(stop_requested) and
            callable(getattr(clock, 'ticks_ms', None)) and
            callable(getattr(clock, 'ticks_diff', None)))
    except BaseException:
        valid_arguments = False
    if not valid_arguments:
        return _BLOCKED_IDENTITY

    expected_digest = binascii.unhexlify(expected_uid_sha256)
    monitor = None
    close = None
    status = _BLOCKED_IDENTITY
    acquired = False

    def stopped():
        value = stop_requested()
        if type(value) is not bool:
            raise ValueError
        return value

    def clock_state(previous, start):
        """Return (now, elapsed), or None for any invalid clock result."""
        try:
            now = clock.ticks_ms()
            if type(now) is not int:
                return None
            elapsed = clock.ticks_diff(now, start)
            since_previous = clock.ticks_diff(now, previous)
            if (type(elapsed) is not int or type(since_previous) is not int or
                    elapsed < 0 or since_previous < 0):
                return None
            return now, elapsed
        except BaseException:
            return None

    try:
        if stopped():
            status = 'STOPPED'
            return status

        try:
            identity = read_identity()
        except BaseException:
            identity = None
        if not (type(identity) is tuple and len(identity) == 3 and
                type(identity[0]) is bytes and len(identity[0]) == 32 and
                _valid_uname(identity[1]) and _valid_uname(identity[2]) and
                identity[0] == expected_digest and
                identity[1] == expected_uname_machine and
                identity[2] == expected_uname_release):
            return _BLOCKED_IDENTITY

        if stopped():
            status = 'STOPPED'
            return status

        # Establish and validate the clock before constructing hardware/network
        # adapters, so an unusable deadline cannot start a publisher.
        try:
            start = clock.ticks_ms()
            if type(start) is not int:
                return _BLOCKED_CLOCK
        except BaseException:
            return _BLOCKED_CLOCK

        try:
            created = monitor_factory()
            if (type(created) is tuple and len(created) == 2 and
                    callable(getattr(created[0], 'step', None)) and
                    callable(getattr(created[0], 'suspend_publication', None)) and
                    callable(created[1])):
                monitor, close = created
                acquired = True
                status = 'SESSION_FAILED'
            else:
                return 'FACTORY_FAILED_CLEANUP_UNKNOWN'
        except BaseException:
            return 'FACTORY_FAILED_CLEANUP_UNKNOWN'

        previous = start
        status = 'DURATION_ENDED'
        for _ in range(MAX_STEPS):
            if stopped():
                status = 'STOPPED'
                break
            state = clock_state(previous, start)
            if state is None:
                status = _BLOCKED_CLOCK
                break
            now, elapsed = state
            previous = now
            if elapsed >= DURATION_MS:
                status = 'DURATION_ENDED'
                break
            if stopped():
                status = 'STOPPED'
                break
            try:
                result = monitor.step(10, 60)
            except BaseException:
                status = 'STEP_FAILED'
                break
            if result is not True and result is not False:
                status = 'STEP_FAILED'
                break
            if stopped():
                status = 'STOPPED'
                break
            state = clock_state(previous, start)
            if state is None:
                status = _BLOCKED_CLOCK
                break
            now, elapsed = state
            previous = now
            if elapsed >= DURATION_MS:
                status = 'DURATION_ENDED'
                break
            if stopped():
                status = 'STOPPED'
                break
            sleep_ms(min(SLEEP_MS, DURATION_MS - elapsed))
            if stopped():
                status = 'STOPPED'
                break
        else:
            status = 'ITERATION_LIMIT'
    except BaseException:
        # Includes interrupts: acquired resources are still handled below.
        status = 'SESSION_FAILED'
    finally:
        if acquired:
            cleanup_failed = False
            try:
                if monitor.suspend_publication() is not True:
                    cleanup_failed = True
            except BaseException:
                cleanup_failed = True
            try:
                close()
            except BaseException:
                cleanup_failed = True
            if cleanup_failed:
                status = 'CLEANUP_FAILED'
    return status


def read_device_identity():
    """Return hashed board UID and uname fields without exposing the raw UID."""
    import hashlib
    import machine
    import os

    digest = hashlib.sha256(machine.unique_id()).digest()
    uname = os.uname()
    return digest, uname.machine, uname.release
