#!/usr/bin/env python3
"""Minimal TFTP client for the UMIX/86 guest server.

The guest serves TFTP over its IP stack (UDP 69) with a negotiated block size
of at most 192 bytes: one 250-byte mux frame carries it whole.  Standard
512-byte blocks do not fit, so clients without a `blksize` option (Windows
tftp, curl) cannot talk to it.  This client always asks for 192.

    py tools\\umix_tftp.py get README.TXT
    py tools\\umix_tftp.py put TEST.BAS
    py tools\\umix_tftp.py --port 6969 get C:INDEX.HTM index.htm

Start the relay first:

    py tools\\mux_over_ip.py --serial COM3 --baud 9600 --tftp-listen 127.0.0.1:6969

The guest needs `TFTP ON` at the CGA console; PUT also needs `WRITE ON`.
"""
from __future__ import annotations

import argparse
import os
import socket
import struct
import sys
import time

RRQ, WRQ, DATA, ACK, ERROR, OACK = 1, 2, 3, 4, 5, 6

ERR_NAMES = {
    0: "not defined",
    1: "file not found",
    2: "access violation",
    3: "disk full",
    4: "illegal operation",
    5: "unknown transfer id",
    6: "file already exists",
    7: "no such user",
    8: "option negotiation failed",
}


def _pack(op: int, block: int = 0) -> bytes:
    return struct.pack(">HH", op, block)


def _req(op: int, name: str, blksize: int, tsize: int | None,
         windowsize: int | None = None) -> bytes:
    out = bytearray(struct.pack(">H", op))
    out += name.encode("ascii", "replace") + b"\x00octet\x00"
    out += b"blksize\x00" + str(blksize).encode() + b"\x00"
    if tsize is not None:
        out += b"tsize\x00" + str(tsize).encode() + b"\x00"
    if windowsize:
        out += b"windowsize\x00" + str(windowsize).encode() + b"\x00"
    return bytes(out)


def _parse_opts(pkt: bytes) -> dict[str, str]:
    parts = pkt[2:].split(b"\x00")
    opts: dict[str, str] = {}
    for i in range(0, len(parts) - 1, 2):
        if not parts[i]:
            break
        opts[parts[i].decode("ascii", "replace").lower()] = \
            parts[i + 1].decode("ascii", "replace")
    return opts


def _error(pkt: bytes) -> str:
    code = struct.unpack(">H", pkt[2:4])[0]
    msg = pkt[4:].split(b"\x00", 1)[0].decode("ascii", "replace")
    return f"ERROR {code} ({ERR_NAMES.get(code, '?')}): {msg}"


class Tftp:
    def __init__(self, host: str, port: int, blksize: int,
                 timeout: float, retries: int) -> None:
        self.host = host
        self.port = port
        self.blksize = blksize
        self.timeout = timeout
        self.retries = retries
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)
        self.peer = (host, port)
        self.windowsize = 1

    def close(self) -> None:
        self.sock.close()

    def _send(self, data: bytes) -> None:
        self.sock.sendto(data, self.peer)

    def _recv(self) -> bytes:
        data, addr = self.sock.recvfrom(2048)
        if addr != self.peer:
            # TFTP: follow the server's transfer id
            self.peer = addr
        return data

    def _exchange(self, first: bytes) -> tuple[int, bytes]:
        """Send `first`, then retransmit it on timeout until something arrives."""
        for attempt in range(self.retries + 1):
            self._send(first)
            try:
                pkt = self._recv()
            except socket.timeout:
                if attempt < self.retries:
                    print(f"  timeout, retry {attempt + 1}/{self.retries}")
                    continue
                raise TimeoutError("no response from the server")
            op = struct.unpack(">H", pkt[:2])[0]
            if op == ERROR:
                raise RuntimeError(_error(pkt))
            return op, pkt
        raise TimeoutError("no response from the server")

    def _wait_ack(self, pkt: bytes, block: int) -> None:
        """Send one DATA packet, then wait for ACK `block`.

        A retransmitted DATA makes the server ACK twice; the stale ACK must
        be ignored, not treated as an error (TFTP duplicate-ACK rule)."""
        for attempt in range(self.retries + 1):
            if attempt:
                print(f"  timeout, retry {attempt}/{self.retries}")
            self._send(pkt)
            deadline = time.time() + self.timeout
            while True:
                left = deadline - time.time()
                if left <= 0:
                    break
                self.sock.settimeout(left)
                try:
                    reply = self._recv()
                except socket.timeout:
                    break
                op = struct.unpack(">H", reply[:2])[0]
                if op == ERROR:
                    raise RuntimeError(_error(reply))
                if op != ACK:
                    raise RuntimeError(f"expected ACK, got op={op}")
                ack = struct.unpack(">H", reply[2:4])[0]
                if ack == block:
                    return
                if ack < block:          # stale/duplicate ACK for an earlier block
                    print(f"  stale ACK {ack} (want {block}), ignoring")
                    continue
                raise RuntimeError(f"ACK {ack}, sent {block}")
        raise TimeoutError("no response from the server")

    # ---- download ----
    def get(self, remote: str, local: str) -> int:
        op, pkt = self._exchange(_req(RRQ, remote, self.blksize, 0, 4))
        expected = 1
        got = 0
        wrote = 0
        start = time.time()
        with open(local, "wb") as fh:
            if op == OACK:
                opts = _parse_opts(pkt)
                if "blksize" in opts:
                    self.blksize = int(opts["blksize"])
                if "windowsize" in opts:
                    self.windowsize = max(1, int(opts["windowsize"]))
                total = int(opts.get("tsize", "0") or 0)
                print(f"OACK blksize={self.blksize}"
                      + (f" windowsize={self.windowsize}"
                         if self.windowsize > 1 else "")
                      + (f" tsize={total}" if total else ""))
                op, pkt = self._exchange(_pack(ACK, 0))
            while True:
                if op != DATA:
                    raise RuntimeError(f"unexpected packet op={op}")
                block = struct.unpack(">H", pkt[2:4])[0]
                payload = pkt[4:]
                final = len(payload) < self.blksize
                if block == expected:
                    fh.write(payload)
                    wrote += len(payload)
                    expected = (expected + 1) & 0xFFFF
                    got += 1
                elif block < expected:
                    pass                            # duplicate: ignore
                else:
                    raise RuntimeError(f"unexpected block {block}, "
                                       f"wanted {expected}")
                if got >= self.windowsize or final:
                    self._send(_pack(ACK, (expected - 1) & 0xFFFF))
                    got = 0
                if final:
                    break
                try:
                    pkt = self._recv()
                except socket.timeout:
                    # cumulative ACK; the server resends the window
                    self._send(_pack(ACK, (expected - 1) & 0xFFFF))
                    got = 0
                    pkt = self._recv()
                op = struct.unpack(">H", pkt[:2])[0]
                if op == ERROR:
                    raise RuntimeError(_error(pkt))
        elapsed = time.time() - start
        rate = wrote / elapsed if elapsed else 0
        print(f"{wrote} bytes in {elapsed:.1f}s ({rate:.0f} B/s)")
        return wrote

    # ---- upload ----
    def put(self, local: str, remote: str) -> int:
        size = os.path.getsize(local)
        op, pkt = self._exchange(_req(WRQ, remote, self.blksize, size))
        if op == OACK:
            opts = _parse_opts(pkt)
            if "blksize" in opts:
                self.blksize = int(opts["blksize"])
            print(f"OACK blksize={self.blksize}")
            # WRQ: ACK 0 is not answered; the next move is ours (DATA 1)
            self._send(_pack(ACK, 0))
        elif op == ACK:
            if struct.unpack(">H", pkt[2:4])[0] != 0:
                raise RuntimeError("server did not ACK block 0")
        else:
            raise RuntimeError(f"unexpected packet op={op}")

        sent = 0
        block = 1
        start = time.time()
        with open(local, "rb") as fh:
            while True:
                chunk = fh.read(self.blksize)
                last = len(chunk) < self.blksize
                pkt = _pack(DATA, block) + chunk
                self._wait_ack(pkt, block)
                sent += len(chunk)
                if last:
                    break
                block = (block + 1) & 0xFFFF
        elapsed = time.time() - start
        rate = sent / elapsed if elapsed else 0
        print(f"{sent} bytes in {elapsed:.1f}s ({rate:.0f} B/s)")
        return sent


def main() -> int:
    ap = argparse.ArgumentParser(description="TFTP client for UMIX/86")
    ap.add_argument("action", choices=("get", "put"))
    ap.add_argument("remote", help="remote 8.3 name (extension optional for .SYS)")
    ap.add_argument("local", nargs="?", help="local file (default: remote name)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=6969,
                    help="relay port (mux_over_ip --tftp-listen)")
    ap.add_argument("-b", "--blksize", type=int, default=192,
                    help="block size, 8..192 (guest maximum)")
    ap.add_argument("-W", "--timeout", type=float, default=5.0)
    ap.add_argument("--retries", type=int, default=5)
    args = ap.parse_args()

    if not 8 <= args.blksize <= 192:
        ap.error("the guest supports blksize 8..192 (one 250-byte frame)")

    local = args.local or args.remote
    tf = Tftp(args.host, args.port, args.blksize, args.timeout, args.retries)
    try:
        if args.action == "get":
            print(f"get {args.remote} -> {local}")
            tf.get(args.remote, local)
        else:
            print(f"put {local} -> {args.remote}")
            tf.put(local, args.remote)
    except (TimeoutError, RuntimeError, OSError) as exc:
        print(f"FAILED: {exc}", file=sys.stderr)
        print("check: TFTP ON at the console, WRITE ON for put, relay running, "
              "MUX ON", file=sys.stderr)
        return 1
    finally:
        tf.close()
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
