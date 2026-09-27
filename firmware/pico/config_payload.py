"""Device-only configuration payload extraction and owned-file persistence.

This module stages validated content only. It does not apply configuration or
select an active payload; callers retain ownership of deleting their exact
full-fleet staging path after successful extraction.
"""

import hashlib
import io
import os

from fleet_config import FleetConfigError, MAX_BYTES, _Reader, parse_fleet


# Worst-case compact JSON is below 12 KiB: the two 2048-byte printable
# credentials can each double (quote/backslash escaping, 8192 bytes total);
# three Wi-Fi profiles contribute at most 576 escaped SSID bytes and 1152
# escaped password bytes (six JSON bytes per source UTF-8 byte), plus under
# 1 KiB for all remaining bounded values, keys, punctuation and integers.
# 16 KiB is a conservative ceiling above that schema-derived bound.
MAX_PAYLOAD_BYTES = 16384
MAX_WRITE_BLOCK = 1024
MAX_FILENAME_ATTEMPTS = 8
_PAYLOAD_FIELDS = ('schema_version', 'fleet_revision', 'device_ref', 'device')
_HEX = '0123456789abcdef'


class ConfigPayloadError(ValueError):
    """Safe, redacted error from device-only payload processing."""


def extract_device_payload(full_fleet_stream, immutable_device_ref, service=None):
    """Validate a complete fleet stream and return compact addressed payload.

    The source must be a binary stream at its beginning. It is fully consumed
    by ``parse_fleet`` (including any malformed tail) before any bytes return.
    """
    try:
        config = parse_fleet(full_fleet_stream, immutable_device_ref, service)
        body = _fleet_configuration_dict(config, immutable_device_ref)
        encoded = _compact_json(body).encode('utf-8')
        if not encoded or len(encoded) > MAX_PAYLOAD_BYTES:
            raise ConfigPayloadError('Device configuration payload exceeds size limit.')
        return encoded, config.revision, config.device.change_id
    except ConfigPayloadError:
        raise
    except Exception:
        raise ConfigPayloadError('Unable to extract device configuration.') from None


def read_device_payload(payload_bytes, immutable_device_ref):
    """Strictly read and validate a device-only payload using fleet rules."""
    try:
        if not isinstance(payload_bytes, bytes) or not payload_bytes:
            raise ConfigPayloadError('Invalid device configuration payload.')
        if len(payload_bytes) > MAX_PAYLOAD_BYTES:
            raise ConfigPayloadError('Device configuration payload exceeds size limit.')
        reader = _Reader(io.BytesIO(payload_bytes), max_bytes=MAX_PAYLOAD_BYTES,
                         max_array=3)
        raw = reader.value()
        reader.space()
        if reader._byte() != -1:
            raise FleetConfigError('Malformed data after payload.')
        if not isinstance(raw, dict) or set(raw) != set(_PAYLOAD_FIELDS):
            raise FleetConfigError('Unknown or missing payload field.')
        if type(raw['schema_version']) is not int or raw['schema_version'] != 1:
            raise FleetConfigError('Unsupported payload schema.')
        if not isinstance(immutable_device_ref, str) or raw['device_ref'] != immutable_device_ref:
            raise FleetConfigError('Payload device reference mismatch.')
        if not isinstance(raw['device'], dict):
            raise FleetConfigError('Invalid addressed device.')
        fleet = {
            'schema_version': 1,
            'fleet_revision': raw['fleet_revision'],
            'devices': {immutable_device_ref: raw['device']},
        }
        encoded_fleet = _compact_json(fleet).encode('utf-8')
        if len(encoded_fleet) > MAX_BYTES:
            raise FleetConfigError('Fleet configuration exceeds size limit.')
        return parse_fleet(io.BytesIO(encoded_fleet), immutable_device_ref)
    except ConfigPayloadError:
        raise
    except Exception:
        raise ConfigPayloadError('Invalid device configuration payload.') from None


def write_owned_payload(directory, payload, random_bytes):
    """Exclusively create, verify and return an owned device-only payload file."""
    _validate_directory(directory)
    try:
        if not isinstance(payload, bytes) or not payload or len(payload) > MAX_PAYLOAD_BYTES:
            raise ConfigPayloadError('Invalid device configuration payload.')
        # Validate before creating a file, then verify again from durable bytes.
        parsed = _find_reference_free_payload(payload)
    except ConfigPayloadError:
        raise
    except Exception:
        raise ConfigPayloadError('Invalid device configuration payload.') from None

    created_path = None
    handle = None
    try:
        basename = None
        for unused in range(MAX_FILENAME_ATTEMPTS):
            entropy = random_bytes(12)
            if not isinstance(entropy, (bytes, bytearray)) or len(entropy) != 12:
                raise ConfigPayloadError('Unable to allocate payload file.')
            basename = 'config-' + _hex(bytes(entropy)) + '.json'
            candidate_path = directory.rstrip('/') + '/' + basename
            try:
                handle = open(candidate_path, 'xb')
                created_path = candidate_path
                break
            except OSError:
                handle = None
        if handle is None:
            raise ConfigPayloadError('Unable to allocate payload file.')

        digest = hashlib.sha256()
        for offset in range(0, len(payload), MAX_WRITE_BLOCK):
            block = payload[offset:offset + MAX_WRITE_BLOCK]
            written = handle.write(block)
            if written is not None and written != len(block):
                raise ConfigPayloadError('Unable to write payload file.')
            digest.update(block)
        expected_digest = _hex(digest.digest())
        handle.flush()
        handle.close()
        handle = None

        verify_digest = hashlib.sha256()
        reread = bytearray()
        with open(created_path, 'rb') as verify:
            while True:
                block = verify.read(MAX_WRITE_BLOCK)
                if not block:
                    break
                if len(reread) + len(block) > MAX_PAYLOAD_BYTES:
                    raise ConfigPayloadError('Payload file size mismatch.')
                reread.extend(block)
                verify_digest.update(block)
        actual_digest = _hex(verify_digest.digest())
        if len(reread) != len(payload) or actual_digest != expected_digest:
            raise ConfigPayloadError('Payload file verification failed.')
        verified = read_device_payload(bytes(reread), parsed[0])
        if verified != parsed[1]:
            raise ConfigPayloadError('Payload file verification failed.')
        return basename, len(payload), actual_digest
    except ConfigPayloadError:
        _close_and_remove(handle, created_path)
        raise
    except Exception:
        _close_and_remove(handle, created_path)
        raise ConfigPayloadError('Unable to persist device configuration payload.') from None


def _fleet_configuration_dict(config, device_ref):
    device = config.device
    profiles = []
    for profile in device.wifi_profiles:
        profiles.append({'profile_id': profile.profile_id, 'ssid': profile.ssid,
                         'password': profile.password})
    return {
        'schema_version': 1,
        'fleet_revision': config.revision,
        'device_ref': device_ref,
        'device': {
            'change_id': device.change_id,
            'logical_id': device.logical_id,
            'wifi_profiles': profiles,
            'config_read_credential': device.config_read_credential,
            'temperature_gist_id': device.temperature_gist_id,
            'diagnostics_gist_id': device.diagnostics_gist_id,
            'gist_write_credential': device.gist_write_credential,
            'sample_interval_seconds': device.sample_interval_seconds,
            'publication_interval_seconds': device.publication_interval_seconds,
        },
    }


def _find_reference_free_payload(payload):
    """Parse strict wrapper fields while discovering the immutable reference."""
    reader = _Reader(io.BytesIO(payload), max_bytes=MAX_PAYLOAD_BYTES, max_array=3)
    raw = reader.value()
    reader.space()
    if reader._byte() != -1 or not isinstance(raw, dict) or set(raw) != set(_PAYLOAD_FIELDS):
        raise FleetConfigError('Invalid payload fields.')
    reference = raw['device_ref']
    parsed = read_device_payload(payload, reference)
    return reference, parsed


def _validate_directory(directory):
    if not isinstance(directory, str) or not directory.startswith('/') or '\x00' in directory:
        raise ConfigPayloadError('Invalid payload directory.')
    segments = directory.split('/')[1:]
    if any(segment in ('', '.', '..') for segment in segments):
        raise ConfigPayloadError('Invalid payload directory.')


def _close_and_remove(handle, path):
    if handle is not None:
        try:
            handle.close()
        except Exception:
            pass
    if path is not None:
        try:
            os.remove(path)
        except Exception:
            pass


def _hex(value):
    output = []
    for byte in value:
        output.append(_HEX[byte >> 4] + _HEX[byte & 15])
    return ''.join(output)


def _compact_json(value):
    """Small JSON encoder limited to the primitive values in our schema."""
    if isinstance(value, str):
        return _quote(value)
    if value is None:
        return 'null'
    if value is True:
        return 'true'
    if value is False:
        return 'false'
    if type(value) is int:
        return str(value)
    if isinstance(value, list):
        return '[' + ','.join(_compact_json(item) for item in value) + ']'
    if isinstance(value, dict):
        return '{' + ','.join(_quote(key) + ':' + _compact_json(item)
                              for key, item in value.items()) + '}'
    raise ConfigPayloadError('Unsupported payload value.')


def _quote(value):
    output = ['"']
    for char in value:
        code = ord(char)
        if char == '"':
            output.append('\\"')
        elif char == '\\':
            output.append('\\\\')
        elif code < 32:
            output.append('\\u00' + _HEX[code >> 4] + _HEX[code & 15])
        else:
            output.append(char)
    output.append('"')
    return ''.join(output)
