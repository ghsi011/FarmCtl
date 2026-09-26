import builtins
import errno
import os
from pathlib import Path
import sys
import tempfile
import traceback
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from firmware.pico.update_state import (
    MAX_RELEASE_ID,
    MAX_RECORD,
    RecoveryRequired,
    StateWriteError,
    UpdateState,
    UpdateStateStore,
    _encode_record,
)
from firmware.pico import update_state as update_state_module


def initial_state():
    return {
        'applied_slot': 'A', 'applied_id': 1,
        'retained_slot': 'B', 'retained_id': 1,
        'installed_high_water': 1, 'failed_high_water': 0,
        'pending_slot': None, 'pending_id': None,
        'trial_marker': None, 'phase': None,
    }


class Clock:
    def __init__(self, value=0):
        self.value = value

    def ticks_ms(self):
        return self.value

    @staticmethod
    def ticks_diff(now, start):
        return ((now - start + 0x80000000) & 0xffffffff) - 0x80000000


class UpdateStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.store = UpdateStateStore(self.temp.name)
        self.store.initialize(initial_state())
        self.model = UpdateState(self.store, self.clock.ticks_ms, self.clock.ticks_diff)

    def tearDown(self):
        self.temp.cleanup()

    def reload(self):
        store = UpdateStateStore(self.temp.name)
        store.load()
        return store, UpdateState(store, self.clock.ticks_ms, self.clock.ticks_diff)

    def stage(self, release_id=2, marker='marker'):
        self.model.stage_candidate(release_id, marker, True, True)

    def enter(self):
        self.model.enter_trial(True, True)

    def test_stage_invalidates_old_retention_before_write_and_commit_trial(self):
        self.stage()
        self.assertEqual(self.model.state['phase'], 'writing')
        self.assertIsNone(self.model.state['retained_slot'])
        self.assertIsNone(self.model.state['retained_id'])
        self.enter()
        store, recovered = self.reload()
        self.assertEqual(store.state['phase'], 'trial_entered')
        self.assertEqual(recovered.recover_after_boot(), 'rolled_back')
        self.assertEqual(recovered.state['applied_slot'], 'A')
        self.assertIsNone(recovered.state['retained_slot'])
        self.assertEqual(recovered.state['failed_high_water'], 2)

    def test_interrupted_writing_rolls_back_suppresses_id_and_preserves_applied(self):
        self.stage()
        _, recovered = self.reload()
        self.assertEqual(recovered.recover_after_boot(), 'rolled_back')
        self.assertEqual(recovered.state['applied_id'], 1)
        self.assertEqual(recovered.state['failed_high_water'], 2)
        with self.assertRaises(ValueError):
            recovered.stage_candidate(2, 'again', True, True)

    def test_success_promotes_immediately_and_two_updates_alternate(self):
        self.stage()
        self.enter()
        self.clock.value = 299999
        self.assertTrue(self.model.confirm_trial_ok(2, 'marker', True))
        self.assertEqual((self.model.state['applied_slot'], self.model.state['retained_slot']), ('B', 'A'))
        self.stage(3, 'm3')
        self.assertEqual(self.model.state['pending_slot'], 'A')
        self.enter()
        self.clock.value += 1
        self.assertTrue(self.model.confirm_trial_ok(3, 'm3', True))
        self.assertEqual((self.model.state['applied_slot'], self.model.state['retained_slot']), ('A', 'B'))

    def test_exact_deadline_and_timeout_without_reply_fail(self):
        self.stage()
        self.enter()
        self.clock.value = 300000
        self.assertFalse(self.model.confirm_trial_ok(2, 'marker', True))
        self.assertEqual(self.model.state['failed_high_water'], 2)
        self.stage(3, 'm3')
        self.enter()
        self.clock.value += 300000
        self.assertTrue(self.model.tick())
        self.assertEqual(self.model.state['failed_high_water'], 3)

    def test_ticks_wrap_negative_elapsed_and_late_stale_callbacks(self):
        self.clock.value = 0xfffffff0
        self.stage()
        self.enter()
        self.clock.value = 0x20
        self.assertTrue(self.model.confirm_trial_ok(2, 'marker', True))
        self.stage(3, 'm3')
        self.enter()
        self.clock.value -= 1
        self.assertFalse(self.model.confirm_trial_ok(3, 'm3', True))
        self.assertFalse(self.model.confirm_trial_ok(2, 'marker', True))
        self.assertIsNone(self.model.state['phase'])
        self.assertEqual(self.model.state['failed_high_water'], 3)

    def test_exact_true_verification_and_response_flags_required(self):
        for signature, compatible in ((1, True), (True, 1), (False, True)):
            with self.subTest(signature=signature, compatible=compatible):
                with self.assertRaises(ValueError):
                    self.model.stage_candidate(2, 'm', signature, compatible)
        self.stage()
        with self.assertRaises(ValueError):
            self.model.enter_trial(1, True)
        with self.assertRaises(ValueError):
            self.model.enter_trial(True, False)
        self.enter()
        self.assertFalse(self.model.confirm_trial_ok(2, 'marker', 1))

    def test_trial_entry_requires_valid_injected_clock_but_recovery_does_not(self):
        self.stage()
        no_clock = UpdateState(self.store)
        with self.assertRaises(ValueError):
            no_clock.enter_trial(True, True)
        self.assertEqual(no_clock.state['phase'], 'writing')
        for invalid_start in (True, 1.0, float('nan')):
            with self.subTest(invalid_start=invalid_start):
                clock = Clock(invalid_start)
                no_clock = UpdateState(self.store, clock.ticks_ms, clock.ticks_diff)
                with self.assertRaises(ValueError):
                    no_clock.enter_trial(True, True)
                self.assertEqual(no_clock.state['phase'], 'writing')
        _, recovery_only = self.reload()
        self.assertEqual(recovery_only.recover_after_boot(), 'rolled_back')

    def test_invalid_backward_and_non_integer_elapsed_terminate_trial(self):
        for invalid_now in (True, 1.0, float('nan')):
            with self.subTest(invalid_now=invalid_now):
                self.stage()
                self.enter()
                self.clock.value = invalid_now
                self.assertTrue(self.model.tick())
                self.assertIsNone(self.model.state['phase'])
                self.assertEqual(self.model.state['failed_high_water'], 2)
                self.tearDown()
                self.setUp()
        self.stage()
        self.enter()
        self.clock.value = -1
        self.assertTrue(self.model.tick())
        self.assertEqual(self.model.state['failed_high_water'], 2)

    def test_float_release_callback_does_not_match_integer_candidate(self):
        self.stage()
        self.enter()
        self.clock.value = 1
        self.assertFalse(self.model.confirm_trial_ok(2.0, 'marker', True))
        self.assertEqual(self.model.state['phase'], 'trial_entered')

    def test_bad_candidate_and_config_trial_rejected(self):
        with self.assertRaises(ValueError):
            self.model.stage_candidate(2, 'm', True, True, 'config')
        with self.assertRaises(ValueError):
            self.model.stage_candidate(True, 'm', True, True)
        with self.assertRaises(ValueError):
            self.model.stage_candidate(1, 'm', True, True)
        with self.assertRaises(ValueError):
            self.model.stage_candidate(MAX_RELEASE_ID + 1, 'm', True, True)

    def test_explicit_retained_recovery_does_not_lower_highwaters(self):
        selection = dict(self.model.state, applied_slot='B', applied_id=2,
                         retained_slot='A', retained_id=1,
                         installed_high_water=2, failed_high_water=3)
        self.store.commit(selection)
        with self.assertRaises(ValueError):
            self.model.recover_retained('A', 1)
        self.assertEqual(self.model.recover_retained('A', True), 'A')
        self.assertEqual(self.model.state['applied_id'], 1)
        self.assertEqual(self.model.state['installed_high_water'], 2)
        self.assertEqual(self.model.state['failed_high_water'], 3)
        self.assertIsNone(self.model.state['retained_slot'])

    def test_one_time_initialize_rejects_existing_corrupt_metadata(self):
        path = os.path.join(self.temp.name, 'state.a')
        with open(path, 'wb') as handle:
            handle.write(b'broken')
        with self.assertRaises(RecoveryRequired):
            UpdateStateStore(self.temp.name).initialize(initial_state())

    def test_initialize_only_treats_enoent_as_absence_and_never_opens_on_io_error(self):
        for error_number in (errno.EIO, errno.EACCES):
            with self.subTest(error_number=error_number):
                writer = mock.Mock(wraps=builtins.open)
                with mock.patch.object(update_state_module.os, 'stat',
                                       side_effect=OSError(error_number, 'stat failed')):
                    with mock.patch('builtins.open', writer):
                        with self.assertRaises(RecoveryRequired):
                            UpdateStateStore(self.temp.name).initialize(initial_state())
                writer.assert_not_called()

    def test_equal_sequence_conflicts_and_oversized_records_fail_closed(self):
        with open(os.path.join(self.temp.name, 'state.a'), 'rb') as handle:
            existing = handle.read()
        with open(os.path.join(self.temp.name, 'state.b'), 'wb') as handle:
            handle.write(existing)
        # Equal identical records are permitted, conflicting ones are not.
        loader = UpdateStateStore(self.temp.name)
        loader.load()
        conflict = initial_state()
        conflict['applied_id'] = 2
        conflict['installed_high_water'] = 2
        with open(os.path.join(self.temp.name, 'state.b'), 'wb') as handle:
            handle.write(_encode_record(loader.sequence, conflict))
        with self.assertRaises(RecoveryRequired):
            UpdateStateStore(self.temp.name).load()
        with open(os.path.join(self.temp.name, 'state.a'), 'wb') as handle:
            handle.write(b'x' * (MAX_RECORD + 1))
        with open(os.path.join(self.temp.name, 'state.b'), 'wb') as handle:
            handle.write(b'x' * (MAX_RECORD + 1))
        with self.assertRaises(RecoveryRequired):
            UpdateStateStore(self.temp.name).load()

    def test_ambiguous_write_errors_invalidate_ram_and_reload_is_required(self):
        real_open = builtins.open

        class BrokenHandle:
            def __init__(self, handle, mode):
                self.handle, self.mode = handle, mode

            def write(self, payload):
                self.handle.write(payload[:5])
                return 5

            def flush(self):
                raise OSError('flush failure')

            def close(self):
                self.handle.close()

            def __getattr__(self, name):
                return getattr(self.handle, name)

        self.stage()
        previous = self.model.state
        with mock.patch('builtins.open', side_effect=lambda path, mode='r', *a, **k:
                        BrokenHandle(real_open(path, mode, *a, **k), mode) if mode == 'wb'
                        else real_open(path, mode, *a, **k)):
            with self.assertRaises(StateWriteError):
                self.enter()
        self.assertIsNone(self.store.state)
        self.assertIsNone(self.model.trial_started)
        with self.assertRaises(RecoveryRequired):
            _ = self.model.state
        loaded, recovered = self.reload()
        self.assertIn(loaded.state, (previous, dict(previous, phase='trial_entered')))
        self.assertIn(recovered.recover_after_boot(), ('rolled_back', 'ready'))

    def test_write_and_readback_errors_hide_storage_details_and_poison_ram(self):
        real_open = builtins.open
        for mode_to_fail in ('wb', 'rb'):
            with self.subTest(mode=mode_to_fail):
                self.tearDown()
                self.setUp()

                def injected(path, mode='r', *args, **kwargs):
                    is_target = str(path).endswith('state.b')
                    if mode == mode_to_fail and is_target:
                        raise OSError('SECRET_LOCATION: storage path detail')
                    return real_open(path, mode, *args, **kwargs)

                with mock.patch('builtins.open', side_effect=injected):
                    try:
                        self.stage()
                    except StateWriteError as error:
                        message = str(error)
                        formatted = traceback.format_exc()
                    else:
                        self.fail('expected ambiguous metadata failure')
                self.assertEqual(message, 'metadata commit ambiguous; reload and reverify slots')
                self.assertNotIn('SECRET_LOCATION', formatted)
                self.assertIsNone(self.store.state)
                with self.assertRaises(RecoveryRequired):
                    self.stage()

    def test_write_flush_close_readback_fault_matrix_and_reset_reload(self):
        # Each injected persistence failure must poison the live RAM store; a
        # fresh store performs the authoritative reboot selection.
        for fault in ('open', 'write', 'flush', 'close', 'readback'):
            with self.subTest(fault=fault):
                self.tearDown()
                self.setUp()
                real_open = builtins.open

                class FaultHandle:
                    def __init__(self, handle): self.handle = handle
                    def write(self, payload):
                        if fault == 'write':
                            self.handle.write(payload[:4])
                            raise OSError('write')
                        return self.handle.write(payload)
                    def flush(self):
                        if fault == 'flush': raise OSError('flush')
                        return self.handle.flush()
                    def close(self):
                        self.handle.close()
                        if fault == 'close': raise OSError('close')
                    def __getattr__(self, name): return getattr(self.handle, name)

                def injected(path, mode='r', *args, **kwargs):
                    if fault == 'open' and mode == 'wb': raise OSError('open')
                    if fault == 'readback' and mode == 'rb' and str(path).endswith('state.b'):
                        raise OSError('readback')
                    handle = real_open(path, mode, *args, **kwargs)
                    return FaultHandle(handle) if mode == 'wb' else handle

                with mock.patch('builtins.open', side_effect=injected):
                    with self.assertRaises(StateWriteError):
                        self.stage()
                self.assertIsNone(self.store.state)
                rebooted = UpdateStateStore(self.temp.name)
                loaded = rebooted.load()
                self.assertIn(loaded, (initial_state(), dict(initial_state(),
                                                             retained_slot=None,
                                                             retained_id=None,
                                                             pending_slot='B', pending_id=2,
                                                             trial_marker='marker',
                                                             phase='writing')))
                if loaded['phase'] == 'writing':
                    self.assertEqual(loaded['failed_high_water'], 0)
                else:
                    self.assertEqual(loaded['failed_high_water'], 0)

    def _fail_next_readback(self):
        real_open = builtins.open
        target = 'state.b' if self.store.active_record == 'state.a' else 'state.a'
        target_path = os.path.join(self.temp.name, target)

        def injected(path, mode='r', *args, **kwargs):
            if mode == 'rb' and os.path.abspath(path) == os.path.abspath(target_path):
                raise OSError('simulated readback failure after complete write')
            return real_open(path, mode, *args, **kwargs)

        return mock.patch('builtins.open', side_effect=injected)

    def test_readback_faults_at_entry_promotion_suppression_recovery_and_second_update(self):
        # Entry: full candidate trial record is on disk despite ambiguous error;
        # reconstructing RAM observes trial_entered and boot recovery suppresses it.
        self.stage()
        with self._fail_next_readback():
            with self.assertRaises(StateWriteError):
                self.enter()
        store, recovered = self.reload()
        self.assertEqual(store.state['phase'], 'trial_entered')
        self.assertEqual(recovered.recover_after_boot(), 'rolled_back')
        self.assertEqual(recovered.state['failed_high_water'], 2)

        # Suppression commit: the complete suppression record wins on reload.
        self.tearDown()
        self.setUp()
        self.stage()
        self.enter()
        with self._fail_next_readback():
            with self.assertRaises(StateWriteError):
                self.model.fail_trial()
        store, recovered = self.reload()
        self.assertIsNone(store.state['phase'])
        self.assertEqual(store.state['failed_high_water'], 2)
        self.assertEqual(recovered.recover_after_boot(), 'ready')
        with self.assertRaises(ValueError):
            recovered.stage_candidate(2, 'retry', True, True)

        # A successful first update followed by a complete-write/readback fault
        # during second-update promotion must reload as the newly selected slot.
        self.tearDown()
        self.setUp()
        self.stage()
        self.enter()
        self.clock.value = 1
        self.assertTrue(self.model.confirm_trial_ok(2, 'marker', True))
        self.stage(3, 'm3')
        self.enter()
        self.clock.value = 2
        with self._fail_next_readback():
            with self.assertRaises(StateWriteError):
                self.model.confirm_trial_ok(3, 'm3', True)
        store, recovered = self.reload()
        self.assertEqual((store.state['applied_slot'], store.state['applied_id']), ('A', 3))
        self.assertEqual((store.state['retained_slot'], store.state['retained_id']), ('B', 2))
        self.assertEqual(recovered.recover_after_boot(), 'ready')

    def test_readback_fault_during_retained_recovery_reloads_selected_slot(self):
        selection = dict(self.model.state, applied_slot='B', applied_id=2,
                         retained_slot='A', retained_id=1,
                         installed_high_water=2, failed_high_water=3)
        self.store.commit(selection)
        with self._fail_next_readback():
            with self.assertRaises(StateWriteError):
                self.model.recover_retained('A', True)
        store, _ = self.reload()
        self.assertEqual(store.state['applied_slot'], 'A')
        self.assertEqual(store.state['applied_id'], 1)
        self.assertEqual(store.state['failed_high_water'], 3)

    def test_failed_suppression_keeps_unresolved_candidate_disabled_across_reboots(self):
        self.stage()
        self.enter()
        with mock.patch('builtins.open', side_effect=OSError('metadata unavailable')):
            with self.assertRaises(StateWriteError):
                self.model.fail_trial()
        store, rebooted = self.reload()
        self.assertEqual(store.state['phase'], 'trial_entered')
        with self.assertRaises(ValueError):
            rebooted.stage_candidate(3, 'newer', True, True)
        self.assertEqual(rebooted.recover_after_boot(), 'rolled_back')
        again_store, again = self.reload()
        self.assertIsNone(again_store.state['phase'])
        self.assertEqual(again_store.state['failed_high_water'], 2)
        self.assertEqual(again.recover_after_boot(), 'ready')
        with self.assertRaises(ValueError):
            again.stage_candidate(2, 'retry', True, True)


if __name__ == '__main__':
    unittest.main()
