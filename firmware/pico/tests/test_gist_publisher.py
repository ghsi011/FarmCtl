import errno
import json
import tempfile
import traceback
import unittest
from unittest import mock

from gist_publisher import (
    DIAGNOSTICS_FILENAME, GistPublisher, GistPublishProofFailure, MAX_REQUEST_BYTES,
    THERMOSTAT_FILENAME,
)

TEMPERATURE_ID = '01234567' * 4
DIAGNOSTICS_ID = '89abcdef' * 4
TOKEN = 'synthetic-test-token'
ROOTS = b'-----BEGIN CERTIFICATE-----synthetic public CA-----END CERTIFICATE-----'
DNS_SERVER = '192.0.2.53'


def fake_resolver(host, dns_server_ip, socket_module, select_module, clock,
                  service=None, deadline_ms=None):
    socket_module.addresses.append((host, 443))
    return [(2, 1, 0, '', ('192.0.2.1', 443))]


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
            self.select, self.sockets, self.clock, DNS_SERVER,
            resolver=fake_resolver, time_is_trusted=lambda: True)
        self.payload = {'files': {THERMOSTAT_FILENAME: {'content': '20.00°C\nSample: b:1'}}}

    def _fresh(self, response=None, **tls_options):
        self.tls = FakeTls(self.clock, self.response if response is None else response, **tls_options)
        self.select = FakeSelect(self.clock)
        self.sockets = FakeSocketModule()
        return GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                             self.tls, self.select, self.sockets, self.clock,
                             DNS_SERVER, resolver=fake_resolver,
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

    def test_publisher_readback_uses_only_registered_fixed_api_get(self):
        document = {'id': TEMPERATURE_ID, 'truncated': False,
                    'files': {THERMOSTAT_FILENAME: {'content': '20.00°C\nSample: x:1'}}}
        self.tls.response = (b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ' +
                             str(len(json.dumps(document).encode())).encode() + b'\r\n\r\n' +
                             json.dumps(document).encode())
        self.assertTrue(self.publisher.confirm_file(
            TEMPERATURE_ID, THERMOSTAT_FILENAME, '20.00°C\nSample: x:1'))
        request = bytes(self.tls.wrapped.request)
        self.assertIn(b'GET /gists/' + TEMPERATURE_ID.encode(), request)
        self.assertIn(b'Host: api.github.com\r\n', request)
        self.assertIn(b'Authorization: Bearer ' + TOKEN.encode(), request)
        self.assertTrue(self.tls.wrapped.closed)

    def test_distinct_gists_and_payload_routed_to_matching_destination(self):
        diagnostics = {'files': {DIAGNOSTICS_FILENAME: {'content': '{}'}}}
        self.assertTrue(self.publisher.publish_diagnostics(diagnostics))
        self.assertIn(b'PATCH /gists/' + DIAGNOSTICS_ID.encode(), self.tls.wrapped.request)
        self.assertNotIn(TEMPERATURE_ID.encode(), self.tls.wrapped.request)
        with self.assertRaises(ValueError):
            GistPublisher(TEMPERATURE_ID, TEMPERATURE_ID, TOKEN, ROOTS, self.tls,
                          self.select, self.sockets, self.clock, DNS_SERVER,
                          resolver=fake_resolver, time_is_trusted=lambda: True)

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
                                  DNS_SERVER, resolver=fake_resolver,
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

    def test_hintless_403_applies_shared_minimum_cooldown(self):
        publisher = self._fresh(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
        self.assertFalse(publisher.publish_temperature(self.payload))
        diagnostics = {'files': {DIAGNOSTICS_FILENAME: {'content': '{}'}}}
        self.assertFalse(publisher.publish_diagnostics(diagnostics))
        self.assertEqual(len(self.sockets.addresses), 1)
        self.clock.now += 60000
        publisher.tls.response = self.response
        self.assertTrue(publisher.publish_diagnostics(diagnostics))

    def test_403_longer_retry_hint_and_tick_wrap_are_shared(self):
        clock = FakeClock(modulus=1000000)
        clock.now = 999950
        tls = FakeTls(clock, b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nRetry-After: 120\r\n\r\n')
        sockets = FakeSocketModule()
        publisher = GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                                  tls, FakeSelect(clock), sockets, clock, DNS_SERVER,
                                  resolver=fake_resolver, time_is_trusted=lambda: True)
        self.assertFalse(publisher.publish_temperature(self.payload))
        diagnostics = {'files': {DIAGNOSTICS_FILENAME: {'content': '{}'}}}
        self.assertFalse(publisher.publish_diagnostics(diagnostics))
        self.assertEqual(len(sockets.addresses), 1)
        clock.now += 119999
        self.assertFalse(publisher.publish_diagnostics(diagnostics))
        self.assertEqual(len(sockets.addresses), 1)
        clock.now += 1
        tls.response = self.response
        self.assertTrue(publisher.publish_diagnostics(diagnostics))

    def test_supervisor_service_reaches_dns_and_poll_and_failure_is_redacted(self):
        serviced = []

        def resolver(host, dns_server_ip, socket_module, select_module, clock,
                     service=None, deadline_ms=None):
            self.assertIs(service, callback)
            service()
            return [(2, 1, 0, '', ('192.0.2.1', 443))]

        def callback():
            serviced.append(self.clock.now)

        publisher = GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                                  self.tls, self.select, self.sockets, self.clock,
                                  DNS_SERVER, resolver=resolver,
                                  time_is_trusted=lambda: True, service=callback)
        self.assertTrue(publisher.publish_temperature(self.payload))
        self.assertGreaterEqual(len(serviced), 3)

        broken = self._fresh(self.response, stall_write=True)
        failures = []

        def secret_failure():
            failures.append(True)
            raise RuntimeError('private-secret-detail')

        broken.service = secret_failure
        self.assertFalse(broken.publish_temperature(self.payload))
        self.assertTrue(failures)
        self.assertTrue(self.sockets.raw.closed)
        self.assertTrue(self.tls.wrapped.closed)

    def test_expired_shared_cooldown_is_cleared_before_later_tick_wrap(self):
        clock = FakeClock(modulus=1000000)
        tls = FakeTls(clock, b'HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n')
        select, sockets = FakeSelect(clock), FakeSocketModule()
        publisher = GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                                  tls, select, sockets, clock,
                                  DNS_SERVER, resolver=fake_resolver,
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
        self.assertEqual(publisher._server_not_before, 60000)

    def test_bounded_stall_cleans_up_sockets_and_backoff_avoids_tight_retry(self):
        publisher = self._fresh(self.response, stall_write=True)
        self.assertFalse(publisher.publish_temperature(self.payload))
        self.assertTrue(self.sockets.raw.closed)
        self.assertTrue(self.tls.wrapped.closed)
        self.assertFalse(publisher.publish_temperature(self.payload))
        self.assertEqual(len(self.sockets.addresses), 1)

    def test_bounded_dns_timeout_fails_before_socket_or_token_write(self):
        def slow_resolver(host, dns_server_ip, socket_module, select_module, clock,
                          service=None, deadline_ms=None):
            clock.now += deadline_ms
            return [(2, 1, 0, '', ('192.0.2.1', 443))]

        publisher = GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS,
                                  self.tls, self.select, self.sockets, self.clock,
                                  DNS_SERVER,
                                  resolver=slow_resolver, time_is_trusted=lambda: True)
        self.assertFalse(publisher.publish_temperature(self.payload))
        self.assertIsNone(self.sockets.raw)
        self.assertIsNone(self.tls.context)

    def test_100_event_payload_fits_request_cap(self):
        content = '{"events":[' + ','.join('{"id":"boot:%d","code":"failure","count":1}' % n for n in range(100)) + ']}'
        payload = {'files': {DIAGNOSTICS_FILENAME: {'content': content}}}
        self.assertTrue(self.publisher.publish_diagnostics(payload))
        self.assertLessEqual(len(self.tls.wrapped.request), MAX_REQUEST_BYTES)

    def test_close_scrubs_in_memory_token(self):
        self.publisher.close()
        self.assertEqual(bytes(self.publisher._token), b'\x00' * len(TOKEN))

    def test_readback_initialization_failure_scrubs_transport_and_redacts_traceback(self):
        import gist_publisher

        captured = []

        def fail_readback(transport, *args):
            captured.append(transport)
            raise MemoryError('SYNTHETIC_SECRET')

        try:
            with mock.patch.object(gist_publisher, 'GistReadback', fail_readback):
                GistPublisher(TEMPERATURE_ID, DIAGNOSTICS_ID, TOKEN, ROOTS, self.tls,
                              self.select, self.sockets, self.clock, DNS_SERVER,
                              resolver=fake_resolver, time_is_trusted=lambda: True)
        except RuntimeError as error:
            self.assertEqual(str(error), 'unable to initialize Gist publisher')
            self.assertNotIn('SYNTHETIC_SECRET', ''.join(traceback.format_exception(error)))
            self.assertIsNone(error.__cause__)
        else:
            self.fail('expected safe publisher initialization failure')
        self.assertEqual(len(captured), 1)
        self.assertEqual(bytes(captured[0].token), b'\x00' * len(TOKEN))

    def test_candidate_constructor_scrubs_read_transport_after_publisher_failure(self):
        import config_proof_io
        from config_payload import read_device_payload

        device = {
            'change_id': 'abcdefab-1234-4234-8234-123456789abc',
            'logical_id': 'unit-one',
            'wifi_profiles': [{'profile_id': 'main', 'ssid': 'farm', 'password': 'wifi-password'}],
            'config_read_credential': 'read-secret',
            'temperature_gist_id': TEMPERATURE_ID,
            'diagnostics_gist_id': DIAGNOSTICS_ID,
            'gist_write_credential': TOKEN,
            'sample_interval_seconds': 30,
            'publication_interval_seconds': 60,
        }
        candidate_data = {
            'schema_version': 1,
            'fleet_revision': '12345678-1234-4234-8234-123456789abc',
            'device_ref': 'unit-01',
            'device': device,
        }
        candidate = read_device_payload(
            json.dumps(candidate_data, separators=(',', ':')).encode(), 'unit-01')
        original_transport = config_proof_io.NativeHttpsTransport
        read_transports = []

        def capture_read_transport(*args, **kwargs):
            transport = original_transport(*args, **kwargs)
            read_transports.append(transport)
            return transport

        with tempfile.TemporaryDirectory() as scratch:
            with mock.patch.object(config_proof_io, 'NativeHttpsTransport',
                                   capture_read_transport), \
                    mock.patch('gist_publisher.GistReadback',
                               side_effect=MemoryError('SYNTHETIC_SECRET')):
                with self.assertRaises(ValueError) as caught:
                    config_proof_io.CandidateProofIO(
                        candidate, 'unit-01',
                        ('fleet-owner', 'private-repo', 'fleet.json', 'main'),
                        ROOTS, self.tls, self.select, self.sockets, self.clock,
                        DNS_SERVER, lambda: True, scratch, lambda count: b'x' * count,
                        resolver=fake_resolver)
        self.assertEqual(len(read_transports), 1)
        self.assertEqual(bytes(read_transports[0].token), b'\x00' * len('read-secret'))
        self.assertNotIn('SYNTHETIC_SECRET', ''.join(traceback.format_exception(caught.exception)))
        self.assertIsNone(caught.exception.__cause__)

    def test_exact_trial_patch_bypasses_backoff_and_sends_exact_registered_content(self):
        self.publisher._failed(THERMOSTAT_FILENAME)
        content = 'exact candidate °C\n'
        self.assertEqual(self.publisher.patch_exact_for_trial(THERMOSTAT_FILENAME, content), content)
        request = bytes(self.tls.wrapped.request)
        self.assertIn(b'PATCH /gists/' + TEMPERATURE_ID.encode(), request)
        self.assertIn(json.dumps({'files': {THERMOSTAT_FILENAME: {'content': content}}},
                                 separators=(',', ':')).encode(), request)
        self.assertEqual(len(self.sockets.addresses), 1)

    def test_exact_trial_patch_allows_only_registered_file_and_honors_service_override(self):
        service_calls = []
        content = '{"trial":"exact"}'
        self.assertEqual(self.publisher.patch_exact_for_trial(
            DIAGNOSTICS_FILENAME, content, service=lambda: service_calls.append(True)), content)
        self.assertIn(b'PATCH /gists/' + DIAGNOSTICS_ID.encode(), self.tls.wrapped.request)
        self.assertNotIn(TEMPERATURE_ID.encode(), self.tls.wrapped.request)
        self.assertTrue(service_calls)
        before = len(self.sockets.addresses)
        for filename, value in (('other.txt', 'x'), (THERMOSTAT_FILENAME, 'x' * 257),
                                (DIAGNOSTICS_FILENAME, 'x' * (16 * 1024 + 1))):
            with self.subTest(filename=filename), self.assertRaises(GistPublishProofFailure) as caught:
                self.publisher.patch_exact_for_trial(filename, value)
            self.assertEqual(caught.exception.kind, 'definite')
        self.assertEqual(len(self.sockets.addresses), before)

    def test_exact_trial_patch_ignores_publisher_backoff_but_requires_trusted_time_and_open_transport(self):
        self.publisher._server_not_before = 999999
        self.publisher.time_is_trusted = lambda: False
        with self.assertRaises(GistPublishProofFailure) as caught:
            self.publisher.patch_exact_for_trial(THERMOSTAT_FILENAME, 'x')
        self.assertEqual(caught.exception.kind, 'inconclusive')
        self.assertFalse(self.sockets.addresses)
        self.publisher.time_is_trusted = lambda: True
        self.publisher.close()
        with self.assertRaises(GistPublishProofFailure) as caught:
            self.publisher.patch_exact_for_trial(THERMOSTAT_FILENAME, 'x')
        self.assertEqual(caught.exception.kind, 'definite')

    def test_exact_trial_http_statuses_are_classified_and_secret_transport_errors_redacted(self):
        expected = {401: 'authentication_failed', 404: 'destination_failed',
                    422: 'destination_failed', 403: 'inconclusive', 429: 'inconclusive',
                    500: 'inconclusive', 503: 'inconclusive'}
        for status, kind in expected.items():
            with self.subTest(status=status):
                publisher = self._fresh(('HTTP/1.1 %d Status\r\nContent-Length: 0\r\n\r\n' % status).encode())
                with self.assertRaises(GistPublishProofFailure) as caught:
                    publisher.patch_exact_for_trial(THERMOSTAT_FILENAME, 'candidate')
                self.assertEqual(caught.exception.kind, kind)
        secret = 'private-secret-token-and-url'

        def fail_with_secret():
            raise RuntimeError(secret)

        self.publisher.service = fail_with_secret
        try:
            self.publisher.patch_exact_for_trial(THERMOSTAT_FILENAME, 'candidate')
        except GistPublishProofFailure as error:
            self.assertEqual(error.kind, 'inconclusive')
            self.assertNotIn(secret, ''.join(traceback.format_exception(error)))
            self.assertIsNone(error.__cause__)
        else:
            self.fail('expected redacted proof failure')

    def test_callback_supplied_proof_failure_is_fresh_and_redacted_without_retry(self):
        secret = 'SYNTHETIC_SECRET'

        def callback_proof_failure():
            try:
                raise RuntimeError(secret)
            except RuntimeError as underlying:
                raise GistPublishProofFailure('definite') from underlying

        for callback_location in ('service', 'transport'):
            with self.subTest(callback_location=callback_location):
                publisher = self._fresh()
                patch_calls = []
                if callback_location == 'service':
                    service = callback_proof_failure
                    original_patch = publisher.transport.patch_gist

                    def patch_with_callback(gist_id, body, service=None):
                        patch_calls.append((gist_id, body))
                        service()
                        return original_patch(gist_id, body, service=service)

                    publisher.transport.patch_gist = patch_with_callback
                else:
                    service = None

                    def patch_with_callback(gist_id, body, service=None):
                        patch_calls.append((gist_id, body))
                        callback_proof_failure()

                    publisher.transport.patch_gist = patch_with_callback

                try:
                    publisher.patch_exact_for_trial(
                        THERMOSTAT_FILENAME, 'candidate', service=service)
                except GistPublishProofFailure as error:
                    self.assertEqual(error.kind, 'inconclusive')
                    self.assertIsNone(error.__cause__)
                    self.assertNotIn(secret, ''.join(traceback.format_exception(error)))
                    self.assertEqual(len(patch_calls), 1)
                    self.assertEqual(publisher._backoff[THERMOSTAT_FILENAME]['failures'], 0)
                else:
                    self.fail('expected normalized proof failure')


if __name__ == '__main__':
    unittest.main()
