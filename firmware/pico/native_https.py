"""Fixed-destination native TLS transport for registered GitHub Gist PATCHes.

DNS resolution uses synchronous getaddrinfo and is not bounded by the socket
deadline. Only the configured Gist IDs can be addressed; callers cannot choose
the HTTPS host, HTTP method, or request path.
"""

import errno

API_HOST = 'api.github.com'
MAX_HEADER_BYTES = 8192
MAX_REQUEST_BYTES = 32768
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
    """Native TLS only; capabilities are a fixed set of Gist identifiers."""

    def __init__(self, gist_identifiers, token, root_bytes, tls_module,
                 select_module, socket_module, clock, resolver=None,
                 timeout_ms=REQUEST_TIMEOUT_MS):
        if (not isinstance(gist_identifiers, (tuple, list)) or not gist_identifiers or
                any(not _is_hex_identifier(value) for value in gist_identifiers) or
                len(set(value.lower() for value in gist_identifiers)) != len(gist_identifiers)):
            raise ValueError('invalid Gist capabilities')
        token_bytes = token.encode() if isinstance(token, str) else bytes(token)
        if not token_bytes or any(byte < 33 or byte > 126 for byte in token_bytes):
            raise ValueError('invalid token')
        if not isinstance(root_bytes, (bytes, bytearray)) or not root_bytes:
            raise ValueError('provisioned CA roots are required')
        self._gist_ids = tuple(value.lower() for value in gist_identifiers)
        self.token = token if isinstance(token, bytearray) else bytearray(token_bytes)
        self.root_bytes = root_bytes
        self.tls = tls_module
        self.select = select_module
        self.socket = socket_module
        self.clock = clock
        self.resolver = resolver or socket_module.getaddrinfo
        self.timeout_ms = timeout_ms
        self._closed = False

    def close(self):
        _zero(self.token)
        self._closed = True

    def patch_gist(self, gist_identifier, body):
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
            return self._request(request)
        finally:
            _zero(request)

    def _request(self, request):
        start = self.clock.ticks_ms()
        raw_sock = tls_sock = None
        try:
            # getaddrinfo is synchronous and can exceed timeout_ms.
            records = self.resolver(API_HOST, 443)
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
                self._wait_for(raw_sock, P_OUT, start, self.select.poll())
            context = self.tls.SSLContext(self.tls.PROTOCOL_TLS_CLIENT)
            context.verify_mode = self.tls.CERT_REQUIRED
            context.load_verify_locations(self.root_bytes)
            tls_sock = context.wrap_socket(raw_sock, server_hostname=API_HOST,
                                           do_handshake_on_connect=False)
            tls_sock.setblocking(False)
            poller = self.select.poll()
            self._write_all(tls_sock, poller, request, start)
            return self._read_response(tls_sock, poller, start)
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

    def _wait_for(self, sock, events, start, poller):
        try:
            poller.modify(sock, events)
        except (AttributeError, OSError):
            try:
                poller.unregister(sock)
            except Exception:
                pass
            poller.register(sock, events)
        ready = poller.poll(min(250, self._remaining(start)))
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

    def _write_all(self, sock, poller, data, start):
        offset = 0
        while offset < len(data):
            if not self._wait_for(sock, P_OUT, start, poller):
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

    def _read_response(self, sock, poller, start):
        header = bytearray()
        boundary = -1
        while boundary < 0:
            if not self._wait_for(sock, P_IN, start, poller):
                continue
            try:
                piece = sock.read(min(1024, MAX_HEADER_BYTES + 1 - len(header)))
            except OSError as error:
                if not _is_would_block(error):
                    raise
                continue
            if piece is None:
                continue
            if piece == b'':
                raise TransportFailure()
            header.extend(piece)
            if len(header) > MAX_HEADER_BYTES:
                raise TransportFailure()
            boundary = header.find(b'\r\n\r\n')
        status, headers = _parse_headers(bytes(header[:boundary]))
        # 200 headers form a provisional ACK; Gist history response bodies can
        # be large, so the transport closes without draining them.
        if status != 200:
            raise HttpFailure(status, headers)
        return headers


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


def _ticks_diff(clock, current, previous):
    fn = getattr(clock, 'ticks_diff', None)
    return fn(current, previous) if fn else current - previous


def _zero(buffer):
    for index in range(len(buffer)):
        buffer[index] = 0
