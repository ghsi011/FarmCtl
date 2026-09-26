import unittest

from native_https import HttpFailure, NativeHttpsTransport, TransportFailure

GIST_ID = '01234567' * 4
OTHER_ID = '89abcdef' * 4
TOKEN = 'native-test-token'
ROOTS = b'synthetic public CA roots'


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
        return self.tls.wrapped


class Tls:
    PROTOCOL_TLS_CLIENT, CERT_REQUIRED = 17, 2

    def __init__(self, response, stalled=False):
        self.response, self.stalled = response, stalled
        self.context = None
        self.wrapped = None

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
            self.sockets, self.clock)

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

    def test_only_registered_gist_capabilities_can_be_patched(self):
        with self.assertRaises(TransportFailure):
            self.transport.patch_gist('fedcba98' * 4, b'{}')
        self.assertEqual(self.sockets.addresses, [])

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
                                         tls, Select(clock), sockets, clock,
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


if __name__ == '__main__':
    unittest.main()
