import json
import traceback
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from public_release_transport import PublicReleaseTransport
from release_client import MAX_DISCOVERY_MS, discover_release
from release_discovery import DiscoveryIncomplete


KEY = b'K' * 32
SIG = b'S' * 64


class Clock:
    def __init__(self):
        self.value = 100

    def ticks_ms(self):
        return self.value

    def ticks_diff(self, current, start):
        return current - start


class FakeTransport(PublicReleaseTransport):
    def __init__(self, pages, manifests, signatures=None):
        self.pages = pages
        self.manifests = manifests
        self.signatures = (signatures if signatures is not None else
                           {release_id: SIG for release_id in manifests})
        self.page_calls = []
        self.asset_calls = []
        self.fail_page = None
        self.page_secret = 'SECRET page response'

    def fetch_page(self, number, per_page=20, service=None):
        self.page_calls.append((number, per_page))
        if service is not None:
            service()
        if number == self.fail_page:
            raise RuntimeError(self.page_secret)
        return self.pages[number]

    def fetch_asset(self, release_id, asset_name, writer, max_bytes,
                    expected_size=None, service=None):
        self.asset_calls.append((release_id, asset_name))
        if asset_name not in ('manifest.json', 'manifest.sig'):
            raise AssertionError('target bytes fetched during discovery')
        raw = (self.manifests if asset_name == 'manifest.json' else self.signatures)[release_id]
        if len(raw) > max_bytes or (expected_size is not None and len(raw) != expected_size):
            raise RuntimeError('bad fixture')
        writer(raw)
        if service is not None:
            service()


def manifest(release_id, *, board='RPI_PICO2_W', minimum='v1.0.0'):
    return json.dumps({
        'algorithm': 'Ed25519',
        'board': board,
        'format_version': 1,
        'min_runtime': minimum,
        'release_id': release_id,
        'targets': [
            {'name': 'app.mpy', 'path': 'app.mpy', 'size_bytes': 12,
             'sha256': 'a' * 64},
            {'name': 'mod.mpy', 'path': 'lib/mod.mpy', 'size_bytes': 7,
             'sha256': 'b' * 64},
        ],
    }, separators=(',', ':')).encode()


def release(tag, release_id, *, assets=None):
    return {'id': release_id, 'tag_name': tag, 'draft': False,
            'prerelease': False, 'assets': assets if assets is not None else [
                {'id': release_id * 10 + 1, 'name': 'manifest.json', 'size': 1},
                {'id': release_id * 10 + 2, 'name': 'manifest.sig', 'size': 64},
                {'id': release_id * 10 + 3, 'name': 'app.mpy', 'size': 12},
                {'id': release_id * 10 + 4, 'name': 'mod.mpy', 'size': 7},
            ]}


def setup_candidate(rid, **kwargs):
    raw = manifest(rid, **kwargs)
    item = release('pico-' + str(rid), rid, assets=[
        {'id': rid * 10 + 1, 'name': 'manifest.json', 'size': len(raw)},
        {'id': rid * 10 + 2, 'name': 'manifest.sig', 'size': 64},
        {'id': rid * 10 + 3, 'name': 'app.mpy', 'size': 12},
        {'id': rid * 10 + 4, 'name': 'mod.mpy', 'size': 7},
    ])
    return item, raw


class ReleaseClientTests(unittest.TestCase):
    def discover(self, transport, **kwargs):
        calls = []

        def verifier(signature, public_key, message):
            calls.append((signature, public_key, message))
            return signature == SIG

        result = discover_release(transport, KEY, verifier, 'RPI_PICO2_W',
                                  'v1.0.0', None, None, Clock(), **kwargs)
        return result, calls

    def test_scans_mixed_android_pico_twenty_plus_short_page_and_returns_exact_winner(self):
        entries, raw_by_id = [], {}
        # API order is intentionally not release-number order.
        for rid in range(20, 0, -1):
            item, raw = setup_candidate(rid)
            entries.append(item)
            raw_by_id[rid] = raw
        # A non-Pico release has no parsed assets and must not displace a winner.
        entries[0] = {'id': 999, 'tag_name': 'v4.0.0', 'draft': False,
                      'prerelease': False, 'assets': []}
        high, raw = setup_candidate(37)
        transport = FakeTransport({1: entries, 2: [high]},
                                  {**raw_by_id, 37: raw})
        result, verified = self.discover(transport)
        self.assertEqual(result, (raw, SIG, 'pico-37'))
        self.assertEqual(len(verified), 20)
        self.assertEqual(transport.page_calls, [(1, 20), (2, 20)])
        self.assertFalse(any(name not in ('manifest.json', 'manifest.sig')
                             for _, name in transport.asset_calls))

    def test_invalid_signature_rejected_before_manifest_parsing(self):
        item = release('pico-4', 4)
        transport = FakeTransport({1: [item]}, {4: b'not-json'}, {4: b'X' * 64})
        result, calls = self.discover(transport)
        self.assertIsNone(result)
        self.assertEqual(calls, [(b'X' * 64, KEY, b'not-json')])

    def test_wrong_board_runtime_and_signed_tag_mismatch_are_skipped(self):
        cases = [
            (7, {'board': 'OTHER'}, 'pico-7'),
            (8, {'minimum': 'v9.0.0'}, 'pico-8'),
            (9, {}, 'pico-10'),
        ]
        for signed_id, kwargs, tag in cases:
            with self.subTest(signed_id=signed_id):
                item, raw = setup_candidate(signed_id, **kwargs)
                item['tag_name'] = tag
                if tag != 'pico-' + str(signed_id):
                    item['id'] = int(tag[5:])
                item['assets'][0]['size'] = len(raw)
                fetched_id = int(tag[5:])
                transport = FakeTransport({1: [item]}, {fetched_id: raw})
                result, _ = self.discover(transport)
                self.assertIsNone(result)

    def test_signed_candidate_inventory_mismatch_and_duplicate_ids_abort(self):
        item, raw = setup_candidate(5)
        item['assets'][-1]['size'] = 8
        duplicate, duplicate_raw = setup_candidate(6)
        duplicate['assets'][-1]['id'] = duplicate['assets'][0]['id']
        for candidate, bytes_value in ((item, raw), (duplicate, duplicate_raw)):
            transport = FakeTransport({1: [candidate]}, {5: raw, 6: duplicate_raw})
            with self.subTest(candidate=candidate['tag_name']):
                with self.assertRaises(DiscoveryIncomplete):
                    self.discover(transport)

    def test_last_page_error_discards_existing_winner_and_redacts(self):
        items = [release('v%d' % index, index + 100) for index in range(19)]
        winner, raw = setup_candidate(50)
        items.append(winner)
        transport = FakeTransport({1: items, 2: []}, {50: raw})
        transport.fail_page = 2
        with self.assertRaises(DiscoveryIncomplete) as caught:
            self.discover(transport)
        self.assertNotIn('SECRET', str(caught.exception))
        self.assertEqual(transport.page_calls, [(1, 20), (2, 20)])

    def test_full_page_cap_exhaustion_and_target_downloads_zero(self):
        items, manifests = [], {}
        for rid in range(1, 21):
            item, raw = setup_candidate(rid)
            items.append(item)
            manifests[rid] = raw
        transport = FakeTransport({1: items}, manifests)
        with self.assertRaises(DiscoveryIncomplete):
            self.discover(transport, max_pages=1)
        self.assertFalse(any(name.endswith('.mpy') for _, name in transport.asset_calls))

    def test_service_and_clock_fail_closed(self):
        item, raw = setup_candidate(2)
        for service in (lambda: False,
                        lambda: (_ for _ in ()).throw(RuntimeError('SECRET token'))):
            transport = FakeTransport({1: [item]}, {2: raw})
            with self.assertRaises(DiscoveryIncomplete) as caught:
                self.discover(transport, service=service)
            self.assertNotIn('SECRET', str(caught.exception))
        clock = Clock()
        clock.ticks_ms = lambda: 'bad'
        with self.assertRaises(DiscoveryIncomplete):
            discover_release(FakeTransport({1: []}, {}), KEY, lambda *args: True,
                             'RPI_PICO2_W', 'v1.0.0', None, None, clock)
        clock = Clock()
        clock.ticks_diff = lambda current, start: -1
        with self.assertRaises(DiscoveryIncomplete):
            discover_release(FakeTransport({1: []}, {}), KEY, lambda *args: True,
                             'RPI_PICO2_W', 'v1.0.0', None, None, clock)
        clock = Clock()

        def exhaust_deadline():
            clock.value += MAX_DISCOVERY_MS
            return True

        with self.assertRaises(DiscoveryIncomplete):
            discover_release(FakeTransport({1: []}, {}), KEY, lambda *args: True,
                             'RPI_PICO2_W', 'v1.0.0', None, None, clock,
                             service=exhaust_deadline)
        self.assertEqual(MAX_DISCOVERY_MS, 120000)

    def test_service_callback_secret_context_is_removed_from_traceback(self):
        item, raw = setup_candidate(2)

        def secret_failure():
            try:
                raise RuntimeError('SECRET service failure')
            except RuntimeError:
                raise DiscoveryIncomplete()

        with self.assertRaises(DiscoveryIncomplete) as caught:
            self.discover(FakeTransport({1: [item]}, {2: raw}),
                          service=secret_failure)
        rendered = ''.join(traceback.format_exception(caught.exception))
        self.assertNotIn('SECRET', rendered)

    def test_service_work_at_deadline_rejects_candidate(self):
        item, raw = setup_candidate(2)
        clock = Clock()
        transport = FakeTransport({1: [item]}, {2: raw})
        calls = [0]

        def advance_on_service():
            calls[0] += 1
            if calls[0] == 1:
                clock.value += MAX_DISCOVERY_MS
            return True

        with self.assertRaises(DiscoveryIncomplete):
            discover_release(transport, KEY, lambda signature, key, data: True,
                             'RPI_PICO2_W', 'v1.0.0', None, None, clock,
                             service=advance_on_service)

    def test_zero_byte_signed_target_is_valid_inventory(self):
        item, raw = setup_candidate(3)
        document = json.loads(raw)
        document['targets'][1]['size_bytes'] = 0
        raw = json.dumps(document, separators=(',', ':')).encode()
        item['assets'][-1]['size'] = 0
        transport = FakeTransport({1: [item]}, {3: raw})
        result, _ = self.discover(transport)
        self.assertEqual(result, (raw, SIG, 'pico-3'))


if __name__ == '__main__':
    unittest.main()
