import os
import builtins
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[3]
PICO = ROOT / 'firmware' / 'pico'
import sys
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(PICO))

from firmware.pico.candidate_manifest import Candidate, AssetDescriptor, CandidateError
from firmware.pico.firmware_supervisor import FirmwareSupervisor, FirmwareSupervisorError
from firmware.pico import slot_storage
from firmware.pico.slot_storage import FixedSlotStorage, SlotStorageError
from firmware.pico.update_state import UpdateState, UpdateStateStore
from tool.pico_release.manifest import build_candidate


class Clock:
    @staticmethod
    def ticks_ms():
        return 1

    @staticmethod
    def ticks_diff(now, start):
        return now - start


class Transport:
    def __init__(self):
        self.assets = {}
        self.calls = []

    def fetch_asset(self, release_id, name, writer, max_bytes,
                    expected_size=None, service=None):
        self.calls.append((release_id, name))
        data = self.assets[(release_id, name)]
        if service is not None:
            service()
        for offset in range(0, len(data), 1024):
            writer(data[offset:offset + 1024])
        return {'content-length': str(len(data))}


class SlotStorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name
        self.paths = {}
        for slot in ('A', 'B'):
            path = os.path.join(self.root, slot)
            os.mkdir(path)
            os.mkdir(os.path.join(path, 'lib'))
            self.paths[slot] = path
        self.private = Ed25519PrivateKey.generate()
        self.public = self.private.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.transport = Transport()
        self.clock = Clock()
        self.store = UpdateStateStore(os.path.join(self.root, 'metadata'))
        os.mkdir(os.path.join(self.root, 'metadata'))
        self.store.initialize({
            'applied_slot': 'A', 'applied_id': 1,
            'retained_slot': 'B', 'retained_id': 1,
            'installed_high_water': 1, 'failed_high_water': 0,
            'pending_slot': None, 'pending_id': None,
            'trial_marker': None, 'phase': None,
        })
        self.state = UpdateState(self.store, self.clock.ticks_ms,
                                 self.clock.ticks_diff)
        self.applied_assets = {'app.mpy': b'applied image', 'lib/keep.mpy': b'keep'}
        self.raw1, self.sig1 = build_candidate(1, 'v1.29.0', self.applied_assets,
                                               self.private)
        self._put_slot('A', self.raw1, self.sig1, self.applied_assets)
        self.launches = []
        self.storage = FixedSlotStorage(self.state, self.paths['A'],
                                        self.paths['B'], self.transport)
        self.supervisor = self._supervisor()

    def tearDown(self):
        self.temp.cleanup()

    def _path(self, slot, relative):
        return os.path.join(self.paths[slot], *relative.split('/'))

    def _put_slot(self, slot, raw, signature, assets):
        with open(self._path(slot, 'manifest.json'), 'wb') as stream:
            stream.write(raw)
        with open(self._path(slot, 'manifest.sig'), 'wb') as stream:
            stream.write(signature)
        for name, data in assets.items():
            with open(self._path(slot, name), 'wb') as stream:
                stream.write(data)

    def _supervisor(self, service=None):
        def verifier(signature, key, message):
            try:
                self.private.public_key().verify(signature, message)
                return key == self.public
            except Exception:
                return False

        return FirmwareSupervisor(
            self.state, self.public, verifier, 'RPI_PICO2_W', 'v1.29.1',
            self.storage.slot_reader, self.storage.stage_writer,
            self.launches.append, self.clock.ticks_ms, self.clock.ticks_diff,
            lambda *_: True, service=service)

    def _candidate(self, release_id=2, assets=None):
        assets = assets or {'app.mpy': b'new app', 'lib/sensor.mpy': b'sensor'}
        raw, signature = build_candidate(release_id, 'v1.29.0', assets, self.private)
        for name, data in assets.items():
            self.transport.assets[(release_id, os.path.basename(name))] = data
        return raw, signature, assets

    def _stage(self, release_id=2, assets=None):
        raw, signature, _ = self._candidate(release_id, assets)
        return self.supervisor.admit_and_stage(raw, signature,
                                                'pico-' + str(release_id),
                                                'marker-' + str(release_id))

    def _bytes(self, slot, relative):
        with open(self._path(slot, relative), 'rb') as stream:
            return stream.read()

    def test_supervisor_stages_verified_b_then_alternates_after_promotion(self):
        old = {name: self._bytes('A', name) for name in
               ('manifest.json', 'manifest.sig', 'app.mpy', 'lib/keep.mpy')}
        self.assertEqual(self._stage(), 'B')
        self.assertEqual(self._bytes('A', 'app.mpy'), old['app.mpy'])
        self.assertEqual(self._bytes('A', 'lib/keep.mpy'), old['lib/keep.mpy'])
        self.assertEqual(self.storage.slot_reader('B')[0], self._bytes('B', 'manifest.json'))
        self.assertEqual(self.launches, ['B'])
        self.assertTrue(self.supervisor.trial_ok(2, 'marker-2', True))
        self.assertEqual(self._stage(3, {'app.mpy': b'v3'}), 'A')
        self.assertEqual(self._bytes('B', 'app.mpy'), b'new app')
        self.assertEqual(self.launches, ['B', 'A'])

    def test_bad_signature_has_no_storage_or_transport_effect(self):
        raw, signature, _ = self._candidate()
        before = self._bytes('A', 'app.mpy')
        with self.assertRaises(CandidateError):
            self.supervisor.admit_and_stage(raw, bytes([signature[0] ^ 1]) + signature[1:],
                                            'pico-2', 'bad')
        self.assertEqual(self._bytes('A', 'app.mpy'), before)
        self.assertEqual(self.transport.calls, [])

    def test_wrong_state_fails_before_any_file_or_transport_effect(self):
        raw, signature, _ = self._candidate()
        candidate = self.supervisor._authenticate(raw, signature, 'pico-2')
        before = self._bytes('A', 'app.mpy')
        for slot in ('A', 'B'):
            with self.subTest(slot=slot):
                with self.assertRaises(SlotStorageError):
                    self.storage.stage_writer(slot, candidate, raw, signature)
        self.state.stage_candidate(2, 'marker', True, True)
        self.store.state['pending_id'] = 3
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, raw, signature)
        self.assertEqual(self._bytes('A', 'app.mpy'), before)
        self.assertEqual(self.transport.calls, [])
        self.store._invalidate()
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, raw, signature)
        self.assertEqual(self.transport.calls, [])

    def test_unknown_nested_and_symlink_entries_rejected_before_cleanup(self):
        self.state.stage_candidate(2, 'marker', True, True)
        nested = os.path.join(self.paths['B'], 'lib', 'nested')
        os.mkdir(nested)
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', Candidate(2, 'v1.29.0', (AssetDescriptor('app.mpy', 'app.mpy', 1, '0' * 64),)), b'x', b's' * 64)
        self.assertTrue(os.path.isdir(nested))
        os.rmdir(nested)
        unexpected = self._path('B', 'intruder')
        with open(unexpected, 'wb') as stream:
            stream.write(b'x')
        candidate = Candidate(2, 'v1.29.0', (AssetDescriptor('app.mpy', 'app.mpy', 1, '0' * 64),))
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, b'x', b's' * 64)
        self.assertTrue(os.path.exists(unexpected))
        os.remove(unexpected)
        link = self._path('B', 'app.mpy')
        try:
            os.symlink(self._path('A', 'app.mpy'), link)
        except (OSError, NotImplementedError):
            self.skipTest('host does not permit symlink test creation')
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, b'x', b's' * 64)
        self.assertEqual(self._bytes('A', 'app.mpy'), b'applied image')

    def test_candidate_reserved_manifest_names_are_unknown_in_inactive_slot(self):
        self.state.stage_candidate(2, 'marker', True, True)
        raw, signature, _ = self._candidate(assets={'app.mpy': b'next'})
        candidate = self.supervisor._authenticate(raw, signature, 'pico-2')
        for name in ('manifest.json.mpy', 'manifest.sig.mpy'):
            path = self._path('B', 'lib/' + name)
            with open(path, 'wb') as stream:
                stream.write(b'foreign')
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, raw, signature)
        self.assertTrue(os.path.exists(self._path('B', 'lib/manifest.json.mpy')))
        self.assertTrue(os.path.exists(self._path('B', 'lib/manifest.sig.mpy')))
        self.assertEqual(self.transport.calls, [])

    def test_root_alias_spellings_are_rejected_before_any_effect(self):
        before = self._bytes('A', 'app.mpy')
        root_a = self.paths['A']
        cases = (
            ('/slots/A', '/slots//A'),
            (root_a, root_a + '/'),
            (root_a, os.path.join(root_a, 'lib')),
            ('C:/slots/A', 'c:/slots/a'),
            ('C:/slots/A', 'c:\\slots\\a\\'),
        )
        for first, second in cases:
            with self.subTest(first=first, second=second):
                with self.assertRaises(SlotStorageError):
                    FixedSlotStorage(self.state, first, second, self.transport)
                self.assertEqual(self._bytes('A', 'app.mpy'), before)
                self.assertEqual(self.transport.calls, [])

    def test_existing_root_identity_alias_is_rejected_when_host_can_make_symlink(self):
        alias = os.path.join(self.root, 'alias-to-A')
        try:
            os.symlink(self.paths['A'], alias, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest('host does not permit symlink test creation')
        before = self._bytes('A', 'app.mpy')
        with self.assertRaises(SlotStorageError):
            FixedSlotStorage(self.state, self.paths['A'], alias, self.transport)
        self.assertEqual(self._bytes('A', 'app.mpy'), before)
        self.assertEqual(self.transport.calls, [])

    def test_typebits_zero_falls_back_to_lstat_and_rejects_symlink(self):
        self.assertEqual(slot_storage._kind(self.paths['A'], ('A', 0)), 'dir')
        self.assertEqual(slot_storage._kind(self._path('A', 'app.mpy'), ('app.mpy', 0)),
                         'file')
        link = self._path('B', 'app.mpy')
        try:
            os.symlink(self._path('A', 'app.mpy'), link)
        except (OSError, NotImplementedError):
            self.skipTest('host does not permit symlink test creation')
        self.assertEqual(slot_storage._kind(link, ('app.mpy', 0)), 'other')

    def test_service_failure_is_redacted_before_inactive_slot_mutation(self):
        self.state.stage_candidate(2, 'marker', True, True)
        raw, signature, _ = self._candidate(assets={'app.mpy': b'next'})
        candidate = self.supervisor._authenticate(raw, signature, 'pico-2')
        sentinel = self._path('B', 'app.mpy')
        with open(sentinel, 'wb') as stream:
            stream.write(b'preserve')

        def fail_service(_count):
            raise RuntimeError('SECRET_CHECKPOINT')

        storage = FixedSlotStorage(self.state, self.paths['A'], self.paths['B'],
                                   self.transport, service=fail_service)
        with self.assertRaises(SlotStorageError) as raised:
            storage.stage_writer('B', candidate, raw, signature)
        self.assertNotIn('SECRET_CHECKPOINT', str(raised.exception))
        self.assertEqual(self._bytes('B', 'app.mpy'), b'preserve')
        self.assertEqual(self.transport.calls, [])

    def test_metadata_short_write_flush_and_close_failures_are_redacted(self):
        self.state.stage_candidate(2, 'marker', True, True)
        raw, signature, _ = self._candidate(assets={'app.mpy': b'next'})
        candidate = self.supervisor._authenticate(raw, signature, 'pico-2')
        real_open = builtins.open

        class BrokenStream:
            def __init__(self, failure):
                self.failure = failure

            def write(self, data):
                return len(data) - 1 if self.failure == 'short' else len(data)

            def flush(self):
                if self.failure == 'flush':
                    raise OSError('SECRET_FLUSH')

            def close(self):
                if self.failure == 'close':
                    raise OSError('SECRET_CLOSE')

        for failure in ('short', 'flush', 'close'):
            with self.subTest(failure=failure):
                storage = FixedSlotStorage(self.state, self.paths['A'],
                                           self.paths['B'], self.transport)

                def open_with_failure(path, mode='r', *args, **kwargs):
                    if mode == 'wb':
                        return BrokenStream(failure)
                    return real_open(path, mode, *args, **kwargs)

                with mock.patch('builtins.open', side_effect=open_with_failure):
                    with self.assertRaises(SlotStorageError) as raised:
                        storage.stage_writer('B', candidate, raw, signature)
                self.assertNotIn('SECRET_', str(raised.exception))
                self.assertEqual(self._bytes('A', 'app.mpy'), b'applied image')
                self.assertEqual(self.transport.calls, [])

    def test_interrupted_writing_boot_suppresses_candidate_and_launches_applied(self):
        self.state.stage_candidate(2, 'marker', True, True)
        rebooted_store = UpdateStateStore(os.path.join(self.root, 'metadata'))
        rebooted_store.load()
        rebooted = UpdateState(rebooted_store, self.clock.ticks_ms,
                               self.clock.ticks_diff)
        launches = []
        supervisor = FirmwareSupervisor(
            rebooted, self.public, self.supervisor._verifier, 'RPI_PICO2_W', 'v1.29.1',
            self.storage.slot_reader, self.storage.stage_writer, launches.append,
            self.clock.ticks_ms, self.clock.ticks_diff, lambda *_: True)
        self.assertEqual(supervisor.boot(), 'A')
        self.assertEqual(launches, ['A'])
        self.assertEqual(rebooted.state['applied_slot'], 'A')
        self.assertEqual(rebooted.state['failed_high_water'], 2)

    def test_inventory_caps_reject_before_cleanup_or_transport(self):
        self.state.stage_candidate(2, 'marker', True, True)
        raw, signature, _ = self._candidate(assets={'app.mpy': b'next'})
        candidate = self.supervisor._authenticate(raw, signature, 'pico-2')
        retained = self._path('B', 'app.mpy')
        with open(retained, 'wb') as stream:
            stream.write(b'do not delete')
        lib_files = []
        for index in range(8):
            name = 'module%d.mpy' % index
            path = self._path('B', 'lib/' + name)
            with open(path, 'wb') as stream:
                stream.write(b'x')
            lib_files.append(path)
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, raw, signature)
        self.assertEqual(self._bytes('B', 'app.mpy'), b'do not delete')
        self.assertTrue(all(os.path.exists(path) for path in lib_files))
        self.assertEqual(self.transport.calls, [])

        for name in ('lib/module0.mpy', 'lib/module1.mpy', 'lib/module2.mpy',
                     'manifest.json', 'manifest.sig'):
            path = self._path('B', name)
            if not os.path.exists(path):
                with open(path, 'wb') as stream:
                    stream.write(b'x')
        fifth = self._path('B', 'unexpected')
        with open(fifth, 'wb') as stream:
            stream.write(b'x')
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, raw, signature)
        self.assertTrue(os.path.exists(fifth))
        self.assertEqual(self.transport.calls, [])

    def test_entry_enumerator_stops_after_limit_plus_one_and_closes(self):
        observed = {'count': 0, 'closed': False}

        class LargeEnumeration:
            def __iter__(inner):
                return inner

            def __next__(inner):
                observed['count'] += 1
                return ('app.mpy', 0x8000, 0, 0)

            def close(inner):
                observed['closed'] = True

        with mock.patch.object(slot_storage.os, 'ilistdir',
                               return_value=LargeEnumeration(), create=True):
            with self.assertRaises(SlotStorageError):
                slot_storage._entry_names(self.root, 4, lambda name: True)
        self.assertEqual(observed['count'], 5)
        self.assertTrue(observed['closed'])

    def test_signed_zero_byte_asset_is_downloaded_and_staged(self):
        self._stage(2, {'app.mpy': b''})
        self.assertEqual(self._bytes('B', 'app.mpy'), b'')
        self.assertIn((2, 'app.mpy'), self.transport.calls)

    def test_partial_and_transport_errors_never_change_applied_slot_or_launch(self):
        self.state.stage_candidate(2, 'marker', True, True)
        raw, signature, assets = self._candidate()
        candidate = self.supervisor._authenticate(raw, signature, 'pico-2')

        class ShortTransport:
            def fetch_asset(inner, release_id, name, writer, max_bytes,
                            expected_size=None, service=None):
                data = assets[name if name == 'app.mpy' else 'lib/' + name]
                writer(data[:1])

        self.storage._transport = ShortTransport()
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, raw, signature)
        self.assertEqual(self._bytes('A', 'app.mpy'), b'applied image')
        self.assertEqual(self.launches, [])

        class FailedTransport:
            def fetch_asset(inner, *args, **kwargs):
                raise OSError('private transport detail')

        self.storage._transport = FailedTransport()
        with self.assertRaises(SlotStorageError):
            self.storage.stage_writer('B', candidate, raw, signature)
        self.assertEqual(self._bytes('A', 'app.mpy'), b'applied image')
        self.assertEqual(self.launches, [])

    def test_metadata_written_before_first_asset_request_and_tampering_rejected(self):
        class ObservingTransport(Transport):
            def fetch_asset(inner, release_id, name, writer, max_bytes,
                            expected_size=None, service=None):
                self.assertEqual(self._bytes('B', 'manifest.json'), self.raw2)
                self.assertEqual(self._bytes('B', 'manifest.sig'), self.sig2)
                source = inner.assets[(release_id, name)]
                data = (bytes([source[0] ^ 1]) + source[1:]) if source else source
                writer(data)

        self.raw2, self.sig2, assets = self._candidate()
        transport = ObservingTransport()
        transport.assets = self.transport.assets
        self.storage._transport = transport
        with self.assertRaises(FirmwareSupervisorError):
            self.supervisor.admit_and_stage(self.raw2, self.sig2, 'pico-2', 'marker-2')
        # The transport wrote one asset with no digest check; supervisor rereads it.
        self.assertEqual(self.launches, [])
        self.assertEqual(self.state.state['applied_slot'], 'A')
        self.assertIsNone(self.state.state['phase'])
        self.assertEqual(self._bytes('A', 'app.mpy'), b'applied image')

    def test_successful_metadata_ordering_precedes_asset_request(self):
        class OrderingTransport(Transport):
            def fetch_asset(inner, release_id, name, writer, max_bytes,
                            expected_size=None, service=None):
                self.assertEqual(self._bytes('B', 'manifest.json'), raw)
                self.assertEqual(self._bytes('B', 'manifest.sig'), signature)
                return super(OrderingTransport, inner).fetch_asset(
                    release_id, name, writer, max_bytes, expected_size, service)

        raw, signature, _ = self._candidate()
        transport = OrderingTransport()
        transport.assets = self.transport.assets
        self.storage._transport = transport
        self.assertEqual(self.supervisor.admit_and_stage(
            raw, signature, 'pico-2', 'marker-2'), 'B')
        self.assertEqual(self.launches, ['B'])


if __name__ == '__main__':
    unittest.main()
