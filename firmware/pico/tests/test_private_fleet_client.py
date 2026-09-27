import hashlib
import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

import private_fleet_client
from native_https import NativeHttpsTransport, TransportFailure
from private_fleet_client import PrivateFleetClient
from test_native_https import (
    Clock, DNS_SERVER, ROOTS, Select, Sockets, Tls, TlsContext, fake_resolver,
)


OWNER, REPO, REMOTE_PATH, BRANCH = 'farmctl', 'private-fleet', 'config/fleet.json', 'main'
READ_TOKEN = 'private-read-token'
GIST_TOKEN = 'gist-write-token'


class RandomSequence:
    def __init__(self, values=None):
        self.values = list(values or [bytes(range(12))])

    def __call__(self, size):
        value = self.values.pop(0) if len(self.values) > 1 else self.values[0]
        return value[:size]


class PrivateFleetClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = self.temp.name
        self.clock = Clock()
        self.content = b'F' * 65536
        self.tls = Tls(self.response(self.content))
        self.sockets = Sockets()
        self.transport = NativeHttpsTransport(
            (), READ_TOKEN, ROOTS, self.tls, Select(self.clock), self.sockets,
            self.clock, DNS_SERVER, resolver=fake_resolver,
            private_contents=(OWNER, REPO, REMOTE_PATH, BRANCH))
        self.client = PrivateFleetClient(self.transport, self.directory,
                                         random_bytes=RandomSequence(),
                                         time_is_trusted=lambda: True)
        self.applied = os.path.join(self.directory, 'fleet.json')
        with open(self.applied, 'wb') as target:
            target.write(b'last-known-good')

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def response(body, headers=b''):
        return (b'HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n' +
                b'Content-Length: ' + str(len(body)).encode() + b'\r\n' + headers +
                b'\r\n' + body)

    def test_streams_maximum_body_and_preserves_applied_file(self):
        candidate, result = self.client.fetch_to_stage(self.applied)
        self.assertEqual(result, (65536, hashlib.sha256(self.content).hexdigest()))
        self.assertTrue(candidate.endswith('.candidate'))
        with open(candidate, 'rb') as source:
            self.assertEqual(source.read(), self.content)
        with open(self.applied, 'rb') as source:
            self.assertEqual(source.read(), b'last-known-good')
        request = bytes(self.tls.wrapped.request)
        self.assertIn(b'GET /repos/farmctl/private-fleet/contents/config/fleet.json?ref=main HTTP/1.1', request)
        self.assertIn(b'Accept: application/vnd.github.raw+json', request)
        self.assertIn(b'Accept-Encoding: identity', request)
        self.assertIn(b'Connection: close', request)
        self.assertEqual(request.count(READ_TOKEN.encode()), 1)
        self.assertNotIn(GIST_TOKEN.encode(), request)
        self.assertTrue(self.tls.wrapped.closed)
        self.assertTrue(self.sockets.raw.closed)

    def test_rejects_body_over_limit_and_deletes_only_partial_candidate(self):
        body = b'X' * 65537
        self.tls.response = self.response(body)
        with self.assertRaises(TransportFailure):
            self.client.fetch_to_stage(self.applied)
        self.assertEqual(self._candidates(), [])
        with open(self.applied, 'rb') as source:
            self.assertEqual(source.read(), b'last-known-good')

    def test_rejects_missing_or_duplicate_content_length(self):
        for headers in (b'', b'Content-Length: 1\r\n'):
            with self.subTest(headers=headers):
                self.tls.response = (b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n' +
                                     headers + b'\r\n{}')
                if headers:
                    # The helper's generated length is intentionally duplicated.
                    self.tls.response = self.response(b'{}', headers)
                with self.assertRaises(TransportFailure):
                    self.client.fetch_to_stage(self.applied)
                self.assertEqual(self._candidates(), [])

    def test_truncated_body_fails_and_removes_partial(self):
        self.tls.response = self.response(b'{}')[:-1]
        with self.assertRaises(TransportFailure):
            self.client.fetch_to_stage(self.applied)
        self.assertEqual(self._candidates(), [])

    def test_rejects_wrong_status_redirect_and_content_type(self):
        for response in (
                b'HTTP/1.1 302 Found\r\nContent-Length: 0\r\nLocation: https://evil.invalid/\r\n\r\n',
                b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n',
                b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\n\r\n{}'):
            self.tls.response = response
            with self.assertRaises(Exception):
                self.client.fetch_to_stage(self.applied)
            self.assertEqual(self._candidates(), [])

    def test_validates_trusted_stage_directory_without_os_path(self):
        original_os = private_fleet_client.os
        no_path = SimpleNamespace(urandom=original_os.urandom, remove=original_os.remove)
        with mock.patch.object(private_fleet_client, 'os', no_path):
            client = PrivateFleetClient(self.transport, self.directory,
                                        random_bytes=RandomSequence(),
                                        time_is_trusted=lambda: True)
            candidate, _ = client.fetch_to_stage(self.applied)
            self.assertTrue(candidate.endswith('.candidate'))
        for path in ('relative/stage', '/tmp/../unsafe', '/tmp/./unsafe', '/tmp//unsafe', '/tmp/\x00bad'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                PrivateFleetClient(self.transport, path)

    def test_collision_retries_without_overwriting_existing_candidate(self):
        collision_random = bytes(range(12))
        next_random = bytes(range(12, 24))
        collision = os.path.join(self.directory,
                                 'fleet-' + collision_random.hex() + '.candidate')
        with open(collision, 'wb') as target:
            target.write(b'unrelated preexisting file')
        client = PrivateFleetClient(
            self.transport, self.directory,
            random_bytes=RandomSequence([collision_random, next_random]),
            time_is_trusted=lambda: True)
        candidate, result = client.fetch_to_stage(self.applied)
        self.assertNotEqual(candidate, collision)
        self.assertEqual(result[0], 65536)
        with open(collision, 'rb') as source:
            self.assertEqual(source.read(), b'unrelated preexisting file')

    def test_write_failure_removes_only_created_partial_candidate(self):
        real_open = open
        writes = [0]

        class FailingFile:
            def __init__(self, wrapped):
                self.wrapped = wrapped

            def write(self, piece):
                writes[0] += 1
                if writes[0] > 1:
                    raise OSError('private path and token must not leak')
                return self.wrapped.write(piece)

            def flush(self):
                self.wrapped.flush()

            def close(self):
                self.wrapped.close()

        def failing_open(path, mode):
            return FailingFile(real_open(path, mode))

        client = PrivateFleetClient(self.transport, self.directory,
                                    random_bytes=RandomSequence(),
                                    time_is_trusted=lambda: True)
        with mock.patch.object(private_fleet_client, 'open', failing_open, create=True):
            with self.assertRaises(TransportFailure) as caught:
                client.fetch_to_stage(self.applied)
        self.assertNotIn('private path', str(caught.exception))
        self.assertEqual(self._candidates(), [])

    def test_private_token_capability_is_separate_from_gist_write(self):
        with self.assertRaises(ValueError):
            NativeHttpsTransport(("01234567" * 4,), GIST_TOKEN, ROOTS,
                                 self.tls, Select(self.clock), self.sockets,
                                 self.clock, DNS_SERVER, resolver=fake_resolver,
                                 private_contents=(OWNER, REPO, REMOTE_PATH, BRANCH))
        for unsafe in ('../fleet.json', 'config//fleet.json', 'config/fleet.json?x=1'):
            with self.subTest(path=unsafe), self.assertRaises(ValueError):
                NativeHttpsTransport((), READ_TOKEN, ROOTS, self.tls,
                                     Select(self.clock), self.sockets, self.clock,
                                     DNS_SERVER, resolver=fake_resolver,
                                     private_contents=(OWNER, REPO, unsafe, BRANCH))

    def test_tick_wrap_and_stalled_stream_timeout_clean_partial(self):
        clock = Clock(modulus=1000)
        clock.now = 950
        stalled = Tls(self.response(self.content), stalled=True)
        transport = NativeHttpsTransport(
            (), READ_TOKEN, ROOTS, stalled, Select(clock), Sockets(), clock,
            DNS_SERVER, resolver=fake_resolver,
            timeout_ms=100, private_contents=(OWNER, REPO, REMOTE_PATH, BRANCH))
        client = PrivateFleetClient(transport, self.directory, random_bytes=RandomSequence(),
                                    time_is_trusted=lambda: True)
        with self.assertRaises(TransportFailure):
            client.fetch_to_stage(self.applied)
        self.assertEqual(self._candidates(), [])

    def test_continuous_trickle_still_obeys_one_total_deadline(self):
        transport = NativeHttpsTransport(
            (), READ_TOKEN, ROOTS, self.tls, Select(self.clock), Sockets(), self.clock,
            DNS_SERVER, resolver=fake_resolver,
            timeout_ms=10, private_contents=(OWNER, REPO, REMOTE_PATH, BRANCH))
        client = PrivateFleetClient(transport, self.directory, random_bytes=RandomSequence(),
                                    time_is_trusted=lambda: True)

        def service():
            self.clock.now += 1

        with self.assertRaises(TransportFailure):
            client.fetch_to_stage(self.applied, service=service)
        self.assertEqual(self._candidates(), [])

    def test_requires_trusted_time_before_dns_or_candidate_creation(self):
        for trusted in (None, lambda: False,
                        lambda: (_ for _ in ()).throw(RuntimeError('secret-path-token'))):
            client = PrivateFleetClient(self.transport, self.directory,
                                        random_bytes=RandomSequence(),
                                        time_is_trusted=trusted)
            with self.assertRaises(TransportFailure) as caught:
                client.fetch_to_stage(self.applied)
            self.assertNotIn('secret-path-token', str(caught.exception))
            self.assertEqual(self.sockets.addresses, [])
            self.assertEqual(self._candidates(), [])

    def test_digest_api_without_hexdigest_and_digest_failure_cleanup(self):
        real_sha256 = hashlib.sha256

        class DigestOnly:
            def __init__(self, fail=False):
                self.fail = fail
                self.value = bytearray()

            def update(self, piece):
                self.value.extend(piece)

            def digest(self):
                if self.fail:
                    raise RuntimeError('secret hash detail')
                return real_sha256(bytes(self.value)).digest()

        with mock.patch.object(private_fleet_client.hashlib, 'sha256',
                               side_effect=lambda: DigestOnly()):
            candidate, result = self.client.fetch_to_stage(self.applied)
        self.assertEqual(result, (len(self.content), real_sha256(self.content).hexdigest()))
        os.remove(candidate)
        with mock.patch.object(private_fleet_client.hashlib, 'sha256',
                               side_effect=lambda: DigestOnly(fail=True)):
            with self.assertRaises(TransportFailure) as caught:
                self.client.fetch_to_stage(self.applied)
        self.assertNotIn('secret hash detail', str(caught.exception))
        self.assertEqual(self._candidates(), [])
        with open(self.applied, 'rb') as source:
            self.assertEqual(source.read(), b'last-known-good')

    def test_unexpected_transport_errors_are_redacted_and_partial_is_removed(self):
        original = self.transport.get_private_contents

        def write_then_fail(writer, service=None):
            writer(b'partial')
            raise RuntimeError('secret-token-and-path')

        self.transport.get_private_contents = write_then_fail
        try:
            with self.assertRaises(TransportFailure) as caught:
                self.client.fetch_to_stage(self.applied)
        finally:
            self.transport.get_private_contents = original
        self.assertNotIn('secret-token-and-path', str(caught.exception))
        self.assertIsNone(caught.exception.__cause__)
        self.assertEqual(self._candidates(), [])

    def test_deadline_is_rechecked_after_final_header_read_and_writer(self):
        original_wrap = TlsContext.wrap_socket

        def advancing_header_read(context, raw_sock, server_hostname,
                                  do_handshake_on_connect):
            tls_sock = original_wrap(context, raw_sock, server_hostname,
                                     do_handshake_on_connect)
            original_read = tls_sock.read

            def read_and_expire(size):
                piece = original_read(size)
                self.clock.now += 10
                return piece

            tls_sock.read = read_and_expire
            return tls_sock

        transport = NativeHttpsTransport(
            (), READ_TOKEN, ROOTS, self.tls, Select(self.clock), Sockets(),
            self.clock, DNS_SERVER, resolver=fake_resolver, timeout_ms=10,
            private_contents=(OWNER, REPO, REMOTE_PATH, BRANCH))
        client = PrivateFleetClient(transport, self.directory,
                                    random_bytes=RandomSequence(),
                                    time_is_trusted=lambda: True)
        with mock.patch.object(TlsContext, 'wrap_socket', advancing_header_read):
            with self.assertRaises(TransportFailure):
                client.fetch_to_stage(self.applied)
        self.assertEqual(self._candidates(), [])

        self.clock.now = 0
        transport = NativeHttpsTransport(
            (), READ_TOKEN, ROOTS, self.tls, Select(self.clock), Sockets(),
            self.clock, DNS_SERVER, resolver=fake_resolver, timeout_ms=10,
            private_contents=(OWNER, REPO, REMOTE_PATH, BRANCH))
        client = PrivateFleetClient(transport, self.directory,
                                    random_bytes=RandomSequence(),
                                    time_is_trusted=lambda: True)
        real_open = open

        class SlowWriter:
            def __init__(self, wrapped):
                self.wrapped = wrapped

            def write(self, piece):
                result = self.wrapped.write(piece)
                self.clock.now += 10
                return result

            def flush(self):
                self.wrapped.flush()

            def close(self):
                self.wrapped.close()

        def slow_open(path, mode):
            return SlowWriter(real_open(path, mode))

        with mock.patch.object(private_fleet_client, 'open', slow_open, create=True):
            with self.assertRaises(TransportFailure):
                client.fetch_to_stage(self.applied)
        self.assertEqual(self._candidates(), [])

    def _candidates(self):
        return [name for name in os.listdir(self.directory) if name.endswith('.candidate')]


if __name__ == '__main__':
    unittest.main()
