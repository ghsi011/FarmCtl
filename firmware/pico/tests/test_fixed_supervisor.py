import io
import hashlib
import importlib
import json
from pathlib import Path
import socket
import sys
import tempfile
import threading
import traceback
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from firmware.pico.config_trial import ConfigTrialStore
from firmware.pico.config_trial import _encode
from firmware.pico.fixed_supervisor import (
    AUTOMATIC_UPDATES_ENABLED, FixedSupervisor, FixedSupervisorError,
    RecoveryRequired,
)
from firmware.pico import fixed_supervisor as fixed_supervisor_module


DEVICE = '123e4567-e89b-42d3-a456-426614174000'
REVISION = '223e4567-e89b-42d3-a456-426614174001'
CHANGE = '123e4567-e89b-42d3-a456-426614174002'
SECRET = 'FIXED_SUPERVISOR_SYNTHETIC_SECRET'


def payload(device_ref=DEVICE):
    data = {
        'schema_version': 1,
        'fleet_revision': REVISION,
        'device_ref': device_ref,
        'device': {
            'change_id': CHANGE,
            'logical_id': 'monitor-a',
            'wifi_profiles': [{'profile_id': 'primary', 'ssid': 'farm',
                               'password': SECRET}],
            'config_read_credential': SECRET,
            'temperature_gist_id': 'a' * 32,
            'diagnostics_gist_id': 'b' * 32,
            'gist_write_credential': SECRET,
            'sample_interval_seconds': 60,
            'publication_interval_seconds': 300,
        },
    }
    return json.dumps(data, separators=(',', ':')).encode('utf-8')


class Store:
    def __init__(self, state=None, error=None, on_load=None):
        self.state = state
        self.error = error
        self.on_load = on_load
        self.calls = []

    def load(self):
        self.calls.append('load')
        if self.on_load:
            self.on_load()
        if self.error:
            raise OSError(SECRET)
        return dict(self.state)

    def recover_after_boot(self):
        self.calls.append('recover')
        if self.error:
            raise OSError(SECRET)
        if self.state['status'] in ('received', 'staged', 'trial'):
            self.state['status'] = 'rolled_back'
            self.state['candidate'] = None
            self.state['reason'] = 'reboot_interrupted'
            return 'rolled_back'
        return 'ready'


class Firmware:
    def __init__(self):
        self.boot_calls = 0
        self.stage_calls = 0
        self._state = mock.Mock(state={
            'phase': None, 'pending_slot': None, 'pending_id': None,
            'trial_marker': None,
        })

    def boot(self):
        self.boot_calls += 1
        return 'A'

    def admit_and_stage(self, *args, **kwargs):
        self.stage_calls += 1


class FakeFilesystem:
    def __init__(self):
        self.files = {}
        self.reads = 0

    def open(self, path, mode):
        self.reads += 1
        if mode != 'rb' or path not in self.files:
            raise OSError(SECRET)
        return io.BytesIO(self.files[path])


class FixedSupervisorTests(unittest.TestCase):
    def setUp(self):
        # Isolate process-lifetime claim state per test without adding a
        # production reset API.
        self._isolate_claim()
        self.temp = tempfile.TemporaryDirectory()
        self.directory = '/trusted/config'
        self.filesystem = FakeFilesystem()
        self.open_patch = mock.patch('builtins.open', self.filesystem.open)
        self.open_patch.start()
        self.raw = payload()
        self.basename = 'config-applied.json'
        self.filesystem.files[self.directory + '/' + self.basename] = self.raw
        self.state = {
            'applied': [self.basename, len(self.raw), hashlib.sha256(self.raw).hexdigest()],
            'applied_revision': REVISION,
            'applied_change_id': CHANGE,
            'device_ref': DEVICE,
            'status': 'ready',
            'candidate': None,
        }

    def tearDown(self):
        self.open_patch.stop()
        self.temp.cleanup()

    def owner(self, store=None, firmware=None, device_ref=DEVICE):
        firmware = firmware or Firmware()
        return FixedSupervisor(store or Store(dict(self.state)), firmware,
                               self.directory, device_ref), firmware

    def test_applied_payload_is_verified_before_firmware_boot(self):
        store = Store(dict(self.state))
        owner, firmware = self.owner(store)
        result = owner.boot_once()
        self.assertEqual(store.calls, ['load', 'recover'])
        self.assertEqual(firmware.boot_calls, 1)
        self.assertEqual(result.slot, 'A')
        self.assertEqual(result.config.revision, REVISION)
        self.assertNotIn(SECRET, repr(result))
        self.assertNotIn(SECRET, repr(result.config))
        self.assertNotIn(SECRET, repr(result.config.device))
        self.assertNotIn(SECRET, repr(result.config.device.wifi_profiles))

    def test_import_is_inert(self):
        reads_before = self.filesystem.reads
        self.assertIs(importlib.import_module('firmware.pico.fixed_supervisor'),
                      fixed_supervisor_module)
        self.assertEqual(self.filesystem.reads, reads_before)

    def test_micropython_shaped_import_without_package_is_inert(self):
        source = Path(fixed_supervisor_module.__file__).read_text(encoding='utf-8')
        namespace = {'__name__': 'fixed_supervisor'}
        with mock.patch('builtins.open', wraps=self.filesystem.open) as open_file, \
                mock.patch.object(socket, 'create_connection') as connect, \
                mock.patch.object(socket, 'socket') as create_socket:
            exec(compile(source, fixed_supervisor_module.__file__, 'exec'), namespace)
        self.assertNotIn('__package__', namespace)
        self.assertTrue(callable(namespace['FixedSupervisor']))
        open_file.assert_not_called()
        connect.assert_not_called()
        create_socket.assert_not_called()

    def test_corrupt_missing_wrong_reference_and_store_error_never_boot(self):
        cases = ('corrupt', 'missing', 'wrong_ref', 'store_error')
        for case in cases:
            with self.subTest(case=case):
                self._isolate_claim()
                state = dict(self.state)
                store = Store(state, error=(case == 'store_error'))
                if case == 'corrupt':
                    self.filesystem.files[self.directory + '/' + self.basename] = self.raw + b'!'
                elif case == 'missing':
                    self.filesystem.files.pop(self.directory + '/' + self.basename)
                elif case == 'wrong_ref':
                    bad = payload('123e4567-e89b-42d3-a456-426614174099')
                    self.filesystem.files[self.directory + '/' + self.basename] = bad
                    state['applied'] = [self.basename, len(bad), hashlib.sha256(bad).hexdigest()]
                owner, firmware = self.owner(store)
                with self.assertRaises(RecoveryRequired) as caught:
                    owner.boot_once()
                self.assertEqual(firmware.boot_calls, 0)
                self.assertNotIn(SECRET, ''.join(traceback.format_exception(caught.exception)))
                if case != 'store_error':
                    self.filesystem.files[self.directory + '/' + self.basename] = self.raw

    def test_interrupted_configuration_trial_rolls_back_before_firmware(self):
        store = Store(dict(self.state, status='trial', candidate=['new.json', 1, '0' * 64]))
        owner, firmware = self.owner(store)
        owner.boot_once()
        self.assertEqual(store.calls, ['load', 'recover'])
        self.assertEqual(store.state['status'], 'rolled_back')
        self.assertEqual(firmware.boot_calls, 1)

    def test_second_boot_once_is_rejected(self):
        owner, firmware = self.owner()
        owner.boot_once()
        with self.assertRaises(FixedSupervisorError):
            owner.boot_once()
        self.assertEqual(firmware.boot_calls, 1)

    def test_second_owner_rejected_while_first_is_active_or_after_return(self):
        second_store = Store(dict(self.state))
        second_owner, second_firmware = self.owner(second_store)
        first_store = Store(dict(self.state), on_load=lambda: self._assert_second_rejected(
            second_owner, second_store, second_firmware))
        first_owner, first_firmware = self.owner(first_store)
        first_owner.boot_once()
        self._assert_second_rejected(second_owner, second_store, second_firmware)
        self.assertEqual(first_firmware.boot_calls, 1)

    def test_second_owner_rejected_after_first_owner_fails(self):
        second_store = Store(dict(self.state))
        second_owner, second_firmware = self.owner(second_store)

        class FailedFirmware(Firmware):
            def boot(self):
                self.boot_calls += 1
                raise RuntimeError(SECRET)

        first_store = Store(dict(self.state))
        first_owner, first_firmware = self.owner(first_store, FailedFirmware())
        with self.assertRaises(RecoveryRequired):
            first_owner.boot_once()
        self._assert_second_rejected(second_owner, second_store, second_firmware)
        self.assertEqual(first_store.calls, ['load', 'recover'])
        self.assertEqual(first_firmware.boot_calls, 1)

    def test_lock_contention_uses_nonblocking_claim(self):
        class ContendedLock:
            def __init__(self):
                self.arguments = []

            def acquire(self, blocking=True):
                self.arguments.append(blocking)
                return False

        lock = ContendedLock()
        fixed_supervisor_module._PROCESS_LOCK = lock
        store = Store(dict(self.state))
        owner, firmware = self.owner(store)
        with self.assertRaises(FixedSupervisorError):
            owner.boot_once()
        self.assertEqual(lock.arguments, [False])
        self.assertEqual(store.calls, [])
        self.assertEqual(firmware.boot_calls, 0)

    def test_metadata_device_ref_must_match_before_payload_or_firmware(self):
        valid_state = {
            'device_ref': '123e4567-e89b-42d3-a456-426614174099',
            'applied': [self.basename, len(self.raw), hashlib.sha256(self.raw).hexdigest()],
            'applied_revision': REVISION,
            'applied_change_id': CHANGE,
            'candidate': None,
            'status': 'ready',
            'revision': REVISION,
            'change_id': CHANGE,
            'consumed': [CHANGE],
            'reason': None,
        }
        # Exercise real CRC-checked metadata loading with an otherwise matching
        # applied payload and immutable payload device_ref.
        metadata_path = '/trusted/meta/config.a'
        self.filesystem.files[metadata_path] = _encode(1, valid_state)

        class CRCStore(ConfigTrialStore):
            def __init__(self):
                super().__init__('/trusted/meta')

        store = CRCStore()
        owner, firmware = self.owner(store)
        with self.assertRaises(RecoveryRequired) as caught:
            owner.boot_once()
        self.assertEqual(firmware.boot_calls, 0)
        # ConfigTrialStore checks both metadata records; no third read of the
        # otherwise matching payload may occur after the device-ref mismatch.
        self.assertEqual(self.filesystem.reads, 2)
        self.assertEqual(str(caught.exception), 'applied configuration requires USB recovery')
        self.assertNotIn(SECRET, ''.join(traceback.format_exception(caught.exception)))

    @staticmethod
    def _assert_second_rejected(owner, store, firmware):
        with unittest.TestCase().assertRaises(FixedSupervisorError):
            owner.boot_once()
        if store is not None:
            assert store.calls == []
        assert firmware.boot_calls == 0

    def test_disabled_release_admission_has_no_writer_effect(self):
        self.assertFalse(AUTOMATIC_UPDATES_ENABLED)
        owner, firmware = self.owner()
        with self.assertRaises(FixedSupervisorError):
            owner.admit_and_stage_firmware(SECRET)
        self.assertEqual(firmware.stage_calls, 0)

    def test_operations_require_completed_boot(self):
        owner, _ = self.owner()
        with self.assertRaises(FixedSupervisorError):
            owner.run_operation('config', lambda: self.fail('callback ran'))

    def test_config_and_firmware_callbacks_reject_cross_family_reentry(self):
        owner, _ = self.owner()
        owner.boot_once()
        observed = []

        def config_work():
            with self.assertRaises(FixedSupervisorError):
                owner.run_operation('firmware', lambda: self.fail('nested ran'))
            observed.append('config')

        owner.run_operation('config', config_work)

        def firmware_work():
            with self.assertRaises(FixedSupervisorError):
                owner.run_operation('config', lambda: self.fail('nested ran'))
            observed.append('firmware')

        owner.run_operation('firmware', firmware_work)
        self.assertEqual(observed, ['config', 'firmware'])

    def test_firmware_pending_metadata_blocks_config_before_callback(self):
        owner, firmware = self.owner()
        owner.boot_once()
        firmware._state.state['phase'] = 'writing'
        called = []
        with self.assertRaises(FixedSupervisorError):
            owner.run_operation('config', lambda: called.append(True))
        self.assertEqual(called, [])

    def test_config_active_status_blocks_firmware_before_callback(self):
        for status in ('received', 'staged', 'trial'):
            with self.subTest(status=status):
                self._isolate_claim()
                store = Store(dict(self.state, status=status))
                owner, _ = self.owner(store)
                owner.boot_once()
                # Boot recovery is responsible for interrupted trials; emulate
                # a later active writer state without reloading the store.
                store.state['status'] = status
                called = []
                with self.assertRaises(FixedSupervisorError):
                    owner.run_operation('firmware', lambda: called.append(True))
                self.assertEqual(called, [])

    def test_invalidated_store_quarantines_until_new_process(self):
        owner, _ = self.owner()
        owner.boot_once()
        owner._config_store.state = None
        with self.assertRaises(FixedSupervisorError):
            owner.run_operation('config', lambda: self.fail('callback ran'))
        owner._config_store.state = dict(self.state)
        with self.assertRaises(FixedSupervisorError):
            owner.run_operation('config', lambda: self.fail('callback ran'))

    def test_explicit_quarantine_during_operation_blocks_later_work(self):
        owner, _ = self.owner()
        owner.boot_once()
        called = []

        self.assertEqual(owner.run_operation('config', lambda: (
            owner.quarantine_operations(), 'completed')[1]), 'completed')
        owner.quarantine_operations()  # Idempotent; does not clear the quarantine.

        for kind in ('config', 'firmware'):
            with self.subTest(kind=kind):
                with self.assertRaises(FixedSupervisorError):
                    owner.run_operation(kind, lambda: called.append(kind))
        self.assertEqual(called, [])
        self.assertEqual(owner._config_store.state, self.state)

    def test_explicit_quarantine_requires_successful_boot(self):
        owner, _ = self.owner()
        with self.assertRaises(FixedSupervisorError):
            owner.quarantine_operations()

    def test_missing_firmware_metadata_quarantines(self):
        owner, firmware = self.owner()
        owner.boot_once()
        firmware._state.state = None
        with self.assertRaises(FixedSupervisorError):
            owner.run_operation('firmware', lambda: self.fail('callback ran'))
        firmware._state.state = {
            'phase': None, 'pending_slot': None, 'pending_id': None,
            'trial_marker': None,
        }
        with self.assertRaises(FixedSupervisorError):
            owner.run_operation('config', lambda: self.fail('callback ran'))

    def test_wrapped_state_write_error_quarantines_and_redacts(self):
        from firmware.pico.config_trial import StateWriteError

        owner, _ = self.owner()
        owner.boot_once()

        def fail_write():
            try:
                raise StateWriteError(SECRET)
            except StateWriteError as error:
                raise RuntimeError('wrapper ' + SECRET) from error

        with self.assertRaises(FixedSupervisorError) as caught:
            owner.run_operation('config', fail_write)
        self.assertNotIn(SECRET, ''.join(traceback.format_exception(caught.exception)))
        with self.assertRaises(FixedSupervisorError):
            owner.run_operation('firmware', lambda: None)

    def test_handled_rollback_allows_later_safe_operation(self):
        owner, _ = self.owner()
        owner.boot_once()
        owner.run_operation('config', lambda: setattr(
            owner._config_store, 'state', dict(self.state, status='rolled_back')))
        self.assertEqual(owner.run_operation('firmware', lambda: 'safe'), 'safe')

    def test_enabled_stage_routes_through_operation_guard(self):
        owner, firmware = self.owner()
        owner.boot_once()
        with mock.patch.object(fixed_supervisor_module,
                               'AUTOMATIC_UPDATES_ENABLED', True):
            owner.admit_and_stage_firmware('candidate')
        self.assertEqual(firmware.stage_calls, 1)

    def test_unsafe_or_ambiguous_applied_basename_never_boots(self):
        for basename in ('../secret.json', '/absolute.json', 'a/b.json', '..', ''):
            with self.subTest(basename=basename):
                self._isolate_claim()
                state = dict(self.state)
                state['applied'] = [basename, len(self.raw), hashlib.sha256(self.raw).hexdigest()]
                owner, firmware = self.owner(Store(state))
                with self.assertRaises(RecoveryRequired):
                    owner.boot_once()
                self.assertEqual(firmware.boot_calls, 0)

    def test_metadata_revision_and_change_id_must_match_payload(self):
        for key in ('applied_revision', 'applied_change_id'):
            with self.subTest(key=key):
                self._isolate_claim()
                state = dict(self.state)
                state[key] = '323e4567-e89b-42d3-a456-426614174001'
                owner, firmware = self.owner(Store(state))
                with self.assertRaises(RecoveryRequired):
                    owner.boot_once()
                self.assertEqual(firmware.boot_calls, 0)

    @staticmethod
    def _isolate_claim():
        fixed_supervisor_module._BOOT_CLAIMED = False
        fixed_supervisor_module._PROCESS_LOCK = threading.Lock()


if __name__ == '__main__':
    unittest.main()
