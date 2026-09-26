"""Fail-closed private fleet Contents download into isolated candidate files."""

import hashlib
import os

from native_https import HttpFailure, NativeHttpsTransport, TransportFailure

MAX_FLEET_BYTES = 65536
MAX_CANDIDATE_ATTEMPTS = 8
_HEX = b'0123456789abcdef'


class PrivateFleetClient:
    def __init__(self, transport, stage_directory, random_bytes=None,
                 time_is_trusted=None):
        if not isinstance(transport, NativeHttpsTransport) or transport._private_contents is None:
            raise ValueError('private Contents transport required')
        self.transport = transport
        self.stage_directory = _validate_directory(stage_directory)
        self.random_bytes = random_bytes or os.urandom
        self.time_is_trusted = time_is_trusted

    def fetch_to_stage(self, applied_path=None, service=None, time_is_trusted=None):
        """Return (candidate_path, (byte_count, lowercase_sha256)); never apply it."""
        output = None
        created_path = None
        count = 0

        def write_chunk(piece):
            nonlocal count, output, created_path
            if not piece or count + len(piece) > MAX_FLEET_BYTES:
                raise TransportFailure()
            if output is None:
                output, created_path = self._open_candidate(applied_path)
            try:
                written = output.write(piece)
            except Exception:
                raise TransportFailure()
            if written is not None and written != len(piece):
                raise TransportFailure()
            digest.update(piece)
            count += len(piece)

        succeeded = False
        try:
            trusted = time_is_trusted if time_is_trusted is not None else self.time_is_trusted
            if not callable(trusted) or not trusted():
                raise TransportFailure()
            digest = hashlib.sha256()
            self.transport.get_private_contents(write_chunk, service=service)
            if output is None or count == 0:
                raise TransportFailure()
            try:
                output.flush()
            except Exception:
                raise TransportFailure()
            digest_hex = _random_hex(digest.digest())
            succeeded = True
            return created_path, (count, digest_hex)
        except HttpFailure as error:
            # Retain the useful HTTP status, but never expose response headers.
            raise HttpFailure(error.status, {}) from None
        except TransportFailure:
            raise TransportFailure() from None
        except Exception:
            # Filesystem, entropy, hashing and injected transport failures may
            # contain paths, tokens or other private values in their messages.
            raise TransportFailure() from None
        finally:
            close_failed = False
            if output is not None:
                try:
                    output.close()
                except Exception:
                    close_failed = True
                    succeeded = False
            if created_path is not None and not succeeded:
                try:
                    os.remove(created_path)
                except OSError:
                    pass
            if close_failed:
                raise TransportFailure()

    def _open_candidate(self, applied_path):
        for _ in range(MAX_CANDIDATE_ATTEMPTS):
            basename = 'fleet-' + _random_hex(self.random_bytes(12)) + '.candidate'
            candidate_path = self.stage_directory + '/' + basename
            if applied_path is not None and candidate_path == applied_path:
                continue
            try:
                return open(candidate_path, 'xb'), candidate_path
            except OSError:
                # Exclusive create failed; retry with fresh entropy without
                # inspecting, truncating, or deleting the colliding path.
                continue
            except Exception:
                raise TransportFailure()
        raise TransportFailure()


def _validate_directory(directory):
    if not isinstance(directory, str) or not directory or '\x00' in directory:
        raise ValueError('invalid staging directory')
    # Native Pico paths are absolute POSIX paths. Also allow an absolute drive
    # path for host-only tests on Windows; neither form uses os.path.
    if directory.startswith('/'):
        normalized = directory.rstrip('/') or '/'
        segments = normalized.split('/')[1:]
    elif (len(directory) >= 3 and directory[0] in
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ' and
          directory[1:3] in (':/', ':\\')):
        normalized = directory[3:].replace('\\', '/').rstrip('/')
        segments = normalized.split('/') if normalized else []
    else:
        raise ValueError('invalid staging directory')
    if any(segment in ('', '.', '..') for segment in segments):
        raise ValueError('invalid staging directory')
    if '\\' in directory and directory.startswith('/'):
        raise ValueError('invalid staging directory')
    if directory.startswith('/'):
        return normalized
    return directory.rstrip('/\\')


def _random_hex(value):
    if not isinstance(value, (bytes, bytearray)) or not value:
        raise TransportFailure()
    encoded = bytearray(len(value) * 2)
    for index, byte in enumerate(value):
        encoded[index * 2] = _HEX[byte >> 4]
        encoded[index * 2 + 1] = _HEX[byte & 15]
    return bytes(encoded).decode('ascii')
