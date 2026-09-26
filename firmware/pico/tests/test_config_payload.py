import hashlib
import io
import json
import unittest

import config_payload
from config_payload import (ConfigPayloadError, extract_device_payload,
                            read_device_payload, write_owned_payload)


REVISION = '11111111-1111-4111-8111-111111111111'
CHANGE = '22222222-2222-4222-8222-222222222222'


def device(logical='monitor-a', credential='read-secret', write='write-secret'):
    return {
        'change_id': CHANGE, 'logical_id': logical,
        'wifi_profiles': [{'profile_id': 'primary', 'ssid': 'farm',
                           'password': 'synthetic-pass'}],
        'config_read_credential': credential,
        'temperature_gist_id': 'a' * 32, 'diagnostics_gist_id': 'b' * 32,
        'gist_write_credential': write,
        'sample_interval_seconds': 60, 'publication_interval_seconds': 300,
    }


def encoded(value):
    return json.dumps(value, separators=(',', ':')).encode('utf-8')


def fleet(devices):
    return {'schema_version': 1, 'fleet_revision': REVISION, 'devices': devices}


class MemoryHandle:
    def __init__(self, fs, path, mode, fail=None):
        self.fs, self.path, self.mode, self.fail = fs, path, mode, fail
        self.position = 0
        if mode == 'xb':
            if path in fs.files:
                raise OSError('collision')
            fs.files[path] = bytearray()

    def write(self, block):
        if self.fail == 'write':
            raise OSError('PRIVATE_PAYLOAD_SECRET')
        if self.fail == 'partial':
            self.fs.files[self.path].extend(block[:1])
            return 1
        self.fs.files[self.path].extend(block)
        return len(block)

    def flush(self):
        if self.fail in ('flush', 'remove'):
            raise OSError('PRIVATE_PAYLOAD_SECRET')

    def close(self):
        if self.fail == 'close':
            raise OSError('PRIVATE_PAYLOAD_SECRET')
        if self.mode == 'xb':
            data = self.fs.files[self.path]
            if self.fail == 'corrupt' and data:
                data[0] ^= 1
            elif self.fail == 'length' and data:
                data.pop()
            elif self.fail == 'extra':
                data.append(0)

    def read(self, size=-1):
        if self.fail == 'read':
            raise OSError('PRIVATE_PAYLOAD_SECRET')
        data = self.fs.files[self.path]
        if size < 0:
            size = len(data) - self.position
        part = bytes(data[self.position:self.position + size])
        self.position += len(part)
        return part

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()


class MemoryFS:
    def __init__(self):
        self.files = {}
        self.fail = None

    def open(self, path, mode):
        if mode == 'rb' and self.fail == 'reopen':
            raise OSError('PRIVATE_PAYLOAD_SECRET')
        return MemoryHandle(self, path, mode, self.fail)

    def remove(self, path):
        if self.fail == 'remove':
            raise OSError('PRIVATE_REMOVE_SECRET')
        self.files.pop(path, None)


class ConfigPayloadTests(unittest.TestCase):
    def test_maximum_fleet_excludes_unrelated_device_secret(self):
        devices = {'device-' + str(index): device('monitor-' + str(index))
                   for index in range(16)}
        devices['device-1']['config_read_credential'] = 'UNRELATED_PASSWORD_MUST_NOT_LEAK'
        devices['device-1']['gist_write_credential'] = 'OTHER_WRITE_SECRET'
        target = devices['device-0']
        target['config_read_credential'] = 'r' * 2048
        target['gist_write_credential'] = 'w' * 2048
        content = encoded(fleet(devices))
        # Fill valid credential fields without changing the addressed section
        # until the complete fleet is exactly at its parser limit.
        for index in range(1, 16):
            entry = devices['device-' + str(index)]
            for key in ('config_read_credential', 'gist_write_credential'):
                room = 2048 - len(entry[key])
                increase = min(room, 65536 - len(content))
                entry[key] += 'x' * increase
                content = encoded(fleet(devices))
                if len(content) == 65536:
                    break
            if len(content) == 65536:
                break
        self.assertEqual(len(content), 65536)
        payload, revision, change_id = extract_device_payload(io.BytesIO(content), 'device-0')
        self.assertLessEqual(len(payload), 8192)
        self.assertEqual((revision, change_id), (REVISION, CHANGE))
        self.assertNotIn(b'UNRELATED_PASSWORD_MUST_NOT_LEAK', payload)
        self.assertNotIn(b'OTHER_WRITE_SECRET', payload)
        self.assertEqual(read_device_payload(payload, 'device-0').device.logical_id, 'monitor-0')

    def test_maximum_addressed_credentials_fit_payload_bound(self):
        config = device(credential='r' * 2048, write='w' * 2048)
        payload, _, _ = extract_device_payload(io.BytesIO(encoded(fleet({'device-a': config}))), 'device-a')
        self.assertLessEqual(len(payload), 8192)
        self.assertEqual(read_device_payload(payload, 'device-a').device.config_read_credential,
                         'r' * 2048)

    def test_worst_case_escaped_fields_extract_read_and_owned_write(self):
        config = device(credential='"' * 2048, write='\\' * 2048)
        config['wifi_profiles'] = [
            {'profile_id': 'p' * 32, 'ssid': '"\\' * 16,
             'password': ('"\\' * 31) + '"'},
            {'profile_id': 'q' * 32, 'ssid': '\\"' * 16,
             'password': ('\\"' * 31) + '\\'},
            {'profile_id': 'r' * 32, 'ssid': '"' * 32,
             'password': '\\' * 63},
        ]
        other = device('monitor-other', 'UNRELATED_DEVICE_SECRET', 'OTHER_SECRET')
        source = encoded(fleet({'device-a': config, 'device-b': other}))
        payload, _, _ = extract_device_payload(io.BytesIO(source), 'device-a')
        self.assertLessEqual(len(payload), config_payload.MAX_PAYLOAD_BYTES)
        self.assertGreater(len(payload), 8192)
        self.assertNotIn(b'UNRELATED_DEVICE_SECRET', payload)
        self.assertNotIn(b'OTHER_SECRET', payload)
        parsed = read_device_payload(payload, 'device-a')
        self.assertEqual(parsed.device.config_read_credential, '"' * 2048)
        self.assertEqual(parsed.device.gist_write_credential, '\\' * 2048)
        self.assertEqual(len(parsed.device.wifi_profiles), 3)

        fs = MemoryFS()
        original_open, original_os = getattr(config_payload, 'open', None), config_payload.os
        config_payload.open = fs.open
        config_payload.os = type('PosixShim', (), {'remove': staticmethod(fs.remove)})
        try:
            name, length, digest = write_owned_payload(
                '/trusted', payload, lambda count: b'\x04' * count)
        finally:
            if original_open is None:
                del config_payload.open
            else:
                config_payload.open = original_open
            config_payload.os = original_os
        self.assertEqual(length, len(payload))
        self.assertEqual(digest, hashlib.sha256(payload).digest().hex())
        self.assertEqual(bytes(fs.files['/trusted/' + name]), payload)

    def test_malformed_tail_duplicate_unknown_and_reference_mismatch_rejected(self):
        source = encoded(fleet({'device-a': device()}))
        with self.assertRaises(ConfigPayloadError):
            extract_device_payload(io.BytesIO(source + b' trailing'), 'device-a')
        with self.assertRaises(ConfigPayloadError):
            read_device_payload(b'{"schema_version":1,"schema_version":1}', 'device-a')
        payload, _, _ = extract_device_payload(io.BytesIO(source), 'device-a')
        value = json.loads(payload.decode('utf-8'))
        value['untrusted'] = 'x'
        with self.assertRaises(ConfigPayloadError):
            read_device_payload(encoded(value), 'device-a')
        with self.assertRaises(ConfigPayloadError):
            read_device_payload(payload, 'other-device')
        with self.assertRaises(ConfigPayloadError):
            read_device_payload(payload[:-1], 'device-a')
        with self.assertRaises(ConfigPayloadError):
            read_device_payload(payload[:-1] + b'\xff', 'device-a')

    def test_owned_write_collision_digest_blocking_and_no_os_path_dependency(self):
        payload, _, _ = extract_device_payload(io.BytesIO(encoded(fleet({'device-a': device()}))), 'device-a')
        fs = MemoryFS()
        fs.files['/trusted/config-' + '01' * 12 + '.json'] = bytearray(b'keep')
        real_open, real_os = getattr(config_payload, 'open', None), config_payload.os
        config_payload.open = fs.open
        config_payload.os = type('PosixShim', (), {'remove': staticmethod(fs.remove)})
        entropy = iter([b'\x01' * 12, b'\x02' * 12])
        try:
            name, length, digest = write_owned_payload('/trusted', payload, lambda count: next(entropy))
        finally:
            if real_open is None:
                del config_payload.open
            else:
                config_payload.open = real_open
            config_payload.os = real_os
        self.assertEqual(name, 'config-' + '02' * 12 + '.json')
        self.assertEqual(length, len(payload))
        self.assertEqual(digest, hashlib.sha256(payload).digest().hex())
        self.assertEqual(fs.files['/trusted/config-' + '01' * 12 + '.json'], bytearray(b'keep'))
        self.assertEqual(bytes(fs.files['/trusted/' + name]), payload)

    def test_write_failures_remove_only_created_file_and_redact_traceback(self):
        secret = 'PRIVATE_PAYLOAD_SECRET'
        payload, _, _ = extract_device_payload(io.BytesIO(encoded(fleet({'device-a': device(secret, secret)}))), 'device-a')
        for failure in ('write', 'partial', 'flush', 'close', 'reopen', 'read',
                        'corrupt', 'length', 'extra', 'remove'):
            fs = MemoryFS()
            fs.fail = failure
            original_open, original_os = getattr(config_payload, 'open', None), config_payload.os
            config_payload.open = fs.open
            config_payload.os = type('PosixShim', (), {'remove': staticmethod(fs.remove)})
            try:
                try:
                    write_owned_payload('/trusted', payload, lambda count: b'\x03' * count)
                    self.fail('expected write failure')
                except ConfigPayloadError as error:
                    rendered = ''.join(__import__('traceback').format_exception(error))
                    self.assertNotIn(secret, rendered)
                    self.assertNotIn('PRIVATE_REMOVE_SECRET', rendered)
                if failure != 'remove':
                    self.assertEqual(fs.files, {})
                else:
                    self.assertTrue(fs.files)
            finally:
                if original_open is None:
                    del config_payload.open
                else:
                    config_payload.open = original_open
                config_payload.os = original_os

    def test_collision_exhaustion_preserves_preexisting_file(self):
        payload, _, _ = extract_device_payload(
            io.BytesIO(encoded(fleet({'device-a': device()}))), 'device-a')
        fs = MemoryFS()
        collision_path = '/trusted/config-' + '05' * 12 + '.json'
        fs.files[collision_path] = bytearray(b'preexisting')
        original_open, original_os = getattr(config_payload, 'open', None), config_payload.os
        config_payload.open = fs.open
        config_payload.os = type('PosixShim', (), {'remove': staticmethod(fs.remove)})
        try:
            with self.assertRaises(ConfigPayloadError):
                write_owned_payload('/trusted', payload, lambda count: b'\x05' * count)
        finally:
            if original_open is None:
                del config_payload.open
            else:
                config_payload.open = original_open
            config_payload.os = original_os
        self.assertEqual(fs.files, {collision_path: bytearray(b'preexisting')})


if __name__ == '__main__':
    unittest.main()
