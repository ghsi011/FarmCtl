import unittest
import traceback
import json

from public_release_transport import PublicReleaseTransport, TransportFailure
from release_discovery import DiscoveryIncomplete, select_signed_release

ROOTS = b'fixture CA roots'
DNS_SERVER = '192.0.2.53'
ASSET_URL = (b'https://release-assets.githubusercontent.com/owner/repo/releases/download/'
             b'pico-7/app.mpy?token=opaque%2Fvalue')
TEST_SECRET = 'SECRET_SIGNED_URL'


def _writer_throws_secret(piece):
    raise RuntimeError(TEST_SECRET + ' writer')


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


class RawSocket:
    def __init__(self):
        self.closed = False

    def setblocking(self, value):
        pass

    def connect(self, address):
        self.address = address

    def close(self):
        self.closed = True


class TlsSocket:
    def __init__(self, response, write_limit=1024, read_limit=1024, stalled=False,
                 hostname=None):
        self.response = response
        self.write_limit = write_limit
        self.read_limit = read_limit
        self.stalled = stalled
        self.hostname = hostname
        self.request = bytearray()
        self.closed = False

    def setblocking(self, value):
        pass

    def write(self, data):
        if (getattr(self, 'write_error', None) is not None and
                (self.write_error_hostname is None or
                 self.hostname == self.write_error_hostname)):
            raise RuntimeError(self.write_error)
        count = min(len(data), self.write_limit)
        self.request.extend(data[:count])
        return count

    def read(self, size):
        count = min(size, self.read_limit, len(self.response))
        result, self.response = self.response[:count], self.response[count:]
        return result

    def close(self):
        self.closed = True


class Poller:
    def __init__(self, clock):
        self.clock = clock

    def register(self, sock, events):
        self.sock, self.events = sock, events

    def unregister(self, sock):
        pass

    def modify(self, sock, events):
        self.sock, self.events = sock, events

    def poll(self, timeout):
        if hasattr(self, 'timeouts'):
            self.timeouts.append(timeout)
        if getattr(self.sock, 'stalled', False):
            self.clock.now += timeout
            return []
        return [(self.sock, self.events)]


class Select:
    def __init__(self, clock):
        self.clock = clock

    def poll(self):
        return Poller(self.clock)


class Context:
    def __init__(self, tls):
        self.tls = tls
        self.verify_mode = None

    def load_verify_locations(self, roots):
        self.roots = roots

    def wrap_socket(self, sock, server_hostname, do_handshake_on_connect):
        self.server_hostname = server_hostname
        self.do_handshake_on_connect = do_handshake_on_connect
        wrapped = TlsSocket(self.tls.responses.pop(0), stalled=self.tls.stalled,
                            hostname=server_hostname)
        wrapped.write_error = self.tls.write_error
        wrapped.write_error_hostname = self.tls.write_error_hostname
        self.tls.wrapped.append(wrapped)
        return wrapped


class Tls:
    PROTOCOL_TLS_CLIENT, CERT_REQUIRED = 17, 2

    def __init__(self, responses, stalled=False):
        self.responses = list(responses)
        self.stalled = stalled
        self.contexts = []
        self.wrapped = []
        self.write_error = None
        self.write_error_hostname = None

    def SSLContext(self, protocol):
        self.protocol = protocol
        context = Context(self)
        self.contexts.append(context)
        return context


class Sockets:
    AF_INET, SOCK_STREAM, IPPROTO_TCP = 2, 1, 6

    def __init__(self):
        self.raw = []

    def socket(self, family, kind, protocol):
        sock = RawSocket()
        self.raw.append(sock)
        return sock


def response(status=200, body=b'firmware', extra=b''):
    return (b'HTTP/1.1 ' + str(status).encode() + b' Test\r\nContent-Length: ' +
            str(len(body)).encode() + b'\r\n' + extra + b'\r\n' + body)


class PublicReleaseTransportTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.sockets = Sockets()
        self.select = Select(self.clock)
        self.tls = Tls([response()])
        self.resolutions = []

        def resolver(host, dns_server_ip, socket_module, select_module, clock,
                     service=None, deadline_ms=None):
            self.resolutions.append((host, deadline_ms))
            if host == 'release-assets.githubusercontent.com' and self.sockets.raw:
                self.assertTrue(self.sockets.raw[-1].closed)
            return [(2, 1, 6, '', ('1.1.1.1', 443))]

        self.resolver = resolver
        self.transport = self.make_transport(self.tls)

    def make_transport(self, tls, usable=lambda: True, resolver=None):
        return PublicReleaseTransport(
            'owner', 'repo', ROOTS, tls, self.select, self.sockets, self.clock,
            DNS_SERVER, usable, resolver=resolver or self.resolver)

    def test_direct_200_streams_bytes_with_fixed_unauthenticated_request(self):
        pieces, serviced = [], []
        self.tls.wrapped.clear()
        self.tls = Tls([response(body=b'payload')])
        self.transport = self.make_transport(self.tls)
        headers = self.transport.fetch_asset(
            7, 'app.mpy', pieces.append, 1024, expected_size=7,
            service=lambda: serviced.append(self.clock.now))
        request = bytes(self.tls.wrapped[0].request)
        self.assertEqual(b''.join(pieces), b'payload')
        self.assertEqual(headers[b'content-length'], b'7')
        self.assertIn(b'GET /owner/repo/releases/download/pico-7/app.mpy HTTP/1.1', request)
        self.assertIn(b'Host: github.com\r\n', request)
        self.assertIn(b'Accept-Encoding: identity\r\n', request)
        for forbidden in (b'Authorization:', b'Cookie:', b'Referer:', b'Proxy-Authorization:'):
            self.assertNotIn(forbidden, request)
        self.assertEqual(self.tls.contexts[0].server_hostname, 'github.com')
        self.assertEqual(self.tls.contexts[0].verify_mode, self.tls.CERT_REQUIRED)
        self.assertEqual(self.tls.contexts[0].roots, ROOTS)
        self.assertTrue(serviced)
        self.assertTrue(all(0 <= tick <= 250 for tick in serviced))
        self.assertTrue(self.sockets.raw[0].closed)
        self.assertTrue(self.tls.wrapped[0].closed)

    def test_valid_redirect_uses_exact_query_and_new_fixed_host_without_credentials(self):
        first = response(302, b'', b'Location: ' + ASSET_URL + b'\r\n')
        second = response(body=b'firmware')
        self.tls = Tls([first, second])
        self.transport = self.make_transport(self.tls)
        pieces = []
        self.transport.fetch_asset(7, 'app.mpy', pieces.append, 1024)
        self.assertEqual([host for host, _ in self.resolutions],
                         ['github.com', 'release-assets.githubusercontent.com'])
        self.assertIn((b'GET /owner/repo/releases/download/pico-7/app.mpy HTTP/1.1'),
                      bytes(self.tls.wrapped[0].request))
        request2 = bytes(self.tls.wrapped[1].request)
        self.assertIn(b'GET /owner/repo/releases/download/pico-7/app.mpy?token=opaque%2Fvalue HTTP/1.1', request2)
        self.assertIn(b'Host: release-assets.githubusercontent.com\r\n', request2)
        for context, hostname in zip(self.tls.contexts,
                                     ('github.com', 'release-assets.githubusercontent.com')):
            self.assertEqual(context.server_hostname, hostname)
        self.assertTrue(all(sock.closed for sock in self.sockets.raw))
        self.assertTrue(all(sock.closed for sock in self.tls.wrapped))
        self.assertEqual(b''.join(pieces), b'firmware')
        for request in (bytes(sock.request) for sock in self.tls.wrapped):
            self.assertNotIn(b'Authorization:', request)
            self.assertNotIn(b'Cookie:', request)

    def test_redirect_body_is_ignored_for_length_chunked_or_unframed_responses(self):
        fixtures = (
            b'HTTP/1.1 302 Found\r\nLocation: ' + ASSET_URL +
            b'\r\nContent-Length: 18\r\n\r\n<html>redirect</html>',
            b'HTTP/1.1 302 Found\r\nLocation: ' + ASSET_URL +
            b'\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nignored body!!!\r\n0\r\n\r\n',
            b'HTTP/1.1 302 Found\r\nLocation: ' + ASSET_URL +
            b'\r\n\r\nignored body',
        )
        for redirect_response in fixtures:
            with self.subTest(redirect=redirect_response[:90]):
                self.sockets = Sockets()
                self.tls = Tls([redirect_response, response(body=b'firmware')])
                self.transport = self.make_transport(self.tls)
                self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
                self.assertEqual(len(self.tls.wrapped), 2)
                self.assertTrue(self.sockets.raw[0].closed)
                self.assertTrue(self.tls.wrapped[0].closed)

    def test_hostile_location_and_second_redirect_fail_closed(self):
        invalid = (
            b'https://evil.invalid/a?b=c',
            b'https://release-assets.githubusercontent.com/a?b=c#frag',
            b'https://release-assets.githubusercontent.com:443/a?b=c',
        )
        for location in invalid:
            with self.subTest(location=location):
                self.resolutions.clear()
                self.tls = Tls([response(302, b'', b'Location: ' + location + b'\r\n')])
                self.transport = self.make_transport(self.tls)
                with self.assertRaises(TransportFailure):
                    self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
                self.assertEqual(len(self.resolutions), 1)
        self.tls = Tls([response(302, b'', b'Location: ' + ASSET_URL + b'\r\n'),
                        response(302, b'', b'Location: ' + ASSET_URL + b'\r\n')])
        self.transport = self.make_transport(self.tls)
        self.resolutions.clear()
        with self.assertRaises(TransportFailure):
            self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
        self.assertEqual(len(self.resolutions), 2)

    def test_unusable_time_prevents_dns_and_socket_creation(self):
        transport = self.make_transport(self.tls, usable=lambda: False)
        with self.assertRaises(TransportFailure):
            transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
        self.assertEqual(self.resolutions, [])
        self.assertEqual(self.sockets.raw, [])

    def test_rejects_truncated_oversize_chunked_and_duplicate_security_headers(self):
        samples = (
            b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc',
            response(body=b'1234'),
            b'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\nabc',
            b'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc',
            b'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Encoding: gzip\r\n\r\nabc',
            b'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nLocation: x\r\n\r\nabc',
        )
        for sample in samples:
            with self.subTest(sample=sample[:80]):
                self.sockets = Sockets()
                self.tls = Tls([sample])
                self.transport = self.make_transport(self.tls)
                with self.assertRaises(TransportFailure):
                    self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 3,
                                               expected_size=3)
                self.assertTrue(self.sockets.raw[0].closed)
                self.assertTrue(self.tls.wrapped[0].closed)

    def test_shared_deadline_covers_dns_tls_and_services_poll_opportunities(self):
        def stalled_dns(host, dns_server_ip, socket_module, select_module, clock,
                        service=None, deadline_ms=None):
            clock.now += deadline_ms
            return [(2, 1, 6, '', ('1.1.1.1', 443))]

        transport = self.make_transport(self.tls, resolver=stalled_dns)
        with self.assertRaises(TransportFailure):
            transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
        self.assertEqual(self.sockets.raw, [])
        self.clock.now = 0
        self.resolutions.clear()
        self.tls = Tls([response()], stalled=True)
        self.transport = self.make_transport(self.tls)
        calls = []
        with self.assertRaises(TransportFailure):
            self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100,
                                       service=lambda: calls.append(self.clock.now))
        self.assertTrue(calls)
        self.assertTrue(all(0 < tick <= 15000 for tick in calls))
        self.assertTrue(self.sockets.raw[0].closed)
        self.assertTrue(self.tls.wrapped[0].closed)

    def test_redirect_hops_share_deadline_and_false_service_stops(self):
        first = response(302, b'', b'Location: ' + ASSET_URL + b'\r\n')
        self.tls = Tls([first, response(body=b'firmware')])

        def slow_first_dns(host, dns_server_ip, socket_module, select_module, clock,
                           service=None, deadline_ms=None):
            self.resolutions.append((host, deadline_ms))
            if host == 'github.com':
                clock.now += 14500
            return [(2, 1, 6, '', ('1.1.1.1', 443))]

        self.transport = self.make_transport(self.tls, resolver=slow_first_dns)
        self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
        self.assertEqual(self.resolutions[0][1], 15000)
        self.assertLess(self.resolutions[1][1], 1000)

        self.resolutions.clear()
        self.clock.now = 0
        self.tls = Tls([response(body=b'firmware')])
        self.transport = self.make_transport(self.tls)
        with self.assertRaises(TransportFailure):
            self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100,
                                       service=lambda: False)
        self.assertEqual(len(self.resolutions), 1)
        self.assertTrue(self.sockets.raw[-1].closed)
        self.assertTrue(self.tls.wrapped[-1].closed)

    def test_writer_failure_and_short_write_are_redacted_and_cleanup(self):
        for writer in (lambda piece: (_ for _ in ()).throw(RuntimeError('secret')), lambda piece: 1):
            self.sockets = Sockets()
            self.tls = Tls([response(body=b'firmware')])
            self.transport = self.make_transport(self.tls)
            with self.assertRaises(TransportFailure) as caught:
                self.transport.fetch_asset(7, 'app.mpy', writer, 100)
            self.assertNotIn('secret', str(caught.exception))
            self.assertTrue(self.sockets.raw[0].closed)
            self.assertTrue(self.tls.wrapped[0].closed)

    def test_full_traceback_hides_signed_url_and_writer_or_tls_exception_details(self):
        secret_url = b'https://evil.invalid/a/b?token=SECRET_SIGNED_URL'
        redirect_response = response(302, b'', b'Location: ' + secret_url + b'\r\n')
        self.tls = Tls([redirect_response])
        self.transport = self.make_transport(self.tls)
        try:
            self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
        except TransportFailure:
            formatted = traceback.format_exc()
        self.assertNotIn('SECRET_SIGNED_URL', formatted)

        valid_url = b'https://release-assets.githubusercontent.com/a/b?token=SECRET_SIGNED_URL'
        redirect_response = response(302, b'', b'Location: ' + valid_url + b'\r\n')
        self.tls = Tls([redirect_response, response(body=b'firmware')])
        self.transport = self.make_transport(self.tls)
        try:
            self.transport.fetch_asset(
                7, 'app.mpy', _writer_throws_secret, 100)
        except TransportFailure:
            formatted = traceback.format_exc()
        self.assertNotIn('SECRET_SIGNED_URL', formatted)

        self.tls = Tls([redirect_response, response(body=b'firmware')])
        self.tls.write_error = 'SECRET_SIGNED_URL TLS failure'
        self.tls.write_error_hostname = 'release-assets.githubusercontent.com'
        self.transport = self.make_transport(self.tls)
        try:
            self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
        except TransportFailure:
            formatted = traceback.format_exc()
        self.assertNotIn('SECRET_SIGNED_URL', formatted)
        self.assertNotIn('TLS failure', formatted)

    def test_tick_wrap_uses_required_ticks_diff_and_missing_clock_api_is_rejected(self):
        with self.assertRaises(ValueError):
            PublicReleaseTransport('owner', 'repo', ROOTS, self.tls, self.select,
                                   self.sockets, object(), DNS_SERVER, lambda: True,
                                   resolver=self.resolver)
        clock = Clock(modulus=1000)
        clock.now = 950
        sockets = Sockets()
        tls = Tls([response(body=b'firmware')])

        def wrap_resolver(host, dns_server_ip, socket_module, select_module, resolver_clock,
                          service=None, deadline_ms=None):
            resolver_clock.now += 100
            return [(2, 1, 6, '', ('1.1.1.1', 443))]

        transport = PublicReleaseTransport('owner', 'repo', ROOTS, tls, Select(clock),
                                           sockets, clock, DNS_SERVER, lambda: True,
                                           resolver=wrap_resolver)
        transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
        self.assertEqual(clock.ticks_ms(), 50)
        self.assertTrue(sockets.raw[0].closed)

    def test_remaining_samples_clock_once_and_wait_fails_before_expired_poll(self):
        class SteppingClock(Clock):
            def __init__(self, values):
                super().__init__()
                self.values = iter(values)

            def ticks_ms(self):
                return next(self.values)

        clock = SteppingClock([14999])
        transport = PublicReleaseTransport(
            'owner', 'repo', ROOTS, self.tls, self.select, self.sockets,
            clock, DNS_SERVER, lambda: True, resolver=self.resolver)
        self.assertEqual(transport._remaining(0), 1)

        clock = SteppingClock([14999, 15001])
        transport = PublicReleaseTransport(
            'owner', 'repo', ROOTS, self.tls, self.select, self.sockets,
            clock, DNS_SERVER, lambda: True, resolver=self.resolver)

        class CapturingPoller:
            def __init__(self):
                self.timeouts = []

            def modify(self, sock, events):
                pass

            def poll(self, timeout):
                self.timeouts.append(timeout)
                return []

        poller = CapturingPoller()
        with self.assertRaises(TransportFailure):
            transport._wait_for(object(), 1, 0, poller, None)
        self.assertEqual(poller.timeouts, [])

    def test_invalid_or_backwards_ticks_fail_closed(self):
        class BadClock(Clock):
            def __init__(self, current, difference):
                super().__init__()
                self.current = current
                self.difference = difference

            def ticks_ms(self):
                return self.current

            def ticks_diff(self, current, previous):
                if isinstance(self.difference, Exception):
                    raise self.difference
                return self.difference

        for current, difference in ((1, -1), (1.5, 1), (1, 1.5), (1, ValueError())):
            with self.subTest(current=current, difference=difference):
                clock = BadClock(current, difference)
                transport = PublicReleaseTransport(
                    'owner', 'repo', ROOTS, self.tls, self.select, self.sockets,
                    clock, DNS_SERVER, lambda: True, resolver=self.resolver)
                with self.assertRaises(TransportFailure):
                    transport._remaining(0)

    def test_injected_transport_failures_are_redacted_at_public_boundary(self):
        for source in ('service', 'tls'):
            self.sockets = Sockets()
            self.tls = Tls([response(body=b'firmware')])
            self.transport = self.make_transport(self.tls)
            try:
                if source == 'service':
                    self.transport.fetch_asset(
                        7, 'app.mpy', lambda piece: None, 100,
                        service=lambda: (_ for _ in ()).throw(
                            TransportFailure(TEST_SECRET)))
                else:
                    def raise_secret(*args, **kwargs):
                        raise TransportFailure(TEST_SECRET + '?token=opaque')
                    self.tls.SSLContext = raise_secret
                    self.transport.fetch_asset(7, 'app.mpy', lambda piece: None, 100)
            except TransportFailure as error:
                formatted = traceback.format_exc()
                self.assertEqual(str(error), '')
            self.assertNotIn(TEST_SECRET, formatted)
            self.assertTrue(self.sockets.raw[0].closed)

    def test_rejects_untrusted_asset_names_and_oversized_limit_before_dns(self):
        for asset, limit in (('../app.mpy', 100), ('app.mpy', 524289)):
            with self.assertRaises(TransportFailure):
                self.transport.fetch_asset(7, asset, lambda piece: None, limit)
        self.assertEqual(self.resolutions, [])

    def _release(self, release_id, tag, assets=None, draft=False, prerelease=False):
        return {
            'id': release_id,
            'tag_name': tag,
            'draft': draft,
            'prerelease': prerelease,
            'assets': assets or [],
            'body': 'ignored metadata',
        }

    def _listing_response(self, body, status=200, extra=b''):
        return (b'HTTP/1.1 ' + str(status).encode() + b' Test\r\nContent-Length: ' +
                str(len(body)).encode() + b'\r\nContent-Type: application/json; charset=utf-8\r\n' +
                extra + b'\r\n' + body)

    def test_fetch_page_normalizes_mixed_android_and_pico_metadata(self):
        android_assets = [
            {'id': index + 1, 'name': 'android-%d.apk' % index, 'size': index}
            for index in range(25)
        ]
        pico_assets = [{'id': 81, 'name': 'manifest.json', 'size': 128}]
        listing = [self._release(10, 'android-v1', android_assets),
                   self._release(11, 'pico-7', pico_assets)]
        self.tls = Tls([self._listing_response(json.dumps(listing).encode())])
        self.transport = self.make_transport(self.tls)
        releases = self.transport.fetch_page(2)
        self.assertEqual(releases, [
            {'id': 10, 'tag_name': 'android-v1', 'draft': False,
             'prerelease': False, 'assets': []},
            {'id': 11, 'tag_name': 'pico-7', 'draft': False,
             'prerelease': False, 'assets': pico_assets},
        ])
        request = bytes(self.tls.wrapped[0].request)
        self.assertIn(b'GET /repos/owner/repo/releases?per_page=20&page=2 HTTP/1.1', request)
        self.assertIn(b'Host: api.github.com\r\n', request)
        self.assertIn(b'Accept: application/vnd.github+json\r\n', request)
        self.assertIn(b'X-GitHub-Api-Version: 2022-11-28\r\n', request)
        self.assertIn(b'Accept-Encoding: identity\r\n', request)
        for forbidden in (b'Authorization:', b'Cookie:', b'Referer:',
                          b'Proxy-Authorization:'):
            self.assertNotIn(forbidden, request)
        self.assertTrue(self.sockets.raw[0].closed)

    def test_fetch_page_walks_numeric_pages_and_selector_scans_full_then_empty(self):
        releases = [self._release(100 + index, 'android-%d' % index)
                    for index in range(20)]
        releases[3] = self._release(
            103, 'pico-7', [{'id': 900, 'name': 'manifest.json', 'size': 128},
                            {'id': 901, 'name': 'manifest.sig', 'size': 64}])
        self.tls = Tls([
            self._listing_response(json.dumps(releases).encode()),
            self._listing_response(b'[]'),
        ])
        self.transport = self.make_transport(self.tls)
        admitted = []

        def admit(release, tag_id, applied_id, failed_high_water):
            admitted.append(tag_id)
            return tag_id

        selected = select_signed_release(
            self.transport.fetch_page, admit, None, None)
        self.assertEqual(selected, 7)
        self.assertEqual(admitted, [7])
        self.assertEqual(len(self.tls.wrapped), 2)
        self.assertIn(b'page=1', bytes(self.tls.wrapped[0].request))
        self.assertIn(b'page=2', bytes(self.tls.wrapped[1].request))

    def test_fetch_page_fails_closed_on_bad_framing_status_and_json(self):
        valid = json.dumps([self._release(1, 'pico-1')]).encode()
        cases = (
            self._listing_response(valid).replace(b'application/json', b'text/plain'),
            self._listing_response(valid, extra=b'Content-Type: text/plain\r\n'),
            self._listing_response(valid, extra=b'Content-Length: %d\r\n' % len(valid)),
            self._listing_response(b'{malformed ' + TEST_SECRET.encode()),
            self._listing_response(valid[:-1]),
            self._listing_response(valid, extra=b'Transfer-Encoding: chunked\r\n'),
            b'HTTP/1.1 302 Found\r\nLocation: https://api.github.com/?token=' +
            TEST_SECRET.encode() + b'\r\nContent-Length: 0\r\n\r\n',
            b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n',
            b'HTTP/1.1 429 Rate Limited\r\nContent-Length: 0\r\n\r\n',
        )
        for fixture in cases:
            with self.subTest(response=fixture[:100]):
                self.sockets = Sockets()
                self.tls = Tls([fixture])
                self.transport = self.make_transport(self.tls)
                try:
                    self.transport.fetch_page(1)
                except TransportFailure:
                    formatted = traceback.format_exc()
                else:
                    self.fail('invalid listing response was accepted')
                self.assertNotIn(TEST_SECRET, formatted)
                self.assertTrue(self.sockets.raw[0].closed)

    def test_fetch_page_rejects_oversized_body_and_invalid_metadata(self):
        oversized = b'[' + b' ' * (131072 + 1) + b']'
        invalid_pages = (
            [self._release(True, 'pico-1')],
            [self._release(1, 'pico-1', [{'id': 0, 'name': 'x', 'size': 1}])],
            [self._release(1, 'pico-1', [{'id': 1, 'name': 'x', 'size': -1}])],
            [self._release(1, 'pico-1', [{'id': 1, 'name': 'x' * 256, 'size': 1}])],
            [self._release(1, 'pico-1', [
                {'id': index + 1, 'name': 'x', 'size': 0} for index in range(17)])],
            [self._release(1, 'pico-1') for unused_index in range(21)],
        )
        samples = [self._listing_response(oversized)] + [
            self._listing_response(json.dumps(page).encode()) for page in invalid_pages]
        for fixture in samples:
            with self.subTest(length=len(fixture)):
                self.sockets = Sockets()
                self.tls = Tls([fixture])
                self.transport = self.make_transport(self.tls)
                with self.assertRaises(TransportFailure):
                    self.transport.fetch_page(1)
                self.assertTrue(self.sockets.raw[0].closed)

    def test_fetch_page_rejects_duplicate_decoded_keys_everywhere(self):
        valid_asset = '"id":9,"name":"manifest.json","size":1'
        valid_release = ('"id":1,"tag_name":"pico-1","draft":false,'
                         '"prerelease":false,"assets":[' + '{' + valid_asset + '}]')
        duplicate_samples = (
            '[' + valid_release.replace('"id":1', '"id":1,"id":2') + ']',
            '[' + valid_release.replace('"tag_name":"pico-1"',
                                        '"tag_name":"pico-1","tag_name":"android-v5"') + ']',
            '[' + valid_release.replace('"draft":false', '"draft":false,"draft":true') + ']',
            '[' + valid_release.replace('"prerelease":false',
                                        '"prerelease":false,"prerelease":true') + ']',
            '[{"id":1,"tag_name":"pico-1","draft":false,"prerelease":false,'
            '"assets":[{"id":9,"id":10,"name":"manifest.json","size":1}]}]',
            '[{"id":1,"tag_name":"pico-1","draft":false,"prerelease":false,'
            '"assets":[{"id":9,"name":"manifest.json","name":"other","size":1}]}]',
            '[{"id":1,"tag_name":"pico-1","draft":false,"prerelease":false,'
            '"assets":[{"id":9,"name":"manifest.json","size":1,"size":2}]}]',
            '[{"id":1,"tag_name":"pico-1","draft":false,"prerelease":false,'
            '"assets":[],"tag_\\u006eame":"android-v5"}]',
            '[{"id":1,"tag_name":"android-v1","draft":false,"prerelease":false,'
            '"assets":[{"id":9,"name":"a","size":1,"uploader":{"login":"a",'
            '"login":"b"}}]}]',
        )
        for raw in duplicate_samples:
            with self.subTest(raw=raw[:80]):
                self.sockets = Sockets()
                self.tls = Tls([self._listing_response(raw.encode())])
                self.transport = self.make_transport(self.tls)
                with self.assertRaises(TransportFailure):
                    self.transport.fetch_page(1)

    def test_fetch_page_handles_expanded_github_objects_and_ignores_quoted_duplicates(self):
        release = self._release(1, 'android-v1', [
            {'id': index + 1, 'name': 'asset-%d' % index, 'size': index}
            for index in range(25)])
        release['body'] = '"tag_name":"android-v5" ' + 'd' * 3000
        release['html_url'] = 'https://example.invalid/release'
        release['target_commitish'] = 'main'
        release['created_at'] = '2026-01-01T00:00:00Z'
        release['published_at'] = '2026-01-01T00:00:00Z'
        release['author'] = {'login': 'owner', 'id': 1, 'url': 'x'}
        release['assets'][0]['uploader'] = {'login': 'owner', 'id': 1}
        raw = json.dumps([release], separators=(',', ':')).encode()
        self.tls = Tls([self._listing_response(raw)])
        self.transport = self.make_transport(self.tls)
        result = self.transport.fetch_page(1)
        self.assertEqual(len(result[0]['assets']), 0)
        self.assertEqual(result[0]['tag_name'], 'android-v1')

    def test_fetch_page_duplicate_keys_across_objects_and_trailing_garbage(self):
        one = '{"id":1,"tag_name":"pico-1","draft":false,"prerelease":false,"assets":[]}'
        two = '{"id":2,"tag_name":"pico-2","draft":false,"prerelease":false,"assets":[]}'
        for raw, accepted in (('[' + one + ',' + two + ']', True),
                              ('[' + one + '] false', False),
                              ('[' + one + '] {}', False)):
            self.sockets = Sockets()
            self.tls = Tls([self._listing_response(raw.encode())])
            self.transport = self.make_transport(self.tls)
            if accepted:
                self.assertEqual(len(self.transport.fetch_page(1)), 2)
            else:
                with self.assertRaises(TransportFailure):
                    self.transport.fetch_page(1)

    def test_fetch_page_parse_service_abort_exception_and_deadline_are_redacted(self):
        raw = json.dumps([self._release(1, 'pico-1')]).encode()
        for behavior in ('false', 'throws', 'deadline'):
            self.sockets = Sockets()
            self.tls = Tls([self._listing_response(raw)])
            self.transport = self.make_transport(self.tls)
            calls = [0]

            def service():
                calls[0] += 1
                # Network wait checkpoints occur before this point; stop during
                # parsing, after the bounded body has been received.
                if calls[0] >= 4:
                    if behavior == 'throws':
                        raise RuntimeError(TEST_SECRET)
                    if behavior == 'deadline':
                        self.clock.now = 15000
                    if behavior == 'false':
                        return False

            with self.assertRaises(TransportFailure) as caught:
                self.transport.fetch_page(1, service=service)
            self.assertEqual(str(caught.exception), '')
            self.assertNotIn(TEST_SECRET, traceback.format_exc())

    def test_fetch_page_validates_fixed_page_parameters_and_time_before_network(self):
        for page, per_page in ((True, 20), (0, 20), (33, 20), (1, True), (1, 19)):
            with self.subTest(page=page, per_page=per_page):
                with self.assertRaises(TransportFailure):
                    self.transport.fetch_page(page, per_page)
        transport = self.make_transport(self.tls, usable=lambda: False)
        with self.assertRaises(TransportFailure):
            transport.fetch_page(1)
        self.assertEqual(self.resolutions, [])
        self.assertEqual(self.sockets.raw, [])

    def test_selector_page_cap_remains_fail_closed(self):
        calls = []

        def full_page(page_number, per_page):
            calls.append((page_number, per_page))
            return [self._release((page_number - 1) * 20 + index + 1,
                                  'android-%d-%d' % (page_number, index))
                    for index in range(20)]

        with self.assertRaises(DiscoveryIncomplete):
            select_signed_release(full_page, lambda *args: None, None, None,
                                  max_pages=3)
        self.assertEqual(calls, [(1, 20), (2, 20), (3, 20)])


if __name__ == '__main__':
    unittest.main()
