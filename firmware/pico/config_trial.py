"""Host-only durable metadata for externally supervised configuration trials.

This module never parses or writes configuration payloads. Callers must retain
the applied payload, verify every referenced file after boot, and provide the
external end-to-end proof required to promote a candidate. Payload reading and
hashing, old/new reference garbage collection, Gist readback, Wi-Fi cutover, and
supervisor serialization are explicitly outside this model.
"""

import binascii
import errno
import json
import os


RECORD_VERSION = 1
MAX_RECORD_BYTES = 8192
MAX_PAYLOAD_BYTES = 65536
MAX_CONSUMED_IDS = 64
MAX_SEQUENCE = 2147483647
TRIAL_MS = 300000
_FIELDS = ('device_ref', 'applied', 'applied_revision', 'applied_change_id',
           'candidate', 'status', 'revision', 'change_id', 'consumed', 'reason')
_STATUSES = ('ready', 'received', 'staged', 'trial', 'rejected',
             'rolled_back', 'applied')
_REASON_CODES = ('invalid_config', 'unsupported_schema', 'signature_invalid',
                 'storage_error', 'trial_failed', 'reboot_failed',
                 'supervisor_rejected', 'inconclusive', 'wifi_failed',
                 'authentication_failed', 'destination_failed', 'sensor_failed',
                 'reboot_interrupted')
_TICKS_PERIOD = 1 << 30
_TICKS_HALF_PERIOD = _TICKS_PERIOD >> 1


class RecoveryRequired(Exception):
    """Metadata or referenced content is not safe to select."""


class StateWriteError(Exception):
    """Persistence outcome is ambiguous; discard RAM state and reload."""


def _uuid(value):
    if not isinstance(value, str) or len(value) != 36:
        raise ValueError('invalid UUID')
    groups = value.split('-')
    if [len(group) for group in groups] != [8, 4, 4, 4, 12]:
        raise ValueError('invalid UUID')
    compact = ''.join(groups)
    if any(char not in '0123456789abcdefABCDEF' for char in compact):
        raise ValueError('invalid UUID')
    lowered = value.lower()
    if lowered[14] not in '12345678' or lowered[19] not in '89ab':
        raise ValueError('invalid UUID variant or version')
    return lowered


def _identifier(value, label, maximum=64):
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ValueError('invalid ' + label)
    if any(char not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-' for char in value):
        raise ValueError('invalid ' + label)
    return value


def _reference(basename, byte_count, digest):
    if not isinstance(basename, str) or not basename or len(basename) > 64:
        raise ValueError('invalid payload basename')
    if basename in ('.', '..') or basename.startswith('.'):
        raise ValueError('invalid payload basename')
    _identifier(basename, 'payload basename')
    if type(byte_count) is not int or not 0 <= byte_count <= MAX_PAYLOAD_BYTES:
        raise ValueError('invalid payload size')
    if (not isinstance(digest, str) or len(digest) != 64
            or any(char not in '0123456789abcdef' for char in digest)):
        raise ValueError('invalid lowercase SHA-256')
    return [basename, byte_count, digest]


def _validate(state):
    if not isinstance(state, dict) or set(state.keys()) != set(_FIELDS):
        raise ValueError('invalid metadata fields')
    _identifier(state['device_ref'], 'device reference', 64)
    for key in ('applied', 'candidate'):
        reference = state[key]
        if reference is not None:
            if not isinstance(reference, list) or len(reference) != 3:
                raise ValueError('invalid payload reference')
            _reference(reference[0], reference[1], reference[2])
    if state['applied'] is None:
        raise ValueError('applied payload reference required')
    if state['status'] not in _STATUSES:
        raise ValueError('invalid status')
    if state['applied_revision'] is None or _uuid(state['applied_revision']) != state['applied_revision']:
        raise ValueError('applied revision must be normalized lowercase UUID')
    if state['applied_change_id'] is None or _uuid(state['applied_change_id']) != state['applied_change_id']:
        raise ValueError('applied change ID must be normalized lowercase UUID')
    if state['revision'] is not None and _uuid(state['revision']) != state['revision']:
        raise ValueError('fleet revision must be normalized lowercase UUID')
    if state['change_id'] is not None and _uuid(state['change_id']) != state['change_id']:
        raise ValueError('change ID must be normalized lowercase UUID')
    consumed = state['consumed']
    if not isinstance(consumed, list) or len(consumed) > MAX_CONSUMED_IDS:
        raise ValueError('invalid consumed IDs')
    normalized = []
    for raw_item in consumed:
        item = _uuid(raw_item)
        if raw_item != item or item in normalized:
            raise ValueError('invalid or duplicate consumed ID')
        normalized.append(item)
    if state['reason'] is not None:
        _reason(state['reason'])
    if state['status'] in ('received', 'staged', 'trial'):
        if state['change_id'] is None or state['revision'] is None:
            raise ValueError('active change identifiers required')
        if state['change_id'] not in consumed:
            raise ValueError('active change ID must be consumed')
    if state['status'] in ('staged', 'trial') and state['candidate'] is None:
        raise ValueError('candidate reference required')
    if state['status'] not in ('staged', 'trial') and state['candidate'] is not None:
        raise ValueError('candidate only valid while staged or trialing')


def _reason(reason):
    if reason not in _REASON_CODES:
        raise ValueError('reason must be a known configuration reason code')
    return reason


def _values(state):
    return [state[key] for key in _FIELDS]


def _encode(sequence, state):
    body = [RECORD_VERSION, sequence] + _values(state)
    checksum = '%08x' % (binascii.crc32(json.dumps(body).encode('utf-8')) & 0xffffffff)
    encoded = json.dumps(body + [checksum]).encode('utf-8')
    if len(encoded) > MAX_RECORD_BYTES:
        raise ValueError('metadata record too large')
    return encoded


def _decode(raw):
    if len(raw) > MAX_RECORD_BYTES:
        raise ValueError('metadata record too large')
    record = json.loads(raw.decode('utf-8'))
    if not isinstance(record, list) or len(record) != len(_FIELDS) + 3:
        raise ValueError('invalid metadata array')
    if type(record[0]) is not int or record[0] != RECORD_VERSION:
        raise ValueError('unsupported metadata version')
    sequence = record[1]
    if type(sequence) is not int or not 1 <= sequence <= MAX_SEQUENCE:
        raise ValueError('invalid metadata sequence')
    state = dict(zip(_FIELDS, record[2:-1]))
    _validate(state)
    checksum = record[-1]
    expected = '%08x' % (binascii.crc32(json.dumps(record[:-1]).encode('utf-8')) & 0xffffffff)
    if not isinstance(checksum, str) or checksum != expected:
        raise ValueError('metadata checksum mismatch')
    return sequence, state


class _ConfigProof:
    """Private receipt binding external proof to one exact loaded trial.

    This is an in-process coordination token, not a cryptographic boundary:
    Python callers able to import private names can construct one. A future
    trusted proof coordinator must create it only after performing real proof.
    """

    __slots__ = ('_store', '_sequence', '_candidate', '_device_ref',
                 '_revision', '_change_id', '_trial_started', '_sealed')

    def __init__(self, store):
        if (not isinstance(store, ConfigTrialStore) or store.state is None
                or store.state.get('status') != 'trial'):
            raise ValueError('a loaded trial is required')
        object.__setattr__(self, '_store', store)
        object.__setattr__(self, '_sequence', store.sequence)
        candidate = store.state.get('candidate')
        object.__setattr__(self, '_candidate', tuple(candidate) if candidate is not None else None)
        object.__setattr__(self, '_device_ref', store.state.get('device_ref'))
        object.__setattr__(self, '_revision', store.state.get('revision'))
        object.__setattr__(self, '_change_id', store.state.get('change_id'))
        object.__setattr__(self, '_trial_started', store.trial_started)
        object.__setattr__(self, '_sealed', True)

    def __setattr__(self, name, value):
        raise AttributeError('configuration proof receipts are immutable')

    def __repr__(self):
        return '<_ConfigProof>'

    def _matches(self, store):
        state = store.state
        return (self._store is store and state is not None
                and state.get('status') == 'trial'
                and store.sequence == self._sequence
                and state.get('candidate') == list(self._candidate)
                and state.get('device_ref') == self._device_ref
                and state.get('revision') == self._revision
                and state.get('change_id') == self._change_id
                and store.trial_started == self._trial_started)


class ConfigTrialStore:
    """Two-record metadata store; payload file lifecycle is caller-owned."""

    def __init__(self, directory, ticks_ms=None, ticks_diff=None):
        self.directory = directory
        self.sequence = 0
        self.active_record = None
        self.state = None
        self.trial_started = None
        self._ticks_ms = ticks_ms
        self._ticks_diff = ticks_diff

    def _path(self, name):
        return self.directory + '/' + name

    def _invalidate(self):
        self.sequence = 0
        self.active_record = None
        self.state = None
        self.trial_started = None

    def _require(self):
        if self.state is None:
            raise RecoveryRequired('reload metadata and reverify referenced payloads')

    def load(self):
        valid = []
        for name in ('config.a', 'config.b'):
            try:
                with open(self._path(name), 'rb') as handle:
                    raw = handle.read(MAX_RECORD_BYTES + 1)
                sequence, state = _decode(raw)
                valid.append((sequence, name, state))
            except (OSError, ValueError, TypeError, UnicodeError):
                pass
        if not valid:
            self._invalidate()
            raise RecoveryRequired('no valid configuration metadata record')
        top = max(item[0] for item in valid)
        highest = [item for item in valid if item[0] == top]
        if len(highest) > 1 and highest[0][2] != highest[1][2]:
            self._invalidate()
            raise RecoveryRequired('conflicting metadata records')
        self.sequence, self.active_record, state = highest[0]
        self.state = dict(state)
        self.trial_started = None
        return dict(self.state)

    def initialize(self, applied_basename, applied_bytes, applied_sha256,
                   revision, change_id, device_ref, verified):
        if self.state is not None:
            raise ValueError('store already initialized')
        for name in ('config.a', 'config.b'):
            try:
                os.stat(self._path(name))
            except OSError as error:
                if getattr(error, 'errno', None) == errno.ENOENT:
                    continue
                raise RecoveryRequired('cannot establish metadata absence')
            raise RecoveryRequired('metadata already exists')
        if verified is not True:
            raise ValueError('externally verified USB baseline required')
        reference = _reference(applied_basename, applied_bytes, applied_sha256)
        applied_revision = _uuid(revision)
        applied_change_id = _uuid(change_id)
        initial = dict(device_ref=_identifier(device_ref, 'device reference', 64), applied=reference,
                       applied_revision=applied_revision,
                       applied_change_id=applied_change_id,
                       candidate=None, status='ready', revision=applied_revision,
                       change_id=applied_change_id, consumed=[applied_change_id], reason=None)
        self._commit(initial)

    def _commit(self, state):
        _validate(state)
        if self.sequence >= MAX_SEQUENCE:
            self._invalidate()
            raise RecoveryRequired('metadata sequence exhausted')
        target = 'config.b' if self.active_record == 'config.a' else 'config.a'
        sequence = self.sequence + 1
        payload = _encode(sequence, state)
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
                reread = verify.read(MAX_RECORD_BYTES + 1)
            read_sequence, read_state = _decode(reread)
            if read_sequence != sequence or read_state != state:
                raise ValueError('metadata readback mismatch')
        except Exception as error:
            self._invalidate()
            raise StateWriteError('metadata write ambiguous; reload and reverify payloads') from None
        self.sequence, self.active_record, self.state = sequence, target, dict(state)

    def begin_received(self, revision, change_id):
        self._require()
        state = dict(self.state)
        if state['status'] in ('received', 'staged', 'trial'):
            raise ValueError('another configuration change is active')
        revision = _uuid(revision)
        change_id = _uuid(change_id)
        if change_id in state['consumed']:
            raise ValueError('change ID was already consumed')
        if len(state['consumed']) >= MAX_CONSUMED_IDS:
            raise RecoveryRequired('consumed change ID capacity exhausted')
        # Reservation and received status are committed before any staging.
        state['consumed'] = state['consumed'] + [change_id]
        state['revision'], state['change_id'] = revision, change_id
        state['candidate'], state['reason'], state['status'] = None, None, 'received'
        self._commit(state)

    def stage_candidate(self, basename, byte_count, sha256, verified):
        self._require()
        if self.state['status'] != 'received':
            raise ValueError('a received change is required')
        if verified is not True:
            raise ValueError('externally verified bounded candidate required')
        state = dict(self.state)
        state['candidate'] = _reference(basename, byte_count, sha256)
        if state['candidate'][0] == state['applied'][0]:
            raise ValueError('candidate must not overwrite applied payload')
        if byte_count == 0:
            raise ValueError('candidate payload must not be empty')
        state['status'] = 'staged'
        self._commit(state)

    def enter_trial(self):
        self._require()
        if self.state['status'] != 'staged':
            raise ValueError('verified staged candidate required')
        if not callable(self._ticks_ms) or not callable(self._ticks_diff):
            raise ValueError('trial requires monotonic ticks_ms clock')
        try:
            started = self._ticks_ms()
        except Exception:
            raise ValueError('trial clock unavailable')
        if type(started) is not int or not 0 <= started < _TICKS_PERIOD:
            raise ValueError('trial clock must return in-range integer ticks')
        state = dict(self.state)
        state['status'] = 'trial'
        self._commit(state)
        self.trial_started = started

    def _elapsed(self, now):
        if (self.trial_started is None or not callable(self._ticks_diff)
                or type(now) is not int or not 0 <= now < _TICKS_PERIOD):
            return None
        try:
            elapsed = self._ticks_diff(now, self.trial_started)
        except Exception:
            return None
        if type(elapsed) is not int or not -_TICKS_HALF_PERIOD <= elapsed < _TICKS_HALF_PERIOD:
            return None
        return elapsed if elapsed >= 0 else None

    def expire_or_confirm(self, now, proof=None):
        self._require()
        if self.state['status'] != 'trial':
            return False
        elapsed = self._elapsed(now)
        if elapsed is None or elapsed >= TRIAL_MS:
            self.rollback('inconclusive')
            return False
        if type(proof) is not _ConfigProof or not proof._matches(self):
            return False
        state = dict(self.state)
        state['applied'] = list(state['candidate'])
        state['applied_revision'] = state['revision']
        state['applied_change_id'] = state['change_id']
        state['candidate'], state['status'], state['reason'] = None, 'applied', None
        self._commit(state)
        self.trial_started = None
        return True

    def reject(self, reason):
        if self.state is None:
            self._require()
        if self.state['status'] == 'trial':
            raise ValueError('an activated trial can only be rolled back')
        self._finish('rejected', reason)

    def rollback(self, reason):
        self._finish('rolled_back', reason)

    def _finish(self, status, reason):
        self._require()
        if self.state['status'] not in ('received', 'staged', 'trial'):
            raise ValueError('no active change to finish')
        state = dict(self.state)
        state['candidate'], state['status'], state['reason'] = None, status, _reason(reason)
        self._commit(state)
        self.trial_started = None

    def recover_after_boot(self):
        self._require()
        if self.state['status'] in ('received', 'staged', 'trial'):
            self._finish('rolled_back', 'reboot_interrupted')
            return 'rolled_back'
        return 'ready'
