#!/usr/bin/env python3
"""UMIX/86 — terminals over IP.

This program is the *IP* transport: the guest's own IPv4 stack carries the
terminal sessions (UDP port 2323 inside the mux ``0xFE`` channel), and the tool
exposes them as TCP (``--telnet-listen``) or raw UDP (``--udp-relay``).

It is deliberately a separate program from ``tools/serial_mux.py``:

    serial_mux.py   standard mux: TCP client -> guest terminal id 1..10
    mux_over_ip.py  IP mux:      TCP/UDP client -> guest session over its IP stack

One serial port carries one of them at a time.  Both share the same wire codec
and the same transports, which is why this file imports them rather than
reimplementing them.

    python3 tools/mux_over_ip.py --serial /dev/ttyUSB0 \\
            --telnet-listen 0.0.0.0:2400
    python3 tools/mux_over_ip.py --serial COM3 --udp-relay 127.0.0.1:2400

The guest needs ``MUX ON`` in STARTUP.JCL: without the framed link there is no
0xFE channel and no IP at all.
"""

from __future__ import annotations

import argparse
import asyncio
import logging

from ip_peer import TERM_IP, IpPeer, TftpRelay, UdpRelay
from serial_mux import (
    DATA,
    FakeGuestTransport,
    FrameDecoder,
    SerialTransport,
    Transport,
    UnixSocketTransport,
    encode_frame,
    parse_listen,
    telnet_filter,
)

LOG = logging.getLogger("mux_over_ip")

class IpBridge:
    """Routes the guest's 0xFE channel to terminal sessions and nothing else."""

    def __init__(
        self,
        transport: Transport,
        *,
        telnet: bool = False,
        telnet_listens: list[tuple[str, int]] | None = None,
        udp_relays: list[tuple[str, int]] | None = None,
        tftp_listens: list[tuple[str, int]] | None = None,
        quiet: bool = False,
        baud: int = 9600,
    ) -> None:
        self.quiet = quiet
        self.baud = baud
        self.transport = transport
        self.telnet = telnet
        self.telnet_listens = list(telnet_listens or [])
        self.udp_relays_cfg = list(udp_relays or [])
        self.tftp_relays_cfg = list(tftp_listens or [])
        self.peer = IpPeer(self.send_packet, baud=baud)
        self.peer.on_udp = self._on_udp
        self.udp_relays: list[UdpRelay] = []
        self.tftp_relays: list[TftpRelay] = []
        self.servers: list[asyncio.AbstractServer] = []
        self.ports: dict[str, int] = {}
        self.decoder = FrameDecoder()
        self.write_lock = asyncio.Lock()
        self.reader_task: asyncio.Task | None = None
        self._stopping = False
        # session-id -> asyncio task pumping guest output to the TCP client
        self._pumps: dict[object, asyncio.Task] = {}

    # ---- wire ----

    async def send_packet(self, packet: bytes) -> None:
        frame = encode_frame(DATA, TERM_IP, packet)
        async with self.write_lock:
            await self.transport.write(frame)

    async def reader_loop(self) -> None:
        while not self._stopping:
            data = await self.transport.read(4096)
            if not data:
                continue
            for ftype, termid, payload in self.decoder.feed(data):
                if ftype == DATA and termid == TERM_IP:
                    await self.peer.feed(payload)
                else:
                    LOG.debug("ignoring frame type=%d term=%d len=%d",
                              ftype, termid, len(payload))

    # ---- TCP terminals ----

    async def handle_client(self, reader: asyncio.StreamReader,
                            writer: asyncio.StreamWriter) -> None:
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

    async def _on_udp(self, info: dict) -> None:
        for relay in self.tftp_relays:
            await relay.on_guest(info)

    # ---- lifecycle ----

    async def start(self) -> None:
        self.reader_task = asyncio.create_task(self.reader_loop())
        for lhost, lport in self.telnet_listens:
            srv = await asyncio.start_server(self.handle_client, lhost, lport)
            self.servers.append(srv)
            bound = srv.sockets[0].getsockname()[1] if srv.sockets else lport
            self.ports[f"telnet:{lhost}"] = bound
            LOG.info("TCP terminal on %s:%d -> guest IP stack", lhost, bound)
        for rhost, rport in self.udp_relays_cfg:
            relay = UdpRelay(self.peer, rhost, rport)
            await relay.start()
            self.udp_relays.append(relay)
            LOG.info("UDP relay on %s:%d (raw session bytes)", *relay.bound)
        for thost, tport in self.tftp_relays_cfg:
            trelay = TftpRelay(self.send_packet, thost, tport)
            await trelay.start()
            self.tftp_relays.append(trelay)
        if (not self.servers and not self.udp_relays
                and not self.tftp_relays and not self.quiet):
            LOG.warning("no listener configured; nothing will answer")

    async def stop(self) -> None:
        self._stopping = True
        for relay in self.udp_relays:
            await relay.close()
        for relay in self.tftp_relays:
            await relay.close()
        for srv in self.servers:
            srv.close()
        for srv in self.servers:
            await srv.wait_closed()
        if self.reader_task:
            self.reader_task.cancel()
            try:
                await self.reader_task
            except asyncio.CancelledError:
                pass
        await self.transport.close()


async def async_main(args: argparse.Namespace) -> int | None:
    telnet_listens = [parse_listen(v) for v in (args.telnet_listen or [])]
    udp_relays = [parse_listen(v) for v in (args.udp_relay or [])]
    tftp_listens = [parse_listen(v) for v in (args.tftp_listen or [])]
    if not telnet_listens and not udp_relays and not tftp_listens:
        telnet_listens = [("0.0.0.0", 2400)]

    if args.fake:
        transport: Transport = FakeGuestTransport()
    elif args.serial.startswith("unix:"):
        transport = UnixSocketTransport(args.serial[5:])
    else:
        LOG.info("opening serial %s @ %d 8N1", args.serial, args.baud)
        try:
            transport = SerialTransport(args.serial, args.baud)
        except Exception as exc:  # noqa: BLE001
            LOG.error("cannot open serial port %s: %s", args.serial, exc)
            LOG.error("Windows: use COMx (COM10+ -> \\\\.\\COM10) and close "
                      "Tera Term first")
            return
    await transport.connect()

    if args.probe:
        probe = IpBridge(transport, quiet=True, baud=args.baud)
        await probe.start()
        try:
            sess = await probe.peer.open_session(timeout=2.0, attempts=3)
            print(f"PROBE OK: guest granted session id {sess.sid}")
            await probe.peer.close_session(sess)   # do not leak a guest slot
            rc = 0
        except Exception as exc:  # noqa: BLE001
            print(f"PROBE REFUSED: {exc}")
            print("  the guest answered, so MUX is on - but it has no free "
                  "session. Run PS on the console to see busy slots.")
            rc = 1
        await asyncio.sleep(0.3)
        await probe.stop()
        return rc

    bridge = IpBridge(transport, telnet=args.telnet,
                      telnet_listens=telnet_listens, udp_relays=udp_relays,
                      tftp_listens=tftp_listens, baud=args.baud)
    await bridge.start()
    LOG.info("IP transport ready (the guest needs MUX ON)")
    try:
        await asyncio.Event().wait()
    finally:
        await bridge.stop()
    return None


def main() -> None:
    parser = argparse.ArgumentParser(
        description="UMIX/86 terminals over the guest's IP stack "
                    "(separate from the standard serial mux)")
    parser.add_argument("--serial", default="/dev/ttyUSB0",
                        help="serial device, or unix:/path for a QEMU serial socket")
    parser.add_argument("--baud", type=int, default=9600, help="serial baud rate")
    parser.add_argument("--telnet-listen", action="append", metavar="HOST:PORT",
                        help="TCP terminal listener (default 0.0.0.0:2400)")
    parser.add_argument("--udp-relay", action="append", metavar="HOST:PORT",
                        help="UDP relay: each client gets a raw-byte session")
    parser.add_argument("--tftp-listen", action="append", metavar="HOST:PORT",
                        help="TFTP relay to the guest server (blksize 8..192)")
    parser.add_argument("--telnet", action="store_true",
                        help="strip telnet IAC negotiation on TCP clients")
    parser.add_argument("--probe", action="store_true",
                        help="ask the guest for one session, report, exit")
    parser.add_argument("--fake", action="store_true", help="use in-memory fake guest")
    parser.add_argument("--log-level", default="INFO",
                        choices=("DEBUG", "INFO", "WARNING", "ERROR"))
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    try:
        rc = asyncio.run(async_main(args))
    except KeyboardInterrupt:
        rc = None
    raise SystemExit(rc or 0)


if __name__ == "__main__":
    main()
