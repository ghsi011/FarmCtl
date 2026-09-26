"""Fixed-destination native TLS transport for GitHub Gist and Contents calls.

Production DNS uses a bounded UDP A resolver and a provisioned numeric DNS
server. Callers cannot choose the HTTPS host, HTTP method, or request path.
"""

import errno

from bounded_dns import resolve_ipv4

API_HOST = 'api.github.com'
MAX_HEADER_BYTES = 8192
MAX_REQUEST_BYTES = 32768
MAX_GIST_JSON_BYTES = 32768  # History metadata beyond this cap is unavailable to readback.
WRITE_CHUNK_BYTES = 512
REQUEST_TIMEOUT_MS = 15000
P_IN, P_OUT, P_ERR, P_HUP, P_NVAL = 1, 4, 8, 16, 32


class TransportFailure(Exception):
    """Safe transport failure with no network or credential detail."""


class HttpFailure(TransportFailure):
    def __init__(self, status, headers):
        self.status = status
        self.headers = headers


class NativeHttpsTransport:
    """Native TLS with either Gist-write or private Contents-read capability."""

    def __init__(self, gist_identifiers, token, root_bytes, tls_module,
                 select_module, socket_module, clock, dns_server_ip, resolver=None,
                 timeout_ms=REQUEST_TIMEOUT_MS, private_contents=None):
        if not isinstance(gist_identifiers, (tuple, list)):
            raise ValueError('invalid capabilities')
        if gist_identifiers and (
                any(not _is_hex_identifier(value) for value in gist_identifiers) or
                len(set(value.lower() for value in gist_identifiers)) != len(gist_identifiers)):
            raise ValueError('invalid Gist capabilities')
        if bool(gist_identifiers) == (private_contents is not None):
            raise ValueError('transport must have exactly one capability')
        if private_contents is not None:
            if (not isinstance(private_contents, (tuple, list)) or len(private_contents) != 4 or
                    not _valid_owner_repo(private_contents[0]) or
                    not _valid_owner_repo(private_contents[1]) or
                    not _valid_contents_path(private_contents[2]) or
                    not _valid_ref(private_contents[3])):
                raise ValueError('invalid private Contents capability')
        token_bytes = token.encode() if isinstance(token, str) else bytes(token)
        if not token_bytes or any(byte < 33 or byte > 126 for byte in token_bytes):
            raise ValueError('invalid token')
        if not isinstance(root_bytes, (bytes, bytearray)) or not root_bytes:
            raise ValueError('provisioned CA roots are required')
        if not _is_ipv4(dns_server_ip):
            raise ValueError('numeric DNS server address is required')
        self._gist_ids = tuple(value.lower() for value in gist_identifiers)
        self._private_contents = tuple(private_contents) if private_contents is not None else None
        self.token = token if isinstance(token, bytearray) else bytearray(token_bytes)
        self.root_bytes = root_bytes
        self.tls = tls_module
        self.select = select_module
        self.socket = socket_module
        self.clock = clock
        self.dns_server_ip = dns_server_ip
        # Optional resolver injection is for host fakes only. Production uses
        # the bounded UDP A resolver and never falls back to getaddrinfo.
        self.resolver = resolver
        self.timeout_ms = timeout_ms
        self._closed = False

    def close(self):
        _zero(self.token)
        self._closed = True

    def patch_gist(self, gist_identifier, body, service=None):
        """PATCH JSON bytes to a registered Gist; path and host are fixed here."""
        if self._closed or not _is_hex_identifier(gist_identifier):
            raise TransportFailure()
        if gist_identifier.lower() not in self._gist_ids:
            raise TransportFailure()
        if not isinstance(body, (bytes, bytearray)):
            raise TransportFailure()
        request = _build_request(gist_identifier.lower(), self.token, body)
        if len(request) > MAX_REQUEST_BYTES:
            _zero(request)
            raise TransportFailure()
        try:
            return self._request(request, service=service)
        finally:
            _zero(request)

    def get_private_contents(self, writer, service=None):
        """Stream the provisioned private file to writer after validating headers."""
        if self._closed or self._private_contents is None or not callable(writer):
            raise TransportFailure()
        request = _build_contents_request(self._private_contents, self.token)
        try:
            return self._request(request, writer=writer, service=service)
        finally:
            _zero(request)

    def get_gist_json(self, gist_identifier, writer, service=None):
        """Read bounded Gist API JSON for a registered Gist capability only."""
        if (self._closed or not _is_hex_identifier(gist_identifier) or
                gist_identifier.lower() not in self._gist_ids or not callable(writer)):
            raise TransportFailure()
        request = _build_gist_get_request(gist_identifier.lower(), self.token)
        try:
            return self._request(request, writer=writer, service=service,
                                 response_kind='gist-json')
        finally:
            _zero(request)

    def _request(self, request, writer=None, service=None, response_kind=None):
        start = self.clock.ticks_ms()
        raw_sock = tls_sock = None
        try:
            remaining = self._remaining(start)
            try:
                if self.resolver is None:
                    records = resolve_ipv4(
                        API_HOST, self.dns_server_ip, self.socket, self.select,
                        self.clock, service=service, deadline_ms=remaining)
                else:
                    records = self.resolver(
                        API_HOST, self.dns_server_ip, self.socket, self.select,
                        self.clock, service=service, deadline_ms=remaining)
            except Exception:
                raise TransportFailure()
            self._remaining(start)
            if not records:
                raise TransportFailure()
            address = records[0]
            raw_sock = self.socket.socket(address[0], address[1], address[2])
            raw_sock.setblocking(False)
            try:
                raw_sock.connect(address[-1])
            except OSError as error:
                if not _is_would_block(error):
                    raise
                self._wait_for(raw_sock, P_OUT, start, self.select.poll(), service)
            context = self.tls.SSLContext(self.tls.PROTOCOL_TLS_CLIENT)
            context.verify_mode = self.tls.CERT_REQUIRED
            context.load_verify_locations(self.root_bytes)
            tls_sock = context.wrap_socket(raw_sock, server_hostname=API_HOST,
                                           do_handshake_on_connect=False)
            tls_sock.setblocking(False)
            poller = self.select.poll()
            self._write_all(tls_sock, poller, request, start, service)
            return self._read_response(tls_sock, poller, start, writer, service,
                                       response_kind)
        finally:
            if tls_sock is not None:
                try:
                    tls_sock.close()
                except Exception:
                    pass
            if raw_sock is not None:
                try:
                    raw_sock.close()
                except Exception:
                    pass

    def _remaining(self, start):
        remaining = self.timeout_ms - _ticks_diff(self.clock, self.clock.ticks_ms(), start)
        if remaining <= 0:
            raise TransportFailure()
        return remaining

    def _wait_for(self, sock, events, start, poller, service=None):
        self._remaining(start)
        try:
            poller.modify(sock, events)
        except (AttributeError, OSError):
            try:
                poller.unregister(sock)
            except Exception:
                pass
            poller.register(sock, events)
        ready = poller.poll(min(250, self._remaining(start)))
        if service is not None:
            try:
                serviced = service()
            except Exception:
                raise TransportFailure()
            if serviced is False:
                raise TransportFailure()
            self._remaining(start)
        if not ready:
            self._remaining(start)
            return False
        for ready_sock, flags in ready:
            if ready_sock is not sock:
                continue
            if flags & P_NVAL or flags & P_ERR:
                raise TransportFailure()
            if flags & events:
                return True
            if flags & P_HUP:
                raise TransportFailure()
        return False

    def _write_all(self, sock, poller, data, start, service=None):
        offset = 0
        while offset < len(data):
            if not self._wait_for(sock, P_OUT, start, poller, service):
                continue
            chunk = data[offset:offset + WRITE_CHUNK_BYTES]
            try:
                try:
                    count = sock.write(chunk)
                except OSError as error:
                    if not _is_would_block(error):
                        raise
                    continue
            finally:
                _zero(chunk)
            if count is None:
                continue
            if count <= 0:
                raise TransportFailure()
            offset += count

    def _read_response(self, sock, poller, start, writer=None, service=None,
                       response_kind=None):
        header = bytearray()
        boundary = -1
        while boundary < 0:
            if not self._wait_for(sock, P_IN, start, poller, service):
                continue
            try:
                piece = sock.read(min(1024, MAX_HEADER_BYTES + 1 - len(header)))
            except OSError as error:
                if not _is_would_block(error):
                    raise
                continue
            self._remaining(start)
            if piece is None:
                continue
            if piece == b'':
                raise TransportFailure()
            header.extend(piece)
            boundary = header.find(b'\r\n\r\n')
            if ((boundary < 0 and len(header) > MAX_HEADER_BYTES) or
                    (boundary >= 0 and boundary + 4 > MAX_HEADER_BYTES)):
                raise TransportFailure()
        status, headers = _parse_headers(bytes(header[:boundary]))
        # PATCH acknowledgements intentionally do not drain potentially large
        # history bodies. Reads, in contrast, are bounded and fully consumed.
        if status != 200:
            raise HttpFailure(status, headers)
        if writer is not None:
            length = headers.get(b'content-length')
            content_type = headers.get(b'content-type', b'').split(b';', 1)[0].strip().lower()
            max_length = MAX_GIST_JSON_BYTES if response_kind == 'gist-json' else 65536
            allowed_types = ((b'application/json',) if response_kind == 'gist-json' else
                             (b'application/vnd.github.raw+json',
                              b'application/octet-stream', b'text/plain'))
            if (length is None or not length.isdigit() or len(length) > 5 or
                    not 1 <= int(length) <= max_length or
                    content_type not in allowed_types):
                raise TransportFailure()
            remaining = int(length)
            prefetched = bytes(header[boundary + 4:])
            if len(prefetched) > remaining:
                raise TransportFailure()
            if prefetched:
                writer(prefetched)
                self._remaining(start)
                remaining -= len(prefetched)
            while remaining:
                if not self._wait_for(sock, P_IN, start, poller, service):
                    continue
                try:
                    piece = sock.read(min(1024, remaining))
                except OSError as error:
                    if not _is_would_block(error):
                        raise
                    continue
                self._remaining(start)
                if piece is None:
                    continue
                if not piece or len(piece) > remaining:
                    raise TransportFailure()
                writer(piece)
                self._remaining(start)
                remaining -= len(piece)
        self._remaining(start)
        return headers


def _build_contents_request(capability, token):
    owner, repo, path, branch = capability
    if not token or any(byte < 33 or byte > 126 for byte in token):
        raise TransportFailure()
    encoded_path = '/'.join(segment for segment in path.split('/'))
    encoded_branch = branch.replace('/', '%2F')
    target = ('/repos/' + owner + '/' + repo + '/contents/' + encoded_path +
              '?ref=' + encoded_branch).encode('ascii')
    return (bytearray(b'GET ' + target + b' HTTP/1.1\r\nHost: ' + API_HOST.encode() +
                      b'\r\nAuthorization: Bearer ' + token +
                      b'\r\nUser-Agent: FarmCtl-Pico/1\r\nAccept: application/vnd.github.raw+json\r\n'
                       b'Accept-Encoding: identity\r\nConnection: close\r\n\r\n'))


def _build_gist_get_request(gist_identifier, token):
    if not token or any(byte < 33 or byte > 126 for byte in token):
        raise TransportFailure()
    return bytearray(b'GET /gists/' + gist_identifier.encode() + b' HTTP/1.1\r\n'
                     b'Host: ' + API_HOST.encode() + b'\r\nAuthorization: Bearer ' + token +
                     b'\r\nUser-Agent: FarmCtl-Pico/1\r\nAccept: application/vnd.github+json\r\n'
                     b'Accept-Encoding: identity\r\nConnection: close\r\n\r\n')


def _build_request(gist_identifier, token, body):
    if not token or any(byte < 33 or byte > 126 for byte in token):
        raise TransportFailure()
    request = bytearray()
    request.extend(b'PATCH /gists/' + gist_identifier.encode() + b' HTTP/1.1\r\n')
    request.extend(b'Host: ' + API_HOST.encode() + b'\r\nAuthorization: Bearer ')
    request.extend(token)
    request.extend(b'\r\nUser-Agent: FarmCtl-Pico/1\r\nAccept: application/vnd.github+json\r\n')
    request.extend(b'Content-Type: application/json\r\nAccept-Encoding: identity\r\n')
    request.extend(b'Content-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n')
    request.extend(body)
    return request


def _parse_headers(raw_headers):
    lines = raw_headers.split(b'\r\n')
    if not lines or len(lines[0].split(b' ', 2)) != 3:
        raise TransportFailure()
    protocol, status_text, reason = lines[0].split(b' ', 2)
    if protocol not in (b'HTTP/1.0', b'HTTP/1.1') or len(status_text) != 3 or not status_text.isdigit():
        raise TransportFailure()
    if reason and any(byte < 32 or byte > 126 for byte in reason):
        raise TransportFailure()
    headers = {}
    for line in lines[1:]:
        if not line or b':' not in line or line[:1] in (b' ', b'\t'):
            raise TransportFailure()
        key, value = line.split(b':', 1)
        if not key or any(byte < 33 or byte > 126 for byte in key):
            raise TransportFailure()
        key, value = key.lower(), value.strip()
        if key in headers or any(byte < 32 and byte != 9 for byte in value):
            raise TransportFailure()
        headers[key] = value
    if b'transfer-encoding' in headers or headers.get(b'content-encoding', b'identity').lower() != b'identity':
        raise TransportFailure()
    length = headers.get(b'content-length')
    if length is None or not length.isdigit():
        raise TransportFailure()
    return int(status_text), headers


def _is_would_block(error):
    transient = (getattr(errno, 'EAGAIN', 11), getattr(errno, 'EWOULDBLOCK', 11),
                 getattr(errno, 'EINPROGRESS', 115), getattr(errno, 'EALREADY', 114))
    return getattr(error, 'errno', None) in transient


def _is_hex_identifier(identifier):
    return isinstance(identifier, str) and len(identifier) == 32 and all(
        character in '0123456789abcdefABCDEF' for character in identifier)


def _valid_owner_repo(value):
    return isinstance(value, str) and 1 <= len(value) <= 100 and all(
        character in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-' for character in value)


def _is_ipv4(address):
    if not isinstance(address, str):
        return False
    parts = address.split('.')
    if len(parts) != 4:
        return False
    for part in parts:
        if not part or not part.isdigit() or len(part) > 3:
            return False
        value = int(part)
        if value > 255 or str(value) != part:
            return False
    return True


def _valid_contents_path(value):
    return isinstance(value, str) and len(value) <= 512 and all(
        _valid_path_segment(segment) for segment in value.split('/'))


def _valid_ref(value):
    return isinstance(value, str) and len(value) <= 128 and all(
        _valid_path_segment(segment) for segment in value.split('/'))


def _valid_path_segment(segment):
    return bool(segment) and segment not in ('.', '..') and all(
        character in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for character in segment)


def _ticks_diff(clock, current, previous):
    fn = getattr(clock, 'ticks_diff', None)
    return fn(current, previous) if fn else current - previous


def _zero(buffer):
    for index in range(len(buffer)):
        buffer[index] = 0
