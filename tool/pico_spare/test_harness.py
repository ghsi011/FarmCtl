import contextlib
import importlib.util
import io
import json
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HARNESS_PATH = Path(__file__).with_name('harness.py')
SPEC = importlib.util.spec_from_file_location('pico_spare_harness', HARNESS_PATH)
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


def valid_inventory():
    return {
        'schema_version': 1,
        'purpose': 'authorized_spare',
        'uid_sha256': 'a' * 64,
        'board': 'RPI_PICO2_W',
        'runtime': 'v1.29.0',
        'authorization_reference': 'ISSUE-43',
    }


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.inventory = Path(self.temp.name) / 'inventory.json'
        self.write(valid_inventory())

    def tearDown(self):
        self.temp.cleanup()

    def write(self, contents):
        if isinstance(contents, bytes):
            self.inventory.write_bytes(contents)
        else:
            self.inventory.write_text(json.dumps(contents), encoding='utf-8')

    def run_cli(self, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = harness.main(list(arguments))
        return result, output.getvalue(), errors.getvalue()

    def test_valid_offline_preflight(self):
        result, output, errors = self.run_cli('preflight', '--inventory', str(self.inventory), '--port', 'COM12')
        self.assertEqual((result, output, errors), (0, 'OFFLINE_PREFLIGHT_PASS\n', ''))

    def test_digest_formats_are_rejected(self):
        for digest in ('a' * 16, 'A' * 64, 'g' * 64, ''):
            data = valid_inventory()
            data['uid_sha256'] = digest
            self.write(data)
            self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM1')
        data = valid_inventory()
        del data['uid_sha256']
        self.write(data)
        self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM1')

    def test_inventory_schema_and_required_values(self):
        for key, value in (('board', 'RPI_PICO_W'), ('runtime', 'v1.28.0'),
                           ('purpose', 'authorized'), ('authorization_reference', 'gist-abc')):
            data = valid_inventory()
            data[key] = value
            self.write(data)
            self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM1')
        data = valid_inventory()
        data['password'] = 'SENSITIVE_SENTINEL'
        self.write(data)
        self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM1',
                            forbidden='SENSITIVE_SENTINEL')

    def test_duplicate_keys_and_oversized_file(self):
        self.write(b'{"schema_version":1,"schema_version":1}')
        self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM1')
        self.write(b' ' * 4097)
        self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM1')

    def test_repository_local_missing_and_symlink_paths(self):
        self.assert_blocked('preflight', '--inventory', str(HARNESS_PATH), '--port', 'COM1')
        self.assert_blocked('preflight', '--inventory', str(self.inventory / 'missing'), '--port', 'COM1')
        link = Path(self.temp.name) / 'link.json'
        try:
            link.symlink_to(self.inventory)
        except (OSError, NotImplementedError):
            return
        self.assert_blocked('preflight', '--inventory', str(link), '--port', 'COM1')

    def test_ports_and_actions_are_explicit(self):
        for port in ('', 'com4', 'COM0', 'COM4*', 'COM4/path', 'tcp://host', 'auto'):
            self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', port)
        self.assert_blocked('preflight', '--inventory', str(self.inventory))
        self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM4', '--probe')
        self.assert_blocked('probe', '--inventory', str(self.inventory), '--port', 'COM4')

    def test_no_process_or_network_calls(self):
        def forbidden(*args, **kwargs):
            raise AssertionError('process/network call')

        with mock.patch.object(subprocess, 'Popen', forbidden), mock.patch.object(subprocess, 'run', forbidden), \
             mock.patch.object(socket.socket, 'connect', forbidden):
            self.assertEqual(harness.main(['--help']), 0)
            self.assertEqual(harness.main(['preflight', '--inventory', str(self.inventory), '--port', 'COM4']), 0)
            self.assertEqual(harness.main(['preflight', '--inventory', str(self.inventory), '--port', 'COM0']), 1)

    def test_failure_does_not_disclose_content_or_exception(self):
        self.write(b'SENSITIVE_SENTINEL')
        self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM4',
                            forbidden='SENSITIVE_SENTINEL')
        with mock.patch.object(Path, 'open', side_effect=OSError('SENSITIVE_SENTINEL')):
            self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM4',
                                forbidden='SENSITIVE_SENTINEL')

    def assert_blocked(self, *arguments, forbidden=None):
        result, output, errors = self.run_cli(*arguments)
        self.assertNotEqual(result, 0)
        self.assertEqual(output, '')
        self.assertEqual(errors, 'BLOCKED\n')
        if forbidden:
            self.assertNotIn(forbidden, output + errors)


if __name__ == '__main__':
    unittest.main()
