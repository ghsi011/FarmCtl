import unittest

from runtime import Monitor
from spare_session import run_spare_session


UID = 'ab' * 32
IDENTITY = (bytes.fromhex(UID), 'RP2', '1.29')


class Clock:
    def __init__(self, modulus=None):
        self.now = 0
        self.modulus = modulus

    def ticks_ms(self):
        return self.now % self.modulus if self.modulus else self.now

    def ticks_diff(self, current, previous):
        if self.modulus:
            half = self.modulus // 2
            return (current - previous + half) % self.modulus - half
        return current - previous


class Sensor:
    def __init__(self, values=None):
        self.values = list(values if values is not None else
                           (20.0 + index for index in range(100)))
        self.reads = 0

    def read_celsius(self):
        self.reads += 1
        if not self.values:
            raise OSError('sensor unavailable')
        return self.values.pop(0)


class Publisher:
    def __init__(self, fail_diagnostics=False):
        self.temperatures = []
        self.diagnostics = []
        self.fail_diagnostics = fail_diagnostics

    def publish_temperature(self, payload):
        self.temperatures.append(payload)

    def publish_diagnostics(self, payload):
        if self.fail_diagnostics:
            raise OSError('private diagnostic transport detail')
        self.diagnostics.append(payload)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.sensor = Sensor()
        self.publisher = Publisher(fail_diagnostics=True)
        self.instance = Monitor(self.sensor, self.publisher, self.clock,
                                'boot-1', 'device', '1.0')
        self.closed = 0
        self.created = 0

    def factory(self):
        self.created += 1
        return self.instance, self.close

    def close(self):
        self.closed += 1

    def run_session(self, **kwargs):
        options = dict(
            expected_uid_sha256=UID,
            expected_uname_machine='RP2',
            expected_uname_release='1.29',
            read_identity=lambda: IDENTITY,
            monitor_factory=self.factory,
            clock=self.clock,
            sleep_ms=lambda duration: setattr(self.clock, 'now', self.clock.now + duration),
            stop_requested=lambda: False,
        )
        options.update(kwargs)
        return run_spare_session(**options)

    def test_real_monitor_publishes_initial_and_fresh_due_marker(self):
        self.sensor = Sensor([20.0 + index for index in range(100)])
        self.instance.sensor = self.sensor
        status = self.run_session()
        self.assertEqual(status, 'DURATION_ENDED')
        self.assertEqual(len(self.publisher.temperatures), 2)
        contents = [item['files']['thermostat.txt']['content']
                    for item in self.publisher.temperatures]
        self.assertNotEqual(contents[0], contents[1])
        self.assertTrue(contents[0].endswith('Sample: boot-1:1'))
        self.assertTrue(contents[1].endswith('Sample: boot-1:7'))
        self.assertEqual(self.sensor.reads, 7)
        self.assertEqual(self.publisher.diagnostics, [])
        self.assertTrue(self.instance._publication_suspended)
        self.assertEqual(self.closed, 1)

    def test_identity_mismatch_or_malformed_fields_never_construct_monitor(self):
        for bad in ((b'x' * 32, 'RP2', '1.29'), (b'x' * 31, 'RP2', '1.29'),
                    (bytes.fromhex(UID), 'RP2\n', '1.29'),
                    (bytes.fromhex(UID), 'RP2é', '1.29')):
            self.assertEqual(self.run_session(read_identity=lambda bad=bad: bad),
                             'BLOCKED_IDENTITY')
        self.assertEqual(self.created, 0)
        self.assertEqual(self.closed, 0)

    def test_identity_exception_and_pre_gate_cancel_are_fail_closed(self):
        self.assertEqual(self.run_session(read_identity=lambda: 1 / 0),
                         'BLOCKED_IDENTITY')
        self.assertEqual(self.run_session(stop_requested=lambda: True), 'STOPPED')
        self.assertEqual(self.created, 0)

    def test_printable_space_identity_is_accepted_and_post_gate_cancel_cleans(self):
        self.assertEqual(self.run_session(
            expected_uname_machine='Raspberry Pi Pico 2 W',
            read_identity=lambda: (bytes.fromhex(UID), 'Raspberry Pi Pico 2 W', '1.29'),
            stop_requested=lambda: False), 'DURATION_ENDED')
        self.setUp()
        checks = [False, False, True]
        self.assertEqual(self.run_session(stop_requested=lambda: checks.pop(0)),
                         'STOPPED')
        self.assertEqual(self.created, 1)
        self.assertEqual(self.closed, 1)

    def test_invalid_clock_prevents_factory_and_in_loop_stop_errors_are_session_failed(self):
        class InvalidClock(Clock):
            def ticks_ms(self):
                return True

        self.assertEqual(self.run_session(clock=InvalidClock()), 'BLOCKED_CLOCK')
        self.assertEqual(self.created, 0)
        checks = [False, False, False]

        def broken_stop_during_loop():
            if checks:
                checks.pop()
                return False
            raise RuntimeError('private stop detail')

        self.assertEqual(self.run_session(stop_requested=broken_stop_during_loop),
                         'SESSION_FAILED')
        self.assertEqual(self.closed, 1)

    def test_cancellation_in_loop_closes_and_wrapping_clock_completes_session(self):
        checks = 0

        def cancel_after_first_step():
            nonlocal checks
            checks += 1
            return checks > 3

        self.assertEqual(self.run_session(stop_requested=cancel_after_first_step), 'STOPPED')
        self.assertEqual(self.closed, 1)

        self.setUp()
        self.clock = Clock(modulus=1 << 20)
        self.instance.clock = self.clock
        self.assertEqual(self.run_session(), 'DURATION_ENDED')
        self.assertEqual(self.closed, 1)

    def test_bad_sample_does_not_republish_old_temperature(self):
        self.sensor.values = [20.0]
        self.publisher.fail_diagnostics = False
        result = self.run_session()
        self.assertEqual(result, 'STEP_FAILED')
        self.assertEqual(len(self.publisher.temperatures), 1)
        self.assertEqual(self.sensor.reads, 2)
        self.assertEqual(len(self.publisher.diagnostics), 2)

    def test_step_failure_closes_once_and_returns_redacted_status(self):
        self.instance.step = lambda *_: (_ for _ in ()).throw(
            OSError('secret token detail'))
        status = self.run_session()
        self.assertEqual(status, 'STEP_FAILED')
        self.assertEqual(self.closed, 1)
        self.assertTrue(self.instance._publication_suspended)
        self.assertNotIn('secret', status)

    def test_suspend_returning_false_is_cleanup_failure_but_close_is_attempted(self):
        self.instance.suspend_publication = lambda: False
        self.assertEqual(self.run_session(), 'CLEANUP_FAILED')
        self.assertEqual(self.closed, 1)

    def test_sleep_failure_and_frozen_clock_are_bounded_and_cleaned(self):
        status = self.run_session(sleep_ms=lambda _: (_ for _ in ()).throw(
            RuntimeError('private sleep detail')))
        self.assertEqual(status, 'SESSION_FAILED')
        self.assertEqual(self.closed, 1)

        self.setUp()
        status = self.run_session(sleep_ms=lambda _: None)
        self.assertEqual(status, 'ITERATION_LIMIT')
        self.assertEqual(self.closed, 1)

    def test_factory_failure_is_not_claimed_as_cleaned_up(self):
        status = self.run_session(monitor_factory=lambda: (_ for _ in ()).throw(
            OSError('partial allocation unknown')))
        self.assertEqual(status, 'FACTORY_FAILED_CLEANUP_UNKNOWN')
        self.assertEqual(self.closed, 0)

    def test_cleanup_failure_overrides_session_result(self):
        self.instance.suspend_publication = lambda: (_ for _ in ()).throw(
            RuntimeError('cleanup detail'))
        self.assertEqual(self.run_session(), 'CLEANUP_FAILED')
        self.assertEqual(self.closed, 1)


if __name__ == '__main__':
    unittest.main()
