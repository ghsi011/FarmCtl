"""Host-only v1 Pico release manifest construction and verification."""

from __future__ import annotations

import hashlib
import json
import re
from typing import Mapping

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey


FORMAT_VERSION = 1
ALGORITHM = 'Ed25519'
BOARD = 'RPI_PICO2_W'
MAX_MANIFEST_BYTES = 2048
MAX_TARGETS = 8  # app.mpy plus at most seven flat library modules.
MAX_TARGET_NAME_LENGTH = 64
MAX_ASSET_BYTES = 512 * 1024
MAX_TOTAL_ASSET_BYTES = 1024 * 1024
MAX_RELEASE_ID = 10**20 - 1
_MANIFEST_FIELDS = {'algorithm', 'board', 'format_version', 'min_runtime', 'release_id', 'targets'}
_TARGET_FIELDS = {'name', 'path', 'size_bytes', 'sha256'}
_RUNTIME_PATTERN = re.compile(r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
_HASH_PATTERN = re.compile(r'^[0-9a-f]{64}$')


class ManifestError(ValueError):
    """Candidate is not a valid signed release for this verifier."""


def canonical_manifest_bytes(manifest: dict) -> bytes:
    """Serialize the v1 canonical representation (UTF-8, sorted, compact)."""
    data = json.dumps(manifest, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    if len(data) > MAX_MANIFEST_BYTES:
        raise ManifestError('manifest exceeds v1 byte limit')
    return data


def _runtime_version(value: object) -> tuple[int, int, int]:
    if not isinstance(value, str) or not (match := _RUNTIME_PATTERN.fullmatch(value)):
        raise ManifestError('invalid min_runtime')
    return tuple(int(part) for part in match.groups())


def _check_path(path: object) -> str:
    if not isinstance(path, str) or not path or len(path) > MAX_TARGET_NAME_LENGTH + 4:
        raise ManifestError('unsafe target path')
    # Only portable ASCII filenames are allowed. This excludes controls, NUL,
    # wildcard/special GitHub path characters, separators and dot-only names.
    if path == 'app.mpy':
        return path
    match = re.fullmatch(r'lib/([A-Za-z0-9_][A-Za-z0-9_.-]{0,59})\.mpy', path)
    if match is None or match.group(1) in ('.', '..'):
        raise ManifestError('target path is not allowlisted')
    if match.group(1) in ('manifest.json', 'manifest.sig'):
        raise ManifestError('reserved target path')
    return path


def _object_no_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError('duplicate JSON key')
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ManifestError(f'invalid JSON constant: {value}')


def _load_manifest(raw: bytes) -> dict:
    try:
        text = raw.decode('utf-8')
        value = json.loads(text, object_pairs_hook=_object_no_duplicate_keys, parse_constant=_reject_constant)
    except ManifestError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ManifestError('invalid UTF-8 JSON manifest') from exc
    if not isinstance(value, dict):
        raise ManifestError('manifest must be an object')
    return value


def _validate(manifest: dict, files: Mapping[str, bytes], tag_name: str,
              actual_board: str, runtime: str, applied_id: int | None,
              failed_id: int | None) -> dict[str, bytes]:
    if set(manifest) != _MANIFEST_FIELDS:
        raise ManifestError('manifest fields are missing or unknown')
    if manifest['format_version'] != FORMAT_VERSION or type(manifest['format_version']) is not int:
        raise ManifestError('unsupported manifest format_version')
    if manifest['algorithm'] != ALGORITHM:
        raise ManifestError('unsupported signature algorithm')
    if manifest['board'] != BOARD or actual_board != BOARD:
        raise ManifestError('wrong board')
    release_id = manifest['release_id']
    if type(release_id) is not int or release_id <= 0 or release_id > MAX_RELEASE_ID:
        raise ManifestError('release_id must be a positive integer of at most 20 digits')
    if tag_name != f'pico-{release_id}':
        raise ManifestError('tag does not match release_id')
    if applied_id is not None and (type(applied_id) is not int or applied_id < 0):
        raise ManifestError('invalid applied high-water mark')
    if failed_id is not None and (type(failed_id) is not int or failed_id < 0):
        raise ManifestError('invalid failed high-water mark')
    if applied_id is not None and release_id <= applied_id:
        raise ManifestError('release_id is not newer than applied high-water mark')
    if failed_id is not None and release_id <= failed_id:
        raise ManifestError('release_id is not newer than failed high-water mark')
    if _runtime_version(manifest['min_runtime']) > _runtime_version(runtime):
        raise ManifestError('runtime is below min_runtime')

    targets = manifest['targets']
    if not isinstance(targets, list) or not targets:
        raise ManifestError('targets must be a non-empty list')
    if len(targets) > MAX_TARGETS:
        raise ManifestError('too many targets')
    expected: dict[str, bytes] = {}
    names: set[str] = set()
    for target in targets:
        if not isinstance(target, dict) or set(target) != _TARGET_FIELDS:
            raise ManifestError('target fields are missing or unknown')
        path = _check_path(target['path'])
        name = target['name']
        if (not isinstance(name, str) or len(name) > MAX_TARGET_NAME_LENGTH
                or name in ('manifest.json', 'manifest.sig')
                or name != path.rsplit('/', 1)[-1]):
            raise ManifestError('invalid target name')
        if path in expected or name in names:
            raise ManifestError('duplicate target path or name')
        names.add(name)
        size = target['size_bytes']
        if type(size) is not int or size < 0:
            raise ManifestError('size_bytes must be a non-negative integer')
        digest = target['sha256']
        if not isinstance(digest, str) or not _HASH_PATTERN.fullmatch(digest):
            raise ManifestError('invalid sha256')
        if path not in files:
            raise ManifestError(f'missing asset: {path}')
        content = files[path]
        if not isinstance(content, bytes):
            raise ManifestError('asset content must be bytes')
        if len(content) > MAX_ASSET_BYTES:
            raise ManifestError('asset exceeds v1 per-file byte limit')
        if len(content) != size:
            raise ManifestError(f'asset size mismatch: {path}')
        if hashlib.sha256(content).hexdigest() != digest:
            raise ManifestError(f'asset hash mismatch: {path}')
        expected[path] = content
    if sum(map(len, expected.values())) > MAX_TOTAL_ASSET_BYTES:
        raise ManifestError('assets exceed v1 total byte limit')
    if 'app.mpy' not in expected:
        raise ManifestError('required app.mpy target missing')
    if set(files) != set(expected):
        raise ManifestError('candidate has missing or excess assets')
    return expected


def verify_candidate(manifest_bytes: bytes, signature: bytes, files: Mapping[str, bytes],
                     public_key_bytes: bytes, actual_board: str, runtime: str,
                     tag_name: str, applied_id: int | None = None,
                     failed_id: int | None = None) -> dict:
    """Verify detached Ed25519 first, then validate signed fields and exact assets.

    Public keys may be 32-byte raw Ed25519 or DER SubjectPublicKeyInfo.
    """
    from cryptography.hazmat.primitives import serialization

    if not isinstance(manifest_bytes, bytes) or len(manifest_bytes) > MAX_MANIFEST_BYTES:
        raise ManifestError('manifest exceeds v1 byte limit')
    try:
        if len(public_key_bytes) == 32:
            key = Ed25519PublicKey.from_public_bytes(public_key_bytes)
        else:
            key = serialization.load_der_public_key(public_key_bytes)
            if not isinstance(key, Ed25519PublicKey):
                raise ManifestError('public key is not Ed25519')
        key.verify(signature, manifest_bytes)
    except InvalidSignature as exc:
        raise ManifestError('manifest signature verification failed') from exc
    except (ValueError, TypeError) as exc:
        raise ManifestError('invalid public key or signature') from exc

    manifest = _load_manifest(manifest_bytes)
    _validate(manifest, files, tag_name, actual_board, runtime, applied_id, failed_id)
    return manifest


def build_candidate(release_id: int, min_runtime: str, files: Mapping[str, bytes],
                    private_key: Ed25519PrivateKey) -> tuple[bytes, bytes]:
    """Build canonical v1 manifest and detached signature using an Ed25519 key."""
    if type(release_id) is not int or release_id <= 0 or release_id > MAX_RELEASE_ID:
        raise ManifestError('release_id must be a positive integer of at most 20 digits')
    _runtime_version(min_runtime)
    targets = []
    normalized: set[str] = set()
    for path, content in sorted(files.items()):
        safe_path = _check_path(path)
        if safe_path in normalized:
            raise ManifestError('duplicate target path')
        if not isinstance(content, bytes):
            raise ManifestError('asset content must be bytes')
        normalized.add(safe_path)
        targets.append({
            'name': safe_path.rsplit('/', 1)[-1],
            'path': safe_path,
            'size_bytes': len(content),
            'sha256': hashlib.sha256(content).hexdigest(),
        })
    if 'app.mpy' not in normalized:
        raise ManifestError('required app.mpy target missing')
    manifest = {
        'algorithm': ALGORITHM,
        'board': BOARD,
        'format_version': FORMAT_VERSION,
        'min_runtime': min_runtime,
        'release_id': release_id,
        'targets': targets,
    }
    # Validate exactly the candidate shape accepted by the verifier before any
    # canonical serialization or private-key operation.
    _validate(manifest, files, f'pico-{release_id}', BOARD, min_runtime, None, None)
    data = canonical_manifest_bytes(manifest)
    return data, private_key.sign(data)
