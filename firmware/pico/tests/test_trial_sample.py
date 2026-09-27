import unittest

from runtime import Monitor


class FakeClock:
    def __init__(self, values=None, modulus=None):
        self.now = 0
        self.values = list(values) if values is not None else None
        self.modulus = modulus

    def ticks_ms(self):
        if self.values is not None:
            value = self.values.pop(0)
            if isinstance(value, Exception):
                raise value
            return value
        return self.now % self.modulus if self.modulus else self.now

    def ticks_diff(self, current, previous):
        if not self.modulus:
            return current - previous
        half = self.modulus // 2
        return (current - previous + half) % self.modulus - half


class FakeSensor:
    def __init__(self, value=22.5, fail=False):
        self.value = value
        self.fail = fail
        self.reads = 0

    def read_celsius(self):
        self.reads += 1
        if self.fail:
            raise OSError('private sensor detail')
        return self.value


class FakePublisher:
    def __init__(self):
        self.temperatures = []
        self.diagnostics = []

    def publish_temperature(self, payload):
        self.temperatures.append(payload)

    def publish_diagnostics(self, payload):
        self.diagnostics.append(payload)


def monitor(clock=None, sensor=None, publisher=None):
    clock = clock or FakeClock()
    sensor = sensor or FakeSensor()
    publisher = publisher or FakePublisher()
    return Monitor(sensor, publisher, clock, 'boot-1', 'device', '1.0'), sensor, publisher


class TrialSampleTests(unittest.TestCase):
    def test_fresh_constant_samples_have_distinct_markers_without_publishing(self):
        clock = FakeClock()
        instance, sensor, publisher = monitor(clock=clock)
        first = instance.take_trial_sample()
        clock.now = 1
        second = instance.take_trial_sample()

        self.assertEqual(sensor.reads, 2)
        self.assertEqual(first.content.splitlines()[0], '22.50°C')
        self.assertEqual(first.marker, 'boot-1:1')
        self.assertEqual(second.marker, 'boot-1:2')
        self.assertEqual(first.content.splitlines()[-1], 'Sample: ' + first.marker)
        self.assertEqual(publisher.temperatures, [])
        self.assertEqual(publisher.diagnostics, [])
        self.assertIsNone(instance.diagnostics['sensor']['last_sample_ref'])

    def test_failed_read_has_no_content_and_does_not_reuse_previous_value(self):
        instance, sensor, _ = monitor()
        self.assertIsNotNone(instance.take_trial_sample())
        sensor.fail = True

        self.assertIsNone(instance.take_trial_sample())
        self.assertEqual(instance.sequence, 1)

    def test_tick_wrap_is_supported_and_bad_or_backward_elapsed_is_rejected(self):
        wrapped, _, _ = monitor(clock=FakeClock(values=[98, 2], modulus=100))
        sample = wrapped.take_trial_sample()
        self.assertIsNotNone(sample)
        self.assertEqual(sample.start_ms, 98)
        self.assertEqual(sample.completed_ms, 2)

        backward, _, _ = monitor(clock=FakeClock(values=[10, 9]))
        self.assertIsNone(backward.take_trial_sample())
        invalid, _, _ = monitor(clock=FakeClock(values=[10, 'bad']))
        self.assertIsNone(invalid.take_trial_sample())

    def test_published_reference_requires_explicit_current_sample_confirmation(self):
        instance, _, _ = monitor()
        sample = instance.take_trial_sample()
        self.assertIsNone(instance.diagnostics['sensor']['last_sample_ref'])
        self.assertTrue(instance.record_trial_sample_published(sample))
        self.assertEqual(instance.diagnostics['sensor']['last_sample_ref'], 'boot-1:1')

        stale = sample
        instance.take_trial_sample()
        self.assertFalse(instance.record_trial_sample_published(stale))
        self.assertEqual(instance.diagnostics['sensor']['last_sample_ref'], 'boot-1:1')

    def test_normal_poll_and_step_still_publish_through_existing_path(self):
        instance, _, publisher = monitor()
        self.assertTrue(instance.poll())
        self.assertEqual(len(publisher.temperatures), 1)

        stepped, _, step_publisher = monitor()
        self.assertTrue(stepped.step(10, 60))
        self.assertEqual(len(step_publisher.temperatures), 1)


if __name__ == '__main__':
    unittest.main()
