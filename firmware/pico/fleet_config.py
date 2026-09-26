"""Bounded streaming reader for schema-v1 local fleet.json files.

Parsing returns a candidate only. It deliberately has no persistence or apply
side effects; callers must keep their last-known-good configuration separately.
"""

try:
    from collections import namedtuple
except ImportError:  # pragma: no cover - MicroPython normally has collections
    namedtuple = None

MAX_BYTES = 65536
CHUNK_SIZE = 1024
MAX_DEVICES = 16
MAX_PROFILES = 3
MAX_DEPTH = 8

WifiProfile = namedtuple('WifiProfile', 'profile_id ssid password')
DeviceConfiguration = namedtuple(
    'DeviceConfiguration',
    'change_id logical_id wifi_profiles config_read_credential '
    'temperature_gist_id diagnostics_gist_id gist_write_credential '
    'sample_interval_seconds publication_interval_seconds',
)
FleetConfiguration = namedtuple('FleetConfiguration', 'revision device')


class FleetConfigError(ValueError):
    """Safe, redacted parse error. Never includes source text or OS details."""


class _Reader:
    def __init__(self, stream, service=None):
        self.stream = stream
        self.service = service
        self.buf = b''
        self.pos = 0
        self.total = 0
        self.eof = False

    def _byte(self):
        if self.pos >= len(self.buf):
            if self.eof:
                return -1
            try:
                block = self.stream.read(CHUNK_SIZE)
            except Exception:
                raise FleetConfigError('Unable to read fleet configuration.')
            if isinstance(block, bytes) and block:
                self.total += len(block)
            if self.service is not None:
                self._service()
            if self.total > MAX_BYTES:
                raise FleetConfigError('Fleet configuration exceeds size limit.')
            if not block:
                self.eof = True
                self.buf = b''
                self.pos = 0
                return -1
            if not isinstance(block, bytes):
                raise FleetConfigError('Fleet configuration must be binary.')
            self.buf, self.pos = block, 0
        value = self.buf[self.pos]
        self.pos += 1
        if not isinstance(value, int):
            value = ord(value)
        return value

    def _service(self):
        try:
            if self.service(self.total) is False:
                raise FleetConfigError('Fleet configuration processing stopped.')
        except FleetConfigError:
            raise FleetConfigError('Fleet configuration processing stopped.')
        except Exception:
            raise FleetConfigError('Fleet configuration processing stopped.')

    def peek(self):
        if self.pos >= len(self.buf):
            value = self._byte()
            if value < 0:
                return -1
            self.pos -= 1
        value = self.buf[self.pos]
        return value if isinstance(value, int) else ord(value)

    def take(self, expected):
        value = self._byte()
        if value != expected:
            raise FleetConfigError('Malformed fleet configuration.')

    def space(self):
        while self.peek() in (9, 10, 13, 32):
            self._byte()

    def string(self):
        self.take(34)
        out = []
        raw = bytearray()
        length = 0

        def flush():
            nonlocal length
            if raw:
                try:
                    text = bytes(raw).decode('utf-8')
                except Exception:
                    raise FleetConfigError('Invalid UTF-8 in fleet configuration.')
                out.append(text)
                length += len(text)
                raw[:] = b''
                if length > 2048:
                    raise FleetConfigError('Fleet string exceeds size limit.')

        while True:
            byte = self._byte()
            if byte < 0:
                raise FleetConfigError('Malformed fleet configuration.')
            if byte == 34:
                flush()
                return ''.join(out)
            if byte < 32:
                raise FleetConfigError('Malformed fleet configuration.')
            if byte != 92:
                raw.append(byte)
                if len(raw) > 8192:
                    raise FleetConfigError('Fleet string exceeds size limit.')
                continue
            flush()
            escape = self._byte()
            simple = {34: '"', 92: '\\', 47: '/', 98: '\b', 102: '\f',
                      110: '\n', 114: '\r', 116: '\t'}
            if escape in simple:
                text = simple[escape]
            elif escape == 117:
                code = self._hex4()
                if 0xD800 <= code <= 0xDBFF:
                    if self._byte() != 92 or self._byte() != 117:
                        raise FleetConfigError('Malformed Unicode escape.')
                    low = self._hex4()
                    if not 0xDC00 <= low <= 0xDFFF:
                        raise FleetConfigError('Malformed Unicode escape.')
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                elif 0xDC00 <= code <= 0xDFFF:
                    raise FleetConfigError('Malformed Unicode escape.')
                text = chr(code)
            else:
                raise FleetConfigError('Malformed string escape.')
            length += len(text)
            if length > 2048:
                raise FleetConfigError('Fleet string exceeds size limit.')
            out.append(text)

    def _hex4(self):
        value = 0
        for unused in range(4):
            digit = self._byte()
            if 48 <= digit <= 57:
                digit -= 48
            elif 65 <= digit <= 70:
                digit -= 55
            elif 97 <= digit <= 102:
                digit -= 87
            else:
                raise FleetConfigError('Malformed Unicode escape.')
            value = value * 16 + digit
        return value

    def value(self, depth=0):
        self.space()
        if depth > MAX_DEPTH:
            raise FleetConfigError('Fleet configuration nesting limit exceeded.')
        ch = self.peek()
        if ch == 34:
            return self.string()
        if ch == 123:
            self._byte()
            result, keys = {}, set()
            self.space()
            if self.peek() == 125:
                self._byte()
                return result
            while True:
                self.space()
                if self.peek() != 34:
                    raise FleetConfigError('Malformed fleet configuration.')
                key = self.string()
                if key in keys:
                    raise FleetConfigError('Duplicate object key.')
                keys.add(key)
                if len(keys) > 9:
                    raise FleetConfigError('Object member limit exceeded.')
                self.space()
                self.take(58)
                result[key] = self.value(depth + 1)
                self.space()
                ch = self._byte()
                if ch == 125:
                    return result
                if ch != 44:
                    raise FleetConfigError('Malformed fleet configuration.')
        if ch == 91:
            self._byte()
            result = []
            self.space()
            if self.peek() == 93:
                self._byte()
                return result
            while True:
                result.append(self.value(depth + 1))
                if len(result) > MAX_PROFILES:
                    raise FleetConfigError('Array item limit exceeded.')
                self.space()
                ch = self._byte()
                if ch == 93:
                    return result
                if ch != 44:
                    raise FleetConfigError('Malformed fleet configuration.')
        if ch == 116:
            self._literal(b'true')
            return True
        if ch == 102:
            self._literal(b'false')
            return False
        if ch == 110:
            self._literal(b'null')
            return None
        if ch == 45 or 48 <= ch <= 57:
            return self._number()
        raise FleetConfigError('Malformed fleet configuration.')

    def _literal(self, literal):
        for byte in literal:
            self.take(byte)

    def _number(self):
        chars = []
        if self.peek() == 45:
            chars.append(chr(self._byte()))
        ch = self.peek()
        if ch == 48:
            chars.append(chr(self._byte()))
            if 48 <= self.peek() <= 57:
                raise FleetConfigError('Malformed number.')
        elif 49 <= ch <= 57:
            while 48 <= self.peek() <= 57:
                chars.append(chr(self._byte()))
        else:
            raise FleetConfigError('Malformed number.')
        if self.peek() in (46, 69, 101):
            raise FleetConfigError('Expected integer value.')
        try:
            return int(''.join(chars))
        except Exception:
            raise FleetConfigError('Malformed number.')


def parse_fleet(stream, device_ref, service=None):
    """Parse and validate the complete bounded binary stream for one ref.

    Only the addressed device is retained in the returned immutable candidate.
    The stream must be opened in binary mode and positioned at its beginning.
    If supplied, ``service`` is called with cumulative bytes read at start, after
    each stream read, and after successful parsing. Returning exactly ``False``
    or raising stops parsing with a redacted error.
    """
    try:
        if service is not None:
            try:
                if service(0) is False:
                    raise FleetConfigError('Fleet configuration processing stopped.')
            except Exception:
                raise FleetConfigError('Fleet configuration processing stopped.')
        parser = _Parser(stream, device_ref, service)
        candidate = parser.parse()
        if service is not None:
            try:
                if service(parser.reader.total) is False:
                    raise FleetConfigError('Fleet configuration processing stopped.')
            except Exception:
                raise FleetConfigError('Fleet configuration processing stopped.')
        return candidate
    except FleetConfigError:
        raise
    except Exception:
        # Deliberately do not chain filesystem/decoder details that can disclose data.
        raise FleetConfigError('Invalid fleet configuration.')


class _Parser:
    def __init__(self, stream, target, service=None):
        self.reader = _Reader(stream, service)
        self.target = target

    def parse(self):
        r = self.reader
        r.space()
        r.take(123)
        root_keys = set()
        schema = revision = target_config = None
        got_devices = False
        while True:
            r.space()
            if r.peek() == 125:
                r._byte()
                break
            key = r.string()
            if key in root_keys:
                raise FleetConfigError('Duplicate object key.')
            root_keys.add(key)
            r.space(); r.take(58); r.space()
            if key == 'schema_version':
                schema = r.value(1)
            elif key == 'fleet_revision':
                revision = r.value(1)
            elif key == 'devices':
                got_devices = True
                target_config = self._devices()
            else:
                # Parse before reporting the unknown field to validate syntax/EOF.
                r.value(1)
                raise FleetConfigError('Unknown fleet field.')
            r.space()
            ch = r._byte()
            if ch == 125:
                break
            if ch != 44:
                raise FleetConfigError('Malformed fleet configuration.')
        r.space()
        if r._byte() != -1:
            raise FleetConfigError('Malformed data after fleet configuration.')
        if root_keys != {'schema_version', 'fleet_revision', 'devices'}:
            raise FleetConfigError('Required fleet field missing.')
        if type(schema) is not int or schema != 1:
            raise FleetConfigError('Unsupported fleet schema.')
        _uuid(revision, 'fleet_revision')
        if not got_devices or target_config is None:
            raise FleetConfigError('Addressed device is absent.')
        return FleetConfiguration(revision, target_config)

    def _devices(self):
        r = self.reader
        r.take(123)
        refs, logical_ids = set(), set()
        target = None
        count = 0
        r.space()
        if r.peek() == 125:
            r._byte()
            raise FleetConfigError('Invalid device count.')
        while True:
            r.space()
            ref = r.string()
            if ref in refs:
                raise FleetConfigError('Duplicate object key.')
            refs.add(ref); count += 1
            if count > MAX_DEVICES:
                raise FleetConfigError('Invalid device count.')
            if not _matches(ref, 1, 256) or not _chars(ref, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-'):
                raise FleetConfigError('Invalid device reference.')
            r.space(); r.take(58)
            raw = r.value(2)
            config = _device(raw)
            if config.logical_id in logical_ids:
                raise FleetConfigError('Duplicate logical ID.')
            logical_ids.add(config.logical_id)
            if ref == self.target:
                target = config
            r.space()
            ch = r._byte()
            if ch == 125:
                return target
            if ch != 44:
                raise FleetConfigError('Malformed fleet configuration.')


def _device(raw):
    keys = {'change_id', 'logical_id', 'wifi_profiles', 'config_read_credential',
            'temperature_gist_id', 'diagnostics_gist_id', 'gist_write_credential',
            'sample_interval_seconds', 'publication_interval_seconds'}
    _fields(raw, keys)
    logical = _string(raw['logical_id'], 1, 64)
    if not _chars(logical, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-'):
        raise FleetConfigError('Invalid logical ID.')
    profiles = raw['wifi_profiles']
    if not isinstance(profiles, list) or not 1 <= len(profiles) <= MAX_PROFILES:
        raise FleetConfigError('Invalid Wi-Fi profiles.')
    profile_ids, parsed = set(), []
    for profile in profiles:
        _fields(profile, {'profile_id', 'ssid', 'password'})
        profile_id = _string(profile['profile_id'], 1, 32)
        if not _chars(profile_id, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-') or profile_id in profile_ids:
            raise FleetConfigError('Invalid or duplicate Wi-Fi profile ID.')
        profile_ids.add(profile_id)
        ssid = _string(profile['ssid'], 1, 32)
        if len(ssid.encode('utf-8')) > 32:
            raise FleetConfigError('Invalid SSID.')
        password = _string(profile['password'], 1, 64)
        encoded = password.encode('utf-8')
        if not (8 <= len(encoded) <= 63 or
                (len(encoded) == 64 and all(c in '0123456789abcdefABCDEF' for c in password))):
            raise FleetConfigError('Invalid Wi-Fi password.')
        parsed.append(WifiProfile(profile_id, ssid, password))
    sample = _integer(raw['sample_interval_seconds'])
    publication = _integer(raw['publication_interval_seconds'])
    if not (10 <= sample <= 300 and 60 <= publication <= 300 and sample <= publication):
        raise FleetConfigError('Invalid sampling intervals.')
    read_credential = _credential(raw['config_read_credential'])
    write_credential = _credential(raw['gist_write_credential'])
    return DeviceConfiguration(
        _uuid(raw['change_id'], 'change_id'), logical, tuple(parsed),
        read_credential, _gist(raw['temperature_gist_id']),
        _gist(raw['diagnostics_gist_id']), write_credential, sample, publication)


def _fields(value, expected):
    if not isinstance(value, dict):
        raise FleetConfigError('Invalid object.')
    if set(value) != expected:
        raise FleetConfigError('Unknown or missing field.')


def _string(value, minimum, maximum):
    if not isinstance(value, str) or not minimum <= len(value) <= maximum:
        raise FleetConfigError('Invalid string field.')
    return value


def _integer(value):
    if type(value) is not int:
        raise FleetConfigError('Expected integer value.')
    return value


def _credential(value):
    value = _string(value, 1, 2048)
    if any(ord(c) < 33 or ord(c) > 126 for c in value):
        raise FleetConfigError('Invalid credential.')
    return value


def _uuid(value, field):
    value = _string(value, 36, 36)
    parts = value.split('-')
    if (list(map(len, parts)) != [8, 4, 4, 4, 12] or
            any(c not in '0123456789abcdefABCDEF' for c in ''.join(parts)) or
            value[14] not in '12345678' or value[19] not in '89abAB'):
        raise FleetConfigError('Invalid ' + field + '.')
    return value


def _gist(value):
    value = _string(value, 32, 40)
    if any(c not in '0123456789abcdefABCDEF' for c in value):
        raise FleetConfigError('Invalid Gist ID.')
    return value


def _matches(value, minimum, maximum):
    return minimum <= len(value) <= maximum


def _chars(value, allowed):
    return all(c in allowed for c in value)
