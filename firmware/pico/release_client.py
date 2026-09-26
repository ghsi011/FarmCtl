"""Bounded host-only admission of signed public Pico releases."""

from candidate_manifest import CandidateError, verify_candidate
from public_release_paths import release_asset_name
from public_release_transport import PublicReleaseTransport
from release_discovery import (
    DiscoveryIncomplete,
    MAX_MANIFEST_BYTES,
    SIGNATURE_BYTES,
    select_signed_release,
)

MAX_DISCOVERY_MS = 120000


def _incomplete():
    raise DiscoveryIncomplete() from None


def discover_release(transport, public_key, verifier, board, runtime,
                     applied_id, failed_high_water, clock, service=None,
                     max_pages=8):
    """Return authenticated winner bytes/tag, or None after a complete scan.

    Only the two small signed metadata assets are fetched during selection.
    Target payload bytes remain untouched until the selected winner is staged.
    """
    if (not isinstance(transport, PublicReleaseTransport) or
            not isinstance(public_key, bytes) or len(public_key) != 32 or
            not callable(verifier) or
            not callable(getattr(clock, 'ticks_ms', None)) or
            not callable(getattr(clock, 'ticks_diff', None))):
        _incomplete()
    try:
        start = clock.ticks_ms()
        if type(start) is not int:
            _incomplete()
    except Exception:
        _incomplete()

    def checkpoint():
        try:
            now = clock.ticks_ms()
            elapsed = clock.ticks_diff(now, start)
            if (type(now) is not int or type(elapsed) is not int or
                    elapsed < 0 or elapsed >= MAX_DISCOVERY_MS):
                _incomplete()
            if service is not None and service() is False:
                _incomplete()
            # The service callback can do arbitrary work, so enforce the
            # deadline again after it returns as well as before it starts.
            now = clock.ticks_ms()
            elapsed = clock.ticks_diff(now, start)
            if (type(now) is not int or type(elapsed) is not int or
                    elapsed < 0 or elapsed >= MAX_DISCOVERY_MS):
                _incomplete()
        except DiscoveryIncomplete:
            _incomplete()
        except Exception:
            _incomplete()

    def fetch_page(page_number, per_page):
        checkpoint()
        try:
            page = transport.fetch_page(page_number, per_page, service=checkpoint)
        except Exception:
            _incomplete()
        checkpoint()
        return page

    retained = [None]

    def admit(release, tag_id, _applied, _failed):
        checkpoint()
        try:
            manifest_data = bytearray()
            signature_data = bytearray()
            transport.fetch_asset(tag_id, 'manifest.json', manifest_data.extend,
                                  MAX_MANIFEST_BYTES, service=checkpoint)
            checkpoint()
            transport.fetch_asset(tag_id, 'manifest.sig', signature_data.extend,
                                  SIGNATURE_BYTES, expected_size=SIGNATURE_BYTES,
                                  service=checkpoint)
            checkpoint()
            manifest_bytes = bytes(manifest_data)
            signature_bytes = bytes(signature_data)
            if len(manifest_bytes) > MAX_MANIFEST_BYTES or len(signature_bytes) != SIGNATURE_BYTES:
                _incomplete()
            try:
                candidate = verify_candidate(
                    manifest_bytes, signature_bytes, public_key, board, runtime,
                    release.get('tag_name'), applied_id, failed_high_water,
                    verifier=verifier)
            except CandidateError:
                # Invalid signed material is an ineligible candidate, not proof
                # that discovery itself was incomplete.
                return None
            checkpoint()
            if candidate.release_id != tag_id:
                return None
            _validate_inventory(release, candidate.targets, len(manifest_bytes))
            checkpoint()
            if retained[0] is None or candidate.release_id > retained[0][2]:
                retained[0] = (manifest_bytes, signature_bytes, candidate.release_id)
            return candidate.release_id
        except DiscoveryIncomplete:
            raise
        except Exception:
            _incomplete()

    try:
        selected_id = select_signed_release(
            fetch_page, admit, applied_id, failed_high_water,
            service=checkpoint, max_pages=max_pages)
        checkpoint()
        if selected_id is None:
            return None
        winner = retained[0]
        if winner is None or winner[2] != selected_id:
            _incomplete()
        return winner[0], winner[1], 'pico-' + str(winner[2])
    except DiscoveryIncomplete:
        raise DiscoveryIncomplete() from None
    except Exception:
        _incomplete()


def _validate_inventory(release, targets, manifest_size):
    assets = release.get('assets')
    if not isinstance(assets, (list, tuple)):
        _incomplete()
    expected = {
        'manifest.json': manifest_size,
        'manifest.sig': SIGNATURE_BYTES,
    }
    for descriptor in targets:
        name = release_asset_name(descriptor.path)
        if name != descriptor.name or name in expected:
            _incomplete()
        expected[name] = descriptor.size_bytes
    seen_names, seen_ids = set(), set()
    if len(assets) != len(expected):
        _incomplete()
    for asset in assets:
        if not isinstance(asset, dict):
            _incomplete()
        name, size, asset_id = asset.get('name'), asset.get('size'), asset.get('id')
        if (not isinstance(name, str) or name in seen_names or name not in expected or
                type(asset_id) is not int or asset_id <= 0 or asset_id in seen_ids or
                type(size) is not int or size < 0 or size != expected[name] or
                (name in ('manifest.json', 'manifest.sig') and size == 0)):
            _incomplete()
        seen_names.add(name)
        seen_ids.add(asset_id)
    if seen_names != set(expected):
        _incomplete()
