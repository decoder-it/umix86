; UMIX/86 - 360 KB floppy boot sector
; Loads 128 sectors (64 KB) from LBA 1 to 1000:0000 and jumps there.
; 8086/8088 real mode only. Geometry: 40 cyl, 2 heads, 9 sectors/track.

        cpu 8086
        bits 16
        org 0x7C00

KERNEL_SEG      equ 0x1000
KERNEL_SECTORS  equ 128

start:
        cli
        xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00
        sti
        mov [drive], dl

        xor ah, ah                      ; reset disk
        mov dl, [drive]
        int 0x13
        jc disk_error

        mov ax, KERNEL_SEG
        mov es, ax
        xor bx, bx
        mov word [lba], 1
        mov cx, KERNEL_SECTORS

load_loop:
        push cx
        mov ax, [lba]
        xor dx, dx
        mov cx, 18                      ; 9 sectors x 2 heads
        div cx
        mov [track], ax                 ; cylinder
        mov ax, dx
        xor dx, dx
        mov cx, 9
        div cx
        mov [head], ax                  ; head 0/1
        inc dx
        mov [sector], dx                ; sector 1..9

        mov ah, 0x02
        mov al, 1
        mov ch, [track]
        mov cl, [sector]
        mov dh, [head]
        mov dl, [drive]
        int 0x13
        jc disk_error

        add bx, 512
        mov ax, [lba]
        inc ax
        mov [lba], ax
        pop cx
        loop load_loop

        mov dl, [drive]
        jmp KERNEL_SEG:0

disk_error:
        mov si, msg_err
        call print
        cli
        hlt
        jmp $

print:
        lodsb
        test al, al
        jz .done
        mov ah, 0x0E
        mov bx, 0x0007
        int 0x10
        jmp print
.done:
        ret

drive   db 0
lba     dw 0
track   dw 0
head    dw 0
sector  dw 0
msg_err db 'UMIX/86: disk read error', 10, 0

        times 510-($-$$) db 0
        dw 0xAA55
