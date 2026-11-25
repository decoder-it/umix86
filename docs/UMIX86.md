# UMIX/86 — minimal 8088 / 360 KB edition

This is a **separate project** from the 64-bit umix in `../umix`. It does not
share code, build files or binaries with it.

A bootable 8086/8088 real-mode kernel for a 360 KB 5.25" floppy that boots
from A: and loads its command extensions from **C:\UMIX.SYS** (a DOS FAT12/16
volume) as an overlay.

- 80×25 text console on CGA (B800) or MDA/Hercules (B000), auto-detected
- BIOS keyboard (`INT 16h`) with serial input polling
- kernel shell: `HELP`, `ECHO`, `CLS`, `MEM`, `TIME`, `VER`, `SYS`, `REBOOT`, `HALT`
- **C: FAT12/FAT16 reader/writer** (MBR partition or superfloppy, geometry from the BPB)
- `SAVE` and `DELETE` write to C: (FAT allocation, both FAT copies, directory
  entries) - **disabled by default**, enabled **from the CGA console only**
  with `WRITE ON`
- **UMIX.SYS overlay** loaded from C: and far-called at `2000:0000`
- overlay commands: `DIR` (root directory), `TYPE <file>`, `JCL <job>` and `BASIC`
- **RAM disk** (`DRIVE M`): a 64 KB FAT12 volume in memory - no media writes
- **UMIX BASIC** (in `UMIX.SYS`): line-numbered programs, PRINT/LET/
  IF..ELSE/GOTO/GOSUB/FOR..NEXT/INPUT, integer expressions, strings and DIM
  arrays, LOAD/SAVE .BAS from A:/B:/C:/M:
- **web server over the multiplexer**: the bridge's `--http-listen` serves
  files from the guest's C: root — `INDEX.HTM` at `/`, and any 8.3 file by
  name (`/README.TXT`), static text/html, 4 KB max; the shipped INDEX.HTM is
  the system guide, and the API explorer lives at `/EXPLORER.HTM` (see below)
- **TFTP server in the guest**: UDP 69 with a negotiated 8..192-byte block
  size and RFC 7440 `windowsize` 1..4 (`TFTP ON|OFF`, console-only, default
  OFF); GET streams any file, PUT streams up to the 64 KB FAT limit;
  `TFTPLOG ON` logs requests and progress
- **serial console logon**: the COM1 shell asks USERID/PASSWORD (type `CHAT` at
  USERID to enter the shared chat room); the CGA shell does not
- **3270/ISPF-style CGA panel**: title bar (system name, date YY.DDD, time), rule,
  scrolling output area, `COMMAND ===>` field and an OIA line
- **console-managed user accounts**: logon table edited from the CGA console
  (`USERS`, `USER ADD|DEL|PASS|SAVE|RESET`), persisted in a reserved sector on
  the boot floppy (LBA 700) and mirrored to `USERS.DAT` on C:
- **SYSTEM user privileges**: `PRIV ON|OFF` on the console (default **OFF**)
  grants the serial **SYSTEM** user the console commands (`WRITE`, `QUANTUM`,
  `USER`, `USERS`, `CHAT ON|OFF`, `/BAN`); the console always has them and other
  serial users never do. `MUX` stays console-only.
- **output pager**: `MORE ON|OFF|LINES` pages all output (HELP, DIR, TYPE, …)
  after N lines; ENTER continues, any other key turns paging off. The wait is
  CRLF-safe (a terminal's CR+LF acts as one ENTER, not an automatic continue)
  and live chat output is never paged.
- **preemptive + cooperative multitasking**: `RUN FILE.SYS [!]` loads a task
  from C:; the PIT tick (INT 08h, 18.2 Hz) switches tasks round-robin, and
  tasks can also yield explicitly (INT 60h AH=7). `PREEMPT ON|OFF` toggles
  preemption (default ON).
- **two independent shells**: slot 0 on the CGA console + keyboard, slot 1 on
  COM1 (9600 8N1 default; `BAUD` changes it); each has its own input, output
  and line buffer
- 8086 instructions only (`cpu 8086` in NASM)

This is the complete UMIX/86 manual: Parts II–IV were merged from the
former `docs/SERIAL_MUX.md`, `docs/C_PROGRAMS.txt` and `8088monitor.txt`
(the standalone copies are kept in `docs/archive/`).

## HTTP API

`/api*` is served by the **API.SYS overlay** (17,452 bytes, loaded at `0x9000`);
the kernel only recognises the `/api` prefix and far-calls it with the path and
the request method in `DS:SI` / `AL`.  The Python gateway stays a byte relay.
Endpoints (V0R138):

```
/api            catalogue          /api/users    user accounts (names only)
/api/system     os/cpu/tasks/uptime /api/speed    baud, tick_hz, CPU line
/api/tasks      task count         /api/time     hh/mm/ss (BCD -> decimal)
/api/memory     RAM                /api/version  os/kernel/api
/api/who        logged-in sessions /api/status   feature bits + SLIP counters
/api/whoami     user of this session /api/chat   chat nicks + API sessions
                                   /api/chat/join, /api/chat/send,
                                   /api/chat/messages (JSON chat API)
/api/ps         task table         /api/apps     job applications
```

Anything else under `/api` answers `404 not found`.  Every response carries
`X-API-Version: 13` and an exact `Content-Length`.

The overlay builds the body in `bodybuf` and emits LF only.  `finish:` counts
the LFs, adds one byte per LF (the kernel turns each into CR+LF) and sends the
headers and body through `INT 60h AH=31` (paced send: DS:SI buffer, CX length),
which flushes the per-session 64-byte TX ring instead of dropping bytes when it
fills.  Example (`/api/system`):

```
HTTP/1.0 200 OK
Content-Type: application/json
X-API-Version: 13
Content-Length: 85
Connection: close

{"os":"UMIX","version":"0.3","cpu":"Intel 8088","ram_kb":640,"tasks":2,"uptime":24}
```

`tasks` counts `task_state == 1`, `uptime` is `ticks/18`.

### POST and request bodies

`web_path_byte` records the first byte of the request line (`G`/`P`/`D`) in
`web_method`; `web_serve` passes it in `AL` on the far call (`0xFF` still means
the init call).  The overlay reads the JSON body itself with `INT 60h AH=32`
(non-blocking byte, `CF=1` if none): it yields (`AH=7`) until it has a balanced
`{...}` object, gives up after 120 ticks, and caps the body at 767 bytes
(`413` beyond that).  This avoids a `Content-Length` parser and body buffer in
the kernel, which has only 160 bytes free.

The overlay serialises request handling with a one-byte test-and-set lock
(`xchg`), because its buffers and the job table are global and a handler can
yield while waiting for a body.

### Job queue (model A)

`POST /api/jobs` queues a compute job; the kernel's idle hook
(`mux_poll` -> `call far [job_vec]`) runs `job_pump` in slices, so jobs progress
between requests without a dedicated task.  `API.SYS` advertises the pump entry
at load time (magic `BJ` in `DX`, offset in `BX`); an old overlay leaves
`job_ok=0` and the hook is skipped.

```
POST   /api/jobs             {"app":"prime","params":{"limit":1000}}
                             -> 202 {"job_id":1,"status":"queued"}
GET    /api/jobs             -> {"jobs":[{"job_id":1,"app":"prime","status":"running"},...]}
GET    /api/jobs/{id}        -> adds "result" when completed and
                                "execution_ticks" once started
GET    /api/jobs/{id}/result -> 200 {"job_id":1,"result":{"prime_count":168}}
                                409 while queued/running/cancelled
DELETE /api/jobs/{id}        -> 200 {"job_id":1,"status":"cancel_requested"}
                                409 if already finished
GET    /api/apps             -> {"applications":[{"id":"prime",...},...]}
```

* **States**: unused, queued, running, completed, cancelled, failed,
  cancel-requested.  One job runs at a time (single-CPU, single pump); the rest
  wait in id order.
* **Apps**: `prime` counts primes <= `limit` (default 1000, 2..5000).
  `sort` has two modes: with `values` (an array of up to 12 strings, 15
  characters each) it sorts the caller's strings bytewise and returns
  `{"count":N,"values":[...]}`; without it, it keeps the numeric benchmark
  of `limit` LCG words from `seed` (default 32, 2..32) and reports
  `count` + `checksum`.  `crc16` accepts `data` (up to 255 bytes) or
  `values` (concatenated) and returns CRC-16/CCITT-FALSE of those bytes;
  without them it checksums `limit` generated bytes (default 256, 1..1024).
  Results are deterministic; `prime` with 1000 gives `prime_count: 168`,
  `{"app":"sort","params":{"values":["apple","pie","banana"]}}` gives
  `["apple","banana","pie"]`, and `{"app":"crc16","params":{"data":"hello"}}`
  gives `crc: 53870`.
* **Retention**: 8 entries (`JOB_MAX`).  Ids are monotonic and never reused;
  when full, the oldest completed/cancelled entry is recycled, else `503`.
* **execution_ticks** is `end_ticks - start_ticks` at 18.2 Hz, with a minimum of
  1 for a completed job.  It is omitted for jobs that never started.
* **Cancellation**: a queued job moves straight to cancelled; a running job
  gets cancel-requested and its next pump slice marks it cancelled.
* Jobs live in RAM only and are lost on reboot.  This is a job *queue*, not
  persistent storage.

### Response-corruption fix (V0R123)

`bodybuf` was 128 bytes while the `/api` catalogue alone is 174, so `b_str`
wrote past the buffer into `b_nl` and `hdr_pre`.  The client then saw a
rotated/truncated response whose first frame was the *tail* of the JSON body
(`curl` reported HTTP/0.9).  The body buffer is now 768 bytes and
`Content-Length` is derived by scanning the body for LFs.  V0R123 also gave
`/api/status` its missing opening `{` and fixed `/api/speed`'s register stack.

### BASIC-served routes (V0R138)

A route maps a URL path to a `.BAS` program on C:.  `API ROUTE /api/demo
APIHELLO.BAS` registers it; `API ROUTES` lists, `API DEL /api/demo` removes.
The image ships `APIHELLO.BAS` and a demo `API ROUTE` line in `STARTUP.JCL`
(which runs after UMIX.SYS loads, so routes survive reboot).

The API overlay asks UMIX.SYS through **INT 62h** (DS:SI path, ES:DI output,
CX max; AX=bytes or CF+AL error).  SYS splits the query, matches the 4-entry
RAM route table, takes the overlay lock non-blocking (an interactive `BASIC`
session causes 503), loads the file with the interpreter's LOAD path, and
runs it with output capture.  `P$` is the path and `Q$` the query string;
both are set in the interpreter's string-slot format (length byte + chars)
after `bas_run` clears the variables.

Capture hooks `putc` (strings), `puts` (messages) and `put_dec` (numeric
PRINT, which bypasses putc), drops CR, and the API adds CR before LF so
`Content-Length` is exact.  A tick deadline (~90 ticks, ~5 s) and the
767-byte body cap turn a runaway program into 500; the guest stays
responsive.  Missing files also return 500.  The route table is RAM only;
re-add the `API ROUTE` lines (or reboot, which runs `STARTUP.JCL`).

Limits: 4 routes; path <= 19 chars starting `/api/`; file <= 15 chars
(8.3, `.BAS` default); GET only; queries work on routes, but built-in JSON
endpoints (`/api/system`, `/api/jobs`, ...) return 404 if a query is
appended.  `/api/hello` remains a built-in UMIX.SYS demo route.

V0R131 made the API subcommands case-insensitive and tolerant of trailing
spaces (`api routes`, `API ROUTES `, `api route ...`).  Before that a
trailing space on `API ROUTES` fell through to the `API ON` path and printed
"API UPDATED".  V0R132 adds method-aware routes: GET, POST and DELETE reach
the same route program, with `M$` = method and `B$` = the first 63 chars of
the POST body (read until the JSON closes or ~30 ticks, 767-byte cap).
`GET /api/routes` returns `{"routes":[...]}`, and `GET /api` now lists the
static endpoints plus every registered route path.  Remember the route table
is RAM: a reboot/guest reset/`SYS` clears it; `STARTUP.JCL` or re-running
`API ROUTE` brings it back.  `API ON` reloads API.SYS only and does not clear
routes.

A BASIC line lives in a 64-byte slot, so a program line may be at most 61
characters; longer lines are truncated (a trailing comma/END can silently
disappear).  Keep JSON PRINTs short and split them across lines.  The image
ships `APIHELLO.BAS` and `ECHO.BAS` with `/api/demo` and `/api/echo`
registered in `STARTUP.JCL`; `API_ENDPOINTS.txt` has the full POST walkthrough
(handler, registration, curl and PowerShell).

Two bugs fixed along the way: `bas_get_name` truncated names at 11 chars
(`APIHELLO.BAS` is 12), and `fname` was 12 bytes; both are 15/16 now.  A
12-byte FAT 8.3 name in `mkfat.py` also corrupted the image (fixed to
`APIHELLOBAS`).

### API recovery (V0R127)

The shell command `API OFF` clears `api_ok`/`job_ok` and makes the kernel
answer `/api` with 404 without entering the overlay.  `API ON` (or
`API RELOAD`) re-reads `C:\API.SYS` into `0x9000`, re-runs its init call and
re-registers the job pump.  Reloading resets the job table and the request
lock; run it when no request is in flight.  It is reachable only while the
kernel/shell is alive — a hard freeze still needs a reboot (and a bridge
restart, because the mux sessions are stale after a guest reset).

UMIX.SYS now installs INT 0 (divide error) and INT 6 (invalid opcode)
handlers that print `PANIC: ... - REBOOT` and halt, so a fault is visible
instead of a silent reset.  The kernel has only 4 bytes free; the API
control handler and both fixes are overlay/SYS work plus a small kernel
stub.

### /api/users returns names only (V0R124, hardened in V0R126)

A user record is `name[10] + password[10]`, and the password sits at +10.
`AH=27` used to return a pointer into the record, so any reader that ran past
the name reached the password.  V0R126 makes `AH=27` return a **standalone
copy**: `user_name_copy` copies at most 8 bytes (the account-name limit) into
`uname_safe` and NUL-terminates it, and the console `USERS` command uses the
same copy.  `users_apply` also zeroes the unused tail of the table and forces
`name[8..9]=0` on loaded files, so a short/hostile `USERS.DAT` cannot expose
stale built-in names or a non-terminated name.  The API additionally stops at
the first missing record.  `b_name` keeps an explicit maximum (`CX`): 8 for
user names, 12 for task names, 10 for chat nicks, 16 for session names, 39 for
the CPU line.

Verified with a crafted floppy user table `SYSTEM/SYS1 + ABCDEFGHIJ/SECRET`:
`/api/users` returns exactly `["SYSTEM","ABCDEFGH"]`; `SYS1` and `SECRET` are
never emitted.  The built-in table still returns its three names.

## Archive

`build.sh` copies the previous artifacts to `archive/<timestamp>/` before it
overwrites them — kernel, both boot images, `UMIX.SYS`, `TCP.SYS`, `CHAT.SYS`,
`API.SYS`, `versions.txt` — together with a `MANIFEST.sha256`.  The per-release image
copies `umix_version_86_V0R<n>.img` / `_360.img` live in
`archive/versions/` (with their own `MANIFEST.sha256`), and `build/` only
holds the current artifacts.  To roll back, copy the
files out of the timestamp directory.  Named snapshots (e.g.
`archive/v0r113-20261120-115337/`) are kept for releases worth remembering.

## Contents

- [The overlay model](#the-overlay-model)
- [Preemptive and cooperative multitasking](#preemptive-and-cooperative-multitasking)
- [RAM disk](#ram-disk)
- [Video: CGA or Hercules/MDA](#video-cga-or-herculesmda)
- [CGA panel (mainframe style)](#cga-panel-mainframe-style)
- [Serial multiplexing (phase 3)](#serial-multiplexing-phase-3)
- [Terminals over IP (guest-side TCP/IP)](#terminals-over-ip-guest-side-tcpip)
- [Chat room over the multiplexer](#chat-room-over-the-multiplexer)
- [Web server over the multiplexer](#web-server-over-the-multiplexer)
- [Baud rate](#baud-rate)
- [UMIX BASIC](#umix-basic)
- [Volumes and floppies](#volumes-and-floppies)
- [Build](#build)
- [Deploy](#deploy)
- [QEMU test with a C: image](#qemu-test-with-a-c-image)
- [Commands](#commands)
- [Full-screen editor](#full-screen-editor)
- [JCL](#jcl)
- [Layout](#layout)
- [Limits](#limits)
- [Next steps](#next-steps)
- [Part II — Serial multiplexer design](#part-ii--serial-multiplexer-design)
  - [1. Decisions](#1-decisions)
  - [2. Topology](#2-topology)
  - [3. Wire protocol](#3-wire-protocol)
  - [4. Guest session model](#4-guest-session-model)
  - [5. Guest receive path](#5-guest-receive-path)
  - [6. Guest transmit path](#6-guest-transmit-path)
  - [7. Python bridge](#7-python-bridge)
  - [8. Error handling](#8-error-handling)
  - [9. Testing plan](#9-testing-plan)
  - [10. Risks and limitations](#10-risks-and-limitations)
  - [11. Phased implementation](#11-phased-implementation)
  - [12. Acceptance criteria (MVP)](#12-acceptance-criteria-mvp)
  - [13. Resolved decisions](#13-resolved-decisions)
  - [14. Web application (app id 2)](#14-web-application-app-id-2)
- [Part III — Writing C programs for UMIX/86](#part-iii--writing-c-programs-for-umix86)
  - [1. RUNTIME CONTRACT (what RUN gives your program)](#1-runtime-contract-what-run-gives-your-program)
  - [2. TOOLCHAIN OPTIONS](#2-toolchain-options)
  - [3. EXAMPLE](#3-example)
  - [3b. READING A LINE](#3b-reading-a-line)
  - [4. LIMITS AND GOTCHAS](#4-limits-and-gotchas)
  - [5. TROUBLESHOOTING](#5-troubleshooting)
  - [6. REFERENCE: ASSEMBLY PROGRAMS](#6-reference-assembly-programs)
- [Part IV — CBM 8088 ROM monitor notes](#part-iv--cbm-8088-rom-monitor-notes)
  - [CBM 8088 ROM monitor (BIOS 4.35)](#cbm-8088-rom-monitor-bios-435)

## The overlay model

The kernel is the only thing on the floppy. Everything else lives on C: as
`UMIX.SYS`, so the OS can grow without re-cutting the boot disk.

```
boot sector (A:) -> kernel 1000:0000
                 -> trace on CGA + COM1: BOOTING, C: MOUNTED,
                    USERS LOADED, UMIX.SYS LOADED, CHAT.SYS LOADED,
                    boot mode prompt, STARTING SESSIONS, READY
                 -> fat_mount C: (80h)
                 -> load C:\UMIX.SYS -> 2000:0000
                 -> far call 2000:0000
                      SYS installs INT 61h (shell command hook)
                      SYS returns to the kernel
                 -> boot mode prompt on COM1: [N]ORMAL / [T]RANSFER
                 -> run C:\STARTUP.JCL (one command per line, optional)
kernel shell: unknown command -> INT 61h -> SYS handles DIR/TYPE
```

Kernel API (INT 60h) available to overlays:

```
AH=0  putc AL
AH=1  puts DS:SI
AH=2  put_dec BX
AH=4  load file: DS:SI = 11-byte 8.3 name, ES:BX = dest, CX = max
      -> DX = bytes read, CF set on error
AH=5  read C: sector: DI = LBA, ES:BX = 512-byte dest, CF on error
AH=6  FS info: ES:BX <- root_lba, root_secs, root_ents (3 words)
AH=7  yield: save the task context and switch to the next ready task
AH=8  exit: free this task slot and switch away (never returns)
AH=9  ticks: AX <- 16-bit timer tick counter (follows QUANTUM, 18 Hz default; wraps)
AH=10 getc: AL <- one key from the current console (yields while waiting)
```

## Preemptive and cooperative multitasking

UMIX is **preemptive by default**: the timer ISR (IRQ0) switches tasks every
quantum whether they cooperate or not. Tasks can also yield cooperatively with
`INT 60h AH=7`; `PREEMPT OFF` disables the timer switch and leaves only
cooperative yields (the tick still counts).

Thirteen task slots (`NSLOTS=13`): slot 0 is the CGA shell, slots 1..10 are
serial sessions, slots 11..12 run programs loaded from C:. Each task has a
code segment, a stack segment and a console (CGA or COM1):

```
slot 0     shell (CGA/keyboard)   stack 8000:0FFE
slot 1..10 serial shells (COM1)   stack 6000:0FFE .. 6900:0FFE
slot 11    code 3000:0000         stack 6A00:0FFE
slot 12    code 4000:0000         stack 6B00:0FFE
```

Per-slot stacks stop below the 0x7000 RAM disk.

Tasks started with `RUN` inherit the launching shell's console; both shells
have their own line buffer (`shellbuf`), so typing in one does not disturb the
other.

Switching happens from the timer ISR (preemptive, the default) or explicitly
(cooperative, INT 60h AH=7): the switcher pushes AX..ES, saves SS:SP in the task
table, picks the next ready slot round-robin, loads its SS:SP, pops the
registers and IRETs into it. The ISR acknowledges the PIC itself (it does not chain to the BIOS tick,
which is not reentrant) and skips switching while a BIOS disk/video call is
in progress (`crit` guard). The shell also yields in its polling loop.

Ctrl-C (`0x03`) breaks a running BASIC program: the interpreter checks the
console between statements.

`RUN FILE.SYS !` (or `&`) starts a background task and returns to the prompt;
`RUN FILE.SYS` waits (yielding) until the task exits. `PS` shows the slots
with state, segment and output console; `KILL n` frees a program slot 11..12 (a ready
background task stops immediately).

C programs can run as tasks too: Part III (Writing C programs) documents the `RUN`
runtime contract (segments, stack, INT 60h API), an IA-16 GCC build recipe and
the limits.

### What `PS` shows: slot, app, term and seg

```
SLOT NAME         APP      T  USER        CON  STATE  SEG
=============================================================
SERVICES: WEB=1 WEBLOG=0 SLIP=0 MUX=1 TFTP=0 PRIV=0
0    CGA-SHELL    console  0 CONSOLE     CGA   READY  1000
1    SER-SHELL    serial   1 SYSTEM      COM1  READY  1000
2    SER-SHELL    web      2 NOT LOGGED  COM1  READY  1000
11   PRIME        program  0 NOT LOGGED  CGA   READY  3000
12   -            -        -  -           -     FREE   4000
```

A `SERVICES:` line precedes the table, mirroring the `/api/status` bitfield.
`PS` reads the task table through `INT 60h AH=33` (offsets of `task_state`,
`task_term`, `task_app`, `task_seg`, `task_name`, `task_out` in the kernel
segment) plus `AH=29` for the services and `AH=24`/`AH=25` for the per-slot
login and name. `/api/ps` emits the same information as JSON.

**SLOT** is the task-table index (`0..12`, `NSLOTS=13`), not a hardware or
CPU feature. The scheduler scans these entries and each one owns a stack
segment, a console, a login identity and its chat state:

| slot | role |
|---|---|
| 0 | CGA/Hercules shell |
| 1..10 | serial sessions (a free slot is claimed on each mux OPEN) |
| 11..12 | program slots (`RUN`) |

The bridge's terminal ID (`tid=1..10`) is **not** the slot number: on OPEN the
kernel takes the lowest free slot 1..10 and stores the tid in `task_term[slot]`.
So terminal 3 may appear as slot 2 if slot 1 was busy.

**SEG** is the real-mode code segment (paragraph address) where the task runs,
printed in hex:

| SEG | linear | meaning |
|---|---|---|
| `1000` | `0x10000` | kernel segment — the shell code (`CGA-SHELL`, `SER-SHELL`) lives in the kernel image, so all shell slots show `1000` while still having separate stacks |
| `3000` | `0x30000` | program slot 11, where `RUN` loads the `.SYS` |
| `4000` | `0x40000` | program slot 12 |

The stack segment is not shown: slot 0 uses `8000:0FFE`, slots 1..12 use
`0x6000+(slot-1)*0x100:0FFE` (below the `0x7000` RAM disk).

Other columns: **NAME** shell/program name; **APP** `console`/`serial`/`web`/
`upload`/`program`; **T** the mux terminal id; **USER** login for serial slots
(`CONSOLE` for CGA, `NOT LOGGED` for an unauthenticated session); **CON**
`CGA`/`COM1`/`BOTH`; **STATE** `READY` while the task exists (a task blocked in
`getchar` still shows `READY` because it yields) or `FREE` for an unused slot.

### 8088 multitasking vs modern CPUs

Both do the same core loop — save the running context, pick another task,
restore it. The real difference is how much the hardware enforces, and in real
mode the answer is essentially nothing:

| | UMIX/86 on 8088 (real mode) | Modern CPU (386+/x86-64, ARM) |
|---|---|---|
| Privilege | one level, no kernel/user split | ring 0/3 (EL0/EL1) enforced by the CPU |
| Memory | one shared 1 MB; segments are only addressing | per-process virtual address space, MMU + page tables |
| Isolation | none: a task can write any address, the IVT, I/O ports | page faults trap to the kernel; user code cannot touch kernel memory |
| Context saved | 9 registers + SS:SP + flags | GPRs, FPU/SIMD, CR3, MSRs, debug/segment state, plus cache/TLB effects |
| Switch cost | ~400 cycles ≈ 40–84 µs (9.54/4.77 MHz) | ~1–10 µs, plus cache/TLB and mitigation effects |
| Address-space switch | none — all tasks share one address space | CR3/ASID/PCID switch, TLB shootdown |
| Timer | 8253 at 18.2 Hz (`QUANTUM` up to 1 kHz) | APIC/TSC/hrtimers, nanosecond resolution |
| Cores | 1 | SMP, per-CPU run queues, true parallelism |
| Scheduling | round-robin over 13 slots | CFS/EEVDF, priorities, RT classes, load balancing |
| Blocking | none — `getchar` busy-polls and yields | sleep/wakeup wait queues, idle CPU |
| Synchronisation | a `crit` byte counter + `cli/sti` | spinlocks, atomics, RCU, memory barriers |
| Fault handling | a bad task hangs or corrupts the machine | trap to kernel, kill the process |

UMIX's entire switch is: push `AX..ES`, save `SS:SP` in the slot table, pick the
next ready slot round-robin, load its `SS:SP`, pop, `iret`. No page tables, no
ring change, no TSS, no FPU state, no TLB flush. That's why the scheduler is a
few hundred bytes — and why there is **zero containment**: a task can `cli`
forever, overwrite another task's stack or hook INT 8. `crit` is a software
promise, not a hardware guarantee, and `INT 60h` is an ordinary vector any
program can call or replace.

The 286 introduced rings and descriptor tables (no paging); the 386 added
paging, flat 32-bit addressing and per-process address spaces; x86-64/ARM added
NX, SMEP/SMAP, ASLR/KPTI and per-CPU scheduling. The modern kernel is a
privileged referee; on the 8088 it is just another task in the same address
space.

> In one line: on the 8088 multitasking is **bookkeeping inside one unprotected
> address space**; on a modern CPU it is a **hardware-enforced contract** between
> an unprivileged task and a privileged kernel, with virtual memory between them.

### Quantum, CPU speed and overhead

The **quantum** is wall-clock time, set by the 8253 divisor, not by the CPU
clock. `QUANTUM` picks the tick rate; `SPEED` measures the CPU clock. They are
independent — and `SPEED` uses the live divisor, so it stays correct after a
rate change.

```
quantum = divisor / 1,193,182 s      cycles per quantum = CPU_Hz × quantum
```

| tick | divisor | quantum | cycles @4.77 MHz | cycles @9.54 MHz | switch overhead @4.77 |
|---|---|---|---|---|---|
| 18 Hz | 65536 | 54.9 ms | 262,144 | 524,288 | ~0.15 % |
| 50 Hz | 23864 | 20.0 ms | 95,455 | 190,909 | ~0.42 % |
| 100 Hz | 11932 | 10.0 ms | 47,727 | 95,455 | ~0.84 % |
| 200 Hz | 5966 | 5.0 ms | 23,864 | 47,727 | ~1.7 % |
| 500 Hz | 2386 | 2.0 ms | 9,546 | 19,091 | ~4.2 % |
| 1000 Hz | 1193 | 1.0 ms | 4,773 | 9,546 | ~8.4 % |

Overhead assumes ~400 cycles per IRQ0 + switch (9 pushes, EOI, `next_task`,
restore, `iret`). At 7.16 MHz the cycle counts are 1.5× the 4.77 column and the
overhead is 2/3 of it; at 9.54 MHz the overhead halves.

Consequences:

- **Higher CPU speed does not switch faster.** 18.2 Hz is 18.2 Hz at 4.77, 7.16
  and 9.54 MHz; the faster modes simply do more work per slice and pay a
  shorter wall-clock switch (84 → 56 → 42 µs).
- **Higher tick rate trades throughput for latency.** Maximum wait for a
  compute-bound task is one quantum: 55 ms at 18 Hz, 10 ms at 100 Hz, 1 ms at
  1 kHz — while the switch overhead grows as above. 100 Hz is the sweet spot on
  an 8088; 200 Hz is about the practical maximum; above ~500 Hz you spend more
  time switching than working.
- **Cooperative yields are free.** A shell blocked in `getchar` yields on every
  poll, so shells and chat stay responsive even at 18 Hz; the quantum mainly
  bounds how long a non-yielding program can hold the CPU.
- `PREEMPT OFF` keeps the tick counting but only cooperative yields switch.

## RAM disk

`DRIVE M` mounts a 64 KB FAT12 volume held in RAM (segment `7000`). It is
formatted at mount time; `SAVE`/`DELETE`/`TYPE`/`DIR` work exactly as on a
real volume, and nothing is written to any disk. If no C: is found at boot,
the RAM disk is mounted automatically. The volume is lost at reboot.

To use UMIX.SYS on a floppy-only machine: put `UMIX.SYS` on a DOS-formatted
data disk, `DRIVE B`, then `SYS` loads it from there.

## Video: CGA or Hercules/MDA

At boot the kernel reads the BDA: if the current video mode is 7 (MDA/Hercules)
or the equipment word says the primary adapter is mono, it selects mode 7 and
writes text to **B000:0000**; otherwise it uses mode 3 and **B800:0000**. The
panel and all output work on either adapter.

## CGA panel (mainframe style)

The CGA console is laid out like a mainframe terminal session:

```
row 0    UMIX/86 V0R121      SYSTEM CONSOLE      SYSID UCS1  26.314  10:31:39
row 1    ------------------------------------------------------------------
rows 2-22  output area (scrolls)
row 23   COMMAND ===> __________________________________________________
row 24    4A     X SYSTEM                                    023/014
```

Row 1 is a line of `=`.  Table outputs put a `=` rule under their column
header too: `DIR` (`NAME SIZE`), `PS` (`SLOT NAME ... SEG`) and `WHO`
(`USERID CONSOLE`).  Boot trace lines are prefixed with `=>`.

Commands are typed on the `COMMAND ===>` line, echoed into the output area and
executed; the OIA shows the input position.

The panel keeps the **last 128 output lines**. `PgUp` scrolls back a page,
`PgDn` scrolls forward; any other key returns to the live view (and is
processed normally). `CLS` and `PANEL OFF`→`ON` clear the history.

The **serial console draws the same panel with ANSI escapes** (clear, cursor
positioning, colours, a scrolling region for rows 3..23), so a terminal shows
the identical layout at 9600 8N1.

`PANEL OFF` / `PANEL ON` toggle the panel **on the console you are typing on**:
on the CGA (or Hercules) it switches to plain `*` lines and back; on the
serial console it switches between the ANSI panel and plain text (useful for
logging/automation). `PANEL` reports the state for the current console.
The serial console starts with the panel **off** (plain `*`) so the boot
log and login session stay visible; `PANEL ON` enables the ANSI panel.
Serial logons and logoffs are logged to both consoles as `COM1 LOGON <user>`
and `COM1 LOGOFF <user>`. System events (logon/logoff, and the console-only
`MUX` / `WRITE` commands) are printed with a `** SYSTEM MESSAGE: ` header so
they are easy to tell apart from command output.

## Serial multiplexing (phase 3)

COM1 boots as a **raw single-connection console** (9600 8N1), so one Tera Term
or `socat` connection works with no bridge. Framing is opt-in: run `MUX ON` on
the CGA/Hercules console to switch COM1 to the framed multiplexed link, and
`MUX OFF` to go back to raw. `MUX` is console-only (it would cut a serial
session's own link); serial sessions get
`MUX: CONSOLE ONLY`. The multiplexer is in Part II (Serial multiplexer design).

```sh
CONSOLE> MUX            show the current mode
CONSOLE> MUX ON         framed link for tools/serial_mux.py
CONSOLE> MUX OFF        raw single-COM console (default)
```

With `MUX ON`, up to **ten** UCS sessions share COM1 through
`tools/serial_mux.py` (`--max-sessions 10`, the bridge default).

```sh
python3 tools/serial_mux.py --serial unix:/tmp/umix-ser.sock \
  --listen 127.0.0.1:2323 --max-sessions 10
```

The bridge only works after `MUX ON` at the console. Note that toggling `MUX ON`
stops the raw COM1 shell in slot 1; `MUX OFF` refuses while framed sessions are
active, then restarts the raw shell.

HTTP probes (browsers, scanners) are detected on the first bytes and answered
with a short HTML page — “UMIX/86 is available only through an interactive
serial session” — without allocating a guest session.

With `--log-level DEBUG` the bridge logs each completed input line per
terminal (`tcp tid=1 input: b'SYSTEM'`) when Enter arrives; CRLF counts once and
backspace edits the buffer. Note this includes passwords typed at a logon
prompt, so keep DEBUG logs private.

For a **telnet** client (`telnet host 7000`, PuTTY in Telnet mode) add
`--telnet`: the bridge strips IAC negotiation and escapes 0xFF, so the guest
never sees telnet control bytes. Raw TCP clients (`nc`, Tera Term in raw mode)
work with or without the flag.

On the first IAC it sees, the bridge sends `IAC WILL ECHO` + `IAC WILL SGA`,
which tells the client that the guest echoes — so the client must **not** echo
locally. If a client still shows every character twice, or shows the line again
after Enter, its local echo/line editing is on:

- **PuTTY** (Telnet or Raw): Terminal → **Local echo: Force off** and
  **Local line editing: Force off**.
- **Tera Term**: Setup → Terminal → uncheck **Local echo**.
- **Windows telnet**: `unset localecho` before connecting; it is a line-mode
  client and may still display the edited line locally — prefer PuTTY or a raw
  client.
- **`nc`**: the local tty echoes by default; use `stty -echo`, connect, then
  `stty echo` (or a client that turns local echo off).

The bridge cannot override a client that *forces* local echo or line editing;
`WILL ECHO` only asks. The guest echoes `*` for passwords, so local echo would
also show them in clear.

`--listen` is repeatable: each port is an independent front door to the same
serial link, and every accepted client gets the next free terminal ID. Use
`--listen-fixed HOST:PORT,TID` to pin a port to one terminal ID (a reconnect
gets the same guest slot; a second simultaneous client is refused):

```sh
python3 tools/serial_mux.py --serial unix:/tmp/umix-ser.sock \
  --listen 127.0.0.1:2323 --listen 127.0.0.1:2324 \
  --listen-fixed 127.0.0.1:2325,3 --max-sessions 10
```

Connect with `nc host 2323` or a terminal program; the TCP client gets a
terminal ID and its own login/UCS session. The bridge owns TCP and framing;
the guest receives IRQ4 frames and sends framed output.

For QEMU, expose COM1 as a Unix socket and use `unix:/path`:

```sh
qemu-system-i386 -machine isapc -m 1M \
  -drive file=build/umix86-360.img,format=raw,if=floppy \
  -drive file=build/testc.img,format=raw,if=none,id=d0 \
  -device ide-hd,drive=d0,cyls=615,heads=4,secs=17 -boot a \
  -display none -serial unix:/tmp/umix-ser.sock,server=on,wait=off
python3 tools/serial_mux.py --serial unix:/tmp/umix-ser.sock \
  --listen 127.0.0.1:2323 --max-sessions 10
```

`--fake` runs the bridge against an in-memory guest (no serial hardware).
The CGA/Hercules console is independent and remains the local admin console;
serial logon/logoff lines are logged there. Direct Tera Term on the raw serial
port no longer works while the guest is in MUX mode (`MUX=1`).

Tests:

```sh
python3 -m unittest discover -s tools -p 'test_*.py'
```

## Terminals over IP (guest-side TCP/IP)

The guest has its own small IPv4 stack. IP packets travel inside the existing
mux link as terminal id `0xFE` DATA frames, so nothing changes on the wire
except the addition of that one channel. Its payload is byte-stuffed:
`0x1B -> 1B 01`, `0x02 -> 1B 02`, `0x03 -> 1B 03`.

Implemented: IPv4, ICMP echo (the machine answers `ping`), UDP, and a
terminal-session protocol on **UDP port 2323**. There is no TCP in the guest;
session traffic is UDP-based because the serial link is already reliable.

| Piece | Address |
|---|---|
| guest | `192.168.99.1`, sessions on UDP 2323 |
| host peer (the bridge) | `192.168.99.2`, ports from 40000 |

Session datagram payload: `[0]` session id, `[1]` op, `[2..]` data, where
`op` is `0` DATA, `1` OPEN, `2` CLOSE, `3` BUSY (guest to client).

**Two programs, two transports.** They share the wire codec and the serial
transports, but nothing else, and one serial port carries one at a time:

| Program | What a TCP/UDP client gets |
|---|---|
| `tools/serial_mux.py` | a terminal on mux terminal id 1..10 (standard) |
| `tools/mux_over_ip.py` | a terminal carried by the guest's own IP stack |

Running the standard mux never touches the IP code, and the IP tool exposes no
mux terminal ids at all.

A session occupies a normal task slot, so login, the shell, `DIR`, `TYPE`, the
editor and JOB control all work unchanged — only the transport differs.

### Using it

The host bridge terminates a session and hands it to an ordinary TCP client:

```sh
python3 tools/mux_over_ip.py --serial /dev/ttyUSB0 --baud 9600 \
    --telnet-listen 0.0.0.0:2400
```

Then from any machine that can reach the bridge:

```sh
telnet <host> 2400      # or: nc <host> 2400
```

You get the normal `USERID:` login over the network. `--telnet` additionally
strips telnet IAC negotiation.

### No driver, any OS: `--udp-relay`

```sh
python3 tools/mux_over_ip.py --serial COM3 --baud 9600 --udp-relay 127.0.0.1:2400
```

Each UDP client that sends a datagram gets its own terminal session; bytes in
are session input, bytes back are whatever the guest printed:

```sh
nc -u 127.0.0.1 2400
```

This needs no TUN/TAP driver, no Administrator/root rights, and behaves the
same on Linux, macOS and Windows. Use it when TUN is unavailable (a Windows
bridge, no privileges, a locked-down machine). Sessions are reaped after
10 minutes of client silence, so idle clients do not hold guest slots.

### TUN (Linux, root, optional)

A TUN device would let the host kernel own the packets (`ping 192.168.99.1`,
routing). It is **not implemented** — on Windows the L2 alternatives
(tap-windows6, Npcap) would additionally need the guest to speak Ethernet and
ARP, which it does not. Wintun (L3) would work but needs a driver and admin
rights. The UDP relay above covers the same ground with none of that.

Notes:

- **No ACK, no prompt?** The bridge prints `no ACK for terminal N ... recent
  bytes from the guest`. If those bytes are readable text (`UMIX/86 ...
  BOOTING`, `USERID:`), the guest is running a *raw* serial console: `MUX ON`
  is not active. Turn it on at the console (`MUX ON` — immediate, no reboot)
  or uncomment the line in `STARTUP.JCL` (`EDIT`, F1 saves) to make it
  permanent. While MUX is on, a plain terminal on COM1 shows garbage — the
  link is framed; use the bridge.
- The link is 9600 baud, so a full-screen redraw is slow by design. The guest
  drops any frame whose payload would exceed 250 bytes; the bridge
  chunks output and shrinks chunks when escaping would overflow.
- No fragmentation and no routing: the guest answers only its own address.
- `tools/ip_peer.py` holds the host-side protocol; `tools/mux_over_ip.py` is
  the IP transport program; `tools/ip_telnet_test.py` boots QEMU, starts it,
  logs in over TCP **and** the UDP relay, and checks a `DIR`.

Testing:

```sh
./build.sh && UMIX_MUX=1 python3 tools/mkfat.py   # MUX ON for the framed link
python3 tools/ip_test.py          # ICMP + UDP session over the raw socket
python3 tools/ip_telnet_test.py   # IP transport: TCP client + UDP relay
python3 tools/mux_std_test.py     # standard mux: TCP client -> terminal id
```

## Chat room over the multiplexer

The serial console offers a second entry point besides logon: type `CHAT` at
the `USERID:` prompt (no password) to enter a shared chat room. You can also
type `CHAT` as a normal command from a logged-on `*` shell, and the
CGA/Hercules console can join too. Messages are broadcast to every session
currently in the room, which makes the multiplexer easy to exercise from two
terminals (and the local console) at once.

```
SERIAL CONSOLE LOGON
TYPE CHAT AT USERID FOR THE CHAT ROOM
USERID: CHAT
****************************************
*      UMIX/86 CHAT SYSTEM             *
****************************************
RUNNING ON A PC/8088 - 640 KB RAM
MEASURED CPU: 9.54 MHZ
UMIX/86 OS V0R121 - MULTITASKING FAT12/16 BASIC
MUX V1.0 FRAMED SERIAL LINK - 9600 BAUD
TYPE A MESSAGE AND PRESS ENTER.
/WHO LIST USERS   /MSG NICK TEXT PRIVATE MSG
/HELP SHOW HELP   /QUIT LEAVE THE ROOM
NICKNAME: ALICE
USERS IN CHAT:
  NICK      CONSOLE
  ALICE     COM1  <== YOU
ALICE> HELLO
```

Chat commands:

```
/WHO            list users as a readable NICK/CONSOLE table
/MSG NICK TEXT  send a private message to one user
/BAN NICK       (console SYSO only) remove a user from the room
/HELP           show the command summary
/QUIT           leave the room; returns to the USERID: prompt if you entered
                from logon, or to the `*` prompt if you typed CHAT from the
                shell
```

The CGA/Hercules console is the chat **SYSO**: it can `/BAN NICK` to eject a
user (the user is woken immediately and told `REMOVED FROM CHAT BY SYSO`), and
`CHAT ON` / `CHAT OFF` (console only) enables or disables the room system-wide
(`CHAT OFF` removes everyone, and also makes every `/api/chat*` endpoint
answer `503`). Other sessions get `BAN: SYSO ON CONSOLE ONLY`
or `CHAT: CONSOLE ONLY TO ENABLE/DISABLE`.

Open two TCP clients on the bridge (e.g. two `nc 127.0.0.1 2323`), type
`CHAT` and a nickname in each, and messages typed in one appear in the other
as `NICK: text`; `/MSG BOB SECRET` arrives only at BOB as
`[PRIVATE] ALICE: SECRET`. The local CGA/Hercules console participates the
same way: run `CHAT` at its shell prompt. Sessions logged on to the shell are
unaffected: chat traffic is only delivered to sessions in the room.

With `PANEL ON`, chat renders inside the 3270-style panel: messages go to the
output area (rows 3-22), the live input line is redrawn on row 24, and incoming
messages do not disturb the text being typed. Without the panel it is a plain
scrolling chat. Only nicknames are uppercased; message text keeps its case.

The preemption quantum is set by the 8253 tick. `QUANTUM` (console, or a serial
SYSTEM session when `PRIV ON`)
reprograms channel 0: 18 Hz is the default (55 ms), 100 Hz gives a 10 ms
quantum for responsive background tasks at under 1 % overhead on a 4.77 MHz
8088. The MUX idle timeout and `SPEED` follow the selected rate.

`SPEED` measures the CPU clock from the 8253 tick and the 8088 `DEC/JNZ`
loop (18 clocks), so the banner and `SPEED` show the speed currently selected
on the machine. On a Commodore PC20-III, `SPEED -D` (or `Ctrl+Alt+D`) selects
Double mode (9.54 MHz); re-run UMIX `SPEED` after changing modes.

## Web server over the multiplexer

The bridge can also expose the guest as a minimal static web server. Start it
with an HTTP listener next to the console listener:

```
python3 tools/serial_mux.py --serial /dev/ttyUSB0 \
    --listen 0.0.0.0:2323 --http-listen 0.0.0.0:8080
```

Put files in the 8.3 root of the mounted volume — C: at boot.  A request for
`/` serves `INDEX.HTM`.  Any other target is mapped to an 8.3 name on the
volume and served if that file exists, so `/README.TXT`, `/JOB.JCL` and
`/index.htm` all work (case-insensitive; a query string such as
`/JOB.JCL?x=1` is ignored).  A missing file, a path with a subdirectory, or a
file larger than the 4000-byte buffer gets `404.HTM` from C: with
`HTTP/1.0 404 Not Found`.  Upload pages over TFTP (`WRITE ON` required):

```sh
python3 tools/umix_tftp.py put 404.HTM
```

If `404.HTM` is not on the volume, the built-in `NOT FOUND` page is served.

```
GET /index.htm HTTP/1.1
-> HTTP/1.0 200 OK
   Content-Type: text/html
   Content-Length: <size>
   Connection: close

   <INDEX.HTM>
```

The image ships a system guide: <code>/</code> (INDEX.HTM) is the overview,
and <code>/UMX002.HTM</code> .. <code>/UMX007.HTM</code> cover the OS,
MUX + TCP/IP, services + BASIC, terminals, web API and chat. Each page is
under 4 KB and links to the others. The API explorer is
<code>/EXPLORER.HTM</code> and the browser chat app is <code>/CHAT.HTM</code>
(both are linked from the overview); the explorer links back to the guide as
"System guide".

The file is sent by the guest itself, so the browser gets exactly what is
stored on C:. Limits: the file is read into a 4000-byte buffer and served as
`text/html` (the extension is not used to pick a Content-Type); one request
per connection; web clients share the same ten serial session slots as console
clients.  Any file in the C: root is reachable, including `UMIX.SYS` names —
keep the listener on a trusted network. The mounted volume must still be C: (a
`DRIVE` elsewhere switches where INDEX.HTM is read from).

Browser request headers (~500 bytes) are fed to the guest in 64-byte chunks
every 10 ms. The per-session receive ring is 256 bytes and the web task runs
once per 18 Hz tick; this keeps the ring from overflowing while making the
hand-off much faster than the old 32-byte/60 ms pacing. The response is limited by the
9600-baud link (about 900 bytes/s): a 161-byte page answers in under a second,
a 4 KB page takes roughly 4 seconds. Keep the page small or raise the serial
speed with `BAUD` (see below): 19200 halves the page transfer time.

Test from the host:

```
curl http://127.0.0.1:8080/
```

A browser also asks for `/favicon.ico`; that now returns `404.HTM` (or the built-in 404) instead
of the whole page, so it no longer doubles the transfer.

The web reads `INDEX.HTM` from the **mounted volume**, so to serve it from RAM:

```
* COPY C:INDEX.HTM M:
```

leaves M: mounted and the next request is read from M:. `DRIVE C` switches the
shell (and the web) back to C:.

Console controls (CGA only):

```
CONSOLE> WEB ON|OFF       enable/disable the web application
CONSOLE> WEBLOG ON|OFF    log incoming requests on the CGA panel
```

`WEB OFF` answers every request with `503 Service Unavailable` / `WEB
DISABLED` without touching the disk. `WEBLOG ON` prints the request line, e.g.
`WEB GET /index.htm HTTP/1.1`, on the CGA panel as it arrives (the web task
temporarily routes the log line to the console, then restores its serial
output).

## Uploading files

The bridge can put a file into the guest's mounted volume:

```
python tools/serial_mux.py --serial COM3 \
    --listen 0.0.0.0:2323 --http-listen 0.0.0.0:7001 \
    --upload-listen 127.0.0.1:7002 --telnet --log-level DEBUG
```

then, from the PC:

```
python tools/umix_put.py 127.0.0.1:7002 INDEX.HTM
OK 3789 BYTES
```

- The bridge opens a session with **application id 3**; the client sends
  `PUT NAME SIZE\n` followed by the raw bytes. The guest writes the file and
  replies `OK n BYTES` or `ERR ...`, then closes.
- The name is **8.3, uppercase**; without a dot the extension defaults to
  `.SYS`. The file goes to the **root of the mounted volume** (C: at boot).
- `WRITE ON` is required (same gate as SAVE/COPY/DELETE); the maximum is
  **8192 bytes** per file.
- Binary-safe: telnet filtering applies only to console sessions, so `.SYS`,
  `.BAS`, `.HTM` and binary files pass through untouched.
- The current volume must be the target: `DRIVE C` before uploading to the hard
  disk; if M: is mounted, the file lands on the RAM disk (lost on reboot).

Useful uploads:

```
umix_put.py ... INDEX.HTM     -> C:\INDEX.HTM, served by the web immediately
umix_put.py ... TEST.BAS      -> C:\TEST.BAS,  BASIC / LOAD "TEST"
umix_put.py ... PROG.SYS      -> C:\PROG.SYS,  RUN PROG.SYS
```

## API explorer (browser)

`tools/api_explorer.html` is shipped as `C:\INDEX.HTM` and served by the guest's
web server.  Open `http://HOST/` (the same `--http-listen` port): the page
lists every endpoint as a button, has method/URL/body fields, job shortcuts
(prime/sort/crc), job detail/result/cancel, `/api/routes`, and pretty-prints
status, Content-Length, X-API-Version and JSON.  Same-origin, so no CORS.

Deploy it with the mux uploader (3,334 bytes) or rebuild the C: image:

```
python3 tools/umix_put.py HOST:UPLOAD tools/api_explorer.html INDEX.HTM
```

The guest's static page limit is 4,000 bytes.  `serial_mux.py` serializes web
sessions from OPEN because the guest's HTTP parser state is global; without
it a browser's document + favicon requests clobber each other.  The page also
suppresses the favicon and serializes its own calls.  A different web front
end (TCP.SYS) bypasses the bridge lock.

## Chat over HTTP

The kernel's line chat room (type `CHAT` at the `USERID:` prompt) and the JSON
API now share one message history, so a browser can read and post to the same
room as serial users. It needs **MUX ON and SLIP/TCP OFF**; otherwise the chat
endpoints answer `503`. Chat is **on by default**; `CHAT OFF` on the console
closes the room and makes every `/api/chat*` endpoint return `503` until
`CHAT ON`. For a default-off image, build with `UMIX_CHAT=0` (mkfat then puts
`CHAT OFF` in STARTUP.JCL; `UMIX_CHAT=1` selects an explicit `CHAT ON`).

```
POST /api/chat/join      {"nick":"ALICE"}          -> {"token":1}
POST /api/chat/send      {"token":1,"text":"hi"}   -> {"seq":4}
GET  /api/chat/messages                            -> {"latest":4,"messages":[...]}
GET  /api/chat/messages/3                          only seq > 3
DELETE /api/chat/join/1                            -> {"ok":true}
GET  /api/chat                                     nicks + api + latest
```

Nicknames are 2..9 alphanumeric characters (upcased); `SYSOP` is reserved.
Text is capped at 50 characters; control characters and quotes are stripped.
The ring keeps the last 16 lines, each with a sequence number, so a client
polls `messages/<last-seq>`.  A join or leave posts `ALICE: JOINED CHAT` /
`ALICE: LEFT CHAT` into that history, so both web and terminal users see
presence; the terminal `/WHO` lists terminal participants and then an
`API: ALICE CAROL` line with the web nicknames.

Implementation: two new `INT 60h` calls — `AH=34` (broadcast and append) and
`AH=35` (next record since a sequence) — plus a history ring and an API
session table in the `0x2900` window (the SYS zero-padding that `TCP.SYS` also
uses). That window is free in the default MUX configuration, so chat history
and `TCP.SYS` are mutually exclusive; a reboot, `SYS` reload or `TCP ON`
resets the history and tokens. The API is unauthenticated, like the rest of
the endpoint set — keep the bridge on a trusted network.



The guest runs its own TFTP server on **UDP port 69**. TFTP is UDP-based, so
it fits the small IP stack that already carries ICMP and the terminal
sessions; there is no TCP in the guest.

Enable it from the CGA/Hercules console (default **OFF**):

```
CONSOLE> TFTP            report the state
CONSOLE> TFTP ON         serve UDP 69 (requires MUX ON for the link)
CONSOLE> TFTP OFF        stop; an active transfer is dropped
CONSOLE> TFTPLOG ON|OFF  log requests, progress every 4 KB, DONE/ERR
```

The host still needs a relay, because nothing on the PC can route to
`192.168.99.1`. Either bridge can be the UDP NAT. `serial_mux.py` with `--ip`
gives you the serial sessions *and* TFTP in one process:

```sh
python3 tools/serial_mux.py --serial /dev/ttyUSB0 --baud 9600 \
    --listen 127.0.0.1:2323 --ip --tftp-listen 127.0.0.1:6969
```

or, if you only want the IP side:

```sh
python3 tools/mux_over_ip.py --serial /dev/ttyUSB0 --baud 9600 \
    --tftp-listen 127.0.0.1:6969
```

`TFTPLOG ON` (console, or a SYSTEM serial session with `PRIV ON`) prints one
line per request, a progress line every 4 KB, and a final `DONE`/`ERR` line,
on the CGA panel and on the serial session that enabled it — the same
plumbing as `WEBLOG`:

```
TFTP GET UMIX.SYS
TFTP GET UMIX.SYS 4224
TFTP GET UMIX.SYS 8256
...
TFTP GET UMIX.SYS DONE 36779
```

The relay talks to the guest from the guest's transfer id (6969) and forwards
the replies to the last client, so any TFTP client that supports a small
`blksize` works. The repository ships one:

```sh
python3 tools/umix_tftp.py get README.TXT
python3 tools/umix_tftp.py put TEST.BAS
```

On Windows the same commands use `py tools\umix_tftp.py` and
`--serial COM3`.

### Block size: 192 bytes is the ceiling

A mux frame carries **250 bytes**, and IP frames are no longer byte-stuffed:
the frame already has a length byte and an XOR, so binary data crosses
verbatim. IP + UDP headers take 28 and the TFTP header takes 4, leaving the
server's `blksize` at **192** (224-byte packet in one frame). A larger
request is answered with `blksize=192` in the OACK.

The server also implements RFC 7440 **`windowsize`** (1..4) for downloads:
it sends up to four DATA blocks before waiting for one cumulative ACK, and
the OACK echoes `windowsize 4`. Clients that do not ask get the classic
one-ACK-per-block behaviour. `umix_tftp.py` asks for 4 by default; atftp
needs `--option "windowsize 4"`. **A client that does not send the `blksize` option cannot be
served**: standard TFTP then uses 512-byte blocks, which cannot cross the
link. The server answers `ERROR 8 (option negotiation failed)` with
`BLKSIZE REQUIRED (MAX 192)` instead of hanging.

In particular the Windows built-in `tftp.exe` has no block-size option and
**cannot** be used, and neither can `curl` (its `--tftp-blksize` accepts 512
and above). Use `umix_tftp.py`, atftp, or PumpKIN.  On a real 9600-baud link
give atftp a sane retransmit delay and keep it from re-ACKing storms:

```bat
atftp --option "blksize 192" --option "windowsize 4" --tftp-timeout 10 --prevent-sas ^
    -g -r UMIX.SYS -l UMIX.SYS 127.0.0.1 6969
```

The guest retransmits after about **two seconds regardless of `QUANTUM`**
(the timeout is computed from `tick_hz`), and an ACK for the previous block
immediately re-sends the current DATA, so a lost packet costs milliseconds,
not a timeout.

### Limits and behaviour

- One transfer at a time. A second request gets `ERROR 0 (BUSY)`; a duplicate
  request from the same client re-sends the last OACK/ACK.
- GET streams from disk, so it serves any file the FAT low word can describe
  (up to 64 KB). PUT streams each block straight into the FAT — clusters are
  allocated and linked as data arrives, the sector is flushed, and the
  directory entry is updated after every 512 bytes — so the limit is the
  FAT's 16-bit size (**64 KB**, the same as any file this OS can address) and
  `WRITE ON` is required. An interrupted upload leaves a consistent file up
  to the last flushed sector.
- Names are uppercased 8.3, root directory only. A name without a dot has no
  extension (unlike the uploader, which defaults to `.SYS`).
- `octet` mode only; `netascii` gets `ERROR 4`.
- The state machine is ticked from `mux_poll`, which the shell calls while it
  waits for a key. A non-yielding program (BASIC, `RUN` without `!`) stops the
  server until the prompt returns.
- Speed: one-ACK-per-block gives ~700 B/s at 9600 (75% of line rate);
  `windowsize 4` removes three of every four ACKs and reaches ~850 B/s
  (about 90%). A 161-byte page is one block; 4 KB ~5 s, 8 KB ~10 s,
  36 KB ~45 s.
- No authentication and no encryption. Keep `TFTP OFF` unless you are using
  it, and remember that `WRITE ON` is the only thing between a PUT and the
  volume.

Test (QEMU): build the C: image with the startup switches, then run the
scripted GET/PUT round trip:

```sh
./build.sh && UMIX_MUX=1 UMIX_TFTP=1 python3 tools/mkfat.py
python3 tools/tftp_test.py          # mux_over_ip relay
python3 tools/combined_test.py      # one serial_mux: session + TFTP
```

## SLIP: raw IP over COM1

`SLIP ON|OFF|SHOW` (CGA console only) turns COM1 into a SLIP line: `0xC0` END,
`0xDB 0xDC` / `0xDB 0xDD` escapes, **250-byte MTU**. `MUX` must be off; SLIP
stops the raw serial shell and enables IRQ4, while the CGA console keeps
running. No bridge process is needed on the host.

Linux host:

```sh
slattach -p slip -s 9600 /dev/ttyUSB0
ifconfig sl0 192.168.99.2 pointopoint 192.168.99.1 mtu 250 up
ping 192.168.99.1
tftp 192.168.99.1 get README.TXT
```

`SLIP` or `SLIP SHOW` reports the state and the address:

```
SLIP: ON
IP 192.168.99.1  MTU 250  MUX OFF
  RX 12  TX 12  ERR 0
```

SLIP has no address negotiation: the guest's address is the IP stack's static
`ip_my_addr` (192.168.99.1); the host configures the peer on `sl0`.  The
guest's ICMP and UDP (TFTP) work natively, and `TCP.SYS` adds TCP + HTTP on
top of the same line (see the next section).  On a real serial link use
`atftp` with both options:

```sh
atftp --option "blksize 192" --option "windowsize 4" \
      -g -r UMIX.SYS -l UMIX.SYS 192.168.99.1
```

Occasional retransmissions ("wrong block N" from atftp) are normal: the
guest resets its retry counter on **any** ACK, so duplicates no longer abort
the transfer, and `windowsize 4` makes the resend cover the whole window. Windows has no SLIP, and a larger MTU
is dropped: a mux frame is 250 bytes. `tools/slip_test.py` exercises ICMP and
a TFTP RRQ over SLIP in QEMU.

## TCP and HTTP (`TCP.SYS`)

`TCP ON|OFF` (console) loads `C:\TCP.SYS` at `0x2900` and starts an HTTP
server on **TCP port 80**.  `SLIP ON` must already be active - TCP has no
path over the framed mux, so `MUX ON` has to be turned off first (`TCP` over
an active mux answers `TCP: ON` but the server sees no packets).
`TCP.SYS` and `CHAT.SYS` share the 0x2900 overlay window; load one at a time.

`TCPLOG ON|OFF` (console) logs each request on the CGA panel, e.g.
`TCP 192.168.99.2:40000 GET / HTTP/1.1` (the address is the peer the guest
sees; behind the SLIP host's NAT that is 192.168.99.2).

The server is deliberately small: one connection at a time, HTTP/1.0 `GET`,
`Connection: close`, MSS 200 (IP total 224 inside the 250-byte SLIP frame),
`/` serves `INDEX.HTM`, everything else `404.HTM`.  The overlay has an 8 KB
body buffer and a ~9 KB response buffer, so pages up to **8,900 bytes** are
served whole (the earlier 512-byte limit is gone).

Browser behaviour, and what the overlay does with it (V0R121):

- **Parallel SYNs.** A browser opens several connections at once (page,
  favicon, speculative sockets).  While a transfer is active the extra SYNs
  are ignored, so they cannot abort the page; an idle/stale TCB or one in
  TIME_WAIT is reset by a fresh SYN.
- **Retransmitted GET data.** A duplicate DATA segment with an old sequence
  number is re-ACKed and *not* appended again, and `req_done` guarantees the
  response is built exactly once per request.  Before V0R121 a retransmit
  could append the request twice and build a second response, which showed up
  in a browser as repeated `GET /` lines and a truncated page.
- **Sequential requests.** After `Connection: close` and the client FIN the
  TCB is freed immediately, so the next connection (new source port) is
  answered right away.
- **Long requests.** A real browser request is 300-600 bytes (cookies,
  `Accept`, `Sec-Fetch-*`).  The parse buffer is 220 bytes, but the sequence
  is advanced past the *whole* segment, so the tail is acknowledged instead of
  being retransmitted for ever.  Before V0R121 the client retransmitted the
  unacknowledged tail in a loop and the page never finished - this was the
  real "it hangs after a few requests" bug, visible in `io2.pcap` from an
  iPhone (522-byte GET, guest stuck ACKing 221).
- **Parallel sockets.**  A browser opens ~6 connections at once.  A SYN from
  another socket used to steal the TCB whenever nothing was in flight - i.e.
  in the window between our SYN-ACK and the client's GET - which killed the
  page socket every time (Chrome failed, curl worked; single-socket clients
  never hit it).  A TCB that has not carried a request yet is still handed
  over immediately (that is how a browser picks the socket for its GET); once
  a request is being served it is kept until the peer has been silent for
  ~3 s.
- **Stray RST.**  Chrome closes its unused preconnect sockets with RST.  Any
  RST used to reset the TCB regardless of who sent it, so abandoning a
  preconnect killed the page being served.  RST is now honoured only from the
  owning IP + port, and a late SYN retransmit on the same socket no longer
  re-handshakes a live connection.
- **Stray FIN.** A FIN is only honoured when it comes from the peer that owns
  the TCB (IP + port match).  Browsers keep several half-open sockets and one
  of them closing must not abort the page in flight.
- **No fast retransmit on stale ACKs.** A delayed or duplicated ACK is
  ignored; resends come from the retransmit timer only.  The old code treated
  every ACK below `snd_nxt` as "you missed my last segment" and re-sent it,
  which doubled the traffic whenever the client retransmitted its request.
- **`/favicon.ico`** (any path containing `.ico` in the request line) answers
  a 66-byte `404` with `Content-Length: 0` and no disk I/O.  Browsers ask for
  it right after the page; a short answer frees the single TCB immediately.
- **FIN together with data.** Some browsers half-close on the last request
  segment.  The payload is consumed, the FIN is acknowledged by consuming its
  sequence number, and the response is still sent; the TCB is freed only after
  the page has gone out.  (V0R83 reset the TCB there, which looked exactly
  like "the page stops and the guest goes silent" - see `io3.pcap`.)

`TCP ON` prints `TCP: ON (HTTP :80)` and the overlay then announces itself on
the console as `TCP.SYS V0R121 - HTTP SERVER ON :80`, so a stale `C:\TCP.SYS`
is immediately visible.

**MSS must be clamped on the host.**  The SLIP link is 250 bytes, so anything
the client sends above that is fragmented (DF=0) or dropped (DF=1) by Linux
before the guest ever sees it.  At MTU 250 the fragments are 244 bytes (224
data, rounded down to a multiple of 8), which is where the odd `ACK 205` in
`io5.pcap` comes from: the guest parsed the first fragment as a complete
segment and acknowledged 204 bytes it had not received.  Clamp it on the host:

```sh
iptables -t mangle -A FORWARD -o sl0 -p tcp --tcp-flags SYN,RST SYN \
         -j TCPMSS --set-mss 200
```

V0R121 also drops any IP fragment (MF set or non-zero offset) instead of
mis-parsing it - there is no reassembly in a 64 KB kernel.

**SLIP frame limit: 256 bytes.**  The receiver buffer is 256 bytes, so an IP
packet larger than that is dropped whole and `SLIP SHOW` counts it in `ERR`.
A browser segments its request by the path MTU, not by our MSS option: with a
256-byte path MTU the request arrives as 216-byte segments (256-byte packets)
and V0R84 rejected them (limit was 250), which looked like "the page loads
sometimes" depending on the request size - see `io4.pcap`.  V0R121 accepts up
to 256.  Keep the host SLIP interface at `mtu 250`; the guest has no memory
to grow the buffer further.

**WEBLOG never draws over the chat.**  If the session that enabled the serial
mirror is in the chat room, the mirror is suppressed (console copy only), so a
log line can never land on the chat screen.

**WEBLOG destinations.**  `WEBLOG ON` (console + serial mirror),
`WEBLOG CONSOLE` (console only), `WEBLOG SERIAL` (console + mirror, refused
unless the session is SYSTEM with `PRIV ON`), `WEBLOG OFF`.  The mirror also
requires that the enabling session is SYSTEM with privileges.

**Nickname rules.**  The room accepts 2-12 characters, letters and digits only;
anything else is rejected with `2+ LETTERS OR DIGITS ONLY` and the prompt repeats.

**Full-screen chat is disabled (V0R121).**  The per-session TX ring is only 64
bytes, so the ANSI sequence + line + CRLF for one message overflows it and the
flush splices spaces into the text (and, before the V0R114 guard, corrupted
memory).  Until `CHAT.SYS` exists, the room uses the plain line mode, which
delivers messages reliably in both directions.

**Chat screen layout (inactive until the overlay).**  Row 1 title with the user count and RTC time, row 2
rule, row 3 `users: <count>`, rows 4-9 one nickname per row (the upper frame),
rows 10-22 messages, row 23 the menu line, row 24 the input.  An empty Enter
sends nothing.

**Chat users line.**  Entering the room prints `users: nick nick` in every
session (plain line), refreshes the panel row on serial sessions, and on a
serial session the chat enables the panel itself.  The room draws `users: <nicks>` on
panel row 3 and moves the message area to rows 5-23, leaving row 24 for the
input.  The list is refreshed whenever a line is written into the panel.

**Mux connection line is console-only.**  The `[TELNET] host:port COLSxROWS`
line is printed with `cur_task` forced to 0, so it appears on the CGA log and
never inside the session window.

**Mux connection line.**  `serial_mux.py` now packs the client address into the
OPEN frame after the app id (`[TELNET] 1.2.3.4:5678 `, `[WEB] …`, `[UPLOAD] …`) and the
guest prints it on the console log when the session opens.  The app id keeps
its position, so a 1-byte payload (old bridge) behaves exactly as before.
Kernel cost: a 16-byte string trim for the shared `** ` prefix, plus ~18 bytes
of code; the kernel is now 64,160 of 65,536 (HELP text moved into the overlay).

**ACK trace.**  With `TCPLOG ON` each acknowledgement prints
`TCP ACK <acked> off <resp_off>` on the panel, so a stall shows whether ACKs
stopped arriving or stopped advancing.

**Stall probe.**  If data remains unsent while nothing is in flight, the
overlay prints `TCP STALL <sent>/<total> <acked>` once, until progress is
made - a sender deadlock, as opposed to a connection that was reset.

**A bystander SYN cannot kill a transfer.**  While a connection has
unacknowledged data, a new SYN now needs ~16 s of silence (was ~3 s) before it
may take the TCB, which is longer than the retransmit timer.

**Reset diagnostics.**  Every TCB reset prints one line on the CGA panel -
`TCP RESET R` (RST), `F` (FIN), `S` (SYN took over), `T` (timeout), and `r`
for a plain retransmit - so a stalled page shows on the console which event
ended the connection.

**Mailbox keeps the newest ACK.**  The TCP mailbox is one packet deep; while
the overlay is blocked pushing bytes to the UART, the client's ACKs queue up
and the kernel used to keep the first and drop the rest - the worst choice
for cumulative ACKs, and the reason a sliding window made throughput worse.
A pure ACK now overwrites a stale one.

**One-slot SYN backlog.**  A SYN that arrives while a page is being served is
remembered and answered as soon as the TCB is free, rather than dropped and
left to the client's RTO (1 s, 2 s, 4 s...).  This keeps a browser's second
connection cheap without serialising the relay.

**Throughput.** 9600 baud is 960 B/s, so a 3,538-byte page plus per-segment
headers and ACKs has a floor of roughly 4.5 s.  V0R121 keeps 600 bytes (three
segments) in flight with cumulative ACKs and go-back-N retransmission; before
that the overlay was stop-and-wait and took about twice as long.  `tools/tcp_test2.py`
test P checks that three segments leave without any ACK arriving.

`tools/tcp_test.py` does the handshake, one `GET /` and checksum validation;
`tools/tcp_test2.py` adds the browser cases above: duplicate GET segment,
second connection after close, intruder SYN during a transfer, a 417-byte
request split like sl0 does at MTU 250, a favicon 404 and a stray FIN from a
parallel socket.
Both boot QEMU with `build/umix86-360.img` plus a C: image built **without**
`UMIX_MUX`:

```sh
./build.sh && UMIX_TCP=1 UMIX_BIGWEB=1 UMIX_TFTP=1 python3 tools/mkfat.py
python3 tools/tcp_test.py
python3 tools/tcp_test2.py
```

```sh
slattach -p slip -s 9600 /dev/ttyUSB0
ifconfig sl0 192.168.99.2 pointopoint 192.168.99.1 mtu 250 up
curl -v http://192.168.99.1/
```

The kernel keeps IPv4/ICMP/UDP/SLIP and only provides the proto-6 mailbox,
the `INT 60h AH=19` send call and the `TCP.SYS` loader; the TCP state machine
and HTTP server live in the overlay.

## Baud rate

The UART starts at 9600 8N1 at every boot. From the CGA console:

```
CONSOLE> BAUD 19200
BAUD SET - RESTART THE BRIDGE WITH --baud 19200
```

Accepted rates: 2400, 4800, 9600, 19200, 38400. The command rewrites the 8250
divisor (48/24/12/6/3). It is console-only on purpose: changing COM1 under a
running bridge would garble the link. Restart the bridge with the same rate:

```
python3 tools/serial_mux.py --serial COM3 --baud 19200 \
    --listen 0.0.0.0:2323 --http-listen 0.0.0.0:7001
```

Typing `BAUD` alone reports the current rate. A reboot returns to 9600.

Effect: the guest-to-host direction (web page, panel output) runs at the new
rate. A 3.3 KB page drops from ~3.6 s at 9600 to ~1.8 s at 19200 (~0.9 s at
38400). The 8250/16450 has no FIFO and the 8088 services one byte per
interrupt: 19200 is safe in normal use; test 38400 on the specific machine,
especially during disk I/O with interrupts off.

### Host-to-guest bursts are paced — do not remove this

The bridge writes 64-byte frames with a delay computed from the baud rate:

```python
line_byte = 10.0 / baud          # 1.04 ms at 9600
delay     = line_byte * 64 * 1.35   # ~90 ms -> 711 B/s, ~75% of the line
```

Without that delay the driver queues the whole buffer instantly and the line
runs at 100% duty cycle. The guest has **no receive FIFO**, so any ISR latency
over ~1 ms drops a byte. The visible symptom is nasty because it is silent: a
web or upload session is ACKed, the request is corrupted, the guest's parser
never sees the terminating blank line, and `web_getc` waits out its 10-second
timeout — no error anywhere, just a browser that spins.

QEMU cannot reproduce this (its UART is instant), so a QEMU-only test will
always pass. Single frames (typing, one key at a time) are still sent
immediately; only bursts longer than one frame are paced.

The bridge also warns when an app session is ACKed but sends nothing back:

```
WARNING terminal 1 (app 2) acknowledged but sent nothing for 6 s:
        the guest task is not reading the request (stale session? reboot)
```

## UMIX BASIC

`BASIC` enters the interpreter (V2, running in `UMIX.SYS`; `C:\UMIX.SYS` must be present):

```
> 10 PRINT "HELLO"
> 20 A=2+3*4
> 30 PRINT A
> 40 IF A=14 THEN PRINT "OK" ELSE PRINT "NO"
> 50 GOSUB 100
> 60 END
> 100 PRINT "DONE"
> 110 RETURN
> LIST
> RUN
HELLO
14
OK
DONE
> SYSTEM
```

Statements: PRINT (strings, expressions, `;`/`,`), LET or `A=...`,
IF..THEN..ELSE (line number or statement), GOTO, GOSUB/RETURN,
FOR..TO..STEP / NEXT, INPUT, DIM, END/STOP, REM (or `'`), CLS, RANDOMIZE.
Several statements can share a line, separated by `:`. A trailing `;` or `,`
in PRINT keeps the line open.

Numbers are 16-bit integers: `+ - * / MOD ^`, parentheses, unary minus,
comparisons (`= <> < > <= >=`; true is -1), `AND OR NOT`, and `ABS() INT()
SGN() SQR()` or `RND(n)`. Numeric variables are A-Z.

Strings: variables `A$`..`Z$` (up to 63 characters), literals in quotes,
concatenation with `+`, string comparisons, and `LEN() LEFT$() RIGHT$()
MID$() INSTR() UCASE$() LCASE$() CHR$() ASC() STR$() VAL()`.

Arrays: `DIM A(10)` (numeric, 0..10) and `DIM A$(10)` (string, 31 characters
per element), separated by commas in one DIM. Elements can be used before DIM
(auto-dimensioned to 0..10). The numeric arena holds 512 words; the string
array arena holds 32 elements in total.

Commands: RUN [n] (clears the variables and arrays), LIST, NEW, AUTO, SYSTEM/QUIT,
`LOAD [A:|B:|C:|M:] NAME` and `SAVE [A:|B:|C:|M:] NAME` (extension `.BAS`
by default; quotes optional). LOAD replaces the current program; SAVE needs
`WRITE ON`. A:/B: need a FAT-formatted data disk, M: is formatted on first
use; with no prefix the currently mounted volume is used. The program store
is 48 lines of 64 bytes, kept sorted by line number.

`AUTO [n[,step]]` turns line numbering on: the prompt is prefilled with
10, 20, ... and you type just the statement. ENTER on a bare number (or
Ctrl-C) turns numbering off; a command typed after the number (`40 RUN`) runs
instead of being stored; `AUTO 100,5` restarts at 100 with a step of 5.

Numbers have no decimal point (the x86-64 umix UBAS interpreter has fixed
point and more functions).

## Volumes and floppies

`DRIVE A|B|C` mounts a volume: the kernel re-reads the BPB, so after booting
from the floppy you can swap the disk in A: for a DOS-formatted data disk and
run `DRIVE A` to use it (the OS itself stays in RAM). `SAVE`/`DELETE` write to
the mounted volume, still gated by `WRITE ON` (set from the CGA console; a
serial session that tries `WRITE` gets `WRITE: CONSOLE ONLY`). FAT12 and FAT16 are both
supported; the mount message names the volume (e.g. `B: FAT12`).

`COPY [C:|M:|A:|B:]SRC [C:|M:|A:|B:]DST` copies a file through a 4 KB buffer
and leaves the destination mounted. A bare destination drive keeps the source
name:

```
COPY C:INDEX.HTM M:
```

This copies `INDEX.HTM` to the RAM disk and leaves M: mounted. M: is formatted
only when it has no valid FAT (so a second COPY preserves the files already
there); `DRIVE M` still formats and erases it. The mounted volume is global:
after this COPY the shell and the web server use M: until `DRIVE C`.

There are two shells: the CGA/keyboard one and a separate COM1 shell (9600
8N1). **The serial shell requires a logon**; the CGA console does not. Built-in
accounts (case-insensitive, password echoed as `*`):

```
SYSTEM / SYS1
USER   / USER
USER2  / USER2
```

The account table is managed **from the CGA console**, or from a serial SYSTEM
session when `PRIV ON` (other serial users get `USER: CONSOLE ONLY`), and
persisted as described below:

```
CONSOLE> USERS                     list accounts
CONSOLE> USER ADD ALICE ALICE1     add an account (name/password max 8 chars)
CONSOLE> USER PASS ALICE NEWPASS   change a password
CONSOLE> USER DEL ALICE            delete an account
CONSOLE> USER LIST                 same as USERS
CONSOLE> USER SAVE                 write the table now
```

Names and passwords are upcased. The table is persisted in **two places**:

- a reserved sector on the **boot floppy** (LBA 700, outside the boot sector and
  the 128-sector kernel area; not a file, so `DIR` does not show it), and
- **`USERS.DAT`** (166 bytes) in the root of the mounted volume (C: at boot).

On boot the kernel reads the floppy sector first and falls back to `USERS.DAT`
if the sector is blank/invalid. Changes are saved automatically when
**`WRITE ON`** is active; `USER SAVE` writes explicitly. If the boot floppy is
write-protected the save goes to C: (`SAVED TO USERS.DAT (C:)`); if neither is
writable you get an error. Without `WRITE ON` changes stay in RAM and the
command prints `NOT SAVED (WRITE ON)`. `USER RESET` restores the built-in
accounts and saves. Passwords are plaintext in RAM and on disk (this is a hobby
OS, not a security boundary). Rebuilding the boot image (`build.sh` zeroes the
reserved sector) or deleting `USERS.DAT` with `WRITE ON` resets to the built-in
accounts. The last remaining account cannot be deleted, so you cannot lock
yourself out.

`LOGOFF` returns the serial console to the USERID prompt (on the CGA console
it reports that no logon is required). `WHO` shows both consoles and their
users; `WHOAMI` prints the user of the console you are typing on (`CONSOLE`
for the CGA). The boot messages are printed to both; after boot each shell owns its
console (`PS` shows OUT 0 = CGA, 1 = COM1). A terminal on the serial port gets
its own prompt and command line, independent of the CGA console.

Demo (files built as `build/hello1.sys` / `build/hello2.sys`, copied to C:):

```
* RUN HELLO1.SYS !
HELLO FROM PROGRAM1
* RUN HELLO2.SYS
HELLO FROM PROGRAM2
HELLO FROM PROGRAM1
HELLO FROM PROGRAM2
...
* DIR
NAME        SIZE
UMIX.SYS  9449
README.TXT  104
HELLO1.SYS  59
HELLO2.SYS  59
```

INT 61h: the shell calls it for unknown commands with `DS:SI` = command and
`DS:DI` = argument. CF=0 means handled; CF=1 lets the kernel print UNKNOWN.

## Build

Requires NASM and Python 3:

```sh
./build.sh
```

Artifacts:

```
build/umix86-360.img   368,640 bytes   full 360 KB boot image (emulator/Gotek)
build/umix86.img        66,048 bytes   boot + kernel area (rawrite/FDIMAGE)
build/kernel.bin        65,431 bytes   kernel inside both images (full 128-sector cap)
archive/versions/umix_version_86_V0R138.img        66,048 B  rawrite/FDIMAGE, versioned
archive/versions/umix_version_86_V0R138_360.img   368,640 B  360 KB floppy, versioned
build/umix.sys          40,472 bytes   copy to C:\UMIX.SYS (BASIC/JCL/DIR/TYPE)
build/tcp.sys            2,816 bytes   copy to C:\TCP.SYS (TCP + HTTP overlay)
build/api.sys           17,452 bytes   copy to C:\API.SYS (JSON API + jobs + chat)
build/chat.sys               1 byte    copy to C:\CHAT.SYS (chat overlay, loads at 0x2900)
```

`umix86.img` is the one to raw-write on a 360 KB DOS machine; `UMIX.SYS` is
copied into the DOS C: root (any 8.3 name works as long as it is `UMIX.SYS`).

## Deploy

1. `RAWRITE2 UMIX.IMG A:` (or FDIMAGE) with the 66,048-byte image.
2. Copy `UMIX.SYS` (36,638 bytes) to `C:\UMIX.SYS` from DOS.
3. Boot from A:. The kernel prints `C: FAT16` (or `12`) and
   `UMIX.SYS LOADED (n BYTES)`; `DIR`, `TYPE`, `JCL` and `BASIC` are then
   available (they live in the overlay).

`SYS` reloads `C:\UMIX.SYS` without rebooting. Host-side tools:
`tools/serial_mux.py` (bridge) and `tools/umix_put.py` (uploader).

## QEMU test with a C: image

`tools/mkfat.py` builds `build/testc.img`: an MBR-partitioned FAT16 disk
(615 cyl × 4 heads × 17 sectors) containing `UMIX.SYS`, `README.TXT`,
`INDEX.HTM`, `JOB.JCL` and the demo `.SYS` files.

```sh
./build.sh && python3 tools/mkfat.py
qemu-system-i386 -machine isapc -m 1M \
  -drive file=build/umix86-360.img,format=raw,if=floppy \
  -drive file=build/testc.img,format=raw,if=none,id=d0 \
  -device ide-hd,drive=d0,cyls=615,heads=4,secs=17 \
  -boot a -display none -serial stdio
```

## Commands

```
* DRIVE M              mount the 64 KB RAM disk (safe, no media)
* DRIVE A              mount A: (insert a data floppy after boot)
* DRIVE B              mount B:
* DRIVE C              mount C: (HDD)
CONSOLE> WRITE ON         enable C: writes (console only; default OFF)
* WHO                 list consoles and their logged-on user
* WHOAMI              current console user (CONSOLE on the CGA)
* LOGOFF              serial console logoff
* CHAT                join the shared chat room (/QUIT to leave)
CONSOLE> PRIV ON|OFF     grant the serial SYSTEM user console commands (default OFF)
CONSOLE> MUX ON|OFF      framed serial multiplexing (CGA only)
* SPEED               measure and print the real CPU clock
CONSOLE> USERS           list user accounts (console, or SYSTEM+PRIV)
CONSOLE> USER ADD|DEL|PASS NAME [PASS]   manage accounts (console, or SYSTEM+PRIV)
CONSOLE> USER SAVE                      write the table (console/SYSTEM+PRIV + WRITE ON)
CONSOLE> USER RESET                     restore the built-in accounts (console/SYSTEM+PRIV)
CONSOLE> QUANTUM 100     scheduler rate (18/50/100/200/500/1000 Hz)
CONSOLE> BAUD 19200      set COM1 rate (2400..38400; restart bridge with --baud)
* BASIC               UMIX BASIC in UMIX.SYS (AUTO, DIM, LOAD/SAVE; SYSTEM exits)
* COPY C:INDEX.HTM M: copy a file; destination drive stays mounted
CONSOLE> WEB ON|OFF      enable/disable the web application (OFF -> 503)
CONSOLE> WEBLOG ON|OFF   log each web request on the CGA panel
CONSOLE> TFTP ON|OFF      guest TFTP server on UDP 69 (console only, default OFF)
* SAVE TEST.TXT       type lines, end with a line containing "."
* DELETE TEST.TXT     remove a file and free its clusters
* MORE ON|OFF|LINES   page all output (ENTER=next, other=stop; chat is never paged)
* RUN HELLO1.SYS !    start a task from C: in the background
* RUN HELLO2.SYS      start a task and wait for it
* PS                  task table: slot, name, app, terminal, user, console, state, segment
* KILL 11             free a program slot (11..12; 0..10 are shells)
* DIR                 list the C: root directory (from UMIX.SYS)
* TYPE README.TXT     print a C: file (from UMIX.SYS)
* EDIT TEST.TXT       full-screen editor (CGA/Hercules)
* JCL JOB.JCL         run a job control script
* SYS                 reload C:\UMIX.SYS
* HELP / ECHO / CLS / MEM / TIME / VER / REBOOT / HALT
```

## Full-screen editor

`EDIT FILE.TXT` opens an existing file or a new 100-line x 80-column buffer on
the CGA/Hercules console. Keys: arrows/Home/End/PgUp/PgDn move, Ins toggles
insert/overwrite, Del and Backspace edit, Enter moves down, Tab inserts four
spaces, Ctrl-N inserts a line, Ctrl-Y deletes a line, F1 saves, F2/Esc quits
(F2 again discards unsaved changes). Saving requires `WRITE ON`. Serial
consoles return `EDIT: CGA CONSOLE ONLY`.

## JCL

`JCL JOB.JCL` runs a small mainframe-style job stream:

```
//MYJOB JOB
//S1 EXEC PGM=DIR
//S2 EXEC CMD='ECHO HELLO FROM JCL'
//S3 EXEC PGM=TYPE,PARM='README.TXT'
// EOJ
```

Lines are uppercased. `PGM=` and `CMD=` steps run through the shell;
`PARM='...'` is appended as an argument. `JOB`, `EXEC`, `EOJ`, comments and
`DD` statements are recognised; other statements are ignored. The job log is
printed as `JOB ... STARTED`, `STEP ...`, `STEP ... RC=0`, `JOB ENDED`.
JCL runs in `UMIX.SYS`, not the kernel: the overlay loads the job stream into
its own 1.5 KB buffer and asks the kernel to execute each step with INT 60h
AH=11. Moving JCL and then BASIC out of the kernel freed about 18 KB;
`kernel.bin` is 57,379 bytes and `UMIX.SYS` 36,638 bytes. The default extension
is `.JCL`, so `JCL JOB` reads `JOB.JCL`.

## Layout

```
A: LBA 0       boot sector (512 B, 0xAA55)
A: LBA 1..128  kernel (max 64 KiB)
A: LBA 700     user table (reserved 512 B sector; not a file)
C:             DOS FAT12 or FAT16 volume; UMIX.SYS in the root
geometry       BPB sectors/track and heads are used for CHS after mount
```

LBA 700 holds the console-managed account table (`'UMXU'`, version 1, count,
8 x 20-byte entries, 16-bit checksum at offset 166). It is read at boot before
the C: fallback and rewritten by `USER`/`USER SAVE`/`USER RESET`. A clean
`build.sh` rewrites the boot image and zeroes that sector, restoring the
built-in accounts. The boot floppy is otherwise read-only; write-protecting it
makes saves go to `C:\USERS.DAT` instead.

The first readable partition entry (type 01/04/06/0E) is used; an
MBR-less (superfloppy) volume is also accepted.

## Limits

- 8088/8086 real mode, 640 KB, 64 KB segments.
- FAT file sizes use the low word (≤ 64 KB per file on disk). The shell `SAVE`
  and `COPY` use a 4 KB buffer; BASIC `SAVE` uses a 4 KB buffer in the overlay;
  the uploader uses an 8 KB buffer. LBA ≤ 65535 (≤ 32 MB disks), root directory
  only, no subdirectories. Writes go to the mounted volume only after
  `WRITE ON`. The boot floppy is read-only except for the reserved user-table
  sector at LBA 700 (`USER`/`USER SAVE`/`USER RESET`); write-protect the floppy
  to prevent that, in which case account saves fall back to `C:\USERS.DAT`.
- Writing is raw INT 13h with no journaling: a failed write (old MFM media,
  power loss) can corrupt the FAT or directory. Back up C: before using
  SAVE/DELETE on real hardware.
- No editor, UBAS/UCOB or RACF. BASIC and JCL run from `UMIX.SYS`.
- The shell busy-polls while idle; that is normal on this minimal build.

## Next steps

1. Subdirectory traversal and a file-size dword.
2. Preemption from the PIT tick (optional) and task priorities.
3. A line editor (arrows/history) and screen paging.

---

# Part II — Serial multiplexer design

Design and implementation notes for the framed serial bridge (`tools/serial_mux.py`).

Status: phase 3 implemented — two framed serial sessions, per-session
login/panel/RX/TX state, and the USER2 account. Phase 1 bridge/codec in
`tools/serial_mux.py`; phase 2 framing/IRQ4/polled RX; phase 3 slots 1..10 are
independent UCS sessions and slots 11..12 are programs (NSLOTS=13). Hardening
and reconnect tests are next.

Goal: two independent UCS shell sessions over one physical serial link, with
users connecting by TCP to a Python bridge.

## 1. Decisions

- 2 simultaneous serial sessions for the first implementation.
- 8250/16450 at 9600 8N1 (no FIFO).
- The Python bridge owns TCP and assigns terminal IDs.
- The guest allocates a session task per OPEN and tags all output with the
  terminal ID.
- The CGA/Hercules console remains the local administration console.
- `DRIVE` and `WRITE` remain system-wide. Login, panel state, and input/output
  buffers are per session.
- Terminal-id 0 system frames are logged by the bridge; broadcasting to all
  clients is optional (`--broadcast-system`).
- The multiplexer is a compile-time build option (`MUX=1`); no runtime `MUX`
  command in the MVP.
- No 16550 is available. The 8250/16450 at 9600 has a one-byte receive register;
  accept possible byte loss during long interrupt-off disk I/O, count overflows,
  and keep the MVP to 2 text sessions.

## 2. Topology

```
 TCP client A ─┐
               ├─ Python bridge ── framed serial ── UMIX/86
 TCP client B ─┘   (TCP server)      (COM1, 9600)     (2 session tasks)
```

The guest never sees TCP. The bridge is the only component that knows about
sockets. It assigns a terminal ID on accept, frames client bytes with that ID,
and routes guest frames back to the matching socket.

Direct Tera Term/socat on COM1 works when the guest is in raw mode (the boot
default, or after `MUX OFF`); it is not usable while framed mode is on. The
bridge can expose a raw single-client mode for compatibility; the guest side
stays framed either way.

## 3. Wire protocol

Length-prefixed binary frames. No escaping; the length delimits the payload, so
STX/ETX may appear inside data.

```
 offset  size  field
 0       1     STX = 0x02
 1       1     TYPE
 2       1     TERMID
 3       1     LEN (0..120)
 4       LEN   PAYLOAD
 4+LEN   1     XOR
 5+LEN   1     ETX = 0x03
```

- Max frame: 126 bytes.
- XOR covers TYPE, TERMID, LEN, and every payload byte.
- STX is the resynchronisation point. On any framing error (bad XOR, bad ETX,
  LEN > 120), drop the frame and return to WAIT_STX; the next STX starts a new
  frame.
- Once TYPE/TERMID/LEN are accepted, consume exactly LEN payload bytes. STX and
  ETX are valid payload values and must not restart the frame. This is why the
  protocol is length-prefixed instead of delimiter-escaped.
- Both sides should reset a partial frame after a short line-idle timeout
  (0.5 s) so a corrupt length cannot wedge the parser until the next reboot.

### Frame types

| Type | Name  | Direction | Payload | Meaning |
|------|-------|-----------|---------|---------|
| 0x01 | DATA  | both      | 1..120  | terminal data |
| 0x02 | OPEN  | bridge→guest | 0   | create session for TERMID |
| 0x03 | CLOSE | bridge→guest | 0   | destroy session for TERMID |
| 0x04 | BUSY  | guest→bridge | 0   | no free session slot |
| 0x05 | ACK   | guest→bridge | 0   | session created / already exists |
| 0x06 | ERROR | both      | 1       | 1 = bad frame, 2 = unknown termid |

### Terminal IDs

- `0` = system/broadcast (guest boot log and system notices). The bridge logs
  these and may broadcast them to all clients.
- `1..2` = user sessions for the MVP.
- `3..254` reserved for a later expansion. `255` reserved.
- The bridge allocates the lowest free ID on TCP accept, sends OPEN, and frees
  the ID on disconnect after sending CLOSE. The guest matches `TERMID` to its
  `task_term[]` array.

### Examples

XOR = TYPE ^ TERMID ^ LEN ^ payload bytes.

```
OPEN  id 1:  02 02 01 00 03 03
ACK   id 1:  02 05 01 00 04 03
BUSY  id 1:  02 04 01 00 05 03
DATA  id 1 "Hi": 02 01 01 02 48 69 23 03
CLOSE id 1:  02 03 01 00 02 03
```

## 4. Guest session model

### 4.1 Slot map

Current V0R23 uses `NSLOTS=5`: slot 0 CGA shell, slot 1 serial shell, slots 2–4
programs. For two serial sessions, use `NSLOTS=7`:

| Slot | Use | task_seg | task_stk | task_in | task_out |
|------|-----|----------|----------|---------|----------|
| 0 | CGA shell | 0x1000 | 0 (kernel stack) | 0 | 0 |
| 1 | serial session A | 0x1000 | 0x6000 | 1 | 1 |
| 2 | serial session B | 0x1000 | 0x6100 | 1 | 1 |
| 3 | program | 0x3000 | 0x6200 | inherited | inherited |
| 4 | program | 0x4000 | 0x6300 | inherited | inherited |
| 5 | program | 0x5000 | 0x6400 | inherited | inherited |
| 6 | program | 0x9000 | 0x6500 | inherited | inherited |

Kernel stack remains at `STACK_SEG=0x8000`. Slot 6 uses 0x9000 to avoid
overlapping the 0x6000–0x6500 stack area; 0x9000:0000 is inside 640 KB.

`NSLOTS=7` requires resizing every task array and `shellbuf` from 320 bytes to
`NSLOTS*160` (1120 bytes). `spawn_shell1` becomes `spawn_session(slot, termid)`.
The shell buffer is selected as `shellbuf + cur_task*160` instead of the
current 0/160 hard-coding.

### 4.2 New per-session state

Replace the current globals with arrays indexed by slot:

| V0R23 global | New form |
|--------------|----------|
| `serial_user times 16` | `serial_user times NSLOTS*16` |
| `ser_panel db` | `ser_panel times NSLOTS db` |
| `sp_cleared db` | `sp_cleared times NSLOTS db` |
| `pin_len db` | `pin_len times NSLOTS db` |
| `pin_col db` | `pin_col times NSLOTS db` |
| `shellbuf times 320` | `shellbuf times NSLOTS*160` |
| — | `task_term times NSLOTS db` |
| — | `rx_head/rx_tail times NSLOTS db` |
| — | `rx_buf times NSLOTS*64 db` |
| — | `tx_len times NSLOTS db` |
| — | `tx_buf times NSLOTS*128 db` |

`prow`/`pcol` stay CGA-panel globals because the serial panel uses ANSI
positioning, not the CGA panel cursor.

Programs launched with `RUN` inherit both `task_out` and `task_term`, so their
`putc` output is framed for the console that started them.

### 4.3 Session lifecycle

- OPEN(termid):
  - Find a free serial slot (1 or 2) that has `task_state=0`.
  - If none: send BUSY(termid).
  - Else: set `task_term[slot]=termid`, `task_out[slot]=1`, `task_in[slot]=1`,
    clear `serial_user[slot]`, `ser_panel[slot]`, `sp_cleared[slot]`,
    `pin_len/col[slot]`, RX/TX queues, and create the task with
    `spawn_session(slot, termid)`.
  - Send ACK(termid).
- Duplicate OPEN for an existing termid: send ACK (idempotent).
- CLOSE(termid):
  - Find the slot whose `task_term` matches.
  - Set `task_state[slot]=0`, clear `task_term[slot]`, and reset its state.
  - If the session task is blocked in `getchar`, it is never scheduled again.
- Session task entry:
  - Print the login banner and call `serial_login` with the current slot's
    `serial_user`.
  - On login success, log `COM1 T<n> LOGON <user>` on the CGA console.
- On guest reboot, all session state is reinitialised; the bridge should see
  the serial line go quiet and re-open sessions on reconnect.

### 4.4 Commands and output

- `WHO`: list each active serial session with terminal ID, user, and `COM1`.
- `WHOAMI`: use `serial_user[cur_task]`.
- `LOGOFF`: only on slot 1/2; log off that session and return to its login
  prompt.
- `PANEL`: use `ser_panel[cur_task]`; serial sessions default to OFF (plain).
- `PS`: add the terminal ID for serial task slots.
- `LOGON/LOGOFF` logs: include the terminal ID (`T1`, `T2`).
- The CGA editor remains CGA-only. A serial session that runs `EDIT` gets
  `EDIT: CGA CONSOLE ONLY`.
- BASIC, JCL, DIR/TYPE, SAVE, and RUN output route through `putc`, so they are
  automatically framed for the current session.

## 5. Guest receive path

Polling in `getchar` is not sufficient: a session running a command (or the
kernel doing disk I/O) would not drain the UART, and the 8250 has a one-byte
receiver. Use IRQ4.

### 5.1 Initialisation

- COM1 at 0x3F8 uses IRQ4.
- Set IER (0x3F9) bit 0 = receive-data-available.
- Unmask IRQ4 in the 8255 PIC: read 0x21, clear bit 4, write 0x21.
- Hook INT 0Ch (IRQ4) to `int0c_serial`.
- Default 9600 8N1 (divisor 12; runtime `BAUD` 2400..38400 changes it), no
  FIFO (FCR=0). If a 16550 is fitted later,
  enable the FIFO (FCR=0xC7) and drain it via IIR in the ISR.

### 5.2 IRQ4 ISR

```
int0c_serial:
    push all registers
    DS = ES = KERNEL_SEG
    read RBR (0x3F8)
    feed mux_byte(al)
    EOI (out 0x20, 0x20)
    pop all
    iret
```

Rules:

- No BIOS calls, no `putc`, no task switching.
- `mux_byte` is the frame state machine: WAIT_STX, TYPE, TERMID, LEN, PAYLOAD,
  XOR, ETX.
- On a complete DATA frame: map TERMID to a slot by scanning `task_term[]`;
  enqueue the payload into that slot's 256-byte RX ring. If full, drop the byte
  and increment `rx_overflow[slot]`.
- On OPEN: set `mux_open_pending = termid`.
- On CLOSE: set `mux_close_pending = termid`.
- Ignore DATA for an unknown termid.

### 5.3 RX queues and `getchar`

- The session shell's `getchar` reads from `rx_buf[slot]` when `task_in=1`.
- If the queue is empty, it yields and retries. The IRQ fills the queue in the
  background.
- `mux_poll` (main context, called from `getchar`) handles pending OPEN/CLOSE:
  creates or kills the session task and sends ACK/BUSY.
- `getchar` must flush the current slot's TX buffer before blocking, so the
  prompt appears promptly.

### 5.4 RX overflow and disk I/O

The 8250/16450 has no FIFO. The kernel performs polled INT 13h disk I/O; the
BIOS may disable interrupts for several milliseconds. At 9600, one byte arrives
every ~1 ms, so a long disk operation can drop input.

Mitigations for the MVP:

- Keep the RX ring at 256 bytes and count overflows; expose the counter in a
  debug command or log it to the CGA console.
- The bridge sends only user keystrokes, not bulk data, unless the user pastes.
- Accept occasional dropped characters during disk I/O.
- Plan a 16550 FIFO upgrade for heavy use.

## 6. Guest transmit path

`ser1` currently polls THRE and writes one byte. In framed mode:

- `ser1` appends to `tx_buf[cur_task]` when `task_term[cur_task] != 0`.
- Flush (send a DATA frame) on newline, when the buffer would exceed 120
  bytes, at the end of a panel draw, and before `getchar` blocks.
- `mux_flush(slot)` sends STX, DATA, termid, len, payload, XOR, ETX and polls
  THRE per byte. It is synchronous; the timer may preempt between bytes, but
  the per-slot buffer keeps other sessions' output separate.
- Term 0 (system/boot messages) uses a separate system buffer and flushes as
  DATA termid 0. The bridge logs or broadcasts these.
- A compile-time `MUX=0` build keeps the current raw serial behaviour for
  debugging. The bridge must match the mode.

At 9600, a 120-byte payload costs 126 bytes on the wire (~131 ms). A full
screen redraw (~2000 bytes) takes ~2 s; the serial panel defaults to off and
should stay off unless a user asks for it.

## 7. Python bridge

The bridge is a TCP server plus a serial framer. It owns:

- Serial frame encode/decode and resynchronisation.
- Terminal ID allocation/freeing.
- TCP accept/close, per-client buffers, and backpressure.
- Session state: `id -> (reader, writer, opened)`.
- Optional raw single-client mode (TCP bytes are framed to term 1; no framing
  is exposed to the client).

### 7.1 Skeleton

```python
import asyncio, struct, serial

STX, ETX = 0x02, 0x03
DATA, OPEN, CLOSE, BUSY, ACK, ERROR = 1, 2, 3, 4, 5, 6

def frame(t, tid, payload=b""):
    body = bytes([t, tid, len(payload)]) + payload
    x = 0
    for b in body:
        x ^= b
    return bytes([STX]) + body + bytes([x, ETX])

class Decoder:
    # WAIT_STX/TYPE/TERMID/LEN/PAYLOAD/XOR/ETX state machine; yield frames
    ...

class Bridge:
    def __init__(self, port, baud, max_sessions=2):
        self.ser = serial.Serial(port, baud, timeout=0.1)
        self.clients = {}          # tid -> (reader, writer)
        self.opened = set()
        self.next_id = 1
        self.max_sessions = max_sessions
        self.wlock = asyncio.Lock()

    def alloc_id(self):
        for tid in range(1, self.max_sessions + 1):
            if tid not in self.clients:
                return tid
        return None

    async def serial_reader(self):
        dec = Decoder()
        while True:
            data = await asyncio.to_thread(self.ser.read, 256)
            for t, tid, payload in dec.feed(data):
                if t == DATA:
                    if tid == 0:
                        log_system(payload)
                    elif tid in self.clients:
                        self.clients[tid][1].write(payload)
                        await self.clients[tid][1].drain()
                elif t == ACK:
                    self.opened.add(tid)
                elif t == BUSY:
                    await self.drop_client(tid, "no session slot")
                elif t == CLOSE:
                    await self.drop_client(tid, "session closed")

    async def handle_client(self, reader, writer):
        tid = self.alloc_id()
        if tid is None:
            writer.write(b"UMIX: no serial session available\r\n")
            await writer.drain()
            writer.close()
            return
        self.clients[tid] = (reader, writer)
        async with self.wlock:
            self.ser.write(frame(OPEN, tid))
        try:
            while data := await reader.read(256):
                for i in range(0, len(data), 120):
                    async with self.wlock:
                        self.ser.write(frame(DATA, tid, data[i:i+120]))
        finally:
            async with self.wlock:
                self.ser.write(frame(CLOSE, tid))
            self.clients.pop(tid, None)
            writer.close()
```

Implementation notes:

- Use `pyserial-asyncio` or a dedicated serial writer thread so blocking
  `serial.write` does not stall the event loop.
- Serialise all serial writes with one lock; both client DATA and control
  frames share the line.
- Apply TCP backpressure with `writer.drain()` and bounded per-client queues.
  A slow client must not block the other session or the serial reader.
- Log frame errors and overflow; optionally close the offending client.
- Authentication is the guest's `USERID/PASSWORD` login. Do not add a bypass.
  Optionally bind the TCP listener to localhost or wrap it with TLS.
- Config: `--serial`, `--baud 9600`, `--listen 0.0.0.0:2323`,
  `--max-sessions 2`, `--raw`.

## 8. Error handling

| Event | Action |
|-------|--------|
| Bad XOR / bad ETX / LEN > 120 | Drop frame, reset parser, count error |
| STX during a frame | Restart frame at this STX |
| OPEN with no free slot | BUSY; bridge reports busy and closes the client |
| Duplicate OPEN | ACK, keep the existing session |
| CLOSE for unknown termid | Ignore |
| DATA for unknown termid | Drop, count |
| RX ring full | Drop byte, increment overflow counter |
| Session task killed externally | Guest should send CLOSE for that termid; bridge closes the client |
| Serial disconnect / reboot | Bridge logs, closes all clients, retries the port |

## 9. Testing plan

1. Frame codec unit tests: encode/decode all types, XOR, corrupt frames,
   resync after garbage, max payload.
2. Bridge loopback: fake guest that echoes frames; two TCP clients; verify ID
   allocation, OPEN/ACK, routing, CLOSE, and ID reuse.
3. QEMU: expose COM1 as a Unix socket
   (`-chardev socket,...,server=on,wait=off -serial chardev:...`), run the
   bridge against it. Connect two `nc` clients; each logs in separately.
4. Guest tests: two sessions run `DIR`, `ECHO`, `BASIC`, `JCL`; verify output
   isolation and CGA admin console independence.
5. Disconnect/reconnect stress: IDs reused, no ghost tasks in `PS`.
6. Load: paste text into one client; measure RX overflow counters and keystroke
   latency at 9600.
7. Real hardware: null-modem/USB serial at 9600; two TCP clients; verify
   login, panel off/on, `WHO`, `PS`, `KILL`, and that the CGA editor still
   works.

## 10. Risks and limitations

- 8250/16450 has no RX FIFO. Disk I/O with interrupts disabled can drop bytes.
  This is the main hardware risk. A 16550 with FIFO is the long-term fix.
- 9600 baud is shared by all sessions. Full-screen panel redraws are slow; serial
  sessions default to plain mode.
- The per-session refactor touches many globals. It must be done in one
  coherent change; partial migration will cause cross-session leakage.
- Task-slot and memory-map changes can affect `RUN`, `PS`, and program slots.
- The editor remains CGA-only. An ANSI full-screen editor is out of scope.
- `DRIVE` is global. `WRITE ON|OFF` is now **console-only** (like `MUX`): it
  enables/disables C: writes for the whole system and serial sessions get
  `WRITE: CONSOLE ONLY`. Per-session write gating remains future work.
- The bridge and guest must run matching protocol versions; a raw mode is kept
  for recovery.

## 11. Phased implementation

1. **Protocol + bridge skeleton** (no kernel change): codec, TCP server, fake
   guest loopback, frame tests. **Done** — `tools/serial_mux.py`,
   `tools/test_serial_mux.py` (18 tests).
2. **Single framed session** (slot 1): TX framing, IRQ4 RX parser, OPEN/CLOSE,
   login over framed serial. Acceptance: one TCP client gets a UCS session;
   CGA unaffected. **Done (V0R24)** — `MUX=1`, per-slot 128-byte TX buffers,
   256-byte RX ring, OPEN/ACK/BUSY/CLOSE, session restart on reconnect.
3. **Two sessions**: NSLOTS=7, per-session state arrays, session tasks, WHO/PS,
   logon/logoff with IDs. Acceptance: two clients logged in simultaneously with
   isolated input/output. **Done (V0R44)** — slots 1..10 are serial sessions,
   slots 11..12 are programs; per-slot login/panel/RX/TX; verified with ten
   concurrent logged-on clients, chat fan-out and private messages.
4. **Hardening**: BUSY/ACK handling, overflow counters, reconnect stress, real
   hardware at 9600.
5. **Optional**: 16550 FIFO, higher baud, 4 sessions, per-session DRIVE/WRITE,
   ANSI editor.

### Phase 3 correctness fixes (V0R44)

Two concurrency bugs made a serial session occasionally execute the *previous*
command, or appear to swallow the first command after login:

- **`mux_poll` did not preserve the caller's registers.** It is called from
  `getchar`, and the shell read loop keeps the write pointer in `DI` and the
  line length in `CX` across keystrokes. When an OPEN/CLOSE was processed
  mid-line, `session_reset_slot` left `DI` pointing into `login_pass`, so
  subsequent characters were stored there and `execute` re-ran the stale line.
  `mux_poll` now saves/restores `AX BX CX DX SI DI BP DS ES`.
- **`spawn_session` / `RUN` switched `SS:SP` to the new task's stack while
  `cur_task` still named the spawning task.** A timer tick in that window
  saved the half-built frame as the spawning task's context, corrupting it.
  The construction is now bracketed with `pushf/cli` + `crit`; console fields
  are published before `task_state`, and the task is marked runnable last.

All `INT 10h` calls now go through a `bios_video` wrapper that preserves
`DS/ES/BP/DI`. Some BIOSes (notably real Hercules/MDA ROMs) clobber them; since
the CGA panel is drawn from the serial session's context on logon, a clobbered
`ES` sent the next typed command to `B800:DI` instead of the command buffer —
the "first command after login is silent" symptom.

Verified on QEMU: two framed sessions, 16 connect/login/command cycles with a
concurrent second session, `PANEL ON|OFF`, `RUN HELLO1.SYS`, and the bridge's
18 unit tests.

### System message header (V0R44)

Console event output is prefixed with `** SYSTEM MESSAGE: `. This covers
logon/logoff log lines (`** SYSTEM MESSAGE: COM1 LOGON SYSTEM`) and the
console-only `MUX` / `WRITE` responses and errors. `sys_begin` prints the
header and preserves `SI`, so existing `mov si, msg / call puts` sites keep
working.

### SYSTEM user privilege (V0R48)

`PRIV ON|OFF` is a console-only command, default **OFF**. It grants the serial
**SYSTEM** account the console commands: `WRITE`, `QUANTUM`, `USER`, `USERS`,
`CHAT ON|OFF` and `/BAN`. The console always has them; other serial users never
do (`...: CONSOLE ONLY`). A serial SYSTEM session while OFF gets
`SYSTEM PRIV OFF - ASK THE CONSOLE`. `MUX` stays console-only regardless
(toggling framing from the serial side would cut the session's own link).

### Runtime toggle (V0R44)

The framer is **off at boot**: `mux_mode` starts at 0 and slot 1 runs the raw
COM1 console, so a single Tera Term / `socat` connection works without the
bridge. `MUX ON|OFF` is a console-only shell command:

- `MUX ON` installs the INT 0Ch handler (`mux_hw_on`), enables the UART RX
  interrupt and unmasks IRQ4, stops the raw slot-1 shell, and lets the next
  framed OPEN claim slot 1.
- `MUX OFF` refuses while a framed session is active (`task_term != 0` on
  slots 1/2); otherwise it clears `mux_mode`, disables UART interrupts
  (`mux_hw_off`), masks IRQ4, resets the mux state and restarts the raw slot-1
  shell.
- `MUX` with no argument prints the current mode.
- Any non-console session gets `MUX: CONSOLE ONLY`.

`serial_init` now calls the same `mux_hw_on` helper, so there is one place that
installs the IRQ4 receiver.

### User accounts (V0R46)

Serial logon no longer compares against hard-coded strings: the kernel keeps an
8-entry table (`user_tab`, 10-byte name + 10-byte password per entry,
`user_cnt`). It boots with SYSTEM/SYS1, USER/USER and USER2/USER2 and is edited
from the CGA console only:

```
USERS                     list
USER ADD name pass        add (max 8 chars each)
USER PASS name newpass    change password
USER DEL name             delete (the last account is protected)
```

`serial_login` upcases the typed name and password, finds the name with
`user_find`, and compares against the entry's password.

Managing the table (`USERS`, `USER ...`) is done from the console, or from a
serial SYSTEM session when `PRIV ON`; other serial sessions get
`USER: CONSOLE ONLY`.

The table is stored in the same 166-byte image in **two places**:

```
offset 0   'UMXU'
offset 4   version 1
offset 5   count (1..8)
offset 6   8 x 20 bytes (10-byte name + 10-byte password, zero padded)
total 166 bytes
```

1. **Reserved sector on the boot floppy**: LBA 700 (the boot image is 720
   sectors; LBA 0 is the boot sector and 1..128 hold the kernel). It is read and
   written with BIOS `INT 13h`, using the 360 KB geometry (9 sectors/track,
   2 heads) that `boot.asm` also assumes and the boot drive captured from DL at
   kernel entry. A 16-bit checksum at offset 166 guards the sector. It is not a
   file, so `DIR` does not show it.
2. **`USERS.DAT`** (same 166 bytes) in the root of the mounted volume
   (C:\USERS.DAT at boot), written through `write_file`.

`users_load` runs after `fat_mount`: it tries the floppy sector first
(magic/version/count/size/checksum) and falls back to the file. `users_save`
writes the floppy sector and the C: file (whichever are writable) after every
ADD/DEL/PASS and for `USER SAVE`; `USER RESET` restores the defaults first.
Saves are gated by `WRITE ON` (otherwise `NOT SAVED (WRITE ON)`). Status codes:
0 = floppy saved, 8 = C: file only (e.g. write-protected floppy), 7 = floppy
write failed and no C:, 2 = no writable store. Passwords are plaintext. If both
stores are absent/corrupt, the built-in SYSTEM/USER/USER2 defaults are used.
Serial sessions that try `USER`/`USERS` get `USER: CONSOLE ONLY`.

A clean `build.sh` rewrites the boot image and therefore zeroes LBA 700,
restoring the built-in accounts. Write-protecting the boot floppy does not
prevent loading the table; it makes `users_save` fall back to the C: file
(status 8).

### HTTP probes

On connect the bridge sniffs the first chunk (100 ms). If it looks like HTTP
(request line with `HTTP/`, or leading `Host:`/`User-Agent:` headers) the bridge
replies:

```
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Connection: close

UMIX/86 is available only through an interactive serial session.
```

and closes the connection **without sending OPEN** — the guest never sees the
probe and no session slot is consumed. A normal terminal that sends nothing
during the sniff window simply proceeds after the timeout; any bytes received
during the sniff are fed to the guest exactly once.

### Debug input logging

At `--log-level DEBUG` each TCP client's input is accumulated and the completed
line is logged when Enter arrives:

```
DEBUG tcp tid=1 input: b'SYSTEM'
```

CR and LF both end a line, CRLF is logged once, backspace (0x08/0x7F) edits the
buffer, and the accumulated line is capped at 256 bytes. With `--telnet` the
logged text is the post-IAC-filtered payload (what the guest receives). The log
includes anything typed at a password prompt, so treat DEBUG logs as sensitive.

### Telnet clients (V0R44)

The bridge is a raw TCP server by default. A telnet client sends IAC
negotiation (`FF FB/FC/FD/FE ...`, `FF FA ... FF F0`) whose option bytes can
be printable (0x20, 0x23, 0x27), so they cannot be filtered safely inside the
guest. Add `--telnet` and the bridge:

- runs a per-client IAC state machine and **strips all negotiation** before
  framing the payload for the guest;
- on the first IAC sends `IAC WILL ECHO` and `IAC WILL SGA`, telling the client
  that the guest echoes (so the client disables local echo — otherwise every
  typed character appears twice, and passwords are shown in clear);
- replies to `DO`/`WILL` (WILL/DONT, accepting ECHO/SGA/BINARY as appropriate)
  so clients stop waiting;
- doubles `0xFF` in guest output (telnet escaping).

Client echo settings (the guest always echoes; the client must not):

- PuTTY: Terminal -> Local echo: Force off, Local line editing: Force off.
- Tera Term: Setup -> Terminal -> uncheck Local echo.
- Windows telnet: `unset localecho`; line mode may still show the line locally.
- `nc`: the local tty echoes; run `stty -echo` around it, or use a raw client
  with local echo off.

`WILL ECHO`/`SGA` cannot override a client that forces local echo or line
editing; in that case the typed line appears once locally and again when the
server echoes it after Enter.

Independently, V0R44's `getline_char` normalises line input for every reader:
CRLF is treated as one Enter, LF-only also ends a line, and bytes >= 128
(IAC) are ignored. That fixes telnet/CRLF clients even in raw mode, but the
IAC option bytes still need `--telnet` to be stripped properly.

### Multiple TCP listeners (V0R44)

The bridge can front the same framed serial link with more than one listener:

- `--listen HOST:PORT` is repeatable. Every pooled listener feeds the same
  terminal-ID pool, so a client on any port gets the next free ID.
- `--listen-fixed HOST:PORT,TID` binds a listener to a specific terminal ID
  (e.g. `127.0.0.1:2325,3`). A second simultaneous client on that port is
  refused with `UMIX: terminal N is in use`; the port is reusable after the
  first disconnects.
- `Bridge.ports` exposes all bound ports (used by the tests); the first is
  also `Bridge.port` for compatibility.

Verified with two pooled ports and one fixed port on one serial link: isolated
echoes, `WHO` seeing two then three COM1 sessions, fixed-port busy/reuse.

### Panel scrollback (V0R44)

The CGA/Hercules panel keeps a 128-line history ring in the free segment
`0x5000` (128 × 80 bytes). `panel_putc` appends characters to `ph_cur` and
commits a line on LF or on 80-column wrap (`panel_commit`, ring index
`total & 127`). `panel_render` reconstructs the 21-row output window from
committed lines plus the current line.

- `PgUp`/`PgDn` adjust `ph_view` by 20 lines, clamped to `total-21`; the BIOS
  keyboard scan codes are 0x49/0x51 and are consumed inside `getchar`.
- Any other key calls `panel_live_if_hist` (view=0 + redraw) before returning,
  so typing always operates on the live screen.
- `CLS` and `PANEL ON` call `panel_init`, which resets the ring.
- `panel_putc` suppresses live drawing while `ph_view != 0`, so new output is
  recorded in the ring without disturbing the page being viewed.

### Scheduler rate (V0R44)

`QUANTUM` (console, or serial SYSTEM with `PRIV ON`) reprograms PIT channel 0. Divisor `= 1193182 / Hz`;
18 Hz (divisor 65536) is the boot default, so existing timing is unchanged.
`tick_div` (0 means 65536), `tick_hz` and `mux_idle` are kept in sync:

- `mux_poll` now compares against `[mux_idle]` (Hz/2 ticks = ~0.5 s) instead of
  the hard-coded `9`, so higher rates do not shorten the partial-frame timeout.
- `measure_cpu` uses `F100 = N*2148/tick_div` (or `N*100/3051` for the 18 Hz
  divisor-0 case), so `SPEED` is correct at every rate.
- `INT 60h AH=0` returns raw ticks at the selected rate; programs that assume
  18.2 Hz (e.g. `SPIN.SYS`) run faster at higher rates.

Quantum is wall-clock, CPU speed is cycles per quantum:

| tick | divisor | quantum | cycles @4.77 | cycles @9.54 | switch overhead @4.77 |
|---|---|---|---|---|---|
| 18 | 65536 | 54.9 ms | 262,144 | 524,288 | ~0.15 % |
| 50 | 23864 | 20.0 ms | 95,455 | 190,909 | ~0.42 % |
| 100 | 11932 | 10.0 ms | 47,727 | 95,455 | ~0.84 % |
| 200 | 5966 | 5.0 ms | 23,864 | 47,727 | ~1.7 % |
| 500 | 2386 | 2.0 ms | 9,546 | 19,091 | ~4.2 % |
| 1000 | 1193 | 1.0 ms | 4,773 | 9,546 | ~8.4 % |

The PC20-III modes (4.77/7.16/9.54 MHz) change cycles per slice and the
wall-clock switch cost (84/56/42 µs), not the tick rate. `SPEED` is
independent of `QUANTUM` because it divides by the live `tick_div`. See the
README section “Quantum, CPU speed and overhead” for the broader comparison
with modern CPUs.

### UART OUT2 fix (V0R44)

`serial_init` used to set MCR = 0x03 (DTR|RTS). On a real 8250/16450/16550 the
**OUT2 (MCR bit 3)** signal gates the interrupt line to the ISA bus; with OUT2
clear the UART never asserts IRQ4, so framed RX never fires even though raw
polled TX/RX works. QEMU does not enforce this, which hid the bug in emulation.
V0R44 sets MCR = 0x0B (DTR|RTS|OUT2) in `serial_init` and again in `mux_hw_on`.

### Measured CPU clock (V0R44)

`SPEED` (and the boot banner) measure the real clock instead of assuming
4.77 MHz. The routine runs a `DEC CX/JNZ` loop (18 clocks per iteration on
8086/8088) for one **current** 8253 tick and computes, with `N` iterations and
the live divisor `tick_div` (`0` means 65536):

```
F100 = N * 2148 / tick_div      ; general, result in MHz*100
F100 = N * 100 / 3051           ; 18 Hz case (divisor 0)
```

At the 18.2 Hz default that is one 54.9254 ms window; at 100 Hz it is a 10 ms
window with correspondingly fewer iterations, so the measured MHz is the same.

`crit` is held during the loop, so IRQ0 still increments `ticks` but no task
switch happens. At 18 Hz the 16-bit iterator covers up to ~21 MHz; shorter
quanta raise that limit. On an emulator (QEMU) it overflows and the line
reports `N/A (TOO FAST)`, which is expected because QEMU is not
cycle-accurate. On a Commodore PC20-III the
BIOS-selected 4.77/7.16/9.54 MHz modes are reported correctly; `SPEED -D`
(or Ctrl+Alt+D) selects 9.54 MHz, then UMIX `SPEED` re-measures.

### Ten serial sessions (V0R44)

`MAXSER equ 10`, `NSLOTS equ MAXSER+3`. Slot 0 is the CGA shell, 1..10 are
serial sessions, 11..12 are program slots. Task stacks run 0x6000..0x6B00
(4 KB each) and stop below the 0x7000 RAM disk. All per-slot arrays scale with
`NSLOTS` (`task_sp`, `task_ss`, `task_state`, `rx_*`, `tx_*`, `login_*`,
`serial_user`, chat state). The mux OPEN/CLOSE scan, `WHO`, `LOGOFF` and chat
loops use `MAXSER`. `RUN` starts at slot `MAXSER+1` so programs never take a
serial slot, and `KILL` accepts program slots 11..12. The bridge default is
`--max-sessions 10`.

### Output pager (V0R48)

`MORE ON|OFF|LINES` (per session, default OFF/20) pages command output —
`HELP`, `DIR`, `TYPE`, … — after N lines. The kernel's putc hook prints
`-- MORE -- (ENTER=CONTINUE, OTHER=QUIT)` and waits through the same
CRLF-aware `getline_char` used by the shells, so a terminal that ends ENTER
with CR+LF consumes the pair as one key instead of continuing immediately.
ENTER continues; any other key turns paging off for that session. Live chat
output is flagged `pager_bypass` and is never paged, so a pager prompt can
never swallow a chat keystroke. The counter is reset at each shell prompt and
the pager is fully register-transparent, so it does not disturb the command
that is printing. `MORE` with no argument shows the state; `MORE 0` is OFF.

### EDIT over serial (V0R50)

`EDIT` no longer refuses a serial session. The editor keeps one screen model and
two renderers:

- keys: `ed_getkey` reads `INT 16h` on the console and `getchar` on a serial
  session, so the ANSI decoder's BIOS-style scan codes (`0x48` up, `0x50` down,
  `0x4B/0x4D` left/right, `0x49/0x51` PgUp/PgDn, `0x47/0x4F` Home/End, `0x52/0x53`
  Ins/Del) drive the same key handlers.
- screen: `ed_char`, `ed_draw_line`, `ed_fill_row`, `ed_clear_screen` and
  `ed_cursor` branch on the session. Serial sessions get `ESC[row;colH`, `ESC[2J`
  and `ESC[7m` for the inverse status line; the console keeps writing to
  `B000`/`B800`.
- autowrap is disabled on entry (`ESC[?7l`) and restored on exit (`ESC[?7h`), so
  an 80-column line cannot scroll the screen.
- columns past 80 are dropped on the serial path; the CGA path silently wrapped
  into the next row, which produced coordinates like `ESC[1;129H` on a terminal.

### IP channel (V0R50, plumbing)

The multiplexer reserves **terminal id `0xFE`** for raw IP traffic, so a network
stack can share the link with console, web and upload sessions instead of
taking the port over (as SLIP would).

Stage 1 shipped: `mux_dispatch` routes term `0xFE` to a dedicated path. The
payload is copied to `ipbuf` and marked pending; `ip_tx_flush`, called from
`mux_poll`, sends it with `mux_send_frame(0x01, 0xFE, ipbuf, len)`. It currently
**echoes**; that proves routing and the transmit path before any IP code exists.

**The reply must never be sent from the ISR.** `mux_dispatch` runs inside the
IRQ4 handler, and `mux_send_frame` polls THRE for the whole frame - at 9600 baud
that is ~1 ms per byte, so a 120-byte reply would block the interrupt for
~125 ms. QEMU hides this because the emulated UART is instant. Hence the
copy-and-defer: the ISR only moves <=128 bytes, and a task sends it.

Verified by injecting `STX 01 FE 08 "HELLO-IP" XOR ETX` into a mux-enabled boot
and receiving the same frame back.

Next: IPv4 header parse/checksum, ICMP echo reply, then UDP and a minimal TCP
client. Host side will open a TUN device in `serial_mux.py` and forward those
frames (needs `CAP_NET_ADMIN`).

*Superseded by V0R52 below: the stack and the host side are implemented; TUN
was replaced by a portable UDP relay.*

### Serial panel escape handling (V0R50)

The serial panel is drawn with ANSI sequences: `ESC[2J ESC[H` (clear),
`ESC[row;colH` (cursor addressing, clamped so a coordinate is never 0),
`ESC[3;23r` (scroll region for the log), `ESC[1;37;44m` / `ESC[32m` / `ESC[0m`
(colours) and `ESC[2K`.

`PANEL ON` also emits `ESC[?7l` to disable autowrap and `PANEL OFF` restores it
with `ESC[?7h` plus `ESC[r`, which resets the scroll region. Without those two,
writing the 80th column wrapped the cursor and scrolled the whole panel, and the
3-23 scroll region leaked into normal shell output after leaving panel mode.
Row content is written as 79 columns plus `ESC[K`, so the last column is never
touched.

The panel needs an **80x25** terminal; Tera Term's default 24 rows will scroll
when the OIA line (row 25) is drawn.

### Versioned images (V0R50)

`tools/mkimage.py` reads the release string from `src/kernel.asm` (the `V0Rn`
token) and, in addition to the usual `umix86.img` / `umix86-360.img`, writes a
copy that can never be clobbered by a later build:

```
archive/versions/umix_version_86_V0R138.img        66,048 bytes   rawrite / FDIMAGE
archive/versions/umix_version_86_V0R138_360.img   368,640 bytes   360 KB floppy
```

Bump the version in the sources and the next build produces a new pair, so
each release keeps its own image.

### Kernel buffers moved out of the kernel segment (V0R50)

The kernel must fit below `SYS_SEG = 0x2000`, and its three large buffers were
consuming almost all of that window. `upbuf` (8 KB, the upload staging area)
now lives in **`BUF_SEG = 0x6C00`**, a 16 KB window between the task stacks
(`0x6000-0x6BFF`) and the RAM disk (`0x7000`).  TFTP's 768-byte window buffer
(`tf_wdata`) uses the second half at **`TFBUF_SEG = 0x6E00`**; the rx/tx
buffers stay in the kernel because the parser and `udp_build_src` address
their data with `DS:SI`.

`write_file` takes the source as an offset plus `sv_src_seg`, so a buffer can be
in either segment:

```
sv_src     = offset within the source segment
sv_src_seg = KERNEL_SEG (default) or BUF_SEG
```

That freed 8,136 bytes: kernel free space went from 520 to 8,656 bytes.
`savebuf` (4 KB) and `fat_buf` (512 B) are still in the kernel window and can
follow the same pattern.

### Boot startup script (V0R50)

`C:\STARTUP.JCL` is a plain text file, one command per line, executed once at
boot: after `UMIX.SYS` loads and before the first prompt. Blank lines and lines
starting with `;`, `#` or `//` are comments; leading and trailing spaces are
trimmed. Each line goes through the normal command dispatcher, so kernel
commands work without any session: `MUX ON`, `WRITE ON`, `BAUD 9600`, `WEB ON`,
`PRIV ON`.

Because it runs **before** the boot mux check, `MUX ON` in the startup file
suppresses the raw serial shell on slot 1 exactly as if it had been typed at
boot time — the machine comes up already owning COM1 in framed mode. A missing
`STARTUP.JCL` is silently ignored, and the file is read only once (the
`startup_done` flag survives `jmp shell`).

Limits: 511 bytes total, 120 characters per line. If the file is found, the
kernel prints `STARTUP.JCL` before running it, so boot output shows whether it
was picked up.

```
; UMIX/86 boot script
; lines starting with ';' '#' or '//' are comments
MUX ON
WRITE ON
BAUD 9600
WEB ON
```

### Transfer mode (V0R50)

A minimal boot mode that uses COM1 purely as a byte pipe, for machines where
timing makes the framed mux impractical. With one floppy drive the workflow is:
boot from the boot floppy, pull it out, insert a data floppy, receive files.

```
COM1 at boot:  BOOT MODE: [N]ORMAL [T]TRANSFER (11s)
               press T within 11 s, anything else (or silence) boots normally
CGA:           REMOVE BOOT DISK, INSERT DATA DISK, PRESS ENTER
CGA:           VOLUME OK            (or: NOT A FAT VOLUME - FORMAT (Y/N)?)
CGA:           FILE NAME:           <- typed on the PC keyboard
CGA:           READY - SEND FILE NOW
Tera Term:     Send File, BINARY mode
8 s idle:      directory entry written, CGA prints  OK <n> BYTES
CGA:           FILE NAME:           <- next file; blank = continue normal boot
```

Properties:

- **No sessions are spawned** in transfer mode, so nothing else reads COM1.
  There is no framing, no checksum and no retransmit: Tera Term's own pacing
  (transmit delay) is the only flow control, which is the point of the mode.
- Files stream to disk in 512-byte sectors through `recv_newcluster`, so there
  is no 8 KB buffer limit. Cluster allocation happens *before* `secbuf` is
  filled, because `fat_set` reuses `secbuf` for the FAT sector.
- End of file is an **8-second idle gap** (~150 ticks at 18 Hz).
- The FAT sector is cached (`fat_fill`/`fat_buf`). Without it, every cluster
  lookup re-read the FAT from the floppy (~30 ms each), so `alloc_cluster`'s
  sequential scan and `free_chain` (4-5 sector I/Os per cluster) made the pause
  between the filename and `READY` take seconds to minutes. With one cached
  sector a sequential scan of a 1.44 MB FAT costs a handful of reads instead of
  ~2800.
- COM1 is received by an **interrupt handler into a 2 KB ring buffer**, the same
  arrangement GW-BASIC's `COM:` driver uses. The ISR keeps capturing bytes while
  the main loop writes sectors, so no terminal flow control is needed: set Tera
  Term to **Flow control = None**, transmit delay 0.
- The ring occupies `rx_buf` (no sessions exist in transfer mode); `raw_head`
  and `raw_tail` are free-running 16-bit indexes masked to 2 KB, which is about
  two seconds of 9600-baud traffic - far more than a floppy sector write needs.
- Bytes flagged by the UART as **overrun / framing error / break** are dropped
  by the ISR, so line noise does not become a leading `00` in the file.
- The **first byte gets a ~66 s window** (1200 ticks); only after data has
  started does the gap fall to ~8 s. That is enough time to open the terminal's
  file dialog. Pressing a key on the PC keyboard during the initial wait aborts
  it.
- If a transfer ends with fewer than 8 bytes the console prints
  `FIRST BYTE hh`, which distinguishes a real file byte from line noise.
- `F` alone at the file-name prompt formats the disk (see below).
- Only `A:` is writable in this mode; a name containing `:` is rejected with
  `TRANSFER MODE WRITES TO A: ONLY`.
- `WRITE ON` is not required here - the mode is itself the authorisation.
- Use **binary** transfer in Tera Term. Text mode converts LF to CRLF and
  changes both the byte count and the file content.

### FORMAT A:|B: (V0R50)

`FORMAT` builds a FAT12 volume on a floppy. It is console-only and needs
`WRITE ON` when invoked from the shell (transfer mode calls it directly).

```
CAPACITY: 1=360K 2=720K 3=1440K ?    (type 1, 2 or 3)
GEOMETRY 40X2X9
720 SECTORS
FORMAT? (Y/N)
FORMAT COMPLETE
A: FAT12
```

Capacity is chosen explicitly rather than detected: `INT 13h AH=08h` reports the
**drive** geometry, not the media, so a 360 KB disk in a 1.44 MB drive would
otherwise produce a BPB describing 2880 sectors.

| Choice | Total | SPC | Root | FAT sectors | Media |
|---|---|---|---|---|---|
| 360K | 720 | 2 | 112 | 2 | FD |
| 720K | 1440 | 2 | 112 | 3 | F9 |
| 1440K | 2880 | 1 | 224 | 9 | F0 |

The formatter writes the boot sector (BPB + `0x55AA`), zeroes the root
directory, and writes both FAT copies with `media, FF, FF` in the first sector.
It **refuses to run if the disk in the drive is the one the machine booted
from**: the first two words of the boot sector are captured at boot and compared
before anything is written, producing `THIS IS THE BOOT DISK - REFUSED`.
A failed write reports the BIOS code, e.g. `FORMAT I/O ERROR 3` (03 = write
protected, 04 = sector not found, 10 = CRC error), which distinguishes a
protected disk from a drive/media mismatch.

### Write safety: the 32 MB LBA limit (V0R50)

All disk addressing in UMIX/86 is 16-bit - `part_lba`, `total_secs` and every LBA
are words - so the kernel can only address LBA 0-65535 (about 33.5 MB). If a
volume extends past that, the partition offset or a `part_lba + data_lba`
addition can wrap and write to a low sector.

`fat_mount` now checks this: if `total_secs` is zero or `part_lba + total_secs`
carries out of 16 bits, the volume is marked read-only and every write is
refused with

```
VOLUME BEYOND 32 MB - WRITES DISABLED (16-BIT LBA LIMIT)
```

So it is safe to save to a C: partition that lies entirely below LBA 65535;
anything larger is refused instead of risking a wrapped write. Verify with
`DIR C:` (the listing must match DOS) and `CHKDSK` in DOS before trusting a new
volume.

The user-table sector is also guarded. `USER_LBA` is a raw sector at LBA 700 on
the boot floppy. With one drive, after the boot floppy is swapped for a data
disk, saving users would write to LBA 700 of the *data* disk - inside its file
area. `users_save` therefore skips the floppy write when the boot drive holds a
mounted FAT volume (i.e. the boot floppy is no longer in the drive).

### Panel input fixes (V0R50)

Two input bugs in the panel shells, both in the serial-panel and CGA-panel line
editors:

- **Backspace erased the wrong cell.** Typing wrote the character at one column
  while the erase-space was drawn at `pin_col` computed *after* the decrement —
  one column to the left. The character the user meant to delete stayed on
  screen and the preceding one was clobbered. The erase now blanks the cell that
  held the deleted character, and the cursor is placed after the last typed
  character (`pin_col+1` on the CGA panel, `pin_col+2` on the serial panel).
  Verified on the serial panel: typing `AB` then backspace emits
  `ESC[24;15H` + space + `_`, and the next character lands back in column 15.
- **Serial function keys leaked into the command line.** There was no escape
  sequence handling on the serial input path, so PgUp (`ESC [ 5 ~`) typed the
  literal bytes `[5~` into the line. `getchar` now swallows `ESC [ …final` and
  `ESC O x` sequences and returns NUL, which every line editor ignores. PgUp and
  PgDn still do not scroll the serial panel — that needs an ANSI history
  renderer — but they no longer corrupt input. A lone `ESC` followed by an
  ordinary character consumes that character (standard terminal behaviour).

### Chat identities and moderation (V0R50)

Chat nicks are per-slot, uppercased, defaulting to `S<slot>` when left blank.
**`SYSOP` is reserved**: only the console (slot 0) or a session logged on as
`SYSTEM` with `PRIV ON` may claim it. Anyone else typing it gets
`SYSOP IS RESERVED - CONSOLE OR SYSTEM ONLY` and is prompted again.

`BAN <nick>` uses the same elevation test (`check_elev`): allowed from the
console or from a `SYSTEM` session with `PRIV ON`; other users see
`BAN: SYSTEM PRIV OFF`, and a `SYSTEM` session without `PRIV ON` gets the
console-only message.

### IPv4 and ICMP (V0R52)

The `0xFE` channel now carries a real IPv4 stack: header validation, the
internet checksum, and ICMP echo reply. The machine answers `ping`.

Two things were worth learning here:

- The IPv4 total length is **big-endian on the wire**. Loading it with a native
  word turned an 84-byte packet into `0x5400`, so every packet was rejected.
  The fix is one `xchg al, ah`; the checksum itself is endian-neutral.
- `ip_tx_flush` now takes the length from the packet's own header instead of a
  counter, and refuses to emit a frame over 120 escaped bytes. One source of
  truth, and a hard bound on what the mux will carry.

### UDP terminal sessions (V0R52)

Sessions ride **UDP port 2323**: `[session id][op][data]`, with `0` DATA,
`1` OPEN, `2` CLOSE and `3` BUSY. The guest allocates an id, then feeds the
bytes into the same per-slot input ring the mux uses, and the output hook in
`mux_send_frame` wraps terminal output in UDP instead of a mux frame. A NET
session therefore occupies a normal task slot: login, shell, `DIR`, `TYPE`, the
editor and JOB control are unchanged — only the transport differs.

Also in this version: the destination address is finally checked against
`ip_my_addr` (`192.168.99.1`), so the guest no longer answers packets addressed
elsewhere.

### The ES bug (V0R52)

`DIR` and `TYPE` over a UDP session lost every non-newline character while the
shell's own output was perfect. `ip_tx_flush` escaped the packet with `stosb`,
which writes **ES:DI**, and never set ES. In kernel context ES happens to be
`KERNEL_SEG`; the SYS overlay runs with **ES = SYS_SEG**, so the escape wrote
into the wrong segment and the frame was assembled from the *previous*
packet's bytes.

```asm
        push es
        mov ax, KERNEL_SEG
        mov es, ax                      ; stosb targets ipesc: ES must be ours
```

Rule for this kernel: any routine reachable from `UMIX.SYS` (anything under the
INT 60h API) must set **both** DS and ES before touching its own buffers.
`putc1`/`tx_slot_append` set DS only — enough until the IP path added `stosb`.
`.readlba` and `.loadf` deliberately keep the caller's ES for caller buffers.

### Host side: telnet and UDP relay (V0R52)

`tools/ip_peer.py` terminates the session protocol on the host:

```sh
python3 tools/mux_over_ip.py --serial /dev/ttyUSB0 --telnet-listen 0.0.0.0:2400
python3 tools/mux_over_ip.py --serial COM3 --udp-relay 127.0.0.1:2400
```

`--telnet-listen` gives a TCP client a session; `--udp-relay` gives each UDP
client one with raw bytes in and out (`nc -u`), needing no driver and no
privileges — the portable option, Windows included. Both chunk output, and
shrink chunks when a frame would exceed 250 bytes.

`serial_mux.py --ip` implements the same IP stack alongside the classic
terminal mux: `--ip-telnet`, `--udp-relay` and `--tftp-listen` take the same
`HOST:PORT` values, terminal id `0xFE` is routed to `ip_peer`, and the console
sessions keep working. One process can therefore serve serial shells, chat,
web, uploads and TFTP at the same time. Ping still needs the standalone
`tools/ip_ping.py` with the bridge stopped (it opens the serial port itself).

Tests: `tools/ip_test.py` (ICMP + session over the raw socket),
`tools/ip_telnet_test.py` (TCP and UDP relay through the bridge),
`tools/test_ip_peer.py` (13 unit tests). TUN is deliberately not implemented:
on Windows the L2 alternatives would need Ethernet and ARP in the guest.

### TFTP server (V0R121)

The guest serves TFTP on UDP 69, enabled with the console-only `TFTP ON|OFF`
command (default OFF).  A mux frame caps the negotiated block size at 40
bytes, so a client must send the `blksize` option; the host relay
(`--tftp-listen`) maps a local UDP port onto the guest's TID 6969.  GET
streams from disk, PUT writes each block straight into the FAT and updates
`write_file`.  `tftp_step` runs from `mux_poll` (task context), so the IRQ4
path only queues one datagram.  See the TFTP section above for limits.

### Chat room (V0R44)

`serial_login` accepts `CHAT` at the `USERID:` prompt and runs a per-session
chat loop instead of the shell. `CHAT` is also a shell command, so a logged-on
session can join without logging off; `/QUIT` returns to whichever context
(login prompt or `*`) invoked it. Slot 0 (the CGA/Hercules console) can join
too: broadcast delivery to slot 0 uses `chat_out_cga`, which writes through
`panel_putc` (panel mode) or the BIOS teletype, while serial slots use
`tx_slot_append`.

This is a direct demonstration of the multiplexer: each session task blocks in
`getchar` on its own RX ring, and a submitted line is formatted as
`NICK: text\r\n` into `chat_out` and delivered to every *other* slot with
`chat_on != 0`. Serial slots receive it through `tx_slot_append`
(`AL` = char, `BL` = slot); slot 0 through `chat_out_cga`. `chat_broadcast`
holds `crit` while appending/flushing so a line cannot interleave with another
session's output; the framed flush still runs with interrupts enabled, so
IRQ4 reception is not starved.

- State: `chat_on[NSLOTS]`, `chat_nick[NSLOTS*10]`, `chat_out[64]`.
- Broadcast iterates slots 0..2; the sender is skipped (it already echoed the
  typed line locally).
- Commands: `/WHO` (readable NICK/CONSOLE table with a dashed rule), `/MSG
  NICK TEXT` (private message; delivered only to that slot as
  `[PRIVATE] NICK: text`), `/HELP`, `/QUIT` (clears `chat_on`, announces
  `LEFT CHAT`, returns to whichever prompt invoked `CHAT`).
- The bridge terminal ID (`tid=1..10`) is mapped to the lowest free guest slot
  at OPEN and stored in `task_term[slot]`; `PS` shows the **slot**, not the tid,
  so they can differ (see the README `PS` section).
- The console (slot 0) is the chat **SYSO**: it has `/BAN NICK`, which clears
  the target's `chat_on`, marks `chat_kick[target]`, and injects a CR into the
  target's RX ring (`chat_wake_slot`) so the blocked `chat_read_prompt` wakes,
  sees `chat_kick`, returns, and prints `REMOVED FROM CHAT BY SYSO`. Non-console
  sessions get `BAN: SYSO ON CONSOLE ONLY`.
- `CHAT ON|OFF` is console-only: `OFF` clears `chat_enabled` and wakes/ejects
  every chat member; joins are refused with `CHAT DISABLED BY CONSOLE`.
- Entering chat prints a banner (`UMIX/86 CHAT SYSTEM`, 8088/640 KB, MUX V1.0,
  commands) and then the user list.
- Panel sessions (`ser_panel[slot] != 0`) render chat in the panel: lines are
  positioned in the output area and the input line is redrawn on row 24.
  Delivery swaps `cur_task` to the target slot so the existing panel/console
  routing applies to that slot, then restores it.
- `session_reset_slot` clears `chat_on` on CLOSE, so a disconnect cannot leave
  a phantom chat member.
- Input reuses the per-slot 160-byte shell line buffer and is capped at 30
  characters, keeping a full line under the 120-byte TX frame limit.
- A message never reaches a session that is logged on to the shell.

Note: `mux_flush` now clears `CH` before using `CX` as the frame length. The
old code relied on `CH` happening to be zero; calling it from a path that had
loaded `CX` with `KERNEL_SEG` (0x1000) made the flush emit `0x10xx` bytes and
desynchronise the frame decoder.

### Phase 2 implementation notes (V0R24)

- `MUX equ 1`; COM1 is a framed link by default. Set `MUX=0` and rebuild to
  return to the old raw path (the bridge cannot talk to a raw guest).
- IRQ4 (INT 0Ch) receiver, 256-byte RX ring, 120-byte max TX payload, per-slot
  128-byte TX buffers.
- OPEN creates session slot 1; CLOSE stops it; a second OPEN gets BUSY (phase 3
  will add the second slot).
- `mux_poll` runs from `getchar`; task creation stays in the main context.
- Serial logon/logoff lines are written to the CGA console only in MUX mode;
  they are not injected into the session stream.
- The bridge accepts `--serial unix:/path` for QEMU sockets in addition to
  pyserial devices and `--fake`.
- Verified: one TCP client logs in over QEMU's serial socket, runs `ECHO` and
  `PS`, gets BUSY as a second client, and reconnects with a fresh login; the
  CGA panel and its `COM1 LOGON ...` line remain intact.

## 12. Acceptance criteria (MVP)

- Two TCP clients connect and each receives a distinct terminal ID.
- Each client sees its own login prompt and UCS shell; typing in one does not
  appear in the other.
- `DIR` in session A is not sent to session B.
- `WHO` shows both sessions with IDs and users; `PS` shows both session tasks.
- Client disconnect/reconnect frees and reuses the ID without ghost tasks.
- CGA console, SAVE, JCL, and the CGA editor remain functional.
- Frame errors and RX overflows are counted and logged.
- At 9600, keystroke latency is acceptable and serial panels default to off.

## 13. Resolved decisions

- Term 0 system frames: log only by default; `--broadcast-system` sends them to
  every connected client.
- `DRIVE` stays global; `WRITE` is console-only (V0R44). Per-session gating is
  future work.
- `MUX`: compile-time switch in the MVP; no runtime command.
- 16550: not available. Accept the 8250/16450 no-FIFO limitation at 9600, count
  overflow events, and keep the first release at 2 text sessions. A 16550/FIFO
  path remains a future upgrade.

## 14. Web application (app id 2)

The OPEN frame payload now carries an application id: empty or 1 = console
(existing behaviour), 2 = web, 3 = upload. The guest stores it per terminal and
`spawn_session` starts `web_entry` or `upload_entry` instead of the logon shell.

The web session waits for the request headers (CRLFCRLF, 2 KB cap), loads
`INDEX.HTM` from the mounted volume into `savebuf` (4 KB max), and sends:

```
HTTP/1.0 200 OK
Content-Type: text/html
Content-Length: <bytes>
Connection: close

<page>
```

The request target is collected after the method. Only `/` (`?query` ignored)
serves `INDEX.HTM`; anything else - notably `/favicon.ico` - loads `404.HTM`
into `savebuf` and returns it with `HTTP/1.0 404 Not Found`.  If the file is
missing, the built-in `NOT FOUND` page is returned. Output is DATA frames tagged with
the terminal id in 120-byte chunks, followed by a CLOSE frame.

Bridge side: `--http-listen HOST:PORT` (repeatable). Web requests are sent in
64-byte chunks every 10 ms after the OPEN ACK. The guest ring is 256 bytes per
session and its web task runs once per 18 Hz tick (~53 bytes per tick), so
this pacing prevents the overflow that used to lose the end of a browser's
header block. On a guest CLOSE the writer queue is drained before the TCP
socket is closed, so the last frame is not truncated. Console and web clients
share the `--max-sessions` pool. Response time is dominated by the 9600-baud
link (~900 bytes/s): about 4 seconds for a 4 KB page, or half that after
`BAUD 19200` (the request pacing stays ring-bound).

The 4 KB file buffer is the same one used by the shell `SAVE` and BASIC; avoid
a large SAVE while a web request is in flight.

The kernel keeps two flags: `web_enabled` (default 1; `WEB OFF` makes the task
send a 503 without touching the disk) and `web_log` (default 0; `WEBLOG ON`
prints each request line on the CGA panel, temporarily forcing
`task_out=0` for the log and restoring it before the response). Both commands
are console-only.

**Upload (app id 3).** `upload_entry` waits for a header line
`PUT <name> <size>`, checks `WRITE ON`, reads exactly `size` bytes into an 8 KB
buffer, builds the 8.3 name, and calls `write_file` in a critical section. It
answers `OK n BYTES` or `ERR WRITE OFF | TOO BIG | I/O | WRITE | SYNTAX` and
closes. The bridge's `--upload-listen` feeds header+bytes in 64-byte chunks
(20 ms gap) - the guest's UART has no FIFO, so a 120-byte payload can overrun
while the mux decoder copies it at ETX. The 256-byte ring keeps the stream
intact; there are no per-frame ACKs.


---

# Part III — Writing C programs for UMIX/86

UMIX/86 is pure x86 real-mode assembly, built with NASM.

The OS itself (src/*.asm, 17,575 lines):

    file                    lines   role
    src/boot.asm               93   512-byte boot sector at 0x7C00; loads 128
                                    sectors via INT 13h, jumps to 1000:0000
    src/kernel.asm        13,068   the kernel: scheduler, shells, FAT12/16,
                                    UMIX.SYS loader, INT 60h/61h, serial mux,
                                    chat/SYSO, CGA panel + scrollback, user
                                    table, BASIC, ...
    src/sys.asm            4,507   UMIX.SYS overlay (DIR/TYPE/JCL/BASIC, INT 61h hook)
    hello1/hello2/spin     28-42    demo tasks (.SYS)

All are NASM -f bin flat binaries with `cpu 8086` / `bits 16` - no C
compiler, no libc, no linker, no runtime. The kernel talks directly to the
hardware through BIOS calls (INT 10h video, INT 13h disk, INT 16h keyboard,
INT 1Ah RTC) and raw I/O ports (8253 PIT, 8259 PIC, 8250 UART, 6845 CRTC).

      nasm -f bin -o build/kernel.bin src/kernel.asm

C programs are optional task binaries loaded by RUN alongside that assembly
OS; this document describes how to build and run them.

Yes, it is possible to write a program in C that runs under UMIX/86 - but not
with a normal DOS C compiler "as is". You need a 16-bit 8086 compiler, a custom
startup, and a flat binary (no MZ header, no relocations, no libc).

This document describes the runtime contract, the toolchain options, a working
recipe, and the limits.

## 1. RUNTIME CONTRACT (what RUN gives your program)

`RUN FILE.SYS` loads the file flat into one of the two program segments and
starts it as a preemptible task:

    program slots   11 and 12
    code segment    0x3000 (slot 11) / 0x4000 (slot 12)
    entry           CS:IP = task_seg:0000
    data            DS = ES = task_seg
    stack           SS = task_stk[slot] (0x6A00 / 0x6B00), SP = 0x0FFE
    stack size      4 KB (grows down from 0x0FFE)
    registers       AX, BX, CX, DX, SI, DI, BP = 0 at entry
    flags           IF = 1 (timer preemption active)
    load limit      file size is a 16-bit value: at most 64 KB
    output console  inherited from the shell that ran RUN (task_out)
    input console   task_in = 0 (keyboard) - see "serial input" below

Exit and I/O use the kernel API via INT 60h:

    60h AH=0  putc AL              write one character
    60h AH=1  puts DS:SI           write a NUL-terminated string
    60h AH=2  put_dec BX           write BX in decimal
    60h AH=4  load file            DS:SI = 11-byte 8.3 name, ES:BX = dest,
                                   CX = max bytes -> DX = size, CF on error
    60h AH=5  read LBA             DI = LBA, ES:BX = dest -> CF on error
    60h AH=6  FS info              ES:BX <- root_lba, root_secs, root_ents
    60h AH=7  yield                give the CPU to the next ready task
    60h AH=8  exit                 terminate this task
    60h AH=9  ticks -> AX          timer ticks (rate follows QUANTUM; 18 Hz
                                   default)
    60h AH=10 getc -> AL           one key from the launching console (yields
                                   while waiting; works on CGA and serial). A
                                   program started by RUN inherits the shell's
                                   input console and its input slot, and the LF
                                   left by the RUN line's CRLF is swallowed on
                                   the first getc.
    60h AH=11 run command line     DS:SI -> NUL-terminated command (in the
                                   caller's DS); the kernel executes it
    60h AH=12 save file            DS:SI = 11-byte 8.3 name, ES:BX = buffer,
                                   CX = size; writes to the mounted volume
                                   (WRITE ON required) -> CF, AL (1=write off)
    60h AH=13 mount drive          AL = A/B/C/M; M is formatted only if it
                                   has no valid FAT -> CF on error
    60h AH=14 break check -> AL    1 if Ctrl-C is pending (mux ring, raw
                                   serial or CGA keyboard)
    60h AH=15 clear screen         console CLS for the calling task

INT 61h is the shell-command hook used by UMIX.SYS (DIR/TYPE/JCL/BASIC): DS:SI =
command, DS:DI = arguments; CF=0 means handled.

The kernel preempts on IRQ0 (unless PREEMPT OFF). Your program may be switched
out at almost any instruction; do not disable interrupts for long periods and
do not assume it owns the machine.


## 2. TOOLCHAIN OPTIONS

A. IA-16 GCC (recommended)
     `ia16-elf-gcc` is a GCC port targeting 8086/8088 real mode. It can emit
     8086-only code, link at offset 0, and produce a flat binary.

     Flags: -march=i8086 -mcmodel=small -ffreestanding -nostdlib
          -fno-pic -Os
     Link at 0 and convert to binary.

B. OpenWatcom C/C++
     `wcc -0 -ms` compiles 8086 small-model code. You must avoid its DOS startup
     (INT 21h), strip any MZ/COM header, and arrange entry at offset 0. More work
     than IA-16 GCC.

C. Bruce's C compiler (dev86 / bcc)
     8086 code generator; skip its libc (which expects Linux/DOS services) and
     provide your own crt0 and I/O wrappers.

D. NOT suitable:
   - Turbo C / Borland C: DOS startup, INT 21h, origin and relocation
       assumptions; not a flat image at offset 0.
   - host `gcc -m16`: emits 32-bit-register code, not 8088-compatible.


## 3. EXAMPLE

Three files: a startup, I/O wrappers, and the C program.

crt0.S  (GAS/AT&T syntax for ia16-elf-as; adjust minor syntax for your
           assembler version)

          .arch i8086
          .code16
          .section .text.start,"ax"
          .globl _start
          .extern main
          .extern __bss_start
          .extern __bss_end

_start:
          movw %cs, %ax
          movw %ax, %ds
          movw %ax, %es

          ; zero .bss: the loader copies only file bytes, .bss is not in the
          ; flat binary and would otherwise contain stale memory
          movw $__bss_start, %di
          movw $__bss_end, %cx
          subw %di, %cx
          xorb %al, %al
          rep stosb

          call main

          movb $8, %ah            ; INT 60h AH=8: exit task
          int $0x60
1:      jmp 1b

io.S  (cdecl wrappers: arguments are on the stack)

          .code16
          .globl kputc, kputs, kexit, kgetc

kputc:                          ; void kputc(unsigned char c)
          pushw %bp
          movw %sp, %bp
          movb 4(%bp), %al
          xorb %ah, %ah
          int $0x60
          popw %bp
          ret

kputs:                          ; void kputs(const char *s)
          pushw %bp
          movw %sp, %bp
          movw 4(%bp), %si
          movb $1, %ah
          int $0x60
          popw %bp
          ret

kexit:                          ; void kexit(void)
          movb $8, %ah
          int $0x60
          ret

kgetc:                          ; unsigned char kgetc(void)
          movb $10, %ah
          int $0x60                       ; returns AL
          ret

main.c

          extern void kputc(unsigned char c);
          extern void kputs(const char *s);
          extern unsigned char kgetc(void);

          int main(void)
          {
              kputs("HELLO FROM C\r\n");
              kputc('!');
              kputc('\r');
              kputc('\n');
              return 0;
          }

Linker script (prog.ld), so .bss symbols exist and the image starts at 0:

          SECTIONS
          {
              . = 0;
              .text   : { *(.text.start) *(.text*) }
              .rodata : { *(.rodata*) }
              .data   : { *(.data*) }
              __bss_start = .;
              .bss    : { *(.bss*) *(COMMON) }
              __bss_end = .;
          }

Build:

          ia16-elf-gcc -march=i8086 -mcmodel=small -Os -ffreestanding \
          -nostdlib -fno-pic -T prog.ld \
          -Wl,--oformat=binary -o PROG.SYS crt0.S io.S main.c

If your ld does not accept --oformat=binary:

          ia16-elf-gcc ... -T prog.ld -o prog.elf crt0.S io.S main.c
          ia16-elf-objcopy -O binary prog.elf PROG.SYS

Then copy PROG.SYS to C: and run:

          * RUN PROG.SYS
          HELLO FROM C
          !


## 3b. READING A LINE

`kgetc` returns raw bytes from the console that launched the program: no echo,
no CR/LF translation, no line editing. The reader has to do all of that
itself. The main trap is the terminal's ENTER:

          Tera Term / most terminals      CR LF
          some telnet clients             CR NUL
          CR-only terminals               CR

If you stop at CR and leave the next byte in the stream, the *next* line read
returns an empty line. Keep a one-byte "skip LF/NUL" flag across calls:

          extern unsigned char kgetc(void);
          extern void kputc(unsigned char c);
          extern void kputs(const char *s);

          int kgets(char *buf, int max)
          {
              static unsigned char skip_lf;       /* .bss: crt0 zeroes it */
              int len = 0;
              unsigned char c;

              if (max < 1) return 0;
              if (max < 2) { buf[0] = 0; return 0; }

              for (;;) {
                  c = kgetc();

                  if (skip_lf) {                  /* swallow CRLF / CR-NUL */
                      skip_lf = 0;
                      if (c == '\n' || c == 0) continue;
                  }

                  if (c == '\r' || c == '\n') {
                      if (c == '\r') skip_lf = 1;
                      break;
                  }
                  if (c == 8 || c == 127) {       /* backspace / delete */
                      if (len) {
                          len--;
                          kputc(8); kputc(' '); kputc(8);
                      }
                      continue;
                  }
                  if (c == 3) {                   /* Ctrl-C aborts the line */
                      len = 0;
                      kputc('^'); kputc('C'); kputc('\n');
                      return 0;
                  }
                  if (c < 32) continue;           /* ignore other controls */

                  if (len < max - 1) {
                      buf[len++] = (char)c;
                      kputc(c);                   /* local echo */
                  }
              }

              buf[len] = 0;
              kputc('\n');                        /* kernel expands LF to CRLF */
              return len;
          }

Use it as:

          char name[32];
          kputs("NAME? ");
          if (kgets(name, sizeof name) == 0)
              kputs("(empty)\r\n");

Notes:

- `kgetc` yields while waiting (INT 60h AH=10), so the task does not spin and
    the rest of the OS keeps running. A program started from a serial shell
    reads that shell's input, so `kgetc` works over the serial bridge too (the
    leftover LF of the RUN line's CRLF is swallowed on the first getc).
- The kernel does not echo input. `kputc(c)` in the loop is the echo; drop it
    if you want a silent read.
- `kputc('\n')` already writes CR+LF (the kernel expands LF), so do not send a
    separate "\r\n" after a line or you get a blank line.
- `skip_lf` must survive from one call to the next: make it `static` (or a
    global), not a local.
- Length is capped at `max-1`. Characters past the cap are consumed but not
    stored; add a bell (`kputc(7)`) if you want feedback.
- There is no timeout: `kgetc` blocks until a key arrives.


## 4. LIMITS AND GOTCHAS

- No libc: no printf/malloc/fopen. Use INT 60h for output, INT 16h for the
    keyboard, INT 10h for video. Static arrays only, or your own allocator inside
    the 64 KB segment.
- .bss is NOT loaded (flat binary has no NOBITS section). Zero it in crt0, or
    initialise every global explicitly.
- 4 KB task stack. Keep recursion and large locals small. If you need more,
    reserve the top of your own 64 KB segment and set SS:SP to it in crt0 (make
    sure code/data/BSS do not overlap it).
- 64 KB segment, and the file itself is limited to 64 KB. Code + data + BSS
    must fit.
- 8086 instructions only. Do not let the compiler emit 186+ opcodes
    (-march=i8086); no FPU (integer or soft-float, and soft-float pulls in
    libgcc routines).
- Flat image at offset 0: no MZ header, no relocations, no far calls to
    external segments. Check the first two bytes are your code, not 'MZ' (4D 5A).
- Preemption: the task can be switched out anywhere; don't hold interrupts
    disabled for long. Global state is per program segment (two instances of the
    same program get 0x3000 and 0x4000, so their data is separate).
- Output goes to the console inherited from the launching shell (CGA or COM1).
- Console input: INT 60h AH=10 (getc) returns one byte from the console that
    launched the program (CGA or serial), yielding while it waits. INT 16h is
    still the raw BIOS keyboard and reads the CGA keyboard regardless.
- Exit with INT 60h AH=8 (crt0 does this after main returns). Do not RET into
    nothing or jump to 0.


## 5. TROUBLESHOOTING

First bytes are 'MZ' (4D 5A)
      You linked a DOS EXE. Link at offset 0 / use --oformat=binary.

Program resets or executes garbage
      Check for 186+ instructions (compile with -march=i8086), stack overflow
      (>4 KB), or an MZ/relocation header. Also check the file is not > 64 KB.

Global variables contain garbage
      .bss was not zeroed. Add the __bss_start/__bss_end loop to crt0 and the
      symbols to the linker script.

No output
      Confirm the API call shape: AH=0 with AL=char, AH=1 with DS:SI=string.
      Output goes to the console that ran RUN. If launched from the CGA console,
      it appears on the CGA panel; from a serial shell, on that terminal.

Undefined __bss_start/__bss_end
      Add them to the linker script (see above).

Hangs after main returns
      crt0 must call INT 60h AH=8; do not fall through or RET.


## 6. REFERENCE: ASSEMBLY PROGRAMS

The demo programs are hand-written assembly and show the same contract:

    src/hello1.asm   prints and yields (RUN HELLO1.SYS &)
    src/hello2.asm   same, different text
    src/spin.asm     busy/yield loop for scheduler testing

They start with:

          mov ax, cs
          mov ds, ax
          mov es, ax
          ...
          mov ah, 8
          int 0x60

and are assembled with NASM (`nasm -f bin`) into .SYS files on C:.

---

# Part IV — CBM 8088 ROM monitor notes

## CBM 8088 ROM monitor (BIOS 4.35)

````text
CBM 8088 MONITOR (ROM MONITOR) - COMMODORE PC10-III / PC20-III / COLT
==========================================================================

Source: Commodore PC10-I/II/III Service Manual, printed page 41
("MONITOR PROGRAM"), memory map on page 40, BIOS 4.36 notes on page 42.

The ROM monitor is a machine-level debugger in ROM. It runs before any OS,
with no protection and no file system. You can inspect and change memory,
registers and I/O ports, and run or single-step code.

This document applies to the PC20-III with BIOS 4.35 (EPROM 318085-01).


WHERE IT LIVES
--------------------------------------------------------------------------
The monitor is part of the 32 KB BIOS EPROM (U201, 27256):

    F8000-F9FFF   8 KB   CBM 8088 Monitor
    FA000-FBFFF   8 KB   Hard Disk BIOS
    FC000-FFFFF  16 KB   Main BIOS (4.35 on 318085-01; 4.36 on 318085-02)

Because it is in the same chip, upgrading to BIOS 4.36 (318085-02) replaces
the monitor as well.


HOW TO ENTER
--------------------------------------------------------------------------
1. Power off and remove the boot floppy from A:.
2. Power on.
3. If no bootable device is found, the BIOS prints:

       Boot disk failure. Type key to Retry.
       Press control 'M' to enter CBM monitor.

4. Hold Ctrl and press M (not Enter). You should see:

       Commodore 8088 Monitor
       Pre-release version 2.0
       Copyright 1987 Commodore Technology Group
       Use ? for help

The monitor can also be entered when a power-up test error is detected, by
pressing Ctrl+M at that error.

If the hard disk is bootable (e.g. DOS), the machine boots C: and you never
reach the prompt. Temporarily disconnect/make the HDD non-bootable, or use a
POST error (e.g. a dead RTC/configuration battery) to reach the prompt.

Type ? and Enter for the command list. Type B (Boot) or reset to leave.


COMMANDS
--------------------------------------------------------------------------
The capital letter is the command key. Addresses are hex, segment:offset.

  D  Dump [starting addr]
     Hex/ASCII memory dump.

  F  Fill [starting addr] [count] [data]
     Write a byte pattern over a range.

  G  Goto [addr] [break point1] [break point2]
     Run code at addr, optionally stopping at up to two breakpoints.

  I  Input port [byte : word] [port addr]
     Read an I/O port (byte or word).

  O  Output port [byte : word] [port addr] [data]
     Write an I/O port.

  N  iNterrupt [#hex]
     Execute a software interrupt (registers set with X).

  M  Move [source addr] [dest addr] [count]
     Block copy.

  S  Substitute memory [addr]
     Edit memory byte by byte.

  T  Trace
     Single-step one instruction.

  X  eXamine [register]
     Show/modify registers (AX.., CS:IP, FLAGS).

  B  Boot
     Boot from disk (INT 19h).

Register addresses conform to PC industry standards.


EXAMPLES
--------------------------------------------------------------------------
Inspect memory:

    D 0:0000        interrupt vector table
                    INT 08 at 0:0020, INT 0C at 0:0030, INT 60 at 0:0180
    D F000:0000     main BIOS (4.35)
    D F800:0000     this monitor ROM
    D B800:0000     CGA text screen (char/attribute pairs)
    D 1000:0000     UMIX kernel segment (after boot/dump, if present)
    D 6000:0F00     a UMIX task stack

Inspect and poke the UART (COM1 at 3F8):

    I 3FD           line-status: bit0 data-ready, bit5 THR-empty
    I 3F8           read a received byte
    I 21            PIC interrupt mask (bit4 = IRQ4)
    I 20            PIC in-service / IRR
    O 3FC 0B        MCR = DTR|RTS|OUT2 (verify the IRQ4 fix; I 3FC -> 0B)
    O 3F9 01        enable UART RX interrupt
    O 21 EF         unmask IRQ4
    I 61            PPI: bit5 timer-2 out, bit0 speaker gate

Call BIOS functions interactively:

    X               set AX=0E41, BX=0007 (AH=0Eh teletype, AL='A', page)
    N 10            INT 10h -> prints 'A'
    X               set AH=02, DX=row/col
    N 10            position the cursor
    N 19            reboot

Poke and run a tiny routine:

    S 1000:0100     type: B0 41 B4 0E CD 10 F4
                    (mov al,'A'; mov ah,0Eh; int 10h; hlt)
    G 1000:0100     runs it, stops at HLT
    X               inspect registers

Run with breakpoints:

    G 1000:0100 1000:0110

Move memory:

    M 1000:0000 3000:0000 2000     copy 8 KB


WHAT IT CANNOT DO
--------------------------------------------------------------------------
- No file load/save. There is no "load .COM from disk" command in the monitor
  set; use B (Boot) to run an OS.
- No assembler/disassembler (D is a dump, not a disassembler), no symbols, no
  source-level debugging.
- No protection: a wrong port or address can hang the machine or corrupt the
  disk controller. Avoid O to disk-controller ports (0x3F0-0x3F7, 0x320 etc.)
  unless you know exactly what you are doing.
- Entry is at boot only: Ctrl+M at the boot-failure or POST-error prompt.
  There is no documented "call monitor" vector, so it is a bring-up and
  post-mortem tool, not a live OS debugger.


USING IT WITH UMIX/86
--------------------------------------------------------------------------
- Verify the UART OUT2/IRQ4 fix:   O 3FC 0B   then   I 3FC   (expect 0B).
- After a crash/reset, if you can reach the monitor: D 0:0000 shows the
  installed vectors, D 1000:0000 the kernel image, D 6000:0F00 a task stack.
- Bring-up experiments (PIT divisor, speaker, video modes) without writing a
  test program: program PIT channel 0/2 with O 43 / O 40 / O 42, read 0x61.
- Inspect the CGA panel directly with D B800:0000 (char/attribute pairs) when
  panel rendering looks wrong on real hardware.


BIOS 4.35 NOTES (318085-01, relevant for UMIX)
--------------------------------------------------------------------------
BIOS 4.36 (318085-02) fixes, among others:

  1. 9600 baud interrupt-driven COM: dropped characters caused by the
     keyclick simulation code. This is the one to watch for the serial mux
     after the OUT2 fix.
  2. INT 11h returns swapped 40/80-column status in CGA mode.
  3. Incorrect INT 16h scan codes for F11/F12.
  4. Microsoft bus mouse autoconfig.
  5. EGA/VGA memory conflicts with the PVC4 video controller.
  6. IBM 3270 card patches (INT 1A).
  7. Hard-disk boot speed.
  8. IBM 5250 upload/download (INT 1A).
  9. OKI real-time clock registers altered by unauthorized system code.
 10. Software cold boot via F00:E05B or FFFF:0000 hangs on pre-4.36
     (example: MS-DOS FDISK). UMIX REBOOT uses INT 19h, not those vectors.
 11. Unexpected interrupts could crash/hang after prolonged use.
 12. On-board base memory configuration when off-board memory is present.

The 4.36 upgrade is an in-line EPROM replacement (27256; a 27C256 works if
you can program the image). The manual says it must be purchased through an
authorized service center and installed by a technician.
````
