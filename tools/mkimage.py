#!/usr/bin/env python3
"""Build the UMIX/86 360 KB floppy images.

    build/umix86-360.img  full 368,640-byte 360 KB image (emulators/Gotek)
    build/umix86.img      512-byte boot + 64 KiB kernel area (rawrite/FDIMAGE)
"""
import re
import subprocess
from pathlib import Path

def version():
    src = Path("src/kernel.asm").read_text(errors="ignore")
    m = re.search(r"V0R\d+", src)
    return m.group(0) if m else "dev"

BOOT = Path("build/boot.bin")
KERN = Path("build/kernel.bin")
FULL = Path("build/umix86-360.img")
PART = Path("build/umix86.img")

SECTOR = 512
KERNEL_AREA = 128 * SECTOR          # the boot sector loads 128 sectors
DISK = 40 * 2 * 9 * SECTOR          # 368,640 bytes

boot = BOOT.read_bytes()
kern = KERN.read_bytes()
if len(boot) != SECTOR:
    raise SystemExit(f"boot.bin is {len(boot)} bytes, expected {SECTOR}")
if len(kern) > KERNEL_AREA:
    raise SystemExit(f"kernel.bin is {len(kern)} bytes, max {KERNEL_AREA}")

part = bytearray(SECTOR + KERNEL_AREA)
part[0:SECTOR] = boot
part[SECTOR:SECTOR + len(kern)] = kern
PART.write_bytes(part)

full = bytearray(DISK)
full[0:SECTOR] = boot
full[SECTOR:SECTOR + len(kern)] = kern
FULL.write_bytes(full)

# versioned copies: one image set per release, never overwritten
ver = version()
stem = f"umix_version_86_{ver}"
arc = Path("archive/versions")
arc.mkdir(parents=True, exist_ok=True)
ver_part = arc / f"{stem}.img"
ver_full = arc / f"{stem}_360.img"
ver_part.write_bytes(part)
ver_full.write_bytes(full)

print(f"boot     {len(boot)} bytes")
print(f"kernel   {len(kern)} bytes")
print(f"{PART}  {len(part)} bytes")
print(f"{FULL}  {len(full)} bytes")
print(f"{ver_part}  {len(part)} bytes   ({ver})")
print(f"{ver_full}  {len(full)} bytes   ({ver})")

# keep the checksum list in step with the snapshots
try:
    subprocess.run("sha256sum umix_version_* > MANIFEST.sha256", shell=True,
                   cwd=arc, check=False)
except Exception:
    pass
