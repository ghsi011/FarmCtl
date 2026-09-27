import errno
import unittest

import bounded_dns


def _name(value):
    result = bytearray()
    for label in value.split('.'):
        encoded = label.encode('ascii')
        result.append(len(encoded))
        result.extend(encoded)
    result.append(0)
    return bytes(result)


def _question(name='api.github.com'):
    return _name(name) + b'\x00\x01\x00\x01'


def _a_record(address, owner=b'\xc0\x0c', ttl=60):
    return owner + b'\x00\x01\x00\x01' + ttl.to_bytes(4, 'big') + b'\x00\x04' + bytes(
        int(part) for part in address.split('.'))


def _cname_record(target, owner=b'\xc0\x0c'):
    target_wire = _name(target)
    return (owner + b'\x00\x05\x00\x01\x00\x00\x00\x3c' +
            len(target_wire).to_bytes(2, 'big') + target_wire)


def _reply(records=(), identifier=0x1234, question='api.github.com',
           flags=0x8180, qd=1, an=None, ns=0, ar=0):
    if an is None:
        an = len(records)
    return (identifier.to_bytes(2, 'big') + flags.to_bytes(2, 'big') +
            qd.to_bytes(2, 'big') + an.to_bytes(2, 'big') +
            ns.to_bytes(2, 'big') + ar.to_bytes(2, 'big') +
            _question(question) + b''.join(records))


class FakeClock:
    def __init__(self, start=0, modulus=1 << 30):
        self.now = start
        self.modulus = modulus

    def ticks_ms(self):
        return self.now % self.modulus

    def ticks_diff(self, current, previous):
        half = self.modulus // 2
        return ((current - previous + half) % self.modulus) - half


class FakeSocket:
    def __init__(self, packets, clock, source=('8.8.8.8', 53),
                 receive_advance_ms=0):
        self.packets = list(packets)
        self.clock = clock
        self.source = source
        self.receive_advance_ms = receive_advance_ms
        self.sent = []
        self.closed = False

    def setblocking(self, flag):
        self.blocking = flag

    def sendto(self, data, address):
        self.sent.append((data, address))

    def recvfrom(self, size):
        if not self.packets:
            raise OSError(errno.EAGAIN, 'would block')
        packet, source = self.packets.pop(0)
        self.clock.now += self.receive_advance_ms
        return packet[:size], source

    def close(self):
        self.closed = True


class FakePoll:
    def __init__(self, sock, clock):
        self.sock = sock
        self.clock = clock

    def register(self, sock, events):
        self.registered = (sock, events)

    def poll(self, timeout):
        if self.sock.packets:
            return [(self.sock, 1)]
        self.clock.now += timeout
        return []


class FakeSelect:
    POLLIN = 1

    def __init__(self, sock, clock):
        self.sock = sock
        self.clock = clock

    def poll(self):
        return FakePoll(self.sock, self.clock)


class FakeSocketModule:
    AF_INET = 2
    SOCK_DGRAM = 2
    SOCK_STREAM = 1
    IPPROTO_TCP = 6

    def __init__(self, packets, clock, source=('8.8.8.8', 53),
                 receive_advance_ms=0):
        self.sock = FakeSocket(packets, clock, source, receive_advance_ms)

    def socket(self, family, kind):
        self.created = (family, kind)
        return self.sock


class BoundedDnsTests(unittest.TestCase):
    def _resolve(self, packets, **kwargs):
        clock = kwargs.pop('clock', FakeClock())
        host = kwargs.pop('host', 'api.github.com')
        source = kwargs.pop('source', ('8.8.8.8', 53))
        receive_advance_ms = kwargs.pop('receive_advance_ms', 0)
        socket_module = FakeSocketModule(packets, clock, source, receive_advance_ms)
        select_module = FakeSelect(socket_module.sock, clock)
        service_calls = []
        service = kwargs.pop('service', lambda: service_calls.append(clock.now))
        result = bounded_dns.resolve_ipv4(
            host, '8.8.8.8', socket_module, select_module, clock,
            service=service, random_bytes=lambda size: b'\x12\x34', **kwargs)
        return result, socket_module.sock, service_calls, clock

    def _assert_failure(self, packets, **kwargs):
        clock = kwargs.pop('clock', FakeClock())
        source = kwargs.pop('source', ('8.8.8.8', 53))
        receive_advance_ms = kwargs.pop('receive_advance_ms', 0)
        socket_module = FakeSocketModule(packets, clock, source, receive_advance_ms)
        select_module = FakeSelect(socket_module.sock, clock)
        callbacks = []
        service = kwargs.pop('service', lambda: callbacks.append(clock.now))
        with self.assertRaises(bounded_dns.DnsFailure):
            bounded_dns.resolve_ipv4(
                'api.github.com', '8.8.8.8', socket_module, select_module,
                clock, service=service, random_bytes=lambda size: b'\x12\x34',
                **kwargs)
        self.assertTrue(socket_module.sock.closed)
        return callbacks, clock

    def test_valid_a_result_has_native_shape_and_closes(self):
        result, sock, callbacks, unused_clock = self._resolve(
            [( _reply([_a_record('140.82.112.5')]), ('8.8.8.8', 53))])
        self.assertEqual(result, ((2, 1, 6, '', ('140.82.112.5', 443)),))
        self.assertEqual(len(sock.sent), 1)
        self.assertEqual(sock.sent[0][1], ('8.8.8.8', 53))
        self.assertTrue(sock.closed)
        self.assertTrue(callbacks)

    def test_all_allowed_hosts_query_the_exact_requested_name_and_follow_cname(self):
        hosts = ('api.github.com', 'github.com',
                 'release-assets.githubusercontent.com')
        for host in hosts:
            with self.subTest(host=host):
                first = _reply([_cname_record('edge.example.net')], question=host)
                second = _reply([_a_record('140.82.112.5')],
                                question='edge.example.net')
                result, sock, unused_calls, unused_clock = self._resolve(
                    [(first, ('8.8.8.8', 53)), (second, ('8.8.8.8', 53))],
                    host=host)
                self.assertEqual(result[0][-1], ('140.82.112.5', 443))
                self.assertEqual(len(sock.sent), 2)
                self.assertEqual(sock.sent[0][0][12:], _question(host))
                self.assertEqual(sock.sent[1][0][12:], _question('edge.example.net'))
                self.assertNotIn(b'token', b''.join(item[0] for item in sock.sent))

    def test_unsupported_hostname_is_rejected_before_socket_creation(self):
        clock = FakeClock()
        sockmod = FakeSocketModule([], clock)
        for host in ('API.github.com', 'github.com.', 'x.github.com',
                     'user@github.com', '192.0.2.1', 'github.com.evil'):
            with self.subTest(host=host):
                with self.assertRaises(bounded_dns.DnsFailure):
                    bounded_dns.resolve_ipv4(
                        host, '8.8.8.8', sockmod, FakeSelect(sockmod.sock, clock),
                        clock, random_bytes=lambda size: b'\x12\x34')
                self.assertIsNone(getattr(sockmod, 'created', None))

    def test_cname_chain_then_a(self):
        # A CNAME target with an explicit owner pointer to its wire name.
        target_offset = 12 + len(_question()) + 12
        target_pointer = bytes((0xc0 | (target_offset >> 8), target_offset & 255))
        packet = _reply([_cname_record('edge.example.net'),
                         _a_record('140.82.112.5', owner=target_pointer)])
        result, sock, unused_calls, unused_clock = self._resolve([(packet, ('8.8.8.8', 53))])
        self.assertEqual(result[0][-1], ('140.82.112.5', 443))
        self.assertEqual(len(sock.sent), 1)

    def test_wrong_id_and_valid_unrelated_question_are_ignored(self):
        unrelated_id = _reply([_a_record('140.82.112.5')], identifier=1)
        unrelated_question = _reply([_a_record('140.82.112.5')],
                                    question='other.example')
        valid = _reply([_a_record('140.82.112.5')])
        result, sock, unused_calls, unused_clock = self._resolve([
            (unrelated_id, ('8.8.8.8', 53)),
            (unrelated_question, ('8.8.8.8', 53)),
            (valid, ('8.8.8.8', 53))])
        self.assertEqual(result[0][-1], ('140.82.112.5', 443))
        self.assertTrue(sock.closed)

    def test_wrong_source_traffic_services_until_deadline(self):
        clock = FakeClock()
        packets = [(_reply([_a_record('140.82.112.5')]), ('1.1.1.1', 53))
                   for unused_index in range(30)]
        callbacks, clock = self._assert_failure(
            packets, clock=clock, deadline_ms=50, receive_advance_ms=3)
        self.assertGreater(len(callbacks), 1)
        self.assertGreaterEqual(clock.now, 50)
        callback_gaps = [right - left for left, right in zip(callbacks, callbacks[1:])]
        self.assertLessEqual(max(callback_gaps), 250)

    def test_service_false_fails_closed_and_closes_socket(self):
        clock = FakeClock()
        calls = []
        callbacks, unused_clock = self._assert_failure(
            [], clock=clock, deadline_ms=2000,
            service=lambda: calls.append(clock.now) or False)
        self.assertEqual(len(calls), 1)

    def test_duplicate_previous_question_ignored_during_cname_followup(self):
        first_reply = _reply([_cname_record('edge.example.net')])
        followup = _reply([_a_record('140.82.112.5')],
                          question='edge.example.net')
        result, sock, unused_calls, unused_clock = self._resolve([
            (first_reply, ('8.8.8.8', 53)),
            (first_reply, ('8.8.8.8', 53)),
            (followup, ('8.8.8.8', 53))])
        self.assertEqual(result[0][-1], ('140.82.112.5', 443))
        self.assertEqual(len(sock.sent), 2)
        self.assertTrue(sock.closed)

    def test_compression_pointer_loop_rejected(self):
        packet = bytearray(_reply([]))
        packet[12:14] = b'\xc0\x0c'
        self._assert_failure([(bytes(packet), ('8.8.8.8', 53))])

    def test_truncated_oversized_and_excess_records_rejected(self):
        valid = _reply([_a_record('140.82.112.5')])
        for packet in (valid[:9], valid + b'x' * 501,
                       _reply([], an=0, ns=33)):
            self._assert_failure([(packet, ('8.8.8.8', 53))])

    def test_private_and_reserved_addresses_rejected(self):
        for address in ('10.0.0.1', '127.0.0.1', '169.254.1.1',
                        '192.168.1.1', '224.0.0.1', '0.0.0.0'):
            self._assert_failure([(_reply([_a_record(address)]), ('8.8.8.8', 53))])

    def test_cname_loop_and_too_many_hops_rejected(self):
        # The pointer makes the CNAME target equal its own owner.
        loop = _cname_record('api.github.com')
        self._assert_failure([(_reply([loop]), ('8.8.8.8', 53))])
        records = []
        previous_owner = b'\xc0\x0c'
        for index in range(5):
            target = 'n%d.example.net' % index
            records.append(_cname_record(target, previous_owner))
            previous_owner = _name(target)
        self._assert_failure([(_reply(records), ('8.8.8.8', 53))])

    def test_deadline_wrap_and_service_failure(self):
        clock = FakeClock(start=(1 << 30) - 100)
        callbacks, clock = self._assert_failure(
            [], clock=clock, deadline_ms=500,
            service=lambda: self.fail('service is called only after a wait'))
        self.assertEqual(callbacks, [])

    def test_deadline_services_and_ticks_wrap(self):
        clock = FakeClock(start=(1 << 30) - 100)
        callbacks, clock = self._assert_failure([], clock=clock, deadline_ms=500)
        self.assertGreaterEqual(len(callbacks), 2)
        self.assertGreaterEqual(clock.now - ((1 << 30) - 100), 500)

    def test_entropy_missing_fails_closed(self):
        clock = FakeClock()
        sockmod = FakeSocketModule([], clock)
        with self.assertRaises(bounded_dns.DnsFailure):
            bounded_dns.resolve_ipv4('api.github.com', '8.8.8.8', sockmod,
                                     FakeSelect(sockmod.sock, clock), clock,
                                     random_bytes=lambda size: (_ for _ in ()).throw(
                                         OSError('entropy unavailable')))
        self.assertIsNone(getattr(sockmod, 'created', None))

    def test_service_exception_is_redacted_and_socket_closes(self):
        clock = FakeClock()
        sockmod = FakeSocketModule([], clock)
        with self.assertRaises(bounded_dns.DnsFailure):
            bounded_dns.resolve_ipv4(
                'api.github.com', '8.8.8.8', sockmod,
                FakeSelect(sockmod.sock, clock), clock,
                service=lambda: (_ for _ in ()).throw(ValueError('secret detail')),
                random_bytes=lambda size: b'\x12\x34', deadline_ms=2000)
        self.assertTrue(sockmod.sock.closed)

    def test_invalid_backwards_and_noninteger_ticks_fail_closed(self):
        class InvalidClock(FakeClock):
            def __init__(self, current, difference):
                super().__init__()
                self.current = current
                self.difference = difference

            def ticks_ms(self):
                return self.current

            def ticks_diff(self, current, previous):
                if isinstance(self.difference, Exception):
                    raise self.difference
                return self.difference

        for current, difference in ((1, -1), (1.5, 1), (1, 1.5), (1, ValueError())):
            with self.subTest(current=current, difference=difference):
                callbacks, unused_clock = self._assert_failure(
                    [], clock=InvalidClock(current, difference))
                self.assertEqual(callbacks, [])

    def test_missing_ticks_diff_and_noninteger_deadline_fail_before_network(self):
        clock = FakeClock()
        clock.ticks_diff = None
        socket_module = FakeSocketModule([], clock)
        with self.assertRaises(bounded_dns.DnsFailure):
            bounded_dns.resolve_ipv4(
                'api.github.com', '8.8.8.8', socket_module,
                FakeSelect(socket_module.sock, clock), clock,
                random_bytes=lambda size: b'\x12\x34')
        self.assertIsNone(getattr(socket_module, 'created', None))

        for deadline in (True, 1.5):
            with self.subTest(deadline=deadline):
                socket_module = FakeSocketModule([], clock)
                with self.assertRaises(bounded_dns.DnsFailure):
                    bounded_dns.resolve_ipv4(
                        'api.github.com', '8.8.8.8', socket_module,
                        FakeSelect(socket_module.sock, clock), FakeClock(),
                        random_bytes=lambda size: b'\x12\x34',
                        deadline_ms=deadline)
                self.assertIsNone(getattr(socket_module, 'created', None))


if __name__ == '__main__':
    unittest.main()
