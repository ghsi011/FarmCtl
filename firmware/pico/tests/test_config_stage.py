import hashlib
import io
import json
import os
import builtins
from pathlib import Path
import sys
import tempfile
import traceback
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import config_stage
from config_payload import extract_device_payload, write_owned_payload
import config_payload
from config_trial import ConfigTrialStore
from private_fleet_client import PrivateFleetClient


DEVICE = '123e4567-e89b-42d3-a456-426614174000'
CHANGE_1 = '123e4567-e89b-42d3-a456-426614174001'
CHANGE_2 = '123e4567-e89b-42d3-a456-426614174002'
REV_1 = '223e4567-e89b-42d3-a456-426614174001'
REV_2 = '223e4567-e89b-42d3-a456-426614174002'
OTHER_SECRET = 'OTHER_DEVICE_SYNTHETIC_TOKEN_93bf'


def device(change_id, secret='target-secret', logical='monitor-a'):
    return {
        'change_id': change_id, 'logical_id': logical,
        'wifi_profiles': [{'profile_id': 'primary', 'ssid': 'farm',
                           'password': 'wifi-secret'}],
        'config_read_credential': secret,
        'temperature_gist_id': 'a' * 32, 'diagnostics_gist_id': 'b' * 32,
        'gist_write_credential': 'write-secret',
        'sample_interval_seconds': 60, 'publication_interval_seconds': 300,
    }


def fleet(revision, target_change, extra=False, tail=b'', device_ref=DEVICE):
    devices = {device_ref: device(target_change)}
    if extra:
        devices['323e4567-e89b-42d3-a456-426614174000'] = device(
            CHANGE_1, OTHER_SECRET, 'monitor-other')
    return json.dumps({'schema_version': 1, 'fleet_revision': revision,
                       'devices': devices}, separators=(',', ':')).encode() + tail


class FakePrivateClient(PrivateFleetClient):
    def __init__(self, stage_directory, contents):
        self.stage_directory = stage_directory
        self.contents = contents
        self.calls = 0
        self.claim_override = None
        self.path_override = None
        self.fail = False

    def fetch_to_stage(self, service=None):
        self.calls += 1
        if self.fail:
            raise RuntimeError('private credential token leaked if chained')
        path = self.stage_directory + '/fleet-stage.json'
        with open(path, 'wb') as handle:
            handle.write(self.contents)
            handle.flush()
        claim = (len(self.contents), hashlib.sha256(self.contents).hexdigest())
        returned_path = self.path_override if self.path_override is not None else path
        return returned_path, self.claim_override if self.claim_override is not None else claim


class ConfigStageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name.replace('\\', '/')
        self.payload_dir = self.root + '/payloads'
        self.stage_dir = self.root + '/stage'
        os.mkdir(self.payload_dir)
        os.mkdir(self.stage_dir)
        directory_patch = mock.patch.object(config_payload, '_validate_directory',
                                            lambda unused: None)
        directory_patch.start()
        self.addCleanup(directory_patch.stop)
        # Host-only adaptation: production payload directories remain POSIX-only.
        stage_directory_patch = mock.patch.object(
            config_stage, '_trusted_directory', lambda directory: directory.rstrip('/\\'))
        stage_directory_patch.start()
        self.addCleanup(stage_directory_patch.stop)
        baseline, _, _ = extract_device_payload(io.BytesIO(fleet(REV_1, CHANGE_1)), DEVICE)
        (name, count, digest) = write_owned_payload(self.payload_dir, baseline,
                                                    lambda size: b'\x11' * size)
        self.applied_name = name
        self.store = ConfigTrialStore(self.root)
        self.store.initialize(name, count, digest, REV_1, CHANGE_1, DEVICE, True)
        self.client = FakePrivateClient(self.stage_dir,
                                        fleet(REV_2, CHANGE_2, extra=True))
        self.coordinator = self.make_coordinator()

    def tearDown(self):
        self.temp.cleanup()

    def make_coordinator(self):
        return config_stage.ConfigStageCoordinator(
            self.store, self.client, self.payload_dir, DEVICE,
            lambda size: b'\x22' * size)

    def payload_files(self):
        return sorted(os.listdir(self.payload_dir))

    def test_new_change_is_staged_without_changing_applied(self):
        old_applied = list(self.store.state['applied'])
        result = self.coordinator.stage_latest()
        self.assertEqual(self.store.state['status'], 'staged')
        self.assertEqual(result, self.store.state['candidate'])
        self.assertNotEqual(result[0], self.applied_name)
        self.assertEqual(self.store.state['applied'], old_applied)
        with open(self.payload_dir + '/' + result[0], 'rb') as handle:
            payload = handle.read()
        self.assertNotIn(OTHER_SECRET.encode(), payload)
        self.assertNotIn(OTHER_SECRET, str(self.store.state))
        self.assertEqual(os.listdir(self.stage_dir), [])

    def test_same_change_id_new_revision_is_skipped(self):
        self.client.contents = fleet(REV_2, CHANGE_1)
        before = self.payload_files()
        self.assertIsNone(self.coordinator.stage_latest())
        self.assertEqual(self.store.state['status'], 'ready')
        self.assertEqual(self.payload_files(), before)
        self.assertEqual(os.listdir(self.stage_dir), [])

    def test_unowned_returned_paths_are_never_removed(self):
        for kind in ('wrong_absolute', 'traversal', 'applied'):
            with self.subTest(kind=kind):
                self.tearDown()
                self.setUp()
                if kind == 'wrong_absolute':
                    returned_path = '/payloads/applied.json'
                elif kind == 'traversal':
                    returned_path = self.stage_dir + '/../payloads/' + self.applied_name
                else:
                    returned_path = self.payload_dir + '/' + self.applied_name
                self.client.path_override = returned_path
                with open(self.payload_dir + '/' + self.applied_name, 'rb') as handle:
                    original_applied = handle.read()
                real_remove = os.remove
                with mock.patch.object(config_stage.os, 'remove', wraps=real_remove) as remove:
                    with self.assertRaises(config_stage.ConfigStageError) as raised:
                        self.coordinator.stage_latest()
                remove.assert_not_called()
                with open(self.payload_dir + '/' + self.applied_name, 'rb') as handle:
                    self.assertEqual(handle.read(), original_applied)
                self.assertEqual(self.store.state['status'], 'ready')
                rendered = ''.join(traceback.format_exception(raised.exception))
                self.assertNotIn(returned_path, rendered)
                self.assertNotIn(OTHER_SECRET, rendered)

    def test_identical_stage_and_payload_directories_are_rejected(self):
        with self.assertRaises(ValueError):
            config_stage.ConfigStageCoordinator(
                self.store, self.client, self.stage_dir, DEVICE, lambda size: b'\x22' * size)
        self.assertEqual(self.client.calls, 0)

    def test_reservation_failure_creates_no_candidate_payload(self):
        with mock.patch.object(self.store, 'begin_received', side_effect=OSError('private token')):
            with self.assertRaises(config_stage.ConfigStageError) as raised:
                self.coordinator.stage_latest()
        self.assertEqual(self.payload_files(), [self.applied_name])
        self.assertNotIn('private token', ''.join(traceback.format_exception(raised.exception)))

    def test_invalid_applied_payload_fails_closed_before_network(self):
        for case in ('missing', 'truncated', 'digest', 'identity'):
            with self.subTest(case=case):
                self.tearDown()
                self.setUp()
                applied_path = self.payload_dir + '/' + self.applied_name
                with open(applied_path, 'rb') as handle:
                    original = handle.read()
                if case == 'missing':
                    os.remove(applied_path)
                elif case == 'truncated':
                    with open(applied_path, 'wb') as handle:
                        handle.write(original[:8])
                elif case == 'digest':
                    with open(applied_path, 'wb') as handle:
                        handle.write(original + b'corruption')
                else:
                    replacement, _, _ = extract_device_payload(
                        io.BytesIO(fleet(REV_2, CHANGE_2)), DEVICE)
                    with open(applied_path, 'wb') as handle:
                        handle.write(replacement)
                    self.store.state['applied'][1] = len(replacement)
                    self.store.state['applied'][2] = hashlib.sha256(
                        replacement).hexdigest()
                before = json.loads(json.dumps(self.store.state))
                with self.assertRaises(config_stage.AppliedConfigInvalid) as raised:
                    self.coordinator.stage_latest()
                self.assertEqual(str(raised.exception),
                                 'Applied configuration requires recovery.')
                self.assertEqual(self.client.calls, 0)
                self.assertEqual(self.store.state, before)
                rendered = ''.join(traceback.format_exception(raised.exception))
                self.assertNotIn(self.root, rendered)
                self.assertNotIn('target-secret', rendered)
                self.assertNotIn('wifi-secret', rendered)
                self.assertNotIn(OTHER_SECRET, rendered)

    def test_candidate_corruption_is_not_applied_config_invalid(self):
        self.client.contents = b'not a valid fleet payload'
        with self.assertRaises(config_stage.ConfigStageError) as raised:
            self.coordinator.stage_latest()
        self.assertNotIsInstance(raised.exception, config_stage.AppliedConfigInvalid)

    def test_pending_or_invalidated_store_fails_before_network(self):
        for status in ('received', 'staged', 'trial'):
            with self.subTest(status=status):
                self.store.state['status'] = status
                old_applied = list(self.store.state['applied'])
                with self.assertRaises(config_stage.ConfigStageError):
                    self.coordinator.stage_latest()
                self.assertEqual(self.client.calls, 0)
                self.assertEqual(self.store.state['applied'], old_applied)
                self.assertEqual(os.listdir(self.stage_dir), [])
        self.store.state = None
        with self.assertRaises(config_stage.ConfigStageError):
            self.coordinator.stage_latest()
        self.assertEqual(self.client.calls, 0)
        self.assertEqual(os.listdir(self.stage_dir), [])

    def test_test_capability_flag_does_not_bypass_private_client_type(self):
        class ArbitraryFake:
            CONFIG_STAGE_TEST_CAPABILITY = True
            stage_directory = 'unused'

            def fetch_to_stage(self, service=None):
                raise AssertionError('must not fetch')

        with self.assertRaises(ValueError):
            config_stage.ConfigStageCoordinator(
                self.store, ArbitraryFake(), self.payload_dir, DEVICE,
                lambda size: b'\x33' * size)
        self.assertEqual(self.client.calls, 0)

    def test_opaque_device_reference_stages_with_test_only_windows_path_adapter(self):
        opaque = 'device-a'
        opaque_directory = self.payload_dir + '/opaque'
        opaque_stage = self.stage_dir + '/opaque'
        os.mkdir(opaque_directory)
        os.mkdir(opaque_stage)
        os.mkdir(self.root + '/opaque-metadata')
        baseline, _, _ = extract_device_payload(
            io.BytesIO(fleet(REV_1, CHANGE_1, device_ref=opaque)), opaque)
        name, count, digest = write_owned_payload(
            opaque_directory, baseline, lambda size: b'\x44' * size)
        store = ConfigTrialStore(self.root + '/opaque-metadata')
        store.initialize(name, count, digest, REV_1, CHANGE_1, opaque, True)
        client = FakePrivateClient(
            opaque_stage, fleet(REV_2, CHANGE_2, device_ref=opaque))
        coordinator = config_stage.ConfigStageCoordinator(
            store, client, opaque_directory, opaque, lambda size: b'\x55' * size)
        self.assertEqual(coordinator.stage_latest(), store.state['candidate'])
        self.assertEqual(store.state['status'], 'staged')
        self.assertEqual(os.listdir(opaque_stage), [])

    def test_bad_full_stage_metadata_or_content_never_reserves(self):
        cases = ('count', 'digest', 'malformed_tail', 'duplicate', 'wrong_reference')
        for case in cases:
            with self.subTest(case=case):
                self.tearDown()
                self.setUp()
                if case == 'count':
                    self.client.claim_override = (1, hashlib.sha256(self.client.contents).hexdigest())
                elif case == 'digest':
                    self.client.claim_override = (len(self.client.contents), '0' * 64)
                elif case == 'malformed_tail':
                    self.client.contents += b' trailing'
                elif case == 'duplicate':
                    self.client.contents = (b'{"schema_version":1,"schema_version":1}'
                                            + b' ' * 0)
                else:
                    self.client.contents = fleet(REV_2, CHANGE_2).replace(
                        DEVICE.encode(), b'wrong-device')
                with self.assertRaises(config_stage.ConfigStageError):
                    self.coordinator.stage_latest()
                self.assertEqual(self.store.state['status'], 'ready')
                self.assertEqual(self.payload_files(), [self.applied_name])
                self.assertEqual(os.listdir(self.stage_dir), [])

    def test_write_failure_and_cleanup_failure_reject_reserved_change(self):
        real_remove = os.remove
        real_open = builtins.open

        class ShortWriter:
            def __init__(self, handle):
                self.handle = handle

            def write(self, block):
                self.handle.write(block[:1])
                return 1

            def __getattr__(self, name):
                return getattr(self.handle, name)

        def fail_owned_write(path, mode='r', *args, **kwargs):
            handle = real_open(path, mode, *args, **kwargs)
            if mode == 'xb' and str(path).startswith(self.payload_dir + '/'):
                return ShortWriter(handle)
            return handle

        def fail_scratch_remove(path):
            if path.startswith(self.stage_dir + '/'):
                raise OSError(OTHER_SECRET)
            return real_remove(path)

        with mock.patch('builtins.open', side_effect=fail_owned_write):
            with mock.patch.object(config_stage.os, 'remove', side_effect=fail_scratch_remove):
                try:
                    self.coordinator.stage_latest()
                    self.fail('expected failure')
                except config_stage.ConfigStageError as error:
                    rendered = ''.join(traceback.format_exception(error))
                    self.assertNotIn(OTHER_SECRET, rendered)
        self.assertEqual(self.store.state['status'], 'rejected')
        self.assertEqual(self.store.state['reason'], 'storage_error')
        self.assertIn(CHANGE_2, self.store.state['consumed'])
        self.assertEqual(self.store.state['applied'][0], self.applied_name)
        self.assertTrue(os.path.exists(self.stage_dir + '/fleet-stage.json'))

    def test_owned_write_failure_rejects_reserved_change_and_keeps_applied(self):
        with mock.patch.object(config_stage, 'write_owned_payload',
                               side_effect=RuntimeError('payload secret')):
            with self.assertRaises(config_stage.ConfigStageError):
                self.coordinator.stage_latest()
        self.assertEqual(self.store.state['status'], 'rejected')
        self.assertEqual(self.store.state['reason'], 'storage_error')
        self.assertIn(CHANGE_2, self.store.state['consumed'])
        self.assertEqual(self.store.state['applied'][0], self.applied_name)

    def test_post_write_verification_failures_remove_only_owned_payload(self):
        real_verify = config_stage._verify_file
        for failure in ('digest', 'io', 'parse'):
            with self.subTest(failure=failure):
                self.tearDown()
                self.setUp()
                if failure == 'digest':
                    def fail_verify(path, maximum):
                        result = real_verify(path, maximum)
                        if (path.startswith(self.payload_dir + '/config-')
                                and not path.endswith('/' + self.applied_name)):
                            return result[0], '0' * 64
                        return result
                    patcher = mock.patch.object(config_stage, '_verify_file',
                                                side_effect=fail_verify)
                elif failure == 'io':
                    def fail_owned_io(path, maximum):
                        if (path.startswith(self.payload_dir + '/config-')
                                and not path.endswith('/' + self.applied_name)):
                            raise OSError(OTHER_SECRET)
                        return real_verify(path, maximum)
                    patcher = mock.patch.object(config_stage, '_verify_file',
                                                side_effect=fail_owned_io)
                else:
                    real_parse = config_stage.read_device_payload
                    calls = 0
                    def fail_owned_parse(payload, device_ref):
                        nonlocal calls
                        calls += 1
                        if calls == 2:
                            raise ValueError(OTHER_SECRET)
                        return real_parse(payload, device_ref)
                    patcher = mock.patch.object(config_stage, 'read_device_payload',
                                                side_effect=fail_owned_parse)
                with patcher:
                    with self.assertRaises(config_stage.ConfigStageError) as raised:
                        self.coordinator.stage_latest()
                self.assertEqual(self.store.state['status'], 'rejected')
                self.assertEqual(self.payload_files(), [self.applied_name])
                self.assertEqual(os.listdir(self.stage_dir), [])
                rendered = ''.join(traceback.format_exception(raised.exception))
                self.assertNotIn(OTHER_SECRET, rendered)

    def test_owned_cleanup_works_without_os_path(self):
        self.client.contents = self.client.contents.replace(
            b'target-secret', OTHER_SECRET.encode())
        real_verify = config_stage._verify_file
        def fail_owned_verify(path, maximum):
            result = real_verify(path, maximum)
            if (path.startswith(self.payload_dir + '/config-')
                    and not path.endswith('/' + self.applied_name)):
                return result[0], '0' * 64
            return result
        with mock.patch.object(config_stage, '_verify_file', side_effect=fail_owned_verify):
            with mock.patch.object(config_stage.os, 'path', None):
                with self.assertRaises(config_stage.ConfigStageError):
                    self.coordinator.stage_latest()
        self.assertEqual(self.payload_files(), [self.applied_name])
        self.assertEqual(os.listdir(self.stage_dir), [])
        with open(self.payload_dir + '/' + self.applied_name, 'rb') as handle:
            self.assertNotIn(OTHER_SECRET.encode(), handle.read())

    @unittest.skipUnless(hasattr(os, 'symlink'), 'host symlink support required')
    def test_owned_cleanup_rejects_symlink_without_touching_target(self):
        sentinel = self.root + '/unrelated-sentinel'
        with open(sentinel, 'wb') as handle:
            handle.write(OTHER_SECRET.encode())
        real_verify = config_stage._verify_file
        def replace_with_symlink(path, maximum):
            if (path.startswith(self.payload_dir + '/config-')
                    and not path.endswith('/' + self.applied_name)):
                os.remove(path)
                os.symlink(sentinel, path)
                raise OSError('verification failed')
            return real_verify(path, maximum)
        with mock.patch.object(config_stage, '_verify_file', side_effect=replace_with_symlink):
            with self.assertRaises(config_stage.ConfigStageError) as raised:
                self.coordinator.stage_latest()
        self.assertEqual(str(raised.exception), 'Unable to clean stored configuration.')
        self.assertEqual(self.store.state['status'], 'rejected')
        self.assertTrue(os.path.islink(self.payload_dir + '/' + self.payload_files()[1]))
        with open(sentinel, 'rb') as handle:
            self.assertEqual(handle.read(), OTHER_SECRET.encode())

    def test_stage_candidate_readback_failure_preserves_candidate_payload(self):
        real_stage_candidate = self.store.stage_candidate
        def commit_then_fail(*args, **kwargs):
            real_stage_candidate(*args, **kwargs)
            raise OSError(OTHER_SECRET)
        with mock.patch.object(self.store, 'stage_candidate', side_effect=commit_then_fail):
            with self.assertRaises(config_stage.ConfigStageError):
                self.coordinator.stage_latest()
        reloaded = ConfigTrialStore(self.root)
        reloaded.load()
        candidate_name = reloaded.state['candidate'][0]
        self.assertEqual(reloaded.state['status'], 'staged')
        self.assertTrue(os.path.isfile(self.payload_dir + '/' + candidate_name))
        self.assertEqual(self.payload_files(), sorted([self.applied_name, candidate_name]))

    def test_owned_payload_deletion_failure_is_redacted_and_rejects_reserved(self):
        real_remove = os.remove
        def fail_owned_remove(path):
            if (path.startswith(self.payload_dir + '/config-')
                    and not path.endswith('/' + self.applied_name)):
                raise OSError(OTHER_SECRET)
            return real_remove(path)
        real_verify = config_stage._verify_file
        def fail_after_write(path, maximum):
            result = real_verify(path, maximum)
            if (path.startswith(self.payload_dir + '/config-')
                    and not path.endswith('/' + self.applied_name)):
                return result[0], '0' * 64
            return result
        with mock.patch.object(config_stage, '_verify_file', side_effect=fail_after_write):
            with mock.patch.object(config_stage.os, 'remove', side_effect=fail_owned_remove):
                with self.assertRaises(config_stage.ConfigStageError) as raised:
                    self.coordinator.stage_latest()
        self.assertEqual(str(raised.exception), 'Unable to clean stored configuration.')
        rendered = ''.join(traceback.format_exception(raised.exception))
        self.assertNotIn(OTHER_SECRET, rendered)
        self.assertEqual(self.store.state['status'], 'rejected')
        self.assertTrue(os.path.isfile(self.payload_dir + '/' + self.applied_name))
        self.assertEqual(len(self.payload_files()), 2)




if __name__ == '__main__':
    unittest.main()
