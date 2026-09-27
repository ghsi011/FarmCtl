"""Import-inert, host-testable fixed boot owner for the Pico firmware.

This is an explicit boot operation, not a ``boot.py``/``main.py`` entrypoint.
The caller supplies USB-provisioned configuration metadata and a trusted
FirmwareSupervisor already bound to the fixed signed A/B slots. Native
filesystem isolation, USB provisioning, watchdog integration, and hardware
qualification remain external.
"""

import hashlib

try:  # MicroPython and CPython both provide a small process-local lock.
    import _thread
    _PROCESS_LOCK = _thread.allocate_lock()
except (ImportError, AttributeError):  # pragma: no cover - unusual host runtime
    _PROCESS_LOCK = None
_BOOT_CLAIMED = False
_OPERATION_ACTIVE = False
_OPERATION_LOCK = _thread.allocate_lock() if '_thread' in globals() else None

if globals().get('__package__'):
    from .config_payload import MAX_PAYLOAD_BYTES, read_device_payload
else:  # MicroPython's trusted modules may be installed on a flat sys.path.
    from config_payload import MAX_PAYLOAD_BYTES, read_device_payload


AUTOMATIC_UPDATES_ENABLED = False


class RecoveryRequired(Exception):
    """A redacted fail-closed boot condition; use the trusted USB path."""


class FixedSupervisorError(Exception):
    """Safe error for invalid owner usage or disabled update admission."""


class BootResult:
    """Boot selection and parsed config, with credentials hidden from repr."""

    __slots__ = ('slot', 'config')

    def __init__(self, slot, config):
        self.slot = slot
        self.config = config

    def __repr__(self):
        return 'BootResult(slot=%r, config=<redacted>)' % (self.slot,)


class _SecretSafeView:
    """Attribute-compatible parsed config view whose representation is safe."""

    __slots__ = ('__value',)

    def __init__(self, value):
        self.__value = value

    def __getattr__(self, name):
        value = getattr(self.__value, name)
        if name == 'device':
            return _SecretSafeView(value)
        if name == 'wifi_profiles':
            return tuple(_SecretSafeView(item) for item in value)
        return value

    def __repr__(self):
        return '<configuration data redacted>'


def _valid_directory(directory):
    if not isinstance(directory, str) or not directory.startswith('/'):
        return False
    if '\x00' in directory or '//' in directory:
        return False
    return all(part not in ('.', '..') for part in directory.split('/')[1:])


def _valid_basename(name):
    if (not isinstance(name, str) or not name or len(name) > 64
            or name in ('.', '..') or name.startswith('.')):
        return False
    return all(char in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-'
               for char in name)


class FixedSupervisor:
    """Load and verify applied config before delegating signed slot selection.

    Configuration and firmware operations share a process-local exclusive
    guard. Automatic configuration activation is deliberately not exposed.
    """

    def __init__(self, config_store, firmware_supervisor,
                 payload_directory, immutable_device_ref):
        if not callable(getattr(config_store, 'load', None)) or not callable(
                getattr(config_store, 'recover_after_boot', None)):
            raise ValueError('configuration store must support load and recovery')
        if not callable(getattr(firmware_supervisor, 'boot', None)):
            raise ValueError('trusted firmware supervisor is required')
        if not _valid_directory(payload_directory):
            raise ValueError('trusted absolute POSIX payload directory required')
        if not isinstance(immutable_device_ref, str) or not immutable_device_ref:
            raise ValueError('immutable device reference required')
        self._config_store = config_store
        self._firmware = firmware_supervisor
        self._payload_directory = payload_directory
        self._device_ref = immutable_device_ref
        self._attempted = False
        self._booted = False
        self._quarantined = False

    def boot_once(self):
        """Recover config first, verify its exact applied bytes, then boot slots."""
        global _BOOT_CLAIMED
        if self._attempted:
            raise FixedSupervisorError('boot already attempted for this owner')
        self._attempted = True  # Claim before touching stores/files or launching.
        if _PROCESS_LOCK is not None:
            # Keep this lock held forever after a successful claim. Nonblocking
            # acquire rejects a competing owner immediately, rather than
            # serializing a second launch behind a long-running first one.
            if not _PROCESS_LOCK.acquire(False):
                raise FixedSupervisorError('process boot already claimed')
        elif _BOOT_CLAIMED:
            # Without _thread, rely only on MicroPython's single-threaded model.
            raise FixedSupervisorError('process boot already claimed')
        _BOOT_CLAIMED = True
        return self._boot_claimed()

    def _boot_claimed(self):
        try:
            state = self._config_store.load()
            self._config_store.recover_after_boot()
            # Recovery may roll back an interrupted trial, so inspect the
            # persisted/current applied reference only after recovery completes.
            state = getattr(self._config_store, 'state', state)
            if not isinstance(state, dict):
                raise ValueError('invalid config metadata')
            if state.get('device_ref') != self._device_ref:
                raise ValueError('configuration metadata device mismatch')
            applied = state.get('applied')
            if not isinstance(applied, list) or len(applied) != 3:
                raise ValueError('invalid applied reference')
            basename, byte_count, expected_digest = applied
            if not _valid_basename(basename):
                raise ValueError('invalid applied basename')
            if (type(byte_count) is not int or not 0 < byte_count <= MAX_PAYLOAD_BYTES
                    or not isinstance(expected_digest, str) or len(expected_digest) != 64
                    or any(char not in '0123456789abcdef' for char in expected_digest)):
                raise ValueError('invalid applied digest reference')
            path = self._payload_directory.rstrip('/') + '/' + basename
            with open(path, 'rb') as handle:
                payload = handle.read(MAX_PAYLOAD_BYTES + 1)
            if (not isinstance(payload, bytes) or len(payload) != byte_count
                    or len(payload) > MAX_PAYLOAD_BYTES
                    or _sha256(payload) != expected_digest):
                raise ValueError('applied payload verification failed')
            parsed = read_device_payload(payload, self._device_ref)
            if (parsed.revision != state.get('applied_revision')
                    or parsed.device.change_id != state.get('applied_change_id')):
                raise ValueError('applied configuration metadata mismatch')
        except Exception:
            # Never chain arbitrary storage/parser errors; they could contain
            # paths or payload-derived secret material.
            raise RecoveryRequired('applied configuration requires USB recovery') from None

        try:
            selected_slot = self._firmware.boot()
        except Exception:
            raise RecoveryRequired('authenticated firmware boot requires USB recovery') from None
        self._booted = True
        return BootResult(selected_slot, _SecretSafeView(parsed))

    def quarantine_operations(self):
        """Permanently reject later operations until reboot or USB recovery."""
        if not self._booted:
            raise FixedSupervisorError('boot must complete before operations')
        self._quarantined = True

    def run_operation(self, kind, callback):
        """Run trusted synchronous config/firmware work under a shared guard."""
        global _OPERATION_ACTIVE
        if kind not in ('config', 'firmware') or not callable(callback):
            raise FixedSupervisorError('invalid operation')
        if not self._booted:
            raise FixedSupervisorError('boot must complete before operations')
        if self._quarantined:
            raise FixedSupervisorError('operations require reboot or USB recovery')
        if _OPERATION_LOCK is not None:
            if not _OPERATION_LOCK.acquire(False):
                raise FixedSupervisorError('operation already active')
        elif _OPERATION_ACTIVE:
            raise FixedSupervisorError('operation already active')
        _OPERATION_ACTIVE = True
        try:
            config, firmware = self._operation_states()
            if kind == 'config':
                if (firmware['phase'] is not None or firmware['pending_slot'] is not None
                        or firmware['pending_id'] is not None
                        or firmware['trial_marker'] is not None):
                    raise FixedSupervisorError('firmware update state is not idle')
            elif config['status'] in ('received', 'staged', 'trial'):
                raise FixedSupervisorError('configuration trial is active')
            try:
                result = callback()
            except Exception as error:
                if _has_write_error(error) or not self._states_loaded():
                    self._quarantined = True
                raise FixedSupervisorError('operation failed; recovery may be required') from None
            if not self._states_loaded():
                self._quarantined = True
                raise FixedSupervisorError('operation state requires recovery')
            return result
        except FixedSupervisorError:
            raise
        except Exception:
            self._quarantined = True
            raise FixedSupervisorError('operation state requires recovery') from None
        finally:
            _OPERATION_ACTIVE = False
            if _OPERATION_LOCK is not None:
                _OPERATION_LOCK.release()

    def _operation_states(self):
        config = getattr(self._config_store, 'state', None)
        firmware_store = getattr(self._firmware, '_state', None)
        firmware = getattr(firmware_store, 'state', None)
        if (not isinstance(config, dict) or config.get('status') not in
                ('ready', 'received', 'staged', 'trial', 'rejected', 'rolled_back', 'applied')
                or not isinstance(firmware, dict)
                or any(key not in firmware for key in
                       ('phase', 'pending_slot', 'pending_id', 'trial_marker'))):
            self._quarantined = True
            raise FixedSupervisorError('operation metadata unavailable')
        return config, firmware

    def _states_loaded(self):
        try:
            self._operation_states()
            return True
        except Exception:
            return False

    def admit_and_stage_firmware(self, *args, **kwargs):
        """Fail closed before any candidate callback while auto-updates are off."""
        if not AUTOMATIC_UPDATES_ENABLED:
            raise FixedSupervisorError('automatic firmware updates are disabled')
        method = getattr(self._firmware, 'admit_and_stage', None)
        if not callable(method):
            raise FixedSupervisorError('firmware staging is unavailable')
        return self.run_operation('firmware', lambda: method(*args, **kwargs))


def _has_write_error(error):
    pending = [error]
    visited = []
    while pending:
        current = pending.pop()
        if current in visited:
            continue
        visited.append(current)
        if current.__class__.__name__ == 'StateWriteError':
            return True
        for linked in (getattr(current, '__cause__', None),
                       getattr(current, '__context__', None)):
            if linked is not None:
                pending.append(linked)
    return False


def _sha256(data):
    digest = hashlib.sha256(data).digest()
    return ''.join('%02x' % byte for byte in digest)
