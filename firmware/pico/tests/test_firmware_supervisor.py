import io
import importlib
import os
from pathlib import Path
import socket
import sys
import tempfile
import traceback
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
PICO = ROOT / 'firmware' / 'pico'
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(PICO))

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from firmware.pico.firmware_supervisor import (
    FirmwareSupervisor, FirmwareSupervisorError, RecoveryRequiredError,
)
from firmware.pico.update_state import (
    RecoveryRequired, StateWriteError, UpdateState, UpdateStateStore,
)
from tool.pico_release.manifest import build_candidate


BOARD = 'RPI_PICO2_W'
ASSETS = {'app.mpy': b'app code', 'lib/sensor.mpy': b'sensor code'}


class Clock:
    def __init__(self):
        self.value = 0

    def ticks_ms(self):
        return self.value

    @staticmethod
    def ticks_diff(now, start):
        return now - start


class Slot:
    def __init__(self, raw, signature, assets):
        self.raw, self.signature, self.assets = raw, signature, dict(assets)

    def list_assets(self):
        return list(self.assets)

    def open_asset(self, path):
        return io.BytesIO(self.assets[path])


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.private = Ed25519PrivateKey.generate()
        self.public = self.private.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.slots = {}
        self.writes = []
        self.launches = []
        self.verify_calls = []
        self.clock = Clock()
        self.confirmed = True
        self.store = UpdateStateStore(self.temp.name)
        self.store.initialize({
            'applied_slot': 'A', 'applied_id': 1,
            'retained_slot': 'B', 'retained_id': 1,
            'installed_high_water': 1, 'failed_high_water': 0,
            'pending_slot': None, 'pending_id': None,
            'trial_marker': None, 'phase': None,
        })
        self.model = UpdateState(self.store, self.clock.ticks_ms,
                                 self.clock.ticks_diff)
        self.raw1, self.sig1 = build_candidate(1, 'v1.29.0', ASSETS, self.private)
        self.slots['A'] = Slot(self.raw1, self.sig1, ASSETS)
        self.sup = self.make_supervisor()

    def tearDown(self):
        self.temp.cleanup()

    def verifier(self, signature, key, message):
        self.verify_calls.append((signature, key, message))
        try:
            self.private.public_key().verify(signature, message)
            return key == self.public
        except Exception:
            return False

    def reader(self, slot):
        saved = self.slots[slot]
        return saved.raw, saved.signature, saved

    def writer(self, slot, candidate, raw, signature):
        self.writes.append((slot, self.store.state['phase']))
        self.slots[slot] = Slot(raw, signature, ASSETS)

    def make_supervisor(self, reporter=None, service=None):
        return FirmwareSupervisor(
            self.model, self.public, self.verifier, BOARD, 'v1.29.1',
            self.reader, self.writer, self.launches.append,
            self.clock.ticks_ms, self.clock.ticks_diff,
            reporter or (lambda release_id, marker: self.confirmed),
            service=service)

    def candidate(self, rid=2):
        return build_candidate(rid, 'v1.29.0', ASSETS, self.private)

    def stage(self, rid=2):
        raw, sig = self.candidate(rid)
        return self.sup.admit_and_stage(raw, sig, 'pico-' + str(rid), 'marker-' + str(rid))

    def reboot(self):
        self.store = UpdateStateStore(self.temp.name)
        self.store.load()
        self.model = UpdateState(self.store, self.clock.ticks_ms,
                                 self.clock.ticks_diff)
        self.sup = self.make_supervisor()

    def test_invalid_signature_key_or_board_do_not_write(self):
        raw, sig = self.candidate()
        bad = bytes([sig[0] ^ 1]) + sig[1:]
        with self.assertRaises(Exception):
            self.sup.admit_and_stage(raw, bad, 'pico-2', 'm')
        with self.assertRaises(Exception):
            self.sup.admit_and_stage(raw, sig, 'pico-3', 'm')
        self.assertEqual(self.writes, [])
        other = Ed25519PrivateKey.generate().public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        invalid = FirmwareSupervisor(self.model, other, self.verifier, BOARD, 'v1.29.1',
                                     self.reader, self.writer, self.launches.append,
                                     self.clock.ticks_ms, self.clock.ticks_diff,
                                     lambda *_: True)
        with self.assertRaises(Exception):
            invalid.admit_and_stage(raw, sig, 'pico-2', 'm')
        wrong_board = FirmwareSupervisor(self.model, self.public, self.verifier,
                                         'RPI_PICO2', 'v1.29.1', self.reader,
                                         self.writer, self.launches.append,
                                         self.clock.ticks_ms, self.clock.ticks_diff,
                                         lambda *_: True)
        with self.assertRaises(Exception):
            wrong_board.admit_and_stage(raw, sig, 'pico-2', 'm')
        self.assertEqual(self.writes, [])

    def test_writing_is_committed_before_slot_writer(self):
        self.stage()
        self.assertEqual(self.writes, [('B', 'writing')])
        raw, signature = self.candidate()
        self.assertEqual(self.verify_calls[-2:], [(signature, self.public, raw)] * 2)
        self.assertEqual(self.store.state['phase'], 'trial_entered')
        self.assertEqual(self.launches, ['B'])

    def test_invalid_staged_inventory_or_assets_fails_without_launch(self):
        for index, replacement in enumerate((
                {'app.mpy': ASSETS['app.mpy'][:-1], 'lib/sensor.mpy': ASSETS['lib/sensor.mpy']},
                {'app.mpy': ASSETS['app.mpy'], 'lib/sensor.mpy': ASSETS['lib/sensor.mpy'], 'extra.mpy': b'x'},
                {'app.mpy': ASSETS['app.mpy']})):
            with self.subTest(replacement=replacement):
                metadata_dir = os.path.join(self.temp.name, str(index))
                os.mkdir(metadata_dir)
                self.store = UpdateStateStore(metadata_dir)
                self.store.initialize({
                    'applied_slot': 'A', 'applied_id': 1, 'retained_slot': 'B', 'retained_id': 1,
                    'installed_high_water': 1, 'failed_high_water': 0, 'pending_slot': None,
                    'pending_id': None, 'trial_marker': None, 'phase': None})
                self.model = UpdateState(self.store, self.clock.ticks_ms, self.clock.ticks_diff)
                self.writes.clear(); self.launches.clear()

                def broken_writer(slot, candidate, raw, signature):
                    self.writes.append((slot, self.store.state['phase']))
                    self.slots[slot] = Slot(raw, signature, replacement)

                self.sup = FirmwareSupervisor(self.model, self.public, self.verifier, BOARD,
                                              'v1.29.1', self.reader, broken_writer,
                                              self.launches.append, self.clock.ticks_ms,
                                              self.clock.ticks_diff, lambda *_: True)
                with self.assertRaises(FirmwareSupervisorError):
                    self.stage()
                self.assertEqual(self.launches, [])
                self.assertEqual(self.model.state['applied_slot'], 'A')
                self.assertIsNone(self.model.state['phase'])

    def test_stage_callback_error_is_failed_and_suppressed(self):
        def explode(*_):
            raise OSError('SECRET_LOCATION: write failed')
        self.sup = FirmwareSupervisor(self.model, self.public, self.verifier, BOARD,
                                      'v1.29.1', self.reader, explode,
                                      self.launches.append, self.clock.ticks_ms,
                                      self.clock.ticks_diff, lambda *_: True)
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.stage()
        self.assertEqual(str(raised.exception), 'staging failed; candidate suppressed')
        formatted = ''.join(traceback.format_exception(
            type(raised.exception), raised.exception, raised.exception.__traceback__))
        self.assertNotIn('SECRET_LOCATION', formatted)
        self.assertEqual(self.model.state['failed_high_water'], 2)
        self.assertEqual(self.model.state['applied_slot'], 'A')
        self.assertEqual(self.launches, [])

    def test_launch_error_is_failed_suppressed_and_not_retried(self):
        calls = []

        def launch(slot):
            calls.append(slot)
            raise OSError('SECRET_LAUNCH_LOCATION')

        self.sup = FirmwareSupervisor(self.model, self.public, self.verifier, BOARD,
                                      'v1.29.1', self.reader, self.writer, launch,
                                      self.clock.ticks_ms, self.clock.ticks_diff,
                                      lambda *_: True)
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.stage()
        self.assertEqual(str(raised.exception), 'staging failed; candidate suppressed')
        formatted = ''.join(traceback.format_exception(
            type(raised.exception), raised.exception, raised.exception.__traceback__))
        self.assertNotIn('SECRET_LAUNCH_LOCATION', formatted)
        self.assertEqual(self.model.state['failed_high_water'], 2)
        self.assertEqual(self.model.state['applied_slot'], 'A')
        self.assertEqual(self.model.state['applied_id'], 1)
        self.assertEqual(calls, ['B'])
        writes = list(self.writes)
        raw, signature = self.candidate()
        with self.assertRaises(Exception):
            self.sup.admit_and_stage(raw, signature, 'pico-2', 'marker-2')
        self.assertEqual(self.writes, writes)
        self.assertEqual(calls, ['B'])

    def test_partial_monitor_launch_failure_is_suppressed_without_cleanup_claim(self):
        monitor = []

        def launch(slot):
            monitor.append(slot)
            raise RuntimeError('SECRET_PARTIAL_MONITOR_DETAIL')

        self.sup = FirmwareSupervisor(self.model, self.public, self.verifier, BOARD,
                                      'v1.29.1', self.reader, self.writer, launch,
                                      self.clock.ticks_ms, self.clock.ticks_diff,
                                      lambda *_: True)
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.stage()
        formatted = ''.join(traceback.format_exception(
            type(raised.exception), raised.exception, raised.exception.__traceback__))
        self.assertNotIn('SECRET_PARTIAL_MONITOR_DETAIL', formatted)
        self.assertEqual(str(raised.exception), 'staging failed; candidate suppressed')
        # Cleanup/re-authentication belongs to the trusted launch integration.
        self.assertEqual(monitor, ['B'])
        self.assertEqual(self.model.state['failed_high_water'], 2)
        self.assertEqual(self.model.state['applied_id'], 1)

    def test_launch_failure_with_ambiguous_suppression_is_not_reported_suppressed(self):
        def launch(slot):
            raise OSError('SECRET_LAUNCH_LOCATION')

        self.sup = FirmwareSupervisor(self.model, self.public, self.verifier, BOARD,
                                      'v1.29.1', self.reader, self.writer, launch,
                                      self.clock.ticks_ms, self.clock.ticks_diff,
                                      lambda *_: True)

        def ambiguous_fail():
            self.store._invalidate()
            raise StateWriteError('SECRET_READBACK_LOCATION')

        self.model.fail_trial = ambiguous_fail
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.stage()
        self.assertEqual(str(raised.exception),
                         'failure suppression ambiguous; reload before use')
        formatted = ''.join(traceback.format_exception(
            type(raised.exception), raised.exception, raised.exception.__traceback__))
        self.assertNotIn('SECRET_LAUNCH_LOCATION', formatted)
        self.assertNotIn('SECRET_READBACK_LOCATION', formatted)
        self.assertIsNone(self.store.state)
        self.assertEqual(self.launches, [])

    def test_ambiguous_launch_failure_is_not_suppressed(self):
        def launch(slot):
            raise RecoveryRequired('ambiguous launch metadata')

        self.sup = FirmwareSupervisor(self.model, self.public, self.verifier, BOARD,
                                      'v1.29.1', self.reader, self.writer, launch,
                                      self.clock.ticks_ms, self.clock.ticks_diff,
                                      lambda *_: True)
        with mock.patch.object(self.model, 'fail_trial') as fail_trial:
            with self.assertRaises(RecoveryRequired):
                self.stage()
        fail_trial.assert_not_called()
        self.assertEqual(self.store.state['phase'], 'trial_entered')
        self.assertEqual(self.store.state['applied_id'], 1)

    def test_hash_service_receives_multiple_cumulative_byte_checkpoints(self):
        assets = {'app.mpy': b'x' * 4097}
        raw, signature = build_candidate(2, 'v1.29.0', assets, self.private)
        self.slots['B'] = Slot(raw, signature, assets)
        checkpoints = []
        self.sup = self.make_supervisor(service=checkpoints.append)
        self.sup._verify_slot('B', 2)
        self.assertGreaterEqual(len(checkpoints), 5)
        self.assertEqual(checkpoints, sorted(checkpoints))
        self.assertGreater(checkpoints[-1], 0)

    def test_hash_cancellation_suppresses_candidate_without_applied_change(self):
        assets = {'app.mpy': b'x' * 4097}
        raw, signature = build_candidate(2, 'v1.29.0', assets, self.private)

        def cancel_hash(count):
            return count < 1024

        self.sup = self.make_supervisor(service=cancel_hash)
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.sup.admit_and_stage(raw, signature, 'pico-2', 'marker-2')
        self.assertEqual(str(raised.exception), 'staging failed; candidate suppressed')
        self.assertEqual(self.model.state['applied_id'], 1)
        self.assertIsNone(self.model.state['phase'])
        self.assertEqual(self.launches, [])

    def test_writer_checkpoint_cancellation_never_launches(self):
        checkpoints = []

        def service(count):
            checkpoints.append(count)
            return len(checkpoints) < 2

        self.sup = self.make_supervisor(service=service)
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.stage()
        self.assertEqual(str(raised.exception), 'staging failed; candidate suppressed')
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.launches, [])
        self.assertEqual(self.model.state['applied_id'], 1)
        self.assertIsNone(self.model.state['phase'])

    def test_boot_service_cancellation_requires_usb_recovery(self):
        self.sup = self.make_supervisor(service=lambda count: False)
        with self.assertRaises(RecoveryRequiredError):
            self.sup.boot()
        self.assertEqual(self.launches, [])

    def test_service_exception_is_redacted_from_staging_traceback(self):
        def fail_service(count):
            raise OSError('SECRET_CHECKPOINT_LOCATION')

        self.sup = self.make_supervisor(service=fail_service)
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.stage()
        self.assertEqual(str(raised.exception), 'staging failed; candidate suppressed')
        formatted = ''.join(traceback.format_exception(
            type(raised.exception), raised.exception, raised.exception.__traceback__))
        self.assertNotIn('SECRET_CHECKPOINT_LOCATION', formatted)
        self.assertEqual(self.launches, [])

    def test_service_type_error_is_not_retried_as_no_argument_callback(self):
        calls = []

        def broken_service(count):
            calls.append(count)
            raise TypeError('SECRET_TYPE_ERROR_DETAIL')

        self.sup = self.make_supervisor(service=broken_service)
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.stage()
        formatted = ''.join(traceback.format_exception(
            type(raised.exception), raised.exception, raised.exception.__traceback__))
        self.assertNotIn('SECRET_TYPE_ERROR_DETAIL', formatted)
        self.assertEqual(calls, [0])
        self.assertEqual(self.launches, [])
        self.assertEqual(self.model.state['applied_id'], 1)

    def test_no_argument_service_fails_closed_without_trial_or_launch(self):
        calls = []

        def no_argument_service():
            calls.append(True)
            return True

        self.sup = self.make_supervisor(service=no_argument_service)
        with self.assertRaises(FirmwareSupervisorError) as raised:
            self.stage()
        self.assertEqual(str(raised.exception), 'staging failed; candidate suppressed')
        # Python rejects the incompatible signature before entering the body.
        self.assertEqual(calls, [])
        self.assertEqual(self.launches, [])
        self.assertEqual(self.model.state['applied_id'], 1)
        self.assertIsNone(self.model.state['phase'])

    def test_flat_import_and_package_import_are_supported(self):
        flat_module = importlib.import_module('firmware_supervisor')
        self.assertTrue(hasattr(flat_module, 'FirmwareSupervisor'))
        self.assertEqual(FirmwareSupervisor.__module__, 'firmware.pico.firmware_supervisor')

    def test_micropython_shaped_import_without_package_is_inert(self):
        module = importlib.import_module('firmware.pico.firmware_supervisor')
        source = Path(module.__file__).read_text(encoding='utf-8')
        namespace = {'__name__': 'firmware_supervisor'}
        with mock.patch('builtins.open', wraps=open) as open_file, \
                mock.patch.object(socket, 'create_connection') as connect, \
                mock.patch.object(socket, 'socket') as create_socket:
            exec(compile(source, module.__file__, 'exec'), namespace)
        self.assertNotIn('__package__', namespace)
        self.assertTrue(callable(namespace['FirmwareSupervisor']))
        open_file.assert_not_called()
        connect.assert_not_called()
        create_socket.assert_not_called()

    def test_ambiguous_trial_metadata_commit_never_launches(self):
        raw, sig = self.candidate()
        real = self.model.assets_verified_and_enter_trial
        self.model.assets_verified_and_enter_trial = lambda *_: (_ for _ in ()).throw(
            StateWriteError('ambiguous'))
        with self.assertRaises(StateWriteError):
            self.sup.admit_and_stage(raw, sig, 'pico-2', 'm')
        self.assertEqual(self.launches, [])
        self.model.assets_verified_and_enter_trial = real

    def test_ambiguous_failure_suppression_requires_reload_and_never_launches(self):
        raw, sig = self.candidate()
        real_fail = self.model.fail_trial

        def corrupt_writer(slot, candidate, raw_bytes, signature):
            self.slots[slot] = Slot(raw_bytes, signature, {'app.mpy': b'corrupt'})

        self.sup = FirmwareSupervisor(self.model, self.public, self.verifier, BOARD,
                                      'v1.29.1', self.reader, corrupt_writer,
                                      self.launches.append, self.clock.ticks_ms,
                                      self.clock.ticks_diff, lambda *_: True)

        def ambiguous_fail():
            self.store._invalidate()
            raise StateWriteError('ambiguous suppression')

        self.model.fail_trial = ambiguous_fail
        with self.assertRaises(FirmwareSupervisorError):
            self.sup.admit_and_stage(raw, sig, 'pico-2', 'm')
        self.assertIsNone(self.store.state)
        self.assertEqual(self.launches, [])
        self.model.fail_trial = real_fail

    def test_interrupted_trial_recovery_suppresses_candidate(self):
        self.stage()
        self.reboot()
        self.assertEqual(self.sup.boot(), 'A')
        self.assertEqual(self.model.state['applied_id'], 1)
        self.assertEqual(self.model.state['failed_high_water'], 2)
        self.assertEqual(self.launches[-1], 'A')

    def test_confirmed_success_immediately_promotes_and_retains_previous(self):
        self.stage()
        self.assertTrue(self.sup.trial_ok(2, 'marker-2', True))
        self.assertEqual((self.model.state['applied_slot'], self.model.state['retained_slot']), ('B', 'A'))

    def test_exact_deadline_rejects_success(self):
        self.stage()
        self.clock.value = 300000
        self.assertFalse(self.sup.trial_ok(2, 'marker-2', True))
        self.assertEqual(self.model.state['failed_high_water'], 2)

    def test_two_updates_alternate_slots(self):
        self.stage(2)
        self.assertTrue(self.sup.trial_ok(2, 'marker-2', True))
        self.stage(3)
        self.assertEqual(self.writes[-1][0], 'A')
        self.assertTrue(self.sup.trial_ok(3, 'marker-3', True))
        self.assertEqual((self.model.state['applied_slot'], self.model.state['retained_slot']), ('A', 'B'))

    def test_corrupt_applied_recovers_only_authenticated_retained(self):
        self.stage(2)
        self.sup.trial_ok(2, 'marker-2', True)
        self.slots['B'].assets['app.mpy'] = b'broken'
        self.launches.clear()
        self.assertEqual(self.sup.boot(), 'A')
        self.assertEqual(self.model.state['applied_id'], 1)
        self.assertEqual(self.launches, ['A'])

    def test_both_slots_invalid_requires_usb_and_launches_nothing(self):
        self.stage(2)
        self.sup.trial_ok(2, 'marker-2', True)
        self.slots['A'].assets['app.mpy'] = b'bad'
        self.slots['B'].assets['app.mpy'] = b'bad'
        self.launches.clear()
        with self.assertRaises(RecoveryRequiredError):
            self.sup.boot()
        self.assertEqual(self.launches, [])

    def test_reporter_must_confirm_literal_true(self):
        self.stage()
        for result in (False, 1, None):
            self.sup = self.make_supervisor(lambda *_: result)
            self.assertFalse(self.sup.trial_ok(2, 'marker-2', True))
            self.assertEqual(self.model.state['phase'], 'trial_entered')


if __name__ == '__main__':
    unittest.main()
