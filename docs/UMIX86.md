# UMIX/86 — user guide

Mostly coded by **DeepSeek-V4.1-Flash**.

UMIX/86 is a small 16-bit, real-mode, multi-tasking operating system for
8086/8088 **PC/XT-class** machines. It boots from a 360 KB floppy, runs in
640 KB, and gives you:

- a text console and a command shell
- a full-screen editor (CGA/Hercules) and a BASIC interpreter
- a job-control language and loadable programs
- up to ten serial terminals over one serial link (**MUX**)
- a web server, a JSON API, a TFTP server and a chat room

Everything runs on the guest. A small program on a modern PC bridges the serial
link to ordinary TCP ports for terminals and the web.

Current build: **V0R138** (API version 13).

## 1. What you need

- An 8086/8088 PC/XT-class machine with 640 KB. A **Commodore PC-III** is a
  good example: 8088, CGA/Hercules, 360 KB 5.25" drive.
- CGA, MDA or Hercules text output (auto-detected).
- A 360 KB 5.25" floppy drive, or a Gotek/USB floppy emulator.
- Optional: a hard disk, CF card or IDE image for the C: volume.
- For serial terminals and the web: a null-modem cable and a PC running
  Python 3, or QEMU.

## 2. Making the disks

### Boot floppy

Write `build/umix86-360.img` to a 360 KB 5.25" floppy:

- DOS: `rawrite` or `FDIMAGE`
- Linux: `dd if=build/umix86-360.img of=/dev/fd0 bs=512`
- Gotek: copy the `.img` to the USB stick and select it

The floppy holds the boot sector and the 64 KB kernel. Nothing else is needed
on A:.

### C: volume

The kernel mounts a FAT12/FAT16 volume as C: and loads its programs from the
root. Use a DOS-formatted hard disk or CF card, or write `build/testc.img` to a
CF/IDE image. Copy these **8.3** files into the root:

    UMIX.SYS  API.SYS  STARTUP.JCL  README.TXT
    INDEX.HTM  UMX002.HTM .. UMX007.HTM  EXPLORER.HTM  CHAT.HTM
    APIHELLO.BAS  ECHO.BAS  HELLO1.SYS  HELLO2.SYS  SPIN.SYS  JOB.JCL

`TCP.SYS` and `CHAT.SYS` are optional (see the MUX section). `tools/mkfat.py`
builds a ready C: image for QEMU or a CF card:

```sh
UMIX_MUX=1 python3 tools/mkfat.py      # -> build/testc.img (21 MB)
```

### STARTUP.JCL

At boot the kernel runs `C:\STARTUP.JCL`, one command per line. Lines starting
with `;`, `#` or `//` are comments. A typical file:

```
MUX ON
;WRITE ON
;TFTP ON
;CHAT OFF
API ROUTE /api/demo APIHELLO.BAS
API ROUTE /api/echo ECHO.BAS
```

- `MUX ON` is needed for serial terminals and the web.
- `WRITE ON` allows writing to C:.
- `TFTP ON` starts the TFTP server.
- `CHAT OFF` disables the chat.

## 3. First boot

1. Put the boot floppy in A: and select A: as the boot device.
2. Power on. The kernel prints its banner, mounts C:, loads `UMIX.SYS` and
   `API.SYS`, and runs `STARTUP.JCL`.
3. The CGA/MDA/Hercules console shows the prompt.

Without a C: volume the kernel still comes up with its built-in shell
(`HELP ECHO CLS MEM TIME VER SYS REBOOT HALT`), but the C: commands, editor,
BASIC, API, web and chat are not available.

The console has no login. Serial sessions ask for `USERID:` and `PASSWORD:`.
Default accounts:

    USER   / USER      ordinary user
    SYSTEM / SYS1      privileged user

Change them after the first boot (`USER`, `USERS`).

## 4. Using the system

### Drives

    A:  the boot floppy
    C:  the hard disk / CF (FAT12/16, 8.3 names)
    M:  a RAM disk (lost on reboot)

Names are 8.3 and case-insensitive; a file is at most 64 KB. `WRITE ON` is
required before anything writes to C:.

### Main shell commands

Files:

    DIR  TYPE  COPY  DEL  REN  EDIT  DRIVE  WRITE

Programs:

    RUN file.SYS   BASIC   JCL file.JCL   SYS

Sessions and users:

    USER  USERS  WHO  PS  PRIV

System and link:

    HELP  CLS  MEM  TIME  VER  SPEED  BAUD  QUANTUM
    WEB  WEBLOG  TFTP  TFTPLOG  CHAT  API  PANEL
    REBOOT  HALT  BYE

`HELP` prints the full list. A few commands are console-only, or need
`SYSTEM` with `PRIV ON`: `WEB`, `WEBLOG`, `TFTP`, `TFTPLOG`, `CHAT`,
`QUANTUM`, `BAUD`, `WRITE`, `DRIVE`, `PRIV`, and user administration.
`PRIV ON` itself is set from the console.

### Panel and editor

`PANEL ON` / `PANEL OFF` toggles the mainframe-style full-screen panel on the
console you are typing on: the CGA/Hercules layout, or the ANSI panel on a
serial terminal. `PANEL` alone reports the current state.

On the CGA/Hercules console, `EDIT FILE` opens a **full-screen editor** (a
100 x 80 buffer). Arrows/Home/End/PgUp/PgDn move, Ins toggles insert,
Del/Backspace edit, Enter moves down, Tab inserts four spaces, Ctrl-N inserts
a line, Ctrl-Y deletes a line, F1 saves, F2/Esc quits. Saving needs
`WRITE ON`.

A serial session gets the ANSI panel and the chat display, but `EDIT` there
answers `EDIT: CGA CONSOLE ONLY`; the full-screen editor is a CGA/Hercules
feature. On the CGA/Hercules console `PANEL ON` restores the mainframe panel
after `PANEL OFF` or `CLS`.

### BASIC

`BASIC` starts a line-numbered, GWBASIC-style interpreter: `FOR/NEXT`,
`IF/THEN/ELSE`, `GOTO`, `GOSUB`, `INPUT`, `PRINT`, `DIM`, integer arithmetic,
strings, and `LOAD`/`SAVE` of `.BAS` files. Limits: 61-character lines,
16-bit integers, 63-character strings.

### JCL and programs

`JCL FILE.JCL` runs a command script. `RUN FILE.SYS` loads a program into a
free program slot and runs it. `SYS` reloads the shell overlay after changing
`UMIX.SYS`.

### More than one terminal

The console is one terminal. To have several at once, or to reach the web
server, use the MUX link and the host bridge.

## 5. MUX and the protocol

### What MUX is

One serial port normally carries one terminal. **MUX** multiplexes the link: up
to ten independent terminal sessions, plus web requests, uploads and TFTP,
share the same serial cable.

The guest speaks a small framed protocol. On the PC side a program called the
**bridge** (`tools/serial_mux.py`) speaks that protocol on the serial port and
offers ordinary TCP services:

    127.0.0.1:2323   terminal sessions
    127.0.0.1:8080   the guest's web server
    127.0.0.1:8081   file upload (optional)
    127.0.0.1:6969   TFTP relay (optional, with --ip)

You do not talk to the guest's serial port directly; you connect a terminal or
a browser to the bridge.

### The protocol at a glance

The serial link carries frames, not raw text. Each frame has:

- a **type**: `OPEN` (start a session), `DATA` (terminal bytes), `CLOSE`
  (session ended), `ACK`, `BUSY`, `ERROR`
- a **terminal id**: `1..10` for serial sessions, `0` for the guest console
  log, `0xFE` for the IP/TFTP channel
- a **payload**, delimited by the frame length and protected by a checksum

`OPEN` also carries the **application id**: `1` console/shell, `2` web,
`3` upload.

That is the whole contract. The bridge implements it; you never type frames by
hand. If you write your own bridge, match these frame types and ids.

### Connecting a real PC

1. Connect the PC's serial port to a modern PC with a null-modem cable at
   9600 8N1.
2. On the modern PC:

```sh
python3 tools/serial_mux.py --serial /dev/ttyUSB0 --baud 9600 \
    --listen 127.0.0.1:2323 --http-listen 127.0.0.1:8080
```

3. `telnet 127.0.0.1 2323` for a terminal, and
   <http://127.0.0.1:8080/> for the web.

Add `--ip --tftp-listen 127.0.0.1:6969` for TFTP, and
`--upload-listen 127.0.0.1:8081` for uploads.

### MUX or TCP, not both

`TCP.SYS` is the alternative to MUX: it turns the same serial link into a SLIP
link with a TCP/IP stack and its own HTTP server. Load one or the other. MUX is
what you want for terminals, the guest web server, the API and chat.

## 6. Quick test under QEMU

```sh
./build.sh
UMIX_MUX=1 python3 tools/mkfat.py

qemu-system-i386 -machine isapc -m 1M \
  -drive file=build/umix86-360.img,format=raw,if=floppy \
  -drive file=build/testc.img,format=raw,if=none,id=d0 \
  -device ide-hd,drive=d0,cyls=615,heads=4,secs=17 -boot a -display none \
  -serial unix:/tmp/umix.sock,server=on,wait=off &

python3 tools/serial_mux.py --serial unix:/tmp/umix.sock \
    --listen 127.0.0.1:2323 --http-listen 127.0.0.1:8080
```

Open <http://127.0.0.1:8080/>. `run.sh` boots the floppy on stdio instead.

## 7. Services

- **Web server**: on by default while MUX is on. `/` is `INDEX.HTM`; any other
  `/NAME.EXT` is served from the C: root if it exists. Pages must be under
  4 KB.
- **JSON API**: `API.SYS`; endpoints under `/api` (system, tasks, memory, who,
  ps, users, speed, time, version, status, apps, jobs, routes, chat). A browser
  explorer is at `/EXPLORER.HTM`.
- **TFTP**: UDP 69, GET and PUT; `TFTP ON` required, and PUT also needs
  `WRITE ON`. Use a client that negotiates a block size of at most 192
  (`tools/umix_tftp.py`, `atftp`); Windows `tftp.exe` and `curl` cannot.
- **Chat**: type `CHAT` at `USERID:`, or open `/CHAT.HTM`. Browser and terminal
  users share one room. `CHAT OFF` disables both.
- **System guide**: `/`, `/UMX002.HTM` .. `/UMX007.HTM`, `/EXPLORER.HTM`.

## 8. Notes and troubleshooting

- Default serial speed is 9600. Change it with `BAUD` (console) and restart
  the bridge with the same `--baud`.
- `WRITE ON` before writing to C:.
- The web server sends at most 4000 bytes per file; larger files are not
  served.
- TFTP needs `blksize <= 192`; `tools/umix_tftp.py` does this for you.
- If the web or chat answers 503, check `MUX ON`, `CHAT ON`, and that SLIP/TCP
  is off.
- The web server, API and chat have no authentication. Keep the bridge on a
  trusted network.
- On a Commodore PC-III use a 360 KB image; do not write a 1.44 MB image to a
  360 KB drive.
- Keep `UMIX.SYS` from the same build as the boot floppy.
