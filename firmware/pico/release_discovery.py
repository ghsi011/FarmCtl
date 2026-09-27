"""Host-testable selection over normalized, bounded Pico release page metadata.

This module deliberately does not perform HTTP, redirects, asset downloads, TLS,
or signature verification. ``fetch_page(page, 20)`` supplies one normalized page;
the trusted ``admit_signed_release`` callback authenticates exact manifest and
signature bytes against the pinned key, board/runtime, tag, and high-waters, and
checks API inventory against the signed target descriptors. Target payload
bytes and their signed hashes are verified for the selected winner before trial,
not for every release considered during discovery.

GitHub's list endpoint may return releases in arbitrary order, so every eligible
entry on every complete page must be considered before selecting the maximum.
The finite page cap fails closed: a qualifying newer release beyond the cap can
exist, so no partial winner is safe. This bound limits memory to one page but
also limits availability to releases found in the first ``max_pages`` pages.
There is intentionally no ETag/conditional cache yet.
"""

MAX_PAGE_ITEMS = 20
DEFAULT_MAX_PAGES = 8
ABSOLUTE_MAX_PAGES = 32
MAX_ASSETS = 16
MAX_TAG_DIGITS = 20
MAX_MANIFEST_BYTES = 2048
SIGNATURE_BYTES = 64


class DiscoveryIncomplete(Exception):
    """Redacted fail-closed discovery error; never includes transport data."""

    def __init__(self):
        super().__init__('Release discovery incomplete.')


def _incomplete():
    raise DiscoveryIncomplete()


def _high_water(value):
    return value is None or (type(value) is int and value >= 0)


def _release_tag_id(tag):
    if not isinstance(tag, str) or not tag.startswith('pico-'):
        return None
    digits = tag[5:]
    if not digits or len(digits) > MAX_TAG_DIGITS or digits[0] == '0':
        return None
    for char in digits:
        if char < '0' or char > '9':
            return None
    return int(digits)


def _asset_metadata(release):
    assets = release.get('assets')
    if not isinstance(assets, (list, tuple)) or len(assets) > MAX_ASSETS:
        _incomplete()
    matches = {'manifest.json': [], 'manifest.sig': []}
    for asset in assets:
        if not isinstance(asset, dict):
            _incomplete()
        name = asset.get('name')
        if not isinstance(name, str):
            _incomplete()
        if name in matches:
            matches[name].append(asset)
    manifest, signature = matches['manifest.json'], matches['manifest.sig']
    if len(manifest) != 1 or len(signature) != 1:
        _incomplete()
    manifest_size = manifest[0].get('size')
    signature_size = signature[0].get('size')
    if type(manifest_size) is not int or type(signature_size) is not int:
        _incomplete()
    if not (0 < manifest_size <= MAX_MANIFEST_BYTES and
            signature_size == SIGNATURE_BYTES):
        _incomplete()
    return True


def _select_signed_release(fetch_page, admit_signed_release, applied_id,
                           failed_high_water, service=None,
                           max_pages=DEFAULT_MAX_PAGES):
    """Return the highest authenticated eligible release ID, or ``None``.

    ``fetch_page(page_number, MAX_PAGE_ITEMS)`` returns one sequence of
    normalized release dictionaries. The callback is invoked as
    ``admit_signed_release(release, tag_id, applied_id, failed_high_water)`` and
    must return its authenticated numeric ID, or ``None`` for invalid material.
    Its implementation must call the real candidate verifier with pinned trust,
    board/runtime, and both high-water values, assert the signed ID matches the
    tag, and check the API asset inventory against signed names and sizes.
    Selected target bytes and hashes are verified before trial. Selector
    validation independently enforces the returned ID/tag/high-water invariants.
    ``service()`` runs
    immediately before each page, each item, and each admission callback;
    returning exactly ``False`` aborts discovery.

    Pages and candidates are processed incrementally; only one page is retained.
    Any malformed/inconsistent metadata, callback/transport exception, service
    cancellation, or exhausted cap is redacted as ``DiscoveryIncomplete``.
    """
    if (not callable(fetch_page) or not callable(admit_signed_release) or
            type(max_pages) is not int or not 1 <= max_pages <= ABSOLUTE_MAX_PAGES or
            not _high_water(applied_id) or not _high_water(failed_high_water)):
        _incomplete()

    def checkpoint():
        if service is not None:
            try:
                if service() is False:
                    _incomplete()
            except DiscoveryIncomplete:
                _incomplete()
            except Exception:
                _incomplete()

    seen_ids = set()
    seen_tags = set()
    winner = None
    for page_number in range(1, max_pages + 1):
        checkpoint()
        try:
            page = fetch_page(page_number, MAX_PAGE_ITEMS)
        except Exception:
            _incomplete()
        if not isinstance(page, (list, tuple)) or len(page) > MAX_PAGE_ITEMS:
            _incomplete()
        if not page:
            return winner

        for release in page:
            checkpoint()
            if not isinstance(release, dict):
                _incomplete()
            release_id = release.get('id')
            if type(release_id) is not int or release_id <= 0 or release_id in seen_ids:
                _incomplete()
            seen_ids.add(release_id)
            tag = release.get('tag_name')
            if not isinstance(tag, str) or tag in seen_tags:
                _incomplete()
            seen_tags.add(tag)
            tag_id = _release_tag_id(tag)
            draft, prerelease = release.get('draft'), release.get('prerelease')
            if type(draft) is not bool or type(prerelease) is not bool:
                _incomplete()
            # Non-Pico and ineligible release entries are valid metadata but
            # never trigger signature/manifest admission.
            if tag_id is None or draft or prerelease:
                continue
            # Historical signed Pico releases are ordinary list entries. They
            # are not candidates after either high-water and must not invoke
            # the verifier callback (which would correctly reject them).
            if ((applied_id is not None and tag_id <= applied_id) or
                    (failed_high_water is not None and
                     tag_id <= failed_high_water)):
                continue
            if not _asset_metadata(release):
                continue
            checkpoint()
            try:
                admitted = admit_signed_release(
                    release, tag_id, applied_id, failed_high_water)
            except Exception:
                _incomplete()
            if admitted is None:
                continue
            if (type(admitted) is not int or admitted != tag_id or
                    (applied_id is not None and admitted <= applied_id) or
                    (failed_high_water is not None and
                     admitted <= failed_high_water)):
                _incomplete()
            if winner is None or admitted > winner:
                winner = admitted

        if len(page) < MAX_PAGE_ITEMS:
            return winner

    # A full final allowed page requires another page to prove completion.
    _incomplete()


def select_signed_release(fetch_page, admit_signed_release, applied_id,
                          failed_high_water, service=None,
                          max_pages=DEFAULT_MAX_PAGES):
    """Public redacted boundary around release selection callbacks."""
    try:
        return _select_signed_release(fetch_page, admit_signed_release,
                                      applied_id, failed_high_water, service,
                                      max_pages)
    except DiscoveryIncomplete:
        raise DiscoveryIncomplete() from None
