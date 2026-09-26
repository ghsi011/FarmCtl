import builtins
import binascii
import errno
import json
import os
from pathlib import Path
import sys
import tempfile
import traceback
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from firmware.pico.config_trial import (
    MAX_CONSUMED_IDS, MAX_RECORD_BYTES, ConfigTrialStore, RecoveryRequired,
    StateWriteError,
)
from firmware.pico import config_trial as config_trial_module


DEVICE = '123e4567-e89b-42d3-a456-426614174000'
BASE_CHANGE = '123e4567-e89b-42d3-a456-426614174001'


def change(number):
    return '123e4567-e89b-42d3-a456-%012x' % number


def revision(number):
    return '223e4567-e89b-42d3-a456-%012x' % number


class Clock:
    def __init__(self, value=0):
        self.value = value

    def ticks_ms(self):
        return self.value

    @staticmethod
    def ticks_diff(now, start):
        return ((now - start + (1 << 29)) & ((1 << 30) - 1)) - (1 << 29)


class ConfigTrialTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.store = ConfigTrialStore(self.temp.name, self.clock.ticks_ms,
                                      self.clock.ticks_diff)
        self.store.initialize('applied.json', 10, 'a' * 64, revision(1), BASE_CHANGE,
                              DEVICE.upper(), True)

    def tearDown(self):
        self.temp.cleanup()

    def reload(self):
        store = ConfigTrialStore(self.temp.name, self.clock.ticks_ms,
                                 self.clock.ticks_diff)
        store.load()
        return store

    def proof(self, store=None):
        return config_trial_module._ConfigProof(self.store if store is None else store)

    def start_staged(self, revision_id=None, identifier=None, basename='candidate.json'):
        identifier = identifier or change(2)
        self.store.begin_received(revision_id or revision(2), identifier)
        self.store.stage_candidate(basename, 20, 'b' * 64, True)

    def test_two_edits_promote_only_on_proof_and_preserve_prior_applied_payload(self):
        self.start_staged()
        self.clock.value = 0
        self.store.enter_trial()
        self.assertFalse(self.store.expire_or_confirm(299999, proof=1))
        self.assertTrue(self.store.expire_or_confirm(299999, proof=self.proof()))
        self.assertEqual(self.store.state['applied'], ['candidate.json', 20, 'b' * 64])
        self.assertEqual(self.store.state['applied_revision'], revision(2))
        self.assertEqual(self.store.state['applied_change_id'], change(2))
        self.assertEqual(self.store.state['status'], 'applied')
        self.start_staged(revision(3), change(3), 'candidate2.json')
        self.clock.value = 500
        self.store.enter_trial()
        self.assertTrue(self.store.expire_or_confirm(501, self.proof()))
        self.assertEqual(self.store.state['applied'], ['candidate2.json', 20, 'b' * 64])
        self.assertEqual(self.store.state['consumed'], [BASE_CHANGE, change(2), change(3)])

    def test_confirmation_requires_current_store_bound_receipt(self):
        self.start_staged()
        self.store.enter_trial()
        receipt = self.proof()
        self.assertEqual(repr(receipt), '<_ConfigProof>')
        for untrusted in (True, 1, {}, lambda: True):
            self.assertFalse(self.store.expire_or_confirm(1, untrusted))
            self.assertEqual(self.store.state['status'], 'trial')

        other_store = self.reload()
        other_store.trial_started = self.store.trial_started
        self.assertFalse(other_store.expire_or_confirm(1, receipt))
        self.assertEqual(other_store.state['status'], 'trial')

    def test_receipt_is_trial_specific_single_use_and_rejects_metadata_mutation(self):
        self.start_staged()
        self.store.enter_trial()
        old_receipt = self.proof()
        with self.assertRaises(AttributeError):
            old_receipt._sequence = self.store.sequence
        self.store.rollback('inconclusive')
        self.start_staged(revision(3), change(3), 'candidate3.json')
        self.store.enter_trial()
        self.assertFalse(self.store.expire_or_confirm(1, old_receipt))
        current_receipt = self.proof()

        self.store.state['revision'] = revision(9)
        self.assertFalse(self.store.expire_or_confirm(1, current_receipt))
        self.assertEqual(self.store.state['status'], 'trial')

        self.store.state['revision'] = revision(3)
        self.assertTrue(self.store.expire_or_confirm(1, current_receipt))
        self.assertFalse(self.store.expire_or_confirm(1, current_receipt))

    def test_receipt_repr_does_not_expose_metadata_or_secret_text(self):
        self.start_staged()
        self.store.enter_trial()
        secret = 'sensitive-password-not-for-metadata'
        self.store.state['device_ref'] = secret
        receipt = self.proof()
        self.assertNotIn(secret, repr(receipt))
        self.assertNotIn('candidate.json', repr(receipt))

    def test_replay_is_case_insensitive_and_revision_does_not_make_id_reusable(self):
        self.store.begin_received(revision(2), change(2))
        self.store.reject('supervisor_rejected')
        with self.assertRaises(ValueError):
            self.store.begin_received(revision(3).upper(), change(2).upper())
        with self.assertRaises(ValueError):
            self.store.begin_received(revision(4), change(2))
        reloaded = self.reload()
        with self.assertRaises(ValueError):
            reloaded.begin_received(revision(9), change(2))

    def test_baseline_change_id_stays_consumed_after_other_edits_and_uppercase_replay(self):
        self.start_staged(revision(2), change(2), 'payload_b.json')
        self.clock.value = 1
        self.store.enter_trial()
        self.assertTrue(self.store.expire_or_confirm(2, self.proof()))
        self.store.begin_received(revision(3), change(3))
        self.store.reject('invalid_config')
        with self.assertRaises(ValueError):
            self.store.begin_received(revision(4), BASE_CHANGE.upper())
        self.assertEqual(self.store.state['applied_change_id'], change(2))

    def test_consumed_capacity_is_non_evicting_and_fails_closed(self):
        for index in range(2, MAX_CONSUMED_IDS + 1):
            identifier = change(index)
            self.store.begin_received(revision(index), identifier)
            self.store.reject('supervisor_rejected')
        self.assertEqual(len(self.store.state['consumed']), MAX_CONSUMED_IDS)
        previous = list(self.store.state['consumed'])
        with self.assertRaises(RecoveryRequired):
            self.store.begin_received(revision(MAX_CONSUMED_IDS + 1), change(MAX_CONSUMED_IDS + 1))
        self.assertEqual(self.store.state['consumed'], previous)

    def test_reboot_at_received_staged_or_trial_rolls_back_and_keeps_applied(self):
        for state in ('received', 'staged', 'trial'):
            with self.subTest(state=state):
                self.tearDown()
                self.setUp()
                self.store.begin_received(revision(2), change(2))
                if state in ('staged', 'trial'):
                    self.store.stage_candidate('candidate.json', 20, 'b' * 64, True)
                if state == 'trial':
                    self.store.enter_trial()
            reloaded = self.reload()
            self.assertEqual(reloaded.recover_after_boot(), 'rolled_back')
            self.assertEqual(reloaded.state['applied'], ['applied.json', 10, 'a' * 64])
            self.assertIn(change(2), reloaded.state['consumed'])
            self.assertEqual(reloaded.state['applied_revision'], revision(1))
            self.assertEqual(reloaded.state['applied_change_id'], BASE_CHANGE)
            self.assertEqual(reloaded.state['reason'], 'reboot_interrupted')
            self.assertEqual(reloaded.recover_after_boot(), 'ready')

    def test_deadline_ticks_wrap_and_bad_clock_fail_closed(self):
        self.start_staged()
        self.clock.value = (1 << 30) - 16
        self.store.enter_trial()
        self.assertTrue(self.store.expire_or_confirm(0x20, self.proof()))
        self.start_staged(revision(3), change(3), 'candidate3.json')
        self.clock.value = 10
        self.store.enter_trial()
        self.assertTrue(self.store.expire_or_confirm(300009, self.proof()))
        self.start_staged(revision(4), change(4))
        self.clock.value = 10
        self.store.enter_trial()
        self.assertFalse(self.store.expire_or_confirm(300010, self.proof()))
        self.assertEqual(self.store.state['reason'], 'inconclusive')
        for index, invalid in enumerate((None, True, 1.5, float('nan'), 9, (1 << 32) + 1), 5):
            self.start_staged(revision(index), change(index), 'candidate%d.json' % index)
            self.clock.value = 10
            self.store.enter_trial()
            self.assertFalse(self.store.expire_or_confirm(invalid, self.proof()))
            self.assertEqual(self.store.state['status'], 'rolled_back')

    def test_rollback_and_reject_keep_old_applied_and_reason_is_token_only(self):
        self.start_staged()
        self.clock.value = 10
        self.store.enter_trial()
        with self.assertRaises(ValueError):
            self.store.reject('trial_failed')
        with self.assertRaises(ValueError):
            self.store.rollback('password=secret')
        self.store.rollback('wifi_failed')
        self.assertEqual(self.store.state['applied'], ['applied.json', 10, 'a' * 64])
        self.assertEqual(self.store.state['reason'], 'wifi_failed')
        self.store.begin_received(revision(3), change(3))
        self.store.reject('supervisor_rejected')
        self.assertEqual(self.store.state['status'], 'rejected')

    def test_metadata_is_bounded_array_and_contains_no_payload_or_secret(self):
        secret = 'sensitive-password-not-for-metadata'
        self.store.begin_received(revision(2), change(2))
        self.store.stage_candidate('candidate.json', 20, 'b' * 64, True)
        with open(os.path.join(self.temp.name, self.store.active_record), 'rb') as handle:
            raw = handle.read(MAX_RECORD_BYTES + 1)
        self.assertLessEqual(len(raw), MAX_RECORD_BYTES)
        record = json.loads(raw.decode('utf-8'))
        self.assertIsInstance(record, list)
        self.assertNotIn(secret.encode(), raw)
        self.assertNotIn('ssid', raw.decode('utf-8').lower())
        self.assertNotIn(secret, str(self.store.state))

    def test_invalid_paths_hashes_and_unverified_candidates_rejected(self):
        self.store.begin_received(revision(2), change(2))
        for name in ('../secret', '/etc/passwd', 'a\\b', '.hidden'):
            with self.assertRaises(ValueError):
                self.store.stage_candidate(name, 1, 'b' * 64, True)
        with self.assertRaises(ValueError):
            self.store.stage_candidate('candidate.json', 1, 'B' * 64, True)
        with self.assertRaises(ValueError):
            self.store.stage_candidate('candidate.json', 1, 'b' * 64, 1)
        with self.assertRaises(ValueError):
            self.store.stage_candidate('candidate.json', 65537, 'b' * 64, True)
        with self.assertRaises(ValueError):
            self.store.stage_candidate('applied.json', 1, 'b' * 64, True)
        with self.assertRaises(ValueError):
            self.store.stage_candidate('empty.json', 0, 'b' * 64, True)
        with self.assertRaises(TypeError):
            self.store.stage_candidate('candidate.json', 1, 'b' * 64)

    def test_initialize_requires_absence_enoent_only_and_verified_baseline(self):
        with self.assertRaises(RecoveryRequired):
            ConfigTrialStore(self.temp.name).initialize('a.json', 1, 'a' * 64,
                                                        revision(1), BASE_CHANGE, DEVICE, True)
        empty = tempfile.TemporaryDirectory()
        self.addCleanup(empty.cleanup)
        with mock.patch.object(config_trial_module.os, 'stat', side_effect=OSError(errno.EIO, 'io')):
            with self.assertRaises(RecoveryRequired):
                ConfigTrialStore(empty.name).initialize('a.json', 1, 'a' * 64,
                                                        revision(1), BASE_CHANGE, DEVICE, True)
        with self.assertRaises(ValueError):
            ConfigTrialStore(empty.name).initialize('a.json', 1, 'a' * 64,
                                                    revision(1), BASE_CHANGE, DEVICE, 1)

    def test_device_reference_is_opaque_bounded_identifier_and_preserved(self):
        for invalid in ('', 'x' * 65, 'device:bad'):
            empty = tempfile.TemporaryDirectory()
            self.addCleanup(empty.cleanup)
            with self.assertRaises(ValueError):
                ConfigTrialStore(empty.name).initialize('a.json', 1, 'a' * 64,
                                                        revision(1), BASE_CHANGE,
                                                        invalid, True)
        empty = tempfile.TemporaryDirectory()
        self.addCleanup(empty.cleanup)
        opaque = 'Device-Mixed_Case.1'
        store = ConfigTrialStore(empty.name)
        store.initialize('a.json', 1, 'a' * 64, revision(1), BASE_CHANGE,
                         opaque, True)
        self.assertEqual(store.state['device_ref'], opaque)
        self.assertEqual(ConfigTrialStore(empty.name).load()['device_ref'], opaque)
        full_length = tempfile.TemporaryDirectory()
        self.addCleanup(full_length.cleanup)
        boundary = 'd' * 64
        boundary_store = ConfigTrialStore(full_length.name)
        boundary_store.initialize('a.json', 1, 'a' * 64, revision(1), BASE_CHANGE,
                                   boundary, True)
        self.assertEqual(boundary_store.state['device_ref'], boundary)

    def test_crc_valid_record_with_uppercase_consumed_uuid_is_rejected(self):
        path = os.path.join(self.temp.name, self.store.active_record)
        with open(path, 'rb') as handle:
            record = json.loads(handle.read().decode('utf-8'))
        record[10][0] = record[10][0].upper()
        record[-1] = '%08x' % (binascii.crc32(
            json.dumps(record[:-1]).encode('utf-8')) & 0xffffffff)
        with open(path, 'wb') as handle:
            handle.write(json.dumps(record).encode('utf-8'))
        with self.assertRaises(RecoveryRequired):
            ConfigTrialStore(self.temp.name).load()

    def test_corrupt_or_torn_records_and_ambiguous_write_invalidate_ram(self):
        active_path = os.path.join(self.temp.name, self.store.active_record)
        with open(active_path, 'wb') as handle:
            handle.write(b'{torn')
        with self.assertRaises(RecoveryRequired):
            ConfigTrialStore(self.temp.name).load()

        self.tearDown()
        self.setUp()
        real_open = builtins.open

        class Broken:
            def __init__(self, handle): self.handle = handle
            def write(self, value): self.handle.write(value[:5]); return 5
            def flush(self): raise OSError('flush failure')
            def close(self): self.handle.close()
            def __getattr__(self, key): return getattr(self.handle, key)

        with mock.patch('builtins.open', side_effect=lambda path, mode='r', *a, **k:
                        Broken(real_open(path, mode, *a, **k)) if mode == 'wb'
                        else real_open(path, mode, *a, **k)):
            with self.assertRaises(StateWriteError):
                self.store.begin_received(revision(2), change(2))
        self.assertIsNone(self.store.state)
        with self.assertRaises(RecoveryRequired):
            self.store.begin_received(revision(2), change(2))

    def test_close_and_readback_faults_invalidate_ram(self):
        for fault in ('close', 'readback'):
            with self.subTest(fault=fault):
                self.tearDown()
                self.setUp()
                real_open = builtins.open

                class FaultHandle:
                    def __init__(self, handle): self.handle = handle
                    def write(self, value): return self.handle.write(value)
                    def flush(self): return self.handle.flush()
                    def close(self):
                        self.handle.close()
                        if fault == 'close': raise OSError('close failure')
                    def __getattr__(self, key): return getattr(self.handle, key)

                def injected(path, mode='r', *args, **kwargs):
                    if fault == 'readback' and mode == 'rb' and str(path).endswith('config.b'):
                        raise OSError('readback failure')
                    handle = real_open(path, mode, *args, **kwargs)
                    return FaultHandle(handle) if mode == 'wb' else handle

                with mock.patch('builtins.open', side_effect=injected):
                    with self.assertRaises(StateWriteError):
                        self.store.begin_received(revision(2), change(2))
                self.assertIsNone(self.store.state)

    def test_ambiguous_fault_matrix_covers_trial_transitions_and_recovery(self):
        scenarios = ('received', 'staged', 'trial', 'promote', 'reject',
                     'rollback', 'recovery')
        for scenario in scenarios:
          for fault in ('open', 'readback'):
            with self.subTest(scenario=scenario, fault=fault):
                self.tearDown()
                self.setUp()
                if scenario != 'received':
                    self.store.begin_received(revision(2), change(2))
                if scenario in ('trial', 'promote', 'rollback', 'recovery'):
                    self.store.stage_candidate('candidate.json', 20, 'b' * 64, True)
                if scenario in ('promote', 'rollback', 'recovery'):
                    self.store.enter_trial()
                operation = {
                    'received': lambda: self.store.begin_received(revision(3), change(3)),
                    'staged': lambda: self.store.stage_candidate('candidate2.json', 21, 'c' * 64, True),
                    'trial': lambda: self.store.enter_trial(),
                    'promote': lambda: self.store.expire_or_confirm(1, self.proof()),
                    'reject': lambda: self.store.reject('invalid_config'),
                    'rollback': lambda: self.store.rollback('wifi_failed'),
                    'recovery': lambda: self.store.recover_after_boot(),
                }[scenario]
                real_open = builtins.open
                target_record = ('config.b' if self.store.active_record == 'config.a'
                                 else 'config.a')

                def injected(path, mode='r', *args, **kwargs):
                    if fault == 'open' and mode == 'wb':
                        raise OSError('synthetic I/O token')
                    if (fault == 'readback' and mode == 'rb'
                            and str(path).endswith(target_record)):
                        raise OSError('synthetic I/O token')
                    return real_open(path, mode, *args, **kwargs)

                with mock.patch('builtins.open', side_effect=injected):
                    with self.assertRaises(StateWriteError):
                        operation()
                self.assertIsNone(self.store.state)
                reloaded = self.reload()
                if scenario == 'promote' and fault == 'readback':
                    self.assertEqual(reloaded.state['applied'], ['candidate.json', 20, 'b' * 64])
                    self.assertEqual(reloaded.state['applied_revision'], revision(2))
                    self.assertEqual(reloaded.state['applied_change_id'], change(2))
                else:
                    self.assertEqual(reloaded.state['applied_revision'], revision(1))
                    self.assertEqual(reloaded.state['applied_change_id'], BASE_CHANGE)

    def test_clock_contract_rejects_bad_ticks_ms_and_ticks_diff(self):
        for invalid_start in (True, 1.5, float('nan'), -1, 1 << 30, (1 << 32) + 1):
            self.tearDown()
            self.setUp()
            self.start_staged(revision(2), change(2), 'candidate.json')
            self.clock.value = invalid_start
            with self.assertRaises(ValueError):
                self.store.enter_trial()
        self.tearDown()
        self.setUp()
        self.start_staged(revision(2), change(2), 'candidate.json')

        def broken_ticks_ms():
            raise OSError('synthetic clock failure')

        self.store._ticks_ms = broken_ticks_ms
        with self.assertRaises(ValueError):
            self.store.enter_trial()
        for invalid_elapsed in (True, 1.0, float('nan'), 1 << 32, -1, 'raise'):
            self.tearDown()
            self.setUp()
            self.start_staged(revision(2), change(2), 'candidate.json')
            self.clock.value = 100
            self.store.enter_trial()
            if invalid_elapsed == 'raise':
                def broken_ticks_diff(now, started):
                    raise OSError('synthetic clock failure')
                self.store._ticks_diff = broken_ticks_diff
            elif invalid_elapsed == -1:
                self.store._ticks_diff = lambda now, started: -1
            else:
                self.store._ticks_diff = lambda now, started, value=invalid_elapsed: value
            self.assertFalse(self.store.expire_or_confirm(101, self.proof()))
            self.assertEqual(self.store.state['status'], 'rolled_back')
            self.assertEqual(self.store.state['reason'], 'inconclusive')

    def test_trial_requires_clock_and_backwards_clock_rolls_back(self):
        self.start_staged()
        self.clock.value = 100
        self.store.enter_trial()
        self.assertFalse(self.store.expire_or_confirm(99, self.proof()))
        self.assertEqual(self.store.state['status'], 'rolled_back')

        no_clock = ConfigTrialStore(self.temp.name)
        no_clock.load()
        no_clock.begin_received(revision(3), change(3))
        no_clock.stage_candidate('candidate3.json', 20, 'c' * 64, True)
        with self.assertRaises(ValueError):
            no_clock.enter_trial()

    def test_bad_uuid_shapes_are_rejected(self):
        for identifier in ('not-a-uuid', '123e4567-e89b-02d3-a456-426614174000',
                           '123e4567-e89b-42d3-7456-426614174000',
                           '123e456--e89b-42d3-a456-000000000002'):
            with self.assertRaises(ValueError):
                self.store.begin_received(revision(2), identifier)

        for invalid_revision in ('not-a-revision', '123e456--e89b-42d3-a456-000000000002'):
            with self.assertRaises(ValueError):
                self.store.begin_received(invalid_revision, change(2))
        self.store.begin_received(revision(2).upper(), change(2).upper())
        self.assertEqual(self.store.state['revision'], revision(2))
        self.assertEqual(self.store.state['change_id'], change(2))

    def test_terminal_changes_never_relabel_applied_identity(self):
        self.start_staged(revision(2), change(2), 'payload_b.json')
        self.clock.value = 0
        self.store.enter_trial()
        self.assertTrue(self.store.expire_or_confirm(1, self.proof()))
        applied = (self.store.state['applied'], self.store.state['applied_revision'],
                   self.store.state['applied_change_id'])
        self.store.begin_received(revision(3), change(3))
        self.store.reject('invalid_config')
        self.assertEqual((self.store.state['applied'], self.store.state['applied_revision'],
                          self.store.state['applied_change_id']), applied)
        self.store.begin_received(revision(4), change(4))
        self.store.stage_candidate('payload_d.json', 20, 'd' * 64, True)
        self.store.enter_trial()
        self.store.rollback('wifi_failed')
        reloaded = self.reload()
        reloaded.recover_after_boot()
        self.assertEqual((reloaded.state['applied'], reloaded.state['applied_revision'],
                          reloaded.state['applied_change_id']), applied)

    def test_secret_does_not_leak_from_invalid_reason_or_io_traceback(self):
        secret = 'SYNTHETIC_SECRET_TOKEN_9f8a'
        self.store.begin_received(revision(2), change(2))
        try:
            self.store.reject(secret)
        except ValueError:
            rendered = traceback.format_exc()
        self.assertNotIn(secret, rendered)
        with mock.patch('builtins.open', side_effect=OSError(secret)):
            try:
                self.store.stage_candidate('candidate.json', 20, 'b' * 64, True)
            except StateWriteError:
                rendered = traceback.format_exc()
        self.assertNotIn(secret, rendered)


if __name__ == '__main__':
    unittest.main()
