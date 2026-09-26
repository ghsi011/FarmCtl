"""Fail-closed, bounded readback of the two registered configuration Gists."""

import json

from native_https import HttpFailure, MAX_GIST_JSON_BYTES

THERMOSTAT_FILENAME = 'thermostat.txt'
DIAGNOSTICS_FILENAME = 'diagnostics.json'
MAX_THERMOSTAT_BYTES = 256
MAX_DIAGNOSTICS_BYTES = 16 * 1024


class GistReadbackFailure(Exception):
    """Safe classification; never carries response, path, or credential data."""

    def __init__(self, kind):
        if kind not in ('definite', 'inconclusive', 'authentication_failed',
                        'destination_failed'):
            kind = 'inconclusive'
        self.kind = kind
        super().__init__(kind)


class GistReadback:
    def __init__(self, transport, temperature_gist_id, diagnostics_gist_id):
        self.transport = transport
        self.gist_ids = {
            THERMOSTAT_FILENAME: temperature_gist_id,
            DIAGNOSTICS_FILENAME: diagnostics_gist_id,
        }

    def confirm_file(self, gist_id, filename, expected_content, service=None):
        """Return True only when API JSON echoes exactly the expected file content."""
        if filename not in (THERMOSTAT_FILENAME, DIAGNOSTICS_FILENAME):
            raise GistReadbackFailure('definite')
        registered = self.gist_ids[filename]
        if (not isinstance(gist_id, str) or not isinstance(registered, str) or
                gist_id.lower() != registered.lower() or
                not isinstance(expected_content, str)):
            raise GistReadbackFailure('definite')
        try:
            expected_bytes = expected_content.encode('utf-8')
        except Exception:
            raise GistReadbackFailure('definite') from None
        limit = MAX_THERMOSTAT_BYTES if filename == THERMOSTAT_FILENAME else MAX_DIAGNOSTICS_BYTES
        if len(expected_bytes) > limit:
            raise GistReadbackFailure('definite')

        body = bytearray()
        try:
            self.transport.get_gist_json(gist_id, body.extend, service=service)
        except HttpFailure as error:
            if error.status == 401:
                kind = 'authentication_failed'
            elif error.status == 404:
                kind = 'destination_failed'
            else:
                kind = 'inconclusive'
            raise GistReadbackFailure(kind) from None
        except Exception:
            raise GistReadbackFailure('inconclusive') from None
        if len(body) > MAX_GIST_JSON_BYTES:
            raise GistReadbackFailure('definite')
        try:
            document = json.loads(bytes(body).decode('utf-8'))
        except Exception:
            raise GistReadbackFailure('definite') from None
        echoed_id = document.get('id') if isinstance(document, dict) else None
        if (not isinstance(document, dict) or not isinstance(echoed_id, str) or
                echoed_id.lower() != gist_id.lower()):
            raise GistReadbackFailure('definite')
        if document.get('truncated') is not False:
            raise GistReadbackFailure('definite')
        files = document.get('files')
        if not isinstance(files, dict) or filename not in files:
            raise GistReadbackFailure('definite')
        file_info = files.get(filename)
        if not isinstance(file_info, dict) or not isinstance(file_info.get('content'), str):
            raise GistReadbackFailure('definite')
        if file_info['content'] != expected_content:
            raise GistReadbackFailure('definite')
        return True
