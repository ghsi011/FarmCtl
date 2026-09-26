"""Offline-only validation for an operator-supplied spare-board inventory."""

import argparse
import json
import re
import stat
import sys
from pathlib import Path


_REPOSITORY = Path(__file__).resolve().parents[2]
_FIELDS = {
    'schema_version',
    'purpose',
    'uid_sha256',
    'board',
    'runtime',
    'authorization_reference',
}


class _Blocked(Exception):
    """A validation failure whose details must not be disclosed."""


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        del message
        raise _Blocked


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _Blocked
        result[key] = value
    return result


def _external_regular_file(value):
    path = Path(value)
    if path.is_symlink():
        raise _Blocked
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(_REPOSITORY)
    except ValueError:
        pass
    else:
        raise _Blocked
    if not stat.S_ISREG(resolved.stat().st_mode):
        raise _Blocked
    return resolved


def _validate_inventory(value):
    path = _external_regular_file(value)
    with path.open('rb') as inventory_file:
        raw = inventory_file.read(4097)
    if len(raw) > 4096:
        raise _Blocked
    try:
        data = json.loads(raw.decode('utf-8'), object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise _Blocked from None
    if not isinstance(data, dict) or set(data) != _FIELDS:
        raise _Blocked
    if type(data['schema_version']) is not int or data['schema_version'] != 1:
        raise _Blocked
    if data['purpose'] != 'authorized_spare':
        raise _Blocked
    if data['board'] != 'RPI_PICO2_W' or data['runtime'] != 'v1.29.0':
        raise _Blocked
    digest = data['uid_sha256']
    if not isinstance(digest, str) or re.fullmatch(r'[0-9a-f]{64}', digest) is None:
        raise _Blocked
    reference = data['authorization_reference']
    if not isinstance(reference, str) or re.fullmatch(
        r'(?:ISSUE-[0-9]{1,8}|CHANGE-[0-9]{1,8})', reference
    ) is None:
        raise _Blocked


def _parser():
    parser = _Parser(prog='harness.py', description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    preflight = commands.add_parser('preflight', help='validate offline inventory format')
    preflight.add_argument('--inventory', required=True)
    preflight.add_argument('--port', required=True)
    return parser


def main(argv=None):
    try:
        args = _parser().parse_args(argv)
        if args.command != 'preflight' or re.fullmatch(r'COM[1-9][0-9]*', args.port) is None:
            raise _Blocked
        _validate_inventory(args.inventory)
    except SystemExit as exc:
        if exc.code == 0:
            return 0
        print('BLOCKED', file=sys.stderr)
        return 1
    except _Blocked:
        print('BLOCKED', file=sys.stderr)
        return 1
    except Exception:
        print('BLOCKED', file=sys.stderr)
        return 1
    print('OFFLINE_PREFLIGHT_PASS')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
