import hashlib
import json
import os
import tempfile
import traceback
import unittest
from unittest import mock

from config_payload import read_device_payload
from config_proof_io import CandidateProofIO, ConfigProofIOFailure
from config_trial import ConfigTrialStore, _ConfigProof
from fleet_config import FleetConfiguration
from gist_publisher import THERMOSTAT_FILENAME
from gist_publisher import GistPublishProofFailure
from gist_readback import GistReadbackFailure
from native_https import HttpFailure, NativeHttpsTransport
from private_fleet_client import PrivateFleetClient


REVISION = '12345678-1234-4234-8234-123456789abc'
CHANGE = 'abcdefab-1234-4234-8234-123456789abc'
REF = 'unit-01'
GIST_TEMP = 'a' * 32
GIST_DIAG = 'b' * 32


def _device(read_token='read-secret', write_token='write-secret', temp=GIST_TEMP,
            password='wifi-password'):
    return {
        'change_id': CHANGE,
        'logical_id': 'unit-one',
        'wifi_profiles': [{'profile_id': 'main', 'ssid': 'farm', 'password': password}],
        'config_read_credential': read_token,
        'temperature_gist_id': temp,
        'diagnostics_gist_id': GIST_DIAG,
        'gist_write_credential': write_token,
        'sample_interval_seconds': 30,
        'publication_interval_seconds': 60,
    }


def _fleet(device=None, unrelated=None):
    devices = {REF: device or _device()}
    if unrelated is not None:
        devices['other-unit'] = unrelated
    return json.dumps({'schema_version': 1, 'fleet_revision': REVISION,
                       'devices': devices}, separators=(',', ':')).encode()


def _candidate(device=None):
    payload = json.dumps({'schema_version': 1, 'fleet_revision': REVISION,
                          'device_ref': REF, 'device': device or _device()},
                         separators=(',', ':')).encode()
    return read_device_payload(payload, REF)


class _Clock:
    def ticks_ms(self):
        return 1


class _Unused:
    pass


class _Socket:
    pass


class CandidateProofIOTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.candidate = _candidate()
        self.io = CandidateProofIO(
            self.candidate, REF, ('fleet-owner', 'private-repo', 'fleet.json', 'main'),
            b'ca-roots', _Unused, _Unused, _Socket, _Clock(), '1.2.3.4',
            lambda: True, self.temp.name, lambda count: b'x' * count,
            resolver=lambda *args, **kwargs: None)

    def tearDown(self):
        self.io.close()
        self.temp.cleanup()

    def _staged(self, content, path=None, claimed=None):
        path = path or os.path.join(self.temp.name, 'candidate.json')
        with open(path, 'wb') as target:
            target.write(content)
        if claimed is None:
            claimed = (len(content), hashlib.sha256(content).hexdigest())
        self.io._fleet_client.fetch_to_stage = lambda **kwargs: (path, claimed)
        return path

    def _stage_client(self, io=None, scope=None, scratch=None, token=None):
        io = io or self.io
        transport = NativeHttpsTransport(
            (), token or bytearray(b'stage-secret'), b'ca-roots', _Unused,
            _Unused, _Socket, _Clock(), '1.2.3.4', resolver=lambda *args, **kwargs: None,
            private_contents=scope or ('fleet-owner', 'private-repo', 'fleet.json', 'main'))
        return PrivateFleetClient(transport, scratch or io._scratch_dir,
                                  lambda count: b'y' * count, time_is_trusted=lambda: True)

    def _trial_store(self, directory=None):
        directory = directory or tempfile.mkdtemp(dir=self.temp.name)
        store = ConfigTrialStore(directory, ticks_ms=lambda: 10,
                                 ticks_diff=lambda now, started: now - started)
        applied_revision = '22345678-1234-4234-8234-123456789abc'
        applied_change = 'bcdefabc-1234-4234-8234-123456789abc'
        store.initialize('old.json', 10, '0' * 64, applied_revision,
                         applied_change, REF, True)
        store.begin_received(REVISION, CHANGE)
        store.stage_candidate('new.json', 11, '1' * 64, True)
        store.enter_trial()
        applied_device = _device()
        applied_device['change_id'] = applied_change
        applied = _candidate(applied_device)._replace(revision=applied_revision)
        return store, applied

    def test_constructs_candidate_bound_capabilities_and_scrubs_tokens(self):
        self.assertEqual(self.io._private_transport._private_contents,
                         ('fleet-owner', 'private-repo', 'fleet.json', 'main'))
        self.assertEqual(bytes(self.io._private_transport.token), b'read-secret')
        self.assertEqual(bytes(self.io._publisher._token), b'write-secret')
        self.assertIn('redacted', repr(self.io).lower())
        self.io.close()
        self.assertEqual(bytes(self.io._private_transport.token), b'\x00' * 11)
        self.assertEqual(bytes(self.io._publisher._token), b'\x00' * 12)

    def test_accepts_exact_addressed_device_but_ignores_unrelated_device_change(self):
        changed_other = _device(read_token='other-read', password='other-password')
        changed_other['logical_id'] = 'other-unit'
        path = self._staged(_fleet(unrelated=changed_other))
        self.assertEqual(self.io.read_exact_candidate(self.candidate), self.candidate)
        self.assertFalse(os.path.exists(path))

    def test_same_ids_with_changed_secret_is_invalid_config(self):
        path = self._staged(_fleet(device=_device(read_token='changed-read')))
        with self.assertRaises(ConfigProofIOFailure) as caught:
            self.io.read_exact_candidate(self.candidate)
        self.assertEqual(caught.exception.kind, 'invalid_config')
        self.assertFalse(os.path.exists(path))

    def test_private_and_gist_capabilities_bind_candidate_not_other_config(self):
        alternate = _candidate(_device(read_token='candidate-B', write_token='writer-B',
                                       temp='c' * 32))
        with self.assertRaises(ConfigProofIOFailure):
            self.io.read_exact_candidate(alternate)
        self.assertEqual(bytes(self.io._private_transport.token), b'read-secret')
        self.assertEqual(self.io._publisher.gist_ids[THERMOSTAT_FILENAME], GIST_TEMP)

    def test_mutable_constructor_candidate_is_canonicalized_and_mutation_blocks_io(self):
        original = _candidate()

        class MutableDevice:
            def __init__(self, device):
                for name in device._fields:
                    setattr(self, name, getattr(device, name))

            def __eq__(self, other):
                return all(getattr(self, name) == getattr(other, name)
                           for name in original.device._fields)

        mutable_device = MutableDevice(original.device)
        mutable_candidate = FleetConfiguration(original.revision, mutable_device)
        other_io = CandidateProofIO(
            mutable_candidate, REF,
            ('fleet-owner', 'private-repo', 'fleet.json', 'main'),
            b'ca-roots', _Unused, _Unused, _Socket, _Clock(), '1.2.3.4',
            lambda: True, self.temp.name, lambda count: b'x' * count,
            resolver=lambda *args, **kwargs: None)
        fetches, patches = [], []
        other_io._fleet_client.fetch_to_stage = lambda **kwargs: fetches.append(True)
        other_io._publisher.patch_exact_for_trial = lambda *args, **kwargs: patches.append(True)
        self.assertEqual(other_io._candidate, original)
        self.assertEqual(bytes(other_io._private_transport.token), b'read-secret')
        self.assertEqual(bytes(other_io._publisher._token), b'write-secret')

        mutable_device.config_read_credential = 'mutated-read-secret'
        mutable_device.gist_write_credential = 'mutated-write-secret'
        with self.assertRaises(ConfigProofIOFailure):
            other_io.read_exact_candidate(mutable_candidate)
        with self.assertRaises(ConfigProofIOFailure):
            other_io.patch_exact(THERMOSTAT_FILENAME, 'content')
        self.assertEqual(fetches, [])
        self.assertEqual(patches, [])
        self.assertEqual(bytes(other_io._private_transport.token), b'read-secret')
        self.assertEqual(bytes(other_io._publisher._token), b'write-secret')
        other_io.close()

    def test_real_private_client_windows_mixed_separator_path_is_owned_and_cleaned(self):
        for fleet, expected_kind in ((_fleet(), None),
                                     (_fleet(device=_device(read_token='changed')), 'invalid_config')):
            self.io._private_transport.get_private_contents = (
                lambda writer, service=None, payload=fleet:
                [writer(payload[offset:offset + 1024])
                 for offset in range(0, len(payload), 1024)])
            if expected_kind is None:
                self.assertEqual(self.io.read_exact_candidate(self.candidate), self.candidate)
            else:
                with self.assertRaises(ConfigProofIOFailure) as caught:
                    self.io.read_exact_candidate(self.candidate)
                self.assertEqual(caught.exception.kind, expected_kind)
            candidates = [name for name in os.listdir(self.temp.name)
                          if name.endswith('.candidate')]
            self.assertEqual(candidates, [])

    def test_second_pass_callback_cancel_or_exception_is_inconclusive_and_cleans(self):
        for callback in (lambda: False,
                         lambda: (_ for _ in ()).throw(RuntimeError('SYNTHETIC_SECRET'))):
            path = self._staged(_fleet())
            with self.assertRaises(ConfigProofIOFailure) as caught:
                self.io.read_exact_candidate(self.candidate, service=callback)
            self.assertEqual(caught.exception.kind, 'inconclusive')
            self.assertFalse(os.path.exists(path))
            self.assertNotIn('SYNTHETIC_SECRET', str(caught.exception))

    def test_rejects_wrong_scratch_path_without_removing_it(self):
        outside = os.path.join(os.path.dirname(self.temp.name), 'do-not-delete.json')
        with open(outside, 'wb') as target:
            target.write(_fleet())
        self.io._fleet_client.fetch_to_stage = lambda **kwargs: (
            outside, (len(_fleet()), hashlib.sha256(_fleet()).hexdigest()))
        try:
            with self.assertRaises(ConfigProofIOFailure):
                self.io.read_exact_candidate(self.candidate)
            self.assertTrue(os.path.exists(outside))
        finally:
            os.remove(outside)

    def test_cleanup_failure_blocks_verified_result(self):
        path = self._staged(_fleet())
        remove = os.remove

        def fail_owned(candidate_path):
            if candidate_path == path:
                raise OSError('secret path')
            remove(candidate_path)

        with mock.patch('config_proof_io.os.remove', side_effect=fail_owned):
            with self.assertRaises(ConfigProofIOFailure) as caught:
                self.io.read_exact_candidate(self.candidate)
        self.assertEqual(caught.exception.kind, 'inconclusive')
        remove(path)

    def test_transport_http_classification_and_redacted_traceback(self):
        for status, expected in ((401, 'authentication_failed'), (429, 'inconclusive')):
            def fail(**kwargs):
                raise HttpFailure(status, {b'x-secret': b'token-value'})
            self.io._fleet_client.fetch_to_stage = fail
            try:
                self.io.read_exact_candidate(self.candidate)
            except ConfigProofIOFailure as error:
                self.assertEqual(error.kind, expected)
                self.assertNotIn('token-value', repr(error))
                self.assertNotIn('token-value', str(error.__cause__))
            else:
                self.fail('expected proof failure')

    def test_size_bound_and_claimed_digest_are_verified(self):
        content = _fleet()
        path = self._staged(content, claimed=(len(content), '0' * 64))
        with self.assertRaises(ConfigProofIOFailure):
            self.io.read_exact_candidate(self.candidate)
        self.assertFalse(os.path.exists(path))
        too_large = b'x' * 65537
        path = self._staged(too_large)
        with self.assertRaises(ConfigProofIOFailure):
            self.io.read_exact_candidate(self.candidate)
        self.assertFalse(os.path.exists(path))

    def test_exact_maximum_size_is_streamed_in_bounded_reads(self):
        content = _fleet() + b' ' * (65536 - len(_fleet()))
        self.assertEqual(len(content), 65536)
        path = self._staged(content)
        read_sizes = []
        actual_open = open

        class TrackingFile:
            def __init__(self, stream):
                self.stream = stream

            def read(self, size=-1):
                read_sizes.append(size)
                return self.stream.read(size)

            def __enter__(self):
                return self

            def __exit__(self, *args):
                self.close()

            def close(self):
                self.stream.close()

        def tracked_open(target, mode):
            return TrackingFile(actual_open(target, mode))

        with mock.patch('config_proof_io.open', side_effect=tracked_open, create=True):
            self.assertEqual(self.io.read_exact_candidate(self.candidate), self.candidate)
        self.assertTrue(read_sizes)
        self.assertLessEqual(max(read_sizes), 1024)
        self.assertFalse(os.path.exists(path))

    def test_changed_file_between_passes_fails_closed(self):
        original = _fleet()
        changed_other = _device(read_token='other-read', password='other-password')
        changed_other['logical_id'] = 'other-unit'
        changed = _fleet(unrelated=changed_other)
        path = self._staged(original)
        actual_open = open
        calls = []

        class ChangedFile:
            def __init__(self, content):
                self.stream = __import__('io').BytesIO(content)

            def read(self, size=-1):
                return self.stream.read(size)

            def close(self):
                self.stream.close()

        def changing_open(target, mode):
            calls.append(target)
            if len(calls) == 1:
                return actual_open(target, mode)
            return ChangedFile(changed)

        with mock.patch('config_proof_io.open', side_effect=changing_open, create=True):
            with self.assertRaises(ConfigProofIOFailure) as caught:
                self.io.read_exact_candidate(self.candidate)
        self.assertEqual(caught.exception.kind, 'inconclusive')
        self.assertFalse(os.path.exists(path))

    def test_callback_proof_error_and_constructor_error_are_redacted(self):
        def fail_fetch(**kwargs):
            try:
                raise RuntimeError('SYNTHETIC_SECRET')
            except RuntimeError as error:
                raise ConfigProofIOFailure('inconclusive') from error

        self.io._fleet_client.fetch_to_stage = fail_fetch
        try:
            self.io.read_exact_candidate(self.candidate)
        except ConfigProofIOFailure as error:
            self.assertNotIn('SYNTHETIC_SECRET', ''.join(
                traceback.format_exception(type(error), error, error.__traceback__)))
        else:
            self.fail('expected proof failure')

        with mock.patch('config_proof_io.GistPublisher',
                        side_effect=RuntimeError('SYNTHETIC_SECRET')):
            with self.assertRaises(ValueError) as caught:
                CandidateProofIO(
                    self.candidate, REF,
                    ('fleet-owner', 'private-repo', 'fleet.json', 'main'),
                    b'ca-roots', _Unused, _Unused, _Socket, _Clock(), '1.2.3.4',
                    lambda: True, self.temp.name, lambda count: b'x' * count,
                    resolver=lambda *args, **kwargs: None)
        self.assertNotIn('SYNTHETIC_SECRET', ''.join(
            traceback.format_exception(type(caught.exception), caught.exception,
                                       caught.exception.__traceback__)))

    def test_truthy_non_boolean_time_is_not_trusted(self):
        self.io._time_is_trusted = lambda: 1
        called = []
        self.io._fleet_client.fetch_to_stage = lambda **kwargs: called.append(True)
        with self.assertRaises(ConfigProofIOFailure):
            self.io.read_exact_candidate(self.candidate)
        self.assertEqual(called, [])

    def test_exact_patch_and_confirm_use_only_registered_candidate_gists(self):
        original_publisher = self.io._publisher
        events = []

        class Readback:
            def confirm_file(self, gist_id, filename, content, service=None):
                events.append(('confirm', gist_id, filename, content, service))
                return True

        class Publisher:
            readback = Readback()

            def patch_exact_for_trial(self, filename, content, service=None):
                events.append(('patch', filename, content, service))
                return content

            def close(self):
                original_publisher.close()

        self.io._publisher = Publisher()
        service = lambda: None
        self.assertEqual(self.io.patch_exact(THERMOSTAT_FILENAME, 'exact bytes', service),
                         'exact bytes')
        self.assertTrue(self.io.confirm_exact(THERMOSTAT_FILENAME, 'exact bytes', service))
        self.assertEqual(events, [
            ('patch', THERMOSTAT_FILENAME, 'exact bytes', service),
            ('confirm', GIST_TEMP, THERMOSTAT_FILENAME, 'exact bytes', service),
        ])

    def test_exact_patch_failure_kinds_wrong_filename_and_confirm_failure(self):
        original_publisher = self.io._publisher

        class Readback:
            def __init__(self, failure):
                self.failure = failure

            def confirm_file(self, *args, **kwargs):
                raise self.failure

        class Publisher:
            def __init__(self, patch_failure=None, read_failure=None):
                self.patch_failure = patch_failure
                self.readback = Readback(read_failure)
                self.called = False

            def patch_exact_for_trial(self, *args, **kwargs):
                self.called = True
                raise self.patch_failure

            def close(self):
                original_publisher.close()

        for proof_failure, expected in ((
                GistPublishProofFailure('authentication_failed'), 'authentication_failed'),
                (GistPublishProofFailure('inconclusive'), 'inconclusive')):
            fake = Publisher(patch_failure=proof_failure)
            self.io._publisher = fake
            with self.assertRaises(ConfigProofIOFailure) as caught:
                self.io.patch_exact(THERMOSTAT_FILENAME, 'exact bytes')
            self.assertEqual(caught.exception.kind, expected)

        fake = Publisher(patch_failure=GistPublishProofFailure('definite'))
        self.io._publisher = fake
        with self.assertRaises(ConfigProofIOFailure):
            self.io.patch_exact('arbitrary.txt', 'exact bytes')
        self.assertFalse(fake.called)

        fake = Publisher(read_failure=GistReadbackFailure('inconclusive'))
        self.io._publisher = fake
        with self.assertRaises(ConfigProofIOFailure) as caught:
            self.io.confirm_exact(THERMOSTAT_FILENAME, 'exact bytes')
        self.assertEqual(caught.exception.kind, 'inconclusive')

    def test_time_callback_must_be_trusted(self):
        self.io._time_is_trusted = lambda: False
        called = []
        self.io._fleet_client.fetch_to_stage = lambda **kwargs: called.append(True)
        with self.assertRaises(ConfigProofIOFailure) as caught:
            self.io.read_exact_candidate(self.candidate)
        self.assertEqual(caught.exception.kind, 'inconclusive')
        self.assertEqual(called, [])

    def test_binding_requires_same_temperature_gist_and_correct_trial_config(self):
        store, applied = self._trial_store()
        wrong_temp = dict(_device())
        wrong_temp['temperature_gist_id'] = 'c' * 32
        with self.assertRaisesRegex(ValueError, '^configuration trial binding rejected$'):
            self.io.bind_trial(store, _candidate(wrong_temp)._replace(revision=applied.revision), self._stage_client())
        with self.assertRaisesRegex(ValueError, '^configuration trial binding rejected$'):
            self.io.bind_trial(store, _candidate()._replace(revision='32345678-1234-4234-8234-123456789abc'), self._stage_client())
        self.io.bind_trial(store, applied, self._stage_client())

    def test_binding_must_precede_any_proof_io(self):
        store, applied = self._trial_store()
        self.io._fleet_client.fetch_to_stage = lambda **kwargs: None
        with self.assertRaises(ConfigProofIOFailure):
            self.io.read_exact_candidate(self.candidate)
        with self.assertRaisesRegex(ValueError, '^configuration trial binding rejected$'):
            self.io.bind_trial(store, applied, self._stage_client())

    def test_binding_rejects_wrong_stage_scope_scratch_identity_and_shared_token(self):
        store, applied = self._trial_store()
        invalid_clients = (
            self._stage_client(scope=('fleet-owner', 'private-repo', 'other.json', 'main')),
            self._stage_client(scratch=os.path.join(self.temp.name, 'other')),
            self.io._fleet_client,
        )
        shared = self._stage_client()
        shared.transport.token = self.io._private_transport.token
        invalid_clients += (shared,)
        for stage_client in invalid_clients:
            with self.assertRaisesRegex(ValueError, '^configuration trial binding rejected$'):
                self.io.bind_trial(store, applied, stage_client)

    def test_failed_proof_close_scrubs_candidate_but_never_touches_old_stage_reader(self):
        store, applied = self._trial_store()
        stage = self._stage_client()
        stage_transport = stage.transport
        stage_token = stage_transport.token
        candidate_transport = self.io._private_transport
        candidate_token = candidate_transport.token
        publisher_token = self.io._publisher._token
        self.io._publisher.close = mock.Mock(side_effect=RuntimeError('writer-secret'))
        self.io.bind_trial(store, applied, stage)
        self.io._time_is_trusted = lambda: False
        with self.assertRaises(ConfigProofIOFailure):
            self.io.read_exact_candidate(self.candidate)
        self.io.close()
        self.io.close()
        self.assertIs(stage_transport.token, stage_token)
        self.assertFalse(stage_transport._closed)
        self.assertEqual(bytes(stage_token), b'stage-secret')
        self.assertEqual(bytes(candidate_token), b'\x00' * len(b'read-secret'))
        self.assertTrue(candidate_transport._closed)
        self.assertEqual(bytes(publisher_token), b'\x00' * len(b'write-secret'))

    def test_binding_rejects_wrong_store_old_config_and_changed_candidate_reference(self):
        store, applied = self._trial_store()
        other_store, unused = self._trial_store()
        other_store.state['device_ref'] = 'other-unit'
        with self.assertRaisesRegex(ValueError, '^configuration trial binding rejected$'):
            self.io.bind_trial(other_store, applied, self._stage_client())

        wrong_applied = applied._replace(revision='32345678-1234-4234-8234-123456789abc')
        with self.assertRaisesRegex(ValueError, '^configuration trial binding rejected$'):
            self.io.bind_trial(store, wrong_applied, self._stage_client())

        self.io.bind_trial(store, applied, self._stage_client())
        store.state['candidate'][2] = '2' * 64
        with self.assertRaisesRegex(ValueError, '^proof I/O ownership transfer rejected$'):
            self.io.detach_after_commit(store)
        self.assertIsNotNone(self.io._publisher)

    def test_detach_requires_single_durable_promotion_and_transfers_exact_candidate_pair(self):
        store, applied = self._trial_store()
        original_publisher = self.io._publisher
        old_stage_client = self._stage_client()
        old_stage_transport = old_stage_client.transport
        old_stage_token = old_stage_transport.token
        candidate_client = self.io._fleet_client
        candidate_transport = self.io._private_transport
        candidate_token = candidate_transport.token
        with self.assertRaisesRegex(ValueError, '^proof I/O ownership transfer rejected$'):
            self.io.detach_after_commit(store)
        self.io.bind_trial(store, applied, old_stage_client)
        with self.assertRaisesRegex(ValueError, '^proof I/O ownership transfer rejected$'):
            self.io.detach_after_commit(store)

        self.assertTrue(store.expire_or_confirm(11, _ConfigProof(store)))
        publisher, transferred_client = self.io.detach_after_commit(store)
        self.assertIs(publisher, original_publisher)
        self.assertIs(transferred_client, candidate_client)
        self.assertIsNot(transferred_client, old_stage_client)
        self.assertIs(transferred_client.transport, candidate_transport)
        self.assertEqual(bytes(old_stage_token), b'stage-secret')
        self.assertEqual(bytes(candidate_token), b'read-secret')
        self.assertIsNone(self.io._publisher)
        for operation in (lambda: self.io.read_exact_candidate(self.candidate),
                          lambda: self.io.patch_exact(THERMOSTAT_FILENAME, 'x'),
                          lambda: self.io.confirm_exact(THERMOSTAT_FILENAME, 'x')):
            with self.assertRaises(ConfigProofIOFailure):
                operation()
        self.io.close()
        self.assertFalse(original_publisher._closed)
        self.assertFalse(old_stage_transport._closed)
        self.assertEqual(bytes(old_stage_token), b'stage-secret')
        self.assertFalse(candidate_transport._closed)
        self.assertEqual(bytes(candidate_token), b'read-secret')
        with self.assertRaisesRegex(ValueError, '^proof I/O ownership transfer rejected$'):
            self.io.detach_after_commit(store)
        old_stage_transport.close()  # The coordinator, not the adapter, retires it.
        transferred_client.transport.close()
        original_publisher.close()

    def test_detach_rejects_closed_publisher_or_wrong_commit_without_detaching(self):
        store, applied = self._trial_store()
        self.io.bind_trial(store, applied, self._stage_client())
        publisher = self.io._publisher
        store.sequence += 1
        store.state['status'] = 'applied'
        store.state['candidate'] = None
        with self.assertRaisesRegex(ValueError, '^proof I/O ownership transfer rejected$'):
            self.io.detach_after_commit(store)
        self.assertIs(self.io._publisher, publisher)
        store, applied = self._trial_store()
        second_io = CandidateProofIO(
            self.candidate, REF, ('fleet-owner', 'private-repo', 'fleet.json', 'main'),
            b'ca-roots', _Unused, _Unused, _Socket, _Clock(), '1.2.3.4',
            lambda: True, self.temp.name, lambda count: b'x' * count,
            resolver=lambda *args, **kwargs: None)
        second_io.bind_trial(store, applied, self._stage_client(second_io))
        second_io._publisher.close()
        with self.assertRaisesRegex(ValueError, '^proof I/O ownership transfer rejected$'):
            second_io.detach_after_commit(store)
        self.assertIsNotNone(second_io._publisher)
        second_io.close()

    def test_transfer_failure_and_close_tracebacks_do_not_disclose_credentials(self):
        store, applied = self._trial_store()
        self.io.bind_trial(store, applied, self._stage_client())
        with self.assertRaises(ValueError) as caught:
            self.io.detach_after_commit(store)
        formatted = ''.join(traceback.format_exception(
            type(caught.exception), caught.exception, caught.exception.__traceback__))
        self.assertNotIn('write-secret', formatted)
        self.assertNotIn('read-secret', formatted)
        self.io._private_transport.close = mock.Mock(side_effect=RuntimeError('read-secret'))
        self.io.close()


if __name__ == '__main__':
    unittest.main()
