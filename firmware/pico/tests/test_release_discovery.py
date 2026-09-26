import unittest
import traceback
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from release_discovery import (
    ABSOLUTE_MAX_PAGES,
    MAX_PAGE_ITEMS,
    DiscoveryIncomplete,
    select_signed_release,
)


def release(tag, release_id, *, draft=False, prerelease=False, assets=None):
    return {
        'id': release_id,
        'tag_name': tag,
        'draft': draft,
        'prerelease': prerelease,
        'assets': assets if assets is not None else [
            {'name': 'manifest.json', 'size': 100},
            {'name': 'manifest.sig', 'size': 64},
        ],
    }


class ReleaseDiscoveryTests(unittest.TestCase):
    def test_ignores_android_draft_and_prerelease_and_checks_all_order(self):
        entries = [
            release('pico-4', 1),
            release('v99.0.0', 2),
            release('pico-200', 3, draft=True),
            release('pico-201', 4, prerelease=True),
            release('pico-12', 5),
        ]
        calls = []

        def admit(item, tag_id, applied, failed):
            calls.append(tag_id)
            return tag_id

        result = select_signed_release(lambda page, per_page: entries,
                                       admit, 2, 3)
        self.assertEqual(result, 12)
        self.assertEqual(calls, [4, 12])

    def test_scans_multiple_pages_and_empty_page_after_full_final(self):
        first = [release('pico-%d' % number, number)
                 for number in range(1, MAX_PAGE_ITEMS + 1)]
        second = [release('pico-50', 50)] + [
            release('v2.%d' % number, MAX_PAGE_ITEMS + number + 1)
            for number in range(MAX_PAGE_ITEMS - 1)
        ]
        pages = {1: first, 2: second, 3: []}
        requests = []

        def fetch(page, size):
            requests.append((page, size))
            return pages[page]

        self.assertEqual(select_signed_release(fetch, lambda r, i, a, f: i,
                                               None, None), 50)
        self.assertEqual(requests, [(1, MAX_PAGE_ITEMS),
                                   (2, MAX_PAGE_ITEMS),
                                   (3, MAX_PAGE_ITEMS)])

    def test_short_page_terminates_without_requesting_next(self):
        requested = []
        result = select_signed_release(
            lambda page, size: requested.append(page) or [release('pico-9', 1)],
            lambda item, tag_id, applied, failed: tag_id, None, None)
        self.assertEqual(result, 9)
        self.assertEqual(requested, [1])

    def test_full_page_at_cap_fails_closed_even_with_candidate(self):
        pages = [release('pico-%d' % (1000 + i), i + 1)
                 for i in range(MAX_PAGE_ITEMS)]
        calls = []
        with self.assertRaises(DiscoveryIncomplete):
            select_signed_release(lambda page, size: pages,
                                  lambda r, i, a, f: calls.append(i) or i,
                                  None, None, max_pages=1)
        self.assertEqual(len(calls), MAX_PAGE_ITEMS)

    def test_cap_exhaustion_does_not_select_partial_high_candidate(self):
        pages = {
            1: [release('pico-%d' % (100 + i), i + 1)
                for i in range(MAX_PAGE_ITEMS)],
            2: [release('pico-1000', 99)],
        }
        with self.assertRaises(DiscoveryIncomplete):
            select_signed_release(lambda page, size: pages[page],
                                  lambda r, i, a, f: i, None, None,
                                  max_pages=1)

    def test_malformed_required_metadata_is_incomplete(self):
        candidates = [
            release('pico-1', 1, assets=[]),
            release('pico-2', 2, assets=[
                {'name': 'manifest.json', 'size': 100},
                {'name': 'manifest.sig', 'size': 63},
            ]),
            release('pico-3', 3, assets=[
                {'name': 'manifest.json', 'size': 2049},
                {'name': 'manifest.sig', 'size': 64},
            ]),
            release('pico-4', 4, assets=[
                {'name': 'manifest.json', 'size': 100},
                {'name': 'manifest.json', 'size': 100},
                {'name': 'manifest.sig', 'size': 64},
            ]),
            release('pico-5', 5, assets=[
                {'name': 'manifest.json', 'size': 100},
                {'name': 'manifest.sig', 'size': 64},
                {'name': 'manifest.sig', 'size': 64},
            ]),
        ]
        calls = []
        with self.assertRaises(DiscoveryIncomplete):
            select_signed_release(lambda page, size: candidates,
                                  lambda r, i, a, f: calls.append(i) or i,
                                  None, None)
        self.assertEqual(calls, [])

    def test_malformed_higher_candidate_cannot_be_hidden_by_lower_winner(self):
        lower = release('pico-4', 1)
        malformed = (
            [],
            [{'name': 'manifest.json', 'size': 100}],
            [{'name': 'manifest.json', 'size': 100},
             {'name': 'manifest.sig', 'size': 63}],
            [{'name': 'manifest.json', 'size': 100},
             {'name': 'manifest.sig', 'size': 64},
             {'name': 'manifest.sig', 'size': 64}],
        )
        for assets in malformed:
            with self.subTest(assets=assets):
                with self.assertRaises(DiscoveryIncomplete):
                    select_signed_release(
                        lambda page, size: [lower, release('pico-5', 2,
                                                           assets=assets)],
                        lambda item, tag_id, applied, failed: tag_id,
                        None, None)

    def test_redacts_discovery_incomplete_with_existing_secret_context(self):
        def raises_in_secret_context(*args):
            try:
                raise RuntimeError('SECRET callback failure')
            except RuntimeError:
                raise DiscoveryIncomplete()

        callbacks = (
            lambda: select_signed_release(raises_in_secret_context,
                                          lambda *args: None, None, None),
            lambda: select_signed_release(
                lambda page, size: [release('pico-10', 1)],
                raises_in_secret_context, None, None),
            lambda: select_signed_release(
                lambda page, size: [release('pico-10', 1)],
                lambda *args: args[1], None, None,
                service=raises_in_secret_context),
        )
        for call in callbacks:
            with self.assertRaises(DiscoveryIncomplete) as caught:
                call()
            rendered = ''.join(traceback.format_exception(caught.exception))
            self.assertNotIn('SECRET', rendered)

    def test_noncanonical_pico_tags_not_admitted(self):
        entries = [release(tag, i) for i, tag in enumerate(
            ('pico-0', 'pico-01', 'pico-+1', 'pico-1x'), 1)]
        self.assertIsNone(select_signed_release(
            lambda page, size: entries,
            lambda r, i, a, f: self.fail('ineligible tag admitted'), None, None))

    def test_signed_id_mismatch_and_non_exact_int_are_incomplete(self):
        for returned in (8, True, 7.0, '7', object()):
            with self.subTest(returned=repr(returned)):
                with self.assertRaises(DiscoveryIncomplete):
                    select_signed_release(
                        lambda page, size: [release('pico-7', 1)],
                        lambda r, i, a, f: returned, None, None)

    def test_historical_releases_skip_callback_and_newer_across_pages_wins(self):
        first = [release('pico-4', 1)] + [
            release('v1.%d' % index, index + 2)
            for index in range(MAX_PAGE_ITEMS - 1)
        ]
        second = [release('pico-1', 30), release('pico-5', 31)]
        calls = []

        def fetch(page, size):
            return {1: first, 2: second}[page]

        def admit(item, tag_id, applied, failed):
            calls.append(tag_id)
            return tag_id

        self.assertEqual(select_signed_release(fetch, admit, 4, 3), 5)
        self.assertEqual(calls, [5])

    def test_only_stale_release_returns_none_without_callback(self):
        calls = []
        result = select_signed_release(
            lambda page, size: [release('pico-1', 10)],
            lambda *args: calls.append(args), 4, 2)
        self.assertIsNone(result)
        self.assertEqual(calls, [])

    def test_callback_old_id_for_new_tag_is_mismatch_not_stale_skip(self):
        with self.assertRaises(DiscoveryIncomplete):
            select_signed_release(
                lambda page, size: [release('pico-5', 10)],
                lambda item, tag_id, applied, failed: 4, 4, 2)

    def test_duplicate_tags_with_distinct_release_ids_fail_closed(self):
        with self.assertRaises(DiscoveryIncomplete):
            select_signed_release(
                lambda page, size: [release('pico-5', 10),
                                    release('pico-5', 11)],
                lambda item, tag_id, applied, failed: tag_id, None, None)

    def test_transport_callback_and_service_failures_redacted_no_partial(self):
        def raises(*args):
            raise RuntimeError('SECRET raw response token')

        for fetch, admit, service in (
                (raises, lambda *args: None, None),
                (lambda p, n: [release('pico-10', 1)], raises, None),
                (lambda p, n: [release('pico-10', 1)],
                 lambda r, i, a, f: i,
                 lambda: (_ for _ in ()).throw(RuntimeError('SECRET'))),
                (lambda p, n: [release('pico-10', 1)],
                 lambda r, i, a, f: i, lambda: False)):
            with self.assertRaises(DiscoveryIncomplete) as caught:
                select_signed_release(fetch, admit, None, None, service=service)
            self.assertNotIn('SECRET', str(caught.exception))

    def test_failure_after_candidate_never_returns_partial_winner(self):
        first = [release('pico-%d' % i, i) for i in range(MAX_PAGE_ITEMS)]

        def fetch(page, size):
            if page == 1:
                return first
            raise RuntimeError('rate limit: secret response')

        with self.assertRaises(DiscoveryIncomplete) as caught:
            select_signed_release(fetch, lambda r, i, a, f: i, None, None)
        self.assertNotIn('rate limit', str(caught.exception))

    def test_duplicate_release_ids_and_malformed_pages_fail(self):
        for page in (
                [release('pico-1', 1), release('pico-2', 1)],
                {'items': []},
                [release('pico-1', 1)] * (MAX_PAGE_ITEMS + 1),
                [release('pico-1', True)]):
            with self.subTest(page=repr(page)[:50]):
                with self.assertRaises(DiscoveryIncomplete):
                    select_signed_release(lambda p, n: page,
                                          lambda r, i, a, f: i, None, None)

    def test_invalid_page_cap_rejected(self):
        for cap in (0, ABSOLUTE_MAX_PAGES + 1, True, 1.5):
            with self.subTest(cap=cap):
                with self.assertRaises(DiscoveryIncomplete):
                    select_signed_release(lambda p, n: [], lambda *args: None,
                                          None, None, max_pages=cap)


if __name__ == '__main__':
    unittest.main()
