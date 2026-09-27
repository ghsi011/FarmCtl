import copy
import traceback
import unittest

from runtime import Monitor


class FakeClock:
    def __init__(self):
        self.now = 0
        self.reads = 0

    def ticks_ms(self):
        self.reads += 1
        return self.now

    def ticks_diff(self, current, previous):
        return current - previous


class FakeSensor:
    def __init__(self):
        self.reads = 0

    def read_celsius(self):
        self.reads += 1
        return 20.0


class FakePublisher:
    def __init__(self):
        self.temperatures = []
        self.diagnostics = []
        self.on_temperature = None

    def publish_temperature(self, payload):
        self.temperatures.append(payload)
        if self.on_temperature is not None:
            self.on_temperature()

    def publish_diagnostics(self, payload):
        self.diagnostics.append(payload)

    def close(self):
        pass


class MonitorSuspensionTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.sensor = FakeSensor()
        self.publisher = FakePublisher()
        self.monitor = Monitor(
            self.sensor, self.publisher, self.clock, 'boot-1', 'device', '1.0'
        )

    def _state(self):
        return (
            self.clock.reads,
            self.sensor.reads,
            self.monitor.sequence,
            self.monitor._last_clock_ms,
            self.monitor._uptime_ms,
            self.monitor._last_sample_attempt_ms,
            self.monitor._last_temperature_published_ms,
            self.monitor._last_publication_attempt_ms,
            self.monitor._last_step_ms,
            self.monitor.last_report_ms,
            copy.deepcopy(self.monitor.diagnostics),
            len(self.publisher.temperatures),
            len(self.publisher.diagnostics),
        )

    def test_suspended_poll_and_step_have_no_effect_and_resume_normally(self):
        self.assertTrue(self.monitor.suspend_publication())
        before = self._state()

        self.assertIsNone(self.monitor.poll())
        self.assertIsNone(self.monitor.step(10, 60))
        self.assertEqual(self._state(), before)

        self.monitor.resume_publication()
        self.assertTrue(self.monitor.poll())
        self.assertEqual(self.monitor.sequence, 1)
        self.assertEqual(len(self.publisher.temperatures), 1)

        stepped = Monitor(
            FakeSensor(), FakePublisher(), FakeClock(), 'boot-2', 'device', '1.0'
        )
        self.assertTrue(stepped.step(10, 60))
        self.assertEqual(stepped.sequence, 1)

    def test_suspended_service_callback_does_not_cancel_transport(self):
        self.assertTrue(self.monitor.suspend_publication())
        callback_results = []

        def service():
            callback_results.append((self.monitor.poll(), self.monitor.step(10, 60)))
            return callback_results[-1][0] is False or callback_results[-1][1] is False

        class FakeTransport:
            def request(self, service_callback):
                cancelled = service_callback()
                return 'cancelled' if cancelled is True else 'completed'

        before = self._state()
        result = FakeTransport().request(service)

        self.assertEqual(callback_results, [(None, None)])
        self.assertEqual(result, 'completed')
        self.assertEqual(self._state(), before)

    def test_reentrant_poll_step_and_suspend_are_rejected_during_publish(self):
        results = []

        def callback():
            results.append((self.monitor.poll(), self.monitor.step(10, 60)))
            results.append(self.monitor.suspend_publication())

        self.publisher.on_temperature = callback
        self.assertTrue(self.monitor.poll())

        self.assertEqual(results, [(None, None), False])
        self.assertFalse(self.monitor._publication_suspended)
        self.assertEqual(self.sensor.reads, 1)
        self.assertEqual(self.monitor.sequence, 1)

    def test_suspend_attempt_during_old_publisher_patch_is_rejected_redacted(self):
        class PatchPublisher(FakePublisher):
            def publish_temperature(inner_self, payload):
                self.assertFalse(self.monitor.suspend_publication())
                raise RuntimeError('PATCH_PRIVATE_DETAIL')

        old = PatchPublisher()
        self.monitor.publisher = old
        try:
            result = self.monitor.poll()
        except Exception as error:
            formatted = ''.join(traceback.format_exception(
                type(error), error, error.__traceback__
            ))
            self.fail('publisher error escaped poll: ' + formatted)
        self.assertFalse(result)
        self.assertFalse(self.monitor._publication_suspended)
        self.assertEqual(len(old.temperatures), 0)
        self.assertEqual(self.monitor.sequence, 1)


if __name__ == '__main__':
    unittest.main()
