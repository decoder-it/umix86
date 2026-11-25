#!/usr/bin/env python3
"""Upload a file to UMIX/86 through the bridge's --upload-listen port.

usage: umix_put.py HOST:PORT FILE [REMOTE.NAME]
Sends "PUT NAME SIZE\n" + raw bytes; the guest writes it to the root of the
mounted volume (C: at boot) and replies OK/ERR.
"""
import os
import socket
import sys

MAX = 8192

def main() -> int:
    if len(sys.argv) < 3:
        print("usage: umix_put.py HOST:PORT FILE [REMOTE.NAME]")
        return 2
    hostport, path = sys.argv[1], sys.argv[2]
    remote = (sys.argv[3] if len(sys.argv) > 3 else os.path.basename(path)).upper()
    if len(remote) > 12:
        print("remote name too long (8.3)")
        return 2
    data = open(path, "rb").read()
    if not data:
        print("empty file")
        return 2
    if len(data) > MAX:
        print(f"file too large ({MAX} bytes max)")
        return 2
    host, port = hostport.rsplit(":", 1)
    s = socket.create_connection((host, int(port)), timeout=10)
    s.settimeout(60)
    s.sendall(("PUT %s %d\n" % (remote, len(data))).encode("ascii") + data)
    out = bytearray()
    try:
        while True:
            d = s.recv(4096)
            if not d:
                break
            out.extend(d)
    except socket.timeout:
        pass
    s.close()
    text = out.decode("latin1", errors="replace").strip()
    print(text or "(no response)")
    return 0 if text.startswith("OK") else 1

if __name__ == "__main__":
    sys.exit(main())
