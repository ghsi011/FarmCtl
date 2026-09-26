"""Small bounded DNS A resolver for the Pico 2 W MicroPython runtime.

The resolver is deliberately limited to the public GitHub API and release
hosts. It does not perform system name resolution and must be given a numeric
DNS server address by its caller.
"""

import errno

try:
    import os
    _system_random_bytes = os.urandom
except (ImportError, AttributeError):
    _system_random_bytes = None

API_HOST = 'api.github.com'
ALLOWED_HOSTS = (API_HOST, 'github.com', 'release-assets.githubusercontent.com')
DNS_PORT = 53
MAX_PACKET_BYTES = 512
MAX_RECORDS = 32
MAX_ANSWERS = 16
MAX_CNAME_HOPS = 4
MAX_QUERIES = 2
DEFAULT_DEADLINE_MS = 15000
POLL_INTERVAL_MS = 250


class DnsFailure(Exception):
    """Redacted, safe-to-report DNS resolution failure."""


def resolve_ipv4(host, dns_server_ip, socket_module, select_module, clock,
                 service=None, deadline_ms=DEFAULT_DEADLINE_MS,
                 random_bytes=None):
    """Return one native getaddrinfo-style AF_INET/SOCK_STREAM result.

    Both the socket wait and optional cooperative service callback share one
    absolute deadline. ``random_bytes`` is injectable for host-side tests; in
    production it should be backed by ``os.urandom``.
    """
    if host not in ALLOWED_HOSTS or not _is_ipv4(dns_server_ip):
        raise DnsFailure()
    if type(deadline_ms) is not int or deadline_ms <= 0:
        raise DnsFailure()
    if not callable(getattr(clock, 'ticks_ms', None)) or not callable(
            getattr(clock, 'ticks_diff', None)):
        raise DnsFailure()
    if random_bytes is None:
        random_bytes = _system_random_bytes
    if random_bytes is None:
        raise DnsFailure()
    try:
        identifier_bytes = random_bytes(2)
        if len(identifier_bytes) != 2:
            raise DnsFailure()
        identifier = (identifier_bytes[0] << 8) | identifier_bytes[1]
    except DnsFailure:
        raise
    except Exception:
        raise DnsFailure()

    start = clock.ticks_ms()
    sock = None
    try:
        sock = socket_module.socket(socket_module.AF_INET, socket_module.SOCK_DGRAM)
        sock.setblocking(False)
        poller = select_module.poll()
        poller.register(sock, getattr(select_module, 'POLLIN', 1))
        target = host
        query_count = 0
        cname_hops = 0
        while query_count < MAX_QUERIES:
            _check_deadline(clock, start, deadline_ms)
            query_count += 1
            query = _make_query(identifier, target)
            try:
                sock.sendto(query, (dns_server_ip, DNS_PORT))
            except Exception:
                raise DnsFailure()
            response = None
            while response is None:
                remaining = _remaining(clock, start, deadline_ms)
                try:
                    ready = poller.poll(min(POLL_INTERVAL_MS, remaining))
                except Exception:
                    raise DnsFailure()
                if ready:
                    try:
                        packet, source = sock.recvfrom(MAX_PACKET_BYTES + 1)
                    except Exception as error:
                        if _is_would_block(error):
                            packet = None
                        else:
                            raise DnsFailure()
                    if packet is not None and source == (dns_server_ip, DNS_PORT):
                        if len(packet) < 2:
                            raise DnsFailure()
                        # Ignore packets for another outstanding DNS transaction
                        # before applying size and content checks to this reply.
                        if _u16(packet, 0) == identifier:
                            if len(packet) > MAX_PACKET_BYTES:
                                raise DnsFailure()
                            response = _parse_response(packet, identifier, target)
                if service is not None:
                    try:
                        if service() is False:
                            raise DnsFailure()
                    except DnsFailure:
                        raise
                    except Exception:
                        raise DnsFailure()
                _check_deadline(clock, start, deadline_ms)
            if response is None:
                continue
            cnames, addresses = response
            current = target
            chain_seen = [current]
            while True:
                address = addresses.get(current)
                if address is not None:
                    if not _is_public_ipv4(address):
                        raise DnsFailure()
                    return ((socket_module.AF_INET, socket_module.SOCK_STREAM,
                             socket_module.IPPROTO_TCP, '', (address, 443)),)
                alias = cnames.get(current)
                if alias is None:
                    break
                cname_hops += 1
                if cname_hops > MAX_CNAME_HOPS or alias in chain_seen:
                    raise DnsFailure()
                chain_seen.append(alias)
                current = alias
            if query_count >= MAX_QUERIES or current == target:
                raise DnsFailure()
            target = current
        raise DnsFailure()
    except DnsFailure:
        raise
    except Exception:
        raise DnsFailure()
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass


def _make_query(identifier, name):
    labels = name.split('.')
    packet = bytearray((identifier >> 8, identifier & 255, 1, 0, 0, 1,
                        0, 0, 0, 0, 0, 0))
    for label in labels:
        encoded = label.encode('ascii')
        if not encoded or len(encoded) > 63:
            raise DnsFailure()
        packet.append(len(encoded))
        packet.extend(encoded)
    packet.extend(b'\0\0\1\0\1')
    if len(packet) > MAX_PACKET_BYTES:
        raise DnsFailure()
    return bytes(packet)


def _parse_response(packet, identifier, question_name):
    if len(packet) < 12 or len(packet) > MAX_PACKET_BYTES:
        raise DnsFailure()
    if _u16(packet, 0) != identifier:
        raise DnsFailure()
    flags = _u16(packet, 2)
    if not flags & 0x8000 or flags & 0x7800 or flags & 0x0200 or flags & 0x000f:
        raise DnsFailure()
    qd, an, ns, ar = _u16(packet, 4), _u16(packet, 6), _u16(packet, 8), _u16(packet, 10)
    if qd != 1 or an > MAX_ANSWERS or an + ns + ar > MAX_RECORDS:
        raise DnsFailure()
    offset = 12
    qname, offset = _decode_name(packet, offset)
    if offset + 4 > len(packet):
        raise DnsFailure()
    question_matches = (_u16(packet, offset) == 1 and
                        _u16(packet, offset + 2) == 1 and
                        qname == question_name)
    offset += 4
    cnames = {}
    addresses = {}
    for index in range(an + ns + ar):
        owner, offset = _decode_name(packet, offset)
        if offset + 10 > len(packet):
            raise DnsFailure()
        record_type = _u16(packet, offset)
        record_class = _u16(packet, offset + 2)
        ttl = _u32(packet, offset + 4)
        length = _u16(packet, offset + 8)
        data_offset = offset + 10
        end = data_offset + length
        if end > len(packet) or ttl > 2147483647:
            raise DnsFailure()
        # Ignore non-IN and non-answer records after validating their bounds.
        if index < an and record_class == 1:
            if record_type == 1:
                if length != 4:
                    raise DnsFailure()
                addresses[owner] = '%d.%d.%d.%d' % tuple(packet[data_offset:end])
            elif record_type == 5:
                alias, alias_end = _decode_name(packet, data_offset)
                if alias_end != end or not _valid_dns_name(alias):
                    raise DnsFailure()
                if owner in cnames and cnames[owner] != alias:
                    raise DnsFailure()
                cnames[owner] = alias
        offset = end
    if offset != len(packet):
        raise DnsFailure()
    # A records may precede the CNAME that introduces their owner; allow only
    # owners reachable through the validated CNAME graph when consuming below.
    if not question_matches:
        return None
    return cnames, addresses


def _decode_name(packet, offset):
    if offset < 0 or offset >= len(packet):
        raise DnsFailure()
    labels = []
    position = offset
    consumed = None
    visited = []
    jumps = 0
    wire_length = 1
    while True:
        if position >= len(packet):
            raise DnsFailure()
        length = packet[position]
        if length & 0xc0 == 0xc0:
            if position + 1 >= len(packet):
                raise DnsFailure()
            pointer = ((length & 0x3f) << 8) | packet[position + 1]
            if pointer >= position or pointer >= len(packet) or pointer in visited or jumps >= 16:
                raise DnsFailure()
            visited.append(pointer)
            jumps += 1
            if consumed is None:
                consumed = position + 2
            position = pointer
            continue
        if length & 0xc0 or length > 63:
            raise DnsFailure()
        position += 1
        if length == 0:
            if consumed is None:
                consumed = position
            break
        if position + length > len(packet):
            raise DnsFailure()
        wire_length += length + 1
        if wire_length > 255:
            raise DnsFailure()
        label = packet[position:position + length]
        if any(byte < 33 or byte > 126 or byte == 46 for byte in label):
            raise DnsFailure()
        labels.append(bytes(label).decode('ascii').lower())
        position += length
    name = '.'.join(labels)
    if not _valid_dns_name(name):
        raise DnsFailure()
    return name, consumed


def _valid_dns_name(name):
    if not name or len(name) > 253:
        return False
    for label in name.split('.'):
        if not label or len(label) > 63 or label[0] == '-' or label[-1] == '-':
            return False
        for char in label:
            if not (char.isalnum() or char == '-'):
                return False
    return True


def _is_ipv4(address):
    if not isinstance(address, str):
        return False
    parts = address.split('.')
    if len(parts) != 4:
        return False
    for part in parts:
        if not part or not part.isdigit() or (len(part) > 1 and part[0] == '-'):
            return False
        value = int(part)
        if value > 255 or str(value) != part:
            return False
    return True


def _is_public_ipv4(address):
    if not _is_ipv4(address):
        return False
    a, b, c, d = [int(part) for part in address.split('.')]
    if a == 0 or a == 10 or a == 127 or a >= 224:
        return False
    if a == 100 and 64 <= b <= 127:
        return False
    if a == 169 and b == 254 or a == 172 and 16 <= b <= 31:
        return False
    if a == 192 and b == 168:
        return False
    if a == 192 and b == 0 and c == 0 or a == 192 and b == 0 and c == 2:
        return False
    if a == 192 and b == 88 and c == 99:
        return False
    if a == 198 and b in (18, 19) or a == 198 and b == 51 and c == 100:
        return False
    if a == 203 and b == 0 and c == 113:
        return False
    if a == 255 and b == 255 and c == 255 and d == 255:
        return False
    return True


def _u16(packet, offset):
    if offset + 2 > len(packet):
        raise DnsFailure()
    return (packet[offset] << 8) | packet[offset + 1]


def _u32(packet, offset):
    return (_u16(packet, offset) << 16) | _u16(packet, offset + 2)


def _elapsed(clock, start):
    try:
        current = clock.ticks_ms()
        if type(current) is not int or type(start) is not int:
            raise ValueError()
        elapsed = clock.ticks_diff(current, start)
        if type(elapsed) is not int or elapsed < 0:
            raise ValueError()
        return elapsed
    except Exception:
        raise DnsFailure()


def _remaining(clock, start, deadline):
    if type(deadline) is not int or deadline <= 0:
        raise DnsFailure()
    value = deadline - _elapsed(clock, start)
    if value <= 0:
        raise DnsFailure()
    return value


def _check_deadline(clock, start, deadline):
    _remaining(clock, start, deadline)


def _is_would_block(error):
    transient = (getattr(errno, 'EAGAIN', 11), getattr(errno, 'EWOULDBLOCK', 11))
    return getattr(error, 'errno', None) in transient
