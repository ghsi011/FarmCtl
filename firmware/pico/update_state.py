"""Host-testable, MicroPython-compatible A/B firmware update metadata model.

Boolean verification arguments are gates, not authentication. The supervisor
must independently call verify_candidate and verify_staged_assets before use.
"""

import binascii
import errno
import json
import os


RECORD_VERSION = 1
TRIAL_SECONDS = 300
TRIAL_MS = 300000
MAX_RECORD = 1024
MAX_SEQUENCE = 2147483647
# Release identifiers may use up to 20 decimal digits; the serialized record
# remains independently bounded by MAX_RECORD.
MAX_RELEASE_ID = 99999999999999999999
MAX_MARKER = 128
_FIELDS = (
    'applied_slot', 'applied_id', 'retained_slot', 'retained_id',
    'installed_high_water', 'failed_high_water', 'pending_slot',
    'pending_id', 'trial_marker', 'phase',
)
_PHASES = (None, 'writing', 'trial_entered')


class RecoveryRequired(Exception):
    """No trustworthy metadata selection exists; require USB recovery."""


class StateWriteError(Exception):
    """A metadata operation had an ambiguous persistence outcome; reload."""


def _state_values(state):
    return [state[name] for name in _FIELDS]


def _state_from_values(values):
    if not isinstance(values, list) or len(values) != len(_FIELDS):
        raise ValueError('invalid state array')
    return dict(zip(_FIELDS, values))


def _validate_state(state):
    if not isinstance(state, dict) or set(state.keys()) != set(_FIELDS):
        raise ValueError('invalid state fields')
    applied = state['applied_slot']
    retained = state['retained_slot']
    if applied not in ('A', 'B'):
        raise ValueError('invalid applied slot')
    if retained is not None and (retained not in ('A', 'B') or retained == applied):
        raise ValueError('invalid retained slot')
    for key in ('applied_id', 'installed_high_water', 'failed_high_water'):
        value = state[key]
        if type(value) is not int or value < 0 or value > MAX_RELEASE_ID:
            raise ValueError('invalid release id')
    if state['applied_id'] <= 0 or state['installed_high_water'] < state['applied_id']:
        raise ValueError('invalid applied release high-water')
    retained_id = state['retained_id']
    if retained is None:
        if retained_id is not None:
            raise ValueError('retained slot and id must be jointly null')
    elif (type(retained_id) is not int or retained_id <= 0
          or retained_id > MAX_RELEASE_ID
          or retained_id > state['installed_high_water']):
        raise ValueError('retained slot requires a previously installed release id')
    pending_slot = state['pending_slot']
    pending_id = state['pending_id']
    marker = state['trial_marker']
    phase = state['phase']
    if phase not in _PHASES:
        raise ValueError('invalid phase')
    if phase is None:
        if pending_slot is not None or pending_id is not None or marker is not None:
            raise ValueError('incomplete pending phase')
    else:
        if pending_slot not in ('A', 'B') or pending_slot == applied:
            raise ValueError('pending trial must use inactive slot')
        if type(pending_id) is not int or pending_id <= 0 or pending_id > MAX_RELEASE_ID:
            raise ValueError('invalid pending release')
        if pending_id <= max(state['installed_high_water'], state['failed_high_water']):
            raise ValueError('pending release must exceed both high-waters')
        if not isinstance(marker, str) or not marker or len(marker) > MAX_MARKER:
            raise ValueError('invalid trial marker')
        try:
            marker.encode('ascii')
        except UnicodeError:
            raise ValueError('trial marker must be ASCII')
        if pending_slot == retained:
            raise ValueError('overwritten slot cannot remain retained')


def _encode_record(sequence, state):
    body = [RECORD_VERSION, sequence] + _state_values(state)
    checksum = '%08x' % (binascii.crc32(json.dumps(body).encode('utf-8')) & 0xffffffff)
    encoded = json.dumps(body + [checksum]).encode('utf-8')
    if len(encoded) > MAX_RECORD:
        raise ValueError('metadata record too large')
    return encoded


def _decode_record(raw):
    """CRC validates the decoded array semantics; whitespace is not signed."""
    if len(raw) > MAX_RECORD:
        raise ValueError('metadata record too large')
    record = json.loads(raw.decode('utf-8'))
    if not isinstance(record, list) or len(record) != len(_FIELDS) + 3:
        raise ValueError('invalid record array')
    version, sequence = record[0], record[1]
    if type(version) is not int or version != RECORD_VERSION:
        raise ValueError('unknown record version')
    if type(sequence) is not int or sequence < 1 or sequence > MAX_SEQUENCE:
        raise ValueError('invalid sequence')
    state = _state_from_values(record[2:-1])
    _validate_state(state)
    checksum = record[-1]
    if not isinstance(checksum, str) or len(checksum) != 8:
        raise ValueError('invalid checksum')
    expected = '%08x' % (binascii.crc32(json.dumps(record[:-1]).encode('utf-8')) & 0xffffffff)
    if checksum != expected:
        raise ValueError('checksum mismatch')
    return sequence, state


class UpdateStateStore:
    """Two-record persistence; ambiguous errors invalidate this RAM instance."""

    def __init__(self, directory):
        self.directory = directory
        self.sequence = 0
        self.active_record = None
        self.state = None

    def _path(self, name):
        return self.directory + '/' + name

    def _invalidate(self):
        self.sequence = 0
        self.active_record = None
        self.state = None

    def load(self):
        valid = []
        for name in ('state.a', 'state.b'):
            try:
                with open(self._path(name), 'rb') as handle:
                    raw = handle.read(MAX_RECORD + 1)
                sequence, state = _decode_record(raw)
                valid.append((sequence, name, state))
            except (OSError, ValueError, TypeError, UnicodeError):
                pass
        if not valid:
            self._invalidate()
            raise RecoveryRequired('no valid applied-state record; USB recovery required')
        top = max(item[0] for item in valid)
        highest = [item for item in valid if item[0] == top]
        if len(highest) > 1 and highest[0][2] != highest[1][2]:
            self._invalidate()
            raise RecoveryRequired('conflicting equal-sequence records')
        self.sequence, self.active_record, loaded = highest[0]
        self.state = dict(loaded)
        return dict(self.state)

    def initialize(self, state):
        """Initialize only if neither metadata path exists, corrupt or not."""
        if self.state is not None:
            raise ValueError('store already initialized')
        for name in ('state.a', 'state.b'):
            try:
                os.stat(self._path(name))
            except OSError as error:
                if getattr(error, 'errno', None) == errno.ENOENT:
                    continue
                raise RecoveryRequired('cannot establish metadata absence')
            raise RecoveryRequired('metadata already exists; load or recover')
        checked = dict(state)
        _validate_state(checked)
        self._commit(checked)

    def commit(self, state):
        checked = dict(state)
        _validate_state(checked)
        if self.state is None:
            raise RecoveryRequired('store not initialized or must reload')
        if checked['installed_high_water'] < self.state['installed_high_water']:
            raise ValueError('installed high-water cannot decrease')
        if checked['failed_high_water'] < self.state['failed_high_water']:
            raise ValueError('failed high-water cannot decrease')
        self._commit(checked)

    def _commit(self, state):
        if self.sequence >= MAX_SEQUENCE:
            raise RecoveryRequired('metadata sequence exhausted')
        target = 'state.b' if self.active_record == 'state.a' else 'state.a'
        sequence = self.sequence + 1
        payload = _encode_record(sequence, state)
        try:
            handle = open(self._path(target), 'wb')
            try:
                written = handle.write(payload)
                if written is not None and written != len(payload):
                    raise OSError('short metadata write')
                handle.flush()
            finally:
                handle.close()
            with open(self._path(target), 'rb') as verify:
                reread = verify.read(MAX_RECORD + 1)
            read_sequence, read_state = _decode_record(reread)
            if read_sequence != sequence or read_state != state:
                raise ValueError('record verification mismatch')
        except Exception:
            self._invalidate()
            raise StateWriteError('metadata commit ambiguous; reload and reverify slots') from None
        self.sequence = sequence
        self.active_record = target
        self.state = dict(state)


def _clear_pending(state):
    result = dict(state)
    result['pending_slot'] = None
    result['pending_id'] = None
    result['trial_marker'] = None
    result['phase'] = None
    return result


class UpdateState:
    """Host state transitions. Does not authenticate candidates or inspect files."""

    def __init__(self, store, ticks_ms=None, ticks_diff=None):
        self.store = store
        self._ticks_ms = ticks_ms
        self._ticks_diff = ticks_diff
        self.trial_started = None

    @property
    def state(self):
        if self.store.state is None:
            raise RecoveryRequired('state not loaded; reload and reverify')
        return dict(self.store.state)

    def _commit(self, state):
        try:
            self.store.commit(state)
        except StateWriteError:
            self.trial_started = None
            raise

    def stage_candidate(self, release_id, trial_marker, signature_verified,
                        compatible, trial_kind='firmware'):
        state = self.state
        if state['phase'] is not None:
            raise ValueError('another trial is pending')
        if trial_kind != 'firmware':
            raise ValueError('configuration trial is outside this model')
        if signature_verified is not True or compatible is not True:
            raise ValueError('signature and compatibility checks are prerequisites')
        if type(release_id) is not int or release_id <= max(
                state['installed_high_water'], state['failed_high_water']):
            raise ValueError('candidate must exceed installed and failed high-waters')
        if not isinstance(trial_marker, str) or not trial_marker or len(trial_marker) > MAX_MARKER:
            raise ValueError('fresh trial marker required')
        result = dict(state)
        target = 'B' if state['applied_slot'] == 'A' else 'A'
        if target == state['retained_slot']:
            result['retained_slot'] = None
            result['retained_id'] = None
        result['pending_slot'] = target
        result['pending_id'] = release_id
        result['trial_marker'] = trial_marker
        result['phase'] = 'writing'
        self._commit(result)

    def assets_verified_and_enter_trial(self, verify_candidate, verify_staged_assets):
        state = self.state
        if state['phase'] != 'writing':
            raise ValueError('candidate is not in writing phase')
        if verify_candidate is not True or verify_staged_assets is not True:
            raise ValueError('candidate signature and staged assets must be verified')
        if not callable(self._ticks_ms) or not callable(self._ticks_diff):
            raise ValueError('trial requires injected ticks_ms and ticks_diff clock')
        try:
            started = self._ticks_ms()
        except Exception as error:
            raise ValueError('trial clock could not be read') from error
        if type(started) is not int:
            raise ValueError('trial clock must return integer ticks')
        result = dict(state)
        result['phase'] = 'trial_entered'
        self._commit(result)
        self.trial_started = started

    def enter_trial(self, verify_candidate, verify_staged_assets):
        """Persist trial_entered before the caller jumps to candidate code."""
        self.assets_verified_and_enter_trial(verify_candidate, verify_staged_assets)

    def _elapsed(self):
        if self.trial_started is None or self._ticks_ms is None or self._ticks_diff is None:
            return None
        try:
            now = self._ticks_ms()
            if type(now) is not int:
                return None
            elapsed = self._ticks_diff(now, self.trial_started)
        except Exception:
            return None
        if type(elapsed) is not int:
            return None
        return elapsed

    def tick(self):
        """Service deadline even when the external trial_ok reply never arrives."""
        state = self.state
        if state['phase'] != 'trial_entered':
            return False
        elapsed = self._elapsed()
        if elapsed is None or elapsed < 0:
            self.fail_trial()
            return True
        if elapsed >= TRIAL_MS:
            self.fail_trial()
            return True
        return False

    def confirm_trial_ok(self, release_id, trial_marker, response_confirmed):
        state = self.state
        if state['phase'] != 'trial_entered' or self.trial_started is None:
            return False
        elapsed = self._elapsed()
        if elapsed is None or elapsed < 0 or elapsed >= TRIAL_MS:
            self.fail_trial()
            return False
        if (type(release_id) is not int or release_id != state['pending_id']
                or trial_marker != state['trial_marker']
                or response_confirmed is not True):
            return False
        result = dict(state)
        previous_slot = state['applied_slot']
        previous_id = state['applied_id']
        result['applied_slot'] = state['pending_slot']
        result['applied_id'] = state['pending_id']
        result['retained_slot'] = previous_slot
        result['retained_id'] = previous_id
        result['installed_high_water'] = max(state['installed_high_water'], state['pending_id'])
        result = _clear_pending(result)
        self._commit(result)
        self.trial_started = None
        return True

    def fail_trial(self):
        state = self.state
        if state['phase'] is None:
            self.trial_started = None
            return False
        result = dict(state)
        result['failed_high_water'] = max(state['failed_high_water'], state['pending_id'])
        result = _clear_pending(result)
        self._commit(result)
        self.trial_started = None
        return True

    def recover_after_boot(self):
        """Suppress uncertain candidate and invalidate its overwritten slot."""
        state = self.state
        if state['phase'] is not None:
            result = dict(state)
            result['failed_high_water'] = max(state['failed_high_water'], state['pending_id'])
            if result['pending_slot'] == result['retained_slot']:
                result['retained_slot'] = None
                result['retained_id'] = None
            self._commit(_clear_pending(result))
            self.trial_started = None
            return 'rolled_back'
        return 'ready'

    def recover_retained(self, slot, physically_verified):
        """Explicitly select only the verified retained slot; never lower highwaters."""
        state = self.state
        if physically_verified is not True:
            raise ValueError('physical slot verification is required')
        if slot not in ('A', 'B') or slot != state['retained_slot']:
            raise ValueError('requested slot is not retained-good')
        result = dict(state)
        old_applied_slot = state['applied_slot']
        old_applied_id = state['applied_id']
        result['applied_slot'] = slot
        result['applied_id'] = state['retained_id']
        result['retained_slot'] = None
        result['retained_id'] = None
        # The displaced applied image is not claimed good after recovery selection.
        result['installed_high_water'] = max(state['installed_high_water'], old_applied_id)
        self._commit(result)
        return slot
