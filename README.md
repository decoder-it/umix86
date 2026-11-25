# UMIX/86

Mostly coded by **DeepSeek-V4.1-Flash**.

A small 16-bit, real-mode, preemptive multitasking operating system for the
**8086/8088 PC/XT class**, written in 8086 assembly. It boots from a 360 KB
floppy, runs in 640 KB, and provides a shell, a BASIC interpreter, a JSON API,
a static web server, TFTP, a shared chat room, and framed serial terminals over
a host-side multiplexer bridge.

Current build: **V0R138** (API version 13).

## What's inside

| path | contents |
|---|---|
| `src/` | boot sector, kernel, `UMIX.SYS`, `TCP.SYS`, `API.SYS`, demo programs |
| `tools/` | image builders, the `serial_mux.py` bridge, TFTP/upload clients, the browser API explorer, the bridge tests |
| `INDEX.HTM`, `UMX002.HTM`..`UMX007.HTM` | the in-guest system guide (overview, OS, MUX/TCP, services/BASIC, terminals, API, chat) |
| `chat_local.htm`, `chat_umix.htm` | browser chat clients |
| `docs/` | user manual, API reference, chat notes, Windows/real-hardware guide |

## Requirements

- `nasm` (flat-binary 8086)
- Python 3.8+ (standard library only)
- QEMU (or a 360 KB floppy / Gotek for real hardware)

## Build

```sh
./build.sh
```

Writes `build/umix86-360.img` (360 KB boot floppy), `build/umix86.img`
(512-byte boot + 64 KB kernel area), `build/umix.sys`, `build/tcp.sys`,
`build/api.sys`.

Build the C: disk image, then start the guest and the host bridge:

```sh
UMIX_MUX=1 python3 tools/mkfat.py

qemu-system-i386 -machine isapc -m 1M \
  -drive file=build/umix86-360.img,format=raw,if=floppy \
  -drive file=build/testc.img,format=raw,if=none,id=d0 \
  -device ide-hd,drive=d0,cyls=615,heads=4,secs=17 -boot a -display none \
  -serial unix:/tmp/umix-ser.sock,server=on,wait=off &

python3 tools/serial_mux.py --serial unix:/tmp/umix-ser.sock \
  --listen 127.0.0.1:2323 --http-listen 127.0.0.1:8080
```

Then:

- terminal: `telnet 127.0.0.1 2323` (login `USER` / `USER`, or `SYSTEM` / `SYS1`)
- system guide: <http://127.0.0.1:8080/>
- API explorer: <http://127.0.0.1:8080/EXPLORER.HTM>
- chat: <http://127.0.0.1:8080/CHAT.HTM>

`run.sh` boots the floppy headless on stdio for a quick console test.

## Build switches (`tools/mkfat.py`)

| variable | effect |
|---|---|
| `UMIX_MUX=1` | MUX ON (needed for terminals, web and chat over the bridge) |
| `UMIX_TCP=1` | SLIP + TCP ON (`TCP.SYS` HTTP instead of MUX) |
| `UMIX_TFTP=1` | `WRITE ON` + `TFTP ON` in `STARTUP.JCL` |
| `UMIX_CHAT=0` | `CHAT OFF` at boot (disables terminal and HTTP chat) |
| `UMIX_INDEX=FILE` | use another file as `INDEX.HTM` |

## Tests

```sh
cd tools && python3 -m unittest test_serial_mux
```

## Notes

- MUX and `TCP.SYS` are mutually exclusive: both use the `0x2900` window and
  the same serial link.
- The web server, JSON API and chat are unauthenticated — keep the bridge on a
  trusted network.
- Static pages served by the guest must stay under 4 KB.
- TFTP needs a client that negotiates a block size ≤ 192 (`tools/umix_tftp.py`,
  `atftp`); the Windows `tftp.exe` and `curl` cannot.

## Documentation

- [User manual](docs/UMIX86.md)
- [API reference](docs/API_ENDPOINTS.txt)
- [Chat API walkthrough](docs/CHAT_API_WEB.txt)
- [Windows / real hardware](docs/LAB3_WINDOWS.txt)
