; SPIN.SYS - busy loop that never yields (preemption test)
; Prints a line every ~5 seconds (91 timer ticks at 18.2 Hz).
        cpu 8086
        bits 16
        org 0
start:
        mov ax, cs
        mov ds, ax
        mov si, msg0
        mov ah, 1
        int 0x60
        mov ah, 9
        int 0x60
        mov [last], ax
        mov word [count], 0
.loop:
        mov cx, 0x2000
.d:
        loop .d
        mov ah, 9
        int 0x60
        mov dx, ax
        sub ax, [last]
        cmp ax, 91
        jb .loop
        mov [last], dx
        add word [count], 5
        mov bx, [count]
        mov si, msg1
        mov ah, 1
        int 0x60
        mov ah, 2
        int 0x60
        mov si, msg2
        mov ah, 1
        int 0x60
        jmp .loop
msg0    db 'SPIN RUNNING (NO YIELDS)', 10, 0
msg1    db 'SPIN +', 0
msg2    db 'S', 10, 0
last    dw 0
count   dw 0
