#!/usr/bin/env python3
"""UMIX/86 IP terminal-session peer (host side).

The guest exposes terminal sessions on UDP port 2323 inside the mux IP channel
(terminal id 0xFE).  This module terminates that protocol and turns each
session into a plain byte stream, so an ordinary TCP client (telnet, nc) can
log in to the machine.

Wire protocol, UDP payload:

    [0] session id   [1] op   [2..] data
    client -> guest: 0 DATA, 1 OPEN, 2 CLOSE
    guest  -> client: 0 DATA, 1 OPEN OK, 3 BUSY

Everything rides the existing serial mux: IP packets are DATA frames with
terminal id 0xFE, byte-stuffed with the same 0x1B escape the guest uses.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable

LOG = logging.getLogger("ip_peer")

GUEST_IP = (192, 168, 99, 1)
HOST_IP = (192, 168, 99, 2)
GUEST_PORT = 2323
PORT_BASE = 40000

MAX_FRAME = 255          # guest frame length byte (one payload per frame)
MAX_SESSION_DATA = 70    # guest caps its UDP payload at 72 (2 header + data)
IP_UDP_LEN = 28

TERM_IP = 0xFE

OP_DATA = 0
OP_OPEN = 1
OP_CLOSE = 2
OP_BUSY = 3

_ESC = {0x1B: 0x01, 0x02: 0x02, 0x03: 0x03}
_UNESC = {v: k for k, v in _ESC.items()}


def escape(payload: bytes) -> bytes:
    out = bytearray()
    for b in payload:
        if b in _ESC:
            out.append(0x1B)
            out.append(_ESC[b])
        else:
            out.append(b)
    return bytes(out)


def unescape(payload: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(payload):
        if payload[i] == 0x1B and i + 1 < len(payload):
            out.append(_UNESC.get(payload[i + 1], payload[i + 1]))
            i += 2
        else:
            out.append(payload[i])
            i += 1
    return bytes(out)


def checksum(data: bytes) -> int:
    if len(data) & 1:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) | data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def build_packet(payload: bytes, sport: int, *, src=HOST_IP, dst=GUEST_IP,
                 dport: int = GUEST_PORT) -> bytes:
    """IPv4 + UDP datagram carrying `payload`."""
    total = IP_UDP_LEN + len(payload)
    ip = bytearray(20)
    ip[0] = 0x45
    ip[2:4] = total.to_bytes(2, "big")
    ip[8] = 64                                   # TTL
    ip[9] = 17                                   # UDP
    ip[12:16] = bytes(src)
    ip[16:20] = bytes(dst)
    ip[10:12] = checksum(bytes(ip)).to_bytes(2, "big")
    udp = bytearray(8)
    udp[0:2] = sport.to_bytes(2, "big")
    udp[2:4] = dport.to_bytes(2, "big")
    udp[4:6] = (8 + len(payload)).to_bytes(2, "big")
    udp[6:8] = b"\x00\x00"                       # checksum optional in IPv4
    return bytes(ip) + bytes(udp) + payload


def parse_packet(pkt: bytes) -> dict | None:
    if len(pkt) < IP_UDP_LEN or pkt[0] != 0x45 or pkt[9] != 17:
        return None
    total = (pkt[2] << 8) | pkt[3]
    if total < IP_UDP_LEN or total > len(pkt):
        return None
    if checksum(pkt[:20]) != 0:
        return None
    sport = (pkt[20] << 8) | pkt[21]
    dport = (pkt[22] << 8) | pkt[23]
    ulen = (pkt[24] << 8) | pkt[25]
    if ulen < 8 or ulen > total - 20:
        return None
    return {
        "src": tuple(pkt[12:16]),
        "dst": tuple(pkt[16:20]),
        "sport": sport,
        "dport": dport,
        "payload": pkt[28:20 + ulen],
    }


class PeerSession:
    def __init__(self, port: int) -> None:
        self.port = port
        self.sid = 0
        self.busy = False
        self.opened = asyncio.Event()
        self.queue: asyncio.Queue[bytes | None] = asyncio.Queue(maxsize=256)
        self.closed = False

    async def deliver(self, data: bytes) -> None:
        if not data:
            return
        try:
            self.queue.put_nowait(data)
        except asyncio.QueueFull:
            LOG.warning("session %d output queue full, dropping", self.sid)


class IpPeer:
    """Terminates guest UDP terminal sessions and hands back byte streams."""

    def __init__(self, send_packet, *, max_frame: int = MAX_FRAME,
                 baud: int = 9600) -> None:
        # send_packet: async callable(bytes) -> None, writes one IP packet to
        # the guest's 0xFE channel (already framed and escaped by the caller).
        self.send_packet = send_packet
        self.max_frame = max_frame
        # Optional tap: async callable(info) for every valid UDP packet,
        # including those that are not terminal sessions (e.g. TFTP on 6969).
        self.on_udp: Callable[[dict], Awaitable[None]] | None = None
        # The guest UART has no receive FIFO: back-to-back datagrams overrun it
        # and the request silently disappears.  Pace to ~75% of the line rate.
        self.baud = baud
        self.sessions: dict[int, PeerSession] = {}
        self.by_port: dict[int, PeerSession] = {}
        self._next_port = PORT_BASE
        self._lock = asyncio.Lock()

    # ---- guest -> host ----

    async def feed(self, packet: bytes) -> None:
        info = parse_packet(packet)
        if info is None:
            return
        if self.on_udp is not None:
            await self.on_udp(info)
        if info["sport"] != GUEST_PORT:
            return
        payload = info["payload"]
        if len(payload) < 2:
            return
        sid, op = payload[0], payload[1]
        data = payload[2:]
        if op == OP_OPEN:
            LOG.info("guest OPEN reply: id=%d (host port %d)", sid, info["dport"])
            sess = self.by_port.get(info["dport"])
            if sess is None or sess.sid:
                return
            sess.sid = sid
            self.sessions[sid] = sess
            sess.opened.set()
            LOG.info("session %d established (host port %d)", sid, sess.port)
        elif op == OP_BUSY:
            sess = self.by_port.get(info["dport"])
            LOG.warning("guest BUSY: payload id=%d op=%d from %s:%d",
                        sid, op, info["src"][0], info["sport"])
            if sid == 0:
                LOG.warning("  -> guest says no free terminal id (all 1..10 "
                            "reserved; check 'PS' on the console)")
            else:
                LOG.warning("  -> guest says no free task slot (all 10 slots "
                            "busy; check 'PS' on the console)")
            if sess is not None:
                sess.busy = True
                sess.opened.set()
        elif op == OP_DATA:
            sess = self.sessions.get(sid)
            if sess is not None:
                await sess.deliver(data)

    # ---- host -> guest ----

    def _alloc_port(self) -> int:
        for _ in range(1000):
            port = self._next_port
            self._next_port += 1
            if self._next_port > 60000:
                self._next_port = PORT_BASE
            if port not in self.by_port:
                return port
        raise RuntimeError("no free host port")

    async def _send_udp(self, port: int, payload: bytes) -> None:
        await self.send_packet(build_packet(payload, port))

    async def open_session(self, timeout: float = 1.0, attempts: int = 4) -> PeerSession:
        port = self._alloc_port()
        sess = PeerSession(port)
        self.by_port[port] = sess
        try:
            for _ in range(attempts):
                await self._send_udp(port, bytes((0, OP_OPEN)))
                try:
                    await asyncio.wait_for(sess.opened.wait(), timeout)
                    break
                except asyncio.TimeoutError:
                    LOG.debug("open retry on port %d", port)
            else:
                raise RuntimeError("guest did not answer OPEN")
            if sess.busy or not sess.sid:
                raise RuntimeError("guest has no free session")
            return sess
        except Exception:
            self.by_port.pop(port, None)
            raise

    async def send_data(self, sess: PeerSession, data: bytes) -> None:
        if not sess.sid or sess.closed:
            return
        i = 0
        while i < len(data):
            n = min(MAX_SESSION_DATA, len(data) - i)
            # shrink until the escaped frame fits the guest's 120-byte cap
            while n > 0:
                payload = bytes((sess.sid, OP_DATA)) + data[i:i + n]
                frame_len = len(escape(build_packet(payload, sess.port))) + 6
                if frame_len <= self.max_frame + 6:
                    break
                n -= 1
            if n == 0:
                LOG.warning("session %d: cannot fit a byte, dropping", sess.sid)
                return
            payload = bytes((sess.sid, OP_DATA)) + data[i:i + n]
            await self._send_udp(sess.port, payload)
            if self.baud > 0:
                wire = frame_len * 10.0 / self.baud
                await asyncio.sleep(wire * 1.35)
            i += n

    async def close_session(self, sess: PeerSession) -> None:
        sess.closed = True
        try:
            if sess.sid:
                await self._send_udp(sess.port, bytes((sess.sid, OP_CLOSE)))
        except Exception:
            LOG.debug("close frame failed for session %d", sess.sid, exc_info=True)
        self.sessions.pop(sess.sid, None)
        self.by_port.pop(sess.port, None)
        try:
            sess.queue.put_nowait(None)
        except asyncio.QueueFull:
            pass


# ---------------------------------------------------------------------------
# UDP relay: give a local UDP client a terminal session, raw bytes in/out.
#
# No driver and no privileges needed, so this is the portable option (Windows
# included).  The first datagram from a client opens a session; from then on
# whatever the client sends becomes session input and whatever the guest
# prints comes back as a datagram.  `nc -u host 2400` is enough to log in.
# ---------------------------------------------------------------------------

_MISSING = object()


class _RelayProtocol(asyncio.DatagramProtocol):
    def __init__(self, relay: "UdpRelay") -> None:
        self.relay = relay

    def datagram_received(self, data: bytes, addr) -> None:
        self.relay.on_client(data, addr)

    def error_received(self, exc: Exception) -> None:
        LOG.debug("udp relay error: %s", exc)


class UdpRelay:
    def __init__(self, peer: IpPeer, host: str = "127.0.0.1", port: int = 0,
                 *, idle: float = 600.0) -> None:
        self.peer = peer
        self.host = host
        self.port = port
        self.idle = idle
        self.transport: asyncio.DatagramTransport | None = None
        self.bound: tuple[str, int] = (host, port)
        self.by_client: dict[tuple, PeerSession | None] = {}
        self.by_session: dict[PeerSession, tuple] = {}
        self.pending: dict[tuple, list[bytes]] = {}
        self.last: dict[tuple, float] = {}
        self.pumps: dict[PeerSession, asyncio.Task] = {}
        self._sweeper: asyncio.Task | None = None
        self._closing = False

    async def start(self) -> None:
        loop = asyncio.get_running_loop()
        self.transport, _ = await loop.create_datagram_endpoint(
            lambda: _RelayProtocol(self), local_addr=(self.host, self.port))
        self.bound = self.transport.get_extra_info("sockname")[:2]
        self._sweeper = asyncio.create_task(self._sweep())

    async def close(self) -> None:
        self._closing = True
        if self._sweeper:
            self._sweeper.cancel()
        for sess in list(self.by_session):
            await self._drop(sess, "relay shutdown")
        if self.transport:
            self.transport.close()

    # ---- client side (called from the datagram protocol) ----

    def on_client(self, data: bytes, addr) -> None:
        now = asyncio.get_running_loop().time()
        self.last[addr] = now
        sess = self.by_client.get(addr, _MISSING)
        if sess is _MISSING:
            self.by_client[addr] = None          # opening
            self.pending[addr] = [data]
            asyncio.create_task(self._open(addr))
            return
        if sess is None:
            self.pending.setdefault(addr, []).append(data)
            return
        if data:
            asyncio.create_task(self.peer.send_data(sess, data))

    async def _open(self, addr) -> None:
        try:
            sess = await self.peer.open_session(timeout=1.0, attempts=3)
        except Exception as exc:  # noqa: BLE001
            LOG.warning("udp relay: no session for %s: %s", addr, exc)
            self.by_client.pop(addr, None)
            self.pending.pop(addr, None)
            if self.transport is not None:
                self.transport.sendto(
                    b"\r\nUMIX/86: no terminal session available\r\n", addr)
            return
        self.by_client[addr] = sess
        self.by_session[sess] = addr
        self.pumps[sess] = asyncio.create_task(self._pump(sess, addr))
        LOG.info("udp relay: session %d for %s", sess.sid, addr)
        for chunk in self.pending.pop(addr, []):
            await self.peer.send_data(sess, chunk)

    async def _pump(self, sess: PeerSession, addr) -> None:
        while True:
            chunk = await sess.queue.get()
            if chunk is None:
                return
            if self.transport is not None:
                self.transport.sendto(chunk, addr)

    async def _drop(self, sess: PeerSession, reason: str) -> None:
        addr = self.by_session.pop(sess, None)
        if addr is not None:
            self.by_client.pop(addr, None)
            self.last.pop(addr, None)
            LOG.info("udp relay: closing session %d (%s)", sess.sid, reason)
        task = self.pumps.pop(sess, None)
        if task:
            task.cancel()
        await self.peer.close_session(sess)

    async def _sweep(self) -> None:
        try:
            while not self._closing:
                await asyncio.sleep(30)
                now = asyncio.get_running_loop().time()
                for sess, addr in list(self.by_session.items()):
                    if now - self.last.get(addr, now) > self.idle:
                        await self._drop(sess, "idle")
        except asyncio.CancelledError:
            pass


TFTP_PORT = 69
TFTP_TID = 6969


class _TftpProto(asyncio.DatagramProtocol):
    def __init__(self, relay: "TftpRelay") -> None:
        self.relay = relay

    def datagram_received(self, data: bytes, addr) -> None:
        self.relay.on_client(data, addr)


class TftpRelay:
    """UDP NAT between a host TFTP client and the guest's TFTP server.

    The guest answers on 192.168.99.1:69 through the IP channel.  The relay
    talks to it from the guest TID (6969) and forwards replies to the last
    host client, so `tftp 127.0.0.1 6969` works unchanged.  One transfer at a
    time: the guest has a single TID and a single state machine.
    """

    def __init__(self, send_packet, host: str, port: int) -> None:
        self.send_packet = send_packet
        self.host = host
        self.port = port
        self.bound = (host, port)
        self.transport: asyncio.DatagramTransport | None = None
        self.client: tuple[str, int] | None = None

    async def start(self) -> None:
        loop = asyncio.get_running_loop()
        self.transport, _ = await loop.create_datagram_endpoint(
            lambda: _TftpProto(self), local_addr=(self.host, self.port))
        self.bound = self.transport.get_extra_info("sockname")[:2]
        LOG.info("TFTP relay on %s:%d -> guest 192.168.99.1:69 "
                 "(blksize 8..192, one transfer at a time)", *self.bound)

    async def close(self) -> None:
        if self.transport is not None:
            self.transport.close()

    def on_client(self, data: bytes, addr) -> None:
        self.client = addr
        LOG.info("tftp: %s:%d -> %d bytes %r", addr[0], addr[1], len(data),
                 data[:12])
        packet = build_packet(data, TFTP_TID, dport=TFTP_PORT)
        asyncio.create_task(self.send_packet(packet))

    async def on_guest(self, info: dict) -> None:
        LOG.debug("tftp guest: sport=%d dport=%d %r",
                  info["sport"], info["dport"], info["payload"][:12])
        if info["sport"] != TFTP_TID:
            return
        if self.client is None or self.transport is None:
            return
        self.transport.sendto(info["payload"], self.client)
