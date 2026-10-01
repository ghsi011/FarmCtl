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
    record_config_applied,
    record_config_attempt,
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
        self.reads = 0

    def read_celsius(self):
        self.reads += 1
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
    def test_step_samples_at_ten_seconds_and_publishes_only_at_sixty(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        self.assertTrue(monitor.step(10, 60))
        self.assertEqual(sensor.reads, 1)
        self.assertEqual(len(publisher.temperatures), 1)
        for second in range(1, 60):
            clock.now = second * 1000
            self.assertTrue(monitor.step(10, 60))
            self.assertEqual(len(publisher.temperatures), 1)
        self.assertEqual(sensor.reads, 6)
        clock.now = 60000
        self.assertTrue(monitor.step(10, 60))
        self.assertEqual(sensor.reads, 7)
        self.assertEqual(len(publisher.temperatures), 2)
        self.assertEqual(
            publisher.temperatures[-1]['files'][THERMOSTAT_FILENAME]['content'].splitlines()[1],
            'Sample: boot:7')

    def test_step_uses_fresh_sample_at_300_second_publication(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        self.assertTrue(monitor.step(60, 300))
        for minute in range(1, 5):
            clock.now = minute * 60000
            self.assertTrue(monitor.step(60, 300))
        self.assertEqual(len(publisher.temperatures), 1)
        clock.now = 300000
        self.assertTrue(monitor.step(60, 300))
        self.assertEqual(len(publisher.temperatures), 2)
        self.assertEqual(sensor.reads, 6)

    def test_step_does_not_write_temperature_on_nonpublication_sample(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        monitor.step(10, 60)
        clock.now = 10000
        self.assertTrue(monitor.step(10, 60))
        self.assertEqual(sensor.reads, 2)
        self.assertEqual(len(publisher.temperatures), 1)
        self.assertEqual(monitor.sequence, 2)

    def test_step_sensor_failure_at_publication_never_refreshes_temperature(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        monitor.step(10, 60)
        clock.now = 60000
        sensor.fail = True
        self.assertFalse(monitor.step(10, 60))
        self.assertEqual(len(publisher.temperatures), 1)
        self.assertEqual(monitor.sequence, 1)
        self.assertEqual(monitor.diagnostics['sensor']['state'], 'error')

    def test_step_diagnostics_transition_is_independent_of_temperature_publication(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        monitor.step(10, 60)
        sensor.fail = True
        clock.now = 10000
        self.assertFalse(monitor.step(10, 60))
        self.assertEqual(len(publisher.temperatures), 1)
        self.assertEqual(len(publisher.diagnostics), 2)

    def test_step_heartbeat_at_300_seconds_while_sample_and_publication_are_not_due(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')

        self.assertTrue(monitor.step(299, 299))
        self.assertEqual(monitor.last_report_ms, 0)
        self.assertEqual(len(publisher.diagnostics), 1)
        clock.now = 299000
        self.assertTrue(monitor.step(299, 299))
        self.assertEqual(sensor.reads, 2)
        self.assertEqual(len(publisher.temperatures), 2)

        clock.now = 299999
        self.assertTrue(monitor.step(299, 299))
        self.assertEqual(monitor.last_report_ms, 0)
        self.assertEqual(len(publisher.diagnostics), 1)
        self.assertEqual(sensor.reads, 2)
        self.assertEqual(len(publisher.temperatures), 2)

        clock.now = 300000
        self.assertTrue(monitor.step(299, 299))
        self.assertEqual(monitor.last_report_ms, 300000)
        self.assertEqual(len(publisher.diagnostics), 2)
        self.assertEqual(sensor.reads, 2)
        self.assertEqual(len(publisher.temperatures), 2)
        heartbeat_sequences = [
            json.loads(item['files'][DIAGNOSTICS_FILENAME]['content'])['heartbeat_seq']
            for item in publisher.diagnostics
        ]
        self.assertEqual(heartbeat_sequences, [1, 2])

    def test_failed_sensor_heartbeat_waits_300_seconds_without_stale_publication(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        sensor.fail = True
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')

        self.assertFalse(monitor.step(299, 299))
        self.assertEqual(monitor.last_report_ms, 0)
        self.assertEqual(len(publisher.diagnostics), 1)
        initial_diagnostics = json.loads(
            publisher.diagnostics[0]['files'][DIAGNOSTICS_FILENAME]['content']
        )
        self.assertEqual(initial_diagnostics['heartbeat_seq'], 1)
        self.assertEqual(initial_diagnostics['sensor']['state'], 'error')
        self.assertEqual(publisher.temperatures, [])
        self.assertEqual(monitor.diagnostics['sensor']['state'], 'error')

        clock.now = 299000
        self.assertFalse(monitor.step(299, 299))
        self.assertEqual(sensor.reads, 2)
        self.assertEqual(len(publisher.diagnostics), 1)
        self.assertEqual(publisher.temperatures, [])

        clock.now = 299999
        self.assertTrue(monitor.step(299, 299))
        self.assertEqual(monitor.last_report_ms, 0)
        self.assertEqual(len(publisher.diagnostics), 1)
        self.assertEqual(sensor.reads, 2)
        self.assertEqual(publisher.temperatures, [])

        clock.now = 300000
        self.assertTrue(monitor.step(299, 299))
        self.assertEqual(monitor.last_report_ms, 300000)
        self.assertEqual(len(publisher.diagnostics), 2)
        self.assertEqual(sensor.reads, 2)
        self.assertEqual(publisher.temperatures, [])
        heartbeat_sequences = [
            json.loads(item['files'][DIAGNOSTICS_FILENAME]['content'])['heartbeat_seq']
            for item in publisher.diagnostics
        ]
        self.assertEqual(heartbeat_sequences, [1, 2])
        self.assertEqual(monitor.diagnostics['sensor']['state'], 'error')
        self.assertEqual(monitor.diagnostics['sensor']['consecutive_failures'], 2)

    def test_step_failed_patch_retries_with_new_sample_after_sample_interval(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        monitor.step(10, 60)
        publisher.fail_temperature = True
        clock.now = 60000
        self.assertFalse(monitor.step(10, 60))
        self.assertEqual(sensor.reads, 2)
        publisher.fail_temperature = False
        sensor.value = 22.5
        clock.now = 69999
        self.assertTrue(monitor.step(10, 60))
        self.assertEqual(sensor.reads, 2)
        clock.now = 70000
        self.assertTrue(monitor.step(10, 60))
        self.assertEqual(sensor.reads, 3)
        content = publisher.temperatures[-1]['files'][THERMOSTAT_FILENAME]['content']
        self.assertEqual(content.splitlines(), ['22.50°C', 'Sample: boot:3'])

    def test_step_tick_wrap_and_backwards_clock_fail_closed(self):
        clock = FakeClock(modulus=100000)
        clock.now = 90000
        sensor, publisher = FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        self.assertTrue(monitor.step(10, 60))
        clock.now += 10000
        self.assertTrue(monitor.step(10, 60))
        self.assertEqual(sensor.reads, 2)
        clock.now -= 1000
        self.assertFalse(monitor.step(10, 60))
        self.assertEqual(sensor.reads, 2)
        self.assertEqual(len(publisher.temperatures), 1)

    def test_step_rejects_invalid_intervals_including_boolean(self):
        clock, sensor, publisher = FakeClock(), FakeSensor(), FakePublisher()
        monitor = Monitor(sensor, publisher, clock, 'boot', 'opaque', '1.0')
        for sample, publication in (
                (True, 60), (9, 60), (301, 300), (10, False),
                (10, 59), (10, 301), (61, 60), (10.0, 60)):
            with self.subTest(sample=sample, publication=publication):
                with self.assertRaises(ValueError):
                    monitor.step(sample, publication)
        self.assertEqual(sensor.reads, 0)

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
        self.assertIsNone(result['firmware']['retained_good'])
        self.assertIsNone(result['firmware']['running_config_schema'])
        self.assertIsNone(result['firmware']['retained_config_schema'])
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

    def test_optional_qualified_firmware_capabilities_are_reported(self):
        snapshot = new_diagnostics(
            'boot', 'device', '1.0', retained_good='1.0.0',
            running_config_schema=1, retained_config_schema=1)
        self.assertEqual(snapshot['firmware']['retained_good'], '1.0.0')
        self.assertEqual(snapshot['firmware']['running_config_schema'], 1)
        self.assertEqual(snapshot['firmware']['retained_config_schema'], 1)

    def test_config_attempt_correlates_uuid_ids_and_rejection_preserves_applied(self):
        snapshot = new_diagnostics('boot', 'device', '1.0')
        previous_applied = '11111111-1111-4111-8111-111111111111'
        change_id = '22222222-2222-4222-8222-222222222222'
        revision = '33333333-3333-4333-8333-333333333333'
        snapshot['configuration']['applied_id'] = previous_applied
        record_config_attempt(snapshot, revision, change_id, 'rejected', 'invalid_config')
        self.assertEqual(snapshot['configuration']['applied_id'], previous_applied)
        self.assertEqual(snapshot['configuration']['last_attempt'], {
            'fleet_revision': revision, 'change_id': change_id,
            'state': 'rejected', 'reason': 'invalid_config',
        })

    def test_config_applied_records_exact_ids_and_rollback_preserves_applied(self):
        snapshot = new_diagnostics('boot', 'device', '1.0')
        revision = '33333333-3333-4333-8333-333333333333'
        change_id = '22222222-2222-4222-8222-222222222222'
        rollback_id = '44444444-4444-4444-8444-444444444444'
        record_config_applied(snapshot, revision, change_id)
        self.assertEqual(snapshot['configuration']['applied_id'], change_id)
        self.assertEqual(snapshot['configuration']['last_attempt'], {
            'fleet_revision': revision, 'change_id': change_id,
            'state': 'applied', 'reason': None,
        })
        record_config_attempt(snapshot, revision, rollback_id, 'rolled_back', 'trial_failed')
        self.assertEqual(snapshot['configuration']['applied_id'], change_id)
        self.assertEqual(snapshot['configuration']['last_attempt']['change_id'], rollback_id)

    def test_config_attempt_rejects_missing_or_malformed_uuid_without_echoing_input(self):
        snapshot = new_diagnostics('boot', 'device', '1.0')
        valid = '22222222-2222-4222-8222-222222222222'
        invalid_values = (None, '', 'not-a-uuid', 'password-secret')
        for invalid in invalid_values:
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError) as raised:
                    record_config_attempt(snapshot, invalid, valid, 'received')
                if invalid:
                    self.assertNotIn(str(invalid), str(raised.exception))
        with self.assertRaises(ValueError):
            record_config_attempt(snapshot, valid, valid, 'received', 'ssid-secret')
        for invalid_uuid in (
                '22222222-2222-0222-8222-222222222222',
                '22222222-2222-4222-7222-222222222222'):
            with self.subTest(invalid_uuid=invalid_uuid):
                with self.assertRaises(ValueError):
                    record_config_attempt(snapshot, invalid_uuid, valid, 'received')
        self.assertIsNone(snapshot['configuration']['last_attempt'])

    def test_inconclusive_rollback_is_distinct_and_applied_requires_confirmed_helper(self):
        snapshot = new_diagnostics('boot', 'device', '1.0')
        revision = '33333333-3333-4333-8333-333333333333'
        change_id = '22222222-2222-4222-8222-222222222222'
        record_config_attempt(snapshot, revision, change_id, 'rolled_back', 'inconclusive')
        self.assertEqual(snapshot['configuration']['last_attempt']['reason'], 'inconclusive')
        record_config_attempt(snapshot, revision, change_id, 'rolled_back', 'trial_failed')
        self.assertEqual(snapshot['configuration']['last_attempt']['reason'], 'trial_failed')
        self.assertIsNone(snapshot['configuration']['applied_id'])
        with self.assertRaises(ValueError):
            record_config_attempt(snapshot, revision, change_id, 'applied')
        self.assertEqual(snapshot['configuration']['last_attempt']['reason'], 'trial_failed')

    def test_config_diagnostics_contain_only_allowlisted_redacted_values(self):
        snapshot = new_diagnostics('boot', 'device', '1.0')
        revision = '33333333-3333-4333-8333-333333333333'
        change_id = '22222222-2222-4222-8222-222222222222'
        record_config_attempt(snapshot, revision, change_id, 'rejected', 'unsupported_schema')
        encoded = diagnostics_payload(snapshot)['files'][DIAGNOSTICS_FILENAME]['content']
        for secret_marker in ('password', 'ssid', 'token', 'gist-credential'):
            self.assertNotIn(secret_marker, encoded.lower())
        self.assertEqual(json.loads(encoded)['configuration']['last_attempt']['change_id'], change_id)

    def test_unknown_retained_good_and_schema_keep_config_capability_disabled(self):
        snapshot = new_diagnostics('boot', 'device', '1.0')
        firmware = snapshot['firmware']
        self.assertIsNone(firmware['retained_good'])
        self.assertIsNone(firmware['running_config_schema'])
        self.assertIsNone(firmware['retained_config_schema'])

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
