"""Test-only TLS/DNS seams around the unchanged native request/poll/deadline loop.

TLS verification and production DNS are intentionally not qualified here.
"""

import select
import socket
import time

from clock_flow import CountingTransport


class PlaintextContext:
    def __init__(self, protocol):
        assert protocol == PlaintextTLS.PROTOCOL_TLS_CLIENT
        self.verify_mode = None

    def load_verify_locations(self, roots):
        assert roots == b"synthetic-unused-ca"

    def wrap_socket(self, connection, server_hostname, do_handshake_on_connect):
        assert self.verify_mode == PlaintextTLS.CERT_REQUIRED
        assert server_hostname == "api.github.com"
        assert do_handshake_on_connect is False
        return connection


class PlaintextTLS:
    PROTOCOL_TLS_CLIENT = 1
    CERT_REQUIRED = 2
    SSLContext = PlaintextContext


def numeric_resolver(port):
    # Unix MicroPython requires its actual packed sockaddr, not a Pico tuple.
    record = socket.getaddrinfo("127.0.0.1", port, socket.AF_INET, socket.SOCK_STREAM)[
        0
    ]

    def resolve(host, dns, socket_module, select_module, clock, service, deadline_ms):
        assert host == "api.github.com" and dns == "127.0.0.1"
        assert socket_module is socket and select_module is select and clock is time
        assert 0 < deadline_ms <= 650
        return (record,)

    return resolve


class NativeLoopbackTransport(CountingTransport):
    """Count actual native PATCH calls; inherit only the fixture stats reader."""

    def __init__(self, port, native):
        super().__init__(port, time)
        self.native = native

    def patch_gist(self, gist, body, service=None):
        self.attempts[gist] += 1
        return self.native.patch_gist(gist, body, service)

    def close(self):
        self.native.close()
