import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import traceback
import unittest
from unittest import mock
import builtins

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import config_payload
import config_stage
from config_payload import extract_device_payload, write_owned_payload
from config_payload import read_device_payload
from config_proof_io import CandidateProofIO
from config_promotion import (ConfigPromotionCoordinator, WifiAssociationConfirmed,
                              CONFIG_AUTOMATIC_PROMOTION_ENABLED)
from config_stage import ConfigStageCoordinator
from config_trial import ConfigTrialStore
from fixed_supervisor import FixedSupervisor
from native_https import NativeHttpsTransport
from private_fleet_client import PrivateFleetClient
from runtime import Monitor


DEVICE = '123e4567-e89b-42d3-a456-426614174000'
CHANGE_1 = '123e4567-e89b-42d3-a456-426614174001'
CHANGE_2 = '123e4567-e89b-42d3-a456-426614174002'
REV_1 = '223e4567-e89b-42d3-a456-426614174001'
REV_2 = '223e4567-e89b-42d3-a456-426614174002'
CHANGE_3 = '123e4567-e89b-42d3-a456-426614174003'
REV_3 = '223e4567-e89b-42d3-a456-426614174003'


def fleet(revision, change_id, gist='a' * 32, read_token='read-secret'):
    device = {
        'change_id': change_id, 'logical_id': 'monitor-a',
        'wifi_profiles': [{'profile_id': 'primary', 'ssid': 'synthetic', 'password': 'wifi-secret'}],
        'config_read_credential': read_token, 'temperature_gist_id': gist,
        'diagnostics_gist_id': 'b' * 32, 'gist_write_credential': 'write-secret',
        'sample_interval_seconds': 60, 'publication_interval_seconds': 300,
    }
    return json.dumps({'schema_version': 1, 'fleet_revision': revision,
                       'devices': {DEVICE: device}}, separators=(',', ':')).encode()


class Clock:
    def __init__(self):
        self.now = 100

    def ticks_ms(self):
        return self.now

    @staticmethod
    def ticks_diff(current, previous):
        return current - previous


class PrivateClient(config_stage.PrivateFleetClient):
    def __init__(self, directory):
        self.stage_directory, self.contents = directory, fleet(REV_2, CHANGE_2)

    def fetch_to_stage(self, service=None):
        path = self.stage_directory + '/download.json'
        with open(path, 'wb') as handle:
            handle.write(self.contents)
        return path, (len(self.contents), hashlib.sha256(self.contents).hexdigest())


class Firmware:
    def __init__(self):
        self._state = type('State', (), {'state': {
            'phase': None, 'pending_slot': None, 'pending_id': None,
            'trial_marker': None}})()

    def boot(self):
        return 'A'


class Publisher:
    def __init__(self):
        self.reports, self.temperatures, self.closed = [], [], False

    def publish_diagnostics(self, value):
        self.reports.append(value)

    def publish_temperature(self, value):
        self.temperatures.append(value)

    def close(self):
        self.closed = True


class Sensor:
    def read_celsius(self):
        return 22.5


class EmptyModule:
    pass


class ProofIO(CandidateProofIO):
    def __new__(cls, candidate, events):
        instance = object.__new__(cls)
        instance.candidate, instance.events = candidate, events
        return instance

    def __init__(self, candidate, events):
        pass

    def bind_trial(self, store, applied_config, stage_client):
        self._bound_trial = (store, store.sequence, store.trial_started)
        self.stage_client = stage_client
        self.events.append('bind')

    def read_exact_candidate(self, expected_candidate, service=None):
        self.events.append('get')
        return self.candidate

    def patch_exact(self, filename, content, service=None):
        self.events.append('patch:' + filename)
        return content

    def confirm_exact(self, filename, content, service=None):
        self.events.append('confirm:' + filename)
        return not getattr(self, 'fail_confirmation', False)

    def detach_after_commit(self, store):
        self.events.append('detach')
        return self.publisher, self.candidate_client

    def close(self):
        self.events.append('close')


class ConfigPromotionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name.replace('\\', '/')
        self.payload_dir, self.stage_dir = self.root + '/payloads', self.root + '/stage'
        os.mkdir(self.payload_dir)
        os.mkdir(self.stage_dir)
        patches = [mock.patch.object(config_payload, '_validate_directory', lambda unused: None),
                   mock.patch.object(config_stage, '_trusted_directory', lambda value: value.rstrip('/\\'))]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        baseline, _, _ = extract_device_payload(io.BytesIO(fleet(REV_1, CHANGE_1)), DEVICE)
        name, size, digest = write_owned_payload(self.payload_dir, baseline, lambda size: b'1' * size)
        self.clock = Clock()
        self.store = ConfigTrialStore(self.root, self.clock_ticks, self.clock_diff)
        self.store.initialize(name, size, digest, REV_1, CHANGE_1, DEVICE, True)
        self.client = PrivateClient(self.stage_dir)
        self.stage = ConfigStageCoordinator(self.store, self.client, self.payload_dir, DEVICE,
                                            lambda size: b'2' * size)
        self.old_publisher, self.new_publisher = Publisher(), Publisher()
        self.monitor = Monitor(Sensor(), self.old_publisher, self.clock, 'boot-test', DEVICE, '1.0')
        self.owner = FixedSupervisor(self.store, Firmware(), '/unused', DEVICE)
        self.owner._booted = True
        self.events = []
        self.fail_confirmation = False
        self.wifi_failed = False
        self.advance_wifi_ms = 0

    def tearDown(self):
        self.temp.cleanup()

    def clock_ticks(self):
        return self.clock.now

    def clock_diff(self, now, previous):
        return now - previous

    def coordinator(self):
        def make_io(candidate):
            value = ProofIO(candidate, self.events)
            value.publisher = self.new_publisher
            value.candidate_client = PrivateClient(self.stage_dir)
            value.fail_confirmation = self.fail_confirmation
            return value

        def connect(profiles, remaining, service):
            if self.wifi_failed:
                from config_promotion import WifiAssociationFailed
                return WifiAssociationFailed()
            self.clock.now += self.advance_wifi_ms
            return WifiAssociationConfirmed('primary', self.clock.now)
        return ConfigPromotionCoordinator(
            self.stage, self.owner, self.monitor, self.clock,
            connect,
            lambda applied, remaining, service: True, make_io)

    def real_io_coordinator(self, callbacks=None, fail_readback=False):
        instances = []
        candidate_tokens = []
        gist_files = {}

        stage_transport = NativeHttpsTransport(
            (), bytearray(b'read-old'), b'root-certificates',
            EmptyModule, EmptyModule, EmptyModule, self.clock, '192.0.2.1',
            resolver=lambda *args, **kwargs: None,
            private_contents=('owner', 'private-repository', 'fleet.json', 'main'))
        stage_client = PrivateFleetClient(stage_transport, self.stage_dir,
                                          random_bytes=lambda size: b's' * size,
                                          time_is_trusted=lambda: True)
        stage_fleet = fleet(REV_2, CHANGE_2, read_token='read-new')
        def stage_fetch(service=None):
            path = self.stage_dir + '/stage-download.json'
            with open(path, 'wb') as handle:
                handle.write(stage_fleet)
            return path, (len(stage_fleet), hashlib.sha256(stage_fleet).hexdigest())
        stage_client.fetch_to_stage = stage_fetch
        self.old_stage_client = stage_client
        self.stage.private_client = stage_client

        def make_io(candidate):
            value = CandidateProofIO(
                candidate, DEVICE, ('owner', 'private-repository', 'fleet.json', 'main'),
                b'root-certificates', EmptyModule, EmptyModule, EmptyModule,
                self.clock, '192.0.2.1', lambda: True, self.stage_dir,
                lambda size: b'z' * size, resolver=lambda *args, **kwargs: None)
            instances.append(value)
            candidate_tokens.append(value._private_transport.token)
            fetched = fleet(candidate.revision, candidate.device.change_id,
                            read_token=candidate.device.config_read_credential)
            def fetch(**kwargs):
                path = self.stage_dir + '/proof-download.json'
                with open(path, 'wb') as handle:
                    handle.write(fetched)
                return path, (len(fetched), hashlib.sha256(fetched).hexdigest())
            value._fleet_client.fetch_to_stage = fetch
            transport = value._publisher.transport
            def patch(gist_id, body, service=None):
                document = json.loads(body.decode('utf-8'))
                for filename, item in document['files'].items():
                    gist_files[(gist_id, filename)] = item['content']
                return True
            def get(gist_id, writer, service=None):
                if callbacks is not None and gist_id == 'b' * 32:
                    callbacks.extend((self.monitor.poll(), self.monitor.step(60, 300)))
                if fail_readback and gist_id == 'b' * 32:
                    raise OSError('SYNTHETIC_SECRET transport failure')
                files = {}
                for (registered_id, filename), content in gist_files.items():
                    if registered_id == gist_id:
                        files[filename] = {'content': content}
                writer(json.dumps({'id': gist_id, 'truncated': False,
                                   'files': files}).encode('utf-8'))
            transport.patch_gist = patch
            transport.get_gist_json = get
            return value

        def connect(profiles, remaining, service):
            return WifiAssociationConfirmed('primary', self.clock.now)

        coordinator = ConfigPromotionCoordinator(
            self.stage, self.owner, self.monitor, self.clock, connect,
            lambda applied, remaining, service: True, make_io)
        return coordinator, instances, candidate_tokens

    def test_success_reads_candidate_and_exact_gists_before_durable_commit_and_switch(self):
        self.assertFalse(CONFIG_AUTOMATIC_PROMOTION_ENABLED)
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'applied', 'recovery_required': False})
        self.assertEqual(self.store.state['status'], 'applied')
        self.assertLess(self.events.index('get'), self.events.index('patch:thermostat.txt'))
        self.assertLess(self.events.index('confirm:diagnostics.json'), self.events.index('detach'))
        self.assertIs(self.monitor.publisher, self.new_publisher)
        self.assertEqual(self.monitor.diagnostics['configuration']['applied_id'], CHANGE_2)
        self.assertTrue(self.old_publisher.closed)
        self.assertNotIn('read-secret', repr(self.coordinator()))

    def test_unchanged_change_is_noop(self):
        self.client.contents = fleet(REV_2, CHANGE_1)
        self.assertIsNone(self.coordinator().run_once())
        self.assertEqual(self.store.state['status'], 'ready')
        self.assertEqual(self.events, [])

    def test_candidate_with_different_temperature_destination_is_rejected(self):
        self.client.contents = fleet(REV_2, CHANGE_2, gist='c' * 32)
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'rejected'})
        self.assertEqual(self.store.state['status'], 'rejected')
        self.assertIn(CHANGE_2, self.store.state['consumed'])
        self.assertEqual(self.events, [])

    def test_post_commit_diagnostics_failure_never_rolls_back(self):
        def failed_report(unused):
            raise OSError('synthetic report failure')
        self.new_publisher.publish_diagnostics = failed_report
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'applied', 'recovery_required': False,
                                  'report_pending': True})
        self.assertEqual(self.store.state['status'], 'applied')
        self.assertIs(self.monitor.publisher, self.new_publisher)

    def test_writer_install_failure_retains_detached_publisher_for_recovery(self):
        coordinator = self.coordinator()
        with mock.patch.object(self.monitor, 'replace_publisher', side_effect=ValueError('install')):
            result = coordinator.run_once()
        self.assertEqual(result, {'state': 'applied', 'recovery_required': True})
        self.assertEqual(self.store.state['status'], 'applied')
        self.assertIs(coordinator._recovery_publisher, self.new_publisher)
        self.assertIsNot(self.stage.private_client, self.client)
        self.assertIs(self.monitor.publisher, self.old_publisher)
        self.assertTrue(self.monitor._publication_suspended)
        self.assertIsNone(self.monitor.poll())
        self.assertIsNone(self.monitor.step(60, 300))
        with self.assertRaises(Exception):
            self.owner.run_operation('firmware', lambda: 'unsafe')

    def test_detach_failure_after_commit_keeps_fence_and_never_publishes_old(self):
        coordinator = self.coordinator()
        def failed_detach(store):
            raise ValueError('SYNTHETIC_SECRET detach failure')
        with mock.patch.object(ProofIO, 'detach_after_commit', failed_detach):
            result = coordinator.run_once()
        self.assertEqual(result, {'state': 'applied', 'recovery_required': True})
        self.assertEqual(self.store.state['status'], 'applied')
        self.assertTrue(self.owner._quarantined)
        self.assertTrue(self.monitor._publication_suspended)
        self.assertIs(self.monitor.publisher, self.old_publisher)
        self.assertIsNone(self.monitor.poll())
        self.assertNotIn('SYNTHETIC_SECRET', repr(result))

    def test_stage_reader_install_failure_keeps_detached_reader_for_recovery(self):
        class FailingReaderStage(ConfigStageCoordinator):
            def __setattr__(self, name, value):
                if name == 'private_client' and getattr(self, 'fail_reader_install', False):
                    raise ValueError('reader install')
                super().__setattr__(name, value)

        coordinator = self.coordinator()
        original_client = self.stage.private_client
        injected_stage = FailingReaderStage(
            self.store, original_client, self.payload_dir, DEVICE,
            lambda size: b'4' * size)
        injected_stage.fail_reader_install = True
        coordinator.stage = injected_stage
        result = coordinator.run_once()
        self.assertEqual(result, {'state': 'applied', 'recovery_required': True})
        self.assertEqual(self.store.state['status'], 'applied')
        self.assertIs(injected_stage.private_client, original_client)
        self.assertIs(coordinator._recovery_private_client.stage_directory, self.stage_dir)
        self.assertIs(coordinator._recovery_publisher, self.new_publisher)
        self.assertTrue(self.owner._quarantined)
        self.assertTrue(self.monitor._publication_suspended)
        self.assertIsNone(self.monitor.poll())

    def test_confirm_readback_failure_rolls_back_and_consumes_change_id(self):
        self.fail_confirmation = True
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'rolled_back', 'reason': 'inconclusive'})
        self.assertEqual(self.store.state['status'], 'rolled_back')
        self.assertIn(CHANGE_2, self.store.state['consumed'])
        self.assertIs(self.monitor.publisher, self.old_publisher)

    def test_trial_deadline_boundary_is_inconclusive_not_applied(self):
        self.advance_wifi_ms = 300000
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'recovery_required'})
        self.assertEqual(self.store.state['status'], 'rolled_back')
        self.assertIs(self.monitor.publisher, self.old_publisher)

    def test_monitor_callbacks_are_fenced_during_candidate_gist_reads(self):
        results = []
        original = ProofIO.confirm_exact
        def during_get(io, filename, content, service=None):
            if filename == 'diagnostics.json':
                self.assertIn('confirm:thermostat.txt', self.events)
                results.extend((self.monitor.poll(), self.monitor.step(60, 300)))
            return original(io, filename, content, service)
        with mock.patch.object(ProofIO, 'confirm_exact', during_get):
            result = self.coordinator().run_once()
        self.assertEqual(result['state'], 'applied')
        self.assertEqual(results, [None, None])
        self.assertEqual(self.old_publisher.temperatures, [])

    def test_corrupt_applied_payload_requires_recovery_and_keeps_fence(self):
        path = self.payload_dir + '/' + self.store.state['applied'][0]
        with open(path, 'wb') as handle:
            handle.write(b'corrupt')
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'recovery_required'})
        self.assertTrue(self.monitor._publication_suspended)
        self.assertTrue(self.owner._quarantined)

    def test_report_false_is_pending_but_candidate_monitoring_resumes(self):
        self.new_publisher.publish_diagnostics = lambda unused: False
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'applied', 'recovery_required': False,
                                  'report_pending': True})
        self.assertIs(self.monitor.publisher, self.new_publisher)
        self.assertFalse(self.monitor._publication_suspended)

    def test_close_old_publisher_error_keeps_candidate_active_and_quarantines(self):
        def broken_close():
            raise OSError('cleanup')
        self.old_publisher.close = broken_close
        result = self.coordinator().run_once()
        self.assertEqual(result['state'], 'applied')
        self.assertTrue(result['recovery_required'])
        self.assertIs(self.monitor.publisher, self.new_publisher)
        self.assertTrue(self.owner._quarantined)
        self.assertTrue(self.monitor._publication_suspended)
        self.assertIsNone(self.monitor.poll())

    def test_old_private_close_failure_scrubs_token_and_resumes_installed_candidate(self):
        class BrokenTransport:
            def __init__(self):
                self.token = bytearray(b'old-reader-secret')
                self._closed = False

            def close(self):
                raise OSError('old-reader-secret close failure')

        old_transport = BrokenTransport()
        self.client.transport = old_transport
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'applied', 'recovery_required': True})
        self.assertEqual(bytes(old_transport.token), b'\x00' * len(b'old-reader-secret'))
        self.assertTrue(old_transport._closed)
        self.assertIs(self.monitor.publisher, self.new_publisher)
        self.assertFalse(self.monitor._publication_suspended)
        self.assertTrue(self.owner._quarantined)

    def test_fence_refusal_defers_without_staging(self):
        self.monitor._normal_publication_active = True
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'deferred'})
        self.assertEqual(self.store.state['status'], 'ready')
        self.assertEqual(self.events, [])

    def test_candidate_corruption_is_rejected_without_recovery_quarantine(self):
        coordinator = self.coordinator()
        original = coordinator._read_ref
        def corrupted(reference, revision, change_id):
            if change_id == CHANGE_2:
                raise ValueError('candidate wifi-secret read-secret')
            return original(reference, revision, change_id)
        coordinator._read_ref = corrupted
        result = coordinator.run_once()
        self.assertEqual(result, {'state': 'rejected'})
        self.assertEqual(self.store.state['status'], 'rejected')
        self.assertFalse(self.monitor._publication_suspended)
        self.assertFalse(self.owner._quarantined)
        self.assertNotIn('secret', repr(result))

    def test_restore_failure_keeps_fence_and_quarantines_operations(self):
        self.fail_confirmation = True
        coordinator = self.coordinator()
        coordinator.restore_applied = lambda applied, remaining, service: False
        result = coordinator.run_once()
        self.assertEqual(result, {'state': 'recovery_required'})
        self.assertTrue(self.monitor._publication_suspended)
        self.assertTrue(self.owner._quarantined)

    def test_ambiguous_commit_readback_fails_closed(self):
        original = self.store.expire_or_confirm
        def commit_then_ambiguous(now, proof=None):
            original(now, proof)
            raise OSError('wifi-secret read-secret')
        self.store.expire_or_confirm = commit_then_ambiguous
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'recovery_required'})
        self.assertTrue(self.monitor._publication_suspended)
        self.assertTrue(self.owner._quarantined)
        self.assertNotIn('secret', repr(result))

    def test_clock_wrap_uses_local_trial_start(self):
        self.clock.now = (1 << 30) - 50
        self.clock.ticks_diff = lambda current, previous: ((current - previous + (1 << 29)) % (1 << 30)) - (1 << 29)
        self.clock_diff = lambda now, previous: ((now - previous + (1 << 29)) % (1 << 30)) - (1 << 29)
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'applied', 'recovery_required': False})

    def test_post_commit_late_report_is_applied_with_explicit_warning(self):
        def late_report(unused):
            self.clock.now += 300001
            return True
        self.new_publisher.publish_diagnostics = late_report
        result = self.coordinator().run_once()
        self.assertEqual(result['state'], 'applied')
        self.assertEqual(result['warning'], 'committed result completed after trial deadline')
        self.assertIs(self.monitor.publisher, self.new_publisher)

    def test_second_run_private_get_outage_keeps_current_applied_monitoring(self):
        first = self.coordinator().run_once()
        self.assertEqual(first['state'], 'applied')
        applied_state = dict(self.store.state)
        self.stage.private_client.contents = fleet(REV_3, CHANGE_3)
        def failed_fetch(service=None):
            raise OSError('SYNTHETIC_SECRET fetch failed')
        self.client.fetch_to_stage = failed_fetch
        result = self.coordinator().run_once()
        self.assertEqual(result, {'state': 'rejected'})
        self.assertFalse(self.owner._quarantined)
        self.assertFalse(self.monitor._publication_suspended)
        self.assertEqual(self.store.state['applied'], applied_state['applied'])
        self.assertEqual(self.store.state['applied_change_id'], applied_state['applied_change_id'])
        self.monitor.poll()
        self.assertEqual(len(self.new_publisher.temperatures), 1)
        self.assertEqual(self.old_publisher.temperatures, [])

    def test_real_candidate_proof_io_transfers_writer_and_scrubs_private_token(self):
        callbacks = []
        coordinator, instances, candidate_tokens = self.real_io_coordinator(callbacks)
        result = coordinator.run_once()
        self.assertEqual(result['state'], 'applied')
        self.assertEqual(callbacks, [None, None])
        io = instances[0]
        self.assertEqual(bytes(candidate_tokens[0]), b'read-new')
        self.assertEqual(bytes(self.old_stage_client.transport.token),
                         b'\x00' * len(b'read-old'))
        self.assertTrue(self.old_stage_client.transport._closed)
        self.assertIsNone(io._publisher)
        self.assertEqual(bytes(self.monitor.publisher._token), b'write-secret')
        self.assertFalse(self.monitor._publication_suspended)

    def test_real_reader_is_retired_when_publisher_install_fails_before_install(self):
        coordinator, instances, candidate_tokens = self.real_io_coordinator()
        with mock.patch.object(self.monitor, 'replace_publisher',
                               side_effect=ValueError('publisher install')):
            result = coordinator.run_once()

        self.assertEqual(result, {'state': 'applied', 'recovery_required': True})
        old_transport = self.old_stage_client.transport
        self.assertEqual(bytes(old_transport.token), b'\x00' * len(b'read-old'))
        self.assertTrue(old_transport._closed)
        candidate_client = self.stage.private_client
        self.assertIsNot(candidate_client, self.old_stage_client)
        self.assertIsNone(coordinator._recovery_private_client)
        self.assertEqual(bytes(candidate_tokens[0]), b'read-new')
        self.assertIs(self.monitor.publisher, self.old_publisher)
        self.assertTrue(self.monitor._publication_suspended)
        self.assertTrue(self.owner._quarantined)
        self.assertIsNotNone(coordinator._recovery_publisher)
        self.assertIsNone(coordinator._recovery_private_client)

    def test_real_stage_reader_install_failure_preserves_current_reader_token(self):
        class FailingReaderStage(ConfigStageCoordinator):
            def __setattr__(self, name, value):
                if name == 'private_client' and getattr(self, 'fail_reader_install', False):
                    raise ValueError('reader install')
                super().__setattr__(name, value)

        coordinator, instances, unused_tokens = self.real_io_coordinator()
        old_stage_client = self.stage.private_client
        injected_stage = FailingReaderStage(
            self.store, old_stage_client, self.payload_dir, DEVICE,
            lambda size: b'4' * size)
        injected_stage.fail_reader_install = True
        coordinator.stage = injected_stage

        result = coordinator.run_once()

        self.assertEqual(result, {'state': 'applied', 'recovery_required': True})
        self.assertIs(injected_stage.private_client, old_stage_client)
        self.assertEqual(bytes(old_stage_client.transport.token), b'read-old')
        self.assertFalse(old_stage_client.transport._closed)
        self.assertTrue(self.owner._quarantined)
        self.assertTrue(self.monitor._publication_suspended)
        candidate_client = coordinator._recovery_private_client
        self.assertIsNotNone(candidate_client)
        self.assertIsNot(candidate_client, old_stage_client)
        self.assertIsNotNone(coordinator._recovery_publisher)

    def test_real_candidate_proof_io_failure_scrubs_both_tokens_after_rollback(self):
        callbacks = []
        coordinator, instances, unused_tokens = self.real_io_coordinator(callbacks, fail_readback=True)
        result = coordinator.run_once()
        self.assertEqual(result, {'state': 'rolled_back', 'reason': 'inconclusive'})
        self.assertEqual(callbacks, [None, None])
        io = instances[0]
        self.assertEqual(bytes(io._private_transport.token), b'\x00' * len(b'read-new'))
        self.assertEqual(bytes(io._publisher._token), b'\x00' * 12)
        self.assertIs(self.monitor.publisher, self.old_publisher)
        self.assertEqual(bytes(self.old_stage_client.transport.token), b'read-old')
        self.assertFalse(self.old_stage_client.transport._closed)
        self.assertFalse(self.monitor._publication_suspended)

    def test_real_reader_handoff_supports_a_second_candidate_after_old_token_revoked(self):
        coordinator, instances, candidate_tokens = self.real_io_coordinator()
        first = coordinator.run_once()
        self.assertEqual(first['state'], 'applied')
        self.assertEqual(self.store.state['applied_change_id'], CHANGE_2)
        self.assertEqual(bytes(candidate_tokens[0]), b'read-new')
        first_client = self.stage.private_client
        self.assertIsNot(first_client, self.old_stage_client)
        self.assertEqual(bytes(self.old_stage_client.transport.token),
                         b'\x00' * len(b'read-old'))
        self.assertTrue(self.old_stage_client.transport._closed)

        next_fleet = fleet(REV_3, CHANGE_3, read_token='read-third')
        def fetch_third(service=None):
            path = self.stage_dir + '/third-download.json'
            with open(path, 'wb') as handle:
                handle.write(next_fleet)
            return path, (len(next_fleet), hashlib.sha256(next_fleet).hexdigest())
        first_client.fetch_to_stage = fetch_third
        self.stage.random_bytes = lambda size: b'3' * size
        read_new_token = first_client.transport.token

        second = coordinator.run_once()
        self.assertEqual(second['state'], 'applied')
        self.assertEqual(self.store.state['applied_change_id'], CHANGE_3)
        self.assertIsNot(self.stage.private_client, first_client)
        self.assertEqual(bytes(candidate_tokens[1]), b'read-third')
        self.assertEqual(bytes(read_new_token), b'\x00' * len(read_new_token))
        self.assertTrue(first_client.transport._closed)
        self.assertFalse(self.monitor._publication_suspended)

    def test_real_store_readback_failure_invalidates_and_scrubs_without_leaking(self):
        coordinator, instances, unused_tokens = self.real_io_coordinator()
        original_open = builtins.open
        enabled = {'value': False}
        def failing_open(path, mode='r', *args, **kwargs):
            if enabled['value'] and mode == 'rb' and str(path).endswith('config.a'):
                raise OSError('SYNTHETIC_SECRET readback')
            return original_open(path, mode, *args, **kwargs)
        original_expire = self.store.expire_or_confirm
        def enable_fault(now, proof=None):
            enabled['value'] = True
            try:
                return original_expire(now, proof)
            finally:
                enabled['value'] = False
        self.store.expire_or_confirm = enable_fault
        with mock.patch('builtins.open', side_effect=failing_open):
            with self.assertRaises(Exception) as raised:
                coordinator.run_once()
        self.assertNotIn('SYNTHETIC_SECRET', str(raised.exception))
        full_traceback = ''.join(traceback.format_exception(raised.exception))
        self.assertNotIn('SYNTHETIC_SECRET', full_traceback)
        self.assertIsNone(self.store.state)
        self.assertTrue(self.monitor._publication_suspended)
        self.assertTrue(self.owner._quarantined)
        io = instances[0]
        self.assertEqual(bytes(io._private_transport.token), b'\x00' * len(b'read-new'))
        self.assertEqual(bytes(io._publisher._token), b'\x00' * 12)
        self.assertIsNone(self.monitor.poll())
        self.assertIsNone(self.monitor.step(60, 300))
        with self.assertRaises(Exception):
            self.coordinator().run_once()


if __name__ == '__main__':
    unittest.main()
