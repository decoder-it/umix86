#!/usr/bin/env python3
"""Tests for the UMIX/86 serial multiplexer codec and bridge."""

from __future__ import annotations

import asyncio
import time
import unittest

from serial_mux import (
    ACK,
    BUSY,
    CLOSE,
    DATA,
    ERROR,
    ETX,
    OPEN,
    STX,
    Bridge,
    FakeGuestTransport,
    FrameDecoder,
    MAX_PAYLOAD,
    encode_frame,
    HTTP_NOTICE_BODY,
    input_line_feed,
    looks_like_http,
    telnet_filter,
)


class CodecTests(unittest.TestCase):
    def test_open_example(self) -> None:
        self.assertEqual(encode_frame(OPEN, 1), bytes.fromhex("02 02 01 00 03 03"))

    def test_ack_example(self) -> None:
        self.assertEqual(encode_frame(ACK, 1), bytes.fromhex("02 05 01 00 04 03"))

    def test_data_example(self) -> None:
        self.assertEqual(encode_frame(DATA, 1, b"Hi"), bytes.fromhex("02 01 01 02 48 69 23 03"))

    def test_decode_single_chunk(self) -> None:
        decoder = FrameDecoder()
        frame = encode_frame(DATA, 2, b"hello")
        self.assertEqual(decoder.feed(frame), [(DATA, 2, b"hello")])
        self.assertEqual(decoder.errors, 0)

    def test_decode_byte_by_byte(self) -> None:
        decoder = FrameDecoder()
        frame = encode_frame(DATA, 2, b"hello")
        out = []
        for byte in frame:
            out.extend(decoder.feed(bytes((byte,))))
        self.assertEqual(out, [(DATA, 2, b"hello")])

    def test_binary_payload_with_markers(self) -> None:
        payload = bytes(range(0, 120))
        decoder = FrameDecoder()
        out = decoder.feed(encode_frame(DATA, 1, payload))
        self.assertEqual(out, [(DATA, 1, payload)])

    def test_max_payload(self) -> None:
        payload = bytes((i & 0xFF) for i in range(MAX_PAYLOAD))
        decoder = FrameDecoder()
        self.assertEqual(decoder.feed(encode_frame(DATA, 1, payload)), [(DATA, 1, payload)])

    def test_corrupt_xor(self) -> None:
        decoder = FrameDecoder()
        bad = bytearray(encode_frame(DATA, 1, b"x"))
        bad[-2] ^= 0x55
        self.assertEqual(decoder.feed(bytes(bad)), [])
        self.assertEqual(decoder.errors, 1)
        self.assertEqual(decoder.feed(encode_frame(DATA, 1, b"y")), [(DATA, 1, b"y")])

    def test_length_too_large(self) -> None:
        decoder = FrameDecoder()
        bad = bytes((STX, DATA, 1, MAX_PAYLOAD + 1))
        self.assertEqual(decoder.feed(bad), [])
        self.assertEqual(decoder.errors, 1)
        self.assertEqual(decoder.feed(encode_frame(DATA, 1, b"ok")), [(DATA, 1, b"ok")])

    def test_garbage_then_frame(self) -> None:
        decoder = FrameDecoder()
        frames = decoder.feed(b"garbage" + encode_frame(DATA, 1, b"ok"))
        self.assertEqual(frames, [(DATA, 1, b"ok")])
        self.assertEqual(decoder.errors, 0)

    def test_bad_etx(self) -> None:
        decoder = FrameDecoder()
        bad = bytearray(encode_frame(DATA, 1, b"x"))
        bad[-1] = 0x00
        self.assertEqual(decoder.feed(bytes(bad)), [])
        self.assertEqual(decoder.errors, 1)

    def test_reset_unsticks_partial_frame(self) -> None:
        decoder = FrameDecoder()
        frame = encode_frame(DATA, 1, b"hello")
        decoder.feed(frame[:4])
        decoder.reset()
        self.assertEqual(decoder.feed(encode_frame(DATA, 1, b"again")), [(DATA, 1, b"again")])

    def test_control_frames_roundtrip(self) -> None:
        decoder = FrameDecoder()
        for ftype in (OPEN, CLOSE, BUSY, ACK):
            self.assertEqual(decoder.feed(encode_frame(ftype, 2)), [(ftype, 2, b"")])

    def test_error_payload(self) -> None:
        decoder = FrameDecoder()
        self.assertEqual(
            decoder.feed(encode_frame(ERROR, 1, b"\x02")),
            [(ERROR, 1, b"\x02")],
        )


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.transport = FakeGuestTransport()
        self.bridge = Bridge(
            self.transport,
            host="127.0.0.1",
            port=0,
            max_sessions=2,
            broadcast_system=False,
            reset_sessions=False,
        )
        await self.bridge.start()

    async def asyncTearDown(self) -> None:
        await self.bridge.stop()

    async def test_two_clients_are_isolated(self) -> None:
        r1, w1 = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        r2, w2 = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        await asyncio.sleep(0.1)

        w1.write(b"hello")
        await w1.drain()
        self.assertEqual(await asyncio.wait_for(r1.read(5), 1.0), b"hello")

        with self.assertRaises(asyncio.TimeoutError):
            await asyncio.wait_for(r2.read(1), 0.2)

        w2.write(b"world")
        await w2.drain()
        self.assertEqual(await asyncio.wait_for(r2.read(5), 1.0), b"world")

        with self.assertRaises(asyncio.TimeoutError):
            await asyncio.wait_for(r1.read(1), 0.2)

        w1.close()
        w2.close()
        await w1.wait_closed()
        await w2.wait_closed()

    async def test_third_client_is_rejected(self) -> None:
        r1, w1 = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        r2, w2 = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        r3, w3 = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        await asyncio.sleep(0.1)

        message = await asyncio.wait_for(r3.read(1024), 1.0)
        self.assertIn(b"all serial sessions are in use", message)

        w1.close()
        w2.close()
        w3.close()
        await w1.wait_closed()
        await w2.wait_closed()
        await w3.wait_closed()

    async def test_id_reuse_after_disconnect(self) -> None:
        r1, w1 = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        await asyncio.sleep(0.1)
        w1.write(b"a")
        await w1.drain()
        self.assertEqual(await asyncio.wait_for(r1.read(1), 1.0), b"a")
        w1.close()
        await w1.wait_closed()
        await asyncio.sleep(0.2)

        r2, w2 = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        await asyncio.sleep(0.1)
        w2.write(b"b")
        await w2.drain()
        self.assertEqual(await asyncio.wait_for(r2.read(1), 1.0), b"b")
        w2.close()
        await w2.wait_closed()

    async def test_large_payload_is_split(self) -> None:
        r1, w1 = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        await asyncio.sleep(0.1)
        payload = bytes((i % 251) for i in range(400))
        w1.write(payload)
        await w1.drain()
        received = await asyncio.wait_for(r1.readexactly(len(payload)), 8.0)
        self.assertEqual(received, payload)
        w1.close()
        await w1.wait_closed()


class HttpTests(unittest.TestCase):
    def test_request_line(self) -> None:
        self.assertTrue(looks_like_http(b"GET / HTTP/1.1\r\nHost: x\r\n"))

    def test_header_only(self) -> None:
        self.assertTrue(looks_like_http(b"Host: 1.2.3.4:80\r\n"))
        self.assertTrue(looks_like_http(b"User-Agent: Mozilla/5.0\r\n"))

    def test_not_http(self) -> None:
        self.assertFalse(looks_like_http(b"SYSTEM\r\n"))
        self.assertFalse(looks_like_http(b"GET\r\n"))
        self.assertFalse(looks_like_http(b"\xff\xfb\x01"))

    def test_notice_body(self) -> None:
        self.assertIn(b"interactive serial session", HTTP_NOTICE_BODY)


class InputLineTests(unittest.TestCase):
    def test_crlf_is_one_line(self) -> None:
        state: dict = {}
        self.assertEqual(input_line_feed(state, b"SYSTEM\r\nSYS1\r\n"),
                         [b"SYSTEM", b"SYS1"])

    def test_split_reads(self) -> None:
        state: dict = {}
        self.assertEqual(input_line_feed(state, b"ab"), [])
        self.assertEqual(input_line_feed(state, b"c\r"), [b"abc"])

    def test_lf_only(self) -> None:
        state: dict = {}
        self.assertEqual(input_line_feed(state, b"hello\n"), [b"hello"])

    def test_backspace_edits(self) -> None:
        state: dict = {}
        self.assertEqual(input_line_feed(state, b"ab\x08c\r"), [b"ac"])
        state2: dict = {}
        self.assertEqual(input_line_feed(state2, b"xy\x7fz\r"), [b"xz"])

    def test_buffer_capped(self) -> None:
        state: dict = {}
        lines = input_line_feed(state, b"a" * 300 + b"\r")
        self.assertEqual(len(lines[0]), 256)


class TelnetTests(unittest.TestCase):
    def test_strip_negotiation(self) -> None:
        state: dict = {}
        data = bytes([0xFF, 0xFB, 0x01, 0xFF, 0xFD, 0x03, 0xFF, 0xFD, 0x18]) + b"SYSTEM\r\n"
        out, resp = telnet_filter(data, state)
        self.assertEqual(out, b"SYSTEM\r\n")
        self.assertIn(bytes([0xFF, 0xFE, 0x01]), resp)   # DONT ECHO
        self.assertIn(bytes([0xFF, 0xFB, 0x03]), resp)   # WILL SGA
        self.assertIn(bytes([0xFF, 0xFC, 0x18]), resp)   # WONT TTYPE

    def test_escaped_iac(self) -> None:
        state: dict = {}
        out, _ = telnet_filter(bytes([0xFF, 0xFF, 0x41]), state)
        self.assertEqual(out, b"\xffA")

    def test_subnegotiation_dropped(self) -> None:
        state: dict = {}
        data = bytes([0xFF, 0xFA, 0x18, 0x00]) + b"XTERM" + bytes([0xFF, 0xF0]) + b"hi"
        out, _ = telnet_filter(data, state)
        self.assertEqual(out, b"hi")

    def test_split_sequence(self) -> None:
        state: dict = {}
        out1, _ = telnet_filter(bytes([0xFF, 0xFD]), state)
        out2, resp = telnet_filter(bytes([0x18]) + b"ok", state)
        self.assertEqual(out1 + out2, b"ok")
        self.assertEqual(resp, bytes([0xFF, 0xFC, 0x18]))


class TelnetBridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.transport = FakeGuestTransport()
        self.bridge = Bridge(
            self.transport,
            host="127.0.0.1", port=0, max_sessions=2,
            broadcast_system=False, reset_sessions=False, telnet=True,
        )
        await self.bridge.start()

    async def asyncTearDown(self) -> None:
        await self.bridge.stop()

    async def test_handshake_and_reply(self) -> None:
        r, w = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        w.write(bytes([0xFF, 0xFD, 0x18]))          # IAC DO TTYPE
        await w.drain()
        data = b""
        end = time.monotonic() + 1.0
        while time.monotonic() < end:
            try:
                data += await asyncio.wait_for(r.read(64), 0.1)
            except asyncio.TimeoutError:
                break
            if len(data) >= 9:
                break
        self.assertIn(bytes([0xFF, 0xFB, 0x01]), data)   # WILL ECHO
        self.assertIn(bytes([0xFF, 0xFB, 0x03]), data)   # WILL SGA
        self.assertIn(bytes([0xFF, 0xFC, 0x18]), data)   # WONT TTYPE
        w.close()
        await w.wait_closed()

    async def test_raw_client_gets_no_handshake(self) -> None:
        r, w = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        w.write(b"hello")
        await w.drain()
        data = await asyncio.wait_for(r.read(5), 1.0)
        self.assertEqual(data, b"hello")            # no IAC bytes prepended
        w.close()
        await w.wait_closed()


class MultiListenerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.transport = FakeGuestTransport()
        self.bridge = Bridge(
            self.transport,
            host="127.0.0.1", port=0, max_sessions=4,
            broadcast_system=False, reset_sessions=False,
            extra_listens=[("127.0.0.1", 0)],
            fixed_listens=[("127.0.0.1", 0, 3)],
        )
        await self.bridge.start()

    async def asyncTearDown(self) -> None:
        await self.bridge.stop()

    async def test_two_pooled_ports_are_isolated(self) -> None:
        p1, p2 = self.bridge.ports[0], self.bridge.ports[1]
        r1, w1 = await asyncio.open_connection("127.0.0.1", p1)
        r2, w2 = await asyncio.open_connection("127.0.0.1", p2)
        await asyncio.sleep(0.1)
        w1.write(b"one"); await w1.drain()
        w2.write(b"two"); await w2.drain()
        self.assertEqual(await asyncio.wait_for(r1.read(3), 1.0), b"one")
        self.assertEqual(await asyncio.wait_for(r2.read(3), 1.0), b"two")
        with self.assertRaises(asyncio.TimeoutError):
            await asyncio.wait_for(r1.read(1), 0.2)
        w1.close(); w2.close()
        await w1.wait_closed(); await w2.wait_closed()

    async def test_http_request_gets_notice(self) -> None:
        r, w = await asyncio.open_connection("127.0.0.1", self.bridge.port)
        w.write(b"GET / HTTP/1.1\r\nHost: 128.116.205.253:80\r\nUser-Agent: Mozilla/5.0\r\n\r\n")
        await w.drain()
        data = await asyncio.wait_for(r.read(4096), 1.0)
        self.assertIn(b"HTTP/1.1 200 OK", data)
        self.assertIn(b"interactive serial session", data)
        await asyncio.sleep(0.1)
        self.assertTrue(self.transport.queue.empty())   # no OPEN -> no guest session
        w.close()
        await w.wait_closed()

    async def test_debug_logs_input_line(self) -> None:
        with self.assertLogs(level="DEBUG") as cm:
            r, w = await asyncio.open_connection("127.0.0.1", self.bridge.port)
            await asyncio.sleep(0.1)
            w.write(b"hello\r\n")
            await w.drain()
            await asyncio.sleep(0.2)
            w.close()
            await w.wait_closed()
        hits = [m for m in cm.output if "input:" in m]
        self.assertEqual(len(hits), 1, hits)
        self.assertIn("b'hello'", hits[0])

    async def test_fixed_tid_port(self) -> None:
        p = self.bridge.ports[2]
        r, w = await asyncio.open_connection("127.0.0.1", p)
        await asyncio.sleep(0.1)
        w.write(b"fix"); await w.drain()
        self.assertEqual(await asyncio.wait_for(r.read(3), 1.0), b"fix")
        r2, w2 = await asyncio.open_connection("127.0.0.1", p)
        await asyncio.sleep(0.2)
        msg = await asyncio.wait_for(r2.read(100), 1.0)
        self.assertIn(b"in use", msg)
        w.close(); w2.close()
        await w.wait_closed(); await w2.wait_closed()


if __name__ == "__main__":
    unittest.main()
