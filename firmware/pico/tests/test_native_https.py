import unittest
from unittest import mock

from native_https import HttpFailure, NativeHttpsTransport, TransportFailure, _build_request

GIST_ID = '01234567' * 4
OTHER_ID = '89abcdef' * 4
TOKEN = 'native-test-token'
ROOTS = b'synthetic public CA roots'
DNS_SERVER = '192.0.2.53'


def fake_resolver(host, dns_server_ip, socket_module, select_module, clock,
                  service=None, deadline_ms=None):
    socket_module.addresses.append((host, 443))
    return [(2, 1, 0, '', ('1.1.1.1', 443))]


class Clock:
    def __init__(self, modulus=None):
        self.now = 0
        self.modulus = modulus

    def ticks_ms(self):
        return self.now % self.modulus if self.modulus else self.now

    def ticks_diff(self, current, previous):
        if not self.modulus:
            return current - previous
        half = self.modulus // 2
        return (current - previous + half) % self.modulus - half


class TlsSocket:
    def __init__(self, response, write_limit=11, read_limit=23, stalled=False):
        self.response = response
        self.write_limit = write_limit
        self.read_limit = read_limit
        self.stalled = stalled
        self.request = bytearray()
        self.closed = False

    def setblocking(self, value):
        self.nonblocking = not value

    def write(self, data):
        count = min(len(data), self.write_limit)
        self.request.extend(data[:count])
        if getattr(self, 'stall_after_request', False) and self.request.endswith(b'\r\n\r\n'):
            self.stalled = True
        return count

    def read(self, size):
        count = min(size, self.read_limit, len(self.response))
        piece, self.response = self.response[:count], self.response[count:]
        return piece

    def close(self):
        self.closed = True


class RawSocket:
    def __init__(self):
        self.closed = False

    def setblocking(self, value):
        self.nonblocking = not value

    def connect(self, address):
        self.address = address

    def close(self):
        self.closed = True


class Poller:
    def __init__(self, clock, stalled=False):
        self.clock = clock
        self.stalled = stalled
        self.sock = None
        self.events = 0

    def register(self, sock, events):
        self.sock, self.events = sock, events

    def unregister(self, sock):
        self.sock = None

    def modify(self, sock, events):
        self.sock, self.events = sock, events

    def poll(self, timeout):
        if self.stalled or getattr(self.sock, 'stalled', False):
            self.clock.now += timeout
            return []
        return [(self.sock, self.events)]


class Select:
    def __init__(self, clock, stalled=False):
        self.clock, self.stalled = clock, stalled

    def poll(self):
        return Poller(self.clock, self.stalled)


class TlsContext:
    def __init__(self, tls):
        self.tls = tls
        self.verify_mode = None

    def load_verify_locations(self, roots):
        self.roots = roots

    def wrap_socket(self, sock, server_hostname, do_handshake_on_connect):
        self.server_hostname = server_hostname
        self.do_handshake_on_connect = do_handshake_on_connect
        self.tls.wrapped = TlsSocket(self.tls.response, stalled=self.tls.stalled)
        self.tls.wrapped.stall_after_request = getattr(self.tls, 'stall_after_request', False)
        return self.tls.wrapped


class Tls:
    PROTOCOL_TLS_CLIENT, CERT_REQUIRED = 17, 2

    def __init__(self, response, stalled=False):
        self.response, self.stalled = response, stalled
        self.context = None
        self.wrapped = None
        self.stall_after_request = False

    def SSLContext(self, protocol):
        self.protocol = protocol
        self.context = TlsContext(self)
        return self.context


class Sockets:
    def __init__(self):
        self.raw = None
        self.addresses = []

    def socket(self, family, socktype, proto):
        self.raw = RawSocket()
        return self.raw

    def getaddrinfo(self, host, port):
        self.addresses.append((host, port))
        return [(2, 1, 0, '', ('192.0.2.1', port))]


class NativeHttpsTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.response = b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}'
        self.tls = Tls(self.response)
        self.select = Select(self.clock)
        self.sockets = Sockets()
        self.transport = NativeHttpsTransport(
            (GIST_ID, OTHER_ID), TOKEN, ROOTS, self.tls, self.select,
            self.sockets, self.clock, DNS_SERVER, resolver=fake_resolver)

    def test_tls_validation_fixed_host_and_partial_io(self):
        self.transport.patch_gist(GIST_ID, b'{"files":{}}')
        self.assertEqual(self.tls.protocol, self.tls.PROTOCOL_TLS_CLIENT)
        self.assertEqual(self.tls.context.verify_mode, self.tls.CERT_REQUIRED)
        self.assertEqual(self.tls.context.roots, ROOTS)
        self.assertEqual(self.tls.context.server_hostname, 'api.github.com')
        self.assertFalse(self.tls.context.do_handshake_on_connect)
        self.assertEqual(self.sockets.addresses, [('api.github.com', 443)])
        self.assertIn(b'PATCH /gists/' + GIST_ID.encode(), self.tls.wrapped.request)
        self.assertTrue(self.sockets.raw.closed)
        self.assertTrue(self.tls.wrapped.closed)

    def test_service_false_before_first_write_cancels_and_scrubs_request(self):
        captured = []
        def capture_request(*args):
            request = _build_request(*args)
            captured.append(request)
            return request

        with mock.patch('native_https._build_request', side_effect=capture_request):
            with self.assertRaises(TransportFailure):
                self.transport.patch_gist(GIST_ID, b'{"files":{}}', service=lambda: False)

        self.assertEqual(bytes(self.tls.wrapped.request), b'')
        self.assertEqual(self.sockets.addresses, [('api.github.com', 443)])
        self.assertTrue(self.sockets.raw.closed)
        self.assertTrue(self.tls.wrapped.closed)
        self.assertEqual(bytes(captured[0]), b'\x00' * len(captured[0]))

    def test_service_false_during_response_cancels_and_scrubs_request(self):
        captured = []
        def capture_request(*args):
            request = _build_request(*args)
            captured.append(request)
            return request

        def cancel_after_request_is_written():
            if self.tls.wrapped is not None and len(self.tls.wrapped.request) == len(captured[0]):
                return False
            return None

        with mock.patch('native_https._build_request', side_effect=capture_request):
            with self.assertRaises(TransportFailure):
                self.transport.patch_gist(GIST_ID, b'{"files":{}}',
                                          service=cancel_after_request_is_written)

        self.assertEqual(len(self.tls.wrapped.request), len(captured[0]))
        self.assertEqual(self.sockets.addresses, [('api.github.com', 443)])
        self.assertTrue(self.sockets.raw.closed)
        self.assertTrue(self.tls.wrapped.closed)
        self.assertEqual(bytes(captured[0]), b'\x00' * len(captured[0]))

    def test_service_true_and_none_continue_successfully(self):
        for service in (None, lambda: True):
            with self.subTest(service=service):
                self.tls = Tls(self.response)
                self.sockets = Sockets()
                self.transport = NativeHttpsTransport(
                    (GIST_ID, OTHER_ID), TOKEN, ROOTS, self.tls, self.select,
                    self.sockets, self.clock, DNS_SERVER, resolver=fake_resolver)
                self.transport.patch_gist(GIST_ID, b'{}', service=service)
                self.assertTrue(self.tls.wrapped.request)
                self.assertTrue(self.sockets.raw.closed)
                self.assertTrue(self.tls.wrapped.closed)

    def test_only_registered_gist_capabilities_can_be_patched(self):
        with self.assertRaises(TransportFailure):
            self.transport.patch_gist('fedcba98' * 4, b'{}')
        self.assertEqual(self.sockets.addresses, [])

    def test_gist_get_is_fixed_registered_and_bounded(self):
        self.tls.response = (b'HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n'
                             b'Content-Length: 2\r\n\r\n{}')
        chunks = []
        serviced = []
        self.transport.get_gist_json(GIST_ID, chunks.append,
                                     service=lambda: serviced.append(self.clock.now))
        request = bytes(self.tls.wrapped.request)
        self.assertIn(b'GET /gists/' + GIST_ID.encode() + b' HTTP/1.1', request)
        self.assertIn(b'Host: api.github.com\r\n', request)
        self.assertIn(b'Accept: application/vnd.github+json\r\n', request)
        self.assertEqual(request.count(TOKEN.encode()), 1)
        self.assertEqual(b''.join(chunks), b'{}')
        self.assertTrue(serviced)
        self.assertTrue(all(0 <= tick <= 250 for tick in serviced))
        with self.assertRaises(TransportFailure):
            self.transport.get_gist_json('fedcba98' * 4, chunks.append)

    def test_gist_get_rejects_oversize_chunked_and_incomplete_length(self):
        responses = (
            b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 32769\r\n\r\n',
            b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n{}',
            b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}',
            b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}',
        )
        for response in responses:
            with self.subTest(response=response[:50]):
                self.tls.response = response
                with self.assertRaises(TransportFailure):
                    self.transport.get_gist_json(GIST_ID, lambda piece: None)

    def test_gist_get_redirect_and_304_are_not_followed(self):
        for status in (302, 304):
            self.sockets.addresses.clear()
            self.tls.response = ('HTTP/1.1 %d Status\r\nContent-Length: 0\r\n\r\n' % status).encode()
            with self.assertRaises(HttpFailure) as caught:
                self.transport.get_gist_json(GIST_ID, lambda piece: None)
            self.assertEqual(caught.exception.status, status)
            self.assertEqual(len(self.sockets.addresses), 1)

    def test_redirect_and_non_200_fail_without_redirect_or_token_forwarding(self):
        self.tls.response = b'HTTP/1.1 302 Found\r\nContent-Length: 0\r\nLocation: https://evil.invalid/\r\n\r\n'
        with self.assertRaises(HttpFailure) as caught:
            self.transport.patch_gist(GIST_ID, b'{}')
        self.assertEqual(caught.exception.status, 302)
        self.assertEqual(len(self.sockets.addresses), 1)
        request = bytes(self.tls.wrapped.request)
        self.assertEqual(request.count(TOKEN.encode()), 1)
        self.assertNotIn(b'evil.invalid', request)
        self.assertTrue(self.sockets.raw.closed)
        self.assertTrue(self.tls.wrapped.closed)

    def test_rate_limit_headers_are_extracted_for_publisher_cooldown(self):
        self.tls.response = b'HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nRetry-After: 60\r\nX-RateLimit-Reset: 1800000060\r\n\r\n'
        with self.assertRaises(HttpFailure) as caught:
            self.transport.patch_gist(GIST_ID, b'{}')
        self.assertEqual(caught.exception.headers[b'retry-after'], b'60')
        self.assertEqual(caught.exception.headers[b'x-ratelimit-reset'], b'1800000060')

    def test_header_limit_and_tick_wrap_timeout_close_sockets(self):
        self.tls.response = b'HTTP/1.1 200 OK\r\nX-Pad: ' + b'x' * 8200 + b'\r\nContent-Length: 0\r\n\r\n'
        with self.assertRaises(TransportFailure):
            self.transport.patch_gist(GIST_ID, b'{}')
        self.assertTrue(self.sockets.raw.closed)
        self.assertTrue(self.tls.wrapped.closed)

        clock = Clock(modulus=1000)
        clock.now = 950
        tls = Tls(self.response, stalled=True)
        sockets = Sockets()
        transport = NativeHttpsTransport((GIST_ID, OTHER_ID), TOKEN, ROOTS,
                                         tls, Select(clock), sockets, clock, DNS_SERVER,
                                         resolver=fake_resolver,
                                         timeout_ms=100)
        with self.assertRaises(TransportFailure):
            transport.patch_gist(GIST_ID, b'{}')
        self.assertTrue(sockets.raw.closed)
        self.assertTrue(tls.wrapped.closed)

    def test_transport_close_scrubs_registered_token(self):
        self.transport.close()
        self.assertEqual(bytes(self.transport.token), b'\x00' * len(TOKEN))
        with self.assertRaises(TransportFailure):
            self.transport.patch_gist(GIST_ID, b'{}')

    def test_private_capability_is_read_only_and_cannot_be_mixed_with_gists(self):
        private = NativeHttpsTransport(
            (), 'private-read-token', ROOTS, self.tls, self.select, self.sockets,
            self.clock, DNS_SERVER, resolver=fake_resolver,
            private_contents=('farmctl', 'fleet', 'config/fleet.json', 'main'))
        with self.assertRaises(TransportFailure):
            private.patch_gist(GIST_ID, b'{}')
        with self.assertRaises(ValueError):
            NativeHttpsTransport(
                (GIST_ID,), TOKEN, ROOTS, self.tls, self.select, self.sockets,
                self.clock, DNS_SERVER, resolver=fake_resolver,
                private_contents=('farmctl', 'fleet', 'config/fleet.json', 'main'))
        with self.assertRaises(ValueError):
            NativeHttpsTransport((), TOKEN, ROOTS, self.tls, self.select, self.sockets,
                                 self.clock, DNS_SERVER, resolver=fake_resolver)

    def _private_transport(self, tls=None, timeout_ms=1000):
        tls = tls or Tls(b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
                         b'Content-Length: 2\r\n\r\n{}')
        return NativeHttpsTransport(
            (), 'private-read-token', ROOTS, tls, self.select, self.sockets, self.clock,
            DNS_SERVER, resolver=fake_resolver,
            timeout_ms=timeout_ms,
            private_contents=('farmctl', 'fleet', 'config/fleet.json', 'main')), tls

    def test_private_get_services_write_and_header_body_poll_opportunities(self):
        transport, tls = self._private_transport()
        calls = []
        result = transport.get_private_contents(lambda piece: None,
                                                service=lambda: calls.append(self.clock.now))
        self.assertEqual(result[b'content-length'], b'2')
        self.assertGreaterEqual(len(calls), 3)
        self.assertTrue(tls.wrapped.closed)

    def test_private_get_stalled_tls_and_header_polling_services_then_times_out(self):
        for stalled_tls, stalled_after_request in ((True, False), (False, True)):
            self.clock.now = 0
            tls = Tls(b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
                      b'Content-Length: 2\r\n\r\n{}', stalled=stalled_tls)
            tls.stall_after_request = stalled_after_request
            transport, tls = self._private_transport(tls=tls, timeout_ms=300)
            calls = []
            with self.assertRaises(TransportFailure):
                transport.get_private_contents(lambda piece: None,
                                               service=lambda: calls.append(self.clock.now))
            self.assertTrue(calls)
            self.assertTrue(tls.wrapped.closed)
            self.assertTrue(self.sockets.raw.closed)

    def test_private_get_service_errors_are_redacted_and_close_sockets(self):
        transport, tls = self._private_transport()

        def broken_service():
            raise RuntimeError('private-token-and-path')

        with self.assertRaises(TransportFailure) as caught:
            transport.get_private_contents(lambda piece: None, service=broken_service)
        self.assertNotIn('private-token-and-path', str(caught.exception))
        self.assertTrue(tls.wrapped.closed)
        self.assertTrue(self.sockets.raw.closed)

    def test_production_resolver_is_bounded_no_getaddrinfo_fallback_and_keeps_sni(self):
        answer = [(2, 1, 0, '', ('1.1.1.1', 443))]
        service = lambda: None
        self.tls.response = (b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
                             b'Content-Length: 2\r\n\r\n{}')
        with mock.patch('native_https.resolve_ipv4', return_value=answer) as bounded:
            transport = NativeHttpsTransport(
                (), TOKEN, ROOTS, self.tls, self.select,
                self.sockets, self.clock, DNS_SERVER,
                private_contents=('farmctl', 'fleet', 'config/fleet.json', 'main'))
            transport.get_private_contents(lambda piece: None, service=service)
        self.assertEqual(bounded.call_args.args[:2], ('api.github.com', DNS_SERVER))
        self.assertIs(bounded.call_args.kwargs['service'], service)
        self.assertEqual(bounded.call_args.kwargs['deadline_ms'], 15000)
        self.assertEqual(self.sockets.addresses, [])
        self.assertEqual(self.sockets.raw.address, ('1.1.1.1', 443))
        self.assertEqual(self.tls.context.server_hostname, 'api.github.com')

    def test_bounded_dns_timeout_fails_before_tls_or_authorization_write(self):
        def elapsed_resolver(host, dns_server_ip, socket_module, select_module, clock,
                             service=None, deadline_ms=None):
            clock.now += deadline_ms
            return [(2, 1, 0, '', ('192.0.2.1', 443))]

        transport = NativeHttpsTransport(
            (GIST_ID, OTHER_ID), TOKEN, ROOTS, self.tls, self.select,
            self.sockets, self.clock, DNS_SERVER, resolver=elapsed_resolver,
            timeout_ms=20)
        with self.assertRaises(TransportFailure):
            transport.patch_gist(GIST_ID, b'{}')
        self.assertIsNone(self.tls.context)
        self.assertIsNone(self.sockets.raw)

    def test_numeric_dns_server_is_required_and_validated(self):
        for address in ('', 'dns.google', '1.1.1.999', '01.2.3.4'):
            with self.subTest(address=address), self.assertRaises(ValueError):
                NativeHttpsTransport((GIST_ID,), TOKEN, ROOTS, self.tls, self.select,
                                     self.sockets, self.clock, address,
                                     resolver=fake_resolver)


if __name__ == '__main__':
    unittest.main()
