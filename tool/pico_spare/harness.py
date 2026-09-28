"""Validate an operator-supplied spare inventory offline or compare probe identity."""

import argparse
import hashlib
import json
import re
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path


_REPOSITORY = Path(__file__).resolve().parents[2]
_V1_FIELDS = {
    'schema_version',
    'purpose',
    'uid_sha256',
    'board',
    'runtime',
    'authorization_reference',
}
_V2_FIELDS = _V1_FIELDS | {'expected_uname_machine', 'expected_uname_release'}
_SENTINEL = 'PICO_SPARE_IDENTITY:'
_MAX_CAPTURE = 4096
_PROBE_TIMEOUT = 10
_CLEANUP_GRACE = 0.25
_FIXED_CODE = (
    "import machine,os,json,ubinascii; u=os.uname(); "
    "print('PICO_SPARE_IDENTITY:'+json.dumps({"
    "'uid_hex':ubinascii.hexlify(machine.unique_id()).decode(),"
    "'uname_machine':u.machine,'uname_release':u.release}))"
)


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
    if not isinstance(data, dict):
        raise _Blocked
    version = data.get('schema_version')
    expected_fields = _V1_FIELDS if type(version) is int and version == 1 else (
        _V2_FIELDS if type(version) is int and version == 2 else None
    )
    if expected_fields is None or set(data) != expected_fields:
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
    if version == 2:
        for field in ('expected_uname_machine', 'expected_uname_release'):
            if not _printable_ascii(data[field]):
                raise _Blocked
    return data


def _printable_ascii(value):
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 256
        and all(0x20 <= ord(character) <= 0x7e for character in value)
    )


def _read_bounded(stream):
    capture = bytearray()
    while True:
        read = getattr(stream, 'read1', stream.read)
        chunk = read(1024)
        if not chunk:
            return bytes(capture), False
        remaining = _MAX_CAPTURE + 1 - len(capture)
        capture.extend(chunk[:remaining])
        if len(chunk) > remaining or len(capture) > _MAX_CAPTURE:
            return bytes(capture), True


def _run_bounded(argv):
    process = subprocess.Popen(
        argv,
        shell=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    captures = {'stdout': b'', 'stderr': b''}
    overflow = threading.Event()
    reader_error = threading.Event()

    def drain(name, stream):
        try:
            captures[name], exceeded = _read_bounded(stream)
            if exceeded:
                overflow.set()
        except Exception:
            reader_error.set()

    readers = [
        threading.Thread(target=drain, args=(name, getattr(process, name)), daemon=True)
        for name in ('stdout', 'stderr')
    ]
    deadline = time.monotonic() + _PROBE_TIMEOUT
    try:
        for reader in readers:
            reader.start()
        while True:
            if overflow.is_set() or reader_error.is_set():
                raise _Blocked
            returncode = process.poll()
            if returncode is not None and not any(reader.is_alive() for reader in readers):
                if overflow.is_set() or reader_error.is_set():
                    raise _Blocked
                break
            if time.monotonic() >= deadline:
                raise _Blocked
            time.sleep(0.01)
        result = returncode, captures['stdout'], captures['stderr']
    except BaseException:
        cleanup_deadline = time.monotonic() + _CLEANUP_GRACE
        try:
            still_running = process.poll() is None
        except Exception:
            still_running = True
        if still_running:
            try:
                process.kill()
            except Exception:
                pass
        try:
            process.wait(timeout=max(0, cleanup_deadline - time.monotonic()))
        except Exception:
            pass
        for reader in readers:
            if reader.ident is not None:
                reader.join(timeout=max(0, cleanup_deadline - time.monotonic()))
        # Closing a buffered pipe while its reader is blocked in read() can wait
        # on the same internal lock. Leave such pipes alone; the daemon readers
        # are a deliberate residual only when child/pipe state is unknown.
        if not any(reader.is_alive() for reader in readers):
            for stream_name in ('stdout', 'stderr'):
                try:
                    getattr(process, stream_name).close()
                except Exception:
                    pass
        raise
    else:
        for stream_name in ('stdout', 'stderr'):
            try:
                getattr(process, stream_name).close()
            except Exception:
                pass
        for reader in readers:
            if reader.ident is not None:
                reader.join()
    return result


def _probe(port, inventory):
    if inventory['schema_version'] != 2:
        raise _Blocked
    try:
        returncode, stdout_bytes, stderr_bytes = _run_bounded(
            ['mpremote', 'connect', 'port:' + port, 'resume', 'exec', _FIXED_CODE]
        )
        stdout = stdout_bytes.decode('utf-8')
    except Exception:
        raise _Blocked from None
    if returncode != 0 or stderr_bytes or len(stdout_bytes) > _MAX_CAPTURE:
        raise _Blocked
    try:
        lines = stdout.splitlines()
        if len(lines) != 1 or not lines[0].startswith(_SENTINEL):
            raise _Blocked
        payload = lines[0][len(_SENTINEL):]
        identity, end = json.JSONDecoder(object_pairs_hook=_unique_object).raw_decode(payload)
        if end != len(payload):
            raise _Blocked
        if not isinstance(identity, dict) or set(identity) != {
            'uid_hex', 'uname_machine', 'uname_release'
        }:
            raise _Blocked
        uid_hex = identity['uid_hex']
        if (not isinstance(uid_hex, str) or not 0 < len(uid_hex) <= 64
                or len(uid_hex) % 2 or re.fullmatch(r'[0-9a-f]+', uid_hex) is None):
            raise _Blocked
        uid_digest = hashlib.sha256(bytes.fromhex(uid_hex)).hexdigest()
        if (uid_digest != inventory['uid_sha256']
                or identity['uname_machine'] != inventory['expected_uname_machine']
                or identity['uname_release'] != inventory['expected_uname_release']
                or not _printable_ascii(identity['uname_machine'])
                or not _printable_ascii(identity['uname_release'])):
            raise _Blocked
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
        raise _Blocked from None


def _parser():
    parser = _Parser(prog='harness.py', description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    preflight = commands.add_parser('preflight', help='validate offline inventory format')
    preflight.add_argument('--inventory', required=True)
    preflight.add_argument('--port', required=True)
    probe = commands.add_parser(
        'probe', help='compare identity; may interrupt running board code'
    )
    probe.add_argument('--inventory', required=True)
    probe.add_argument('--port', required=True)
    probe.add_argument('--ack-interruption', action='store_true')
    return parser


def main(argv=None):
    try:
        args = _parser().parse_args(argv)
        if re.fullmatch(r'COM[1-9][0-9]*', args.port) is None:
            raise _Blocked
        inventory = _validate_inventory(args.inventory)
        if args.command == 'preflight':
            print('OFFLINE_PREFLIGHT_PASS')
            return 0
        if not args.ack_interruption or inventory['schema_version'] != 2:
            raise _Blocked
        _probe(args.port, inventory)
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
    print('IDENTITY_MATCH')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
