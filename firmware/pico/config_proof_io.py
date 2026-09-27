"""Explicit, candidate-bound I/O used only to prove configuration trials.

Importing this module performs no hardware, filesystem, or network operations.
"""

import hashlib
import os

from config_payload import (
    _compact_json,
    _fleet_configuration_dict,
    extract_device_payload,
    read_device_payload,
)
from fleet_config import FleetConfiguration
from gist_publisher import (
    DIAGNOSTICS_FILENAME,
    THERMOSTAT_FILENAME,
    GistPublishProofFailure,
    GistPublisher,
)
from gist_readback import GistReadbackFailure
from native_https import HttpFailure, NativeHttpsTransport
from private_fleet_client import MAX_FLEET_BYTES, PrivateFleetClient


class ConfigProofIOFailure(Exception):
    """Redacted proof-I/O failure, carrying only a stable classification."""

    def __init__(self, kind):
        if kind not in ('invalid_config', 'inconclusive', 'authentication_failed',
                        'destination_failed', 'definite'):
            kind = 'inconclusive'
        self.kind = kind
        super().__init__(kind)


class CandidateProofIO:
    """Candidate-only private configuration fetch and exact registered Gist I/O."""

    def __init__(self, candidate, immutable_device_ref, private_contents,
                 root_bytes, tls_module, select_module, socket_module, clock,
                 dns_server_ip, time_is_trusted, scratch_dir, random_bytes,
                 service=None, resolver=None, timeout_ms=15000):
        if not isinstance(candidate, FleetConfiguration):
            raise ValueError('verified candidate required')
        if (not isinstance(immutable_device_ref, str) or not immutable_device_ref or
                not callable(time_is_trusted) or not callable(random_bytes)):
            raise ValueError('device reference, trusted-time callback, and entropy required')
        # This roundtrip validates shape only. Durable verification/provenance
        # remains the caller's responsibility (normally ConfigTrialStore).
        try:
            candidate_bytes = _encode_candidate(candidate, immutable_device_ref)
            canonical = read_device_payload(candidate_bytes, immutable_device_ref)
        except Exception:
            raise ValueError('verified candidate required') from None
        if (not isinstance(private_contents, (tuple, list)) or len(private_contents) != 4 or
                any(not isinstance(value, str) for value in private_contents)):
            raise ValueError('fixed private Contents capability required')
        if not isinstance(scratch_dir, str) or not scratch_dir or '\x00' in scratch_dir:
            raise ValueError('trusted scratch directory required')

        self._candidate = canonical
        self._source_candidate = candidate
        self._canonical_payload = _encode_candidate(canonical, immutable_device_ref)
        self._device_ref = immutable_device_ref
        self._scratch_dir = _normalize_scratch(scratch_dir)
        self._service = service
        self._time_is_trusted = time_is_trusted
        self._closed = False

        device = canonical.device
        self._private_transport = None
        self._fleet_client = None
        self._publisher = None
        self._bound_trial = None
        self._capabilities_detached = False
        self._bound_stage_client = None
        self._bound_stage_transport = None
        self._bound_stage_scope = None
        self._bound_stage_scratch = None
        self._bound_candidate_client = None
        self._bound_candidate_transport = None
        self._proof_started = False
        try:
            self._private_transport = NativeHttpsTransport(
                (), device.config_read_credential, root_bytes, tls_module,
                select_module, socket_module, clock, dns_server_ip, resolver,
                timeout_ms, private_contents=tuple(private_contents))
            self._fleet_client = PrivateFleetClient(
                self._private_transport, self._scratch_dir, random_bytes,
                time_is_trusted=time_is_trusted)
            self._publisher = GistPublisher(
                device.temperature_gist_id, device.diagnostics_gist_id,
                device.gist_write_credential, root_bytes, tls_module,
                select_module, socket_module, clock, dns_server_ip,
                resolver=resolver, time_is_trusted=time_is_trusted,
                timeout_ms=timeout_ms, service=service)
        except Exception:
            for owner in (self._publisher, self._private_transport):
                try:
                    if owner is not None:
                        owner.close()
                except Exception:
                    pass
            raise ValueError('unable to initialize candidate proof I/O') from None

    def __repr__(self):
        return 'CandidateProofIO(<redacted>)'

    def read_exact_candidate(self, expected_candidate, service=None):
        """Fetch and validate the complete private fleet against the stored candidate."""
        self._proof_started = True
        if self._closed or self._capabilities_detached:
            raise ConfigProofIOFailure('inconclusive')
        if (not isinstance(expected_candidate, FleetConfiguration) or
                expected_candidate != self._candidate or
                not self._source_matches_snapshot()):
            raise ConfigProofIOFailure('invalid_config')
        self._require_trusted_time()
        if (expected_candidate != self._candidate or
                not self._source_matches_snapshot()):
            raise ConfigProofIOFailure('invalid_config')
        owned_path = None
        try:
            result = self._fleet_client.fetch_to_stage(
                service=self._service if service is None else service)
            if (expected_candidate != self._candidate or
                    not self._source_matches_snapshot()):
                raise ConfigProofIOFailure('invalid_config')
            if (not isinstance(result, (tuple, list)) or len(result) != 2 or
                    not isinstance(result[1], (tuple, list)) or len(result[1]) != 2):
                raise ConfigProofIOFailure('inconclusive')
            path, claimed = result
            claimed_count, claimed_digest = claimed
            if not _is_direct_child(path, self._scratch_dir):
                raise ConfigProofIOFailure('inconclusive')
            owned_path = path
            if (type(claimed_count) is not int or not 1 <= claimed_count <= MAX_FLEET_BYTES or
                    not isinstance(claimed_digest, str) or len(claimed_digest) != 64 or
                    any(char not in '0123456789abcdef' for char in claimed_digest)):
                raise ConfigProofIOFailure('inconclusive')
            digest = hashlib.sha256()
            byte_count = 0
            with open(path, 'rb') as source:
                while True:
                    block = source.read(min(1024, MAX_FLEET_BYTES + 1 - byte_count))
                    if not block:
                        break
                    if byte_count + len(block) > MAX_FLEET_BYTES:
                        raise ConfigProofIOFailure('inconclusive')
                    digest.update(block)
                    byte_count += len(block)
            if (byte_count != claimed_count or
                    _hex(digest.digest()) != claimed_digest):
                raise ConfigProofIOFailure('inconclusive')
            parser_service = _ServiceGuard(
                self._service if service is None else service)
            try:
                second_pass = _DigestingReader(open(path, 'rb'))
                try:
                    parsed = extract_device_payload(
                        second_pass, self._device_ref,
                        service=parser_service if parser_service.callback is not None else None)
                finally:
                    second_pass.close()
                reread = read_device_payload(parsed[0], self._device_ref)
            except Exception:
                if parser_service.stopped:
                    raise ConfigProofIOFailure('inconclusive') from None
                raise ConfigProofIOFailure('invalid_config') from None
            if (second_pass.byte_count != byte_count or
                    _hex(second_pass.digest.digest()) != claimed_digest):
                raise ConfigProofIOFailure('inconclusive')
            if (reread.revision != self._candidate.revision or
                    reread.device != self._candidate.device or
                    expected_candidate != self._candidate or
                    not self._source_matches_snapshot()):
                raise ConfigProofIOFailure('invalid_config')
            return reread
        except ConfigProofIOFailure as error:
            raise ConfigProofIOFailure(error.kind) from None
        except HttpFailure as error:
            raise ConfigProofIOFailure(_http_kind(error.status)) from None
        except Exception:
            raise ConfigProofIOFailure('inconclusive') from None
        finally:
            if owned_path is not None:
                try:
                    os.remove(owned_path)
                except Exception:
                    # Cleanup is part of the proof: never return a verified result
                    # if an owned private staging file remains behind.
                    raise ConfigProofIOFailure('inconclusive') from None

    def patch_exact(self, filename, content, service=None):
        self._proof_started = True
        if self._closed or self._capabilities_detached:
            raise ConfigProofIOFailure('inconclusive')
        if filename not in (THERMOSTAT_FILENAME, DIAGNOSTICS_FILENAME):
            raise ConfigProofIOFailure('definite')
        self._ensure_source_snapshot()
        self._require_trusted_time()
        self._ensure_source_snapshot()
        try:
            result = self._publisher.patch_exact_for_trial(
                filename, content,
                service=self._service if service is None else service)
            self._ensure_source_snapshot()
            return result
        except ConfigProofIOFailure as error:
            raise ConfigProofIOFailure(error.kind) from None
        except GistPublishProofFailure as error:
            raise ConfigProofIOFailure(error.kind) from None
        except Exception:
            raise ConfigProofIOFailure('inconclusive') from None

    def confirm_exact(self, filename, content, service=None):
        self._proof_started = True
        if self._closed or self._capabilities_detached:
            raise ConfigProofIOFailure('inconclusive')
        self._ensure_source_snapshot()
        self._require_trusted_time()
        self._ensure_source_snapshot()
        if filename == THERMOSTAT_FILENAME:
            gist_id = self._candidate.device.temperature_gist_id
        elif filename == DIAGNOSTICS_FILENAME:
            gist_id = self._candidate.device.diagnostics_gist_id
        else:
            raise ConfigProofIOFailure('definite')
        try:
            result = self._publisher.readback.confirm_file(
                gist_id, filename, content,
                service=self._service if service is None else service)
            self._ensure_source_snapshot()
            return result
        except ConfigProofIOFailure as error:
            raise ConfigProofIOFailure(error.kind) from None
        except GistReadbackFailure as error:
            raise ConfigProofIOFailure(error.kind) from None
        except Exception:
            raise ConfigProofIOFailure('inconclusive') from None

    def bind_trial(self, store, applied_config, stage_client):
        """Bind the candidate writer and the already-proved stage reader.

        The coordinator must independently verify the referenced files before
        calling this method; this is an in-process identity/consistency check.
        """
        from config_trial import ConfigTrialStore

        state = getattr(store, 'state', None)
        candidate_ref = state.get('candidate') if isinstance(state, dict) else None
        if (self._closed or self._capabilities_detached or self._proof_started or
                self._bound_trial is not None or
                not isinstance(stage_client, PrivateFleetClient) or
                stage_client is self._fleet_client or
                not isinstance(store, ConfigTrialStore) or state is None or
                state.get('status') != 'trial' or store.trial_started is None or
                type(store.sequence) is not int or store.sequence < 1 or
                not isinstance(candidate_ref, list) or len(candidate_ref) != 3 or
                not self._source_matches_snapshot() or
                state.get('revision') != self._candidate.revision or
                state.get('change_id') != self._candidate.device.change_id or
                state.get('device_ref') != self._device_ref or
                not isinstance(applied_config, FleetConfiguration) or
                applied_config.revision != state.get('applied_revision') or
                applied_config.device.change_id != state.get('applied_change_id') or
                applied_config.device.temperature_gist_id != self._candidate.device.temperature_gist_id or
                self._publisher.gist_ids != {
                    THERMOSTAT_FILENAME: self._candidate.device.temperature_gist_id,
                    DIAGNOSTICS_FILENAME: self._candidate.device.diagnostics_gist_id,
                }):
            raise ValueError('configuration trial binding rejected')
        candidate_transport = self._private_transport
        stage_transport = getattr(stage_client, 'transport', None)
        try:
            stage_scratch = _normalize_scratch(stage_client.stage_directory)
        except Exception:
            raise ValueError('configuration trial binding rejected') from None
        candidate_scope = getattr(candidate_transport, '_private_contents', None)
        stage_scope = getattr(stage_transport, '_private_contents', None)
        if (stage_transport is candidate_transport or
                self._fleet_client is None or
                getattr(self._fleet_client, 'transport', None) is not candidate_transport or
                stage_transport is not getattr(stage_client, 'transport', None) or
                not isinstance(stage_transport, NativeHttpsTransport) or
                candidate_transport._closed is not False or stage_transport._closed is not False or
                candidate_scope is None or stage_scope != candidate_scope or
                stage_scratch != self._scratch_dir or
                not isinstance(candidate_transport.token, bytearray) or
                not isinstance(stage_transport.token, bytearray) or
                candidate_transport.token is stage_transport.token):
            raise ValueError('configuration trial binding rejected')
        reference = tuple(candidate_ref)
        if len(reference[0]) == 0 or type(reference[1]) is not int or not isinstance(reference[2], str):
            raise ValueError('configuration trial binding rejected')
        self._bound_trial = (
            store, store.sequence, store.trial_started, reference,
            state.get('revision'), state.get('change_id'), state.get('device_ref'),
            state.get('applied_revision'), state.get('applied_change_id'),
            dict(self._publisher.gist_ids),
        )
        self._bound_stage_client = stage_client
        self._bound_stage_transport = stage_transport
        self._bound_stage_scope = tuple(stage_scope)
        self._bound_stage_scratch = stage_scratch
        self._bound_candidate_client = self._fleet_client
        self._bound_candidate_transport = candidate_transport

    def detach_after_commit(self, store):
        """Transfer the publisher and proved candidate reader after promotion."""
        bound = self._bound_trial
        if bound is None or self._closed or self._capabilities_detached:
            raise ValueError('proof I/O ownership transfer rejected')
        (bound_store, sequence, started, candidate_ref, revision, change_id,
         device_ref, applied_revision, applied_change_id, gist_ids) = bound
        state = getattr(store, 'state', None)
        publisher = self._publisher
        stage_client = self._bound_stage_client
        candidate_client = self._bound_candidate_client
        stage_transport = self._bound_stage_transport
        candidate_transport = self._bound_candidate_transport
        if (store is not bound_store or not self._source_matches_snapshot() or
                store.sequence != sequence + 1 or store.trial_started is not None or
                not isinstance(state, dict) or state.get('status') != 'applied' or
                state.get('candidate') is not None or state.get('applied') != list(candidate_ref) or
                state.get('applied_revision') != revision or
                state.get('applied_change_id') != change_id or
                state.get('revision') != revision or state.get('change_id') != change_id or
                state.get('device_ref') != device_ref or
                applied_revision is None or applied_change_id is None or
                started is None or getattr(publisher, '_closed', True) is not False or
                publisher.gist_ids != gist_ids or
                stage_client is None or stage_client is self._fleet_client or
                candidate_client is None or candidate_client is not self._fleet_client or
                stage_client is not self._bound_stage_client or
                getattr(stage_client, 'transport', None) is not stage_transport or
                self._fleet_client is not self._bound_candidate_client or
                self._private_transport is not candidate_transport or
                getattr(stage_transport, '_closed', True) is not False or
                getattr(candidate_transport, '_closed', True) is not False or
                getattr(stage_transport, '_private_contents', None) != self._bound_stage_scope or
                getattr(candidate_transport, '_private_contents', None) != self._bound_stage_scope or
                not isinstance(getattr(stage_client, 'stage_directory', None), str) or
                _safe_normalized_scratch(stage_client.stage_directory) != self._bound_stage_scratch or
                not isinstance(getattr(stage_transport, 'token', None), bytearray) or
                not isinstance(getattr(candidate_transport, 'token', None), bytearray) or
                stage_transport.token is candidate_transport.token):
            raise ValueError('proof I/O ownership transfer rejected')
        transferred = (publisher, candidate_client)
        self._capabilities_detached = True
        self._publisher = None
        self._bound_stage_client = None
        self._bound_stage_transport = None
        self._bound_candidate_client = None
        self._bound_candidate_transport = None
        self._private_transport = None
        self._fleet_client = None
        return transferred

    def close(self):
        if self._closed:
            return
        # Mark closed first so cleanup failures cannot make a second close touch
        # an owner whose cleanup may already have partially completed.
        self._closed = True
        if not self._capabilities_detached:
            try:
                if self._private_transport is not None:
                    self._private_transport.close()
            except Exception:
                pass
            finally:
                token = getattr(self._private_transport, 'token', None)
                if isinstance(token, bytearray):
                    for index in range(len(token)):
                        token[index] = 0
            try:
                if self._publisher is not None:
                    self._publisher.close()
            except Exception:
                pass
            finally:
                token = getattr(self._publisher, '_token', None)
                if isinstance(token, bytearray):
                    for index in range(len(token)):
                        token[index] = 0

    def _require_trusted_time(self):
        try:
            trusted = self._time_is_trusted()
        except Exception:
            raise ConfigProofIOFailure('inconclusive') from None
        if trusted is not True:
            raise ConfigProofIOFailure('inconclusive')

    def _source_matches_snapshot(self):
        try:
            return _encode_candidate(self._source_candidate, self._device_ref) == self._canonical_payload
        except Exception:
            return False

    def _ensure_source_snapshot(self):
        if not self._source_matches_snapshot():
            raise ConfigProofIOFailure('invalid_config')


class _DigestingReader:
    def __init__(self, stream):
        self._stream = stream
        self.byte_count = 0
        self.digest = hashlib.sha256()

    def read(self, size=-1):
        block = self._stream.read(size)
        if block:
            self.byte_count += len(block)
            self.digest.update(block)
        return block

    def close(self):
        self._stream.close()


class _ServiceGuard:
    def __init__(self, callback):
        self.callback = callback
        self.stopped = False

    def __call__(self, unused_count):
        try:
            result = self.callback()
        except Exception:
            self.stopped = True
            raise
        if result is False:
            self.stopped = True
        return result


def _normalize_scratch(directory):
    # The production Pico filesystem is POSIX. Drive paths are accepted for
    # host tests, without relying on host-specific normpath semantics.
    if directory.startswith('/'):
        if '\\' in directory:
            raise ValueError('invalid trusted scratch directory')
        result = directory.rstrip('/') or '/'
        segments = result.split('/')[1:]
    elif (len(directory) >= 3 and directory[0].isalpha() and
          directory[1:3] in (':/', ':\\')):
        result = directory.rstrip('/\\')
        segments = result[3:].replace('\\', '/').split('/')
    else:
        raise ValueError('invalid trusted scratch directory')
    if any(segment in ('', '.', '..') for segment in segments):
        raise ValueError('invalid trusted scratch directory')
    return result


def _safe_normalized_scratch(directory):
    try:
        return _normalize_scratch(directory)
    except Exception:
        return None


def _is_direct_child(path, directory):
    if not isinstance(path, str) or not path or '\x00' in path:
        return False
    if directory.startswith('/'):
        prefix = directory.rstrip('/') + '/'
        if not path.startswith(prefix):
            return False
        name = path[len(prefix):]
        return bool(name) and '/' not in name and '\\' not in name and name not in ('.', '..')
    # PrivateFleetClient builds paths with '/', even on host Windows paths.
    # Accept either single separator after the trusted directory, never both.
    base = directory.rstrip('/\\')
    if path.startswith(base + '/'):
        name = path[len(base) + 1:]
    elif path.startswith(base + '\\'):
        name = path[len(base) + 1:]
    else:
        return False
    return bool(name) and '/' not in name and '\\' not in name and name not in ('.', '..')


def _http_kind(status):
    if status == 401:
        return 'authentication_failed'
    if status == 404:
        return 'destination_failed'
    return 'inconclusive'


def _hex(value):
    alphabet = '0123456789abcdef'
    return ''.join(alphabet[byte >> 4] + alphabet[byte & 15] for byte in value)


def _encode_candidate(candidate, device_ref):
    """Serialize only for schema revalidation; credentials never enter errors/repr."""
    return _compact_json(_fleet_configuration_dict(candidate, device_ref)).encode('utf-8')
