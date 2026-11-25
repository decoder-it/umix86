; HELLO2.SYS - task demo: print and yield (started with RUN ...)
        cpu 8086
        bits 16
        org 0
start:
        mov ax, cs
        mov ds, ax
        mov es, ax
        mov bx, 8
.line:
        push bx
        mov si, msg
        mov ah, 1
        int 0x60
        mov cx, 0x4000
.dl:
        push cx
        mov ah, 7
        int 0x60
        pop cx
        loop .dl
        pop bx
        dec bx
        jnz .line
        mov ah, 8
        int 0x60
        jmp $
msg     db 'HELLO FROM PROGRAM2', 10, 0
