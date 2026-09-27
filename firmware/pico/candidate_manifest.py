"""Bounded device-side admission for authenticated Pico release candidates.

The verifier callback is expected to perform Ed25519 verification using the
trusted raw public key. This module never writes assets or stores key material.
The signed ``min_runtime`` gate checks the official runtime version only; it
does not prove native ``.mpy`` build/ABI compatibility, which must be qualified
by the supervisor/release process where build metadata is available.
"""

import hashlib
from collections import namedtuple
from io import BytesIO

from fleet_config import _Reader, FleetConfigError

MAX_MANIFEST_BYTES = 2048
MAX_TARGETS = 8
MAX_ASSET_BYTES = 524288
MAX_TOTAL_ASSET_BYTES = 1048576
MAX_TARGET_NAME_LENGTH = 64
MAX_RELEASE_ID = 10 ** 20 - 1
BOARD = 'RPI_PICO2_W'
_ROOT_FIELDS = {'algorithm', 'board', 'format_version', 'min_runtime',
                'release_id', 'targets'}
_TARGET_FIELDS = {'name', 'path', 'size_bytes', 'sha256'}

CandidateError = type('CandidateError', (ValueError,), {})
AssetDescriptor = namedtuple('AssetDescriptor', 'name path size_bytes sha256')
Candidate = namedtuple('Candidate', 'release_id min_runtime targets')


def _fail():
    raise CandidateError('Invalid candidate manifest.') from None


def _hex_digest(value):
    """Convert digest bytes to lowercase hexadecimal without bytes.hex()."""
    digits = '0123456789abcdef'
    result = []
    for byte in value:
        result.append(digits[(byte >> 4) & 15])
        result.append(digits[byte & 15])
    return ''.join(result)


def _runtime(value):
    if not isinstance(value, str) or not value or value[0] != 'v':
        _fail()
    parts = value[1:].split('.')
    if len(parts) != 3:
        _fail()
    result = []
    for part in parts:
        if not part or (len(part) > 1 and part[0] == '0'):
            _fail()
        number = 0
        for char in part:
            if char < '0' or char > '9':
                _fail()
            number = number * 10 + ord(char) - 48
        result.append(number)
    return tuple(result)


def _path(value):
    if not isinstance(value, str) or len(value) > MAX_TARGET_NAME_LENGTH + 4:
        _fail()
    if value == 'app.mpy':
        return value
    prefix = 'lib/'
    suffix = '.mpy'
    if not value.startswith(prefix) or not value.endswith(suffix):
        _fail()
    base = value[len(prefix):-len(suffix)]
    if not base or len(base) > 60 or base in ('.', '..'):
        _fail()
    for index, char in enumerate(base):
        alpha = ('A' <= char <= 'Z') or ('a' <= char <= 'z') or char == '_'
        digit = '0' <= char <= '9'
        digit_or_other = alpha or digit or char in '.-'
        if (index == 0 and not (alpha or digit)) or not digit_or_other:
            _fail()
    if base in ('manifest.json', 'manifest.sig'):
        _fail()
    return value


def _parse(raw):
    try:
        reader = _Reader(BytesIO(raw), max_bytes=MAX_MANIFEST_BYTES,
                         max_array=MAX_TARGETS)
        value = reader.value()
        reader.space()
        if reader._byte() != -1:
            _fail()
        if not isinstance(value, dict):
            _fail()
        return value
    except CandidateError:
        raise
    except Exception:
        _fail()


def verify_candidate(manifest_bytes, signature, public_key, actual_board,
                     runtime, tag_name, applied_id=None, failed_id=None,
                     verifier=None):
    """Authenticate exact manifest bytes, then return immutable descriptors.

    ``verifier(signature, raw_public_key, message)`` must raise or return false
    when signature verification fails. It is deliberately called before JSON
    parsing and before any signed metadata is inspected.
    """
    try:
        if (not isinstance(manifest_bytes, bytes) or
                len(manifest_bytes) > MAX_MANIFEST_BYTES or
                not isinstance(signature, bytes) or len(signature) != 64 or
                not isinstance(public_key, bytes) or len(public_key) != 32 or
                verifier is None):
            _fail()
        try:
            verified = verifier(signature, public_key, manifest_bytes)
        except Exception:
            _fail()
        if verified is not True:
            _fail()

        manifest = _parse(manifest_bytes)
        if set(manifest) != _ROOT_FIELDS:
            _fail()
        if type(manifest['format_version']) is not int or manifest['format_version'] != 1:
            _fail()
        if manifest['algorithm'] != 'Ed25519':
            _fail()
        if manifest['board'] != BOARD or actual_board != BOARD:
            _fail()
        release_id = manifest['release_id']
        if type(release_id) is not int or release_id <= 0 or release_id > MAX_RELEASE_ID:
            _fail()
        if tag_name != 'pico-' + str(release_id):
            _fail()
        for high_water in (applied_id, failed_id):
            if high_water is not None and (type(high_water) is not int or high_water < 0):
                _fail()
            if high_water is not None and release_id <= high_water:
                _fail()
        minimum = _runtime(manifest['min_runtime'])
        if minimum > _runtime(runtime):
            _fail()

        targets = manifest['targets']
        if not isinstance(targets, list) or not targets or len(targets) > MAX_TARGETS:
            _fail()
        descriptors = []
        paths, names = set(), set()
        total = 0
        for target in targets:
            if not isinstance(target, dict) or set(target) != _TARGET_FIELDS:
                _fail()
            path = _path(target['path'])
            name = target['name']
            basename = path.split('/')[-1]
            if (not isinstance(name, str) or len(name) > MAX_TARGET_NAME_LENGTH or
                    name in ('manifest.json', 'manifest.sig') or name != basename):
                _fail()
            if path in paths or name in names:
                _fail()
            size = target['size_bytes']
            if type(size) is not int or size < 0 or size > MAX_ASSET_BYTES:
                _fail()
            digest = target['sha256']
            if not isinstance(digest, str) or len(digest) != 64:
                _fail()
            for char in digest:
                if char not in '0123456789abcdef':
                    _fail()
            paths.add(path)
            names.add(name)
            total += size
            if total > MAX_TOTAL_ASSET_BYTES:
                _fail()
            descriptors.append(AssetDescriptor(name, path, size, digest))
        if 'app.mpy' not in paths:
            _fail()
        return Candidate(release_id, manifest['min_runtime'], tuple(descriptors))
    except CandidateError:
        raise
    except Exception:
        _fail()


def verify_staged_assets(candidate, stage_dir, service=None):
    """Stream staged files through an isolated accessor and verify exact bytes.

    ``candidate`` must be the object returned by ``verify_candidate``. The
    Candidate type itself is not proof of authentication: the supervisor must
    call ``verify_candidate`` directly and pass its returned object here.
    ``stage_dir`` must provide ``open_asset(relative_path)`` and ``list_assets()``.
    The supervisor owns directory/symlink isolation; this
    function only passes paths that satisfy the signed-format allowlist.
    Reads are capped at 1024 bytes and no asset is retained in memory.
    """
    try:
        if not isinstance(candidate, Candidate):
            _fail()
        descriptors = candidate.targets
        opener = getattr(stage_dir, 'open_asset', None)
        listing = getattr(stage_dir, 'list_assets', None)
        if not callable(opener) or not callable(listing):
            _fail()
        expected = set()
        normalized = []
        total = 0
        for descriptor in descriptors:
            path = _path(descriptor.path)
            if path != descriptor.path or descriptor.name != path.split('/')[-1]:
                _fail()
            if (type(descriptor.size_bytes) is not int or descriptor.size_bytes < 0 or
                    descriptor.size_bytes > MAX_ASSET_BYTES or
                    len(descriptor.sha256) != 64):
                _fail()
            if path in expected:
                _fail()
            expected.add(path)
            total += descriptor.size_bytes
            if total > MAX_TOTAL_ASSET_BYTES:
                _fail()
            normalized.append(descriptor)
        listed = listing()
        if set(listed) != expected:
            _fail()
        total_hashed_bytes = 0
        for descriptor in normalized:
            digest = hashlib.sha256()
            count = 0
            stream = opener(descriptor.path)
            try:
                while True:
                    block = stream.read(1024)
                    if not block:
                        break
                    if not isinstance(block, bytes) or len(block) > 1024:
                        _fail()
                    count += len(block)
                    total_hashed_bytes += len(block)
                    if count > descriptor.size_bytes:
                        _fail()
                    digest.update(block)
                    if service is not None and service(total_hashed_bytes) is False:
                        _fail()
            finally:
                close = getattr(stream, 'close', None)
                if callable(close):
                    close()
            if count != descriptor.size_bytes or _hex_digest(digest.digest()) != descriptor.sha256:
                _fail()
        return True
    except CandidateError:
        _fail()
    except Exception:
        _fail()
