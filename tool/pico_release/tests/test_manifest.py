import hashlib
import json
import unittest
from unittest import mock

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

from tool.pico_release import cli
from tool.pico_release.manifest import (
    MAX_MANIFEST_BYTES,
    ManifestError,
    build_candidate,
    canonical_manifest_bytes,
    verify_candidate,
)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.private = Ed25519PrivateKey.generate()
        self.public = self.private.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw
        )
        self.files = {'app.mpy': b'fixture application', 'lib/sensor.mpy': b'companion'}
        self.data, self.signature = build_candidate(12, 'v1.29.0', self.files, self.private)

    def verify(self, **changes):
        options = {
            'manifest_bytes': self.data,
            'signature': self.signature,
            'files': dict(self.files),
            'public_key_bytes': self.public,
            'actual_board': 'RPI_PICO2_W',
            'runtime': 'v1.29.1',
            'tag_name': 'pico-12',
        }
        options.update(changes)
        return verify_candidate(**options)

    def test_good_fixture_and_deterministic_canonical_manifest(self):
        self.assertEqual(self.verify()['release_id'], 12)
        manifest = json.loads(self.data)
        self.assertEqual(self.data, canonical_manifest_bytes(manifest))
        self.assertEqual(manifest['targets'][0]['sha256'], hashlib.sha256(b'fixture application').hexdigest())
        self.assertEqual(manifest['targets'][0]['path'], 'app.mpy')

    def test_builder_output_round_trips_through_verifier(self):
        data, signature = build_candidate(23, 'v1.29.0', self.files, self.private)
        self.assertEqual(verify_candidate(
            data, signature, self.files, self.public, 'RPI_PICO2_W',
            'v1.29.0', 'pico-23')['release_id'], 23)

    def test_exact_manifest_limit_is_accepted_and_one_byte_over_is_rejected(self):
        # A large, valid release id makes an otherwise ordinary one-target
        # candidate exactly fill the firmware verifier's fixed input buffer.
        base, _ = build_candidate(1, 'v1.29.0', {'app.mpy': b'app'}, self.private)
        digits = MAX_MANIFEST_BYTES - len(base) + 1
        release_id = int('1' * digits)
        data, signature = build_candidate(release_id, 'v1.29.0', {'app.mpy': b'app'}, self.private)
        self.assertEqual(len(data), MAX_MANIFEST_BYTES)
        self.assertEqual(verify_candidate(data, signature, {'app.mpy': b'app'}, self.public,
                                          'RPI_PICO2_W', 'v1.29.0', f'pico-{release_id}')['release_id'],
                         release_id)
        with self.assertRaisesRegex(ManifestError, 'byte limit'):
            verify_candidate(data + b' ', signature, {'app.mpy': b'app'}, self.public,
                             'RPI_PICO2_W', 'v1.29.0', f'pico-{release_id}')
        with self.assertRaisesRegex(ManifestError, 'byte limit'):
            build_candidate(int('1' * (digits + 1)), 'v1.29.0', {'app.mpy': b'app'}, self.private)

    def test_tampered_manifest_bytes_and_signature_fail(self):
        with self.assertRaisesRegex(ManifestError, 'signature'):
            self.verify(manifest_bytes=self.data + b' ')
        with self.assertRaisesRegex(ManifestError, 'signature'):
            self.verify(signature=b'wrong')

    def test_wrong_key_and_board_fail(self):
        other = Ed25519PrivateKey.generate().public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw
        )
        with self.assertRaisesRegex(ManifestError, 'signature'):
            self.verify(public_key_bytes=other)
        with self.assertRaisesRegex(ManifestError, 'board'):
            self.verify(actual_board='RPI_PICO2')

    def test_duplicate_json_keys_including_escaped_alias_fail_after_signature(self):
        raw = b'{"algorithm":"Ed25519","\\u0061lgorithm":"Ed25519"}'
        signature = self.private.sign(raw)
        with self.assertRaisesRegex(ManifestError, 'duplicate'):
            self.verify(manifest_bytes=raw, signature=signature)

    def test_unknown_fields_and_algorithm_fail(self):
        manifest = json.loads(self.data)
        manifest['unknown'] = True
        data = canonical_manifest_bytes(manifest)
        with self.assertRaisesRegex(ManifestError, 'fields'):
            self.verify(manifest_bytes=data, signature=self.private.sign(data))
        manifest = json.loads(self.data)
        manifest['algorithm'] = 'RSA'
        data = canonical_manifest_bytes(manifest)
        with self.assertRaisesRegex(ManifestError, 'algorithm'):
            self.verify(manifest_bytes=data, signature=self.private.sign(data))

    def test_path_safety_allowlist_and_duplicate_target_rejected(self):
        for path in ('../app.mpy', '/app.mpy', 'lib\\sensor.mpy', 'lib/nested/sensor.mpy',
                     'unknown.txt', 'lib/bad\x00name.mpy', 'lib/bad?name.mpy',
                     'lib/bad*name.mpy', 'lib/manifest.json.mpy', 'lib/manifest.sig.mpy'):
            with self.subTest(path=path), self.assertRaises(ManifestError):
                build_candidate(12, 'v1.29.0', {'app.mpy': b'a', path: b'b'}, self.private)
        manifest = json.loads(self.data)
        manifest['targets'][1]['path'] = 'app.mpy'
        manifest['targets'][1]['name'] = 'app.mpy'
        data = canonical_manifest_bytes(manifest)
        with self.assertRaisesRegex(ManifestError, 'duplicate'):
            self.verify(manifest_bytes=data, signature=self.private.sign(data))

    def test_asset_count_and_builder_duplicate_basename_rejected_before_signing(self):
        files = {'app.mpy': b'app'}
        files.update({f'lib/module{index}.mpy': b'x' for index in range(15)})
        with self.assertRaisesRegex(ManifestError, 'too many targets'):
            build_candidate(12, 'v1.29.0', files, self.private)
        class SigningSpy:
            called = False

            def sign(self, data):
                self.called = True
                return self.private.sign(data)

        spy = SigningSpy()
        spy.private = self.private
        with self.assertRaisesRegex(ManifestError, 'duplicate'):
            build_candidate(12, 'v1.29.0', {'app.mpy': b'a', 'lib/app.mpy': b'b'}, spy)
        self.assertFalse(spy.called)

    def test_target_name_must_match_safe_basename(self):
        for name in ('wrong.mpy', 'lib/sensor.mpy', 'sensor\x00.mpy', 'sensor?.mpy', 'manifest.json'):
            manifest = json.loads(self.data)
            manifest['targets'][1]['name'] = name
            data = canonical_manifest_bytes(manifest)
            with self.subTest(name=name), self.assertRaisesRegex(ManifestError, 'target name'):
                self.verify(manifest_bytes=data, signature=self.private.sign(data))

    def test_hash_and_size_mismatch_and_extra_or_missing_assets_fail(self):
        with self.assertRaisesRegex(ManifestError, 'size'):
            self.verify(files={'app.mpy': b'wrong-size', 'lib/sensor.mpy': b'companion'})
        with self.assertRaisesRegex(ManifestError, 'hash'):
            self.verify(files={'app.mpy': b'fixture application', 'lib/sensor.mpy': b'changed!!'})
        with self.assertRaisesRegex(ManifestError, 'missing asset'):
            self.verify(files={'app.mpy': b'fixture application'})
        with self.assertRaisesRegex(ManifestError, 'excess assets'):
            self.verify(files={**self.files, 'lib/extra.mpy': b'extra'})

    def test_tag_runtime_and_high_water_constraints(self):
        for tag in ('v12', 'pico-13'):
            with self.subTest(tag=tag), self.assertRaises(ManifestError):
                self.verify(tag_name=tag)
        with self.assertRaisesRegex(ManifestError, 'runtime'):
            self.verify(runtime='v1.28.9')
        with self.assertRaisesRegex(ManifestError, 'applied'):
            self.verify(applied_id=12)
        with self.assertRaisesRegex(ManifestError, 'failed'):
            self.verify(failed_id=12)

    def test_noncanonical_signed_bytes_are_valid_if_signature_is_exact(self):
        manifest = json.loads(self.data)
        raw = json.dumps(manifest, indent=2).encode()
        self.assertEqual(self.verify(manifest_bytes=raw, signature=self.private.sign(raw))['release_id'], 12)

    def test_cli_manifest_read_is_bounded_to_one_byte_over_limit(self):
        file_handle = mock.MagicMock()
        file_handle.__enter__.return_value.read.return_value = b'x' * (MAX_MANIFEST_BYTES + 1)
        with mock.patch('pathlib.Path.open', return_value=file_handle) as open_file:
            with self.assertRaisesRegex(ManifestError, 'byte limit'):
                cli._read_manifest(__import__('pathlib').Path('manifest.json'))
        file_handle.__enter__.return_value.read.assert_called_once_with(MAX_MANIFEST_BYTES + 1)
        open_file.assert_called_once_with('rb')

    def test_cli_raw_key_storage_matches_pem_and_der_inputs(self):
        raw_private = self.private.private_bytes(
            serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        pem_private = self.private.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        der_private = self.private.private_bytes(
            serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        outputs = [cli._private_key(key).public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)
                   for key in (raw_private, pem_private, der_private)]
        self.assertEqual(outputs, [self.public] * 3)
        pem_public = self.private.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        der_public = self.private.public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        self.assertEqual([cli._public_key(key) for key in (self.public, pem_public, der_public)],
                         [self.public] * 3)


if __name__ == '__main__':
    unittest.main()
