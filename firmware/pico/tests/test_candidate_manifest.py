import io
import json
from pathlib import Path
import sys
import traceback
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

import candidate_manifest
from candidate_manifest import CandidateError, verify_candidate, verify_staged_assets
from tool.pico_release.manifest import ManifestError, build_candidate, verify_candidate as host_verify
from tool.pico_release.manifest import MAX_RELEASE_ID


BOARD = 'RPI_PICO2_W'


class Verifier:
    def __init__(self, private):
        self.private = private
        self.calls = []

    def __call__(self, signature, key, message):
        self.calls.append((signature, key, message))
        try:
            self.private.public_key().verify(signature, message)
            return key == self.private.public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        except Exception:
            return False


class MemoryStage:
    def __init__(self, assets):
        self.assets = assets
        self.opened = []

    def list_assets(self):
        return list(self.assets)

    def open_asset(self, path):
        self.opened.append(path)
        return io.BytesIO(self.assets[path])


class CandidateManifestTests(unittest.TestCase):
    def setUp(self):
        self.private = Ed25519PrivateKey.generate()
        self.public = self.private.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.assets = {'app.mpy': b'application', 'lib/sensor.mpy': b'sensor'}
        self.raw, self.signature = build_candidate(12, 'v1.29.0', self.assets, self.private)
        self.verifier = Verifier(self.private)

    def device_verify(self, raw=None, signature=None, **kwargs):
        options = dict(actual_board=BOARD, runtime='v1.29.1', tag_name='pico-12')
        options.update(kwargs)
        return verify_candidate(self.raw if raw is None else raw,
                                self.signature if signature is None else signature,
                                self.public, verifier=self.verifier, **options)

    def signed(self, mutate):
        value = json.loads(self.raw)
        mutate(value)
        raw = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
        return raw, self.private.sign(raw)

    def assert_invalid_both(self, raw, signature, **opts):
        with self.assertRaises(CandidateError):
            self.device_verify(raw, signature, **opts)
        kwargs = dict(manifest_bytes=raw, signature=signature, files=self.assets,
                      public_key_bytes=self.public, actual_board=opts.get('actual_board', BOARD),
                      runtime=opts.get('runtime', 'v1.29.1'), tag_name=opts.get('tag_name', 'pico-12'),
                      applied_id=opts.get('applied_id'), failed_id=opts.get('failed_id'))
        with self.assertRaises(ManifestError):
            host_verify(**kwargs)

    def test_valid_builder_parity_and_streamed_assets(self):
        candidate = self.device_verify()
        host = host_verify(self.raw, self.signature, self.assets, self.public,
                           BOARD, 'v1.29.1', 'pico-12')
        self.assertEqual(candidate.release_id, host['release_id'])
        self.assertEqual(tuple((d.path, d.size_bytes, d.sha256) for d in candidate.targets),
                         tuple((t['path'], t['size_bytes'], t['sha256']) for t in host['targets']))
        stage = MemoryStage(self.assets)
        self.assertTrue(verify_staged_assets(candidate, stage))
        self.assertEqual(set(stage.opened), set(self.assets))

    def test_release_id_twenty_digit_boundary_matches_host_and_device(self):
        raw, signature = build_candidate(MAX_RELEASE_ID, 'v1.29.0', self.assets, self.private)
        tag = 'pico-' + str(MAX_RELEASE_ID)
        device = self.device_verify(raw, signature, tag_name=tag)
        host = host_verify(raw, signature, self.assets, self.public, BOARD, 'v1.29.1', tag)
        self.assertEqual(device.release_id, MAX_RELEASE_ID)
        self.assertEqual(host['release_id'], MAX_RELEASE_ID)

        with self.assertRaisesRegex(ManifestError, '20 digits'):
            build_candidate(MAX_RELEASE_ID + 1, 'v1.29.0', self.assets, self.private)
        oversized = json.loads(raw)
        oversized['release_id'] = MAX_RELEASE_ID + 1
        oversized_raw = json.dumps(oversized, sort_keys=True, separators=(',', ':')).encode()
        oversized_signature = self.private.sign(oversized_raw)
        with self.assertRaises(CandidateError):
            self.device_verify(oversized_raw, oversized_signature,
                               tag_name='pico-' + str(MAX_RELEASE_ID + 1))
        with self.assertRaisesRegex(ManifestError, '20 digits'):
            host_verify(oversized_raw, oversized_signature, self.assets, self.public,
                        BOARD, 'v1.29.1', 'pico-' + str(MAX_RELEASE_ID + 1))

    def test_oversized_release_id_is_checked_after_signature_callback(self):
        oversized = json.loads(self.raw)
        oversized['release_id'] = MAX_RELEASE_ID + 1
        raw = json.dumps(oversized, sort_keys=True, separators=(',', ':')).encode()
        signature = self.private.sign(raw)
        with mock.patch.object(candidate_manifest, '_parse') as parse:
            with self.assertRaises(CandidateError):
                self.device_verify(raw, signature,
                                   tag_name='pico-' + str(MAX_RELEASE_ID + 1))
            self.assertEqual(len(self.verifier.calls), 1)
            parse.assert_called_once_with(raw)

    def test_verifier_runs_before_any_json_parse(self):
        spy = Verifier(self.private)
        with self.assertRaises(CandidateError):
            verify_candidate(b'{not json', self.signature, self.public, BOARD,
                             'v1.29.1', 'pico-12', verifier=spy)
        self.assertEqual(len(spy.calls), 1)
        spy.calls.clear()
        with self.assertRaises(CandidateError):
            verify_candidate(b'{not json', b'x' * 63, self.public, BOARD,
                             'v1.29.1', 'pico-12', verifier=spy)
        self.assertEqual(spy.calls, [])

    def test_verifier_must_return_exact_true_before_manifest_parse(self):
        for result in (None, 1, 'ok', object()):
            def verifier(signature, key, message, result=result):
                return result

            with self.subTest(result=result):
                with mock.patch.object(candidate_manifest, '_parse') as parse:
                    with self.assertRaises(CandidateError):
                        verify_candidate(self.raw, self.signature, self.public,
                                         BOARD, 'v1.29.1', 'pico-12', verifier=verifier)
                    parse.assert_not_called()

        def raising_verifier(signature, key, message):
            raise RuntimeError('verification failed')

        with self.assertRaises(CandidateError):
            verify_candidate(self.raw, self.signature, self.public,
                             BOARD, 'v1.29.1', 'pico-12', verifier=raising_verifier)

    def test_staged_assets_reject_bare_descriptor_list(self):
        """Candidate is only a type contract; supervisor must pass verified output."""
        candidate = self.device_verify()
        with self.assertRaises(CandidateError):
            verify_staged_assets(candidate.targets, MemoryStage(self.assets))

    def test_wrong_detached_signature_and_trusted_key_are_rejected(self):
        bad_signature = bytes([self.signature[0] ^ 1]) + self.signature[1:]
        with self.assertRaises(CandidateError):
            self.device_verify(signature=bad_signature)
        other_key = Ed25519PrivateKey.generate().public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        with self.assertRaises(CandidateError):
            verify_candidate(self.raw, self.signature, other_key, BOARD, 'v1.29.1',
                             'pico-12', verifier=self.verifier)

    def test_duplicate_keys_including_escaped_duplicate_are_rejected(self):
        root_duplicate = self.raw.replace(
            b'"algorithm":"Ed25519"',
            b'"algorithm":"Ed25519","\\u0061lgorithm":"Ed25519"', 1)
        nested_duplicate = self.raw.replace(
            b'"name":"sensor.mpy"',
            b'"name":"sensor.mpy","\\u006eame":"sensor.mpy"', 1)
        for raw in (root_duplicate, nested_duplicate):
            with self.subTest(raw=raw):
                self.assert_invalid_both(raw, self.private.sign(raw))

    def test_short_runtime_versions_and_digit_starting_paths_match_host(self):
        assets = {'app.mpy': b'application', 'lib/1wire.mpy': b'sensor'}
        raw, signature = build_candidate(12, 'v1.9.0', assets, self.private)
        for runtime in ('v1.29.1', 'v2.0.0'):
            with self.subTest(runtime=runtime):
                candidate = verify_candidate(raw, signature, self.public, BOARD,
                                             runtime, 'pico-12', verifier=self.verifier)
                host = host_verify(raw, signature, assets, self.public, BOARD,
                                   runtime, 'pico-12')
                self.assertEqual(candidate.min_runtime, host['min_runtime'])
                self.assertIn('lib/1wire.mpy', {target.path for target in candidate.targets})

        zero_raw, zero_signature = build_candidate(13, 'v0.0.0', assets, self.private)
        candidate = verify_candidate(zero_raw, zero_signature, self.public, BOARD,
                                     'v2.0.0', 'pico-13', verifier=self.verifier)
        host = host_verify(zero_raw, zero_signature, assets, self.public, BOARD,
                           'v2.0.0', 'pico-13')
        self.assertEqual(candidate.min_runtime, host['min_runtime'])

    def test_malformed_and_oversized_manifest_rejected(self):
        for raw in (b'[]', b'{', b'{} trailing', self.raw + b' ' * 3000):
            signature = self.private.sign(raw)
            with self.subTest(size=len(raw)):
                self.assert_invalid_both(raw, signature)

    def test_board_runtime_tag_and_highwater_checks_match_host(self):
        for options in ({'actual_board': 'RPI_PICO2'}, {'runtime': 'v1.28.9'},
                        {'tag_name': 'pico-13'}, {'applied_id': 12}, {'failed_id': 12}):
            with self.subTest(options=options):
                with self.assertRaises(CandidateError):
                    self.device_verify(**options)
                with self.assertRaises(ManifestError):
                    host_verify(self.raw, self.signature, self.assets, self.public,
                                options.get('actual_board', BOARD),
                                options.get('runtime', 'v1.29.1'),
                                options.get('tag_name', 'pico-12'),
                                options.get('applied_id'), options.get('failed_id'))

    def test_signed_metadata_types_fields_and_path_constraints(self):
        cases = [
            lambda value: value.update(board='wrong'),
            lambda value: value.update(algorithm='RSA'),
            lambda value: value.update(format_version=True),
            lambda value: value.update(release_id=True),
            lambda value: value['targets'][1].update(path='../sensor.mpy'),
            lambda value: value['targets'][1].update(path='/app.mpy', name='app.mpy'),
            lambda value: value['targets'][1].update(path='lib\\sensor.mpy'),
            lambda value: value['targets'][1].update(path='lib/nested/sensor.mpy'),
            lambda value: value['targets'][1].update(name='wrong.mpy'),
            lambda value: value['targets'][1].update(size_bytes=True),
            lambda value: value['targets'][1].update(sha256='A' * 64),
            lambda value: value.update(extra=True),
        ]
        for mutate in cases:
            raw, signature = self.signed(mutate)
            with self.subTest(raw=raw):
                with self.assertRaises(CandidateError):
                    self.device_verify(raw, signature)
                with self.assertRaises(ManifestError):
                    host_verify(raw, signature, self.assets, self.public, BOARD,
                                'v1.29.1', 'pico-12')

    def test_target_count_and_asset_size_limits(self):
        def add_extras(value):
            for index in range(7):
                name = 'extra%d.mpy' % index
                value['targets'].append({'name': name, 'path': 'lib/' + name,
                                         'size_bytes': 1, 'sha256': '0' * 64})

        raw, signature = self.signed(add_extras)
        with self.assertRaises(CandidateError):
            self.device_verify(raw, signature)
        raw, signature = self.signed(lambda value: value['targets'][0].update(
            size_bytes=524289))
        with self.assertRaises(CandidateError):
            self.device_verify(raw, signature)

    def test_asset_truncation_hash_size_excess_and_unsafe_path(self):
        candidate = self.device_verify()
        for assets in ({'app.mpy': b'application', 'lib/sensor.mpy': b'senso'},
                       {'app.mpy': b'changed-app', 'lib/sensor.mpy': b'sensor'},
                       {**self.assets, 'unexpected.mpy': b'extra'},
                       {'app.mpy': b'application'}):
            with self.subTest(assets=assets):
                with self.assertRaises(CandidateError):
                    verify_staged_assets(candidate, MemoryStage(assets))
        unsafe = candidate.targets[1]._replace(path='../sensor.mpy')
        stage = MemoryStage(self.assets)
        with self.assertRaises(CandidateError):
            verify_staged_assets(candidate._replace(
                targets=(candidate.targets[0], unsafe)), stage)
        self.assertEqual(stage.opened, [])

    def test_staged_reads_are_bounded_and_exact_size_enforced(self):
        candidate = self.device_verify()

        class CheckedStream(io.BytesIO):
            def read(self, size=-1):
                if size < 0 or size > 1024:
                    raise AssertionError('unbounded asset read')
                return super().read(size)

        class CheckedStage(MemoryStage):
            def open_asset(self, path):
                self.opened.append(path)
                return CheckedStream(self.assets[path])

        self.assertTrue(verify_staged_assets(candidate, CheckedStage(self.assets)))
        bad = candidate.targets[0]._replace(size_bytes=candidate.targets[0].size_bytes + 1)
        with self.assertRaises(CandidateError):
            verify_staged_assets(candidate._replace(
                targets=(bad,) + candidate.targets[1:]), CheckedStage(self.assets))

    def test_service_receives_cumulative_bytes_across_asset_boundaries(self):
        assets = {'app.mpy': b'a' * 512, 'lib/sensor.mpy': b'b' * 2048}
        raw, signature = build_candidate(12, 'v1.29.0', assets, self.private)
        candidate = verify_candidate(raw, signature, self.public, BOARD, 'v1.29.1',
                                     'pico-12', verifier=self.verifier)
        checkpoints = []
        self.assertTrue(verify_staged_assets(
            candidate, MemoryStage(assets), service=checkpoints.append))
        self.assertEqual(checkpoints, [512, 1536, 2560])

    def test_external_callback_errors_are_redacted_from_full_traceback(self):
        def raising_verifier(signature, key, message):
            raise RuntimeError('SECRET_VERIFIER_DETAIL')

        with self.assertRaises(CandidateError) as raised:
            verify_candidate(self.raw, self.signature, self.public, BOARD,
                             'v1.29.1', 'pico-12', verifier=raising_verifier)
        formatted = ''.join(traceback.format_exception(
            type(raised.exception), raised.exception, raised.exception.__traceback__))
        self.assertNotIn('SECRET_VERIFIER_DETAIL', formatted)

        candidate = self.device_verify()

        class RaisingStage(MemoryStage):
            def open_asset(self, path):
                raise CandidateError('SECRET_ACCESSOR_DETAIL')

        for stage, service, secret in (
                (RaisingStage(self.assets), None, 'SECRET_ACCESSOR_DETAIL'),
                (MemoryStage(self.assets),
                 lambda count: (_ for _ in ()).throw(
                     CandidateError('SECRET_SERVICE_DETAIL')), 'SECRET_SERVICE_DETAIL')):
            with self.subTest(secret=secret):
                with self.assertRaises(CandidateError) as raised:
                    verify_staged_assets(candidate, stage, service=service)
                formatted = ''.join(traceback.format_exception(
                    type(raised.exception), raised.exception, raised.exception.__traceback__))
                self.assertNotIn(secret, formatted)

    def test_streams_are_closed_on_every_validation_failure(self):
        candidate = self.device_verify()

        class TrackedStream(io.BytesIO):
            def __init__(self, value):
                super().__init__(value)
                self.was_closed = False

            def close(self):
                self.was_closed = True
                super().close()

        class TrackedStage(MemoryStage):
            def __init__(self, assets):
                super().__init__(assets)
                self.streams = []

            def open_asset(self, path):
                self.opened.append(path)
                stream = TrackedStream(self.assets[path])
                self.streams.append(stream)
                return stream

        scenarios = [
            ('truncated', self.assets['app.mpy'][:-1], None, None),
            ('overflow', self.assets['app.mpy'], 1, None),
            ('hash mismatch', self.assets['app.mpy'], None, '0' * 64),
            ('service abort', self.assets['app.mpy'], None, None),
        ]
        for label, content, size, sha256 in scenarios:
            with self.subTest(failure=label):
                assets = dict(self.assets)
                assets['app.mpy'] = content
                descriptor = candidate.targets[0]
                if size is not None:
                    descriptor = descriptor._replace(size_bytes=size)
                if sha256 is not None:
                    descriptor = descriptor._replace(sha256=sha256)
                altered = candidate._replace(
                    targets=(descriptor,) + candidate.targets[1:])
                stage = TrackedStage(assets)
                service = (lambda count: False) if label == 'service abort' else None
                with self.assertRaises(CandidateError):
                    verify_staged_assets(altered, stage, service=service)
                self.assertEqual(len(stage.streams), 1)
                self.assertTrue(stage.streams[0].was_closed)

        descriptors = list(candidate.targets)
        descriptors[1] = descriptors[1]._replace(sha256='0' * 64)
        stage = TrackedStage(self.assets)
        with self.assertRaises(CandidateError):
            verify_staged_assets(candidate._replace(targets=tuple(descriptors)), stage)
        self.assertEqual(len(stage.streams), 2)
        self.assertTrue(all(stream.was_closed for stream in stage.streams))

    def test_digest_works_without_hexdigest(self):
        candidate = self.device_verify()
        real_sha256 = candidate_manifest.hashlib.sha256

        class DigestOnly:
            def __init__(self):
                self.digest_impl = real_sha256()

            def update(self, value):
                self.digest_impl.update(value)

            def digest(self):
                return self.digest_impl.digest()

        with mock.patch.object(candidate_manifest.hashlib, 'sha256', DigestOnly):
            self.assertTrue(verify_staged_assets(candidate, MemoryStage(self.assets)))


if __name__ == '__main__':
    unittest.main()
