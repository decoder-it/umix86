#!/bin/sh
# Quick headless test: CGA text plus COM1 at 9600. Quit with Ctrl-A X.
cd "$(dirname "$0")"
exec qemu-system-i386 -machine isapc -m 1M \
    -drive file=build/umix86-360.img,format=raw,if=floppy -boot a \
    -display none -serial stdio -monitor none
