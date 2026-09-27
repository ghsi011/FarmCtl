import json
import unittest

from gist_readback import GistReadback, GistReadbackFailure
from native_https import HttpFailure

TEMPERATURE_ID = '01234567' * 4
DIAGNOSTICS_ID = '89abcdef' * 4


class FakeTransport:
    def __init__(self, payload=None, error=None):
        self.payload = payload
        self.error = error
        self.calls = []

    def get_gist_json(self, gist_id, writer, service=None):
        self.calls.append((gist_id, service))
        if self.error:
            raise self.error
        writer(self.payload)


def response(content='20.00°C\nSample: boot:2', gist_id=TEMPERATURE_ID,
             filename='thermostat.txt', truncated=False, files=None):
    if files is None:
        files = {filename: {'content': content, 'raw_url': 'https://ignored.invalid/raw'}}
    return json.dumps({'id': gist_id, 'truncated': truncated, 'files': files}).encode('utf-8')


class GistReadbackTests(unittest.TestCase):
    def setUp(self):
        self.transport = FakeTransport(response())
        self.readback = GistReadback(self.transport, TEMPERATURE_ID, DIAGNOSTICS_ID)

    def test_exact_utf8_content_and_current_sample_marker_confirm(self):
        expected = '20.00°C\nSample: boot:2'
        self.assertIs(self.readback.confirm_file(TEMPERATURE_ID, 'thermostat.txt', expected), True)
        self.transport.payload = response(content='21.25°C\nSample: boot:3')
        self.assertIs(self.readback.confirm_file(TEMPERATURE_ID, 'thermostat.txt',
                                                 '21.25°C\nSample: boot:3'), True)

    def test_stale_or_wrong_content_and_diagnostics_trial_id_fail_definitely(self):
        for body, filename, expected in (
                (response(content='20.00°C\nSample: boot:1'), 'thermostat.txt',
                 '20.00°C\nSample: boot:2'),
                (json.dumps({'id': DIAGNOSTICS_ID, 'truncated': False,
                             'files': {'diagnostics.json': {'content': '{"trial":"old"}'}}}).encode(),
                 'diagnostics.json', '{"trial":"trial-current"}')):
            self.transport.payload = body
            gist_id = DIAGNOSTICS_ID if filename == 'diagnostics.json' else TEMPERATURE_ID
            with self.subTest(filename=filename), self.assertRaises(GistReadbackFailure) as caught:
                self.readback.confirm_file(gist_id, filename, expected)
            self.assertEqual(caught.exception.kind, 'definite')

    def test_exact_diagnostics_trial_correlation_confirms(self):
        content = '{"trial_id":"trial-current","status":"candidate"}'
        self.transport.payload = json.dumps({
            'id': DIAGNOSTICS_ID, 'truncated': False,
            'files': {'diagnostics.json': {'content': content}},
        }).encode()
        self.assertTrue(self.readback.confirm_file(
            DIAGNOSTICS_ID, 'diagnostics.json', content))

    def test_id_filename_truncation_missing_and_malformed_content_fail_closed(self):
        invalid = (
            response(gist_id=DIAGNOSTICS_ID),
            response(filename='other.txt'),
            response(truncated=True),
            json.dumps({'id': TEMPERATURE_ID, 'files': {}}).encode(),
            json.dumps({'id': TEMPERATURE_ID, 'truncated': False,
                        'files': {'thermostat.txt': {'content': None}}}).encode(),
        )
        for body in invalid:
            self.transport.payload = body
            with self.assertRaises(GistReadbackFailure) as caught:
                self.readback.confirm_file(TEMPERATURE_ID, 'thermostat.txt',
                                           '20.00°C\nSample: boot:2')
            self.assertEqual(caught.exception.kind, 'definite')

    def test_other_files_are_ignored_and_raw_url_is_never_used(self):
        self.transport.payload = response(files={
            'thermostat.txt': {'content': 'ok', 'raw_url': 'https://evil.invalid/'},
            'other.txt': {'content': 'ignored', 'raw_url': 'https://evil.invalid/other'},
        })
        self.assertTrue(self.readback.confirm_file(TEMPERATURE_ID, 'thermostat.txt', 'ok'))
        self.assertEqual(len(self.transport.calls), 1)

    def test_capability_and_expected_size_are_restricted(self):
        with self.assertRaises(GistReadbackFailure):
            self.readback.confirm_file(DIAGNOSTICS_ID, 'thermostat.txt', 'x')
        with self.assertRaises(GistReadbackFailure):
            self.readback.confirm_file(TEMPERATURE_ID, 'other.txt', 'x')
        with self.assertRaises(GistReadbackFailure):
            self.readback.confirm_file(TEMPERATURE_ID, 'thermostat.txt', 'x' * 257)

    def test_transport_errors_are_inconclusive_and_redacted(self):
        secret = 'super-secret-token-and-response'
        self.transport.error = RuntimeError(secret)
        with self.assertRaises(GistReadbackFailure) as caught:
            self.readback.confirm_file(TEMPERATURE_ID, 'thermostat.txt', 'anything')
        self.assertEqual(caught.exception.kind, 'inconclusive')
        self.assertNotIn(secret, str(caught.exception))
        self.assertIsNone(caught.exception.__cause__)

    def test_http_statuses_have_narrow_readback_classification(self):
        expected = {401: 'authentication_failed', 404: 'destination_failed',
                    422: 'inconclusive', 403: 'inconclusive', 429: 'inconclusive',
                    500: 'inconclusive', 503: 'inconclusive'}
        for status, kind in expected.items():
            with self.subTest(status=status):
                self.transport.error = HttpFailure(status, {b'x-secret': b'not-exposed'})
                with self.assertRaises(GistReadbackFailure) as caught:
                    self.readback.confirm_file(TEMPERATURE_ID, 'thermostat.txt', 'expected')
                self.assertEqual(caught.exception.kind, kind)
                self.assertIsNone(caught.exception.__cause__)
        self.transport.error = None


if __name__ == '__main__':
    unittest.main()
