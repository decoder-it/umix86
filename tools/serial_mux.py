#!/usr/bin/env python3
"""UMIX/86 serial console multiplexer.

TCP clients connect to this bridge.  Each client gets a terminal ID; the
bridge frames client bytes for the guest and routes guest frames back to the
right socket.  The guest sees only a length-prefixed binary protocol on COM1.

Frame: STX(0x02) TYPE TERMID LEN PAYLOAD[LEN] XOR ETX(0x03)
XOR covers TYPE..payload.  See README.md, Part II (serial multiplexer).
HTTP clients can connect to an --http-listen port: the bridge opens the guest
session with application id 2 and the guest serves INDEX.HTM from its mounted
volume. Upload clients connect to an --upload-listen port: application id 3
receives "PUT NAME SIZE\n" + bytes and writes the file (see tools/umix_put.py).

Examples:
    python3 tools/serial_mux.py --serial /dev/ttyUSB0 --baud 9600 \
        --listen 0.0.0.0:2323 --max-sessions 10
    python3 tools/serial_mux.py --fake --listen 127.0.0.1:2323

The TCP side is raw terminal data (telnet/nc/serial terminal client); framing
exists only on the serial link.  The guest login (SYSTEM/SYS1, USER/USER) is
the authentication.  Do not expose the TCP port to untrusted networks without
a wrapper.
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import time
from dataclasses import dataclass, field

from ip_peer import TERM_IP, IpPeer, TftpRelay, UdpRelay, escape, unescape

LOG = logging.getLogger("serial_mux")

STX = 0x02
ETX = 0x03

DATA = 0x01
OPEN = 0x02
CLOSE = 0x03
BUSY = 0x04
ACK = 0x05
ERROR = 0x06

# OPEN payload: application id
APP_CONSOLE = 1
APP_WEB = 2
APP_UPLOAD = 3

MAX_PAYLOAD = 250
FRAME_OVERHEAD = 6
MAX_FRAME = MAX_PAYLOAD + FRAME_OVERHEAD


def encode_frame(ftype: int, termid: int, payload: bytes = b"") -> bytes:
    if not 0 <= ftype <= 0xFF:
        raise ValueError("bad frame type")
    if not 0 <= termid <= 0xFF:
        raise ValueError("bad terminal id")
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("payload too large")
    body = bytes((ftype, termid, len(payload))) + payload
    checksum = 0
    for byte in body:
        checksum ^= byte
    return bytes((STX,)) + body + bytes((checksum, ETX))


class FrameDecoder:
    """Length-prefixed frame decoder with error counting."""

    WAIT_STX, TYPE, TERMID, LEN, PAYLOAD, XOR, ETX = range(7)
    JUNK_LIMIT = 64

    def __init__(self) -> None:
        self.errors = 0
        self.junk = bytearray()
        self.reset()

    def note_junk(self, data: bytes) -> None:
        room = self.JUNK_LIMIT - len(self.junk)
        if room > 0:
            self.junk += data[:room]

    def take_junk(self) -> bytes:
        sample = bytes(self.junk)
        self.junk.clear()
        return sample

    def peek_junk(self) -> bytes:
        return bytes(self.junk)

    def _reset_error(self, data: bytes) -> None:
        self.errors += 1
        self.note_junk(data)
        self.reset()

    def reset(self) -> None:
        self.state = self.WAIT_STX
        self.body = bytearray()
        self.ftype = 0
        self.termid = 0
        self.length = 0

    def feed(self, data: bytes) -> list[tuple[int, int, bytes]]:
        frames: list[tuple[int, int, bytes]] = []
        for byte in data:
            frame = self._byte(byte)
            if frame is not None:
                frames.append(frame)
        return frames

    def _byte(self, byte: int):
        if self.state == self.WAIT_STX:
            if byte == STX:
                self.body = bytearray()
                self.state = self.TYPE
            else:
                self.note_junk(bytes((byte,)))   # raw console text lives here
            return None

        if self.state == self.TYPE:
            self.ftype = byte
            self.body.append(byte)
            self.state = self.TERMID
            return None

        if self.state == self.TERMID:
            self.termid = byte
            self.body.append(byte)
            self.state = self.LEN
            return None

        if self.state == self.LEN:
            self.length = byte
            self.body.append(byte)
            if byte > MAX_PAYLOAD:
                self._reset_error(bytes(self.body))
            else:
                self.state = self.PAYLOAD if byte else self.XOR
            return None

        if self.state == self.PAYLOAD:
            self.body.append(byte)
            if len(self.body) - 3 >= self.length:
                self.state = self.XOR
            return None

        if self.state == self.XOR:
            checksum = 0
            for value in self.body:
                checksum ^= value
            if checksum != byte:
                self._reset_error(bytes(self.body) + bytes((byte,)))
            else:
                self.state = self.ETX
            return None

        if self.state == self.ETX:
            if byte != ETX:
                self._reset_error(bytes(self.body) + bytes((byte,)))
                return None
            payload = bytes(self.body[3:3 + self.length])
            frame = (self.ftype, self.termid, payload)
            self.reset()
            return frame

        self.reset()
        return None


class Transport:
    async def connect(self) -> None:  # pragma: no cover - interface
        return None

    async def read(self, size: int) -> bytes:  # pragma: no cover - interface
        raise NotImplementedError

    async def write(self, data: bytes) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    async def close(self) -> None:  # pragma: no cover - interface
        raise NotImplementedError


class SerialTransport(Transport):
    def __init__(self, port: str, baud: int) -> None:
        import serial  # imported here so --fake works without pyserial

        self.serial = serial.Serial(port, baudrate=baud, timeout=0.1)
        try:
            # discard bytes buffered by the driver at the old rate
            self.serial.reset_input_buffer()
            self.serial.reset_output_buffer()
        except Exception:
            pass

    async def read(self, size: int) -> bytes:
        return await asyncio.to_thread(self.serial.read, size)

    async def write(self, data: bytes) -> None:
        # serial.write() buffers in the OS; do not flush (it would block for
        # the full wire time of every frame).
        await asyncio.to_thread(self.serial.write, data)

    async def close(self) -> None:
        await asyncio.to_thread(self.serial.close)


class UnixSocketTransport(Transport):
    """QEMU -serial unix:/path transport (the bridge is the client)."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None

    async def connect(self) -> None:
        last: Exception | None = None
        for _ in range(50):
            try:
                self.reader, self.writer = await asyncio.open_unix_connection(self.path)
                return
            except OSError as exc:
                last = exc
                await asyncio.sleep(0.1)
        raise ConnectionError(f"cannot connect to {self.path}: {last}")

    async def read(self, size: int) -> bytes:
        assert self.reader is not None
        try:
            return await asyncio.wait_for(self.reader.read(size), timeout=0.1)
        except asyncio.TimeoutError:
            return b""

    async def write(self, data: bytes) -> None:
        assert self.writer is not None
        self.writer.write(data)
        await self.writer.drain()

    async def close(self) -> None:
        if self.writer is not None:
            self.writer.close()
            try:
                await self.writer.wait_closed()
            except Exception:
                pass


class FakeGuestTransport(Transport):
    """In-memory fake guest: ACKs OPEN, echoes DATA, echoes CLOSE."""

    def __init__(self) -> None:
        self.queue: asyncio.Queue[bytes] = asyncio.Queue()
        self.decoder = FrameDecoder()
        self.closed = False

    async def read(self, size: int) -> bytes:
        try:
            return await asyncio.wait_for(self.queue.get(), timeout=0.1)
        except asyncio.TimeoutError:
            return b""

    async def write(self, data: bytes) -> None:
        for ftype, termid, payload in self.decoder.feed(data):
            if ftype == OPEN:
                await self.queue.put(encode_frame(ACK, termid))
            elif ftype == CLOSE:
                await self.queue.put(encode_frame(CLOSE, termid))
            elif ftype == DATA and termid != 0:
                await self.queue.put(encode_frame(DATA, termid, payload))

    async def close(self) -> None:
        self.closed = True


TELNET_IAC = 0xFF
TELNET_SB = 0xFA
TELNET_SE = 0xF0
TELNET_WILL = 0xFB
TELNET_WONT = 0xFC
TELNET_DO = 0xFD
TELNET_DONT = 0xFE
TELNET_ECHO = 0x01
TELNET_SGA = 0x03
TELNET_BINARY = 0x00


HTTP_METHODS = (b"GET ", b"POST ", b"HEAD ", b"PUT ", b"DELETE ",
                b"OPTIONS ", b"PATCH ", b"CONNECT ", b"TRACE ")

HTTP_NOTICE_BODY = (
    b"<!doctype html><html><head><meta charset=\"utf-8\">"
    b"<title>UMIX/86</title></head><body>"
    b"<h1>UMIX/86</h1>"
    b"<p>UMIX/86 is available only through an interactive serial session.</p>"
    b"<p>This port does not serve HTTP. Connect with a terminal "
    b"(telnet or raw TCP) instead.</p>"
    b"</body></html>\r\n"
)


APP_NAMES = {APP_CONSOLE: "TELNET", APP_WEB: "WEB", APP_UPLOAD: "UPLOAD"}


def _peer_text(peer) -> str:
    """'host:port' from an asyncio peername tuple (IPv4 or IPv6)."""
    if not peer:
        return ""
    try:
        return f"{peer[0]}:{peer[1]}"
    except (TypeError, IndexError):
        return str(peer)


def open_payload(client: "Client") -> bytes:
    """OPEN payload: [app id][printable line][NUL].

    The guest prints everything after the app id on its console log; a guest
    that only understands the 1-byte form ignores the rest."""
    text = client.peer_text
    if not text:
        return bytes((client.app,))
    kind = APP_NAMES.get(client.app, "MUX")
    line = f"[{kind}] {text} {client.cols}x{client.rows} ".encode("ascii", "replace")[:64]
    return bytes((client.app,)) + line + b"\0"


def looks_like_http(data: bytes) -> bool:
    """True if the first client chunk looks like an HTTP request/headers."""
    head = data.lstrip()[:512]
    first = head.split(b"\n", 1)[0].strip()
    if any(first.startswith(m) for m in HTTP_METHODS) and b"HTTP/" in first:
        return True
    if b"HTTP/1." in head[:256]:
        return True
    low = first.lower()
    return low.startswith(b"host:") or low.startswith(b"user-agent:")


async def send_http_notice(writer: asyncio.StreamWriter) -> None:
    resp = (b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: text/html; charset=utf-8\r\n"
            b"Connection: close\r\n"
            b"Content-Length: %d\r\n\r\n" % len(HTTP_NOTICE_BODY)) + HTTP_NOTICE_BODY
    writer.write(resp)
    try:
        await writer.drain()
    except (ConnectionError, OSError):
        pass
    writer.close()
    try:
        await writer.wait_closed()
    except (ConnectionError, OSError):
        pass


def input_line_feed(state: dict, data: bytes) -> list[bytes]:
    """Accumulate client input and return completed lines (on CR/LF).

    CRLF counts once, backspace edits the buffer, and the buffer is capped.
    `state` is a per-client dict so split TCP reads work.
    """
    buf: bytearray = state.setdefault("buf", bytearray())
    skip_lf: bool = state.get("skip_lf", False)
    lines: list[bytes] = []
    for b in data:
        if b in (13, 10):
            if b == 10 and skip_lf:
                skip_lf = False
                continue
            skip_lf = (b == 13)
            lines.append(bytes(buf))
            buf.clear()
        elif b in (8, 127):
            if buf:
                buf.pop()
            skip_lf = False
        else:
            skip_lf = False
            if len(buf) < 256:
                buf.append(b)
    state["skip_lf"] = skip_lf
    return lines


def telnet_filter(data: bytes, state: dict) -> tuple[bytes, bytes]:
    """Strip telnet IAC negotiation and return (payload, replies).

    `state` is a per-client dict so sequences split across TCP reads work.
    """
    out = bytearray()
    replies = bytearray()
    for b in data:
        st = state.get("s", 0)
        if st == 0:
            if b == TELNET_IAC:
                state["s"] = 1
            else:
                out.append(b)
        elif st == 1:                       # after IAC
            if b == TELNET_IAC:
                out.append(TELNET_IAC)
                state["s"] = 0
            elif b in (TELNET_WILL, TELNET_WONT, TELNET_DO, TELNET_DONT):
                state["s"] = 2
                state["cmd"] = b
            elif b == TELNET_SB:
                state["s"] = 3
            else:                           # other 2-byte command
                state["s"] = 0
        elif st == 2:                       # option byte
            cmd = state.get("cmd", 0)
            if cmd == TELNET_DO:
                replies += bytes((TELNET_IAC,
                                  TELNET_WILL if b in (TELNET_ECHO, TELNET_SGA, TELNET_BINARY) else TELNET_WONT, b))
            elif cmd == TELNET_WILL:
                replies += bytes((TELNET_IAC,
                                  TELNET_DO if b in (TELNET_SGA, TELNET_BINARY) else TELNET_DONT, b))
            state["s"] = 0
        elif st == 3:                       # subnegotiation
            if b == TELNET_IAC:
                state["s"] = 4
        elif st == 4:
            if b == TELNET_SE:
                state["s"] = 0
            elif b == TELNET_IAC:
                state["s"] = 3
            else:
                state["s"] = 3
    return bytes(out), bytes(replies)


@dataclass
class Client:
    tid: int
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    app: int = APP_CONSOLE
    queue: asyncio.Queue[bytes | None] = field(default_factory=lambda: asyncio.Queue(maxsize=256))
    stop: asyncio.Event = field(default_factory=asyncio.Event)
    writer_task: asyncio.Task | None = None
    handler_task: asyncio.Task | None = None
    retry_task: asyncio.Task | None = None
    opened: bool = False
    opened_evt: asyncio.Event = field(default_factory=asyncio.Event)
    telnet_state: dict = field(default_factory=dict)
    input_state: dict = field(default_factory=dict)
    telnet_hello: bool = False
    got_data: bool = False
    watchdog: asyncio.Task | None = None
    peer_text: str = ""
    cols: int = 80
    rows: int = 24


class Bridge:
    def __init__(
        self,
        transport: Transport,
        host: str = "0.0.0.0",
        port: int = 2323,
        max_sessions: int = 10,
        broadcast_system: bool = False,
        reset_sessions: bool = True,
        extra_listens: list[tuple[str, int]] | None = None,
        fixed_listens: list[tuple[str, int, int]] | None = None,
        http_listens: list[tuple[str, int]] | None = None,
        upload_listens: list[tuple[str, int]] | None = None,
        ip_enabled: bool = False,
        ip_telnet_listens: list[tuple[str, int]] | None = None,
        ip_udp_relays: list[tuple[str, int]] | None = None,
        tftp_listens: list[tuple[str, int]] | None = None,
        telnet: bool = False,
        baud: int = 9600,
    ) -> None:
        self.transport = transport
        self.host = host
        self.port = port
        self.extra_listens = list(extra_listens or [])
        self.fixed_listens = list(fixed_listens or [])
        self.http_listens = list(http_listens or [])
        self.upload_listens = list(upload_listens or [])
        self.ip_telnet_listens = list(ip_telnet_listens or [])
        self.ip_udp_relays_cfg = list(ip_udp_relays or [])
        self.tftp_listens = list(tftp_listens or [])
        self.telnet = telnet
        self.baud = baud
        self.max_sessions = max_sessions
        self.broadcast_system = broadcast_system
        self.reset_sessions = reset_sessions
        self.clients: dict[int, Client] = {}
        self.write_lock = asyncio.Lock()
        # The guest's HTTP parser state is global; serialize web requests.
        self.web_lock = asyncio.Lock()
        self.server: asyncio.AbstractServer | None = None
        self.servers: list[asyncio.AbstractServer] = []
        self.ports: list[int] = []
        self.reader_task: asyncio.Task | None = None
        self.decoder = FrameDecoder()
        self._hinted: set[int] = set()
        self.last_rx = 0.0
        self._stopping = False
        # optional guest IP stack (terminal id 0xFE)
        self.peer: IpPeer | None = None
        self.ip_servers: list[asyncio.AbstractServer] = []
        self.ip_udp_relays: list[UdpRelay] = []
        self.tftp_relays: list[TftpRelay] = []
        if ip_enabled:
            self.peer = IpPeer(self.send_ip_packet, baud=baud)
            self.peer.on_udp = self._on_ip_udp

    # ---- framing ----

    async def send_frame(self, ftype: int, termid: int, payload: bytes = b"",
                         byte_delay: float = 0.0) -> None:
        frame = encode_frame(ftype, termid, payload)
        async with self.write_lock:
            if byte_delay:
                # Space the frame bytes themselves: the guest UART has no
                # FIFO and a polled task may not read a whole frame in one
                # scheduler slice.
                for b in frame:
                    await self.transport.write(bytes((b,)))
                    await asyncio.sleep(byte_delay)
            else:
                await self.transport.write(frame)
        LOG.debug("tx type=%d tid=%d len=%d", ftype, termid, len(payload))

    async def send_ip_packet(self, packet: bytes) -> None:
        await self.send_frame(DATA, TERM_IP, packet)

    async def _on_ip_udp(self, info: dict) -> None:
        for relay in self.tftp_relays:
            await relay.on_guest(info)

    async def handle_ip_client(self, reader: asyncio.StreamReader,
                               writer: asyncio.StreamWriter) -> None:
        """TCP client -> a guest IP-stack terminal session (UDP 2323)."""
        assert self.peer is not None
        peername = writer.get_extra_info("peername")
        try:
            sess = await self.peer.open_session()
        except Exception as exc:  # noqa: BLE001 - refusal is reported to the client
            LOG.warning("no IP session for %s: %s", peername, exc)
            try:
                writer.write(b"\r\nUMIX/86: no terminal session available\r\n")
                await writer.drain()
            except (ConnectionError, OSError):
                pass
            writer.close()
            return
        LOG.info("IP terminal %d -> %s", sess.sid, peername)
        state: dict = {}

        async def pump_out() -> None:
            while True:
                chunk = await sess.queue.get()
                if chunk is None:
                    return
                if self.telnet:
                    chunk = chunk.replace(b"\xff", b"\xff\xff")
                writer.write(chunk)
                await writer.drain()

        out_task = asyncio.create_task(pump_out())
        try:
            while True:
                data = await reader.read(2048)
                if not data:
                    break
                if self.telnet:
                    data, replies = telnet_filter(data, state)
                    if replies:
                        writer.write(replies)
                if data:
                    await self.peer.send_data(sess, data)
        except (ConnectionError, OSError):
            pass
        finally:
            out_task.cancel()
            await self.peer.close_session(sess)
            try:
                writer.close()
            except OSError:
                pass

    def alloc_id(self) -> int | None:
        for tid in range(1, self.max_sessions + 1):
            if tid not in self.clients:
                return tid
        return None

    # ---- TCP clients ----

    async def writer_loop(self, client: Client) -> None:
        try:
            while True:
                data = await client.queue.get()
                if data is None:
                    client.queue.task_done()
                    return
                if self.telnet and client.app == APP_CONSOLE:
                    data = data.replace(b"\xff", b"\xff\xff")
                client.writer.write(data)
                await client.writer.drain()
                client.queue.task_done()
        except (ConnectionError, asyncio.CancelledError):
            return

    async def open_retry(self, client: Client) -> None:
        """Resend OPEN until the guest ACKs (it may boot after the TCP client)."""
        for _ in range(5):
            try:
                await asyncio.wait_for(client.opened_evt.wait(), timeout=0.5)
                return
            except asyncio.TimeoutError:
                if client.tid not in self.clients or self._stopping:
                    return
                if client.tid not in self._hinted:
                    self._hinted.add(client.tid)
                    LOG.warning(
                        "no ACK for terminal %d: the guest is not answering a "
                        "framed OPEN. Most likely it is not in MUX mode - "
                        "uncomment 'MUX ON' in STARTUP.JCL and reboot. "
                        "Recent bytes from the guest: %r",
                        client.tid, self.decoder.peek_junk()[-48:])
                else:
                    LOG.warning("no ACK for terminal %d; retrying OPEN", client.tid)
                try:
                    await self.send_frame(OPEN, client.tid, open_payload(client))
                except Exception as exc:
                    LOG.debug("OPEN retry failed: %s", exc)
                    return

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
                            fixed_tid: int | None = None, app: int = APP_CONSOLE) -> None:
        peer = writer.get_extra_info("peername")
        first = b""
        try:
            first = await asyncio.wait_for(reader.read(4096), timeout=0.10)
        except asyncio.TimeoutError:
            first = b""
        if first == b"" and reader.at_eof():
            return
        if app == APP_CONSOLE and first and looks_like_http(first):
            LOG.info("tcp %s: HTTP request; sending notice", peer)
            await send_http_notice(writer)
            return
        # A browser preconnect sends nothing.  Do not open a guest session (and
        # do not hold the web lock) for it; wait briefly for a real request.
        if app == APP_WEB and not first:
            try:
                first = await asyncio.wait_for(reader.read(4096), timeout=5.0)
            except asyncio.TimeoutError:
                first = b""
            if not first:
                writer.close()
                return
        # The guest's HTTP parser state (web_path/web_state/...) is global.
        # Serialize from OPEN, not just at DATA time: a second web task would
        # otherwise clear that state while the first is still serving.
        web_locked = False
        if app == APP_WEB:
            await self.web_lock.acquire()
            web_locked = True
        try:
            if fixed_tid is not None:
                if fixed_tid in self.clients:
                    writer.write(b"UMIX: terminal %d is in use\r\n" % fixed_tid)
                    await writer.drain()
                    writer.close()
                    LOG.warning("rejecting %s: terminal %d busy", peer, fixed_tid)
                    return
                tid = fixed_tid
            else:
                tid = self.alloc_id()
                if tid is None:
                    writer.write(b"UMIX: all serial sessions are in use\r\n")
                    await writer.drain()
                    writer.close()
                    LOG.warning("rejecting %s: no free session", peer)
                    return

            client = Client(tid=tid, app=app, reader=reader, writer=writer,
                            peer_text=_peer_text(peer))
            client.handler_task = asyncio.current_task()
            client.writer_task = asyncio.create_task(self.writer_loop(client))
            self.clients[tid] = client
            LOG.info("tcp %s -> terminal %d app=%d", peer, tid, app)
            await self.send_frame(OPEN, tid, open_payload(client))
            client.retry_task = asyncio.create_task(self.open_retry(client))
            if app in (APP_WEB, APP_UPLOAD):
                # do not send DATA before the guest has claimed the session
                try:
                    await asyncio.wait_for(client.opened_evt.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    LOG.warning("terminal %d not acknowledged; sending anyway", tid)

            if app in (APP_WEB, APP_UPLOAD):
                client.watchdog = asyncio.create_task(self.silence_watchdog(client))
            try:
                await self.feed_client(client, first)
                while True:
                    data = await reader.read(4096)
                    if not data:
                        break
                    await self.feed_client(client, data)
            except (ConnectionError, asyncio.CancelledError):
                pass
            finally:
                await self.close_client(tid, send_close=True, reason="tcp disconnect")
        finally:
            if web_locked:
                self.web_lock.release()

    async def silence_watchdog(self, client: Client) -> None:
        """A web/upload session that ACKs but never answers means the guest's
        application task is not reading its input ring."""
        try:
            for _ in range(3):
                await asyncio.sleep(2.0)
                if client.got_data or client.tid not in self.clients:
                    return
            LOG.warning("terminal %d (app %d) acknowledged but sent nothing for 6 s: "
                        "the guest task is not reading the request "
                        "(stale session? reboot the guest)", client.tid, client.app)
        except asyncio.CancelledError:
            pass

    async def feed_client(self, client: Client, data: bytes) -> None:
        if not data:
            return
        if self.telnet and client.app == APP_CONSOLE and not client.telnet_hello and data[:1] == b"\xff":
            client.telnet_hello = True
            # The guest echoes; tell the telnet client to stop local echo.
            client.writer.write(bytes((TELNET_IAC, TELNET_WILL, TELNET_ECHO,
                                       TELNET_IAC, TELNET_WILL, TELNET_SGA)))
            await client.writer.drain()
            LOG.debug("tcp tid=%d: telnet WILL ECHO/SGA sent", client.tid)
        if self.telnet and client.app == APP_CONSOLE:
            data, replies = telnet_filter(data, client.telnet_state)
            if replies:
                client.writer.write(replies)
                await client.writer.drain()
            if not data:
                return
        if LOG.isEnabledFor(logging.DEBUG):
            for line in input_line_feed(client.input_state, data):
                LOG.debug("tcp tid=%d input: %r", client.tid, line)
        # The guest UART (8250/16450) has NO receive FIFO: it must copy each
        # byte within ~1 ms at 9600 or the byte is lost.  A back-to-back burst
        # therefore corrupts any request longer than a few dozen bytes.  The
        # upload/web paths pace their 64-byte frames; console input is paced
        # one byte at a time because the shell tasks only poll between
        # scheduler slices, and a short unpaced line is still lost while BASIC
        # is running.
        line_byte = 10.0 / max(self.baud, 1200)
        byte_delay = 0.0
        if client.app == APP_UPLOAD:
            chunk = 64
            delay = line_byte * chunk * 1.35
        elif client.app == APP_WEB:
            chunk = 64
            delay = line_byte * chunk * 1.35
        elif client.app == APP_CONSOLE:
            chunk = 8
            delay = 0.0
            byte_delay = 0.010               # space the frame bytes, not just lines
        elif len(data) <= 64:
            chunk, delay = 64, 0.0          # single frame: no pacing needed
        else:
            chunk = 64
            delay = line_byte * chunk * 1.35
        for start in range(0, len(data), chunk):
            await self.send_frame(DATA, client.tid, data[start:start + chunk],
                                  byte_delay=byte_delay)
            if delay:
                await asyncio.sleep(delay)

    async def close_client(self, tid: int, send_close: bool, reason: str) -> None:
        client = self.clients.pop(tid, None)
        if client is None:
            return

        LOG.info("closing terminal %d (%s)", tid, reason)
        if send_close and not self._stopping:
            try:
                await self.send_frame(CLOSE, tid)
            except Exception as exc:  # serial may already be gone
                LOG.debug("close frame failed: %s", exc)

        client.stop.set()
        try:
            client.queue.put_nowait(None)
        except asyncio.QueueFull:
            pass
        if client.retry_task:
            client.retry_task.cancel()
        if client.watchdog:
            client.watchdog.cancel()
        if client.writer_task:
            client.writer_task.cancel()
        try:
            client.writer.close()
            await client.writer.wait_closed()
        except Exception:
            pass
        if client.handler_task and client.handler_task is not asyncio.current_task():
            client.handler_task.cancel()

    async def guest_close(self, tid: int, reason: str) -> None:
        client = self.clients.get(tid)
        if client is None:
            return
        if client.app != APP_CONSOLE:
            # close only after every queued DATA frame has been written
            try:
                await asyncio.wait_for(client.queue.join(), timeout=2.0)
            except asyncio.TimeoutError:
                pass
        else:
            try:
                client.writer.write((reason + "\r\n").encode())
                await client.writer.drain()
            except Exception:
                pass
        await self.close_client(tid, send_close=False, reason=reason)

    # ---- serial reader ----

    async def serial_reader(self) -> None:
        while not self._stopping:
            try:
                data = await self.transport.read(256)
            except Exception as exc:
                if not self._stopping:
                    LOG.error("serial read failed: %s", exc)
                break

            now = time.monotonic()
            if data:
                self.last_rx = now
            elif self.decoder.state != FrameDecoder.WAIT_STX and now - self.last_rx > 0.5:
                LOG.warning("resetting stuck serial frame decoder")
                self.decoder.reset()

            before = self.decoder.errors
            frames = self.decoder.feed(data)
            if self.decoder.errors != before:
                sample = self.decoder.take_junk()
                LOG.warning("serial frame errors: +%d (total %d); stray bytes "
                            "%s (%r)", self.decoder.errors - before,
                            self.decoder.errors, sample.hex(), sample)
            for ftype, termid, payload in frames:
                await self.dispatch(ftype, termid, payload)

        if not self._stopping:
            LOG.error("serial reader stopped")
            for tid in list(self.clients):
                await self.close_client(tid, send_close=False, reason="serial link down")

    async def dispatch(self, ftype: int, termid: int, payload: bytes) -> None:
        LOG.debug("rx type=%d tid=%d len=%d", ftype, termid, len(payload))
        if ftype == DATA:
            if termid == TERM_IP:
                if self.peer is not None:
                    await self.peer.feed(payload)
                return
            if termid == 0:
                text = payload.decode("latin1", "replace")
                LOG.info("guest: %s", text.rstrip("\r\n"))
                if self.broadcast_system:
                    for client in list(self.clients.values()):
                        try:
                            client.queue.put_nowait(payload)
                        except asyncio.QueueFull:
                            pass
                return
            client = self.clients.get(termid)
            if client is None:
                LOG.debug("data for unknown terminal %d dropped", termid)
                return
            client.got_data = True
            try:
                client.queue.put_nowait(payload)
            except asyncio.QueueFull:
                LOG.warning("terminal %d output queue full; dropping client", termid)
                asyncio.create_task(self.guest_close(termid, "UMIX: output overflow"))
        elif ftype == ACK:
            client = self.clients.get(termid)
            if client:
                client.opened = True
                client.opened_evt.set()
                LOG.info("terminal %d acknowledged", termid)
        elif ftype == BUSY:
            LOG.warning("guest BUSY for terminal %d", termid)
            await self.guest_close(termid, "UMIX: no serial session available")
        elif ftype == CLOSE:
            LOG.info("guest closed terminal %d", termid)
            await self.guest_close(termid, "UMIX: session closed")
        elif ftype == ERROR:
            code = payload[0] if payload else 0
            LOG.warning("guest protocol error %d for terminal %d", code, termid)
        else:
            LOG.debug("ignoring unknown frame type %d", ftype)

    # ---- lifecycle ----

    async def start(self) -> None:
        self.reader_task = asyncio.create_task(self.serial_reader())
        if self.reset_sessions:
            # Clear stale guest sessions BEFORE accepting TCP clients, so a
            # startup CLOSE cannot race with a new OPEN.
            for tid in range(1, self.max_sessions + 1):
                await self.send_frame(CLOSE, tid)
            await asyncio.sleep(0.2)
        self.server = await asyncio.start_server(self.handle_client, self.host, self.port)
        self.servers.append(self.server)
        sockets = self.server.sockets or []
        if sockets:
            self.port = sockets[0].getsockname()[1]
        self.ports.append(self.port)
        LOG.info("listening on %s:%d (max %d sessions)", self.host, self.port, self.max_sessions)
        for lhost, lport in self.extra_listens:
            srv = await asyncio.start_server(self.handle_client, lhost, lport)
            self.servers.append(srv)
            bound = srv.sockets[0].getsockname()[1] if srv.sockets else lport
            self.ports.append(bound)
            LOG.info("listening on %s:%d (pooled)", lhost, bound)
        for lhost, lport, tid in self.fixed_listens:
            srv = await asyncio.start_server(
                lambda r, w, t=tid: self.handle_client(r, w, fixed_tid=t), lhost, lport)
            self.servers.append(srv)
            bound = srv.sockets[0].getsockname()[1] if srv.sockets else lport
            self.ports.append(bound)
            LOG.info("listening on %s:%d -> terminal %d", lhost, bound, tid)
        for lhost, lport in self.http_listens:
            srv = await asyncio.start_server(
                lambda r, w: self.handle_client(r, w, app=APP_WEB), lhost, lport)
            self.servers.append(srv)
            bound = srv.sockets[0].getsockname()[1] if srv.sockets else lport
            self.ports.append(bound)
            LOG.info("listening on %s:%d (web -> app %d)", lhost, bound, APP_WEB)
        for lhost, lport in self.upload_listens:
            srv = await asyncio.start_server(
                lambda r, w: self.handle_client(r, w, app=APP_UPLOAD), lhost, lport)
            self.servers.append(srv)
            bound = srv.sockets[0].getsockname()[1] if srv.sockets else lport
            self.ports.append(bound)
            LOG.info("listening on %s:%d (upload -> app %d)", lhost, bound, APP_UPLOAD)
        if self.peer is not None:
            for lhost, lport in self.ip_telnet_listens:
                srv = await asyncio.start_server(self.handle_ip_client, lhost, lport)
                self.ip_servers.append(srv)
                bound = srv.sockets[0].getsockname()[1] if srv.sockets else lport
                LOG.info("IP terminal on %s:%d -> guest UDP 2323", lhost, bound)
            for rhost, rport in self.ip_udp_relays_cfg:
                relay = UdpRelay(self.peer, rhost, rport)
                await relay.start()
                self.ip_udp_relays.append(relay)
                LOG.info("IP UDP relay on %s:%d (raw session bytes)", *relay.bound)
            for thost, tport in self.tftp_listens:
                trelay = TftpRelay(self.send_ip_packet, thost, tport)
                await trelay.start()
                self.tftp_relays.append(trelay)

    async def stop(self) -> None:
        self._stopping = True
        for srv in self.servers:
            srv.close()
        for srv in self.servers:
            await srv.wait_closed()
        for srv in self.ip_servers:
            srv.close()
        for srv in self.ip_servers:
            await srv.wait_closed()
        for relay in self.ip_udp_relays:
            await relay.close()
        for relay in self.tftp_relays:
            await relay.close()
        for tid in list(self.clients):
            await self.close_client(tid, send_close=False, reason="bridge shutdown")
        if self.reader_task:
            self.reader_task.cancel()
            try:
                await self.reader_task
            except asyncio.CancelledError:
                pass
        await self.transport.close()


def parse_listen(value: str) -> tuple[str, int]:
    host, sep, port = value.rpartition(":")
    if not sep:
        return "0.0.0.0", int(value)
    return (host or "0.0.0.0"), int(port)


def parse_fixed(value: str) -> tuple[str, int, int]:
    """HOST:PORT,TID"""
    addr, sep, tid = value.rpartition(",")
    if not sep:
        raise argparse.ArgumentTypeError("expected HOST:PORT,TID")
    host, port = parse_listen(addr)
    return host, port, int(tid)


async def async_main(args: argparse.Namespace) -> None:
    listens = [parse_listen(v) for v in (args.listen or ["0.0.0.0:2323"])]
    host, port = listens[0]
    fixed = [parse_fixed(v) for v in (args.listen_fixed or [])]
    http = [parse_listen(v) for v in (args.http_listen or [])]
    upload = [parse_listen(v) for v in (args.upload_listen or [])]
    ip_telnet = [parse_listen(v) for v in (args.ip_telnet or [])]
    ip_udp = [parse_listen(v) for v in (args.udp_relay or [])]
    tftp = [parse_listen(v) for v in (args.tftp_listen or [])]
    ip_enabled = bool(args.ip or ip_telnet or ip_udp or tftp)
    if args.fake:
        transport: Transport = FakeGuestTransport()
    elif args.serial.startswith("unix:"):
        transport = UnixSocketTransport(args.serial[5:])
    else:
        LOG.info("opening serial %s @ %d 8N1", args.serial, args.baud)
        try:
            transport = SerialTransport(args.serial, args.baud)
        except Exception as exc:
            LOG.error("cannot open serial port %s: %s", args.serial, exc)
            LOG.error("Windows: use COMx (COM10+ -> \\\\.\\COM10) and close Tera Term first")
            return
    await transport.connect()

    bridge = Bridge(
        transport,
        host=host,
        port=port,
        max_sessions=args.max_sessions,
        broadcast_system=args.broadcast_system,
        reset_sessions=not args.no_reset,
        extra_listens=listens[1:],
        fixed_listens=fixed,
        http_listens=http,
        upload_listens=upload,
        ip_enabled=ip_enabled,
        ip_telnet_listens=ip_telnet,
        ip_udp_relays=ip_udp,
        tftp_listens=tftp,
        telnet=args.telnet,
        baud=args.baud,
    )
    await bridge.start()
    try:
        await asyncio.Event().wait()
    finally:
        await bridge.stop()



async def raw_main(args: argparse.Namespace) -> None:
    """Raw serial bridge: one TCP client, no UMIX framing.

    The guest must be in raw console mode (MUX OFF).  Used for a single
    terminal/session; the framed mode remains the default for the lab scripts.
    """
    if args.fake:
        LOG.error("--fake requires framed mode")
        return
    if (args.listen_fixed or args.http_listen or args.upload_listen
            or args.ip or args.ip_telnet or args.udp_relay or args.tftp_listen):
        LOG.warning("raw mode ignores --listen-fixed/--http-listen/--upload-listen "
                    "and the IP/TFTP listeners (they need framed MUX)")
    if args.serial.startswith("unix:"):
        transport: Transport = UnixSocketTransport(args.serial[5:])
    else:
        LOG.info("opening serial %s @ %d 8N1 (raw)", args.serial, args.baud)
        try:
            transport = SerialTransport(args.serial, args.baud)
        except Exception as exc:
            LOG.error("cannot open serial port %s: %s", args.serial, exc)
            return
    await transport.connect()
    host, port = parse_listen((args.listen or ["0.0.0.0:2323"])[0])
    busy = False

    async def handle(reader: asyncio.StreamReader,
                     writer: asyncio.StreamWriter) -> None:
        nonlocal busy
        if busy:
            writer.write(b"UMIX SERIAL BRIDGE BUSY\r\n")
            try:
                await writer.drain()
            except (ConnectionError, OSError):
                pass
            writer.close()
            return
        busy = True
        LOG.info("raw client connected")
        telnet_state: dict = {}
        telnet_hello = False

        async def tcp_to_serial() -> None:
            nonlocal telnet_hello
            while True:
                data = await reader.read(4096)
                if not data:
                    return
                if args.telnet:
                    if not telnet_hello and data[:1] == b"\xff":
                        telnet_hello = True
                        writer.write(bytes((TELNET_IAC, TELNET_WILL, TELNET_ECHO,
                                            TELNET_IAC, TELNET_WILL, TELNET_SGA)))
                        await writer.drain()
                    data, replies = telnet_filter(data, telnet_state)
                    if replies:
                        writer.write(replies)
                        await writer.drain()
                    if not data:
                        continue
                await transport.write(data)

        async def serial_to_tcp() -> None:
            while True:
                data = await transport.read(4096)
                if data:
                    if args.telnet:
                        data = data.replace(b"\xff", b"\xff\xff")
                    writer.write(data)
                    await writer.drain()

        tasks = {asyncio.create_task(tcp_to_serial()),
                 asyncio.create_task(serial_to_tcp())}
        try:
            done, pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
        except (ConnectionError, OSError):
            pass
        finally:
            busy = False
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass
            LOG.info("raw client disconnected")

    server = await asyncio.start_server(handle, host, port)
    LOG.info("raw serial bridge on %s:%d (no framing, one client)", host, port)
    try:
        async with server:
            await server.serve_forever()
    finally:
        await transport.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="UMIX/86 serial console multiplexer")
    parser.add_argument("--version", action="version",
                        version="serial_mux frame-paced 2026-11-17 "
                                "(framed + IP: sessions, TFTP, UDP relay; "
                                "console 8 data bytes/frame, 10 ms/frame byte)")
    parser.add_argument("--framed", action=argparse.BooleanOptionalAction,
                        default=True,
                        help="UMIX framed mux (default); --no-framed is a raw "
                             "one-client serial bridge (guest MUX OFF)")
    parser.add_argument("--serial", default="/dev/ttyUSB0",
                        help="serial device, or unix:/path for a QEMU serial socket")
    parser.add_argument("--baud", type=int, default=9600, help="serial baud rate")
    parser.add_argument("--listen", action="append", metavar="HOST:PORT",
                        help="pooled TCP listener (repeatable; default 0.0.0.0:2323)")
    parser.add_argument("--listen-fixed", action="append", metavar="HOST:PORT,TID",
                        help="listener bound to a fixed terminal id (repeatable)")
    parser.add_argument("--http-listen", action="append", metavar="HOST:PORT",
                        help="web listener: serves INDEX.HTM from the guest (repeatable)")
    parser.add_argument("--upload-listen", action="append", metavar="HOST:PORT",
                        help="upload listener: PUT NAME SIZE + bytes (repeatable)")
    parser.add_argument("--ip", action="store_true",
                        help="enable the guest IP stack (terminal id 0xFE); implied "
                             "by --ip-telnet/--udp-relay/--tftp-listen")
    parser.add_argument("--ip-telnet", action="append", metavar="HOST:PORT",
                        help="TCP -> guest IP terminal session (repeatable)")
    parser.add_argument("--udp-relay", action="append", metavar="HOST:PORT",
                        help="UDP relay over the guest IP stack (repeatable)")
    parser.add_argument("--tftp-listen", action="append", metavar="HOST:PORT",
                        help="TFTP relay to the guest server (blksize 8..192)")
    parser.add_argument("--max-sessions", type=int, default=10, help="guest session slots (1..10)")
    parser.add_argument("--telnet", action="store_true",
                        help="accept telnet clients in framed or raw mode: "
                             "negotiate/strip IAC and escape 0xFF")
    parser.add_argument("--fake", action="store_true", help="use in-memory fake guest")
    parser.add_argument("--broadcast-system", action="store_true",
                        help="send terminal-id 0 guest messages to all clients")
    parser.add_argument("--no-reset", action="store_true",
                        help="do not send CLOSE for 1..max-sessions at startup")
    parser.add_argument("--log-level", default="INFO",
                        choices=("DEBUG", "INFO", "WARNING", "ERROR"))
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    LOG.info("serial_mux frame-paced console: 8 data bytes/frame, "
             "10 ms between frame bytes")
    try:
        if args.framed:
            asyncio.run(async_main(args))
        else:
            asyncio.run(raw_main(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
