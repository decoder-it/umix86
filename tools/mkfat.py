#!/usr/bin/env python3
"""Build build/testc.img: an MBR-partitioned FAT16 disk (615x4x17) holding
UMIX.SYS and README.TXT, for QEMU tests of the C: reader."""
from pathlib import Path
import os
import struct

SECTOR = 512
CYL, HEADS, SPT = 615, 4, 17
TOTAL = CYL * HEADS * SPT
PART_LBA = 63
PART_SECS = TOTAL - PART_LBA
SPC = 4
RSVD = 1
NFATS = 2
ROOT_ENTRIES = 512
ROOT_SECS = ROOT_ENTRIES * 32 // SECTOR
FAT_SECS = 41

def chs(lba):
    cyl, rem = divmod(lba, HEADS * SPT)
    head, sec = divmod(rem, SPT)
    return bytes([head & 0xFF, (sec + 1) | ((cyl >> 2) & 0xC0), cyl & 0xFF])

img = bytearray(TOTAL * SECTOR)

# --- MBR ---
mbr = bytearray(SECTOR)
e = 0x1BE
mbr[e + 0] = 0x80
mbr[e + 1:e + 4] = chs(PART_LBA)
mbr[e + 4] = 0x06                       # FAT16
mbr[e + 5:e + 8] = chs(PART_LBA + PART_SECS - 1)
struct.pack_into("<I", mbr, e + 8, PART_LBA)
struct.pack_into("<I", mbr, e + 12, PART_SECS)
mbr[510:512] = b"\x55\xAA"
img[0:SECTOR] = mbr

# --- partition boot sector ---
bs = bytearray(SECTOR)
bs[0:3] = b"\xEB\x3C\x90"
bs[3:11] = b"UMIX86  "
struct.pack_into("<H", bs, 11, SECTOR)
bs[13] = SPC
struct.pack_into("<H", bs, 14, RSVD)
bs[16] = NFATS
struct.pack_into("<H", bs, 17, ROOT_ENTRIES)
struct.pack_into("<H", bs, 19, PART_SECS)
bs[21] = 0xF8
struct.pack_into("<H", bs, 22, FAT_SECS)
struct.pack_into("<H", bs, 24, SPT)
struct.pack_into("<H", bs, 26, HEADS)
struct.pack_into("<I", bs, 28, PART_LBA)
bs[36] = 0x80
bs[38] = 0x29
struct.pack_into("<I", bs, 39, 0x12345678)
bs[43:54] = b"UMIX86 TEST"
bs[54:62] = b"FAT16   "
bs[510:512] = b"\x55\xAA"
img[PART_LBA * SECTOR:(PART_LBA + 1) * SECTOR] = bs

FAT1 = PART_LBA + RSVD
FAT2 = FAT1 + FAT_SECS
ROOT = FAT2 + FAT_SECS
DATA = ROOT + ROOT_SECS

# --- FAT16 ---
fat = bytearray(FAT_SECS * SECTOR)
struct.pack_into("<H", fat, 0, 0xFFF8)
struct.pack_into("<H", fat, 2, 0xFFFF)
next_cluster = 2

def add_file(name83, data):
    global next_cluster
    clusters = max(1, (len(data) + SPC * SECTOR - 1) // (SPC * SECTOR))
    start = next_cluster
    for i in range(clusters):
        cl = start + i
        nxt = cl + 1 if i < clusters - 1 else 0xFFFF
        struct.pack_into("<H", fat, cl * 2, nxt)
        off = (DATA + (cl - 2) * SPC) * SECTOR
        chunk = data[i * SPC * SECTOR:(i + 1) * SPC * SECTOR]
        img[off:off + len(chunk)] = chunk
    next_cluster += clusters
    return start, len(data)

entries = []
def root_entry(name83, start, size, attr=0x20):
    e = bytearray(32)
    e[0:11] = name83
    e[11] = attr
    struct.pack_into("<H", e, 26, start)
    struct.pack_into("<I", e, 28, size)
    entries.append(e)

sysdata = Path("build/umix.sys").read_bytes()
readme = (b"UMIX/86 C: README\r\n"
          b"This file lives on the DOS FAT16 volume.\r\n"
          b"DIR and TYPE are implemented in UMIX.SYS.\r\n")
s1, n1 = add_file(b"UMIX    SYS", sysdata)
s2, n2 = add_file(b"README  TXT", readme)
root_entry(b"UMIX    SYS", s1, n1)
root_entry(b"README  TXT", s2, n2)

h1data = Path("build/hello1.sys").read_bytes()
h2data = Path("build/hello2.sys").read_bytes()
s3, n3 = add_file(b"HELLO1  SYS", h1data)
s4, n4 = add_file(b"HELLO2  SYS", h2data)
root_entry(b"HELLO1  SYS", s3, n3)
root_entry(b"HELLO2  SYS", s4, n4)

spdata = Path("build/spin.sys").read_bytes()
s5, n5 = add_file(b"SPIN    SYS", spdata)
root_entry(b"SPIN    SYS", s5, n5)

job = (b"//MYJOB JOB\r\n"
       b"//S1 EXEC CMD='ECHO HELLO FROM JCL'\r\n"
       b"//S2 EXEC PGM=DIR\r\n"
       b"//S3 EXEC CMD='ECHO AFTER DIR'\r\n"
       b"// EOJ\r\n")
s7, n7 = add_file(b"JOB     JCL", job)
root_entry(b"JOB     JCL", s7, n7)

web_path = os.environ.get("UMIX_INDEX", "INDEX.HTM")
web = Path(web_path).read_bytes()
if len(web) > 3999:
    raise SystemExit(f"{web_path} is {len(web)} bytes; INDEX.HTM max is 4000")
s6, n6 = add_file(b"INDEX   HTM", web)
root_entry(b"INDEX   HTM", s6, n6)
# the old explorer page is kept as EXPLORER.HTM
_exp = Path("tools/api_explorer.html").read_bytes()
if len(_exp) > 3999:
    raise SystemExit(f"tools/api_explorer.html is {len(_exp)} bytes; max is 4000")
_se, _ne = add_file(b"EXPLORERHTM", _exp)
root_entry(b"EXPLORERHTM", _se, _ne)
# the browser chat app (relative /api paths, served by the guest)
_chat = Path("chat_umix.htm").read_bytes()
if len(_chat) > 3999:
    raise SystemExit(f"chat_umix.htm is {len(_chat)} bytes; max is 4000")
_sc, _nc = add_file(b"CHAT    HTM", _chat)
root_entry(b"CHAT    HTM", _sc, _nc)

# system guide pages UMX002.HTM .. UMX007.HTM (each < 4000 bytes)
for _name in ("UMX002.HTM","UMX003.HTM","UMX004.HTM",
              "UMX005.HTM","UMX006.HTM","UMX007.HTM"):
    _data = Path(_name).read_bytes()
    if len(_data) > 3999:
        raise SystemExit(f"{_name} is {len(_data)} bytes; INDEX.HTM max is 4000")
    _b, _e = _name.split(".")
    _fat = (_b.ljust(8) + _e.ljust(3)).encode("ascii")
    _s, _n = add_file(_fat, _data)
    root_entry(_fat, _s, _n)
basdemo = (b'10 PRINT "{";CHR$(34);"route";CHR$(34);":1,"\r\n'
           b'20 PRINT CHR$(34);"path";CHR$(34);":";CHR$(34);P$;CHR$(34);","\r\n'
           b'30 PRINT CHR$(34);"q";CHR$(34);":";CHR$(34);Q$;CHR$(34);","\r\n'
           b'40 PRINT CHR$(34);"m";CHR$(34);":";CHR$(34);M$;CHR$(34);","\r\n'
           b'50 PRINT CHR$(34);"blen";CHR$(34);":";LEN(B$);"}"\r\n')
s10, n10 = add_file(b"APIHELLOBAS", basdemo)
root_entry(b"APIHELLOBAS", s10, n10)

echodemo = (b'10 IF M$="POST" THEN GOTO 30\r\n'
           b'20 PRINT "{";CHR$(34);"error";CHR$(34);":";CHR$(34);\r\n'
           b'25 PRINT "POST";CHR$(34);"}": END\r\n'
           b'30 PRINT "{";CHR$(34);"m";CHR$(34);":";CHR$(34);M$;CHR$(34);","\r\n'
           b'40 PRINT CHR$(34);"blen";CHR$(34);":";LEN(B$);"}"\r\n')
s_e, n_e = add_file(b"ECHO    BAS", echodemo)
root_entry(b"ECHO    BAS", s_e, n_e)

chat = Path("build/chat.sys").read_bytes()
s9, n9 = add_file(b"CHAT    SYS", chat)
root_entry(b"CHAT    SYS", s9, n9)
tcp = Path("build/tcp.sys").read_bytes()
s10, n10 = add_file(b"TCP     SYS", tcp)
root_entry(b"TCP     SYS", s10, n10)
api = Path("build/api.sys").read_bytes()
s11, n11 = add_file(b"API     SYS", api)
root_entry(b"API     SYS", s11, n11)

# COM1 is either the framed mux or SLIP, never both.  Asking for TCP wins:
# MUX is left off, otherwise "SLIP ON" fails with "SLIP: MUX IS ON".
use_mux = os.environ.get("UMIX_MUX") == "1" and os.environ.get("UMIX_TCP") != "1"
use_tcp = os.environ.get("UMIX_TCP") == "1"

startup = (
    b"; UMIX/86 boot script - one command per line\r\n"
    b"; lines starting with ';' '#' or '//' are comments\r\n"
    b"; runs before the first prompt, after UMIX.SYS loads\r\n"
    b";\r\n"
    + (b"MUX ON\r\n" if use_mux else b";MUX ON\r\n")
    + (b"WRITE ON\r\n" if os.environ.get("UMIX_TFTP") == "1" else b";WRITE ON\r\n")
    + (b"TFTP ON\r\n" if os.environ.get("UMIX_TFTP") == "1" else b";TFTP ON\r\n")
    + (b"MUX OFF\r\n" if use_tcp else b";MUX OFF\r\n")
    + (b"SLIP ON\r\n" if use_tcp else b";SLIP ON\r\n")
    + (b"TCP ON\r\n" if use_tcp else b";TCP ON\r\n")
    + (b"CHAT ON\r\n" if os.environ.get("UMIX_CHAT") == "1"
       else b"CHAT OFF\r\n" if os.environ.get("UMIX_CHAT") == "0"
       else b";CHAT ON\r\n")
    + b";WEB ON\r\n"
    + b";BAUD 9600\r\n"
    + b"API ROUTE /api/demo APIHELLO.BAS\r\n"
    + b"API ROUTE /api/echo ECHO.BAS\r\n"
)
s8, n8 = add_file(b"STARTUP JCL", startup)
root_entry(b"STARTUP JCL", s8, n8)

for i, e in enumerate(entries):
    img[(ROOT * SECTOR) + i * 32:(ROOT * SECTOR) + (i + 1) * 32] = e

img[FAT1 * SECTOR:(FAT1 + FAT_SECS) * SECTOR] = fat
img[FAT2 * SECTOR:(FAT2 + FAT_SECS) * SECTOR] = fat

out = Path("build/testc.img")
out.write_bytes(img)
print(f"{out}  {len(img)} bytes  FAT16 {SPC*SECTOR}B/cluster  "
      f"UMIX.SYS {n1} @{s1}  README.TXT {n2} @{s2}  "
      f"HELLO1.SYS {n3} @{s3}  HELLO2.SYS {n4} @{s4}  SPIN.SYS {n5} @{s5}  "
      f"INDEX.HTM {n6} @{s6}  JOB.JCL {n7} @{s7}  CHAT.SYS {n9} @{s9}")
