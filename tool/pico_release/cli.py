"""Local fixture builder/verifier; this tool does not publish releases."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

from .manifest import MAX_MANIFEST_BYTES, ManifestError, build_candidate, verify_candidate


def _read_manifest(path: Path) -> bytes:
    """Read no more than one byte beyond the verifier's manifest limit."""
    with path.open('rb') as manifest_file:
        data = manifest_file.read(MAX_MANIFEST_BYTES + 1)
    if len(data) > MAX_MANIFEST_BYTES:
        raise ManifestError('manifest exceeds v1 byte limit')
    return data


def _private_key(data: bytes) -> Ed25519PrivateKey:
    if len(data) == 32:
        return Ed25519PrivateKey.from_private_bytes(data)
    try:
        key = serialization.load_pem_private_key(data, password=None)
    except ValueError:
        key = serialization.load_der_private_key(data, password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ManifestError('private key is not Ed25519')
    return key


def _public_key(data: bytes) -> bytes:
    if len(data) == 32:
        return data
    try:
        key = serialization.load_pem_public_key(data)
    except ValueError:
        key = serialization.load_der_public_key(data)
    if not isinstance(key, Ed25519PublicKey):
        raise ManifestError('public key is not Ed25519')
    return key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def _read_assets(root: Path) -> dict[str, bytes]:
    if not root.is_dir():
        raise ManifestError('assets directory does not exist')
    result = {}
    for path in root.rglob('*'):
        if path.is_symlink():
            raise ManifestError('symlink assets are not allowed')
        if path.is_file():
            result[path.relative_to(root).as_posix()] = path.read_bytes()
        elif path.is_dir() and path != root and path.relative_to(root).as_posix() != 'lib':
            raise ManifestError('nested unknown asset directory')
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sign = sub.add_parser('sign', help='build and sign local candidate fixture')
    sign.add_argument('--release-id', type=int, required=True)
    sign.add_argument('--min-runtime', required=True)
    sign.add_argument('--assets', type=Path, required=True)
    sign.add_argument('--private-key', type=Path, required=True)
    sign.add_argument('--output', type=Path, required=True)
    verify = sub.add_parser('verify', help='verify a local signed candidate fixture')
    verify.add_argument('--manifest', type=Path, required=True)
    verify.add_argument('--signature', type=Path, required=True)
    verify.add_argument('--assets', type=Path, required=True)
    verify.add_argument('--public-key', type=Path, required=True)
    verify.add_argument('--tag', required=True)
    verify.add_argument('--board', default='RPI_PICO2_W')
    verify.add_argument('--runtime', required=True)
    verify.add_argument('--applied-id', type=int)
    verify.add_argument('--failed-id', type=int)
    args = parser.parse_args(argv)
    try:
        if args.command == 'sign':
            manifest, signature = build_candidate(
                args.release_id, args.min_runtime, _read_assets(args.assets),
                _private_key(args.private_key.read_bytes()),
            )
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / 'manifest.json').write_bytes(manifest)
            (args.output / 'manifest.sig').write_bytes(signature)
            print('candidate manifest and signature written')
        else:
            manifest = _read_manifest(args.manifest)
            verify_candidate(
                manifest, args.signature.read_bytes(), _read_assets(args.assets),
                _public_key(args.public_key.read_bytes()), args.board, args.runtime,
                args.tag, args.applied_id, args.failed_id,
            )
            print('candidate verified')
        return 0
    except (ManifestError, OSError, ValueError, TypeError):
        # Exception details may contain local paths or sensitive input; keep
        # diagnostics deliberately generic.
        print('error: invalid candidate input', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
