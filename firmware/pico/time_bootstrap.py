"""Bounded, unauthenticated NTP hint for cold-boot RTC initialization.

This is only a wall-clock hint. It does not authenticate time and must not be
treated as a TLS trust anchor; callers must independently check the RTC before
using HTTPS.
"""

POLL_INTERVAL_MS = 250
DEFAULT_DEADLINE_MS = 10000
MAX_PACKET_BYTES = 128
NTP_PORT = 123
NTP_UNIX_DELTA = 2208988800
MIN_UNIX_SECONDS = 1704067200  # 2024-01-01T00:00:00Z
MAX_UNIX_SECONDS = 4133980800  # 2101-01-01T00:00:00Z, exclusive

try:
    import os
    _system_random_bytes = os.urandom
except (ImportError, AttributeError):
    _system_random_bytes = None


class _BootstrapError(Exception):
    pass


def bootstrap_utc(ntp_server_ip, socket_module, select_module, clock,
                  rtc_set_utc, service=None, deadline_ms=DEFAULT_DEADLINE_MS,
                  random_bytes=None):
    """Try one bounded NTP exchange; return a redacted ``usable`` outcome.

    ``ntp_server_ip`` must be a numeric IPv4 address; no name resolution is
    performed. The injected random source should be backed by ``os.urandom``.
    """
    if not _is_ipv4(ntp_server_ip):
        return _failure('configuration')
    if not isinstance(deadline_ms, int) or deadline_ms <= 0 or deadline_ms > DEFAULT_DEADLINE_MS:
        return _failure('configuration')
    if not callable(rtc_set_utc):
        return _failure('configuration')
    if random_bytes is None:
        random_bytes = _system_random_bytes
    if random_bytes is None:
        return _failure('randomness')

    try:
        nonce = random_bytes(8)
        if len(nonce) != 8:
            return _failure('randomness')
        request = bytearray(48)
        request[0] = 0x23  # LI=0, VN=4, client mode=3
        request[40:48] = nonce
    except Exception:
        return _failure('randomness')

    start = clock.ticks_ms()
    sock = None
    try:
        sock = socket_module.socket(socket_module.AF_INET, socket_module.SOCK_DGRAM)
        sock.setblocking(False)
        poller = select_module.poll()
        poller.register(sock, getattr(select_module, 'POLLIN', 1))
        _service_or_cancel(service)
        sock.sendto(bytes(request), (ntp_server_ip, NTP_PORT))

        while True:
            elapsed = _ticks_diff(clock, clock.ticks_ms(), start)
            if elapsed > deadline_ms:
                raise _BootstrapError()
            remaining = deadline_ms - elapsed
            ready = poller.poll(min(POLL_INTERVAL_MS, remaining))
            if ready:
                try:
                    packet, source = sock.recvfrom(MAX_PACKET_BYTES + 1)
                except Exception as error:
                    if not _would_block(error):
                        raise _BootstrapError()
                    packet = None
                    source = None
                if packet is not None and source == (ntp_server_ip, NTP_PORT):
                    unix_seconds = _parse_reply(packet, nonce)
                    if unix_seconds is not None:
                        # The instant at the deadline remains usable, but anything
                        # observed after it is rejected.
                        if _ticks_diff(clock, clock.ticks_ms(), start) > deadline_ms:
                            raise _BootstrapError()
                        _service_or_cancel(service)
                        try:
                            rtc_set_utc(unix_seconds)
                        except Exception:
                            raise _BootstrapError()
                        return {'usable': True, 'unix_seconds': unix_seconds}
            if service is not None:
                _service_or_cancel(service)
            if _ticks_diff(clock, clock.ticks_ms(), start) >= deadline_ms:
                raise _BootstrapError()
    except Exception:
        return _failure('unavailable')
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass


def _parse_reply(packet, nonce):
    if len(packet) < 48 or len(packet) > MAX_PACKET_BYTES:
        raise _BootstrapError()
    if packet[24:32] != nonce:
        # A datagram from the configured endpoint without our nonce is stale or
        # unrelated; ignore it rather than treating it as this transaction.
        return None
    first = packet[0]
    leap = first >> 6
    version = (first >> 3) & 7
    mode = first & 7
    stratum = packet[1]
    if leap == 3 or version not in (3, 4) or mode != 4 or not 1 <= stratum <= 15:
        raise _BootstrapError()
    seconds = ((packet[40] << 24) | (packet[41] << 16) |
               (packet[42] << 8) | packet[43])
    if seconds == 0:
        raise _BootstrapError()
    unix_seconds = _plausible_unix_seconds(seconds)
    if unix_seconds is None:
        raise _BootstrapError()
    return unix_seconds


def _plausible_unix_seconds(ntp_seconds):
    # NTP's 32-bit seconds field wraps in 2036. Check both relevant eras and
    # accept only a candidate in the explicit plausible UTC interval.
    for era in (0, 1):
        candidate = ((era << 32) | ntp_seconds) - NTP_UNIX_DELTA
        if MIN_UNIX_SECONDS <= candidate < MAX_UNIX_SECONDS:
            return candidate
    return None


def _failure(reason):
    return {'usable': False, 'reason': reason}


def _service_or_cancel(service):
    if service is None:
        return
    try:
        if service() is False:
            raise _BootstrapError()
    except _BootstrapError:
        raise
    except Exception:
        raise _BootstrapError()


def _is_ipv4(value):
    if not isinstance(value, str):
        return False
    pieces = value.split('.')
    if len(pieces) != 4:
        return False
    for piece in pieces:
        if not piece or not piece.isdigit() or (len(piece) > 1 and piece[0] == '0'):
            return False
        try:
            number = int(piece)
        except Exception:
            return False
        if number > 255:
            return False
    return True


def _ticks_diff(clock, current, previous):
    fn = getattr(clock, 'ticks_diff', None)
    return fn(current, previous) if fn is not None else current - previous


def _would_block(error):
    code = getattr(error, 'errno', None)
    return code in (11, 35, 10035)
