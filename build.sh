#!/bin/sh
set -eu
cd "$(dirname "$0")"

mkdir -p build

# keep the previous artifacts before overwriting them
if [ -f build/kernel.bin ]; then
    STAMP=$(date +%Y%m%d-%H%M%S)
    DEST="archive/$STAMP"
    mkdir -p "$DEST"
    for f in kernel.bin umix86.img umix86-360.img umix.sys tcp.sys chat.sys api.sys versions.txt; do
        [ -f "build/$f" ] && cp "build/$f" "$DEST/"
    done
    ( cd "$DEST" && sha256sum * > MANIFEST.sha256 2>/dev/null ) || true
    echo "archived previous build -> $DEST"
fi

nasm -f bin -o build/boot.bin src/boot.asm
nasm -f bin -o build/kernel.bin src/kernel.asm
nasm -f bin -o build/umix.sys src/sys.asm
nasm -f bin -o build/chat.sys src/chat.asm
nasm -f bin -o build/tcp.sys src/tcp.asm
nasm -f bin -o build/api.sys src/api.asm
nasm -f bin -o build/hello1.sys src/hello1.asm
nasm -f bin -o build/hello2.sys src/hello2.asm
nasm -f bin -o build/spin.sys src/spin.asm
python3 tools/mkimage.py

{
    echo "UMIX/86 build $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "The boot image and UMIX.SYS are a matched pair."
    sha256sum build/kernel.bin build/umix86.img build/umix86-360.img \
        build/umix.sys build/tcp.sys build/api.sys
} > build/versions.txt
cat build/versions.txt

ls -l build/umix86-360.img build/umix86.img build/umix.sys build/chat.sys build/tcp.sys build/hello1.sys build/hello2.sys build/spin.sys
