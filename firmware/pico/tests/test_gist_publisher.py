import errno
import unittest

from gist_publisher import (
    DIAGNOSTICS_FILENAME, GistPublisher, MAX_REQUEST_BYTES,
    THERMOSTAT_FILENAME,
)

TEMPERATURE_ID = '01234567' * 4
DIAGNOSTICS_ID = '89abcdef' * 4
TOKEN = 'synthetic-test-token'
ROOTS = b'-----BEGIN CERTIFICATE-----synthetic public CA-----END CERTIFICATE-----'


class FakeClock:
    def __init__(self, modulus=None):
        self.now = 0
        self.epoch = 1800000000
        self.modulus = modulus

    def ticks_ms(self):
        return self.now % self.modulus if self.modulus else self.now

    def ticks_diff(self, current, previous):
        if not self.modulus:
            return current - previous
        half = self.modulus // 2
        return (current - previous + half) % self.modulus - half

    def ticks_add(self, value, delta):
        return (value + delta) % self.modulus if self.modulus else value + delta

    def time(self):
        return self.epoch


class FakeTlsSocket:
    def __init__(self, response, clock, write_limit=19, read_none_once=False,
                 stall_write=False, write_none_count=0, writable_only=False):
        self.response = response
        self.clock = clock
        self.write_limit = write_limit
        self.read_none_once = read_none_once
        self.stall_write = stall_write
        self.write_none_count = write_none_count
        self.writable_only = writable_only
        self.request = bytearray()
        self.closed = False
        self.read_calls = 0

    def setblocking(self, value):
        self.nonblocking = not value

    def write(self, data):
        if self.stall_write:
            return None
        if self.write_none_count:
            self.write_none_count -= 1
            if not self.write_none_count:
                self.writable_only = False
            return None
        count = min(len(data), self.write_limit)
        self.request.extend(data[:count])
        return count

    def read(self, size):
        self.read_calls += 1
        if self.read_none_once:
            self.read_none_once = False
            return None
        piece = self.response[:size]
        self.response = self.response[size:]
        return piece

    def close(self):
        self.closed = True


class FakeRawSocket:
    def __init__(self):
        self.closed = False

    def setblocking(self, value):
        self.nonblocking = not value

    def connect(self, address):
        self.address = address

    def close(self):
        self.closed = True


class FakePoller:
    def __init__(self, clock):
        self.clock = clock
        self.sock = None
        self.events = 0
        self.poll_events = []

    def register(self, sock, events):
        self.sock, self.events = sock, events

    def modify(self, sock, events):
        self.sock, self.events = sock, events

    def unregister(self, sock):
        self.sock = None

    def poll(self, timeout):
        self.poll_events.append(self.events)
        if getattr(self.sock, 'stall_write', False):
            self.clock.now += timeout
            return []
        if getattr(self.sock, 'writable_only', False):
            if self.events & 4:
                return [(self.sock, 4)]
            self.clock.now += timeout
            return []
        return [(self.sock, self.events)]


class FakeSelect:
    POLLIN, POLLOUT, POLLERR, POLLHUP, POLLNVAL = 1, 4, 8, 16, 32

    def __init__(self, clock):
        self.clock = clock
        self.pollers = []

    def poll(self):
        poller = FakePoller(self.clock)
        self.pollers.append(poller)
        return poller


class FakeTlsContext:
    def __init__(self, tls):
        self.tls = tls
        self.verify_mode = None
        self.roots = None
        self.server_name = None

    def load_verify_locations(self, roots):
        self.roots = roots

    def wrap_socket(self, sock, server_hostname, do_handshake_on_connect):
        self.server_name = server_hostname
        self.handshake_option = do_handshake_on_connect
        self.tls.wrapped = FakeTlsSocket(
            self.tls.response, self.tls.clock, self.tls.write_limit,
            self.tls.read_none_once, self.tls.stall_write,
            self.tls.write_none_count, self.tls.writable_only)
        return self.tls.wrapped


class FakeTls:
    PROTOCOL_TLS_CLIENT, CERT_REQUIRED = 17, 2

    def __init__(self, clock, response, write_limit=19, read_none_once=False,
                 stall_write=False, write_none_count=0, writable_only=False):
        self.clock, self.response = clock, response
        self.write_limit, self.read_none_once, self.stall_write = write_limit, read_none_once, stall_write
        self.write_none_count, self.writable_only = write_none_count, writable_only
        self.context = None
        self.wrapped = None

    def SSLContext(self, protocol):
        self.protocol = protocol
        self.context = FakeTlsContext(self)
        return self.context


class FakeSocketModule:
    def __init__(self):
        self.raw = None
        self.addresses = []

    def socket(self, family, socktype, proto):
        self.raw = FakeRawSocket()
        return self.raw

    def getaddrinfo(self, host, port):
        self.addresses.append((host, port))
        return [(2, 1, 0, '', ('192.0.2.1', port))]


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.response = b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}'
        self.tls = FakeTls(self.clock, self.response)
        self.select = FakeSelect(self.clock)
        self.sockets = FakeSocketModule()
        self.publisher = GistPublisher(
            TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS, self.tls,
            self.select, self.sockets, self.clock, time_is_trusted=lambda: True)
        self.payload = {'files': {THERMOSTAT_FILENAME: {'content': '20.00°C\nSample: b:1'}}}

    def _fresh(self, response=None, **tls_options):
        self.tls = FakeTls(self.clock, self.response if response is None else response, **tls_options)
        self.select = FakeSelect(self.clock)
        self.sockets = FakeSocketModule()
        return GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                             self.tls, self.select, self.sockets, self.clock,
                             time_is_trusted=lambda: True)

    def test_native_tls_sni_ca_partial_io_and_fixed_github_user_agent(self):
        self.assertTrue(self.publisher.publish_temperature(self.payload))
        self.assertEqual(self.tls.protocol, self.tls.PROTOCOL_TLS_CLIENT)
        self.assertEqual(self.tls.context.verify_mode, self.tls.CERT_REQUIRED)
        self.assertEqual(self.tls.context.roots, ROOTS)
        self.assertEqual(self.tls.context.server_name, 'api.github.com')
        self.assertFalse(self.tls.context.handshake_option)
        request = bytes(self.tls.wrapped.request)
        self.assertIn(b'PATCH /gists/' + TEMPERATURE_ID.encode(), request)
        self.assertIn(b'Host: api.github.com\r\n', request)
        self.assertIn(b'User-Agent: FarmCtl-Pico/1\r\n', request)
        self.assertIn(b'Authorization: Bearer ' + TOKEN.encode(), request)
        self.assertTrue(self.tls.wrapped.closed)
        self.assertTrue(self.sockets.raw.closed)

    def test_distinct_gists_and_payload_routed_to_matching_destination(self):
        diagnostics = {'files': {DIAGNOSTICS_FILENAME: {'content': '{}'}}}
        self.assertTrue(self.publisher.publish_diagnostics(diagnostics))
        self.assertIn(b'PATCH /gists/' + DIAGNOSTICS_ID.encode(), self.tls.wrapped.request)
        self.assertNotIn(TEMPERATURE_ID.encode(), self.tls.wrapped.request)
        with self.assertRaises(ValueError):
            GistPublisher(TEMPERATURE_ID, TEMPERATURE_ID, TOKEN, ROOTS, self.tls,
                          self.select, self.sockets, self.clock, time_is_trusted=lambda: True)

    def test_200_headers_are_ack_without_draining_large_history_body(self):
        publisher = self._fresh(b'HTTP/1.1 200 OK\r\nContent-Length: 500000\r\n\r\n')
        self.assertTrue(publisher.publish_temperature(self.payload))
        self.assertEqual(self.tls.wrapped.read_calls, 1)

    def test_none_is_would_block_but_empty_bytes_is_eof(self):
        publisher = self._fresh(self.response, read_none_once=True)
        self.assertTrue(publisher.publish_temperature(self.payload))
        publisher = self._fresh(b'')
        self.assertFalse(publisher.publish_temperature(self.payload))

    def test_untrusted_time_and_invalid_payload_fail_before_dns(self):
        publisher = GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                                  self.tls, self.select, self.sockets, self.clock,
                                  time_is_trusted=lambda: False)
        self.assertFalse(publisher.publish_temperature(self.payload))
        self.assertFalse(self.sockets.addresses)
        self.assertFalse(self.publisher.publish_temperature({'unexpected': 'shape'}))
        self.assertFalse(self.sockets.addresses)

    def test_request_size_limit_precedes_dns(self):
        payload = {'files': {THERMOSTAT_FILENAME: {'content': 'x' * MAX_REQUEST_BYTES}}}
        self.assertFalse(self.publisher.publish_temperature(payload))
        self.assertFalse(self.sockets.addresses)

    def test_non_200_and_redirect_responses_rejected(self):
        for status in (301, 302, 303, 307, 308, 401, 403, 429, 500, 503):
            with self.subTest(status=status):
                self.clock.now += 400000
                publisher = self._fresh(('HTTP/1.1 %d Status\r\nContent-Length: 0\r\n\r\n' % status).encode())
                self.assertFalse(publisher.publish_temperature(self.payload))

    def test_rate_limit_retry_hint_applies_to_both_streams(self):
        publisher = self._fresh(b'HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nRetry-After: 60\r\n\r\n')
        self.assertFalse(publisher.publish_temperature(self.payload))
        diagnostics = {'files': {DIAGNOSTICS_FILENAME: {'content': '{}'}}}
        self.assertFalse(publisher.publish_diagnostics(diagnostics))
        self.assertEqual(len(self.sockets.addresses), 1)

    def test_hintless_429_applies_shared_minimum_cooldown(self):
        publisher = self._fresh(b'HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n')
        self.assertFalse(publisher.publish_temperature(self.payload))
        diagnostics = {'files': {DIAGNOSTICS_FILENAME: {'content': '{}'}}}
        self.assertFalse(publisher.publish_diagnostics(diagnostics))
        self.assertEqual(len(self.sockets.addresses), 1)
        self.clock.now += 59999
        self.assertFalse(publisher.publish_diagnostics(diagnostics))
        self.assertEqual(len(self.sockets.addresses), 1)
        self.clock.now += 1
        publisher.tls.response = self.response
        self.assertTrue(publisher.publish_diagnostics(diagnostics))
        self.assertEqual(len(self.sockets.addresses), 2)

    def test_expired_shared_cooldown_is_cleared_before_later_tick_wrap(self):
        clock = FakeClock(modulus=1000000)
        tls = FakeTls(clock, b'HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n')
        select, sockets = FakeSelect(clock), FakeSocketModule()
        publisher = GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                                  tls, select, sockets, clock,
                                  time_is_trusted=lambda: True)
        self.assertFalse(publisher.publish_temperature(self.payload))
        clock.now += 60000
        tls.response = self.response
        diagnostics = {'files': {DIAGNOSTICS_FILENAME: {'content': '{}'}}}
        self.assertTrue(publisher.publish_temperature(self.payload))
        self.assertIsNone(publisher._server_not_before)
        clock.now += 600000
        self.assertTrue(publisher.publish_temperature(self.payload))
        self.assertTrue(publisher.publish_diagnostics(diagnostics))

    def test_tls_write_retries_transient_none_on_writable_readiness_without_retry_cap(self):
        publisher = self._fresh(self.response, write_none_count=12, writable_only=True)
        self.assertTrue(publisher.publish_temperature(self.payload))
        self.assertEqual(self.tls.wrapped.write_none_count, 0)
        poller = self.select.pollers[-1]
        self.assertTrue(all(events & 4 for events in poller.poll_events[:13]))

    def test_rate_limit_reset_is_honored_for_403(self):
        publisher = self._fresh(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nX-RateLimit-Reset: 1800000030\r\n\r\n')
        self.assertFalse(publisher.publish_temperature(self.payload))
        self.assertEqual(publisher._server_not_before, 30000)

    def test_bounded_stall_cleans_up_sockets_and_backoff_avoids_tight_retry(self):
        publisher = self._fresh(self.response, stall_write=True)
        self.assertFalse(publisher.publish_temperature(self.payload))
        self.assertTrue(self.sockets.raw.closed)
        self.assertTrue(self.tls.wrapped.closed)
        self.assertFalse(publisher.publish_temperature(self.payload))
        self.assertEqual(len(self.sockets.addresses), 1)

    def test_synchronous_dns_can_exceed_deadline_and_is_an_unresolved_gate(self):
        def slow_resolver(host, port):
            self.clock.now += 20000
            return [(2, 1, 0, '', ('192.0.2.1', port))]

        publisher = GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                                  self.tls, self.select, self.sockets, self.clock,
                                  resolver=slow_resolver, time_is_trusted=lambda: True)
        self.assertFalse(publisher.publish_temperature(self.payload))
        self.assertTrue(self.sockets.raw.closed)

    def test_100_event_payload_fits_request_cap(self):
        content = '{"events":[' + ','.join('{"id":"boot:%d","code":"failure","count":1}' % n for n in range(100)) + ']}'
        payload = {'files': {DIAGNOSTICS_FILENAME: {'content': content}}}
        self.assertTrue(self.publisher.publish_diagnostics(payload))
        self.assertLessEqual(len(self.tls.wrapped.request), MAX_REQUEST_BYTES)

    def test_close_scrubs_in_memory_token(self):
        self.publisher.close()
        self.assertEqual(bytes(self.publisher._token), b'\x00' * len(TOKEN))


if __name__ == '__main__':
    unittest.main()
