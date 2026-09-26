import json
import unittest

from runtime import Monitor
from telemetry import (
    DIAGNOSTICS_FILENAME,
    HEARTBEAT_INTERVAL_MS,
    MAX_EVENTS,
    THERMOSTAT_FILENAME,
    diagnostics_payload,
    new_diagnostics,
    record_failure,
    record_sample,
    record_temperature_publish_failure,
    record_temperature_published,
    should_publish_diagnostics,
)


class FakeClock:
    def __init__(self, modulus=None):
        self.now = 0
        self.modulus = modulus

    def ticks_ms(self):
        return self.now % self.modulus if self.modulus else self.now

    def ticks_diff(self, current, previous):
        if not self.modulus:
            return current - previous
        half = self.modulus // 2
        return (current - previous + half) % self.modulus - half


class FakeSensor:
    def __init__(self, value=21.25):
        self.value = value
        self.fail = False

    def read_celsius(self):
        if self.fail:
            raise OSError('synthetic sensor failure')
        return self.value


class FakePublisher:
    def __init__(self):
        self.temperatures = []
        self.diagnostics = []
        self.fail_temperature = False
        self.return_false_temperature = False
        self.fail_diagnostics = False
        self.return_false_diagnostics = False
        self.diagnostic_attempts = 0

    def publish_temperature(self, payload):
        if self.fail_temperature:
            raise OSError('synthetic publish failure')
        if self.return_false_temperature:
            return False
        self.temperatures.append(payload)

    def publish_diagnostics(self, payload):
        self.diagnostic_attempts += 1
        if self.fail_diagnostics:
            raise OSError('synthetic diagnostics failure')
        if self.return_false_diagnostics:
            return False
        self.diagnostics.append(payload)


class TelemetryTests(unittest.TestCase):
    def test_constant_temperature_still_has_changing_sample_marker(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot-abc', 'opaque-01', '1.2.3')
        self.assertTrue(monitor.poll())
        self.assertTrue(monitor.poll())
        first = publisher.temperatures[0]['files'][THERMOSTAT_FILENAME]['content']
        second = publisher.temperatures[1]['files'][THERMOSTAT_FILENAME]['content']
        self.assertEqual(first.splitlines()[0], '21.25°C')
        self.assertEqual(first.splitlines()[1], 'Sample: boot-abc:1')
        self.assertEqual(second.splitlines()[1], 'Sample: boot-abc:2')
        self.assertNotEqual(first, second)

    def test_failed_sample_does_not_publish_stale_temperature(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot-abc', 'opaque-01', '1.2.3')
        monitor.poll()
        sensor.fail = True
        self.assertFalse(monitor.poll())
        self.assertEqual(len(publisher.temperatures), 1)
        snapshot = json.loads(publisher.diagnostics[-1]['files'][DIAGNOSTICS_FILENAME]['content'])
        self.assertEqual(snapshot['sensor']['state'], 'error')
        self.assertEqual(snapshot['sensor']['consecutive_failures'], 1)
        self.assertEqual(snapshot['sensor']['last_sample_ref'], 'boot-abc:1')

    def test_diagnostics_are_independent_redacted_snapshot(self):
        snapshot = new_diagnostics('boot-id', 'device-ref', '1.2.3')
        temperature = record_sample(snapshot, 42.125, 'boot-id', 1, 100)
        record_temperature_published(snapshot, 'boot-id', 1)
        record_failure(snapshot, 200)
        temperature['files'][THERMOSTAT_FILENAME]['content'] = 'edited separately'
        encoded = diagnostics_payload(snapshot)['files'][DIAGNOSTICS_FILENAME]['content']
        result = json.loads(encoded)
        self.assertEqual(result['schema_version'], 1)
        self.assertEqual(result['sensor']['last_sample_ref'], 'boot-id:1')
        self.assertNotIn('42.125', encoded)
        self.assertNotIn('edited separately', encoded)
        self.assertEqual(result['reported_at'], None)
        self.assertEqual(result['firmware']['running'], '1.2.3')
        self.assertEqual(result['configuration'], {'applied_id': None, 'last_attempt': None})
        self.assertEqual(set(result['events'][0]), {'id', 'code', 'count', 'occurred_at', 'uptime_s'})
        self.assertEqual(result['events'][0]['id'], 'boot-id:1')

    def test_diagnostics_heartbeat_and_bounded_transition_events(self):
        snapshot = new_diagnostics('boot', 'opaque-id', '0.0.1')
        self.assertTrue(should_publish_diagnostics(snapshot, 0, None))
        self.assertFalse(should_publish_diagnostics(snapshot, 10, 0))
        self.assertTrue(should_publish_diagnostics(snapshot, HEARTBEAT_INTERVAL_MS, 0))
        for at_ms in range(10):
            record_failure(snapshot, at_ms)
        self.assertEqual(len(snapshot['events']), 1)
        self.assertEqual(snapshot['events'][0]['count'], 10)
        for at_ms in range(MAX_EVENTS + 20):
            if at_ms % 2:
                record_failure(snapshot, at_ms)
            else:
                record_sample(snapshot, 20, 'boot', at_ms + 1, at_ms + 1)
        self.assertLessEqual(len(snapshot['events']), MAX_EVENTS)

    def test_device_reference_is_required_and_opaque_value_is_preserved(self):
        with self.assertRaises(ValueError):
            new_diagnostics('boot', '', '1.0')
        snapshot = new_diagnostics('boot', 'opaque-provisioned-id', '1.0')
        self.assertEqual(snapshot['device_ref'], 'opaque-provisioned-id')

    def test_boot_id_event_identity_is_stable_across_reboot_and_coalescing(self):
        old_snapshot = new_diagnostics('boot-before-reboot', 'device', '1.0')
        record_failure(old_snapshot, 1)
        original_id = old_snapshot['events'][0]['id']
        record_failure(old_snapshot, 2)
        self.assertEqual(old_snapshot['events'][0]['id'], original_id)
        self.assertEqual(old_snapshot['events'][0]['count'], 2)
        new_snapshot = new_diagnostics('boot-after-reboot', 'device', '1.0')
        record_failure(new_snapshot, 3)
        self.assertNotEqual(new_snapshot['events'][0]['id'], original_id)
        self.assertEqual(original_id, 'boot-before-reboot:1')

    def test_boot_id_device_ref_and_version_bounds_are_enforced(self):
        for boot, device, version in (
                ('', 'device', '1.0'), ('unsafe:boot', 'device', '1.0'),
                ('b' * 65, 'device', '1.0'), ('boot', 'd' * 65, '1.0'),
                ('boot', 'device', 'v' * 33)):
            with self.subTest(boot=boot, device=device):
                with self.assertRaises(ValueError):
                    new_diagnostics(boot, device, version)

    def test_failed_temperature_put_does_not_advance_last_sample_or_fail_sensor(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        publisher.fail_temperature = True
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        self.assertFalse(monitor.poll())
        self.assertEqual(monitor.diagnostics['sensor']['state'], 'ok')
        self.assertEqual(monitor.diagnostics['sensor']['consecutive_failures'], 0)
        self.assertIsNone(monitor.diagnostics['sensor']['last_sample_ref'])
        self.assertEqual(monitor.diagnostics['events'][-1]['code'], 'temperature_publish_failed')
        self.assertEqual(publisher.temperatures, [])
        publisher.fail_temperature = False
        publisher.return_false_temperature = True
        self.assertFalse(monitor.poll())
        self.assertEqual(monitor.diagnostics['sensor']['last_sample_ref'], None)
        self.assertEqual(monitor.diagnostics['events'][-1]['count'], 2)

    def test_non_finite_and_out_of_range_samples_are_rejected(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(float('nan')), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        self.assertFalse(monitor.poll())
        self.assertEqual(publisher.temperatures, [])
        self.assertIsNone(monitor.diagnostics['sensor']['last_sample_ref'])
        sensor.value = float('inf')
        self.assertFalse(monitor.poll())
        sensor.value = 126
        self.assertFalse(monitor.poll())

    def test_tick_wrap_does_not_break_five_minute_heartbeat(self):
        clock = FakeClock(modulus=1000000)
        clock.now = 900000
        sensor, publisher = FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        self.assertTrue(monitor.poll())
        clock.now += HEARTBEAT_INTERVAL_MS - 1
        self.assertTrue(monitor.poll())
        self.assertEqual(len(publisher.diagnostics), 1)
        clock.now += 1
        self.assertTrue(monitor.poll())
        self.assertEqual(len(publisher.diagnostics), 2)

    def test_diagnostics_failure_does_not_interrupt_valid_temperature(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        publisher.fail_diagnostics = True
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        self.assertTrue(monitor.poll())
        self.assertEqual(len(publisher.temperatures), 1)
        self.assertEqual(monitor.diagnostics['sensor']['last_sample_ref'], 'boot:1')

        publisher.fail_diagnostics = False
        publisher.return_false_diagnostics = True
        self.assertTrue(monitor.poll())
        self.assertEqual(len(publisher.temperatures), 2)
        self.assertEqual(publisher.diagnostic_attempts, 2)
        self.assertEqual(monitor.last_report_ms, None)


if __name__ == '__main__':
    unittest.main()
