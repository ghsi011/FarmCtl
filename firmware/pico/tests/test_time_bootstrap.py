import errno
import unittest

import time_bootstrap


SERVER = '192.0.2.123'
NONCE = b'12345678'
GOOD_UNIX = 1893456000  # 2030-01-01 UTC


def _reply(nonce=NONCE, unix_seconds=GOOD_UNIX, leap=0, version=4,
           mode=4, stratum=2, length=48):
    packet = bytearray(max(48, length))
    packet[0] = (leap << 6) | (version << 3) | mode
    packet[1] = stratum
    packet[24:32] = nonce
    ntp_seconds = (unix_seconds + time_bootstrap.NTP_UNIX_DELTA) & 0xffffffff
    packet[40:44] = ntp_seconds.to_bytes(4, 'big')
    return bytes(packet[:length])


class Clock:
    def __init__(self, start=0, modulus=1 << 30):
        self.now = start
        self.modulus = modulus

    def ticks_ms(self):
        return self.now % self.modulus

    def ticks_diff(self, current, previous):
        half = self.modulus // 2
        return ((current - previous + half) % self.modulus) - half


class FakeSocket:
    def __init__(self, packets, clock):
        self.packets = list(packets)
        self.clock = clock
        self.receive_advance_ms = 0
        self.sent = []
        self.closed = False

    def setblocking(self, value):
        self.blocking = value

    def sendto(self, packet, address):
        self.sent.append((packet, address))

    def recvfrom(self, size):
        if not self.packets:
            raise OSError(errno.EAGAIN, 'would block')
        packet, source = self.packets.pop(0)
        self.clock.now += self.receive_advance_ms
        return packet[:size], source

    def close(self):
        self.closed = True


class Poller:
    def __init__(self, sock, clock):
        self.sock = sock
        self.clock = clock
        self.waits = []

    def register(self, sock, events):
        self.registered = (sock, events)

    def poll(self, timeout):
        self.waits.append(timeout)
        if self.sock.packets:
            return [(self.sock, 1)]
        self.clock.now += timeout
        return []


class FakeSelect:
    POLLIN = 1

    def __init__(self, sock, clock):
        self.poller = Poller(sock, clock)

    def poll(self):
        return self.poller


class FakeSocketModule:
    AF_INET = 2
    SOCK_DGRAM = 2

    def __init__(self, packets, clock):
        self.sock = FakeSocket(packets, clock)

    def socket(self, family, kind):
        self.created = (family, kind)
        return self.sock


class TimeBootstrapTests(unittest.TestCase):
    def setup_exchange(self, packets, start=0, modulus=1 << 30):
        clock = Clock(start, modulus)
        sock_module = FakeSocketModule(packets, clock)
        select_module = FakeSelect(sock_module.sock, clock)
        set_calls = []

        def set_rtc(seconds):
            set_calls.append(seconds)

        result = time_bootstrap.bootstrap_utc(
            SERVER, sock_module, select_module, clock, set_rtc,
            random_bytes=lambda count: NONCE)
        return result, clock, sock_module, select_module, set_calls

    def test_valid_reply_sets_rtc_and_sends_v4_client_request(self):
        result, _, sockets, _, set_calls = self.setup_exchange([
            (_reply(), (SERVER, 123))])
        self.assertEqual({'usable': True, 'unix_seconds': GOOD_UNIX}, result)
        self.assertEqual([GOOD_UNIX], set_calls)
        self.assertEqual((2, 2), sockets.created)
        self.assertFalse(sockets.sock.blocking)
        request, target = sockets.sock.sent[0]
        self.assertEqual((SERVER, 123), target)
        self.assertEqual(48, len(request))
        self.assertEqual(0x23, request[0])
        self.assertEqual(NONCE, request[40:48])
        self.assertTrue(sockets.sock.closed)

    def test_service_false_before_send_cancels_without_sending(self):
        clock = Clock()
        sockets = FakeSocketModule([], clock)
        select_module = FakeSelect(sockets.sock, clock)
        set_calls = []
        result = time_bootstrap.bootstrap_utc(
            SERVER, sockets, select_module, clock, set_calls.append,
            service=lambda: False, random_bytes=lambda count: NONCE)
        self.assertFalse(result['usable'])
        self.assertEqual([], sockets.sock.sent)
        self.assertEqual([], set_calls)
        self.assertTrue(sockets.sock.closed)

    def test_service_false_during_poll_cancels_without_retry(self):
        clock = Clock()
        sockets = FakeSocketModule([], clock)
        select_module = FakeSelect(sockets.sock, clock)
        service_results = iter((None, False))
        result = time_bootstrap.bootstrap_utc(
            SERVER, sockets, select_module, clock, lambda value: self.fail(),
            service=lambda: next(service_results), random_bytes=lambda count: NONCE)
        self.assertFalse(result['usable'])
        self.assertEqual(1, len(sockets.sock.sent))
        self.assertEqual([250], select_module.poller.waits)
        self.assertTrue(sockets.sock.closed)

    def test_service_false_before_rtc_set_discards_valid_reply(self):
        clock = Clock()
        sockets = FakeSocketModule([(_reply(), (SERVER, 123))], clock)
        select_module = FakeSelect(sockets.sock, clock)
        service_results = iter((None, False))
        set_calls = []
        result = time_bootstrap.bootstrap_utc(
            SERVER, sockets, select_module, clock, set_calls.append,
            service=lambda: next(service_results), random_bytes=lambda count: NONCE)
        self.assertFalse(result['usable'])
        self.assertEqual(1, len(sockets.sock.sent))
        self.assertEqual([], set_calls)
        self.assertTrue(sockets.sock.closed)

    def test_service_exception_fails_closed_without_leaking_detail(self):
        clock = Clock()
        sockets = FakeSocketModule([], clock)
        select_module = FakeSelect(sockets.sock, clock)

        def broken_service():
            raise ValueError('secret detail')

        result = time_bootstrap.bootstrap_utc(
            SERVER, sockets, select_module, clock, lambda value: self.fail(),
            service=broken_service, random_bytes=lambda count: NONCE)
        self.assertFalse(result['usable'])
        self.assertEqual([], sockets.sock.sent)
        self.assertNotIn('secret detail', repr(result))
        self.assertTrue(sockets.sock.closed)

    def test_service_none_and_true_remain_non_cancelling(self):
        for service in (None, lambda: True):
            with self.subTest(service=service):
                result, _, sockets, _, set_calls = self.setup_exchange(
                    [(_reply(), (SERVER, 123))])
                if service is not None:
                    clock = Clock()
                    sockets = FakeSocketModule([(_reply(), (SERVER, 123))], clock)
                    select_module = FakeSelect(sockets.sock, clock)
                    set_calls = []
                    result = time_bootstrap.bootstrap_utc(
                        SERVER, sockets, select_module, clock, set_calls.append,
                        service=service, random_bytes=lambda count: NONCE)
                self.assertTrue(result['usable'])
                self.assertEqual([GOOD_UNIX], set_calls)
                self.assertEqual(1, len(sockets.sock.sent))
                self.assertTrue(sockets.sock.closed)

    def test_ignores_wrong_source_and_nonce_before_valid_reply(self):
        result, _, _, _, set_calls = self.setup_exchange([
            (_reply(), ('192.0.2.124', 123)),
            (_reply(nonce=b'87654321'), (SERVER, 123)),
            (_reply(), (SERVER, 123)),
        ])
        self.assertTrue(result['usable'])
        self.assertEqual([GOOD_UNIX], set_calls)

    def test_rejects_invalid_matching_replies_and_closes_socket(self):
        invalid = [
            _reply(stratum=0), _reply(stratum=16), _reply(leap=3),
            _reply(version=2), _reply(mode=3), _reply(length=47),
            _reply(length=129), _reply(unix_seconds=0),
            _reply(unix_seconds=1704067199), _reply(unix_seconds=4133980800),
        ]
        for packet in invalid:
            with self.subTest(packet=packet[:2]):
                result, _, sockets, _, set_calls = self.setup_exchange([
                    (packet, (SERVER, 123))])
                self.assertFalse(result['usable'])
                self.assertEqual([], set_calls)
                self.assertTrue(sockets.sock.closed)

    def test_service_runs_during_continuous_wrong_source_until_deadline(self):
        clock = Clock(modulus=1 << 30)
        source_packets = [(_reply(), ('192.0.2.200', 123)) for _ in range(50)]
        sockets = FakeSocketModule(source_packets, clock)
        sockets.sock.receive_advance_ms = 250
        select_module = FakeSelect(sockets.sock, clock)
        service_times = []
        result = time_bootstrap.bootstrap_utc(
            SERVER, sockets, select_module, clock, lambda value: self.fail(),
            service=lambda: service_times.append(clock.now),
            random_bytes=lambda count: NONCE)
        self.assertFalse(result['usable'])
        self.assertEqual(10_000, clock.now)
        self.assertEqual(41, len(service_times))
        self.assertTrue(all(wait <= 250 for wait in select_module.poller.waits))
        self.assertTrue(sockets.sock.closed)

    def test_deadline_uses_ticks_diff_across_wrap(self):
        clock = Clock(start=(1 << 30) - 100, modulus=1 << 30)
        sockets = FakeSocketModule([], clock)
        select_module = FakeSelect(sockets.sock, clock)
        result = time_bootstrap.bootstrap_utc(
            SERVER, sockets, select_module, clock, lambda value: self.fail(),
            random_bytes=lambda count: NONCE)
        self.assertFalse(result['usable'])
        self.assertEqual(10_000, clock.now - ((1 << 30) - 100))
        self.assertTrue(sockets.sock.closed)

    def test_rtc_failure_is_unusable_and_invalid_address_never_opens_socket(self):
        result, _, sockets, _, _ = self.setup_exchange([
            (_reply(), (SERVER, 123))])
        # Verify callback failure doesn't leak the exception text.
        clock = Clock()
        socket_module = FakeSocketModule([(_reply(), (SERVER, 123))], clock)
        select_module = FakeSelect(socket_module.sock, clock)
        failed = time_bootstrap.bootstrap_utc(
            SERVER, socket_module, select_module, clock,
            lambda value: (_ for _ in ()).throw(ValueError('secret detail')),
            random_bytes=lambda count: NONCE)
        self.assertTrue(result['usable'])
        self.assertFalse(failed['usable'])
        self.assertNotIn('secret detail', repr(failed))
        invalid = time_bootstrap.bootstrap_utc(
            'ntp.example.test', socket_module, select_module, clock,
            lambda value: None, random_bytes=lambda count: NONCE)
        self.assertFalse(invalid['usable'])

    def test_no_name_resolution_is_used(self):
        result, _, sockets, _, _ = self.setup_exchange([
            (_reply(), (SERVER, 123))])
        self.assertTrue(result['usable'])
        self.assertFalse(hasattr(sockets, 'getaddrinfo'))


if __name__ == '__main__':
    unittest.main()
