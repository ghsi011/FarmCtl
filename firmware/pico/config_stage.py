"""Host-only coordinator for safely staging a private fleet configuration.

Staging is not activation: this module never enters a trial or claims that a
configuration has been applied. The applied file remains immutable.
"""

import hashlib
import os

from config_payload import (ConfigPayloadError, extract_device_payload,
                            read_device_payload, write_owned_payload)
from config_trial import ConfigTrialStore
from private_fleet_client import PrivateFleetClient, MAX_FLEET_BYTES


_BLOCK = 1024


class ConfigStageError(Exception):
    """Redacted fail-closed staging error."""


class AppliedConfigInvalid(ConfigStageError):
    """The retained applied configuration cannot be trusted."""


class ConfigStageCoordinator:
    def __init__(self, store, private_client, payload_directory, device_ref,
                 random_bytes, service=None):
        if not isinstance(store, ConfigTrialStore) or store.state is None:
            raise ValueError('loaded configuration store required')
        if not isinstance(private_client, PrivateFleetClient):
            raise ValueError('private fleet capability required')
        self.payload_directory = _trusted_directory(payload_directory)
        stage_directory = getattr(private_client, 'stage_directory', None)
        if not isinstance(stage_directory, str) or not stage_directory:
            raise ValueError('private stage directory required')
        stage_directory = _trusted_directory(stage_directory)
        if stage_directory == self.payload_directory:
            raise ValueError('private stage and payload directories must differ')
        if not callable(random_bytes):
            raise ValueError('random source required')
        if device_ref != store.state.get('device_ref'):
            raise ValueError('immutable device reference mismatch')
        self.store = store
        self.private_client = private_client
        self.stage_directory = stage_directory
        self.device_ref = device_ref
        self.random_bytes = random_bytes
        self.service = service

    def stage_latest(self):
        """Return a verified staged reference, or None for an unchanged change ID."""
        state = self.store.state
        if (not isinstance(state, dict)
                or state.get('status') in ('received', 'staged', 'trial')):
            raise ConfigStageError('Configuration transaction is not available.') from None
        reserved = False
        scratch_path = None
        cleanup_ok = True
        reference = None
        unchanged = False
        owned_basename = None
        owned_path = None
        stage_handoff = False
        owned_cleanup_ok = True
        try:
            self._verify_applied()
            result = self.private_client.fetch_to_stage(service=self.service)
            if (not isinstance(result, tuple) or len(result) != 2
                    or not isinstance(result[0], str)):
                raise ConfigStageError('Unable to stage configuration.')
            returned_path, claimed = result
            applied_name = self.store.state['applied'][0]
            _valid_basename(applied_name)
            applied_path = self.payload_directory.rstrip('/') + '/' + applied_name
            if returned_path == applied_path:
                raise ConfigStageError('Invalid downloaded configuration path.')
            _require_direct_child(self.stage_directory, returned_path)
            # Only a path validated against the fixed, trusted stage directory
            # may reach finally, where it can be removed.
            scratch_path = returned_path
            count, digest = _verify_file(scratch_path, MAX_FLEET_BYTES)
            if (not isinstance(claimed, tuple) or len(claimed) != 2
                    or type(claimed[0]) is not int or claimed[0] != count
                    or not _valid_digest(claimed[1]) or claimed[1] != digest):
                raise ConfigStageError('Unable to verify downloaded configuration.')
            with open(scratch_path, 'rb') as source:
                payload, revision, change_id = extract_device_payload(
                    source, self.device_ref, service=self.service)
            if change_id == self.store.state['applied_change_id']:
                unchanged = True
            else:
                self.store.begin_received(revision, change_id)
                reserved = True
                basename, byte_count, sha256 = write_owned_payload(
                    self.payload_directory, payload, self.random_bytes)
                owned_basename = basename
                # Reopen the owned file and independently verify its exact bytes
                # and identity before handing the reference to durable metadata.
                owned_path = self.payload_directory.rstrip('/') + '/' + basename
                owned_count, owned_digest = _verify_file(owned_path, 16384)
                with open(owned_path, 'rb') as owned:
                    owned_bytes = _read_bounded(owned, 16384)
                parsed = read_device_payload(owned_bytes, self.device_ref)
                if (owned_count != byte_count or owned_digest != sha256
                        or parsed.revision != revision
                        or parsed.device.change_id != change_id):
                    raise ConfigStageError('Unable to verify stored configuration.')
                stage_handoff = True
                self.store.stage_candidate(basename, owned_count, owned_digest, verified=True)
                reference = list(self.store.state['candidate'])
        except ConfigStageError:
            if not stage_handoff:
                self._reject_reserved(reserved)
            raise
        except Exception:
            if not stage_handoff:
                self._reject_reserved(reserved)
            raise ConfigStageError('Unable to stage configuration.') from None
        finally:
            if owned_path is not None and not stage_handoff:
                try:
                    self._remove_unreferenced_owned_payload(owned_basename, owned_path)
                except Exception:
                    owned_cleanup_ok = False
            if scratch_path is not None:
                try:
                    os.remove(scratch_path)
                except Exception:
                    cleanup_ok = False
            if not cleanup_ok and not stage_handoff:
                self._reject_reserved(reserved)
            if not owned_cleanup_ok and not stage_handoff:
                self._reject_reserved(reserved)
            if not owned_cleanup_ok:
                raise ConfigStageError('Unable to clean stored configuration.') from None
        if not cleanup_ok:
            raise ConfigStageError('Unable to clean downloaded configuration.') from None
        return None if unchanged else reference

    def _verify_applied(self):
        try:
            reference = self.store.state['applied']
            basename = reference[0]
            _valid_basename(basename)
            path = self.payload_directory.rstrip('/') + '/' + basename
            count, digest = _verify_file(path, 16384)
            if count != reference[1] or digest != reference[2]:
                raise ValueError('applied bytes do not match reference')
            with open(path, 'rb') as handle:
                payload = _read_bounded(handle, 16384)
            parsed = read_device_payload(payload, self.device_ref)
            if (parsed.revision != self.store.state['applied_revision']
                    or parsed.device.change_id != self.store.state['applied_change_id']):
                raise ValueError('applied identity does not match metadata')
        except Exception:
            raise AppliedConfigInvalid(
                'Applied configuration requires recovery.') from None

    def _remove_unreferenced_owned_payload(self, basename, path):
        _valid_basename(basename)
        _require_direct_child(self.payload_directory, path)
        if path != self.payload_directory.rstrip('/') + '/' + basename:
            raise ConfigStageError('Unable to clean stored configuration.')
        state = self.store.state
        if not isinstance(state, dict):
            raise ConfigStageError('Unable to clean stored configuration.')
        for key in ('applied', 'candidate'):
            reference = state.get(key)
            if isinstance(reference, (list, tuple)) and reference and reference[0] == basename:
                raise ConfigStageError('Unable to clean stored configuration.')
        # Keep the deletion check compatible with MicroPython, which has no
        # os.path and whose trusted LittleFS root cannot contain symlinks.
        # Where lstat exists, reject symlinks and every non-regular file.
        lstat = getattr(os, 'lstat', None)
        if callable(lstat):
            mode = lstat(path)[0]
            if not isinstance(mode, int) or mode & 0xF000 != 0x8000:
                raise ConfigStageError('Unable to clean stored configuration.')
        os.remove(path)

    def _reject_reserved(self, reserved):
        if reserved and self.store.state is not None:
            try:
                if self.store.state.get('status') in ('received', 'staged'):
                    self.store.reject('storage_error')
            except Exception:
                pass


def _trusted_directory(directory):
    if (not isinstance(directory, str) or not directory.startswith('/')
            or '\x00' in directory):
        raise ValueError('invalid trusted payload directory')
    parts = directory.split('/')[1:]
    if any(part in ('', '.', '..') for part in parts):
        raise ValueError('invalid trusted payload directory')
    return directory.rstrip('/\\')


def _valid_basename(name):
    if (not isinstance(name, str) or not name or len(name) > 64
            or name.startswith('.') or name in ('.', '..')
            or any(char not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-'
                   for char in name)):
        raise ConfigStageError('Invalid payload reference.')


def _require_direct_child(directory, path):
    prefix = directory.rstrip('/') + '/'
    if not path.startswith(prefix):
        raise ConfigStageError('Invalid downloaded configuration path.')
    basename = path[len(prefix):]
    _valid_basename(basename)
    if '/' in basename or '\\' in basename:
        raise ConfigStageError('Invalid downloaded configuration path.')


def _valid_digest(value):
    return (isinstance(value, str) and len(value) == 64
            and all(char in '0123456789abcdef' for char in value))


def _verify_file(path, maximum):
    digest = hashlib.sha256()
    count = 0
    with open(path, 'rb') as handle:
        while True:
            block = handle.read(_BLOCK)
            if not block:
                break
            count += len(block)
            if count > maximum:
                raise ConfigStageError('Configuration exceeds size limit.')
            digest.update(block)
    return count, _hex(digest.digest())


def _read_bounded(handle, maximum):
    chunks = bytearray()
    while True:
        block = handle.read(_BLOCK)
        if not block:
            break
        if len(chunks) + len(block) > maximum:
            raise ConfigStageError('Configuration exceeds size limit.')
        chunks.extend(block)
    return bytes(chunks)


def _hex(value):
    digits = '0123456789abcdef'
    return ''.join(digits[byte >> 4] + digits[byte & 15] for byte in value)
