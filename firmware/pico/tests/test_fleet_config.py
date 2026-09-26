import io
import json
import unittest

from fleet_config import FleetConfigError, MAX_BYTES, parse_fleet


REVISION = '11111111-1111-4111-8111-111111111111'
CHANGE = '22222222-2222-4222-8222-222222222222'
READ = 'synthetic-read-placeholder'
WRITE = 'synthetic-write-placeholder'


def device(logical='monitor-a'):
    return {
        'change_id': CHANGE,
        'logical_id': logical,
        'wifi_profiles': [{'profile_id': 'primary', 'ssid': 'farm', 'password': 'synthetic-pass'}],
        'config_read_credential': READ,
        'temperature_gist_id': 'a' * 32,
        'diagnostics_gist_id': 'b' * 32,
        'gist_write_credential': WRITE,
        'sample_interval_seconds': 60,
        'publication_interval_seconds': 300,
    }


def fleet(devices=None):
    return {'schema_version': 1, 'fleet_revision': REVISION,
            'devices': devices if devices is not None else {'device-a': device()}}


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')


class Chunked(io.BytesIO):
    def __init__(self, value, maximum_return=37):
        super().__init__(value)
        self.maximum_return = maximum_return
        self.requests = []

    def read(self, size=-1):
        self.requests.append(size)
        return super().read(min(size, self.maximum_return))


class FleetConfigTests(unittest.TestCase):
    def parse(self, content, ref='device-a'):
        return parse_fleet(Chunked(content), ref)

    def assert_rejected(self, content, ref='device-a'):
        with self.assertRaises(FleetConfigError):
            self.parse(content, ref)

    def test_reads_candidate_and_only_exposes_immutable_addressed_device(self):
        config = self.parse(encoded(fleet({'device-a': device(), 'other': device('monitor-b')})))
        self.assertEqual(config.revision, REVISION)
        self.assertEqual(config.device.logical_id, 'monitor-a')
        self.assertEqual(config.device.wifi_profiles[0].password, 'synthetic-pass')
        with self.assertRaises(AttributeError):
            config.device.logical_id = 'changed'
        with self.assertRaises(AttributeError):
            config.revision = 'changed'

    def test_exact_semantically_populated_size_limit(self):
        devices = {}
        for index in range(16):
            entry = device('monitor-' + str(index))
            devices['device-' + str(index)] = entry
        value = fleet(devices)
        content = encoded(value)
        # Lengthen semantically meaningful credentials up to their schema caps.
        for entry in devices.values():
            if len(content) >= MAX_BYTES:
                break
            for key in ('config_read_credential', 'gist_write_credential'):
                room = 2048 - len(entry[key])
                increase = min(room, MAX_BYTES - len(content))
                entry[key] += 'x' * increase
                content = encoded(value)
                if len(content) == MAX_BYTES:
                    break
        self.assertEqual(len(content), MAX_BYTES)
        result = self.parse(content, 'device-0')
        self.assertEqual(result.device.logical_id, 'monitor-0')
        self.assert_rejected(content + b' ')

    def test_service_checkpoints_cover_maximum_file_with_bounded_progress(self):
        content = self._maximum_fleet()
        progress = []
        result = parse_fleet(
            Chunked(content, 1024), 'device-0', service=progress.append)
        self.assertEqual(result.device.logical_id, 'monitor-0')
        self.assertEqual(progress[0], 0)
        self.assertEqual(progress[-1], MAX_BYTES)
        self.assertGreater(len(progress), 10)
        self.assertTrue(all(0 <= current - previous <= 1024
                            for previous, current in zip(progress, progress[1:])))

    def _maximum_fleet(self):
        devices = {}
        for index in range(16):
            devices['device-' + str(index)] = device('monitor-' + str(index))
        value = fleet(devices)
        content = encoded(value)
        for entry in devices.values():
            for key in ('config_read_credential', 'gist_write_credential'):
                room = 2048 - len(entry[key])
                increase = min(room, MAX_BYTES - len(content))
                entry[key] += 'x' * increase
                content = encoded(value)
                if len(content) == MAX_BYTES:
                    return content
        self.fail('Unable to construct a maximum-size fleet configuration.')

    def test_service_abort_fails_closed_and_callback_error_is_redacted(self):
        content = encoded(fleet())

        def stop_after_read(progress):
            if progress:
                return False

        with self.assertRaises(FleetConfigError) as aborted:
            parse_fleet(Chunked(content), 'device-a', service=stop_after_read)
        self.assertIn('stopped', str(aborted.exception))

        def fail_with_sensitive_detail(progress):
            raise RuntimeError('credential-must-not-leak')

        with self.assertRaises(FleetConfigError) as caught:
            parse_fleet(Chunked(content), 'device-a', service=fail_with_sensitive_detail)
        self.assertNotIn('credential-must-not-leak', str(caught.exception))

    def test_service_does_not_change_malformed_file_rejection(self):
        checkpoints = []
        with self.assertRaises(FleetConfigError):
            parse_fleet(Chunked(encoded(fleet()) + b' false'), 'device-a',
                        service=checkpoints.append)
        self.assertGreater(len(checkpoints), 1)

    def test_utf8_multibyte_ssid_and_secrets_are_not_in_errors(self):
        value = fleet()
        value['devices']['device-a']['wifi_profiles'][0]['ssid'] = '農場🌱'
        result = self.parse(encoded(value))
        self.assertEqual(result.device.wifi_profiles[0].ssid, '農場🌱')
        bad_value = fleet()
        bad_value['devices']['device-a']['wifi_profiles'][0]['password'] = 'bad-secret-value' + 'x' * 50
        bad = encoded(bad_value)
        with self.assertRaises(FleetConfigError) as caught:
            self.parse(bad)
        self.assertNotIn('bad-secret-value', str(caught.exception))

    def test_decoded_duplicate_keys_at_root_device_and_credentials(self):
        self.assert_rejected(('{"schema_version":1,"fleet_revision":"%s",'
                              '"devices":{},"dev\\u0069ces":{}}' % REVISION).encode())
        self.assert_rejected(('{"schema_version":1,"fleet_revision":"%s",'
                              '"devices":{"device-a":{},"device\\u002da":{}}}' % REVISION).encode())
        content = encoded(fleet()).decode()
        original = '"config_read_credential":"%s"' % READ
        duplicate = '"config_read_credential":"%s","config_read_credential":"duplicate"' % READ
        content = content.replace(original, duplicate, 1)
        self.assert_rejected(content.encode())

    def test_duplicate_logical_id_in_non_addressed_device_is_rejected(self):
        self.assert_rejected(encoded(fleet({'device-a': device(), 'device-b': device()})))

    def test_malformed_tail_and_absent_addressed_device(self):
        self.assert_rejected(encoded(fleet()) + b' false')
        self.assert_rejected(encoded(fleet()), ref='not-present')

    def test_unknown_fields_in_addressed_and_non_addressed_devices_rejected(self):
        for ref in ('device-a', 'other'):
            value = fleet({'device-a': device(), 'other': device('monitor-b')})
            value['devices'][ref]['surprise'] = 'not-secret'
            self.assert_rejected(encoded(value))

    def test_schema_types_numeric_ranges_and_profile_ids_are_strict(self):
        cases = []
        value = fleet(); value['schema_version'] = True; cases.append(value)
        value = fleet(); value['devices']['device-a']['sample_interval_seconds'] = 60.0; cases.append(value)
        value = fleet(); value['devices']['device-a']['sample_interval_seconds'] = 9; cases.append(value)
        value = fleet(); value['devices']['device-a']['publication_interval_seconds'] = 301; cases.append(value)
        value = fleet(); value['devices']['device-a']['wifi_profiles'].append(
            dict(value['devices']['device-a']['wifi_profiles'][0])); cases.append(value)
        for value in cases:
            self.assert_rejected(encoded(value))

    def test_chunk_boundaries_and_utf8_validation(self):
        content = encoded(fleet())
        stream = Chunked(content, 1)
        self.assertEqual(parse_fleet(stream, 'device-a').device.logical_id, 'monitor-a')
        self.assertTrue(all(size <= 1024 for size in stream.requests))
        self.assert_rejected(content[:-1] + b'\xff}')

    def test_excessive_nesting_is_rejected(self):
        content = (b'{"schema_version":1,"fleet_revision":"' + REVISION.encode() +
                   b'","devices":{"device-a":' + b'[' * 8 + b'0' + b']' * 8 + b'}}')
        self.assert_rejected(content)


if __name__ == '__main__':
    unittest.main()
