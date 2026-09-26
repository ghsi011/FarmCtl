"""Fail-closed URL policy for public Pico release assets.

This module only constructs/checks URL components. It is not a TLS client or
downloader: callers must verify HTTPS certificates and the signed manifest and
asset hashes independently. The fixed redirect-host allowlist deliberately
trades availability for safety; a future transport must reject any further
redirect after this one.
"""

_HOST = b'release-assets.githubusercontent.com'
_RELEASE_ID_MAX = 10 ** 20 - 1
_HEX = b'0123456789abcdefABCDEF'
_UNRESERVED = b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~'


def _fail():
    # Keep failures generic: never include untrusted URL/query bytes.
    raise ValueError('invalid public release path')


def _safe_component(value, allow_dot):
    if not isinstance(value, str) or not value or len(value) > 100:
        _fail()
    for char in value:
        valid = ('A' <= char <= 'Z' or 'a' <= char <= 'z' or
                 '0' <= char <= '9' or char in '-_')
        if allow_dot and char == '.':
            valid = True
        if not valid:
            _fail()
    if value in ('.', '..'):
        _fail()
    return value


def release_asset_name(target_path):
    """Map a signed flat target to its unique GitHub release asset filename.

    ``lib/<module>.mpy`` is published as the flat basename. It may not collide
    with the application asset. Callers must also reject duplicate names across
    the complete signed target list.
    """
    if target_path in ('manifest.json', 'manifest.sig', 'app.mpy'):
        return target_path
    if not isinstance(target_path, str) or not target_path.startswith('lib/'):
        _fail()
    filename = target_path[4:]
    if (not filename.endswith('.mpy') or '/' in filename or '\\' in filename or
            len(filename) <= 4 or len(filename) > 64):
        _fail()
    stem = filename[:-4]
    if stem in ('.', '..', 'app'):
        _fail()
    for index, char in enumerate(stem):
        alpha = 'A' <= char <= 'Z' or 'a' <= char <= 'z' or char == '_'
        digit = '0' <= char <= '9'
        if not ((alpha or digit) if index == 0 else
                (alpha or digit or char in '.-')):
            _fail()
    return filename


def _validate_asset_name(asset_name):
    if not isinstance(asset_name, str):
        _fail()
    if asset_name in ('manifest.json', 'manifest.sig', 'app.mpy'):
        return
    if '/' in asset_name or '\\' in asset_name:
        _fail()
    if release_asset_name('lib/' + asset_name) != asset_name:
        _fail()


def build_release_path(fixed_owner, fixed_repo, release_id, asset_name):
    """Return a fixed GitHub host and path for one public release asset."""
    owner = _safe_component(fixed_owner, False)
    repo = _safe_component(fixed_repo, True)
    if type(release_id) is not int or release_id <= 0 or release_id > _RELEASE_ID_MAX:
        _fail()
    _validate_asset_name(asset_name)
    tag = 'pico-' + str(release_id)
    return (b'github.com', ('/' + owner + '/' + repo + '/releases/download/' +
                            tag + '/' + asset_name).encode('ascii'))


def _valid_path(path):
    if not path or len(path) > 1024 or path[0:1] != b'/':
        return False
    if path.startswith(b'//') or path.endswith(b'/'):
        return False
    segment = bytearray()
    index = 1
    while index < len(path):
        byte = path[index]
        if byte == 47:
            if not segment or bytes(segment) in (b'.', b'..'):
                return False
            segment = bytearray()
            index += 1
            continue
        if byte == 37:
            if index + 2 >= len(path) or path[index + 1] not in _HEX or path[index + 2] not in _HEX:
                return False
            escaped = path[index + 1:index + 3].lower()
            # Prevent encoded path separators, backslashes, and dot segments.
            if escaped in (b'2f', b'5c', b'2e'):
                return False
            segment.extend(b'%')
            segment.extend(path[index + 1:index + 3])
            index += 3
            continue
        if byte not in _UNRESERVED:
            return False
        segment.append(byte)
        index += 1
    return bool(segment) and bytes(segment) not in (b'.', b'..')


def parse_release_redirect(location_bytes):
    """Validate one absolute redirect; return fixed host and exact request bytes."""
    if not isinstance(location_bytes, bytes):
        _fail()
    # ASCII-only and reject all controls, whitespace, and backslashes up front.
    for byte in location_bytes:
        if byte <= 32 or byte >= 127 or byte == 92 or byte == 35:
            _fail()
    prefix = b'https://'
    if not location_bytes.startswith(prefix):
        _fail()
    remainder = location_bytes[len(prefix):]
    slash = remainder.find(b'/')
    if slash < 0:
        _fail()
    authority = remainder[:slash]
    if authority != _HOST:
        _fail()
    path_query = remainder[slash:]
    question = path_query.find(b'?')
    if question <= 0 or path_query.find(b'?', question + 1) >= 0:
        _fail()
    path = path_query[:question]
    query = path_query[question + 1:]
    if not query or len(query) > 2048 or not _valid_path(path):
        _fail()
    index = 0
    while index < len(query):
        byte = query[index]
        if byte == 37:
            if index + 2 >= len(query) or query[index + 1] not in _HEX or query[index + 2] not in _HEX:
                _fail()
            index += 3
        else:
            # Opaque signed query: preserve bytes, but reject URL delimiters and
            # characters that could alter request framing.
            if byte in (34, 39, 60, 62):
                _fail()
            index += 1
    return _HOST, path + b'?' + query
