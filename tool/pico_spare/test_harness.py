import contextlib
import hashlib
import importlib.util
import io
import json
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


HARNESS_PATH = Path(__file__).with_name('harness.py')
SPEC = importlib.util.spec_from_file_location('pico_spare_harness', HARNESS_PATH)
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


class FakePipe:
    def __init__(self, data=b'', release=None):
        self.data = bytearray(data)
        self.release = release
        self.closed = False

    def read(self, size):
        if self.data:
            chunk = bytes(self.data[:size])
            del self.data[:size]
            return chunk
        if self.release is not None:
            self.release.wait()
        return b''

    def close(self):
        self.closed = True
        if self.release is not None:
            self.release.set()


class FakeProcess:
    def __init__(self, stdout=b'', stderr=b'', returncode=0, running=False,
                 kill_releases=True, wait_times_out=False):
        self.returncode = None if running else returncode
        self.killed = False
        self.waited = False
        self.kill_releases = kill_releases
        self.wait_times_out = wait_times_out
        self.release = threading.Event()
        self.stdout = FakePipe(stdout, self.release if running else None)
        self.stderr = FakePipe(stderr, self.release if running else None)

    def poll(self):
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = -9
        if self.kill_releases:
            self.release.set()

    def wait(self, timeout=None):
        self.waited = True
        if self.wait_times_out:
            raise subprocess.TimeoutExpired('fake-process', timeout)
        if self.returncode is None:
            self.kill()
        return self.returncode


def valid_inventory():
    return {
        'schema_version': 1,
        'purpose': 'authorized_spare',
        'uid_sha256': 'a' * 64,
        'board': 'RPI_PICO2_W',
        'runtime': 'v1.29.0',
        'authorization_reference': 'CHANGE-123',
    }


def valid_v2_inventory():
    data = valid_inventory()
    data.update({
        'schema_version': 2,
        'expected_uname_machine': 'synthetic-machine',
        'expected_uname_release': 'synthetic-release',
    })
    return data


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

    def test_v2_preflight_remains_offline(self):
        self.write(valid_v2_inventory())
        with mock.patch.object(subprocess, 'Popen', side_effect=AssertionError('spawn')):
            result, output, errors = self.run_cli(
                'preflight', '--inventory', str(self.inventory), '--port', 'COM12'
            )
        self.assertEqual((result, output, errors), (0, 'OFFLINE_PREFLIGHT_PASS\n', ''))

    def test_v2_uname_fields_require_printable_ascii_bounds(self):
        for value in ('', 'x' * 257, 'x\n', 'é'):
            data = valid_v2_inventory()
            data['expected_uname_machine'] = value
            self.write(data)
            self.assert_blocked('preflight', '--inventory', str(self.inventory), '--port', 'COM1')

    def test_probe_gates_before_subprocess(self):
        with mock.patch.object(subprocess, 'Popen') as popen:
            for args in (
                ('probe', '--inventory', str(self.inventory), '--port', 'COM4', '--ack-interruption'),
            ):
                self.assert_blocked(*args)
            self.write(valid_v2_inventory())
            for args in (
                ('probe', '--inventory', str(self.inventory), '--port', 'COM4'),
                ('probe', '--inventory', str(self.inventory), '--port', 'com4', '--ack-interruption'),
                ('probe', '--inventory', str(self.inventory), '--port', 'COM0', '--ack-interruption'),
            ):
                self.assert_blocked(*args)
            popen.assert_not_called()

    def test_probe_success_uses_fixed_argv_timeout_and_full_digest(self):
        raw_uid = bytes.fromhex('0011223344556677')
        data = valid_v2_inventory()
        data['uid_sha256'] = hashlib.sha256(raw_uid).hexdigest()
        self.write(data)
        stdout = 'PICO_SPARE_IDENTITY:' + json.dumps({
            'uid_hex': raw_uid.hex(),
            'uname_machine': data['expected_uname_machine'],
            'uname_release': data['expected_uname_release'],
        }) + '\n'
        process = FakeProcess(stdout.encode())
        with mock.patch.object(subprocess, 'Popen', return_value=process) as popen:
            result, output, errors = self.run_cli(
                'probe', '--inventory', str(self.inventory), '--port', 'COM7', '--ack-interruption'
            )
        self.assertEqual((result, output, errors), (0, 'IDENTITY_MATCH\n', ''))
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)
        args, kwargs = popen.call_args
        self.assertEqual(args[0][:4], ['mpremote', 'connect', 'port:COM7', 'resume'])
        self.assertEqual(args[0][4], 'exec')
        self.assertEqual(args[0][5], harness._FIXED_CODE)
        self.assertNotIn('--no-follow', args[0])
        self.assertEqual(kwargs, {
            'shell': False, 'stdin': subprocess.DEVNULL,
            'stdout': subprocess.PIPE, 'stderr': subprocess.PIPE,
        })
        self.assertEqual(harness._PROBE_TIMEOUT, 10)

    def test_reader_error_during_final_poll_cannot_return_identity_match(self):
        data = valid_v2_inventory()
        raw_uid = bytes.fromhex('00112233')
        data['uid_sha256'] = hashlib.sha256(raw_uid).hexdigest()
        self.write(data)
        identity = b'PICO_SPARE_IDENTITY:' + json.dumps({
            'uid_hex': raw_uid.hex(),
            'uname_machine': data['expected_uname_machine'],
            'uname_release': data['expected_uname_release'],
        }).encode() + b'\n'
        fail_reader = threading.Event()
        reader_failed = threading.Event()

        class FailingPipe(FakePipe):
            def read(self, size):
                fail_reader.wait()
                reader_failed.set()
                raise OSError('SECRET_READER_ERROR')

        class PollTriggersReaderFailure(FakeProcess):
            def __init__(self):
                super().__init__(stdout=identity)
                self.stderr = FailingPipe()

            def poll(self):
                fail_reader.set()
                self.assert_reader_failed()
                return 0

            @staticmethod
            def assert_reader_failed():
                if not reader_failed.wait(1):
                    raise AssertionError('reader did not fail')

        process = PollTriggersReaderFailure()
        with mock.patch.object(subprocess, 'Popen', return_value=process):
            self.assert_probe_blocked(forbidden='SECRET')

    def test_read_bounded_prefers_partial_read1(self):
        class Read1OnlyPipe:
            def read(self, size):
                raise AssertionError('read must not be used when read1 is available')

            def read1(self, size):
                return b'x' * min(size, harness._MAX_CAPTURE + 1)

        captured, overflowed = harness._read_bounded(Read1OnlyPipe())
        self.assertTrue(overflowed)
        self.assertEqual(len(captured), harness._MAX_CAPTURE + 1)

    def test_probe_rejects_mismatch_bad_output_and_process_errors_without_disclosure(self):
        data = valid_v2_inventory()
        self.write(data)
        good = {
            'uid_hex': '00112233',
            'uname_machine': data['expected_uname_machine'],
            'uname_release': data['expected_uname_release'],
        }
        data['uid_sha256'] = hashlib.sha256(bytes.fromhex(good['uid_hex'])).hexdigest()
        self.write(data)
        invalid_outputs = [
            'SENSITIVE_SENTINEL',
            'banner\n' + 'PICO_SPARE_IDENTITY:' + json.dumps(good),
            'PICO_SPARE_IDENTITY:' + json.dumps(good) + '\npost-query noise',
            '\nPICO_SPARE_IDENTITY:' + json.dumps(good),
            'PICO_SPARE_IDENTITY:' + json.dumps(good) + '\n\n',
            'PICO_SPARE_IDENTITY:' + json.dumps(good) + '\nSENSITIVE_SENTINEL',
            'PICO_SPARE_IDENTITY:' + json.dumps(good) + '\t',
            'PICO_SPARE_IDENTITY:{bad json}\n',
            'PICO_SPARE_IDENTITY:{"uid_hex":"00112233","uid_hex":"00112233",'
            '"uname_machine":"synthetic-machine","uname_release":"synthetic-release"}',
            'PICO_SPARE_IDENTITY:' + json.dumps(good) + '\nPICO_SPARE_IDENTITY:' + json.dumps(good),
            'PICO_SPARE_IDENTITY:' + json.dumps(dict(good, extra='x')),
            'PICO_SPARE_IDENTITY:' + json.dumps(dict(good, uid_hex='0011')),
            'PICO_SPARE_IDENTITY:' + json.dumps(dict(good, uid_hex='00112234')),
            'PICO_SPARE_IDENTITY:' + json.dumps(dict(good, uid_hex='0011223')),
            'PICO_SPARE_IDENTITY:' + json.dumps(dict(good, uname_machine='different')),
            'PICO_SPARE_IDENTITY:' + json.dumps(dict(good, uname_release='different')),
            'x' * 4097,
        ]
        for stdout in invalid_outputs:
            with self.subTest(stdout=stdout[:40]), mock.patch.object(
                subprocess, 'Popen', return_value=FakeProcess(stdout.encode())
            ):
                self.assert_probe_blocked()
        for process in (
            FakeProcess(b'SENSITIVE_SENTINEL', returncode=1),
            FakeProcess(b'PICO_SPARE_IDENTITY:' + json.dumps(good).encode(), b'SECRET_STDERR'),
        ):
            with mock.patch.object(subprocess, 'Popen', return_value=process):
                self.assert_probe_blocked()
        for error in (OSError('SECRET_EXCEPTION'),):
            with mock.patch.object(subprocess, 'Popen', side_effect=error):
                self.assert_probe_blocked(forbidden='SECRET')

    def test_probe_bounds_both_streams_and_kills_on_timeout(self):
        data = valid_v2_inventory()
        uid_hex = '00112233'
        data['uid_sha256'] = hashlib.sha256(bytes.fromhex(uid_hex)).hexdigest()
        self.write(data)
        identity = 'PICO_SPARE_IDENTITY:' + json.dumps({
            'uid_hex': uid_hex,
            'uname_machine': data['expected_uname_machine'],
            'uname_release': data['expected_uname_release'],
        })
        for stream in ('stdout', 'stderr'):
            output = (identity if stream == 'stdout' else '')
            secret_overflow = b'x' * (harness._MAX_CAPTURE + 1024)
            process = FakeProcess(
                stdout=output.encode() + (secret_overflow if stream == 'stdout' else b''),
                stderr=secret_overflow if stream == 'stderr' else b'',
                running=True,
            )
            with self.subTest(stream=stream), mock.patch.object(
                subprocess, 'Popen', return_value=process
            ):
                self.assert_probe_blocked(forbidden='x' * 20)
                self.assertTrue(process.killed)
                self.assertTrue(process.waited)

        silent = FakeProcess(running=True)
        with mock.patch.object(harness, '_PROBE_TIMEOUT', 0.05), mock.patch.object(
            subprocess, 'Popen', return_value=silent
        ):
            self.assert_probe_blocked()
        self.assertTrue(silent.killed)
        self.assertTrue(silent.waited)

        secret_timeout = FakeProcess(
            stdout=b'SECRET_TIMEOUT_OUTPUT',
            stderr=b'SECRET_TIMEOUT_STDERR',
            running=True,
        )
        with mock.patch.object(harness, '_PROBE_TIMEOUT', 0.05), mock.patch.object(
            subprocess, 'Popen', return_value=secret_timeout
        ):
            self.assert_probe_blocked(forbidden='SECRET_TIMEOUT')
        self.assertTrue(secret_timeout.killed)
        self.assertTrue(secret_timeout.waited)

    def test_unreleased_readers_and_unreaped_child_have_bounded_cleanup(self):
        self.write(valid_v2_inventory())
        process = FakeProcess(running=True, kill_releases=False, wait_times_out=True)
        with mock.patch.object(harness, '_PROBE_TIMEOUT', 0.02), mock.patch.object(
            harness, '_CLEANUP_GRACE', 0.05
        ), mock.patch.object(subprocess, 'Popen', return_value=process):
            start = harness.time.monotonic()
            self.assert_probe_blocked(forbidden='SECRET')
            elapsed = harness.time.monotonic() - start

        self.assertLess(elapsed, 0.5)
        self.assertTrue(process.killed)
        self.assertTrue(process.waited)
        # An active reader's pipe must not be closed (which can block acquiring
        # BufferedReader's lock). Release the test doubles so no test thread lingers.
        self.assertFalse(process.stdout.release.is_set())
        self.assertFalse(process.stdout.closed)
        self.assertFalse(process.stderr.closed)
        process.release.set()

    def test_each_pipe_capture_is_limited_to_cap_plus_one(self):
        for stream_name in ('stdout', 'stderr'):
            with self.subTest(stream=stream_name):
                capture, overflowed = harness._read_bounded(
                    io.BytesIO(b'x' * (harness._MAX_CAPTURE + 2048))
                )
                self.assertTrue(overflowed)
                self.assertEqual(len(capture), harness._MAX_CAPTURE + 1)

    def assert_probe_blocked(self, forbidden=None):
        self.assert_blocked('probe', '--inventory', str(self.inventory), '--port', 'COM4',
                            '--ack-interruption', forbidden=forbidden)

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
