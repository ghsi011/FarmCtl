"""Credential-free, fixed-destination transport for public Pico release assets.

This deliberately does not share the authenticated Gist/private-repository
transport. It follows only GitHub's one validated release-asset redirect. The
    Asset responses are limited to identity-encoded Content-Length bodies;
    chunked or compressed asset responses fail closed (and may reduce
    availability if GitHub changes its response behavior). Redirect response
    bodies are ignored and their sockets closed. This module does not verify
    manifest signatures or asset hashes; callers must do so independently.
"""

import errno
import io

from bounded_dns import API_HOST, resolve_ipv4
from fleet_config import FleetConfigError, _Reader
from public_release_paths import build_release_path, parse_release_redirect

GITHUB_HOST = 'github.com'
RELEASE_ASSET_HOST = 'release-assets.githubusercontent.com'
MAX_RELEASE_PAGE_BYTES = 131072
MAX_RELEASE_PAGES = 32
MAX_RELEASE_TAG_BYTES = 128
MAX_RELEASE_ASSETS = 16
MAX_RELEASE_ASSET_NAME_BYTES = 255
GITHUB_API_VERSION = b'2022-11-28'
MAX_HEADER_BYTES = 8192
MAX_LOCATION_BYTES = 3072
MAX_ASSET_BYTES = 524288
WRITE_CHUNK_BYTES = 1024
REQUEST_TIMEOUT_MS = 15000
P_IN, P_OUT, P_ERR, P_HUP, P_NVAL = 1, 4, 8, 16, 32


class TransportFailure(Exception):
    """Redacted public transport failure."""


class PublicReleaseTransport:
    """Download bounded bytes from one provisioned public GitHub repository."""

    def __init__(self, owner, repo, root_bytes, tls_module, select_module,
                 socket_module, clock, dns_server_ip, time_is_usable,
                 resolver=None):
        # build_release_path performs strict fixed component validation; using
        # a valid example here prevents storing arbitrary URL authority input.
        build_release_path(owner, repo, 1, 'manifest.json')
        if not isinstance(root_bytes, (bytes, bytearray)) or not root_bytes:
            raise ValueError('provisioned CA roots are required')
        if not _is_ipv4(dns_server_ip):
            raise ValueError('numeric DNS server address is required')
        if not callable(time_is_usable):
            raise ValueError('trusted-time check is required')
        if not callable(getattr(clock, 'ticks_ms', None)) or not callable(
                getattr(clock, 'ticks_diff', None)):
            raise ValueError('monotonic tick clock is required')
        self.owner = owner
        self.repo = repo
        self.root_bytes = root_bytes
        self.tls = tls_module
        self.select = select_module
        self.socket = socket_module
        self.clock = clock
        self.dns_server_ip = dns_server_ip
        self.time_is_usable = time_is_usable
        # Production uses the bounded DNS resolver; injection is only for tests.
        self.resolver = resolver

    def fetch_asset(self, release_id, asset_name, writer, max_bytes,
                    expected_size=None, service=None):
        """Stream a fixed release asset to writer, returning validated headers."""
        if not callable(writer) or type(max_bytes) is not int or not 1 <= max_bytes <= MAX_ASSET_BYTES:
            raise TransportFailure() from None
        if expected_size is not None and (
                type(expected_size) is not int or expected_size < 0 or
                expected_size > max_bytes):
            raise TransportFailure() from None
        try:
            _, path = build_release_path(self.owner, self.repo, release_id, asset_name)
        except Exception:
            raise TransportFailure() from None
        try:
            start = self.clock.ticks_ms()
            # This check intentionally precedes resolver invocation and socket
            # creation: without usable time certificate validation is unsafe.
            if self.time_is_usable() is not True:
                raise TransportFailure() from None
            self._remaining(start)
            headers, status = self._request_hop(
                GITHUB_HOST, path, start, service, max_bytes, expected_size,
                writer, redirect=False)
            if status == 200:
                return headers
            if status != 302:
                raise TransportFailure() from None
            try:
                location = headers[b'location']
                host_bytes, redirect_path = parse_release_redirect(location)
            except Exception:
                raise TransportFailure() from None
            if host_bytes != RELEASE_ASSET_HOST.encode('ascii'):
                raise TransportFailure() from None
            self._remaining(start)
            second_headers, second_status = self._request_hop(
                RELEASE_ASSET_HOST, redirect_path, start, service, max_bytes,
                expected_size, writer, redirect=True)
            if second_status != 200:
                raise TransportFailure() from None
            return second_headers
        except Exception:
            # Never expose TLS, DNS, writer, or socket exception text.
            raise TransportFailure() from None

    def fetch_page(self, page_number, per_page=20, service=None):
        """Fetch and normalize one bounded public GitHub release-list page.

        The 128 KiB body cap bounds memory and intentionally fails closed if a
        page contains unusually large descriptions or other response data.
        """
        if (type(page_number) is not int or not 1 <= page_number <= MAX_RELEASE_PAGES or
                type(per_page) is not int or per_page != 20):
            raise TransportFailure() from None
        try:
            path = (b'/repos/' + self.owner.encode('ascii') + b'/' +
                    self.repo.encode('ascii') + b'/releases?per_page=20&page=' +
                    str(page_number).encode('ascii'))
            start = self.clock.ticks_ms()
            if self.time_is_usable() is not True:
                raise TransportFailure() from None
            self._remaining(start)
            body = io.BytesIO()
            headers, status = self._request_hop(
                API_HOST, path, start, service, MAX_RELEASE_PAGE_BYTES, None,
                body.write, redirect=False, listing=True)
            if status != 200:
                raise TransportFailure() from None
            if headers.get(b'content-type', b'').split(b';', 1)[0].strip().lower() not in (
                    b'application/json', b'application/vnd.github+json'):
                raise TransportFailure() from None
            body.seek(0)

            def parse_service(unused_byte_count):
                self._remaining(start)
                if service is not None and service() is False:
                    raise FleetConfigError('Release page processing stopped.')
                self._remaining(start)

            reader = _Reader(body, service=parse_service,
                             max_bytes=MAX_RELEASE_PAGE_BYTES,
                             max_members=64, max_string=16384, max_array=128)
            releases = reader.value()
            reader.space()
            if reader._byte() != -1:
                raise FleetConfigError('Malformed data after release page.')
            normalized = _normalize_release_page(releases)
            self._remaining(start)
            return normalized
        except Exception:
            # Keep signed URLs, response contents, and injected exception text
            # out of the public exception and its traceback.
            raise TransportFailure() from None

    def _request_hop(self, host, path, start, service, max_bytes,
                     expected_size, writer, redirect, listing=False):
        self._remaining(start)
        try:
            if self.resolver is None:
                records = resolve_ipv4(
                    host, self.dns_server_ip, self.socket, self.select,
                    self.clock, service=service, deadline_ms=self._remaining(start))
            else:
                records = self.resolver(
                    host, self.dns_server_ip, self.socket, self.select,
                    self.clock, service=service, deadline_ms=self._remaining(start))
        except Exception:
            raise TransportFailure() from None
        self._remaining(start)
        if not records:
            raise TransportFailure() from None
        raw_sock = None
        tls_sock = None
        try:
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
            tls_sock = context.wrap_socket(raw_sock, server_hostname=host,
                                           do_handshake_on_connect=False)
            tls_sock.setblocking(False)
            poller = self.select.poll()
            request = _build_request(host, path, listing=listing)
            try:
                self._write_all(tls_sock, poller, request, start, service)
            finally:
                _zero(request)
            return self._read_response(
                tls_sock, poller, start, service, max_bytes, expected_size,
                writer, redirect,
                expected_content_type=(b'application/json',
                                       b'application/vnd.github+json') if listing else None)
        except TransportFailure:
            raise
        except Exception:
            raise TransportFailure() from None
        finally:
            for sock in (tls_sock, raw_sock):
                if sock is not None:
                    try:
                        sock.close()
                    except Exception:
                        pass

    def _remaining(self, start):
        try:
            current = self.clock.ticks_ms()
            if type(current) is not int or type(start) is not int:
                raise ValueError()
            elapsed = self.clock.ticks_diff(current, start)
            if type(elapsed) is not int or elapsed < 0:
                raise ValueError()
            remaining = REQUEST_TIMEOUT_MS - elapsed
        except Exception:
            raise TransportFailure() from None
        if remaining <= 0:
            raise TransportFailure() from None
        return remaining

    def _wait_for(self, sock, events, start, poller, service):
        self._remaining(start)
        try:
            poller.modify(sock, events)
        except (AttributeError, OSError):
            try:
                poller.unregister(sock)
            except Exception:
                pass
            poller.register(sock, events)
        remaining = self._remaining(start)
        ready = poller.poll(min(250, remaining))
        if service is not None:
            try:
                if service() is False:
                    raise TransportFailure() from None
            except TransportFailure:
                raise
            except Exception:
                raise TransportFailure() from None
        self._remaining(start)
        if not ready:
            return False
        for ready_sock, flags in ready:
            if ready_sock is not sock:
                continue
            if flags & (P_NVAL | P_ERR) or (flags & P_HUP and not flags & events):
                raise TransportFailure() from None
            if flags & events:
                return True
        return False

    def _write_all(self, sock, poller, data, start, service):
        offset = 0
        while offset < len(data):
            if not self._wait_for(sock, P_OUT, start, poller, service):
                continue
            try:
                count = sock.write(data[offset:offset + WRITE_CHUNK_BYTES])
            except OSError as error:
                if _is_would_block(error):
                    continue
                raise TransportFailure() from None
            self._remaining(start)
            if count is None:
                continue
            if count <= 0:
                raise TransportFailure() from None
            offset += count

    def _read_response(self, sock, poller, start, service, max_bytes,
                       expected_size, writer, redirect,
                       expected_content_type=None):
        header = bytearray()
        boundary = -1
        while boundary < 0:
            if not self._wait_for(sock, P_IN, start, poller, service):
                continue
            try:
                piece = sock.read(min(1024, MAX_HEADER_BYTES + 1 - len(header)))
            except OSError as error:
                if _is_would_block(error):
                    continue
                raise TransportFailure() from None
            self._remaining(start)
            if piece is None:
                continue
            if not piece:
                raise TransportFailure() from None
            header.extend(piece)
            boundary = header.find(b'\r\n\r\n')
            if ((boundary < 0 and len(header) > MAX_HEADER_BYTES) or
                    (boundary >= 0 and boundary + 4 > MAX_HEADER_BYTES)):
                raise TransportFailure() from None
        status, headers = _parse_headers(bytes(header[:boundary]))
        if status == 302 and not redirect:
            location = headers.get(b'location')
            if location is None or len(location) > MAX_LOCATION_BYTES:
                raise TransportFailure() from None
            # Ignore all body bytes, including chunked framing. The hop socket
            # is closed in _request_hop's finally before another DNS lookup.
            if b'transfer-encoding' in headers:
                if (headers[b'transfer-encoding'].lower() != b'chunked' or
                        b'content-length' in headers):
                    raise TransportFailure() from None
            elif (b'content-length' in headers and
                  (not headers[b'content-length'].isdigit() or
                   len(headers[b'content-length']) > 10)):
                raise TransportFailure() from None
            return headers, status
        if status >= 300 and status != 302:
            raise TransportFailure() from None
        if redirect:
            if status == 302 or b'location' in headers:
                raise TransportFailure() from None
        elif status == 302:
            raise TransportFailure() from None
        elif status != 200 or b'location' in headers:
            raise TransportFailure() from None
        if (b'transfer-encoding' in headers or
                headers.get(b'content-encoding', b'identity').lower() != b'identity' or
                b'content-length' not in headers):
            raise TransportFailure() from None
        if expected_content_type is not None:
            content_type = headers.get(b'content-type', b'').split(b';', 1)[0].strip().lower()
            if content_type not in expected_content_type:
                raise TransportFailure() from None
        length_text = headers[b'content-length']
        if (not length_text.isdigit() or len(length_text) > 10):
            raise TransportFailure() from None
        length = int(length_text)
        if length > max_bytes or (expected_size is not None and length != expected_size):
            raise TransportFailure() from None
        remaining = length
        prefetched = bytes(header[boundary + 4:])
        if len(prefetched) > remaining:
            raise TransportFailure() from None
        if prefetched:
            self._write_chunk(writer, prefetched, start)
            remaining -= len(prefetched)
        while remaining:
            if not self._wait_for(sock, P_IN, start, poller, service):
                continue
            try:
                piece = sock.read(min(WRITE_CHUNK_BYTES, remaining))
            except OSError as error:
                if _is_would_block(error):
                    continue
                raise TransportFailure() from None
            self._remaining(start)
            if piece is None:
                continue
            if not piece or len(piece) > remaining:
                raise TransportFailure() from None
            self._write_chunk(writer, piece, start)
            remaining -= len(piece)
        self._remaining(start)
        return headers, status

    def _write_chunk(self, writer, piece, start):
        try:
            written = writer(piece)
        except Exception:
            raise TransportFailure() from None
        self._remaining(start)
        if written is not None and written != len(piece):
            raise TransportFailure() from None


def _build_request(host, path, listing=False):
    accept = (b'application/vnd.github+json' if listing else
              b'application/octet-stream')
    request = (b'GET ' + path + b' HTTP/1.1\r\nHost: ' + host.encode('ascii') +
               b'\r\nUser-Agent: FarmCtl-Pico/1\r\nAccept: ' + accept +
               b'\r\nAccept-Encoding: identity\r\n')
    if listing:
        request += b'X-GitHub-Api-Version: ' + GITHUB_API_VERSION + b'\r\n'
    return bytearray(request + b'Connection: close\r\n\r\n')


def _normalize_release_page(releases):
    if not isinstance(releases, list) or len(releases) > 20:
        raise TransportFailure() from None
    normalized = []
    for release in releases:
        if not isinstance(release, dict):
            raise TransportFailure() from None
        release_id = release.get('id')
        tag_name = release.get('tag_name')
        draft = release.get('draft')
        prerelease = release.get('prerelease')
        raw_assets = release.get('assets')
        if (type(release_id) is not int or release_id <= 0 or
                not isinstance(tag_name, str) or not tag_name or
                len(tag_name.encode('utf-8')) > MAX_RELEASE_TAG_BYTES or
                type(draft) is not bool or type(prerelease) is not bool or
                not isinstance(raw_assets, list)):
            raise TransportFailure() from None
        assets = []
        # Non-Pico releases (notably Android) may contain many unrelated
        # assets; retain no asset metadata for entries the selector won't admit.
        if tag_name.startswith('pico-'):
            if len(raw_assets) > MAX_RELEASE_ASSETS:
                raise TransportFailure() from None
            for raw_asset in raw_assets:
                if not isinstance(raw_asset, dict):
                    raise TransportFailure() from None
                asset_id = raw_asset.get('id')
                name = raw_asset.get('name')
                size = raw_asset.get('size')
                if (type(asset_id) is not int or asset_id <= 0 or
                        not isinstance(name, str) or not name or
                        len(name.encode('utf-8')) > MAX_RELEASE_ASSET_NAME_BYTES or
                        type(size) is not int or size < 0):
                    raise TransportFailure() from None
                assets.append({'id': asset_id, 'name': name, 'size': size})
        normalized.append({
            'id': release_id,
            'tag_name': tag_name,
            'draft': draft,
            'prerelease': prerelease,
            'assets': assets,
        })
    return normalized


def _parse_headers(raw):
    lines = raw.split(b'\r\n')
    if not lines or len(lines[0].split(b' ', 2)) != 3:
        raise TransportFailure() from None
    protocol, status_text, reason = lines[0].split(b' ', 2)
    if (protocol not in (b'HTTP/1.0', b'HTTP/1.1') or len(status_text) != 3 or
            not status_text.isdigit() or
            any(byte < 32 or byte > 126 for byte in reason)):
        raise TransportFailure() from None
    headers = {}
    for line in lines[1:]:
        if not line or b':' not in line or line[:1] in (b' ', b'\t'):
            raise TransportFailure() from None
        key, value = line.split(b':', 1)
        if not key or any(byte < 33 or byte > 126 for byte in key):
            raise TransportFailure() from None
        key, value = key.lower(), value.strip()
        if key in headers or any(byte < 32 and byte != 9 for byte in value):
            raise TransportFailure() from None
        headers[key] = value
    if (b'content-length' in headers and
            not headers[b'content-length'].isdigit()):
        raise TransportFailure() from None
    return int(status_text), headers


def _is_would_block(error):
    transient = (getattr(errno, 'EAGAIN', 11), getattr(errno, 'EWOULDBLOCK', 11),
                 getattr(errno, 'EINPROGRESS', 115), getattr(errno, 'EALREADY', 114))
    return getattr(error, 'errno', None) in transient


def _is_ipv4(address):
    if not isinstance(address, str):
        return False
    parts = address.split('.')
    if len(parts) != 4:
        return False
    for part in parts:
        if not part or not part.isdigit() or len(part) > 3 or int(part) > 255 or str(int(part)) != part:
            return False
    return True


def _zero(buffer):
    for index in range(len(buffer)):
        buffer[index] = 0
