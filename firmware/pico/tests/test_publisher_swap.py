import unittest
import traceback

from runtime import Monitor


class FakeClock:
    def __init__(self):
        self.now = 0

    def ticks_ms(self):
        return self.now

    def ticks_diff(self, current, previous):
        return current - previous


class FakeSensor:
    def __init__(self):
        self.value = 20.0

    def read_celsius(self):
        return self.value


class FakePublisher:
    def __init__(self, token=b'old-secret', fail_close=False):
        self.token = bytearray(token)
        self.fail_close = fail_close
        self.temperatures = []
        self.diagnostics = []
        self.closed = False

    def publish_temperature(self, payload):
        self.temperatures.append(payload)

    def publish_diagnostics(self, payload):
        self.diagnostics.append(payload)

    def close(self):
        self.closed = True
        if self.fail_close:
            raise RuntimeError('SYNTHETIC_SECRET')
        for index in range(len(self.token)):
            self.token[index] = 0


class PublisherSwapTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.sensor = FakeSensor()
        self.old = FakePublisher()
        self.monitor = Monitor(
            self.sensor, self.old, self.clock, 'boot-1', 'device', '1.0'
        )

    def test_swap_scrubs_old_writer_and_preserves_monitor_state(self):
        self.assertTrue(self.monitor.poll())
        self.assertIn('Sample: boot-1:1',
                      self.old.temperatures[0]['files']['thermostat.txt']['content'])
        diagnostics = self.monitor.diagnostics
        events = diagnostics['events']
        event_contents = [dict(event) for event in events]
        sequence = self.monitor.sequence
        boot_id = self.monitor.boot_id
        report_ms = self.monitor.last_report_ms

        new = FakePublisher(b'new-secret')
        self.monitor.replace_publisher(new)
        self.assertTrue(self.old.closed)
        self.assertEqual(self.old.token, bytearray(len(self.old.token)))
        self.assertIs(self.monitor.publisher, new)

        self.sensor.value = 21.5
        self.clock.now = 300000
        self.assertTrue(self.monitor.poll())
        content = new.temperatures[0]['files']['thermostat.txt']['content']
        self.assertEqual(content, '21.50°C\nSample: boot-1:2')
        self.assertEqual(len(self.old.temperatures), 1)
        self.assertEqual(len(new.diagnostics), 1)
        self.assertIs(self.monitor.diagnostics, diagnostics)
        self.assertIs(self.monitor.diagnostics['events'], events)
        self.assertEqual(events, event_contents)
        self.assertEqual(self.monitor.sequence, sequence + 1)
        self.assertEqual(self.monitor.boot_id, boot_id)
        self.assertEqual(report_ms, 0)

    def test_invalid_or_same_publisher_does_not_replace_active_writer(self):
        class InvalidPublisher:
            def publish_temperature(self, payload):
                pass

            def publish_diagnostics(self, payload):
                pass

        for candidate in (self.old, InvalidPublisher(), object()):
            with self.assertRaisesRegex(ValueError, '^invalid publisher replacement$'):
                self.monitor.replace_publisher(candidate)
            self.assertIs(self.monitor.publisher, self.old)

        self.assertTrue(self.monitor.poll())
        self.assertEqual(len(self.old.temperatures), 1)

    def test_old_close_failure_is_redacted_and_new_publisher_stays_active(self):
        self.old.fail_close = True
        new = FakePublisher(b'candidate-secret')
        diagnostics = self.monitor.diagnostics
        sequence = self.monitor.sequence

        with self.assertRaisesRegex(RuntimeError, '^previous publisher could not be closed$') as caught:
            self.monitor.replace_publisher(new)

        formatted = ''.join(traceback.format_exception(
            type(caught.exception), caught.exception, caught.exception.__traceback__
        ))
        self.assertNotIn('SYNTHETIC_SECRET', formatted)
        self.assertIs(self.monitor.publisher, new)
        self.assertIs(self.monitor.diagnostics, diagnostics)
        self.assertEqual(self.monitor.sequence, sequence)
        self.sensor.value = 22.0
        self.assertTrue(self.monitor.poll())
        self.assertEqual(len(new.temperatures), 1)
        self.assertEqual(self.old.temperatures, [])

    def test_getattr_failure_is_redacted_from_full_traceback(self):
        class MaliciousPublisher:
            def __getattribute__(self, name):
                if name == 'publish_temperature':
                    raise RuntimeError('SYNTHETIC_SECRET')
                return object.__getattribute__(self, name)

        diagnostics = self.monitor.diagnostics
        sequence = self.monitor.sequence
        candidate = MaliciousPublisher()

        with self.assertRaisesRegex(ValueError, '^invalid publisher replacement$') as caught:
            self.monitor.replace_publisher(candidate)

        formatted = ''.join(traceback.format_exception(
            type(caught.exception), caught.exception, caught.exception.__traceback__
        ))
        self.assertNotIn('SYNTHETIC_SECRET', formatted)
        self.assertIs(self.monitor.publisher, self.old)
        self.assertIs(self.monitor.diagnostics, diagnostics)
        self.assertEqual(self.monitor.sequence, sequence)


if __name__ == '__main__':
    unittest.main()
