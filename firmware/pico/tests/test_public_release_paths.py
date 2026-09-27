import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from public_release_paths import (
    build_release_path,
    parse_release_redirect,
    release_asset_name,
)


class PublicReleasePathTests(unittest.TestCase):
    def test_release_asset_paths_and_id_boundaries(self):
        maximum = 10 ** 20 - 1
        self.assertEqual(
            build_release_path('FarmCtl', 'firmware_repo', maximum, 'app.mpy'),
            (b'github.com', b'/FarmCtl/firmware_repo/releases/download/pico-' +
             str(maximum).encode('ascii') + b'/app.mpy'))
        self.assertEqual(
            build_release_path('owner', 'repo', 9, 'sensor.mpy')[1],
            b'/owner/repo/releases/download/pico-9/sensor.mpy')
        for filename in ('manifest.json', 'manifest.sig', 'app.mpy'):
            self.assertTrue(build_release_path('owner', 'repo', 1, filename)[1].endswith(
                b'/' + filename.encode('ascii')))

    def test_flat_target_name_mapping_is_explicit_and_collision_safe(self):
        self.assertEqual(release_asset_name('lib/sensor.mpy'), 'sensor.mpy')
        self.assertEqual(release_asset_name('lib/1wire.mpy'), '1wire.mpy')
        self.assertEqual(release_asset_name('app.mpy'), 'app.mpy')
        with self.assertRaises(ValueError):
            release_asset_name('lib/app.mpy')
        for target in ('lib/a/b.mpy', 'lib/../sensor.mpy', 'lib/.mpy',
                       'lib/bad name.mpy', 'sensor.mpy', 'lib/manifest.json'):
            with self.subTest(target=target), self.assertRaises(ValueError):
                release_asset_name(target)

    def test_rejects_unsafe_release_components_and_assets(self):
        invalid = [
            ('../owner', 'repo', 1, 'app.mpy'),
            ('owner/path', 'repo', 1, 'app.mpy'),
            ('', 'repo', 1, 'app.mpy'),
            ('owner', '..', 1, 'app.mpy'),
            ('owner', 'repo', 0, 'app.mpy'),
            ('owner', 'repo', -1, 'app.mpy'),
            ('owner', 'repo', True, 'app.mpy'),
            ('owner', 'repo', 10 ** 20, 'app.mpy'),
            ('owner', 'repo', 1, '../app.mpy'),
            ('owner', 'repo', 1, 'lib/sensor.mpy'),
            ('owner', 'repo', 1, 'app.mpy?token=secret'),
            ('owner', 'repo', 1, 'other.zip'),
        ]
        for args in invalid:
            with self.subTest(args=args), self.assertRaises(ValueError):
                build_release_path(*args)

    def test_accepts_signed_redirect_preserving_opaque_query_exactly(self):
        location = (b'https://release-assets.githubusercontent.com/assets/abc/file.mpy?'
                    b'token=a%2Fb&expires=123&signature=Aa9%2B%2F%3D&x=@')
        host, target = parse_release_redirect(location)
        self.assertEqual(host, b'release-assets.githubusercontent.com')
        self.assertEqual(target, location.split(b'.com', 1)[1].removeprefix(b''))
        self.assertEqual(target,
                         b'/assets/abc/file.mpy?token=a%2Fb&expires=123&'
                         b'signature=Aa9%2B%2F%3D&x=@')

    def test_rejects_hostile_redirects_without_echoing_location(self):
        secret = b'NEVER-ECHO-THIS-TOKEN'
        hostile = [
            b'http://release-assets.githubusercontent.com/a?' + secret,
            b'https://evilrelease-assets.githubusercontent.com/a?' + secret,
            b'https://release-assets.githubusercontent.com.evil.test/a?' + secret,
            b'https://release-assets.githubusercontent.com./a?' + secret,
            b'https://user@release-assets.githubusercontent.com/a?' + secret,
            b'https://release-assets.githubusercontent.com:443/a?' + secret,
            b'https://127.0.0.1/a?' + secret,
            b'https://[::1]/a?' + secret,
            b'https://release-assets.githubusercontent.com/a#frag?' + secret,
            b'https://release-assets.githubusercontent.com/a?' + secret + b'#frag',
            b'https://release-assets.githubusercontent.com//a?' + secret,
            b'https://release-assets.githubusercontent.com/a/../b?' + secret,
            b'https://release-assets.githubusercontent.com/a/%2e%2e/b?' + secret,
            b'https://release-assets.githubusercontent.com/a%2fb?' + secret,
            b'https://release-assets.githubusercontent.com/a%5Cb?' + secret,
            b'https://release-assets.githubusercontent.com/a%GG?' + secret,
            b'https://release-assets.githubusercontent.com/a?' + secret + b'%Q0',
            b'https://release-assets.githubusercontent.com/a',
            b'https://release-assets.githubusercontent.com/a?',
            b'https://release-assets.githubusercontent.com/a?x y',
            b'https://release-assets.githubusercontent.com/a?x\\y',
            b'https://release-assets.githubusercontent.com/a?x\r\nHost: evil',
            b'https://release-assets.githubusercontent.com/' + b'a' * 1025 + b'?' + secret,
            b'https://release-assets.githubusercontent.com/a?' + b'x' * 2049,
        ]
        for location in hostile:
            with self.subTest(location='<redacted>'):
                with self.assertRaises(ValueError) as caught:
                    parse_release_redirect(location)
                self.assertNotIn(secret.decode('ascii'), str(caught.exception))
                self.assertNotIn(location.decode('ascii', 'replace'), repr(caught.exception))

    def test_rejects_non_bytes_redirect_without_rendering_value(self):
        with self.assertRaises(ValueError):
            parse_release_redirect('https://release-assets.githubusercontent.com/a?secret')


if __name__ == '__main__':
    unittest.main()
