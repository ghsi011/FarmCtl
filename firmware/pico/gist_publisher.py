"""Bounded GitHub Gist PATCH publisher using the fixed native TLS transport."""

import json

from native_https import (
    HttpFailure as _HttpFailure,
    MAX_REQUEST_BYTES,
    NativeHttpsTransport,
    TransportFailure as _RequestFailure,
)
from gist_readback import (
    GistReadback,
    MAX_DIAGNOSTICS_BYTES,
    MAX_THERMOSTAT_BYTES,
)

THERMOSTAT_FILENAME = 'thermostat.txt'
DIAGNOSTICS_FILENAME = 'diagnostics.json'
INITIAL_BACKOFF_MS = 5000
MAX_BACKOFF_MS = 300000
MAX_RETRY_HINT_MS = 3600000


class GistPublishProofFailure(Exception):
    """Safe result classification for an explicit configuration-trial PATCH."""

    def __init__(self, kind):
        if kind not in ('definite', 'authentication_failed', 'destination_failed',
                        'inconclusive'):
            kind = 'inconclusive'
        self.kind = kind
        super().__init__(kind)


class GistPublisher:
    """Publish telemetry to its two pre-registered Gists."""

    def __init__(self, temperature_gist_id, diagnostics_gist_id, token, root_bytes,
                 tls_module, select_module, socket_module, clock, dns_server_ip, resolver=None,
                 time_is_trusted=None, timeout_ms=15000, service=None):
        if not _is_hex_identifier(temperature_gist_id) or not _is_hex_identifier(diagnostics_gist_id):
            raise ValueError('invalid Gist identifier')
        if temperature_gist_id.lower() == diagnostics_gist_id.lower():
            raise ValueError('temperature and diagnostics Gists must be distinct')
        token_bytes = token.encode() if isinstance(token, str) else bytes(token)
        if not token_bytes or any(byte < 33 or byte > 126 for byte in token_bytes):
            raise ValueError('invalid token')
        if not isinstance(root_bytes, (bytes, bytearray)) or not root_bytes:
            raise ValueError('provisioned CA roots are required')
        self.gist_ids = {
            THERMOSTAT_FILENAME: temperature_gist_id,
            DIAGNOSTICS_FILENAME: diagnostics_gist_id,
        }
        self.transport = NativeHttpsTransport(
            (temperature_gist_id, diagnostics_gist_id), token_bytes, root_bytes,
            tls_module, select_module, socket_module, clock, dns_server_ip,
            resolver, timeout_ms,
        )
        try:
            # Preserve the prior inspectable mutable token buffer for close/scrub.
            self._token = self.transport.token
            self.readback = GistReadback(self.transport, temperature_gist_id,
                                         diagnostics_gist_id)
            self.root_bytes = root_bytes
            self.tls = tls_module
            self.select = select_module
            self.socket = socket_module
            self.clock = clock
            self.time_is_trusted = time_is_trusted
            self.service = service
            self.timeout_ms = timeout_ms
            self._closed = False
            self._backoff = {name: {'failures': 0, 'last_failure': None, 'delay': 0}
                             for name in self.gist_ids}
            self._server_not_before = None
            self._failure_count = 0
        except Exception:
            try:
                self.transport.close()
            except Exception:
                pass
            raise RuntimeError('unable to initialize Gist publisher') from None

    def publish_temperature(self, payload):
        return self._publish(THERMOSTAT_FILENAME, payload)

    def publish_diagnostics(self, payload):
        return self._publish(DIAGNOSTICS_FILENAME, payload)

    def patch_exact_for_trial(self, filename, exact_content, service=None):
        """Write one exact registered file for a configuration trial.

        Unlike telemetry publication this path intentionally bypasses retry and
        backoff state: its result is evidence for the current trial only.
        """
        if self._closed:
            raise GistPublishProofFailure('definite')
        if filename not in (THERMOSTAT_FILENAME, DIAGNOSTICS_FILENAME):
            raise GistPublishProofFailure('definite')
        if not isinstance(exact_content, str):
            raise GistPublishProofFailure('definite')
        try:
            content_bytes = exact_content.encode('utf-8')
        except Exception:
            raise GistPublishProofFailure('definite') from None
        limit = (MAX_THERMOSTAT_BYTES if filename == THERMOSTAT_FILENAME
                 else MAX_DIAGNOSTICS_BYTES)
        if len(content_bytes) > limit:
            raise GistPublishProofFailure('definite')
        if self.time_is_trusted is None:
            raise GistPublishProofFailure('inconclusive')
        try:
            trusted = self.time_is_trusted()
        except Exception:
            raise GistPublishProofFailure('inconclusive') from None
        if not trusted:
            raise GistPublishProofFailure('inconclusive')
        try:
            body = _encode_payload(filename, {'files': {filename: {'content': exact_content}}})
        except Exception:
            raise GistPublishProofFailure('inconclusive') from None
        if len(body) > MAX_REQUEST_BYTES:
            raise GistPublishProofFailure('definite')
        try:
            self.transport.patch_gist(
                self.gist_ids[filename], body,
                service=self.service if service is None else service)
        except _HttpFailure as error:
            if error.status == 401:
                kind = 'authentication_failed'
            elif error.status in (404, 422):
                kind = 'destination_failed'
            else:
                kind = 'inconclusive'
            raise GistPublishProofFailure(kind) from None
        except Exception:
            raise GistPublishProofFailure('inconclusive') from None
        return exact_content

    def confirm_file(self, gist_id, filename, expected_content, service=None):
        return self.readback.confirm_file(
            gist_id, filename, expected_content,
            service=self.service if service is None else service)

    def close(self):
        self.transport.close()
        self._closed = True

    def _publish(self, filename, payload):
        if self._closed:
            return False
        now = self.clock.ticks_ms()
        backoff = self._backoff[filename]
        if backoff['last_failure'] is not None and self._ticks_diff(now, backoff['last_failure']) < backoff['delay']:
            return False
        if self._server_not_before is not None:
            if self._ticks_diff(now, self._server_not_before) < 0:
                return False
            self._server_not_before = None
        try:
            if self.time_is_trusted is None or not self.time_is_trusted():
                raise _RequestFailure()
            body = _encode_payload(filename, payload)
            # The transport accepts only registered Gist IDs and builds its
            # own fixed PATCH path, host, authorization, and headers.
            self.transport.patch_gist(self.gist_ids[filename], body, service=self.service)
        except _HttpFailure as error:
            self._failed(filename, error)
            return False
        except Exception:
            self._failed(filename)
            return False
        backoff['failures'] = 0
        backoff['delay'] = 0
        backoff['last_failure'] = None
        return True

    def _failed(self, filename, http_error=None):
        backoff = self._backoff[filename]
        backoff['failures'] += 1
        self._failure_count += 1
        delay = min(INITIAL_BACKOFF_MS * (2 ** min(backoff['failures'] - 1, 16)), MAX_BACKOFF_MS)
        # Bounded deterministic jitter avoids adding a random dependency on-device.
        delay = min(MAX_BACKOFF_MS, delay + (self._failure_count % 5) * min(1000, delay // 8))
        hint = self._retry_hint_ms(http_error) if http_error else None
        if http_error is not None and http_error.status in (403, 429):
            shared_delay = max(60000, hint or 0)
            self._server_not_before = self._ticks_add(self.clock.ticks_ms(), shared_delay)
            delay = max(delay, shared_delay)
        backoff['delay'] = delay
        # Timestamp completion, not the attempt's start.
        backoff['last_failure'] = self.clock.ticks_ms()

    def _retry_hint_ms(self, error):
        if error.status not in (403, 429) or self.time_is_trusted is None or not self.time_is_trusted():
            return None
        headers = error.headers
        retry = headers.get(b'retry-after')
        delay = None
        if retry is not None and retry.isdigit():
            delay = int(retry) * 1000
        reset = headers.get(b'x-ratelimit-reset')
        epoch = getattr(self.clock, 'time', None)
        if reset is not None and reset.isdigit() and callable(epoch):
            try:
                reset_delay = max(0, int(reset) - int(epoch())) * 1000
                delay = max(delay or 0, reset_delay)
            except Exception:
                pass
        return min(MAX_RETRY_HINT_MS, delay) if delay is not None else None

    def _ticks_diff(self, current, previous):
        ticks_diff = getattr(self.clock, 'ticks_diff', None)
        return ticks_diff(current, previous) if ticks_diff else current - previous

    def _ticks_add(self, value, delta):
        ticks_add = getattr(self.clock, 'ticks_add', None)
        return ticks_add(value, delta) if ticks_add else value + delta


def _is_hex_identifier(identifier):
    return isinstance(identifier, str) and len(identifier) == 32 and all(
        character in '0123456789abcdefABCDEF' for character in identifier)


def _encode_payload(filename, payload):
    if filename not in (THERMOSTAT_FILENAME, DIAGNOSTICS_FILENAME):
        raise _RequestFailure()
    if not isinstance(payload, dict) or set(payload.keys()) != {'files'}:
        raise _RequestFailure()
    files = payload.get('files')
    if not isinstance(files, dict) or set(files.keys()) != {filename}:
        raise _RequestFailure()
    file_info = files[filename]
    if (not isinstance(file_info, dict) or set(file_info.keys()) != {'content'} or
            not isinstance(file_info['content'], str)):
        raise _RequestFailure()
    return json.dumps(payload, separators=(',', ':')).encode()
