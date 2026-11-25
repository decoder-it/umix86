; UMIX/86 V0R138 - 8088 kernel
; Floppy boot; reads the DOS FAT12/16 volume on C: (80h) and loads UMIX.SYS
; from the root directory into 2000:0000, then far-calls it.  The SYS overlay
; installs INT 61h (shell command hook) and uses INT 60h (kernel API):
;   60h AH=0 putc AL       AH=1 puts DS:SI      AH=2 put_dec BX
;   AH=4 load file: DS:SI 11-byte 8.3 name, ES:BX dest, CX max -> DX size, CF
;   AH=5 read C: LBA: DI = LBA, ES:BX dest -> CF
;   AH=6 FS info: ES:BX <- root_lba, root_secs, root_ents (words)
;   AH=7 yield      AH=8 exit      AH=9 ticks -> AX (18.2 Hz)

        cpu 8086
        bits 16
        org 0

KERNEL_SEG      equ 0x1000
STACK_SEG       equ 0x8000
HDD_DL          equ 0x80
SYS_SEG         equ 0x2000
CHAT_SEG        equ 0x2900
; Chat history + API chat sessions live in the (TCP/CHAT-unused) 0x2900 window.
; Layout (byte offsets in CHATAPI_SEG = CHAT_SEG):
;   0  ch_head   db   next write slot
;   1  ch_cnt    db   entries held (0..CH_N)
;   2  ch_seq    dw   last assigned sequence
;   4  ch_ent    CH_N * CH_ESZ: dw seq ; db line[70]
;   ... then SESS_N * SESS_SZ API session records, then SESS_NEXT dw
CHATAPI_SEG     equ CHAT_SEG
CH_N            equ 16
CH_ESZ          equ 72
CH_HEAD         equ 0
CH_CNT          equ 1
CH_SEQ          equ 2
CH_ENT          equ 4
CH_LINE         equ 2
SESS_N          equ 8
SESS_SZ         equ 14          ; used(1) token(2) nick(10) pad(1)
SESS_ENT        equ CH_ENT + CH_N*CH_ESZ
SESS_NEXT       equ SESS_ENT + SESS_N*SESS_SZ
API_LIST        equ 0x500       ; '  API: nick nick' built by API.SYS
API_SEG         equ 0x9000      ; CHAT.SYS overlay (gap below task code)
TCP_SEG         equ 0x2900      ; TCP.SYS overlay (same window, load one)
BUF_SEG         equ 0x6C00      ; 16 KB free window above the task stacks
TFBUF_SEG       equ 0x6E00      ; second half: TFTP window buffer (8 KB)
UPBUF_OFF       equ 0
RAMSEG          equ 0x7000
MAXLINES        equ 48
RAMSECT         equ 128
PHIST_SEG       equ 0x5000      ; scrollback ring lives in this free segment
PH_LINES        equ 128         ; 128 lines x 80 bytes
MAXSER          equ 10
NSLOTS          equ MAXSER+3   ; 0=CGA, 1..10 serial, 11..12 programs
MUX_TX_MAX      equ 64
MUX_RX_SIZE     equ 256
STARTUP_MAX     equ 512         ; C:\STARTUP.JCL scratch buffer

start:
        cli
        mov ax, KERNEL_SEG
        mov ds, ax
        mov [boot_dl], dl               ; BIOS boot drive (0/1 = floppy)
        mov es, ax
        mov ax, STACK_SEG
        mov ss, ax
        mov sp, 0xFFFE
        sti
        cld

        call serial_init
        call video_init
        mov si, s_boot_hello
        call boot_msg
        mov si, s_video_state
        call puts
        cmp byte [mono], 0
        je .vidcol
        mov si, s_mono
        jmp .vidmsg
.vidcol:
        mov si, s_color
.vidmsg:
        call puts

        ; INT 60h (API) and INT 61h (default: not handled)
        push es
        xor ax, ax
        mov es, ax
        mov word [es:0x180], int60
        mov word [es:0x182], KERNEL_SEG
        mov word [es:0x184], int61_default
        mov word [es:0x186], KERNEL_SEG
        mov ax, [es:0x20]
        mov [old08], ax
        mov ax, [es:0x22]
        mov [old08+2], ax
        mov word [es:0x20], int08_new
        mov word [es:0x22], KERNEL_SEG
        pop es

        mov byte [task_state], 1        ; shell = task 0

        mov si, banner
        call puts
        call measure_cpu
        call build_cpu_line
        ; remember the boot sector so FORMAT can refuse to wipe this disk
        mov byte [disk_ram], 0
        mov al, [boot_dl]
        mov [disk_dl], al
        mov word [spt], 9
        mov word [heads], 2
        xor ax, ax
        call hdd_read
        jc .bsig
        mov ax, [secbuf]
        mov [boot_sig], ax
        mov ax, [secbuf+2]
        mov [boot_sig+2], ax
.bsig:
        mov byte [disk_dl], 0x80
        call fat_mount
        cmp byte [fs_ok], 0
        jne .hasc
        mov byte [disk_ram], 1
        mov byte [disk_dl], 0
        call ram_format
        call fat_mount
        mov si, s_boot_ram
        call boot_msg
        jmp .diskdone
.hasc:
        mov si, s_boot_disk
        call boot_msg
.diskdone:
        call users_load
        mov si, s_boot_users
        call boot_msg
        call load_sys
        mov si, s_boot_sys
        call boot_msg
        call load_chat
        call load_api
        cmp byte [chat_ok], 0
        je .nochat_ld
        mov si, s_boot_chat
        call boot_msg
.nochat_ld:
        call boot_mode_prompt           ; [N]ORMAL or [T]RANSFER on COM1
        jnc .no_transfer
        call transfer_mode
.no_transfer:
        call startup_run                ; C:\STARTUP.JCL, once, before sessions
        mov si, s_boot_sessions
        call boot_msg
        cmp byte [slip_mode], 0
        jne .no_shell1
        cmp byte [mux_mode], 0
        jne .no_shell1
        call spawn_shell1
.no_shell1:
        mov byte [task_out], 0          ; CGA shell stops mirroring to COM1
        mov si, s_boot_ready
        call boot_msg

shell:
        call pager_reset
        mov ax, KERNEL_SEG
        mov es, ax
        mov al, [cur_task]
        xor ah, ah
        mov bx, 160
        mul bx
        add ax, shellbuf
        mov bp, ax
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        cmp byte [task_out+si], 0
        jne .sp
        cmp byte [cga_panel], 0
        je .plain
        jmp shell_panel
.sp:
        cmp byte [task_out+si], 1
        jne .plain
        cmp byte [ser_panel+si], 0
        je .plain
        jmp shell_serial_panel
.plain:
        mov si, prompt
        call puts
        mov di, bp
        xor cx, cx
.read:
        push bp
        push cx
        push di
        call getline_char
        pop di
        pop cx
        pop bp
        cmp al, 13
        je .enter
        cmp al, 10
        je .enter
        cmp al, 8
        je .back
        cmp al, 127
        je .back
        cmp al, 32
        jb .read
        cmp cx, 120
        jae .read
        push ax
        mov ax, KERNEL_SEG
        mov es, ax
        pop ax
        cld
        stosb
        inc cx
        call putc
        jmp .read
.back:
        test cx, cx
        jz .read
        dec cx
        dec di
        mov al, 8
        call putc
        mov al, ' '
        call putc
        mov al, 8
        call putc
        jmp .read
.enter:
        mov al, 10
        call putc
        mov byte [di], 0
        call execute
        jmp shell

; ---- command dispatch ----

execute:
        cld
        mov ax, KERNEL_SEG
        mov es, ax
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        mov byte [pager_count+si], 0
        mov si, bp
.skip:
        mov al, [si]
        cmp al, ' '
        jne .start
        inc si
        jmp .skip
.start:
        cmp al, 0
        je .ret
        mov di, bp
        add di, 128
        xor cx, cx
.copy:
        mov al, [si]
        cmp al, 0
        je .endtok
        cmp al, ' '
        je .endtok
        cmp al, 'a'
        jb .store
        cmp al, 'z'
        ja .store
        sub al, 32
.store:
        stosb
        inc si
        inc cx
        cmp cx, 15
        jb .copy
.endtok:
        mov byte [di], 0
.skip2:
        mov al, [si]
        cmp al, ' '
        jne .argdone
        inc si
        jmp .skip2
.argdone:
        mov [bp+144], si

        mov si, bp
        add si, 128
        mov di, s_echo
        call streq
        cmp al, 1
        je .echo

        mov si, bp
        add si, 128
        mov di, s_chat_user
        call streq
        cmp al, 1
        je .chatcmd

        mov si, bp
        add si, 128
        mov di, s_cls
        call streq
        cmp al, 1
        je .cls

        mov si, bp
        add si, 128
        mov di, s_mem
        call streq
        cmp al, 1
        je .mem

        mov si, bp
        add si, 128
        mov di, s_time
        call streq
        cmp al, 1
        je .time

        mov si, bp
        add si, 128
        mov di, s_ver
        call streq
        cmp al, 1
        je .ver

        mov si, bp
        add si, 128
        mov di, s_video
        call streq
        cmp al, 1
        je .videocmd

        mov si, bp
        add si, 128
        mov di, s_panel
        call streq
        cmp al, 1
        je .panelcmd

        mov si, bp
        add si, 128
        mov di, s_preempt
        call streq
        cmp al, 1
        je .preemptcmd

        mov si, bp
        add si, 128
        mov di, s_fmt_cmd
        call streq
        cmp al, 1
        je .formatcmd

        mov si, bp
        add si, 128
        mov di, s_mux_cmd
        call streq
        cmp al, 1
        je .muxcmd

        mov si, bp
        add si, 128
        mov di, s_slip_cmd
        call streq
        cmp al, 1
        je .slipcmd

        mov si, bp
        add si, 128
        mov di, s_tcp_cmd
        call streq
        cmp al, 1
        je .tcpcmd

        mov si, bp
        add si, 128
        mov di, s_tcplog_cmd
        call streq
        cmp al, 1
        je .tcplogcmd

        mov si, bp
        add si, 128
        mov di, s_baud_cmd
        call streq
        cmp al, 1
        je .baudcmd

        mov si, bp
        add si, 128
        mov di, s_web_cmd
        call streq
        cmp al, 1
        je .webcmd

        mov si, bp
        add si, 128
        mov di, s_weblog_cmd
        call streq
        cmp al, 1
        je .weblogcmd

        mov si, bp
        add si, 128
        mov di, s_tftp_cmd
        call streq
        cmp al, 1
        je .tftpcmd

        mov si, bp
        add si, 128
        mov di, s_tftplog_cmd
        call streq
        cmp al, 1
        je .tftplogcmd

        mov si, bp
        add si, 128
        mov di, s_speed
        call streq
        cmp al, 1
        je .speedcmd

        mov si, bp
        add si, 128
        mov di, s_quantum
        call streq
        cmp al, 1
        je .quantumcmd

        mov si, bp
        add si, 128
        mov di, s_priv_cmd
        call streq
        cmp al, 1
        je .privcmd

        mov si, bp
        add si, 128
        mov di, s_more_cmd
        call streq
        cmp al, 1
        je .morecmd

        mov si, bp
        add si, 128
        mov di, s_users_cmd
        call streq
        cmp al, 1
        je .userscmd

        mov si, bp
        add si, 128
        mov di, s_user_cmd
        call streq
        cmp al, 1
        je .usercmd

        mov si, bp
        add si, 128
        mov di, s_who
        call streq
        cmp al, 1
        je .whocmd

        mov si, bp
        add si, 128
        mov di, s_whoami
        call streq
        cmp al, 1
        je .whoamicmd

        mov si, bp
        add si, 128
        mov di, s_logoff
        call streq
        cmp al, 1
        je .logoffcmd

        mov si, bp
        add si, 128
        mov di, s_drive
        call streq
        cmp al, 1
        je .drivecmd

        mov si, bp
        add si, 128
        mov di, s_copy_cmd
        call streq
        cmp al, 1
        je .copycmd

        mov si, bp
        add si, 128
        mov di, s_write
        call streq
        cmp al, 1
        je .writecmd

        mov si, bp
        add si, 128
        mov di, s_save
        call streq
        cmp al, 1
        je .savecmd

        mov si, bp
        add si, 128
        mov di, s_del
        call streq
        cmp al, 1
        je .delcmd

        mov si, bp
        add si, 128
        mov di, s_kill
        call streq
        cmp al, 1
        je .killcmd

        mov si, bp
        add si, 128
        mov di, s_run
        call streq
        cmp al, 1
        je .runcmd

        mov si, bp
        add si, 128
        mov di, s_sys
        call streq
        cmp al, 1
        je .syscmd

        mov si, bp
        add si, 128
        mov di, s_reboot
        call streq
        cmp al, 1
        je .reboot

        mov si, bp
        add si, 128
        mov di, s_halt
        call streq
        cmp al, 1
        je .halt

        mov si, bp
        add si, 128
        mov di, s_edit
        call streq
        cmp al, 1
        je .editcmd

        ; not a kernel command: let the SYS overlay try
        mov si, bp
        add si, 128
        mov di, [bp+144]
        int 0x61
        jnc .ret
        mov si, s_unknown
        call puts
        jmp .ret

.echo:
        mov si, [bp+144]
        call puts
        mov al, 10
        call putc
        jmp .ret
.chatcmd:
        call do_chat
        jmp .ret
.cls:
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        cmp byte [task_out+si], 0
        jne .cls2
        call panel_init
        jmp .ret
.cls2:
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        cmp byte [task_out+si], 1
        jne .cls3
        cmp byte [ser_panel+si], 0
        jne .clspan
        mov si, sp_clear
        call sp_str
        mov si, sp_reset
        call sp_str
        jmp .ret
.clspan:
        mov byte [sp_cleared+si], 0
        call sp_prompt
        jmp .ret
.cls3:
        mov ax, 3
        call bios_video
        jmp .ret
.mem:
        mov si, s_memory
        call puts
        int 0x12
        call put_dec
        mov si, s_kb
        call puts
        mov al, 10
        call putc
        jmp .ret
.time:
        mov si, s_time_is
        call puts
        mov ah, 2
        int 0x1A
        cld
        mov al, ch
        call put_bcd
        mov al, ':'
        call putc
        mov al, cl
        call put_bcd
        mov al, ':'
        call putc
        mov al, dh
        call put_bcd
        mov al, 10
        call putc
        jmp .ret
.ver:
        mov si, banner
        call puts
        jmp .ret
.videocmd:
        call do_video
        jmp .ret
.panelcmd:
        call do_panel
        jmp .ret
.muxcmd:
        call do_mux
        jmp .ret
.slipcmd:
        call do_slip
        jmp .ret
.tcpcmd:
        call do_tcp
        jmp .ret
.tcplogcmd:
        call do_tcplog
        jmp .ret
.formatcmd:
        call do_format
        jmp .ret
.baudcmd:
        call do_baud
        jmp .ret
.webcmd:
        call do_web
        jmp .ret
.weblogcmd:
        call do_weblog
        jmp .ret
.tftpcmd:
        call do_tftp
        jmp .ret
.tftplogcmd:
        call do_tftplog
        jmp .ret
.speedcmd:
        call measure_cpu
        call build_cpu_line
        mov si, cpu_line
        call puts
        mov al, 10
        call putc
        jmp .ret
.quantumcmd:
        call do_quantum
        jmp .ret
.privcmd:
        call do_priv
        jmp .ret
.morecmd:
        call do_more
        jmp .ret
.userscmd:
        call do_users
        jmp .ret
.usercmd:
        call do_user
        jmp .ret
.preemptcmd:
        call do_preempt
        jmp .ret
.whocmd:
        call do_who
        jmp .ret
.whoamicmd:
        call do_whoami
        jmp .ret
.logoffcmd:
        call do_logoff
        jmp .ret
.drivecmd:
        call do_drive
        jmp .ret
.copycmd:
        call do_copy
        jmp .ret
.writecmd:
        call do_write
        jmp .ret
.savecmd:
        call do_save
        jmp .ret
.delcmd:
        call do_delete
        jmp .ret
.killcmd:
        call do_kill
        jmp .ret
.runcmd:
        call do_run
        jmp .ret
.editcmd:
        call do_edit
        jmp .ret
.syscmd:
        call load_sys
        jmp .ret
.reboot:
        int 0x19
        jmp .ret
.halt:
        cli
.halt_loop:
        hlt
        jmp .halt_loop
.ret:
        ret

; ---- string compare: SI vs DI, AL=1 equal, AL=0 different ----

streq:
        push si
        push di
.loop:
        mov al, [si]
        cmp al, [di]
        jne .no
        test al, al
        jz .yes
        inc si
        inc di
        jmp .loop
.no:
        pop di
        pop si
        mov al, 0
        ret
.yes:
        pop di
        pop si
        mov al, 1
        ret

; ---- BIOS video wrapper ----
; Some BIOSes clobber DS/ES/BP/DI in INT 10h.  The kernel keeps its data in
; DS=KERNEL_SEG and the shell read loop keeps its write pointer in DI, so call
; the video BIOS through this wrapper instead of issuing INT 10h directly.
bios_video:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        push es
        int 0x10
        cld
        pop es
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---- case-insensitive string compare: SI vs DI, AL=1 equal ----

streqi:
        push si
        push di
        push bx
.sl:
        mov al, [si]
        call upcase
        mov bl, al
        mov al, [di]
        call upcase
        cmp al, bl
        jne .sno
        test bl, bl
        jz .syes
        inc si
        inc di
        jmp .sl
.sno:
        pop bx
        pop di
        pop si
        mov al, 0
        ret
.syes:
        pop bx
        pop di
        pop si
        mov al, 1
        ret

; ---- output ----

putc:
        push ds
        push ax
        mov ax, KERNEL_SEG
        mov ds, ax
        inc byte [crit]
        pop ax
        cmp al, 10
        jne .plain
        mov al, 13
        call putc1
        mov al, 10
.plain:
        call putc1
        push ax
        mov ax, KERNEL_SEG
        mov ds, ax
        dec byte [crit]
        pop ax
        pop ds
        cmp al, 10
        jne .putdone
        call pager_line
.putdone:
        ret

; ---- output pager (MORE ON|OFF|LINES) ----
pager_reset:
        push ax
        push bx
        mov bl, [cur_task]
        xor bh, bh
        mov byte [pager_count+bx], 0
        pop bx
        pop ax
        ret

pager_line:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        mov ax, KERNEL_SEG
        mov ds, ax
        cmp byte [pager_hold], 0
        jne .done
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [pager_bypass+bx], 0
        jne .done
        cmp byte [pager_on+bx], 0
        je .done
        inc byte [pager_count+bx]
        mov al, [pager_lines+bx]
        cmp al, [pager_count+bx]
        ja .done
        mov byte [pager_count+bx], 0
        mov byte [pager_hold], 1
        mov si, s_pager_prompt
        call puts
        call getline_char
        cmp al, 13
        je .resume
        cmp al, 10
        je .resume
        mov bl, [cur_task]
        xor bh, bh
        mov byte [pager_on+bx], 0
.resume:
        mov byte [pager_hold], 0
.done:
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; AL = char; console chosen by task_out[cur_task] (0 CGA, 1 COM1, 2 both)
putc1:
        push ax
        push bx
        push cx
        push dx
        push ds
        mov bx, KERNEL_SEG
        mov ds, bx
        mov bl, [cur_task]
        xor bh, bh
        mov bl, [task_out+bx]
        cmp bl, 1
        je .ser
        cmp bl, 0
        je .cga
        call ser1
        jmp .cga
.ser:
        call ser1
        jmp .done
.cga:
        cmp byte [cga_panel], 0
        jne .pan
        push ax
        mov ah, 0x0E
        mov bx, 0x0007
        inc byte [crit]
        call bios_video
        dec byte [crit]
        pop ax
        jmp .done
.pan:
        call panel_putc
.done:
        pop ds
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ser1:
        cmp byte [mux_mode], 0
        jne ser_tx_byte
ser_raw:
        push ax
        push dx
        mov ah, al
.w:
        mov dx, 0x3FD
        in al, dx
        test al, 0x20
        jz .w
        mov dx, 0x3F8
        mov al, ah
        out dx, al
        pop dx
        pop ax
        ret

; Print the console event header, then let the caller print the message.
; Preserves SI so the caller's `mov si, msg / call puts` still works.
sys_begin:
        push si
        mov si, s_sys_hdr
        call puts
        pop si
        ret

puts:
        push ax
        push si
.next:
        lodsb
        test al, al
        jz .done
        call putc
        jmp .next
.done:
        pop si
        pop ax
        ret

put_ip:                         ; SI -> 4 address bytes
        push ax
        push cx
        push si
        mov cx, 4
.pi_l:
        mov al, [si]
        xor ah, ah
        push cx
        call put_dec
        pop cx
        inc si
        dec cx
        jz .pi_d
        mov al, '.'
        call putc
        jmp .pi_l
.pi_d:
        pop si
        pop cx
        pop ax
        ret

put_dec:
        push ax
        push bx
        push cx
        push dx
        mov bx, 10
        xor cx, cx
.div:
        xor dx, dx
        div bx
        push dx
        inc cx
        test ax, ax
        jnz .div
.print:
        pop ax
        add al, '0'
        call putc
        loop .print
        pop dx
        pop cx
        pop bx
        pop ax
        ret

put_bcd:
        push ax
        push bx
        mov bl, al
        shr al, 1
        shr al, 1
        shr al, 1
        shr al, 1
        add al, '0'
        call putc
        mov al, bl
        and al, 0x0F
        add al, '0'
        call putc
        pop bx
        pop ax
        ret

; ---- input: COM1 polling first, then BIOS keyboard ----

getchar:
        cld
        mov byte [key_scan], 0
.loop:
        mov ah, 7
        int 0x60
        call mux_poll                   ; flush TX / TFTP even in raw or SLIP
        cmp byte [mux_mode], 0
        je .nomux
        call mux_flush_current
.nomux:
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [task_in+bx], 1
        je .serial
        mov ah, 1
        int 0x16
        cld
        jz .loop
        xor ah, ah
        int 0x16
        cld
        test al, al
        jnz .key
        cmp ah, 0x49
        je .pgup
        cmp ah, 0x51
        je .pgdn
        call panel_live_if_hist
        jmp .loop
.pgup:
        cmp byte [cga_panel], 0
        je .loop
        call panel_page_up
        jmp .loop
.pgdn:
        cmp byte [cga_panel], 0
        je .loop
        call panel_page_down
        jmp .loop
.key:
        call panel_live_if_hist
        jmp .got
.serial:
        cmp byte [mux_mode], 0
        je .rawser
        mov bl, [cur_task]
        xor bh, bh
        mov al, [task_inslot+bx]
        test al, al
        jz .gs_self
        mov bl, al
.gs_self:
        mov al, [rx_head+bx]
        cmp al, [rx_tail+bx]
        je .loop
        push cx
        push si
        mov al, bl
        xor ah, ah
        mov cl, 8
        shl ax, cl
        mov si, rx_buf
        add si, ax
        mov al, [rx_head+bx]
        xor ah, ah
        add si, ax
        mov al, [si]
        pop si
        pop cx
        inc byte [rx_head+bx]
        and byte [rx_head+bx], MUX_RX_SIZE-1
        jmp .got
.rawser:
        mov dx, 0x3FD
        in al, dx
        test al, 1
        jz .loop
        mov dx, 0x3F8
        in al, dx
        jmp .got
.got:
        cmp al, 0x1B                    ; ESC: decode an ANSI key sequence
        jne .got2
        call esc_key
        jc .gotunk
        mov [key_scan], ah
        xor al, al
        jmp .got2
.gotunk:
        xor al, al
        xor ah, ah
.got2:
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [task_eat_lf+bx], 0
        je .ret
        mov byte [task_eat_lf+bx], 0
        cmp al, 10
        jne .ret
        jmp .loop
.ret:
        mov ah, [key_scan]
        ret

; ---- ANSI escape-sequence suppressor (serial function keys) ----
; Terminal function keys arrive as ESC [ ... final (PgUp = ESC [ 5 ~).
; Without this the '[' '5' '~' bytes are typed into the command line.
; Swallows the whole sequence and returns nothing worth echoing.

poll_byte:                      ; CF=0 AL=byte, CF=1 nothing pending
        push bx
        push cx
        push dx
        push si
        cmp byte [mux_mode], 0
        je .raw
        mov bl, [cur_task]
        xor bh, bh
        mov al, [task_inslot+bx]
        test al, al
        jz .self
        mov bl, al
.self:
        mov al, [rx_head+bx]
        cmp al, [rx_tail+bx]
        je .none
        mov al, bl
        xor ah, ah
        mov cl, 8
        shl ax, cl
        mov si, rx_buf
        add si, ax
        mov al, [rx_head+bx]
        xor ah, ah
        add si, ax
        mov al, [si]
        inc byte [rx_head+bx]
        and byte [rx_head+bx], MUX_RX_SIZE-1
        clc
        jmp .done
.raw:
        mov dx, 0x3FD
        in al, dx
        test al, 1
        jz .none
        mov dx, 0x3F8
        in al, dx
        clc
        jmp .done
.none:
        stc
.done:
        pop si
        pop dx
        pop cx
        pop bx
        ret

esc_key:                        ; ESC seq -> AH = BIOS scan code, AL = 0
        push bx                         ; CF=1 if the sequence is unknown
        push cx
        push dx
        mov dx, 200
        call .wait
        jc .bad
        cmp al, '['
        je .csi
        cmp al, 'O'
        je .ss3
        jmp .bad
.csi:
        mov dx, 200
        call .wait
        jc .bad
        cmp al, 'A'
        je .up
        cmp al, 'B'
        je .down
        cmp al, 'C'
        je .right
        cmp al, 'D'
        je .left
        cmp al, 'H'
        je .home
        cmp al, 'F'
        je .end
        sub al, '0'
        cmp al, 9
        ja .bad
        mov bl, al
        mov dx, 200
        call .wait
        jc .bad
        cmp al, '~'
        jne .bad
        mov al, bl
        cmp al, 1
        je .home
        cmp al, 2
        je .ins
        cmp al, 3
        je .del
        cmp al, 4
        je .end
        cmp al, 5
        je .pgup
        cmp al, 6
        je .pgdn
        jmp .bad
.ss3:
        mov dx, 200
        call .wait
        jc .bad
        cmp al, 'A'
        je .up
        cmp al, 'B'
        je .down
        cmp al, 'C'
        je .right
        cmp al, 'D'
        je .left
        cmp al, 'H'
        je .home
        cmp al, 'F'
        je .end
        jmp .bad
.up:    mov ah, 0x48
        jmp .ok
.down:  mov ah, 0x50
        jmp .ok
.left:  mov ah, 0x4B
        jmp .ok
.right: mov ah, 0x4D
        jmp .ok
.home:  mov ah, 0x47
        jmp .ok
.end:   mov ah, 0x4F
        jmp .ok
.pgup:  mov ah, 0x49
        jmp .ok
.pgdn:  mov ah, 0x51
        jmp .ok
.ins:   mov ah, 0x52
        jmp .ok
.del:   mov ah, 0x53
        jmp .ok
.bad:
        stc
        jmp .out
.ok:
        xor al, al
        clc
.out:
        pop dx
        pop cx
        pop bx
        ret
.wait:
        push cx
        mov cx, dx
.wb:
        call poll_byte
        jnc .wd
        loop .wb
        pop cx
        stc
        ret
.wd:
        pop cx
        clc
        ret

; line-oriented input: CRLF -> one CR, LF-only -> LF, ignore >=128 (telnet IAC)
getline_char:
        call getchar
        cmp al, 128
        jb .gl_low
        jmp getline_char
.gl_low:
        cmp al, 10
        jne .gl_nl
        cmp byte [eat_lf], 0
        je .gl_ret
        mov byte [eat_lf], 0
        jmp getline_char
.gl_nl:
        cmp al, 13
        jne .gl_other
        mov byte [eat_lf], 1
        ret
.gl_other:
        mov byte [eat_lf], 0
.gl_ret:
        ret

; ---- COM1 9600 8N1 ----

serial_init:
        mov dx, 0x3F9
        xor al, al
        out dx, al
        mov dx, 0x3FB
        mov al, 0x80
        out dx, al
        mov dx, 0x3F8
        mov al, 12
        out dx, al
        mov dx, 0x3F9
        xor al, al
        out dx, al
        mov dx, 0x3FB
        mov al, 3
        out dx, al
        mov dx, 0x3FA
        xor al, al
        out dx, al
        mov dx, 0x3FC
        mov al, 0x0B                    ; DTR|RTS|OUT2 (OUT2 gates IRQ4)
        out dx, al
        cmp byte [mux_mode], 0
        je .done
        call mux_hw_on
.done:
        ret

; Runtime framing toggle: install/remove the IRQ4 receiver.
mux_hw_on:
        cli
        push es
        xor ax, ax
        mov es, ax
        mov word [es:0x30], int0c_serial
        mov word [es:0x32], KERNEL_SEG
        pop es
        mov dx, 0x3FC
        mov al, 0x0B                    ; DTR|RTS|OUT2: enable IRQ4 driver
        out dx, al
        mov dx, 0x3F9
        mov al, 1                       ; RX data available
        out dx, al
        in al, 0x21
        and al, 0xEF                    ; unmask IRQ4
        out 0x21, al
        sti
        ret

mux_hw_off:
        cli
        mov dx, 0x3F9
        xor al, al
        out dx, al                      ; no UART interrupts
        in al, 0x21
        or al, 0x10                     ; mask IRQ4
        out 0x21, al
        sti
        ret

; =====================================================================
; Serial multiplexer: TX framing, IRQ4 RX, session lifecycle
; =====================================================================

ser_tx_byte:                    ; AL = char -> current task's TX buffer
        push bx
        mov bl, [cur_task]
        xor bh, bh
        call tx_slot_append
        pop bx
        ret

; AL = char, BL = slot; append to that slot's framed TX buffer.
; A newline flushes the slot; the buffer-full guard flushes first.
tx_slot_append:
        push ax
        push bx
        push cx
        push si
        push ds
        mov cx, KERNEL_SEG
        mov ds, cx
        cmp byte [tx_len+bx], MUX_TX_MAX
        jb .space
        push ax
        mov al, bl
        call mux_flush
        pop ax
        cmp byte [tx_len+bx], MUX_TX_MAX
        jae .done                      ; still full: drop, never overrun
.space:
        push ax
        mov ax, bx
        mov cl, 7
        shl ax, cl
        mov si, tx_buf
        add si, ax
        mov al, [tx_len+bx]
        xor ah, ah
        add si, ax
        pop ax
        mov [si], al
        inc byte [tx_len+bx]
        cmp al, 10
        jne .done
        mov al, bl
        call mux_flush
.done:
        pop ds
        pop si
        pop cx
        pop bx
        pop ax
        ret

mux_flush:                      ; AL = slot
        push ax
        push bx
        push cx
        push dx
        push si
        mov bl, al
        xor bh, bh
        mov cl, [tx_len+bx]
        xor ch, ch                  ; CX is the frame length below: CH must be 0
        test cl, cl
        jz .done
        mov ax, bx
        mov cl, 7
        shl ax, cl
        mov si, tx_buf
        add si, ax
        mov cl, [tx_len+bx]
        mov dl, [task_term+bx]
        mov al, 0x01                ; DATA
        inc byte [crit]
        call mux_send_frame
        dec byte [crit]
        mov byte [tx_len+bx], 0
.done:
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

mux_flush_current:
        cmp byte [mux_mode], 0
        je .r
        mov al, [cur_task]
        call mux_flush
.r:
        ret

mux_send_frame:                 ; AL=type, DL=termid, SI=payload, CX=len
        cmp al, 0x01                ; DATA for a NET session leaves as UDP
        jne .msf_frame
        cmp dl, 1
        jb .msf_frame
        cmp dl, MAXSER
        ja .msf_frame
        push bx
        mov bl, dl
        xor bh, bh
        cmp byte [ses_tr+bx], 0
        pop bx
        je .msf_frame                   ; flags survive pop
        call udp_send_sess
        ret
.msf_frame:
        push ax
        push bx
        push cx
        push dx
        push si
        mov bl, al
        mov bh, bl
        xor bh, dl
        xor bh, cl
        mov al, 0x02
        call ser_raw
        mov al, bl
        call ser_raw
        mov al, dl
        call ser_raw
        mov al, cl
        call ser_raw
        jcxz .no_pay
        push cx
.pl:
        lodsb
        xor bh, al
        call ser_raw
        loop .pl
        pop cx
.no_pay:
        mov al, bh
        call ser_raw
        mov al, 0x03
        call ser_raw
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

mux_send_ctl:                   ; AL=type, DL=termid, no payload
        push ax
        push cx
        push si
        inc byte [crit]
        xor cx, cx
        call mux_send_frame
        dec byte [crit]
        pop si
        pop cx
        pop ax
        ret

raw_rx_store:                   ; AL = byte -> ring at rx_buf
        push bx
        push si
        mov si, [raw_head]
        mov bx, si
        and bx, 2047
        mov [rx_buf+bx], al
        inc si
        mov [raw_head], si
        pop si
        pop bx
        ret

; raw (unframed) receiver for transfer mode: IRQ4 fills a 2 KB ring, so bytes
; are captured while the main loop writes sectors - the same trick GW-BASIC's
; COM: driver uses.
serial_rx_raw_on:
        cli
        push es
        xor ax, ax
        mov es, ax
        mov word [es:0x30], int0c_serial
        mov word [es:0x32], KERNEL_SEG
        pop es
        mov word [raw_head], 0
        mov word [raw_tail], 0
        mov byte [raw_rx_on], 1
        mov dx, 0x3FC
        mov al, 0x0B
        out dx, al
        mov dx, 0x3F9
        mov al, 1
        out dx, al
        mov dx, 0x3F8
        in al, dx                      ; drop a stale byte
        in al, 0x21
        and al, 0xEF
        out 0x21, al
        sti
        ret

serial_rx_raw_off:
        cli
        mov byte [raw_rx_on], 0
        mov dx, 0x3F9
        xor al, al
        out dx, al
        in al, 0x21
        or al, 0x10
        out 0x21, al
        sti
        ret

; ---------------------------------------------------------------
; UDP terminal sessions, port 2323.
;   payload[0] = terminal id, payload[1] = op, payload[2..] = data
;   client -> guest:  0 DATA, 1 OPEN, 2 CLOSE
;   guest  -> client: 0 DATA, 1 OPEN OK, 3 BUSY
; A NET session still owns a normal task slot: the id is the same terminal id
; the mux would use, so the shell, the input ring and mux_flush are unchanged.
; ---------------------------------------------------------------
UDP_SESS_MAXDATA equ 72         ; session chunk (20 + 8 + 2 + 72)
UDP_PAY_MAX     equ 200         ; builder cap: TFTP DATA 4 + 192

; AL = terminal id -> BL = slot index, 0 when no active slot owns that id
find_slot_term:
        push ax
        push cx
        mov bl, 1
.fst_l:
        cmp bl, MAXSER
        ja .fst_none
        xor bh, bh
        cmp al, [task_term+bx]
        je .fst_hit
        inc bl
        jmp .fst_l
.fst_none:
        xor bx, bx
.fst_hit:
        pop cx
        pop ax
        ret

; AL = terminal id, SI = bytes, CX = count: append to that terminal's input ring
sess_enq:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov bh, 0
        mov bl, al
        call find_slot_term
        test bl, bl
        jz .se_done
        mov al, bl
        xor ah, ah
        push cx
        mov cl, 8
        shl ax, cl
        pop cx
        mov di, rx_buf
        add di, ax
.se_l:
        jcxz .se_done
        mov al, [rx_tail+bx]
        inc al
        and al, MUX_RX_SIZE-1
        cmp al, [rx_head+bx]
        je .se_ovf
        mov al, [rx_tail+bx]
        xor ah, ah
        push di
        add di, ax
        mov al, [si]
        mov [di], al
        pop di
        inc byte [rx_tail+bx]
        and byte [rx_tail+bx], MUX_RX_SIZE-1
        inc si
        dec cx
        jmp .se_l
.se_ovf:
        inc word [mux_rx_overflows]
.se_done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; DI = destination IP (4 bytes), DX = destination port (wire order),
; SI = payload, CX = payload length.  Builds IP+UDP+payload in ipbuf and
; queues it for ip_tx_flush.  Drops the packet if one is already queued or
; the payload is too long.
; udp_build_src: like udp_build but BX = source port (native).  The port is
; programmed with interrupts off so an IRQ4 udp_build cannot overwrite it
; between the store and the header build (the build itself is pure memory).
udp_build_src:
        push ax
        pushf
        cli
        mov [ub_sport], bx
        call udp_build_core
        mov word [ub_sport], UDP_SESS_PORT
        popf
        pop ax
        ret

udp_build:
        mov bx, UDP_SESS_PORT
        jmp udp_build_src

udp_build_core:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov bx, KERNEL_SEG
        mov es, bx
        cmp byte [ip_tx_pending], 0
        jne .ub_out
        cmp cx, UDP_PAY_MAX
        ja .ub_out
        pushf
        cli                             ; ipbuf is shared with the IRQ input path
        mov [ub_si], si
        mov [ub_cx], cx
        mov [ub_dx], dx
        mov [ub_di], di
        mov di, ipbuf
        mov al, 0x45
        stosb                           ; version/IHL
        xor al, al
        stosb                           ; TOS
        mov ax, [ub_cx]
        add ax, 28
        xchg al, ah
        stosw                           ; total length
        xor ax, ax
        stosw                           ; id
        stosw                           ; flags/fragment
        mov al, 0x40
        stosb                           ; TTL
        mov al, 17
        stosb                           ; UDP
        xor ax, ax
        stosw                           ; header checksum placeholder
        mov si, ip_my_addr
        movsw
        movsw                           ; source
        mov si, [ub_di]
        movsw
        movsw                           ; destination
        mov ax, [ub_sport]
        xchg al, ah
        stosw                           ; source port
        mov ax, [ub_dx]
        stosw                           ; destination port
        mov ax, [ub_cx]
        add ax, 8
        xchg al, ah
        stosw                           ; UDP length
        xor ax, ax
        stosw                           ; checksum: optional for IPv4
        mov si, [ub_si]
        mov cx, [ub_cx]
        rep movsb
        xor ax, ax
        mov si, ipbuf
        mov cx, 20
        call ip_csum
        mov [ipbuf+10], ax
        mov ax, [ub_cx]
        add ax, 28
        mov [ip_tx_len], ax
        mov byte [ip_tx_pending], 1
        popf
.ub_out:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; DL = terminal id, SI = bytes, CX = count: send terminal output as UDP DATA.
; Chunks to UDP_SESS_MAXDATA; drops the remainder if a packet is already queued.
udp_send_sess:
        push ax
        push bx
        push bp
        push cx
        push dx
        push si
        push di
        mov bl, dl
        xor bh, bh
.us_l:
        test cx, cx
        jz .us_done
        cmp byte [ip_tx_pending], 0
        je .us_ok
        call ip_tx_flush                ; task context: drain, never drop output
.us_ok:
        mov ax, cx
        cmp ax, UDP_SESS_MAXDATA
        jbe .us_have
        mov ax, UDP_SESS_MAXDATA
.us_have:
        mov [ub_n], ax
        mov di, ub_pay
        mov [di], dl                    ; terminal id
        mov byte [di+1], 0              ; DATA
        add di, 2
        mov bp, ax                      ; bytes to copy (AX is destroyed below)
.us_cp:
        mov al, [si]
        mov [di], al
        inc si
        inc di
        dec bp
        jnz .us_cp
        sub cx, [ub_n]
        mov [ub_rem], cx
        mov si, bx
        shl si, 1
        shl si, 1
        mov di, ses_ip
        add di, si
        mov si, bx
        shl si, 1
        mov dx, [ses_port+si]
        mov si, ub_pay
        mov cx, [ub_n]
        add cx, 2
        call udp_build
        call ip_tx_flush                ; task context: send now, do not drop the burst
        mov cx, [ub_rem]
        jmp .us_l
.us_done:
        pop di
        pop si
        pop dx
        pop cx
        pop bp
        pop bx
        pop ax
        ret

; AL = mux control code (4 BUSY, 5 ACK), DL = terminal id.
; Routes over UDP for a NET session, over the mux frame otherwise.
sess_ctl:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov bl, dl
        xor bh, bh
        cmp bl, 1
        jb .sc_mux
        cmp bl, MAXSER
        ja .sc_mux
        cmp byte [ses_tr+bx], 0
        je .sc_mux
        mov di, ub_pay
        mov [di], dl
        mov byte [di+1], 1              ; open OK
        cmp al, 5
        je .sc_udp
        mov byte [di+1], 3              ; busy
.sc_udp:
        mov ax, bx
        shl ax, 1
        shl ax, 1
        mov di, ses_ip
        add di, ax
        mov ax, bx
        shl ax, 1
        mov si, ses_port
        add si, ax
        mov dx, [si]
        mov si, ub_pay
        mov cx, 2
        call udp_build
        call ip_tx_flush
        jmp .sc_done
.sc_mux:
        call mux_send_ctl
.sc_done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; AX = internet checksum of DS:SI, CX bytes.  Clobbers AX,BX,CX,DX,SI.
ip_csum:
        push cx
        push si
        xor bx, bx
.cs_l:
        cmp cx, 2
        jb .cs_t
        mov ax, [si]
        add bx, ax
        adc bx, 0
        add si, 2
        sub cx, 2
        jmp .cs_l
.cs_t:
        test cx, cx
        jz .cs_d
        xor ax, ax
        mov al, [si]
        mov ah, al
        xor al, al
        add bx, ax
        adc bx, 0
.cs_d:
        mov ax, bx
        not ax
        pop si
        pop cx
        ret

; parse a frame from mux_payload; answer ICMP echo requests and UDP on the
; terminal-session port
UDP_SESS_PORT   equ 2323        ; compared as a native word after byte swap

ip_input:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov cx, [mux_idx]
        cmp cx, 20
        jb .ip_out
        mov si, mux_payload
        cmp byte [si], 0x45             ; IPv4, no options
        jne .ip_out
        mov ax, [si+2]                  ; total length (big-endian on the wire)
        xchg al, ah                     ; -> native 16-bit for use as a count
        cmp ax, cx
        ja .ip_out
        cmp ax, 28                      ; IP + ICMP header
        jb .ip_out
        mov [ip_len], ax
        mov cx, 20
        call ip_csum
        test ax, ax                     ; 0 = header checksum good
        jnz .ip_out
        mov si, mux_payload
        mov ax, [si+16]                 ; destination address must be ours
        cmp ax, [ip_my_addr]
        jne .ip_out
        mov ax, [si+18]
        cmp ax, [ip_my_addr+2]
        jne .ip_out
        cmp byte [si+9], 1              ; ICMP
        je .icmp
        cmp byte [si+9], 17             ; UDP
        je .udp
        cmp byte [si+9], 6              ; TCP
        je .tcp
        jmp .ip_out
.tcp:
        cmp byte [tcp_loaded], 0
        je .ip_out
        push es
        mov ax, TCP_SEG
        mov es, ax
        cmp byte [es:0x2000], 0
        je .tcp_put
        ; mailbox busy: a pure ACK (40 bytes) supersedes an older ACK.
        ; TCP ACKs are cumulative, so keeping the newest one is what a
        ; window needs; dropping it stranded the sender.
        cmp word [ip_len], 40
        jne .tcp_done
.tcp_put:
        mov di, 0x2003
        mov si, mux_payload
        mov cx, [ip_len]
        rep movsb
        mov ax, [ip_len]
        mov [es:0x2001], ax
        mov byte [es:0x2000], 1
.tcp_done:
        pop es
        jmp .ip_out
.icmp:
        cmp byte [si+20], 8             ; echo request
        jne .ip_out
        cmp byte [si+21], 0
        jne .ip_out

        ; ICMP: type 0, recompute checksum
        mov byte [si+20], 0
        mov word [si+22], 0
        add si, 20
        mov cx, [ip_len]
        sub cx, 20
        call ip_csum
        mov si, mux_payload
        mov [si+22], ax
        jmp .ip_reply
.udp:
        cmp word [ip_len], 28           ; IP header + UDP header
        jb .ip_out
        mov dx, [si+22]                 ; destination port
        xchg dl, dh
        mov ax, [si+24]                 ; UDP length
        xchg al, ah
        cmp ax, 8
        jb .ip_out
        mov bx, [ip_len]
        sub bx, 20
        cmp ax, bx                      ; beyond the IP payload?
        ja .ip_out
        cmp ax, 10                      ; session header is 2 bytes
        jb .ip_out
        mov [udp_ulen], ax
        cmp dx, UDP_SESS_PORT
        jne .udp_other
        mov si, mux_payload
        add si, 28                      ; UDP payload
        cmp byte [si+1], 1
        je .udp_open
        cmp byte [si+1], 0
        je .udp_data
        cmp byte [si+1], 2
        je .udp_close
        jmp .ip_out
.udp_other:
        cmp dx, TFTP_PORT
        je .udp_tftp
        cmp dx, [tf_tid]
        je .udp_tftp
        jmp .ip_out
.udp_tftp:
        ; TFTP: only queue one packet; tftp_step does the disk work in task
        ; context (this path runs with interrupts off / inside the IRQ4 ISR).
        cmp byte [tf_enabled], 0
        je .ip_out
        cmp byte [tf_pending], 0
        jne .ip_out
        sub ax, 8
        cmp ax, TFTP_RXMAX
        ja .ip_out
        mov [tf_rxlen], ax
        mov ax, [mux_payload+12]        ; source IP
        mov [tf_qip], ax
        mov ax, [mux_payload+14]
        mov [tf_qip+2], ax
        mov ax, [mux_payload+20]        ; source port (wire order)
        mov [tf_qport], ax
        mov si, mux_payload
        add si, 28
        mov di, tf_rxbuf
        push es
        push ds
        pop es
        mov cx, [tf_rxlen]
        rep movsb
        pop es
        mov bx, [tf_rxlen]
        mov byte [tf_rxbuf+bx], 0
        mov byte [tf_pending], 1
        jmp .ip_out
.udp_data:
        mov al, [si]
        test al, al
        jz .ip_out
        cmp al, MAXSER
        ja .ip_out
        mov bl, al
        xor bh, bh
        cmp byte [ses_tr+bx], 0
        je .ip_out
        add si, 2
        mov cx, [udp_ulen]
        sub cx, 10                      ; UDP + session header
        test cx, cx
        jz .ip_out
        call sess_enq
        jmp .ip_out
.udp_open:
        ; remember who asked, in case we have to answer BUSY
        mov ax, [mux_payload+12]
        mov [req_ip], ax
        mov ax, [mux_payload+14]
        mov [req_ip+2], ax
        mov ax, [mux_payload+20]
        mov [req_port], ax
        mov bl, 1
.uo_l:
        cmp bl, MAXSER
        ja .uo_busy
        xor bh, bh
        mov [udp_cand], bl
        cmp byte [ses_tr+bx], 0
        jne .uo_next
        cmp byte [mux_open_pending+bx], 0
        jne .uo_next
        mov al, bl                      ; a serial session may already own this id
        call find_slot_term
        test bl, bl
        jz .uo_free
.uo_next:
        mov bl, [udp_cand]
        inc bl
        jmp .uo_l
.uo_free:
        mov bl, [udp_cand]
        jmp .uo_claim
.uo_busy:
        mov di, req_ip
        mov dx, [req_port]
        mov si, ub_pay
        mov byte [si], 0
        mov byte [si+1], 3              ; BUSY
        mov cx, 2
        call udp_build
        jmp .ip_out
.uo_claim:
        mov al, bl
        xor ah, ah
        mov si, ax
        shl si, 1
        shl si, 1                       ; id * 4
        mov al, [req_ip]
        mov [ses_ip+si], al
        mov al, [req_ip+1]
        mov [ses_ip+si+1], al
        mov al, [req_ip+2]
        mov [ses_ip+si+2], al
        mov al, [req_ip+3]
        mov [ses_ip+si+3], al
        mov di, bx
        shl di, 1                       ; id * 2
        mov al, [req_port]
        mov [ses_port+di], al
        mov al, [req_port+1]
        mov [ses_port+di+1], al
        mov byte [ses_tr+bx], 1
        mov byte [mux_app_pending+bx], 1
        mov byte [mux_open_pending+bx], 1
        jmp .ip_out
.udp_close:
        mov al, [si]
        cmp al, 1
        jb .ip_out
        cmp al, MAXSER
        ja .ip_out
        mov bl, al
        xor bh, bh
        cmp byte [ses_tr+bx], 0
        je .ip_out
        mov byte [ses_tr+bx], 0
        mov byte [mux_close_pending+bx], 1
        jmp .ip_out
.echo:
        ; swap source and destination ports, zero the (optional) checksum
        mov ax, [si+20]
        xchg ax, [si+22]
        mov [si+20], ax
        mov word [si+26], 0
        jmp .ip_reply
.ip_reply:
        ; swap source and destination addresses
        mov ax, [si+12]
        mov bx, [si+14]
        xchg ax, [si+16]
        xchg bx, [si+18]
        mov [si+12], ax
        mov [si+14], bx
        ; IP: recompute header checksum
        mov word [si+10], 0
        mov cx, 20
        call ip_csum
        mov si, mux_payload
        mov [si+10], ax
        ; queue for task-context transmit
        cmp byte [ip_tx_pending], 0
        jne .ip_out
        mov cx, [ip_len]
        mov [ip_tx_len], cx
        mov di, ipbuf
        rep movsb
        mov byte [ip_tx_pending], 1
.ip_out:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tcp_step:
        cmp byte [tcp_loaded], 0
        je .ret
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push ds
        push es
        call far [tcp_entry]
        pop es
        pop ds
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
.ret:   ret

slip_rx_byte:                   ; AL = byte from COM1, SLIP framing
        cmp al, 0xC0
        je .se
        cmp byte [slip_bad], 0
        jne .sr
        cmp al, 0xDB
        je .sesc
        cmp byte [slip_esc], 0
        je .sst
        mov byte [slip_esc], 0
        cmp al, 0xDC
        je .sc0d
        cmp al, 0xDD
        je .sdbd
        ret                             ; invalid escape
.sc0d:
        mov al, 0xC0
        jmp .sst
.sdbd:
        mov al, 0xDB
.sst:
        mov bx, [slip_len]
        cmp bx, 256                     ; buffer size: a 256-byte packet fits
        jae .sbad
        mov [mux_payload+bx], al
        inc word [slip_len]
.sr:
        ret
.sesc:
        mov byte [slip_esc], 1
        ret
.sbad:
        mov byte [slip_bad], 1
        inc word [slip_errors]
        ret
.se:
        mov byte [slip_esc], 0
        mov byte [slip_bad], 0
        mov ax, [slip_len]
        mov word [slip_len], 0
        test ax, ax
        jz .sr
        cmp ax, 20
        jb .sr
        mov [mux_idx], ax
        inc word [slip_rx_pkts]
        call ip_input
        ret

slip_send:                      ; SI = packet, CX = length
        push ax
        push cx
        push si
        mov al, 0xC0
        call ser_raw
.sl:
        test cx, cx
        jz .sfin
        lodsb
        dec cx
        cmp al, 0xC0
        je .sc0
        cmp al, 0xDB
        je .sdb
        call ser_raw
        jmp .sl
.sc0:
        mov al, 0xDB
        call ser_raw
        mov al, 0xDC
        call ser_raw
        jmp .sl
.sdb:
        mov al, 0xDB
        call ser_raw
        mov al, 0xDD
        call ser_raw
        jmp .sl
.sfin:
        mov al, 0xC0
        call ser_raw
        inc word [slip_tx_pkts]
        pop si
        pop cx
        pop ax
        ret

ip_tx_flush:                    ; task context only: never send inside the ISR
        push ax
        push bx
        push cx
        push dx
        push si
        push es
        mov ax, KERNEL_SEG
        mov es, ax                      ; stosb targets ipesc: ES must be ours
        cmp byte [ip_tx_pending], 0
        je .itx_done
        mov byte [ip_tx_pending], 0
        pushf
        cli                             ; snapshot ipbuf before the slow send
        cmp byte [ipbuf], 0x45          ; only a well-formed packet may go out
        jne .itx_drop
        mov ah, [ipbuf+2]               ; length comes from the IP header, not
        mov al, [ipbuf+3]               ; from a possibly stale counter
        mov cx, ax
        cmp cx, 28
        jb .itx_drop
        cmp cx, 250                     ; frame length byte, IP header included
        ja .itx_drop
        mov bx, cx                      ; rep movsb consumes CX
        mov si, ipbuf
        mov di, ipesc                   ; snapshot: the ISR may reuse ipbuf
        rep movsb
        popf
        mov si, ipesc
        mov cx, bx
        cmp byte [slip_mode], 0
        je .itx_mux
        call slip_send
        jmp .itx_done
.itx_mux:
        mov al, 1
        mov dl, 0xFE
        call mux_send_frame
        jmp .itx_done
.itx_drop:
        popf
.itx_done:
        pop es
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

int0c_serial:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        push es
        mov ax, KERNEL_SEG
        mov ds, ax
        mov es, ax
        mov dx, 0x3FD
        in al, dx
        test al, 1
        jz .eoi
        mov ah, al                      ; keep LSR for the error bits
        test al, 2
        jz .havebyte
        mov byte [mux_state], 0
.havebyte:
        mov dx, 0x3F8
        in al, dx
        test ah, 0x1A                   ; overrun | framing | break = noise
        jnz .eoi
        cmp byte [raw_rx_on], 0
        je .chkslip
        call raw_rx_store
        jmp .eoi
.chkslip:
        cmp byte [slip_mode], 0
        je .chkmux
        call slip_rx_byte
        jmp .eoi
.chkmux:
        cmp byte [mux_mode], 0
        je .eoi
        call mux_rx_byte
.eoi:
        mov al, 0x20
        out 0x20, al
        pop es
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        iret

mux_rx_byte:                    ; AL = byte from COM1
        push ax
        push bx
        push cx
        push si
        mov bx, [ticks]
        mov [mux_last_tick], bx
        mov bl, [mux_state]
        cmp bl, 0
        je .stx
        cmp bl, 1
        je .type
        cmp bl, 2
        je .term
        cmp bl, 3
        je .len
        cmp bl, 4
        je .payload
        cmp bl, 5
        je .xor
        cmp bl, 6
        je .etx
        jmp .reset
.stx:
        cmp al, 0x02
        jne .done
        mov byte [mux_state], 1
        jmp .done
.type:
        mov [mux_type], al
        mov byte [mux_state], 2
        jmp .done
.term:
        mov [mux_term], al
        mov byte [mux_state], 3
        jmp .done
.len:
        cmp al, 250                     ; length byte; RX buffer is 256
        ja .reset
        mov [mux_len], al
        mov word [mux_idx], 0
        mov byte [mux_rcnt], 0
        mov byte [mux_esc], 0
        mov bl, [mux_type]
        xor bl, [mux_term]
        xor bl, al
        mov [mux_sum], bl
        test al, al
        jz .xor_state
        mov byte [mux_state], 4
        jmp .done
.xor_state:
        mov byte [mux_state], 5
        jmp .done
.payload:
        xor [mux_sum], al               ; XOR covers the whole frame payload
        inc byte [mux_rcnt]
        mov bl, [mux_idx]
        xor bh, bh
        cmp bl, 250
        jae .reset
        mov [mux_payload+bx], al
        inc byte [mux_idx]
.pl_end:
        mov bl, [mux_rcnt]
        cmp bl, [mux_len]
        jb .done
        mov byte [mux_state], 5
        jmp .done
.xor:
        cmp al, [mux_sum]
        jne .reset
        mov byte [mux_state], 6
        jmp .done
.etx:
        cmp al, 0x03
        jne .reset
        call mux_dispatch
.reset:
        mov byte [mux_state], 0
.done:
        pop si
        pop cx
        pop bx
        pop ax
        ret

mux_dispatch:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov al, [mux_type]
        cmp al, 0x01
        je .data
        cmp al, 0x02
        je .open
        cmp al, 0x03
        je .close
        jmp .done
.data:
        cmp byte [mux_term], 0xFE       ; IP channel
        jne .data_sess
        call ip_input
        jmp .done
.data_sess:
        mov al, [mux_term]
        test al, al
        jz .done
        mov bl, 1
.find:
        cmp bl, MAXSER
        ja .done
        xor bh, bh
        cmp al, [task_term+bx]
        je .found
        inc bl
        jmp .find
.found:
        mov al, bl
        xor ah, ah
        mov cl, 8
        shl ax, cl
        mov di, rx_buf
        add di, ax
        xor ch, ch
        mov cl, [mux_len]
        mov si, mux_payload
.enq:
        jcxz .done
        mov al, [rx_tail+bx]
        mov ah, al
        inc ah
        and ah, MUX_RX_SIZE-1
        cmp ah, [rx_head+bx]
        je .overflow
        push di
        mov al, [rx_tail+bx]
        xor ah, ah
        add di, ax
        mov al, [si]
        mov [di], al
        pop di
        inc byte [rx_tail+bx]
        and byte [rx_tail+bx], MUX_RX_SIZE-1
        inc si
        dec cx
        jmp .enq
.overflow:
        inc word [mux_rx_overflows]
        jmp .done
.open:
        mov al, [mux_term]
        cmp al, 1
        jb .done
        cmp al, MAXSER
        ja .done
        mov bl, al
        xor bh, bh
        mov al, 1
        cmp byte [mux_len], 0
        je .app_set
        call open_meta
        mov al, [mux_payload]
        cmp al, 2
        je .app_set
        cmp al, 3
        je .app_set
        mov al, 1
.app_set:
        mov [mux_app_pending+bx], al
        mov byte [mux_open_pending+bx], 1
        jmp .done
.close:
        mov al, [mux_term]
        cmp al, 1
        jb .done
        cmp al, MAXSER
        ja .done
        mov bl, al
        xor bh, bh
        mov byte [mux_close_pending+bx], 1
.done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; OPEN payload may carry, after the app id, a printable line supplied by the
; bridge (client address/port).  Print it on the console log; the app id keeps
; its position so an old bridge (1-byte payload) behaves exactly as before.
open_meta:
        cmp byte [mux_len], 1
        jbe .om_ret
        push ax
        push bx
        mov bl, [cur_task]
        mov byte [cur_task], 0         ; console log only, never the session
        mov si, mux_payload+1
        mov ah, 1
        int 0x60
        mov al, 10
        mov ah, 0
        int 0x60
        mov [cur_task], bl
        pop bx
        pop ax
.om_ret:
        ret

mux_poll:
        call ip_tx_flush
        ; Called from getchar(), which the shell read loop depends on to keep
        ; DI (write pointer) and CX (line length) live across keystrokes.
        ; Session start/reset deep inside touches DI, and the event loops below
        ; use CX/DX/BX, so preserve the full caller context here.
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        push es
        cmp byte [mux_mode], 0
        je .ret
        ; Polled RX fallback: works even if the serial card is not wired to
        ; IRQ4. The IRQ handler checks LSR first, so a spurious IRQ after this
        ; drain is harmless.
        pushf
        cli
.rx:
        mov dx, 0x3FD
        in al, dx
        test al, 1
        jz .rxdone
        test al, 2
        jz .rxread
        mov byte [mux_state], 0
.rxread:
        mov dx, 0x3F8
        in al, dx
        call mux_rx_byte
        jmp .rx
.rxdone:
        popf
        cmp byte [mux_state], 0
        je .events
        mov ax, [ticks]
        sub ax, [mux_last_tick]
        cmp ax, [mux_idle]
        jb .events
        mov byte [mux_state], 0
.events:
        ; CLOSE first for terminal IDs 1..MAXSER
        mov byte [mux_id], 1
.close_loop:
        mov al, [mux_id]
        cmp al, MAXSER
        ja .open_start
        mov bl, al
        xor bh, bh
        cmp byte [mux_close_pending+bx], 0
        je .close_next
        mov byte [mux_close_pending+bx], 0
        mov byte [mux_slot], 1
.close_find:
        mov al, [mux_slot]
        cmp al, MAXSER
        ja .close_next
        mov bl, al
        xor bh, bh
        cmp byte [task_state+bx], 1
        jne .close_find_next
        mov al, [mux_id]
        cmp al, [task_term+bx]
        jne .close_find_next
        mov byte [task_state+bx], 0
        mov byte [task_term+bx], 0
        mov byte [task_app+bx], 0
        mov al, [mux_slot]
        call session_reset_slot
        jmp .close_next
.close_find_next:
        inc byte [mux_slot]
        jmp .close_find
.close_next:
        inc byte [mux_id]
        jmp .close_loop
.open_start:
        mov byte [mux_id], 1
.open_loop:
        mov al, [mux_id]
        cmp al, MAXSER
        ja .ret
        mov bl, al
        xor bh, bh
        cmp byte [mux_open_pending+bx], 0
        je .open_next
        mov byte [mux_open_pending+bx], 0
        mov byte [mux_slot], 1
.open_dup:
        mov al, [mux_slot]
        cmp al, MAXSER
        ja .open_free_start
        mov bl, al
        xor bh, bh
        cmp byte [task_state+bx], 1
        jne .open_dup_next
        mov al, [mux_id]
        cmp al, [task_term+bx]
        jne .open_dup_next
        mov al, [mux_id]
        xor ah, ah
        mov si, ax
        mov al, [mux_app_pending+si]
        test al, al
        jnz .dup_have_app
        mov al, 1
.dup_have_app:
        cmp al, [task_app+bx]
        je .dup_ack
        ; same terminal id, different application: replace the old session
        mov byte [task_state+bx], 0
        mov byte [task_term+bx], 0
        mov byte [task_app+bx], 0
        mov al, [mux_slot]
        call session_reset_slot
        jmp .open_free_start
.dup_ack:
        mov dl, [mux_id]
        mov al, 0x05
        call sess_ctl
        jmp .open_next
.open_dup_next:
        inc byte [mux_slot]
        jmp .open_dup
.open_free_start:
        mov byte [mux_slot], 1
.open_free:
        mov al, [mux_slot]
        cmp al, MAXSER
        ja .open_busy
        mov bl, al
        xor bh, bh
        cmp byte [task_state+bx], 0
        je .open_claim
        inc byte [mux_slot]
        jmp .open_free
.open_busy:
        mov dl, [mux_id]
        mov al, 0x04
        call sess_ctl                    ; routed by the current transport
        mov al, [mux_id]                 ; then release the id: no session exists
        xor ah, ah
        mov bx, ax
        mov byte [ses_tr+bx], 0
        jmp .open_next
.open_claim:
        mov al, [mux_slot]
        mov bl, al
        xor bh, bh
        mov al, [mux_id]
        mov [task_term+bx], al
        mov al, [mux_id]
        xor ah, ah
        mov si, ax
        mov al, [mux_app_pending+si]
        test al, al
        jnz .app_ok
        mov al, 1
.app_ok:
        mov [task_app+bx], al
        mov al, [mux_slot]
        call session_start
        mov dl, [mux_id]
        mov al, 0x05
        call sess_ctl
.open_next:
        inc byte [mux_id]
        jmp .open_loop
.ret:
        call tftp_step
        call tcp_step
        cmp byte [job_ok], 0
        je .noj
        call far [cs:job_vec]
.noj:
        pop es
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; Serial session log: logon/logoff events to CGA and COM1
; =====================================================================

log_user_event:                 ; SI = prefix; append serial_user
        push ax
        push di
        push si
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, logbuf
        push si
        mov si, s_sys_hdr
        call copyz
        pop si
        call copyz
        push di
        call user_ptr
        mov si, di
        pop di
        call copyz
        mov al, 13
        stosb
        mov al, 10
        stosb
        xor al, al
        stosb
        mov si, logbuf
        call log_str
        pop es
        pop si
        pop di
        pop ax
        ret

copyz:                          ; DS:SI -> ES:DI (NUL included, DI at NUL)
        push ax
.l:
        lodsb
        stosb
        test al, al
        jnz .l
        dec di
        pop ax
        ret

log_str:                        ; SI -> string; CGA + COM1, atomic
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        inc byte [crit]
.c:
        lodsb
        test al, al
        jz .done
        push ax
        cmp byte [ed_active], 0
        jne .ser
        cmp byte [cga_panel], 0
        je .tty
        call panel_putc
        jmp .ser
.tty:
        mov ah, 0x0E
        mov bx, 0x0007
        call bios_video
.ser:
        pop ax
        cmp byte [mux_mode], 0
        jne .c
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [ser_panel+bx], 0
        jne .c
        call ser1
        jmp .c
.done:
        dec byte [crit]
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; VIDEO init: BDA-detected MDA/Hercules (mode 7, B000) or CGA (mode 3)
; =====================================================================

video_init:
        push ax
        push es
        mov ax, 0x40
        mov es, ax
        mov al, [es:0x49]               ; BDA current CRT mode
        cmp al, 7
        je .mono
        mov al, [es:0x10]               ; equipment word
        and al, 0x30                    ; bits 5-4: 11 = mono 80x25
        cmp al, 0x30
        je .mono
        mov ax, [es:0x63]               ; CRTC base port
        cmp ax, 0x3B4                   ; 3B4 = MDA/Hercules
        je .mono
        pop es
        mov byte [mono], 0
        mov word [vid_seg], 0xB800
        mov ax, 3
        jmp .set
.mono:
        pop es
        mov byte [mono], 1
        mov word [vid_seg], 0xB000
        mov ax, 7
.set:
        mov ah, 0
        call bios_video
        pop ax
        ret

serial_out:
        push ax
        push dx
        mov ah, al
.wait:
        mov dx, 0x3FD
        in al, dx
        test al, 0x20
        jz .wait
        mov dx, 0x3F8
        mov al, ah
        out dx, al
        pop dx
        pop ax
        ret

; =====================================================================
; C: FAT12/16 reader
; =====================================================================

fat_mount:
        mov byte [fs_ok], 0
        mov byte [disk_ro], 0
        cmp byte [disk_dl], 0x80
        jb .flp
        mov word [spt], 17              ; HDD defaults for the first read
        mov word [heads], 4
        jmp .r0
.flp:
        mov word [spt], 9               ; 360 KB floppy
        mov word [heads], 2
        xor ah, ah                      ; reset the controller (disk change)
        mov dl, [disk_dl]
        int 0x13
        cld
.r0:
        xor ax, ax
        call hdd_read
        jc .fail
        cmp byte [disk_dl], 0x80
        jb .super
        cmp word [secbuf+0x1FE], 0xAA55
        jne .super
        mov si, secbuf+0x1BE
        mov cx, 4
.find:
        mov al, [si+4]
        test al, al
        jz .next
        cmp al, 1
        je .part
        cmp al, 4
        je .part
        cmp al, 6
        je .part
        cmp al, 0x0E
        je .part
.next:
        add si, 16
        loop .find
.super:
        mov word [part_lba], 0
        jmp .parse
.part:
        mov ax, [si+8]
        mov [part_lba], ax
        call hdd_read
        jc .fail
.parse:
        cmp word [secbuf+11], 512
        jne .fail
        mov al, [secbuf+0x0D]
        test al, al
        jz .fail
        mov [sec_per_clus], al
        mov ax, [secbuf+0x0E]
        mov [rsvd_secs], ax
        mov al, [secbuf+0x10]
        test al, al
        jz .fail
        mov [num_fats], al
        mov ax, [secbuf+0x11]
        mov [root_ents], ax
        mov ax, [secbuf+0x13]
        test ax, ax
        jnz .tot_ok
        mov ax, [secbuf+0x20]
.tot_ok:
        mov [total_secs], ax
        ; 16-bit LBA limit: the volume must end below LBA 65536 or the
        ; address arithmetic in hdd_read/hdd_write can wrap.  Mark such
        ; a volume read-only instead of risking a wrapped write.
        test ax, ax
        jz .ro_vol
        add ax, [part_lba]
        jc .ro_vol
        jmp .sz_ok
.ro_vol:
        mov byte [disk_ro], 1
.sz_ok:
        mov ax, [secbuf+0x16]
        test ax, ax
        jz .fail
        mov [fat_secs], ax
        mov ax, [secbuf+0x18]
        test ax, ax
        jz .fail
        mov [spt], ax
        mov ax, [secbuf+0x1A]
        test ax, ax
        jz .fail
        mov [heads], ax

        ; root_lba = part_lba + rsvd + nfats*fat_secs
        mov ax, [fat_secs]
        mov cl, [num_fats]
        xor ch, ch
        mul cx
        add ax, [rsvd_secs]
        add ax, [part_lba]
        mov [root_lba], ax
        ; root_secs = ceil(root_ents/16)
        mov ax, [root_ents]
        add ax, 15
        mov cl, 4
        shr ax, cl
        mov [root_secs], ax
        ; data_lba = root_lba + root_secs
        add ax, [root_lba]
        mov [data_lba], ax
        ; fat_lba = part_lba + rsvd
        mov ax, [rsvd_secs]
        add ax, [part_lba]
        mov [fat_lba], ax
        ; data_secs = total - (rsvd + nfats*fat + root_secs)
        mov ax, [fat_secs]
        mov cl, [num_fats]
        xor ch, ch
        mul cx
        add ax, [rsvd_secs]
        add ax, [root_secs]
        mov bx, [total_secs]
        sub bx, ax
        mov ax, bx
        mov cl, [sec_per_clus]
        xor ch, ch
        xor dx, dx
        div cx
        mov [max_cluster], ax
        inc word [max_cluster]
        cmp ax, 4085
        jb .fat12
        mov byte [fat_type], 16
        jmp .mounted
.fat12:
        mov byte [fat_type], 12
.mounted:
        mov byte [fs_ok], 1
        mov al, 'C'
        cmp byte [disk_ram], 0
        je .pdr2
        mov al, 'M'
        jmp .pdr
.pdr2:
        cmp byte [disk_dl], 0x80
        jae .pdr
        mov al, 'A'
        cmp byte [disk_dl], 0
        je .pdr
        mov al, 'B'
.pdr:
        push ax
        mov si, s_boot_arrow
        call puts
        pop ax
        call putc
        mov si, s_colfat
        call puts
        cmp byte [fat_type], 16
        jne .p12
        mov si, s_fat16
        jmp .pp
.p12:
        mov si, s_fat12
.pp:
        call puts
        mov al, 10
        call putc
        clc
        ret
.fail:
        mov si, s_nocdrive
        call puts
        stc
        ret

; hdd_read: AX = LBA -> secbuf (C:), geometry in spt/heads
hdd_read:
        cmp byte [disk_ram], 0
        jne ram_read
        push ax
        push bx
        push cx
        push dx
        push es
        xor dx, dx
        div word [spt]
        inc dx
        mov cl, dl
        xor dx, dx
        div word [heads]
        mov ch, al
        mov bx, ax
        mov al, ah
        and al, 3
        shl al, 1
        shl al, 1
        shl al, 1
        shl al, 1
        shl al, 1
        shl al, 1
        or cl, al
        mov dh, dl
        mov dl, [disk_dl]
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, secbuf
        mov ax, 0x0201
        inc byte [crit]
        int 0x13
        cld
        dec byte [crit]
        jc .fail
        clc
        jmp .done
.fail:
        mov [disk_err], ah
        stc
.done:
        pop es
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; find_file: DS:namebuf -> file_cluster, file_size
find_file:
        push es
        mov ax, ds
        mov es, ax
        mov ax, [root_lba]
        mov [scan_lba], ax
        mov ax, [root_secs]
        mov [root_left], ax
.scan:
        mov ax, [scan_lba]
        call hdd_read
        jc .nf
        mov si, secbuf
        mov word [ent_left], 16
.entry:
        mov al, [si]
        test al, al
        jz .nf
        cmp al, 0xE5
        je .next
        test byte [si+11], 0x08
        jnz .next
        push si
        mov di, namebuf
        mov cx, 11
        repe cmpsb
        pop si
        je .found
.next:
        add si, 32
        dec word [ent_left]
        jnz .entry
        inc word [scan_lba]
        dec word [root_left]
        jnz .scan
        jmp .nf
.found:
        mov ax, [si+0x1A]
        mov [file_cluster], ax
        mov ax, [si+0x1C]
        mov [file_size], ax
        mov ax, [si+0x1E]
        mov [file_size+2], ax
        mov ax, [scan_lba]
        mov [ent_lba], ax
        mov ax, si
        sub ax, secbuf
        mov [ent_off], ax
        pop es
        clc
        ret
.nf:
        pop es
        stc
        ret

; load_file: ES:BX dest, CX max -> DX = bytes
load_file:
        push es
        push di
        push si
        mov ax, [file_size]
        cmp ax, cx
        jbe .sz
        mov ax, cx
.sz:
        mov [copy_left], ax
        mov [ret_size], ax
        mov ax, [file_cluster]
        mov [cur_cluster], ax
        mov di, bx
.c_loop:
        cmp word [copy_left], 0
        je .done
        mov al, [sec_per_clus]
        xor ah, ah
        mov [secs_left], ax
        mov ax, [cur_cluster]
        sub ax, 2
        mov cl, [sec_per_clus]
        xor ch, ch
        mul cx
        add ax, [data_lba]
        mov [cur_lba], ax
.s_loop:
        mov ax, [cur_lba]
        call hdd_read
        jc .err
        mov si, secbuf
        mov cx, 512
        cmp word [copy_left], cx
        jae .full
        mov cx, [copy_left]
.full:
        sub word [copy_left], cx
        rep movsb
        inc word [cur_lba]
        dec word [secs_left]
        jnz .s_loop
        mov ax, [cur_cluster]
        call fat_next
        jc .err
        cmp byte [fat_type], 16
        jne .c12
        cmp ax, 0xFFF8
        jae .done
        jmp .cset
.c12:
        cmp ax, 0xFF8
        jae .done
.cset:
        mov [cur_cluster], ax
        jmp .c_loop
.done:
        mov dx, [ret_size]
        clc
        jmp .ret
.err:
        stc
.ret:
        pop si
        pop di
        pop es
        ret

; fat_next: AX = cluster -> AX = next
fat_next:
        push bx
        push cx
        push si
        cmp byte [fat_type], 16
        jne .f12
        mov bx, ax
        shl bx, 1
        mov ax, bx
        mov cl, 9
        shr ax, cl
        add ax, [fat_lba]
        mov si, bx
        and si, 511
        call hdd_read
        jc .err
        mov ax, [secbuf+si]
        clc
        jmp .ret
.f12:
        mov bx, ax
        shr ax, 1
        add ax, bx
        mov bx, ax
        mov cl, 9
        shr ax, cl
        add ax, [fat_lba]
        mov si, bx
        and si, 511
        call hdd_read
        jc .err
        mov ax, [secbuf+si]
        test byte [cur_cluster], 1
        jz .even
        mov cl, 4
        shr ax, cl
.even:
        and ax, 0x0FFF
        clc
        jmp .ret
.err:
        stc
.ret:
        pop si
        pop cx
        pop bx
        ret

; load_sys: load UMIX.SYS from C: to 2000:0000 and call it
load_sys:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        cmp byte [fs_ok], 0
        je .fail
        mov si, sys_name
        mov di, namebuf
        mov cx, 11
        rep movsb
        call find_file
        jc .fail
        mov ax, SYS_SEG
        mov es, ax
        xor bx, bx
        mov cx, 0xFFFF
        call load_file
        jc .fail
        mov si, s_sysload
        call puts
        mov ax, dx
        call put_dec
        mov si, s_bytes
        call puts
        call far [sys_entry]
        mov ax, KERNEL_SEG
        mov ds, ax
        mov es, ax
        clc
        jmp .ret
.fail:
        mov si, s_nosys
        call puts
        stc
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; STARTUP.JCL - plain command script, run once at boot
; One command per line.  Blank lines and lines starting with ; # or //
; are skipped.  Lines are fed to the normal command dispatcher, so
; MUX ON, WRITE ON, BAUD, WEB, PRIV etc. take effect before the boot
; mux check and before any serial session is spawned.
; =====================================================================
startup_run:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push es
        cmp byte [startup_done], 0
        jne .done
        mov byte [startup_done], 1
        cmp byte [fs_ok], 0
        je .done
        mov si, startup_name
        call build83
        call find_file
        jc .done
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, startup_buf
        mov cx, STARTUP_MAX-1
        call load_file
        jc .done
        mov di, startup_buf
        add di, dx
        mov byte [di], 0
        mov si, s_boot_arrow
        call puts
        mov si, s_startup_hdr
        call puts
        mov si, startup_buf
.line:
        mov al, [si]
        test al, al
        jz .done
        cmp al, 13
        je .nl
        cmp al, 10
        je .nl
        cmp al, ' '
        je .nl
        cmp al, ';'
        je .eol
        cmp al, '#'
        je .eol
        cmp al, '/'
        jne .copy
        cmp byte [si+1], '/'
        je .eol
.copy:
        mov di, shellbuf
        xor cx, cx
.cl:
        mov al, [si]
        test al, al
        jz .cle
        cmp al, 13
        je .cle
        cmp al, 10
        je .cle
        cmp cx, 120
        jae .cle
        mov [di], al
        inc di
        inc si
        inc cx
        jmp .cl
.cle:
        cmp di, shellbuf
        jbe .trimd
        cmp byte [di-1], ' '
        jne .trimd
        dec di
        jmp .cle
.trimd:
        mov byte [di], 0
        push si
        mov bp, shellbuf
        call execute
        pop si
        jmp .line
.nl:
        inc si
        jmp .line
.eol:
        mov al, [si]
        test al, al
        jz .done
        cmp al, 13
        je .line
        cmp al, 10
        je .line
        inc si
        jmp .eol
.done:
        pop es
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; Raw COM1 helpers (used before any session exists)
; =====================================================================
com_out:                        ; AL = char
        push ax
        push dx
        mov ah, al
        mov dx, 0x3FD
.co_w:
        in al, dx
        test al, 0x20                   ; THRE
        jz .co_w
        mov dx, 0x3F8
        mov al, ah
        out dx, al
        pop dx
        pop ax
        ret

boot_msg:                       ; SI = NUL-terminated, console + COM1
        push ax
        push si
        mov si, s_boot_arrow
        call puts
        pop si
        push si
        call puts
        pop si
        push si
        mov si, s_boot_arrow
        call com_puts
        pop si
        push si
        call com_puts
        pop si
        pop ax
        ret

com_puts:                       ; SI = NUL-terminated
        push ax
        push si
.cp_l:
        mov al, [si]
        test al, al
        jz .cp_d
        call com_out
        inc si
        jmp .cp_l
.cp_d:
        pop si
        pop ax
        ret

com_in:                         ; CF=1 nothing pending, else AL=byte
        push dx
        mov dx, 0x3FD
        in al, dx
        test al, 1
        jz .ci_n
        mov dx, 0x3F8
        in al, dx
        pop dx
        clc
        ret
.ci_n:
        pop dx
        stc
        ret

; =====================================================================
; Boot mode prompt: [N]ORMAL or [T]RANSFER on the raw serial line.
; CF=1 when the user picked transfer mode.
; =====================================================================
boot_mode_prompt:
        push ax
        push si
        mov si, s_mode_prompt
        call com_puts
        mov si, s_mode_prompt2
        call puts
        mov ax, [ticks]
        mov [mode_start], ax
.bm_w:
        call com_in
        jnc .bm_g
        mov ax, [ticks]
        sub ax, [mode_start]
        cmp ax, 200                     ; ~11 s at 18 Hz
        jb .bm_w
        clc
        jmp .bm_d
.bm_g:
        call upcase
        cmp al, 'T'
        jne .bm_n
        stc
        jmp .bm_d
.bm_n:
        clc
.bm_d:
        push ax
        pushf                           ; com_out's TEST clobbers CF
        mov al, 13
        call com_out
        mov al, 10
        call com_out
        popf
        pop ax
        pop si
        pop ax
        ret

; read a line from the BIOS keyboard into DI (CX = max), echoing to CGA
kbd_getline:
        push ax
        push bx
        push cx
        push dx
        push di
        xor bx, bx
.kg_l:
        xor ah, ah
        int 0x16
        cmp al, 13
        je .kg_d
        cmp al, 8
        je .kg_b
        cmp al, 127
        je .kg_b
        cmp al, 32
        jb .kg_l
        cmp bx, cx
        jae .kg_l
        mov [di], al
        inc di
        inc bx
        push ax
        call putc
        pop ax
        jmp .kg_l
.kg_b:
        test bx, bx
        jz .kg_l
        dec bx
        dec di
        mov al, 8
        call putc
        mov al, ' '
        call putc
        mov al, 8
        call putc
        jmp .kg_l
.kg_d:
        mov byte [di], 0
        mov al, 10
        call putc
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; TRANSFER MODE - COM1 is a raw byte sink, files go to the floppy in A:
; =====================================================================
transfer_mode:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov si, s_tm_insert
        call puts
        xor ah, ah
        int 0x16
        call serial_rx_raw_on
        mov byte [disk_ram], 0
        mov byte [disk_dl], 0
        call fat_mount
        jnc .tm_have
        mov si, s_tm_notfat
        call puts
        xor ah, ah
        int 0x16
        push ax
        call putc
        pop ax
        call upcase
        cmp al, 'Y'
        jne .tm_exit
        xor al, al
        call format_volume
        cmp byte [fs_ok], 0
        je .tm_exit
.tm_have:
        mov si, s_tm_ready
        call puts
.tm_next:
        mov si, s_tm_name
        call puts
        mov di, tm_name
        mov cx, 12
        call kbd_getline
        cmp byte [tm_name], 0
        je .tm_exit
        mov al, [tm_name]
        call upcase
        cmp al, 'F'
        jne .tm_recv
        cmp byte [tm_name+1], 0
        jne .tm_recv
        xor al, al
        call format_volume
        jmp .tm_next
.tm_recv:
        mov si, tm_name
.tm_chk:
        mov al, [si]
        test al, al
        jz .tm_okname
        cmp al, ':'
        je .tm_drv
        inc si
        jmp .tm_chk
.tm_drv:
        mov si, s_tm_drv
        call puts
        jmp .tm_next
.tm_okname:
        mov si, tm_name
        call build83
        call recv_file
        jmp .tm_next
.tm_exit:
        call serial_rx_raw_off
        mov byte [disk_ram], 0
        mov byte [disk_dl], 0x80
        call fat_mount
        cmp byte [fs_ok], 0
        jne .tm_done
        mov byte [disk_ram], 1
        mov byte [disk_dl], 0
        call ram_format
        call fat_mount
.tm_done:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; stream one file from COM1 to the mounted volume; namebuf holds the 8.3
recv_file:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov byte [recv_full], 0
        mov word [sv_size], 0
        mov word [sv_first], 0
        mov word [sv_prev], 0
        mov word [sv_secs], 0
        mov word [raw_head], 0
        mov word [raw_tail], 0
        call find_file
        jc .rf_new
        mov byte [dir_new], 0
        mov ax, [file_cluster]
        call free_chain
        jmp .rf_alloc
.rf_new:
        mov byte [dir_new], 1
.rf_alloc:
        call alloc_cluster
        jc .rf_nofree
        mov [sv_first], ax
        mov [sv_prev], ax
        mov [sv_cur], ax
        call recv_lba_for_cur
        mov al, [sec_per_clus]
        xor ah, ah
        mov [sv_secs], ax
        mov si, s_tm_send
        call puts
        mov ax, [ticks]
        mov [recv_last], ax
        mov di, secbuf
        mov word [recv_cnt], 0
        mov byte [recv_first], 0
.rf_fill:
        call recv_byte
        jc .rf_short
        cmp word [recv_cnt], 0
        jne .rf_nofirst
        mov [recv_first], al
.rf_nofirst:
        stosb
        inc word [recv_cnt]
        cmp word [recv_cnt], 512
        jb .rf_fill
        call recv_write
        jc .rf_ioerr
        cmp byte [recv_full], 0
        jne .rf_fin
        add word [sv_size], 512
        cmp word [sv_size], 65000
        jae .rf_fin
        mov di, secbuf
        mov word [recv_cnt], 0
        jmp .rf_fill
.rf_short:
        mov cx, [recv_cnt]
        test cx, cx
        jz .rf_fin
        mov [part_cnt], cx
        mov ax, 512
        sub ax, cx
        mov cx, ax
        xor al, al
        rep stosb
        call recv_write
        jc .rf_ioerr
        mov ax, [part_cnt]
        add [sv_size], ax
.rf_fin:
        cmp word [sv_first], 0
        je .rf_noent
        mov ax, [sv_prev]
        mov dx, 0xFFFF
        call fat_set
.rf_noent:
        cmp byte [dir_new], 0
        je .rf_haveent
        call free_dir
        jc .rf_nospace
.rf_haveent:
        mov ax, [ent_lba]
        call hdd_read
        jc .rf_ioerr
        mov di, secbuf
        add di, [ent_off]
        mov si, namebuf
        mov cx, 11
        rep movsb
        mov al, 0x20
        stosb
        xor cx, cx
.rf_z:
        xor al, al
        stosb
        inc cx
        cmp cx, 20
        jb .rf_z
        mov di, secbuf
        add di, [ent_off]
        mov ax, [sv_first]
        mov [di+26], ax
        mov ax, [sv_size]
        mov [di+28], ax
        xor ax, ax
        mov [di+30], ax
        mov ax, [ent_lba]
        call hdd_write
        jc .rf_ioerr
        mov si, s_tm_ok
        call puts
        mov ax, [sv_size]
        call put_dec
        mov si, s_tm_bytes
        call puts
        cmp word [sv_size], 8
        jae .rf_chkfull
        mov si, s_tm_first
        call puts
        mov al, [recv_first]
        call put_hex
        mov si, s_nl
        call puts
.rf_chkfull:
        cmp byte [recv_full], 0
        je .rf_done
        mov si, s_tm_full
        call puts
.rf_done:
        clc
        jmp .rf_out
.rf_nofree:
        mov si, s_tm_nofree
        call puts
        stc
        jmp .rf_out
.rf_nospace:
        mov si, s_tm_nofree
        call puts
        stc
        jmp .rf_out
.rf_ioerr:
        mov si, s_tm_ioerr
        call puts
        stc
.rf_out:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

recv_lba_for_cur:
        push ax
        push cx
        push dx
        mov ax, [sv_cur]
        sub ax, 2
        mov cl, [sec_per_clus]
        xor ch, ch
        mul cx
        add ax, [data_lba]
        mov [sv_lba], ax
        pop dx
        pop cx
        pop ax
        ret

recv_write:
        push ax
        push bx
        mov ax, [sv_lba]
        call hdd_write
        jc .rw_err
        inc word [sv_lba]
        dec word [sv_secs]
        jnz .rw_out
        call alloc_cluster
        jc .rw_full
        push ax
        mov dx, ax
        mov ax, [sv_prev]
        call fat_set
        pop ax
        mov [sv_prev], ax
        mov [sv_cur], ax
        call recv_lba_for_cur
        mov al, [sec_per_clus]
        xor ah, ah
        mov [sv_secs], ax
        jmp .rw_out
.rw_full:
        mov byte [recv_full], 1
.rw_out:
        clc
        jmp .rw_done
.rw_err:
        stc
.rw_done:
        pop bx
        pop ax
        ret

recv_byte:                      ; CF=1 = idle timeout, else AL=byte
        push dx
        push bx
.rb_l:
        mov ax, [raw_tail]
        cmp ax, [raw_head]
        je .rb_idle
        mov bx, ax
        and bx, 2047
        inc ax                          ; advance the index BEFORE AL is
        mov [raw_tail], ax              ; overwritten with the byte
        mov al, [rx_buf+bx]
        push ax
        mov ax, [ticks]
        mov [recv_last], ax
        pop ax
        pop bx
        pop dx
        clc
        ret
.rb_idle:
        mov ax, [ticks]
        sub ax, [recv_last]
        mov bx, [sv_size]
        or bx, [recv_cnt]
        jz .rb_first
        cmp ax, 150                     ; ~8 s gap = end of file
        jb .rb_l
        jmp .rb_end
.rb_first:
        cmp ax, 1200                    ; ~66 s to start the transfer
        jae .rb_end
        mov ah, 1                       ; a console key aborts the wait
        int 0x16
        jz .rb_l
        xor ah, ah
        int 0x16
.rb_end:
        pop bx
        pop dx
        stc
        ret

; =====================================================================
; CHAT.SYS overlay loader (segment 0x2900)
; =====================================================================
load_chat:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov byte [chat_ok], 0
        cmp byte [fs_ok], 0
        je .lc_done
        mov si, s_chat_name
        mov di, namebuf
        mov cx, 11
        rep movsb
        call find_file
        jc .lc_done
        mov ax, CHAT_SEG
        mov es, ax
        xor bx, bx
        mov cx, 8000
        call load_file
        jc .lc_done
        cmp dx, 100                    ; ignore a stub: only a real overlay
        jb .lc_done
        mov byte [chat_ok], 1
.lc_done:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; C: write support (SAVE / DELETE)
; =====================================================================

load_api:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov byte [api_ok], 0
        cmp byte [fs_ok], 0
        je .lc_done
        push ds
        pop es                         ; rep movsb writes ES:DI; API caller's ES != kernel
        mov si, s_api_name
        mov di, namebuf
        mov cx, 11
        rep movsb
        call find_file
        jc .lc_done
        mov ax, API_SEG
        mov es, ax
        xor bx, bx
        mov cx, 24576                  ; room for jobs + chat (0x9000..0xF000: free RAM)
        call load_file
        jc .lc_done
        cmp dx, 100                    ; ignore a stub: only a real overlay
        jb .lc_done
        mov byte [api_ok], 1
        mov al, 0FFh                   ; init call: overlay prints its version
        mov bx, cs
        push bx
        mov bx, .la_ret
        push bx
        mov bx, API_SEG
        push bx
        xor bx, bx
        push bx
        retf
.la_ret:
        cmp dx, 0x4A42                  ; 'BJ': overlay advertises a job pump
        jne .lc_done
        mov [job_vec], bx
        mov word [job_vec+2], API_SEG
        mov byte [job_ok], 1
.lc_done:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; C: write support (SAVE / DELETE)
; =====================================================================

hdd_write:                      ; AX = LBA, secbuf -> volume
        cmp byte [disk_ram], 0
        jne ram_write
        push ax
        push bx
        push cx
        push dx
        push es
        xor dx, dx
        div word [spt]
        inc dx
        mov cl, dl
        xor dx, dx
        div word [heads]
        mov ch, al
        mov bx, ax
        mov al, ah
        and al, 3
        shl al, 1
        shl al, 1
        shl al, 1
        shl al, 1
        shl al, 1
        shl al, 1
        or cl, al
        mov dh, dl
        mov dl, [disk_dl]
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, secbuf
        mov ax, 0x0301
        inc byte [crit]
        int 0x13
        cld
        dec byte [crit]
        jc .fail
        clc
        jmp .done
.fail:
        mov [disk_err], ah
        stc
.done:
        pop es
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; AX = cluster -> DX = FAT value
; FAT sector cache.  fat_get is called once per cluster and a real floppy
; costs ~30 ms per sector read, so a sequential scan must not touch the disk
; for every entry.  fat_fill keeps one FAT sector in fat_buf.
fat_fill:                       ; AX = absolute FAT sector LBA
        push ax
        push cx
        push si
        push di
        push es
        cmp ax, [fat_cache_lba]
        jne .ff_r
        cmp byte [fat_cache_ok], 0
        jne .ff_ok
.ff_r:
        mov [fat_cache_lba], ax
        mov byte [fat_cache_ok], 0
        call hdd_read               ; into secbuf
        jc .ff_err
        mov ax, KERNEL_SEG
        mov es, ax
        mov si, secbuf
        mov di, fat_buf
        mov cx, 256
        rep movsw
        mov byte [fat_cache_ok], 1
.ff_ok:
        clc
        jmp .ff_out
.ff_err:
        stc
.ff_out:
        pop es
        pop di
        pop si
        pop cx
        pop ax
        ret

fat_get:
        push ax
        push bx
        push cx
        push si
        mov [fs_cl], ax
        mov bx, ax
        cmp byte [fat_type], 16
        jne .f12
        shl bx, 1
        mov ax, bx
        mov cl, 9
        shr ax, cl
        add ax, [fat_lba]
        mov si, bx
        and si, 511
        call fat_fill
        jc .err
        mov dx, [fat_buf+si]
        jmp .ret
.f12:
        mov si, ax
        shr ax, 1
        add ax, si
        mov bx, ax
        mov cl, 9
        shr ax, cl
        add ax, [fat_lba]
        mov si, bx
        and si, 511
        call fat_fill
        jc .err
        mov dx, [fat_buf+si]
        test byte [fs_cl], 1
        jz .even
        mov cl, 4
        shr dx, cl
.even:
        and dx, 0x0FFF
        jmp .ret
.err:
        stc
        jmp .out
.ret:
        clc
.out:
        pop si
        pop cx
        pop bx
        pop ax
        ret

; AX = cluster, DX = value -> write into every FAT copy
fat_set:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov [fs_cl], ax
        mov [fs_val], dx
        cmp byte [fat_type], 16
        jne .f12
        mov bx, ax
        shl bx, 1
        mov ax, bx
        mov cl, 9
        shr ax, cl
        mov [fs_soff], ax
        mov ax, bx
        and ax, 511
        mov [fs_off], ax
        jmp .have
.f12:
        mov si, ax
        mov bx, ax
        shr ax, 1
        add ax, bx
        mov bx, ax
        mov cl, 9
        shr ax, cl
        mov [fs_soff], ax
        mov ax, bx
        and ax, 511
        mov [fs_off], ax
.have:
        mov ax, [fs_soff]
        add ax, [fat_lba]
        call fat_fill
        jc .err
        cmp byte [fat_type], 16
        jne .f12w
        mov ax, [fs_val]
        mov bx, [fs_off]
        mov [fat_buf+bx], ax
        jmp .wr
.f12w:
        mov bx, [fs_off]
        mov ax, [fat_buf+bx]
        mov dx, [fs_val]
        test byte [fs_cl], 1
        jz .even
        and ax, 0x000F
        shl dx, 1
        shl dx, 1
        shl dx, 1
        shl dx, 1
        or ax, dx
        jmp .store
.even:
        and ax, 0xF000
        and dx, 0x0FFF
        or ax, dx
.store:
        mov [fat_buf+bx], ax
.wr:
        mov ax, KERNEL_SEG
        mov es, ax
        mov si, fat_buf
        mov di, secbuf
        mov cx, 256
        rep movsw
        mov byte [fs_i], 0
.loop:
        mov al, [fs_i]
        cmp al, [num_fats]
        jae .done
        xor ah, ah
        mov bx, ax
        mov ax, [fat_secs]
        mul bx
        add ax, [fs_soff]
        add ax, [fat_lba]
        call hdd_write
        jc .err
        inc byte [fs_i]
        jmp .loop
.done:
        clc
        jmp .ret
.err:
        stc
.ret:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; -> AX = a free cluster, CF if none
alloc_cluster:
        push bx
        mov ax, 2
.l:
        cmp ax, [max_cluster]
        ja .full
        push ax
        call fat_get
        pop bx
        test dx, dx
        jnz .next
        mov ax, bx
        push ax
        mov dx, 0xFFFF
        call fat_set
        pop ax
        pop bx
        clc
        ret
.next:
        mov ax, bx
        inc ax
        jmp .l
.full:
        stc
        pop bx
        ret

; free a cluster chain starting at AX
free_chain:
        push ax
        push bx
        push cx
        push dx
        mov cx, [max_cluster]
        inc cx
.l:
        dec cx
        jz .done
        cmp ax, 2
        jb .done
        cmp ax, [max_cluster]
        ja .done
        push ax
        call fat_get
        pop bx
        push dx
        push bx
        mov ax, bx
        xor dx, dx
        call fat_set
        pop bx
        pop dx
        mov ax, dx
        cmp ax, 0xFFF8
        jae .done
        jmp .l
.done:
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; find a free root directory slot -> ent_lba/ent_off; CF if full
free_dir:
        mov ax, [root_lba]
        mov [scan_lba], ax
        mov ax, [root_secs]
        mov [root_left], ax
.scan:
        mov ax, [scan_lba]
        call hdd_read
        jc .full
        mov si, secbuf
        mov word [ent_left], 16
.entry:
        mov al, [si]
        test al, al
        jz .found
        cmp al, 0xE5
        je .found
        add si, 32
        dec word [ent_left]
        jnz .entry
        inc word [scan_lba]
        dec word [root_left]
        jnz .scan
.full:
        stc
        ret
.found:
        mov ax, [scan_lba]
        mov [ent_lba], ax
        mov ax, si
        sub ax, secbuf
        mov [ent_off], ax
        clc
        ret

; read one line for SAVE -> svline (NUL terminated); CF on Ctrl-Z/EOF
save_line:
        mov di, svline
        xor cx, cx
.l:
        call getline_char
        cmp al, 13
        je .done
        cmp al, 10
        je .done
        cmp al, 8
        je .back
        cmp al, 127
        je .back
        cmp al, 0x1A
        je .eof
        cmp al, 32
        jb .l
        cmp cx, 120
        jae .l
        stosb
        inc cx
        call putc
        jmp .l
.back:
        test cx, cx
        jz .l
        dec cx
        dec di
        mov al, 8
        call putc
        mov al, ' '
        call putc
        mov al, 8
        call putc
        jmp .l
.done:
        mov al, 10
        call putc
        mov byte [di], 0
        clc
        ret
.eof:
        mov byte [di], 0
        stc
        ret

; =====================================================================
; EDIT FILE.TXT - full-screen editor (CGA/Hercules, 100 x 80)
; =====================================================================

do_edit:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        push bp
        call ed_is_serial
        test al, al
        jz .cgaok
        mov si, sp_noautowrap
        call sp_str
.cgaok:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .have
        mov si, s_ed_usage
        call puts
        jmp .ret
.have:
        mov di, fname
        mov bx, ed_name
        xor cx, cx
.tok:
        mov al, [si]
        test al, al
        jz .tokend
        cmp al, ' '
        je .tokend
        cmp cx, 11
        jae .tskip
        call upcase
        stosb
        mov [bx], al
        inc bx
        inc cx
.tskip:
        inc si
        jmp .tok
.tokend:
        mov byte [di], 0
        mov byte [bx], 0
        mov si, fname
        call build83

        mov ax, KERNEL_SEG
        mov es, ax
        mov di, ed_buf
        mov ax, 0x2020
        mov cx, 4000
        rep stosw
        mov byte [ed_rows], 1
        mov byte [ed_row], 0
        mov byte [ed_col], 0
        mov byte [ed_top], 0
        mov byte [ed_mod], 0
        mov byte [ed_ins], 1
        mov byte [ed_quitarmed], 0

        call find_file
        jc .blank
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, savebuf
        mov cx, 8192
        call load_file
        jc .blank
        call ed_parse
.blank:
        mov byte [ed_active], 1
        call ed_clear_screen
        call ed_draw_all
        call ed_status
        call ed_help
        call ed_cursor
        jmp ed_loop
.ret:
        pop bp
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---- editor: load raw savebuf (DX bytes) into 80-char lines ----

ed_parse:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov ax, KERNEL_SEG
        mov es, ax
        mov si, savebuf
        mov di, ed_buf
        mov cx, dx
        xor bx, bx
        mov byte [ed_rows], 1
.pc:
        test cx, cx
        jz .done
        lodsb
        dec cx
        cmp al, 13
        je .pc
        cmp al, 10
        je .nl
        cmp bl, 80
        jae .pc
        stosb
        inc bl
        jmp .pc
.nl:
        mov al, 80
        sub al, bl
        xor ah, ah
        add di, ax
        xor bl, bl
        inc byte [ed_rows]
        cmp byte [ed_rows], 100
        ja .done
        jmp .pc
.done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---- editor: screen primitives (direct video memory) ----

ed_clear_screen:
        call ed_is_serial
        test al, al
        jz .ecs_cga
        mov si, sp_clear
        call sp_str
        ret
.ecs_cga:
        push ax
        push cx
        push di
        push es
        mov ax, [vid_seg]
        mov es, ax
        xor di, di
        mov ax, 0x0720
        mov cx, 2000
        rep stosw
        pop es
        pop di
        pop cx
        pop ax
        ret

ed_getkey:                      ; AL/AH like INT 16h
        call ed_is_serial
        test al, al
        jz .egk_bios
        call getchar
        ret
.egk_bios:
        xor ah, ah
        int 0x16
        ret

ed_is_serial:                   ; AL=1 if this session writes to COM1
        push bx
        mov bl, [cur_task]
        xor bh, bh
        mov al, [task_out+bx]
        test al, al
        jz .eis_no
        mov al, 1
        pop bx
        ret
.eis_no:
        xor al, al
        pop bx
        ret

ed_ser_cell:                    ; DH=row, DL=col, AL=char, BL=attr
        cmp dl, 80
        jb .esc_ok
        ret
.esc_ok:
        push ax
        push bx
        push cx
        push dx
        mov cl, dl
        inc cl
        mov ch, dh
        inc ch
        call sp_cup
        cmp bl, 0x70
        jne .esc_n
        mov si, sp_inv
        jmp .esc_s
.esc_n:
        mov si, sp_reset
.esc_s:
        call sp_str
        pop dx
        pop cx
        pop bx
        pop ax
        push ax
        call ser1
        mov si, sp_reset
        call sp_str
        pop ax
        ret

ed_ser_line:                    ; DH=row, BL=attr, SI=80-char line
        push ax
        push bx
        push cx
        push dx
        push si
        mov cl, 1
        mov ch, dh
        inc ch
        call sp_cup
        cmp bl, 0x70
        jne .esl_n
        mov si, sp_inv
        jmp .esl_s
.esl_n:
        mov si, sp_reset
.esl_s:
        call sp_str
        pop si
        push si
        mov cx, 80
.esl_l:
        lodsb
        push cx
        call ser1
        pop cx
        loop .esl_l
        mov si, sp_reset
        call sp_str
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_ser_fill:                    ; DH=row, AL=char, BL=attr
        push ax
        push bx
        push cx
        push dx
        mov cl, 1
        mov ch, dh
        inc ch
        call sp_cup
        cmp bl, 0x70
        jne .esf_n
        mov si, sp_inv
        jmp .esf_s
.esf_n:
        mov si, sp_reset
.esf_s:
        call sp_str
        pop dx
        pop cx
        pop bx
        pop ax
        push ax
        mov cx, 80
.esf_l:
        push cx
        push ax
        call ser1
        pop ax
        pop cx
        loop .esf_l
        mov si, sp_reset
        call sp_str
        pop ax
        ret

ed_char:                        ; DH=row, DL=col, AL=char, BL=attr
        push ax
        push bx
        call ed_is_serial
        test al, al
        pop bx
        pop ax
        jnz ed_ser_cell
        push ax
        push bx
        push cx
        push dx
        push di
        push es
        mov cl, al
        mov ch, bl
        push dx
        mov al, dh
        xor ah, ah
        mov di, 80
        mul di
        pop dx
        xor dh, dh
        add ax, dx
        shl ax, 1
        mov di, ax
        mov ax, [vid_seg]
        mov es, ax
        mov al, cl
        mov ah, ch
        mov [es:di], ax
        pop es
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_fill_row:                    ; DH=row, AL=char, BL=attr
        push ax
        push bx
        call ed_is_serial
        test al, al
        pop bx
        pop ax
        jnz ed_ser_fill
        push ax
        push bx
        push cx
        push dx
        push di
        push es
        mov cl, al
        mov ch, bl
        push dx
        mov al, dh
        xor ah, ah
        mov di, 80
        mul di
        pop dx
        shl ax, 1
        mov di, ax
        mov ax, [vid_seg]
        mov es, ax
        mov al, cl
        mov ah, ch
        mov cx, 80
        rep stosw
        pop es
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_puts_rc:                     ; DH=row, DL=col, BL=attr, SI=string
        push ax
        push bx
        push si
.l:
        lodsb
        test al, al
        jz .d
        call ed_char
        inc dl
        jmp .l
.d:
        pop si
        pop bx
        pop ax
        ret

ed_draw_line:                   ; DH=screen row, BL=attr, SI=80-char line
        push ax
        push bx
        call ed_is_serial
        test al, al
        pop bx
        pop ax
        jnz ed_ser_line
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov bh, bl                      ; attribute; CX becomes the count
        push dx
        mov al, dh
        xor ah, ah
        mov di, 80
        mul di
        pop dx
        shl ax, 1
        mov di, ax
        mov ax, [vid_seg]
        mov es, ax
        mov cx, 80
.dl:
        lodsb
        mov ah, bh
        stosw
        loop .dl
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_draw_all:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov byte [ed_tmp], 0
.row:
        cmp byte [ed_tmp], 23
        jae .done
        mov al, [ed_top]
        add al, [ed_tmp]
        cmp al, [ed_rows]
        jae .blank
        mov bl, al
        xor bh, bh
        mov ax, bx
        mov cx, 80
        mul cx
        mov si, ed_buf
        add si, ax
        mov dh, [ed_tmp]
        inc dh
        mov bl, 0x07
        call ed_draw_line
        jmp .next
.blank:
        mov dh, [ed_tmp]
        inc dh
        mov al, ' '
        mov bl, 0x07
        call ed_fill_row
.next:
        inc byte [ed_tmp]
        jmp .row
.done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_status:
        push ax
        push bx
        push dx
        push si
        mov dh, 0
        mov al, ' '
        mov bl, 0x70
        call ed_fill_row
        mov word [tb_i], 0
        mov si, s_ed_title
        call tb_str
        mov si, ed_name
        call tb_str
        mov si, s_ed_ln
        call tb_str
        mov al, [ed_row]
        inc al
        xor ah, ah
        call tb_dec3
        mov al, '/'
        call tb_ch
        mov al, [ed_rows]
        xor ah, ah
        call tb_dec3
        mov si, s_ed_col
        call tb_str
        mov al, [ed_col]
        inc al
        xor ah, ah
        call tb_dec3
        mov si, s_ed_sp2
        call tb_str
        cmp byte [ed_ins], 0
        je .ovr
        mov si, s_ed_ins
        jmp .ins
.ovr:
        mov si, s_ed_ovr
.ins:
        call tb_str
        mov al, ' '
        call tb_ch
        cmp byte [ed_mod], 0
        je .nomod
        mov al, '*'
        jmp .mod
.nomod:
        mov al, ' '
.mod:
        call tb_ch
        xor al, al
        call tb_ch
        mov dh, 0
        xor dl, dl
        mov bl, 0x70
        mov si, tbuf
        call ed_puts_rc
        pop si
        pop dx
        pop bx
        pop ax
        ret

ed_help:
        push ax
        push bx
        push dx
        push si
        mov dh, 24
        mov al, ' '
        mov bl, 0x07
        call ed_fill_row
        mov dh, 24
        xor dl, dl
        mov bl, 0x0F
        mov si, s_ed_help
        call ed_puts_rc
        pop si
        pop dx
        pop bx
        pop ax
        ret

ed_unsaved:
        mov dh, 24
        mov al, ' '
        mov bl, 0x0F
        call ed_fill_row
        mov dh, 24
        xor dl, dl
        mov bl, 0x0F
        mov si, s_ed_unsaved
        call ed_puts_rc
        ret

ed_cursor:
        call ed_is_serial
        test al, al
        jz .ecur_cga
        mov dh, [ed_row]
        sub dh, [ed_top]
        inc dh
        mov ch, dh
        mov cl, [ed_col]
        inc cl
        call sp_cup
        ret
.ecur_cga:
        push ax
        push bx
        push dx
        mov dh, [ed_row]
        sub dh, [ed_top]
        inc dh
        mov dl, [ed_col]
        xor bh, bh
        mov ah, 2
        inc byte [crit]
        call bios_video
        dec byte [crit]
        pop dx
        pop bx
        pop ax
        ret

ed_redraw_line:
        push ax
        push bx
        push cx
        push dx
        push si
        mov al, [ed_row]
        mov bl, al
        xor bh, bh
        mov ax, bx
        mov cx, 80
        mul cx
        mov si, ed_buf
        add si, ax
        mov dh, [ed_row]
        sub dh, [ed_top]
        inc dh
        mov bl, 0x07
        call ed_draw_line
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_scroll_check:
        mov al, [ed_row]
        cmp al, [ed_top]
        jae .below
        mov [ed_top], al
        call ed_draw_all
        ret
.below:
        mov al, [ed_top]
        add al, 22
        cmp al, [ed_row]
        jae .done
        mov al, [ed_row]
        sub al, 22
        mov [ed_top], al
        call ed_draw_all
.done:
        ret

; ---- editor: line editing ----

ed_insert_at:                   ; AL = char at ed_row/ed_col
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov bl, al
        mov ax, KERNEL_SEG
        mov es, ax
        mov al, [ed_row]
        xor ah, ah
        mov cx, 80
        mul cx
        mov di, ed_buf
        add di, ax
        mov al, [ed_col]
        xor ah, ah
        add di, ax
        mov [ed_ptr], di
        cmp byte [ed_ins], 0
        je .ovr
        mov cx, 79
        sub cl, [ed_col]
        jz .put
        mov si, di
        add si, 78
        sub si, ax
        mov dx, di
        add dx, 79
        sub dx, ax
        mov di, dx
        std
        rep movsb
        cld
.put:
        mov di, [ed_ptr]
        mov al, bl
        stosb
        jmp .done
.ovr:
        mov di, [ed_ptr]
        mov al, bl
        stosb
.done:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_del_at:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov al, [ed_row]
        xor ah, ah
        mov cx, 80
        mul cx
        mov di, ed_buf
        add di, ax
        mov al, [ed_col]
        xor ah, ah
        add di, ax
        mov si, di
        inc si
        mov cx, 79
        sub cl, [ed_col]
        jz .pad
        cld
        rep movsb
.pad:
        mov al, [ed_row]
        xor ah, ah
        mov cx, 80
        mul cx
        mov di, ed_buf
        add di, ax
        add di, 79
        mov al, ' '
        stosb
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_insert_line:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        cmp byte [ed_rows], 100
        jae .ret
        mov ax, KERNEL_SEG
        mov es, ax
        mov al, [ed_rows]
        sub al, [ed_row]
        xor ah, ah
        mov cx, 80
        mul cx
        mov cx, ax
        mov al, [ed_rows]
        dec al
        xor ah, ah
        mov bx, 80
        mul bx
        mov si, ed_buf
        add si, ax
        mov di, si
        add di, 80
        std
        rep movsb
        cld
        mov al, [ed_row]
        xor ah, ah
        mov cx, 80
        mul cx
        mov di, ed_buf
        add di, ax
        mov ax, 0x2020
        mov cx, 40
        rep stosw
        inc byte [ed_rows]
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ed_delete_line:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        cmp byte [ed_rows], 1
        jbe .ret
        mov ax, KERNEL_SEG
        mov es, ax
        mov al, [ed_rows]
        sub al, [ed_row]
        dec al
        jz .clear
        xor ah, ah
        mov cx, 80
        mul cx
        mov cx, ax
        mov al, [ed_row]
        inc al
        xor ah, ah
        mov bx, 80
        mul bx
        mov si, ed_buf
        add si, ax
        mov di, si
        sub di, 80
        cld
        rep movsb
.clear:
        mov al, [ed_rows]
        dec al
        xor ah, ah
        mov cx, 80
        mul cx
        mov di, ed_buf
        add di, ax
        mov ax, 0x2020
        mov cx, 40
        rep stosw
        dec byte [ed_rows]
        mov al, [ed_rows]
        dec al
        cmp al, [ed_row]
        jae .ret
        mov [ed_row], al
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---- editor: save ----

ed_putdec:                      ; AX -> decimal at DH/DL, BL attr
        push ax
        push bx
        push cx
        mov [ed_pdx], dx
        mov bx, 10
        xor cx, cx
.div:
        xor dx, dx
        div bx
        push dx
        inc cx
        test ax, ax
        jnz .div
        mov dx, [ed_pdx]
.pr:
        pop ax
        add al, '0'
        call ed_char
        inc dl
        loop .pr
        pop cx
        pop bx
        pop ax
        ret

ed_save_buffer:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        cmp byte [write_ok], 0
        jne .wok
        mov dh, 0
        mov al, ' '
        mov bl, 0x70
        call ed_fill_row
        mov dh, 0
        xor dl, dl
        mov bl, 0x70
        mov si, s_ed_wr_off
        call ed_puts_rc
        jmp .ret
.wok:
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, savebuf
        xor bx, bx
        mov si, ed_buf
        mov byte [ed_tmp], 0
.srow:
        mov al, [ed_tmp]
        cmp al, [ed_rows]
        jae .sdone
        cmp bx, 8100
        jae .sdone
        mov cx, 80
.scopy:
        lodsb
        mov [di], al
        inc di
        inc bx
        loop .scopy
        mov dx, 80
.trim:
        cmp dx, 0
        je .emit
        cmp byte [di-1], ' '
        jne .emit
        dec di
        dec bx
        dec dx
        jmp .trim
.emit:
        mov byte [di], 10
        inc di
        inc bx
        inc byte [ed_tmp]
        jmp .srow
.sdone:
        mov [sv_size], bx
        mov word [sv_src], savebuf
        mov word [sv_src_seg], KERNEL_SEG
        call write_file
        jc .err
        mov byte [ed_mod], 0
        mov dh, 0
        mov al, ' '
        mov bl, 0x70
        call ed_fill_row
        mov dh, 0
        xor dl, dl
        mov bl, 0x70
        mov si, s_ed_saved
        call ed_puts_rc
        mov ax, [sv_size]
        call ed_putdec
        mov si, s_ed_bytes2
        call ed_puts_rc
        jmp .ret
.err:
        mov dh, 0
        mov al, ' '
        mov bl, 0x70
        call ed_fill_row
        mov dh, 0
        xor dl, dl
        mov bl, 0x70
        mov si, s_ed_saveerr
        call ed_puts_rc
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---- editor: key loop ----

ed_loop:
        call ed_getkey
        cmp ah, 0x3B
        je ed_key_save
        cmp ah, 0x3C
        je ed_key_quit
        cmp ah, 0x01
        je ed_key_quit
        cmp byte [ed_quitarmed], 0
        je .noarm
        mov byte [ed_quitarmed], 0
        call ed_help
.noarm:
        cmp ah, 0x48
        je ed_key_up
        cmp ah, 0x50
        je ed_key_down
        cmp ah, 0x4B
        je ed_key_left
        cmp ah, 0x4D
        je ed_key_right
        cmp ah, 0x47
        je ed_key_home
        cmp ah, 0x4F
        je ed_key_end
        cmp ah, 0x49
        je ed_key_pgup
        cmp ah, 0x51
        je ed_key_pgdn
        cmp ah, 0x53
        je ed_key_del
        cmp ah, 0x52
        je ed_key_ins
        cmp al, 13
        je ed_key_enter
        cmp al, 10
        je ed_key_enter
        cmp al, 8
        je ed_key_bs
        cmp al, 127
        je ed_key_bs
        cmp al, 9
        je ed_key_tab
        cmp al, 14
        je ed_key_insline
        cmp al, 25
        je ed_key_delline
        cmp al, 19
        je ed_key_save
        cmp al, 17
        je ed_key_quit
        cmp al, 32
        jb ed_loop
        cmp al, 126
        ja ed_loop
        jmp ed_key_char

ed_key_up:
        cmp byte [ed_row], 0
        je .go
        dec byte [ed_row]
.go:
        call ed_scroll_check
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_down:
        mov al, [ed_row]
        inc al
        cmp al, [ed_rows]
        jae .go
        mov [ed_row], al
.go:
        call ed_scroll_check
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_left:
        cmp byte [ed_col], 0
        jne .dec
        cmp byte [ed_row], 0
        je .go
        dec byte [ed_row]
        mov byte [ed_col], 79
        call ed_scroll_check
        jmp .go
.dec:
        dec byte [ed_col]
.go:
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_right:
        cmp byte [ed_col], 79
        jae .next
        inc byte [ed_col]
        jmp .go
.next:
        mov al, [ed_row]
        inc al
        cmp al, [ed_rows]
        jae .go
        mov [ed_row], al
        mov byte [ed_col], 0
        call ed_scroll_check
.go:
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_home:
        mov byte [ed_col], 0
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_end:
        mov byte [ed_col], 79
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_pgup:
        cmp byte [ed_row], 23
        jb .zero
        sub byte [ed_row], 23
        jmp .go
.zero:
        mov byte [ed_row], 0
.go:
        call ed_scroll_check
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_pgdn:
        mov al, [ed_row]
        add al, 23
        cmp al, [ed_rows]
        jb .set
        mov al, [ed_rows]
        dec al
.set:
        mov [ed_row], al
        call ed_scroll_check
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_enter:
        mov al, [ed_row]
        inc al
        cmp al, [ed_rows]
        jb .set
        cmp byte [ed_rows], 100
        jae .go
        inc byte [ed_rows]
.set:
        mov [ed_row], al
        mov byte [ed_col], 0
.go:
        call ed_scroll_check
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_bs:
        cmp byte [ed_col], 0
        jne .same
        cmp byte [ed_row], 0
        je .go
        dec byte [ed_row]
        mov byte [ed_col], 79
        call ed_del_at
        call ed_scroll_check
        jmp .mark
.same:
        dec byte [ed_col]
        call ed_del_at
.mark:
        mov byte [ed_mod], 1
        call ed_redraw_line
.go:
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_del:
        call ed_del_at
        mov byte [ed_mod], 1
        call ed_redraw_line
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_tab:
        mov cx, 4
.t:
        mov al, ' '
        call ed_insert_at
        cmp byte [ed_col], 79
        jae .next
        inc byte [ed_col]
.next:
        loop .t
        mov byte [ed_mod], 1
        call ed_redraw_line
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_ins:
        xor byte [ed_ins], 1
        call ed_status
        jmp ed_loop

ed_key_insline:
        call ed_insert_line
        mov byte [ed_mod], 1
        call ed_draw_all
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_delline:
        call ed_delete_line
        mov byte [ed_mod], 1
        call ed_draw_all
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_char:
        call ed_insert_at
        cmp byte [ed_col], 79
        jae .go
        inc byte [ed_col]
.go:
        mov byte [ed_mod], 1
        call ed_redraw_line
        call ed_cursor
        call ed_status
        jmp ed_loop

ed_key_save:
        mov byte [ed_quitarmed], 0
        call ed_help
        call ed_save_buffer
        call ed_cursor
        jmp ed_loop

ed_key_quit:
        cmp byte [ed_mod], 0
        je ed_exit
        cmp byte [ed_quitarmed], 0
        jne ed_exit
        mov byte [ed_quitarmed], 1
        call ed_unsaved
        jmp ed_loop

ed_exit:
        mov byte [ed_active], 0
        call ed_is_serial
        test al, al
        jz .ee_cga
        mov si, sp_reset
        call sp_str
        mov si, sp_autowrap
        call sp_str
.ee_cga:
        call ed_clear_screen
        mov byte [prow], 2
        mov byte [pcol], 0
        mov dh, 2
        xor dl, dl
        xor bh, bh
        mov ah, 2
        call bios_video
        mov si, s_ed_done
        call puts
        jmp do_edit.ret

; =====================================================================
; write_file: write namebuf from sv_src/sv_size to C:
; CF=0 success (AX=size), CF=1 error (message already printed)
; =====================================================================
write_file:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        cmp byte [disk_ro], 0
        je .w_ok
        mov si, s_vol_ro
        call puts
        stc
        jmp .ret
.w_ok:
        call find_file
        jc .new
        mov byte [dir_new], 0
        mov ax, [file_cluster]
        call free_chain
        jmp .alloc
.new:
        mov byte [dir_new], 1
.alloc:
        mov word [sv_first], 0
        mov word [sv_prev], 0
        mov ax, [sv_size]
        test ax, ax
        jz .nocls
        mov ax, 512
        mov cl, [sec_per_clus]
        xor ch, ch
        mul cx
        mov bx, ax
        mov ax, [sv_size]
        add ax, bx
        dec ax
        xor dx, dx
        div bx
        mov [sv_cnt], ax
.cl:
        call alloc_cluster
        jc .nofree
        cmp word [sv_first], 0
        jne .chain
        mov [sv_first], ax
.chain:
        cmp word [sv_prev], 0
        je .first
        push ax
        mov dx, ax
        mov ax, [sv_prev]
        call fat_set
        pop ax
.first:
        mov [sv_prev], ax
        dec word [sv_cnt]
        jnz .cl
        mov ax, [sv_prev]
        mov dx, 0xFFFF
        call fat_set
.nocls:
        mov ax, [sv_first]
        mov [sv_cur], ax
        mov word [sv_off], 0
        mov ax, [sv_size]
        test ax, ax
        jz .entry
.wcl:
        mov ax, [sv_off]
        cmp ax, [sv_size]
        jae .entry
        mov al, [sec_per_clus]
        xor ah, ah
        mov [sv_secs], ax
        mov ax, [sv_cur]
        sub ax, 2
        mov cl, [sec_per_clus]
        xor ch, ch
        mul cx
        add ax, [data_lba]
        mov [sv_lba], ax
.wsec:
        mov ax, [sv_off]
        cmp ax, [sv_size]
        jae .entry
        mov si, [sv_src]
        add si, [sv_off]
        mov di, secbuf
        mov ax, [sv_size]
        sub ax, [sv_off]
        mov cx, 512
        cmp ax, 512
        jae .fullsec
        mov cx, ax
.fullsec:
        mov ax, [sv_src_seg]
        push ds
        mov ds, ax
        rep movsb
        pop ds
        mov ax, [sv_lba]
        call hdd_write
        jc .ioerr_w
        add word [sv_off], 512
        inc word [sv_lba]
        dec word [sv_secs]
        jnz .wsec
        mov ax, [sv_cur]
        call fat_get
        cmp dx, 0xFFF8
        jae .entry
        mov [sv_cur], dx
        jmp .wcl
.nofree:
        mov al, 1
        jmp .err
.ioerr:
        mov al, 2
        jmp .err
.ioerr_w:
        mov al, 4
        jmp .err
.ioerr_r:
        mov al, 5
        jmp .err
.ioerr_e:
        mov al, 6
        jmp .err
.entry:
        cmp byte [dir_new], 0
        je .haveent
        call free_dir
        jc .no_space
.haveent:
        mov ax, KERNEL_SEG
        mov es, ax
        mov ax, [ent_lba]
        call hdd_read
        jc .ioerr_r
        mov di, secbuf
        add di, [ent_off]
        mov si, namebuf
        mov cx, 11
        rep movsb
        mov al, 0x20
        stosb
        xor cx, cx
.z:
        xor al, al
        stosb
        inc cx
        cmp cx, 20
        jb .z
        mov di, secbuf
        add di, [ent_off]
        mov ax, [sv_first]
        mov [di+26], ax
        mov ax, [sv_size]
        mov [di+28], ax
        xor ax, ax
        mov [di+30], ax
        mov ax, [ent_lba]
        call hdd_write
        jc .ioerr_e
        mov ax, [sv_size]
        clc
        jmp .ret
.no_space:
        mov al, 3
.err:
        stc
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; FORMAT A:|B:  - build a FAT12 volume on a floppy
; =====================================================================
do_format:
        push ax
        push si
        cmp byte [write_ok], 0
        jne .ok
        mov si, s_wr_off
        call puts
        jmp .ret
.ok:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .have
        mov si, s_fmt_usage
        call puts
        jmp .ret
.have:
        mov al, [si]
        call upcase
        cmp al, 'A'
        jne .b
        xor al, al
        call format_volume
        jmp .ret
.b:
        cmp al, 'B'
        jne .bad
        mov al, 1
        call format_volume
        jmp .ret
.bad:
        mov si, s_fmt_usage
        call puts
.ret:
        pop si
        pop ax
        ret

; AL = drive (0=A, 1=B).  Builds a FAT12 volume and refuses to touch the
; disk the machine was booted from.
format_volume:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov [fmt_drv], al
        ; refuse before asking anything if this is the disk we booted from
        mov ax, KERNEL_SEG
        mov es, ax
        mov byte [disk_ram], 0
        mov al, [fmt_drv]
        mov [disk_dl], al
        mov word [spt], 9
        mov word [heads], 2
        xor ax, ax
        call hdd_read
        jc .noboot
        mov al, [fmt_drv]
        cmp al, [boot_dl]
        jne .noboot
        mov ax, [secbuf]
        cmp ax, [boot_sig]
        jne .noboot
        mov ax, [secbuf+2]
        cmp ax, [boot_sig+2]
        jne .noboot
        mov si, s_fmt_bootdisk
        call puts
        stc
        jmp .out
.noboot:
        ; capacity is explicit: INT 13h AH=08h reports the DRIVE geometry,
        ; not the media, so a 360K disk in a 1.44M drive would mis-report
        mov si, s_fmt_cap
        call puts
        xor ah, ah
        int 0x16
        push ax
        call putc
        pop ax
        cmp al, '1'
        je .c360
        cmp al, '2'
        je .c720
        cmp al, '3'
        je .c144
        mov si, s_fmt_abort
        call puts
        stc
        jmp .out
.c360:
        mov word [fmt_total], 720
        mov byte [fmt_spc], 2
        mov word [fmt_root], 112
        mov byte [fmt_media], 0xFD
        mov word [fmt_fatsec], 2
        mov word [fmt_spt], 9
        mov word [fmt_heads], 2
        mov word [fmt_cyl], 40
        jmp .params
.c720:
        mov word [fmt_total], 1440
        mov byte [fmt_spc], 2
        mov word [fmt_root], 112
        mov byte [fmt_media], 0xF9
        mov word [fmt_fatsec], 3
        mov word [fmt_spt], 9
        mov word [fmt_heads], 2
        mov word [fmt_cyl], 80
        jmp .params
.c144:
        mov word [fmt_total], 2880
        mov byte [fmt_spc], 1
        mov word [fmt_root], 224
        mov byte [fmt_media], 0xF0
        mov word [fmt_fatsec], 9
        mov word [fmt_spt], 18
        mov word [fmt_heads], 2
        mov word [fmt_cyl], 80
.params:
        mov ax, [fmt_root]
        add ax, 15
        mov cl, 4
        shr ax, cl
        mov [fmt_rootsec], ax
.f_ok:
        mov si, s_fmt_det
        call puts
        mov ax, [fmt_cyl]
        call put_dec
        mov si, s_fmt_x
        call puts
        mov ax, [fmt_heads]
        call put_dec
        mov si, s_fmt_x
        call puts
        mov ax, [fmt_spt]
        call put_dec
        mov si, s_fmt_secs
        call puts
        mov ax, [fmt_total]
        call put_dec
        mov si, s_fmt_ask
        call puts
        xor ah, ah
        int 0x16
        push ax
        call putc
        pop ax
        call upcase
        cmp al, 'Y'
        je .doit
        mov si, s_fmt_abort
        call puts
        stc
        jmp .out
.doit:
        mov di, secbuf
        mov cx, 256
        xor ax, ax
        rep stosw
        mov di, secbuf
        mov al, 0xEB
        stosb
        mov al, 0x3C
        stosb
        mov al, 0x90
        stosb
        mov si, s_fmt_oem
        mov cx, 8
        rep movsb
        mov di, secbuf+11
        mov ax, 512
        stosw
        mov di, secbuf+13
        mov al, [fmt_spc]
        stosb
        mov di, secbuf+14
        mov ax, 1
        stosw
        mov di, secbuf+16
        mov al, 2
        stosb
        mov di, secbuf+17
        mov ax, [fmt_root]
        stosw
        mov di, secbuf+19
        mov ax, [fmt_total]
        stosw
        mov di, secbuf+21
        mov al, [fmt_media]
        stosb
        mov di, secbuf+22
        mov ax, [fmt_fatsec]
        stosw
        mov di, secbuf+24
        mov ax, [fmt_spt]
        stosw
        mov di, secbuf+26
        mov ax, [fmt_heads]
        stosw
        mov byte [secbuf+36], 0
        mov byte [secbuf+38], 0x29
        mov di, secbuf+43
        mov si, s_fmt_label
        mov cx, 11
        rep movsb
        mov di, secbuf+54
        mov si, s_fmt_fatname
        mov cx, 8
        rep movsb
        mov word [secbuf+510], 0xAA55
        xor ax, ax
        call hdd_write
        jc .ioerr

        mov di, secbuf
        mov cx, 256
        xor ax, ax
        rep stosw
        mov ax, [fmt_fatsec]
        shl ax, 1
        inc ax
        mov [fmt_lba], ax
        mov cx, [fmt_rootsec]
.rz:
        mov ax, [fmt_lba]
        call hdd_write
        jc .ioerr
        inc word [fmt_lba]
        loop .rz

        mov ax, 1
        mov [fmt_lba], ax
        mov byte [fmt_copy], 2
.fcopy:
        mov di, secbuf
        mov cx, 256
        xor ax, ax
        rep stosw
        mov al, [fmt_media]
        mov [secbuf], al
        mov byte [secbuf+1], 0xFF
        mov byte [secbuf+2], 0xFF
        mov ax, [fmt_lba]
        call hdd_write
        jc .ioerr
        inc word [fmt_lba]
        mov bx, [fmt_fatsec]
        dec bx
        jz .fc_done
.fzero:
        mov di, secbuf
        mov cx, 256
        xor ax, ax
        rep stosw
        mov ax, [fmt_lba]
        call hdd_write
        jc .ioerr
        inc word [fmt_lba]
        dec bx
        jnz .fzero
.fc_done:
        dec byte [fmt_copy]
        jnz .fcopy

        mov al, [fmt_drv]
        mov [disk_dl], al
        call fat_mount
        jc .ioerr
        mov si, s_fmt_done
        call puts
        clc
        jmp .out
.ioerr:
        mov si, s_fmt_ioerr
        call puts
        mov al, [disk_err]
        xor ah, ah
        call put_dec
        mov si, s_nl
        call puts
        stc
.out:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; SAVE FILE.TXT - read lines until "." (or Ctrl-Z), write to C:
do_save:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        cmp byte [write_ok], 0
        jne .ok
        mov si, s_wr_off
        call puts
        jmp .ret
.ok:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .have
        mov si, s_save_usage
        call puts
        jmp .ret
.have:
        ; token -> fname (same rules as RUN)
        mov di, fname
        xor cx, cx
.tok:
        mov al, [si]
        test al, al
        jz .tokend
        cmp al, ' '
        je .tokend
        cmp cx, 11
        jae .tskip
        call upcase
        stosb
        inc cx
.tskip:
        inc si
        jmp .tok
.tokend:
        mov byte [di], 0
        mov si, fname
        call build83
        ; existing entry?
        call find_file
        jc .newent
        mov byte [dir_new], 0
        jmp .read
.newent:
        mov byte [dir_new], 1
.read:
        mov word [sv_size], 0
        mov si, s_save_hint
        call puts
.line:
        call save_line
        jc .endin
        ; end on a lone "."
        mov si, svline
        cmp byte [si], '.'
        jne .store
        cmp byte [si+1], 0
        je .endin
.store:
        ; append svline + LF
        mov si, svline
.copy:
        mov al, [si]
        test al, al
        jz .crlf
        mov bx, [sv_size]
        cmp bx, 4090
        jae .full
        mov di, savebuf
        add di, bx
        mov [di], al
        inc word [sv_size]
        inc si
        jmp .copy
.crlf:
        mov bx, [sv_size]
        mov di, savebuf
        add di, bx
        mov al, 10
        mov [di], al
        inc word [sv_size]
        jmp .line
.full:
        mov si, s_save_full
        call puts
.endin:
        mov word [sv_src], savebuf
        mov word [sv_src_seg], KERNEL_SEG
        call write_file
        jc .werr
        mov si, s_saved
        call puts
        mov ax, [sv_size]
        call put_dec
        mov si, s_saved_bytes
        call puts
        jmp .ret
.werr:
        cmp al, 2
        je .werr_io
        mov si, s_no_space
        call puts
        jmp .ret
.werr_io:
        mov si, s_io_err
        call puts
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; DELETE FILE.TXT
do_delete:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        cmp byte [write_ok], 0
        jne .ok
        mov si, s_wr_off
        call puts
        jmp .ret
.ok:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .have
        mov si, s_del_usage
        call puts
        jmp .ret
.have:
        mov di, fname
        xor cx, cx
.tok:
        mov al, [si]
        test al, al
        jz .tokend
        cmp al, ' '
        je .tokend
        cmp cx, 11
        jae .tskip
        call upcase
        stosb
        inc cx
.tskip:
        inc si
        jmp .tok
.tokend:
        mov byte [di], 0
        mov si, fname
        call build83
        call find_file
        jc .nofile
        mov ax, [file_cluster]
        cmp ax, 2
        jb .delent
        call free_chain
.delent:
        mov ax, [ent_lba]
        call hdd_read
        jc .ioerr
        mov di, secbuf
        add di, [ent_off]
        mov byte [di], 0xE5
        mov ax, [ent_lba]
        call hdd_write
        jc .ioerr
        mov si, s_deleted
        call puts
        jmp .ret
.nofile:
        mov si, s_nofile3
        call puts
        jmp .ret
.ioerr:
        mov si, s_io_err
        call puts
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; DRIVE A|B|C - mount a volume (floppy can be swapped after boot)
; =====================================================================

; COPY [C:|M:|A:|B:]SRC [C:|M:|A:|B:]DST
; A bare destination drive (e.g. "M:") keeps the source name.
do_copy:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov byte [copy_locked], 0
        mov al, [disk_ram]
        mov [copy_old_ram], al
        mov al, [disk_dl]
        mov [copy_old_dl], al
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        je .usage
        mov di, copysrc
        xor cx, cx
.t1:
        mov al, [si]
        test al, al
        jz .t1d
        cmp al, ' '
        je .t1d
        cmp cx, 15
        jae .t1s
        call upcase
        stosb
        inc cx
.t1s:
        inc si
        jmp .t1
.t1d:
        mov byte [di], 0
        call skip_sp
        cmp byte [si], 0
        je .usage
        mov di, copydst
        xor cx, cx
.t2:
        mov al, [si]
        test al, al
        jz .t2d
        cmp al, ' '
        je .t2d
        cmp cx, 15
        jae .t2s
        call upcase
        stosb
        inc cx
.t2s:
        inc si
        jmp .t2
.t2d:
        mov byte [di], 0
        cmp byte [write_ok], 0
        jne .wr
        mov si, s_wr_off
        call puts
        jmp .ret
.wr:
        inc byte [crit]
        mov byte [copy_locked], 1
        mov si, copysrc
        call copy_parse_drive
        mov [copy_src_drv], al
        mov [copy_src_name], si
        cmp byte [si], 0
        je .usage
        mov al, [copy_src_drv]
        call copy_mount
        jc .ret
        mov si, [copy_src_name]
        call build83
        call find_file
        jc .nofile
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, savebuf
        mov cx, 4095
        call load_file
        jc .nofile
        mov [copy_size], dx
        mov si, copydst
        call copy_parse_drive
        mov [copy_dst_drv], al
        mov [copy_dst_name], si
        cmp byte [si], 0
        jne .dn
        mov si, [copy_src_name]
        mov [copy_dst_name], si
.dn:
        mov al, [copy_dst_drv]
        call copy_mount
        jc .ret
        mov si, [copy_dst_name]
        call build83
        mov word [sv_src], savebuf
        mov word [sv_src_seg], KERNEL_SEG
        mov ax, [copy_size]
        mov [sv_size], ax
        call write_file
        jc .werr
        mov si, s_copy_ok
        call puts
        mov ax, [copy_size]
        call put_dec
        mov si, s_copy_bytes
        call puts
        jmp .ret
.nofile:
        mov si, s_copy_nofile
        call puts
        jmp .ret
.werr:
        mov si, s_copy_werr
        call puts
        jmp .ret
.usage:
        mov si, s_copy_usage
        call puts
.ret:
        cmp byte [copy_locked], 0
        je .ret0
        dec byte [crit]
        mov byte [copy_locked], 0
.ret0:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; SI=token, AL=0 -> AL=drive letter (0 none), SI=name
copy_parse_drive:
        mov al, [si]
        cmp byte [si+1], ':'
        jne .none
        call upcase
        cmp al, 'A'
        je .ok
        cmp al, 'B'
        je .ok
        cmp al, 'C'
        je .ok
        cmp al, 'M'
        je .ok
        xor al, al
        ret
.ok:
        add si, 2
        ret
.none:
        xor al, al
        ret

; AL=drive or 0; mount it (M: formats only if unformatted)
copy_mount:
        test al, al
        jz .ok
        cmp al, 'M'
        je .m
        mov byte [disk_ram], 0
        mov byte [disk_dl], 0
        cmp al, 'A'
        je .go
        mov byte [disk_dl], 1
        cmp al, 'B'
        je .go
        mov byte [disk_dl], 0x80
        jmp .go
.m:
        mov byte [disk_ram], 1
        mov byte [disk_dl], 0
        xor ax, ax
        call ram_read
        jc .m_fmt
        cmp word [secbuf+11], 512
        jne .m_fmt
        cmp byte [secbuf+13], 1
        jne .m_fmt
        cmp word [secbuf+19], RAMSECT
        jne .m_fmt
        cmp word [secbuf+510], 0xAA55
        jne .m_fmt
        jmp .go
.m_fmt:
        call ram_format
        jmp .go
.ok:
        clc
        ret
.go:
        call fat_mount
        jc .fail
        clc
        ret
.fail:
        mov al, [copy_old_ram]
        mov [disk_ram], al
        mov al, [copy_old_dl]
        mov [disk_dl], al
        call fat_mount
        stc
        ret

do_drive:
        push ax
        push si
        mov si, [bp+144]
        call skip_sp
        mov al, [si]
        call upcase
        cmp al, 'A'
        je .da
        cmp al, 'B'
        je .db
        cmp al, 'C'
        je .dc
        cmp al, 'M'
        je .dm
        mov si, s_drive_usage
        call puts
        jmp .ret
.da:
        mov byte [disk_ram], 0
        mov byte [disk_dl], 0
        jmp .mount
.db:
        mov byte [disk_ram], 0
        mov byte [disk_dl], 1
        jmp .mount
.dc:
        mov byte [disk_ram], 0
        mov byte [disk_dl], 0x80
        jmp .mount
.dm:
        mov byte [disk_ram], 1
        mov byte [disk_dl], 0
        call ram_format
.mount:
        call fat_mount
.ret:
        pop si
        pop ax
        ret

; =====================================================================
; WRITE ON|OFF - allow SAVE/DELETE on C: (default OFF)
; =====================================================================

do_write:
        push ax
        push si
        call check_elev
        cmp al, 0
        je .console
        cmp al, 1
        je .conly
        mov si, s_priv_req
        call sys_begin
        call puts
        jmp .ret
.conly:
        mov si, s_wr_console_only
        call sys_begin
        call puts
        jmp .ret
.console:
        mov si, [bp+144]
        call skip_sp
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .p
        call sys_begin
        mov si, s_wr_state
        call puts
        cmp byte [write_ok], 0
        je .off
        mov si, s_on
        jmp .pp
.off:
        mov si, s_offstr
.pp:
        call puts
        mov al, 10
        call putc
        jmp .ret
.p:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .ret
        mov al, [si+1]
        call upcase
        cmp al, 'N'
        jne .offcmd
        mov byte [write_ok], 1
        call sys_begin
        mov si, s_wr_on
        call puts
        jmp .ret
.offcmd:
        cmp al, 'F'
        jne .ret
        mov al, [si+2]
        call upcase
        cmp al, 'F'
        jne .ret
        mov byte [write_ok], 0
        call sys_begin
        mov si, s_wr_off2
        call puts
.ret:
        pop si
        pop ax
        ret

; =====================================================================
; VIDEO MONO|COLOR - select the text adapter
; =====================================================================

do_video:
        push ax
        push si
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .par
        mov si, s_video_state
        call puts
        cmp byte [mono], 0
        je .vcol
        mov si, s_mono
        jmp .vp
.vcol:
        mov si, s_color
.vp:
        call puts
        mov al, 10
        call putc
        jmp .ret
.par:
        mov al, [si]
        call upcase
        cmp al, 'M'
        je .vmono
        cmp al, 'C'
        je .vcolor
        mov si, s_video_usage
        call puts
        jmp .ret
.vmono:
        mov byte [mono], 1
        mov word [vid_seg], 0xB000
        mov ax, 7
        jmp .vset
.vcolor:
        mov byte [mono], 0
        mov word [vid_seg], 0xB800
        mov ax, 3
.vset:
        mov ah, 0
        call bios_video
        call panel_init
        mov si, s_video_set
        call puts
.ret:
        pop si
        pop ax
        ret

; =====================================================================
; PANEL ON|OFF - ANSI panel on the serial console
; =====================================================================

do_panel:
        push ax
        push si
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        mov al, [task_out+si]
        mov [pv_out], al
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_panel_state
        call puts
        cmp byte [pv_out], 1
        jne .rcga
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        cmp byte [ser_panel+si], 0
        je .off
        mov si, s_on
        jmp .pp
.rcga:
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        cmp byte [ser_panel+si], 0
        je .off
        mov si, s_on
        jmp .pp
.off:
        mov si, s_offstr
.pp:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .offc
        mov al, [si+1]
        call upcase
        cmp al, 'N'
        jne .offc
        cmp byte [pv_out], 1
        jne .oncga
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        mov byte [ser_panel+si], 1
        mov byte [sp_cleared+si], 0
        mov si, sp_noautowrap
        call sp_str
        mov si, s_panel_on
        call puts
        jmp .ret
.oncga:
        mov byte [cga_panel], 1
        call panel_init
        mov si, s_panel_on
        call puts
        jmp .ret
.offc:
        cmp al, 'F'
        jne .ret
        mov al, [si+1]
        call upcase
        cmp al, 'F'
        jne .ret
        cmp byte [pv_out], 1
        jne .offcga
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        mov byte [ser_panel+si], 0
        mov si, sp_clear
        call sp_str
        mov si, sp_reset
        call sp_str
        mov si, sp_rst_rgn
        call sp_str
        mov si, sp_autowrap
        call sp_str
        jmp .done
.offcga:
        mov byte [cga_panel], 0
        call clr_screen
.done:
        mov si, s_panel_off
        call puts
.ret:
        pop si
        pop ax
        ret

; =====================================================================
; PS / KILL
; =====================================================================

put_hex:                        ; AX -> 4 hex digits
        push ax
        push bx
        push cx
        push dx
        mov bx, ax
        mov cx, 4
.l:
        push cx
        mov cl, 4
        rol bx, cl
        mov al, bl
        and al, 0x0F
        cmp al, 10
        jb .d
        add al, 7
.d:
        add al, '0'
        call putc
        pop cx
        loop .l
        pop dx
        pop cx
        pop bx
        pop ax
        ret

do_kill:
        push ax
        push bx
        push cx
        push dx
        push di
        push si
        mov si, [bp+144]
        call skip_sp
        mov al, [si]
        cmp al, '0'
        jb .usage
        cmp al, '9'
        ja .usage
        sub al, '0'
        xor ah, ah
        mov bx, ax
        inc si
        mov al, [si]
        cmp al, '0'
        jb .kchk
        cmp al, '9'
        ja .kchk
        sub al, '0'
        xor ah, ah
        push ax
        mov ax, bx
        mov cx, 10
        mul cx
        mov bx, ax
        pop ax
        add bx, ax
.kchk:
        cmp bx, MAXSER+1
        jb .usage
        cmp bx, NSLOTS
        jae .usage
        cmp byte [task_state+bx], 0
        je .notask
        cmp byte [ovl_owner], bl
        jne .kill_no_ovl
        mov byte [ovl_owner], 0xFF
.kill_no_ovl:
        mov byte [task_state+bx], 0
        mov byte [task_term+bx], 0      ; release the terminal id as well
        mov byte [task_app+bx], 0
        mov ax, bx
        mov cx, 12
        mul cx
        mov di, task_name
        add di, ax
        mov byte [di], 0
        mov si, s_killed
        call puts
        mov ax, bx
        call put_dec
        mov al, 10
        call putc
        jmp .ret
.notask:
        mov si, s_notask
        call puts
        jmp .ret
.usage:
        mov si, s_kill_usage
        call puts
.ret:
        pop si
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; 3270-style CGA console: title, rule, output area, COMMAND ===> , OIA
; =====================================================================

vid_put_rc:                     ; CH=row, CL=col, AL=char, BL=attr
        push ax
        push bx
        push cx
        push dx
        mov dh, ch
        mov dl, cl
        xor bh, bh
        mov ah, 2
        inc byte [crit]
        call bios_video
        dec byte [crit]
        xor bh, bh
        mov cx, 1
        mov ah, 9
        inc byte [crit]
        call bios_video
        dec byte [crit]
        pop dx
        pop cx
        pop bx
        pop ax
        ret

vid_puts_rc:                    ; CH=row, CL=col, SI=str, BL=attr
        push ax
        push cx
        push si
.vl:
        lodsb
        test al, al
        jz .vd
        mov [vp_col], cl
        call vid_put_rc
        inc byte [vp_col]
        mov cl, [vp_col]
        jmp .vl
.vd:
        pop si
        pop cx
        pop ax
        ret

vid_fill_row:                   ; CH=row, AL=char, BL=attr
        push ax
        push bx
        push cx
        push dx
        mov dh, ch
        xor dl, dl
        xor bh, bh
        mov ah, 2
        inc byte [crit]
        call bios_video
        dec byte [crit]
        xor bh, bh
        mov cx, 80
        mov ah, 9
        inc byte [crit]
        call bios_video
        dec byte [crit]
        pop dx
        pop cx
        pop bx
        pop ax
        ret

panel_scroll:
        mov ax, 0x0601                  ; scroll 1 line
        mov bh, 0x07
        mov ch, 2
        xor cl, cl
        mov dh, 22
        mov dl, 79
        inc byte [crit]
        call bios_video
        dec byte [crit]
        ret

; ---- panel scrollback -------------------------------------------------

panel_commit:                   ; append ph_cur (80 bytes) to the ring
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push ds
        push es
        mov ax, [ph_total]
        mov bx, ax
        and bx, PH_LINES-1
        mov ax, 80
        mul bx
        mov di, ax
        mov ax, PHIST_SEG
        mov es, ax
        mov si, ph_cur
        mov cx, 40
        rep movsw
        inc word [ph_total]
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, ph_cur
        mov al, ' '
        mov cx, 80
        rep stosb
        mov byte [ph_len], 0
        pop es
        pop ds
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

panel_getline:                  ; AX = logical line -> p_tmp (80 + NUL)
        push ax
        push bx
        push cx
        push si
        push di
        push ds
        push es
        mov bx, ax
        and bx, PH_LINES-1
        mov ax, 80
        mul bx
        mov si, ax
        mov ax, PHIST_SEG
        mov ds, ax
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, p_tmp
        mov cx, 40
        rep movsw
        mov byte [p_tmp+80], 0
        pop es
        pop ds
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        ret

panel_getcur:                   ; copy ph_cur -> p_tmp
        push ax
        push cx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov si, ph_cur
        mov di, p_tmp
        mov cx, 40
        rep movsw
        mov byte [p_tmp+80], 0
        pop es
        pop di
        pop si
        pop cx
        pop ax
        ret

panel_render:                   ; draw the last 21 lines ending view back
        push ax
        push bx
        push cx
        push si
        push di
        mov ax, [ph_total]
        sub ax, 20
        sub ax, [ph_view]
        jnc .sok
        xor ax, ax
.sok:
        mov [ph_start], ax
        mov byte [ph_row], 2
.rowloop:
        mov al, [ph_row]
        cmp al, 23
        jae .done
        mov al, [ph_row]
        sub al, 2
        xor ah, ah
        add ax, [ph_start]
        cmp ax, [ph_total]
        ja .blank
        je .current
        mov bx, [ph_total]
        sub bx, PH_LINES
        jnc .retok
        xor bx, bx
.retok:
        cmp ax, bx
        jb .blank
        call panel_getline
        jmp .emit
.current:
        cmp word [ph_view], 0
        jne .blank
        call panel_getcur
.emit:
        mov ch, [ph_row]
        xor cl, cl
        mov bl, 0x07
        mov si, p_tmp
        call vid_puts_rc
        jmp .next
.blank:
        mov ch, [ph_row]
        mov al, ' '
        mov bl, 0x07
        call vid_fill_row
.next:
        inc byte [ph_row]
        jmp .rowloop
.done:
        cmp word [ph_view], 0
        jne .atcmd
        mov ch, [prow]
        mov cl, [pcol]
        jmp .setcur
.atcmd:
        mov ch, 23
        mov cl, 13
.setcur:
        mov ah, 2
        xor bh, bh
        call bios_video
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        ret

; ANSI version of panel_render for a serial panel session
sp_render:
        push ax
        push bx
        push cx
        push si
        mov ax, [ph_total]
        sub ax, 20
        sub ax, [ph_view]
        jnc .sok
        xor ax, ax
.sok:
        mov [ph_start], ax
        mov byte [ph_row], 2
.rowloop:
        mov al, [ph_row]
        cmp al, 23
        jae .done
        mov al, [ph_row]
        sub al, 2
        xor ah, ah
        add ax, [ph_start]
        cmp ax, [ph_total]
        ja .blank
        je .current
        mov bx, [ph_total]
        sub bx, PH_LINES
        jnc .retok
        xor bx, bx
.retok:
        cmp ax, bx
        jb .blank
        call panel_getline
        jmp .emit
.current:
        cmp word [ph_view], 0
        jne .blank
        call panel_getcur
.emit:
        mov ch, [ph_row]
        mov cl, 1
        call sp_cup
        mov si, p_tmp
        mov cx, 79
.em:
        lodsb
        push cx
        call ser1
        pop cx
        loop .em
        mov si, sp_reset
        call sp_str
        mov si, sp_eol2
        call sp_str
        jmp .next
.blank:
        mov ch, [ph_row]
        mov cl, 1
        call sp_cup
        mov cx, 80
.bl:
        push cx
        mov al, ' '
        call ser1
        pop cx
        loop .bl
.next:
        inc byte [ph_row]
        jmp .rowloop
.done:
        cmp word [ph_view], 0
        jne .atcmd
        mov ch, [prow]
        mov cl, [pcol]
        jmp .setcur
.atcmd:
        mov ch, 23
        mov cl, 13
.setcur:
        call sp_cup
        pop si
        pop cx
        pop bx
        pop ax
        ret

panel_redraw:
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [ser_panel+bx], 0
        jne sp_render
        jmp panel_render

panel_page_up:
        mov ax, [ph_total]
        cmp ax, 21
        jb .done
        sub ax, 21
        mov bx, [ph_view]
        cmp bx, ax
        jae .done
        add bx, 20
        cmp bx, ax
        jbe .set
        mov bx, ax
.set:
        mov [ph_view], bx
        call panel_redraw
.done:
        ret

panel_page_down:
        cmp word [ph_view], 0
        je .done
        mov ax, [ph_view]
        sub ax, 20
        jnc .set
        xor ax, ax
.set:
        mov [ph_view], ax
        call panel_redraw
.done:
        ret

panel_live_if_hist:
        cmp word [ph_view], 0
        je .done
        mov word [ph_view], 0
        call panel_render
.done:
        ret

panel_putc:                     ; AL = char into the output area
        push di
        cmp al, 13
        je .r
        cmp al, 10
        jne .ch
        call panel_commit
        mov byte [pcol], 0
        inc byte [prow]
        cmp byte [prow], 23
        jb .r
        cmp word [ph_view], 0
        jne .noscr
        call panel_scroll
.noscr:
        mov byte [prow], 22
        jmp .r
.ch:
        cmp al, 32
        jb .r
        mov bl, [ph_len]
        cmp bl, 80
        jae .noapp
        mov di, ph_cur
        xor bh, bh
        add di, bx
        mov [di], al
        inc byte [ph_len]
.noapp:
        cmp word [ph_view], 0
        jne .r
        mov ch, [prow]
        mov cl, [pcol]
        mov bl, 0x07
        call vid_put_rc
        inc byte [pcol]
        cmp byte [pcol], 80
        jb .r
        call panel_commit
        mov byte [pcol], 0
        inc byte [prow]
        cmp byte [prow], 23
        jb .r
        call panel_scroll
        mov byte [prow], 22
.r:
        pop di
        ret

tb_ch:                          ; AL -> tbuf
        push bx
        push di
        mov bx, [tb_i]
        mov di, tbuf
        add di, bx
        mov [di], al
        inc bx
        mov [tb_i], bx
        pop di
        pop bx
        ret

tb_str:                         ; SI -> tbuf
        push ax
        push si
.ts:
        lodsb
        test al, al
        jz .td
        call tb_ch
        jmp .ts
.td:
        pop si
        pop ax
        ret

tb_bcd:                         ; AL = BCD -> two digits
        push ax
        push cx
        mov ah, al
        mov cl, 4
        shr al, cl
        add al, '0'
        call tb_ch
        mov al, ah
        and al, 0x0F
        add al, '0'
        call tb_ch
        pop cx
        pop ax
        ret

tb_dec3:                        ; AX -> three decimal digits (leading zeros)
        push ax
        push bx
        push dx
        mov bx, 100
        xor dx, dx
        div bx
        add al, '0'
        call tb_ch
        mov ax, dx
        mov bx, 10
        xor dx, dx
        div bx
        add al, '0'
        call tb_ch
        mov al, dl
        add al, '0'
        call tb_ch
        pop dx
        pop bx
        pop ax
        ret

bcd2bin:
        push bx
        mov bl, al
        shr al, 1
        shr al, 1
        shr al, 1
        shr al, 1
        mov bh, al
        mov al, bl
        and al, 0x0F
        mov bl, al
        mov al, bh
        mov bh, 10
        mul bh
        add al, bl
        pop bx
        ret

panel_title:
        mov ch, 0
        mov al, ' '
        mov bl, 0x1F
        call vid_fill_row
        mov ch, 0
        xor cl, cl
        mov bl, 0x1F
        mov si, s_title_left
        call vid_puts_rc
        mov ch, 0
        mov cl, 33
        mov bl, 0x1F
        mov si, s_title_center
        call vid_puts_rc
        call build_sysid
        mov ch, 0
        mov cl, 52
        mov bl, 0x1F
        mov si, tbuf
        call vid_puts_rc
        ret

build_sysid:
        mov word [tb_i], 0
        mov si, s_sysid
        call tb_str
        mov ah, 4
        int 0x1A
        cld
        mov al, cl
        call tb_bcd
        mov al, '.'
        call tb_ch
        mov al, dh
        call bcd2bin
        dec ax
        shl ax, 1
        mov bx, ax
        mov ax, [month_days+bx]
        push ax
        mov al, dl
        call bcd2bin
        xor ah, ah
        mov bx, ax
        pop ax
        add ax, bx
        call tb_dec3
        mov al, ' '
        call tb_ch
        mov al, ' '
        call tb_ch
        mov ah, 2
        int 0x1A
        cld
        mov al, ch
        call tb_bcd
        mov al, ':'
        call tb_ch
        mov al, cl
        call tb_bcd
        mov al, ':'
        call tb_ch
        mov al, dh
        call tb_bcd
        xor al, al
        call tb_ch
        ret

panel_rule:
        mov ch, 1
        mov al, '='
        mov bl, 0x1F
        call vid_fill_row
        ret

panel_cmdfield:
        mov ch, 23
        mov al, ' '
        mov bl, 0x07
        call vid_fill_row
        mov ch, 23
        xor cl, cl
        mov bl, 0x0A
        mov si, s_cmdprompt
        call vid_puts_rc
        mov ch, 23
        mov cl, 13
.pf:
        mov al, '_'
        mov bl, 0x09
        call vid_put_rc
        inc cl
        cmp cl, 80
        jb .pf
        ret

panel_oia_pos:                  ; CL = input column (0-based)
        push cx
        mov word [tb_i], 0
        mov ax, 23
        call tb_dec3
        mov al, '/'
        call tb_ch
        mov al, cl
        xor ah, ah
        inc ax
        call tb_dec3
        xor al, al
        call tb_ch
        mov ch, 24
        mov cl, 71
        mov bl, 0x09
        mov si, tbuf
        call vid_puts_rc
        pop cx
        ret

panel_oia:
        mov ch, 24
        mov al, ' '
        mov bl, 0x07
        call vid_fill_row
        mov ch, 24
        mov cl, 1
        mov bl, 0x0F
        mov si, s_oia1
        call vid_puts_rc
        mov ch, 24
        mov cl, 8
        mov bl, 0x0F
        mov si, s_oia2
        call vid_puts_rc
        mov cl, 13
        call panel_oia_pos
        ret

clr_screen:
        mov ax, 3
        cmp byte [mono], 0
        je .cs
        mov ax, 7
.cs:
        mov ah, 0
        call bios_video
        ret

panel_init:
        mov byte [prow], 2
        mov byte [pcol], 0
        mov word [ph_total], 0
        mov word [ph_view], 0
        mov byte [ph_len], 0
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, ph_cur
        mov al, ' '
        mov cx, 80
        rep stosb
        pop es
        mov ax, 0x0600                  ; clear the whole screen
        mov bh, 0x07
        xor cx, cx
        mov dx, 0x184F
        inc byte [crit]
        call bios_video
        dec byte [crit]
        call panel_title
        call panel_rule
        call panel_cmdfield
        call panel_oia
        mov ah, 2
        xor bh, bh
        mov dh, 23
        mov dl, 13
        call bios_video
        ret

panel_echo_cmd:                 ; echo [bp] into the output area
        push si
        mov si, bp
.ec:
        lodsb
        test al, al
        jz .ed
        call panel_putc
        jmp .ec
.ed:
        mov al, 10
        call panel_putc
        pop si
        ret

; =====================================================================
; Serial console panel (ANSI): same layout over COM1
; =====================================================================

sp_str:                         ; SI = zero-terminated bytes -> COM1
        push ax
        push si
.ss:
        lodsb
        test al, al
        jz .sd
        call ser1
        jmp .ss
.sd:
        pop si
        pop ax
        ret

slot_str:                       ; SI = string, BL = target serial slot
        push ax
        push si
.l:
        lodsb
        test al, al
        jz .d
        call tx_slot_append
        jmp .l
.d:
        pop si
        pop ax
        ret

sp_dec:                         ; AX -> decimal digits on COM1
        push ax
        push bx
        push cx
        push dx
        mov bx, 10
        xor cx, cx
.sd:
        xor dx, dx
        div bx
        push dx
        inc cx
        test ax, ax
        jnz .sd
.sdp:
        pop ax
        add al, '0'
        call ser1
        loop .sdp
        pop dx
        pop cx
        pop bx
        pop ax
        ret

sp_cup:                         ; CH=row, CL=col (1-based)
        push ax
        push cx
        test ch, ch
        jnz .r_ok
        mov ch, 1
.r_ok:
        test cl, cl
        jnz .c_ok
        mov cl, 1
.c_ok:
        mov al, 27
        call ser1
        mov al, '['
        call ser1
        mov al, ch
        xor ah, ah
        call sp_dec
        mov al, ';'
        call ser1
        mov al, cl
        xor ah, ah
        call sp_dec
        mov al, 'H'
        call ser1
        pop cx
        pop ax
        ret

sp_title:
        mov si, sp_blue
        call sp_str
        mov ch, 1
        mov cl, 1
        call sp_cup
        mov si, s_title_left
        call sp_str
        mov ch, 1
        mov cl, 33
        call sp_cup
        mov si, s_title_center
        call sp_str
        call build_sysid
        mov ch, 1
        mov cl, 53
        call sp_cup
        mov si, tbuf
        call sp_str
        mov si, sp_reset
        call sp_str
        ret

sp_rule:
        mov si, sp_blue
        call sp_str
        mov ch, 2
        mov cl, 1
        call sp_cup
        mov si, sp_rule80
        call sp_str
        mov si, sp_reset
        call sp_str
        ret

sp_cmdline:
        mov ch, 24
        mov cl, 1
        call sp_cup
        mov si, sp_green
        call sp_str
        mov si, s_cmdprompt
        call sp_str
        mov si, sp_blue
        call sp_str
        mov si, sp_fill67
        call sp_str
        mov si, sp_reset
        call sp_str
        ret

sp_oia_pos:                     ; CL = input column (0-based)
        push cx
        mov ch, 25
        mov cl, 72
        call sp_cup
        mov si, sp_blue
        call sp_str
        mov al, '0'
        call ser1
        mov al, '2'
        call ser1
        mov al, '3'
        call ser1
        mov al, '/'
        call ser1
        pop cx
        mov al, cl
        xor ah, ah
        inc ax
        call sp_dec
        mov si, sp_reset
        call sp_str
        ret

sp_oia:
        mov ch, 25
        mov cl, 1
        call sp_cup
        mov si, sp_white
        call sp_str
        mov si, s_oia1
        call sp_str
        mov ch, 25
        mov cl, 8
        call sp_cup
        mov si, s_oia2
        call sp_str
        mov si, sp_reset
        call sp_str
        ret

sp_prompt:
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [sp_cleared+bx], 0
        jne .nc
        mov si, sp_clear
        call sp_str
        mov bl, [cur_task]
        xor bh, bh
        mov byte [sp_cleared+bx], 1
.nc:
        mov si, sp_rgn
        call sp_str
        call sp_title
        call sp_rule
        call sp_cmdline
        call sp_oia
        mov cl, 13
        call sp_oia_pos
        mov ch, 24
        mov cl, 14
        call sp_cup
        call mux_flush_current
        ret

shell_serial_panel:        call pager_reset
        call sp_prompt
        mov di, bp
        mov bl, [cur_task]
        xor bh, bh
        mov byte [pin_len+bx], 0
.spr:
        push bp
        push cx
        push di
        call getline_char
        pop di
        pop cx
        pop bp
        test al, al
        jnz .spr_norm
        cmp ah, 0x49
        je .spr_pgup
        cmp ah, 0x51
        je .spr_pgdn
        jmp .spr
.spr_pgup:
        call panel_page_up
        jmp .spr
.spr_pgdn:
        call panel_page_down
        jmp .spr
.spr_norm:
        cmp al, 13
        je .spe
        cmp al, 10
        je .spe
        cmp al, 8
        je .spb
        cmp al, 127
        je .spb
        cmp al, 32
        jb .spr
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [pin_len+bx], 66
        jae .spr
        push ax
        mov ax, KERNEL_SEG
        mov es, ax
        pop ax
        cld
        stosb
        inc byte [pin_len+bx]
        push ax
        mov al, [pin_len+bx]
        add al, 12
        mov [pin_col+bx], al
        pop ax
        mov cl, [pin_col+bx]
        inc cl
        mov ch, 24
        call sp_cup
        call ser1
        mov bl, [cur_task]
        xor bh, bh
        mov cl, [pin_col+bx]
        call sp_oia_pos
        mov bl, [cur_task]
        xor bh, bh
        mov cl, [pin_col+bx]
        add cl, 2                       ; cursor sits after the typed char
        mov ch, 24
        call sp_cup
        jmp .spr
.spb:
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [pin_len+bx], 0
        je .spr
        dec byte [pin_len+bx]
        dec di
        mov al, [pin_len+bx]
        add al, 12
        mov [pin_col+bx], al            ; first free cell
        mov cl, al
        add cl, 2                       ; cell that held the deleted char
        mov ch, 24
        call sp_cup
        mov al, ' '
        call ser1                       ; erase the character
        mov bl, [cur_task]
        xor bh, bh
        mov cl, [pin_col+bx]
        add cl, 2
        mov ch, 24
        call sp_cup
        mov si, sp_blue
        call sp_str
        mov al, '_'
        call ser1
        mov si, sp_reset
        call sp_str
        mov bl, [cur_task]
        xor bh, bh
        mov cl, [pin_col+bx]
        call sp_oia_pos
        mov bl, [cur_task]
        xor bh, bh
        mov cl, [pin_col+bx]
        add cl, 2
        mov ch, 24
        call sp_cup
        jmp .spr
.spe:
        mov byte [di], 0
        mov ch, 23
        mov cl, 1
        call sp_cup
        mov si, sp_green
        call sp_str
        mov si, bp
.spe2:
        lodsb
        test al, al
        jz .spe3
        call ser1
        jmp .spe2
.spe3:
        mov si, sp_reset
        call sp_str
        mov al, 13
        call ser1
        mov al, 10
        call ser1
        call execute
        jmp shell

shell_panel:        call pager_reset
        call panel_title
        call panel_rule
        call panel_cmdfield
        call panel_oia
        mov ah, 2
        xor bh, bh
        mov dh, 23
        mov dl, 13
        call bios_video
        mov di, bp
        mov byte [pin_len], 0
.pr:
        push bp
        push cx
        push di
        call getline_char
        pop di
        pop cx
        pop bp
        cmp al, 13
        je .pe
        cmp al, 10
        je .pe
        cmp al, 8
        je .pb
        cmp al, 127
        je .pb
        cmp al, 32
        jb .pr
        cmp byte [pin_len], 66
        jae .pr
        push ax
        mov ax, KERNEL_SEG
        mov es, ax
        pop ax
        cld
        stosb
        inc byte [pin_len]
        push ax
        mov al, [pin_len]
        add al, 12
        mov [pin_col], al
        pop ax
        mov cl, [pin_col]
        mov ch, 23
        mov bl, 0x0F
        call vid_put_rc
        mov dh, 23
        mov dl, cl
        inc dl                          ; cursor sits after the typed char
        mov ah, 2
        xor bh, bh
        call bios_video
        mov cl, [pin_col]
        inc cl
        call panel_oia_pos
        jmp .pr
.pb:
        cmp byte [pin_len], 0
        je .pr
        dec byte [pin_len]
        dec di
        mov al, [pin_len]
        add al, 12
        mov [pin_col], al               ; first free cell
        inc al                          ; cell that held the deleted char
        mov cl, al
        mov ch, 23
        mov al, ' '
        mov bl, 0x0F
        call vid_put_rc                 ; erase the character
        mov cl, [pin_col]
        inc cl
        mov ch, 23
        mov al, '_'
        mov bl, 0x09
        call vid_put_rc                 ; draw the cursor cell
        mov dh, 23
        mov dl, [pin_col]
        inc dl
        mov ah, 2
        xor bh, bh
        call bios_video
        mov cl, [pin_col]
        inc cl
        call panel_oia_pos
        jmp .pr
.pe:
        mov byte [di], 0
        mov byte [pcol], 0
        ; move to a fresh output line
        inc byte [prow]
        cmp byte [prow], 23
        jb .pe2
        call panel_commit
        call panel_scroll
        mov byte [prow], 22
.pe2:
        call panel_echo_cmd
        call execute
        jmp shell

; =====================================================================
; UMIX BASIC - line-numbered program, integer expressions
; =====================================================================

read_line_plain:                ; DI = buffer, visible echo
        push di
        xor cx, cx
.l:
        call getline_char
        cmp al, 13
        je .d
        cmp al, 10
        je .d
        cmp al, 8
        je .b
        cmp al, 127
        je .b
        cmp al, 32
        jb .l
        cmp cx, 30
        jae .l
        stosb
        inc cx
        call putc
        jmp .l
.b:
        test cx, cx
        jz .l
        dec cx
        dec di
        mov al, 8
        call putc
        mov al, ' '
        call putc
        mov al, 8
        call putc
        jmp .l
.d:
        mov al, 10
        call putc
        mov byte [di], 0
        pop di
        ret

read_secret:                    ; DI = buffer, '*' echo
        push di
        xor cx, cx
.l:
        call getline_char
        cmp al, 13
        je .d
        cmp al, 10
        je .d
        cmp al, 8
        je .b
        cmp al, 127
        je .b
        cmp al, 32
        jb .l
        cmp cx, 30
        jae .l
        stosb
        inc cx
        mov al, '*'
        call putc
        jmp .l
.b:
        test cx, cx
        jz .l
        dec cx
        dec di
        mov al, 8
        call putc
        mov al, ' '
        call putc
        mov al, 8
        call putc
        jmp .l
.d:
        mov al, 10
        call putc
        mov byte [di], 0
        pop di
        ret

upcase_str:                    ; SI = NUL-terminated buffer
        push si
        push ax
.u:
        mov al, [si]
        test al, al
        jz .ud
        cmp al, 'a'
        jb .un
        cmp al, 'z'
        ja .un
        sub al, 32
        mov [si], al
.un:
        inc si
        jmp .u
.ud:
        pop ax
        pop si
        ret

user_ptr:                       ; DI = serial_user + cur_task*16
        push ax
        push cx
        mov al, [cur_task]
        xor ah, ah
        mov cl, 4
        shl ax, cl
        mov di, serial_user
        add di, ax
        pop cx
        pop ax
        ret

user_name_copy:                 ; DI = record -> AX = uname_safe (name only)
        push bx
        push cx
        push si
        push di
        mov si, di
        mov di, uname_safe
        mov cx, 8
.uc_l:
        mov al, [si]
        test al, al
        jz .uc_d
        mov [di], al
        inc si
        inc di
        dec cx
        jnz .uc_l
.uc_d:
        mov byte [di], 0
        mov ax, uname_safe
        pop di
        pop si
        pop cx
        pop bx
        ret

user_ptr_slot:                  ; AL = slot -> DI = serial_user + slot*16
        push ax
        push cx
        xor ah, ah
        mov cl, 4
        shl ax, cl
        mov di, serial_user
        add di, ax
        pop cx
        pop ax
        ret

login_user_ptr:                 ; DI = login_user + cur_task*32
        push ax
        push cx
        mov al, [cur_task]
        xor ah, ah
        mov cl, 5
        shl ax, cl
        mov di, login_user
        add di, ax
        pop cx
        pop ax
        ret

login_pass_ptr:                 ; DI = login_pass + cur_task*32
        push ax
        push cx
        mov al, [cur_task]
        xor ah, ah
        mov cl, 5
        shl ax, cl
        mov di, login_pass
        add di, ax
        pop cx
        pop ax
        ret

MAXUSERS        equ 8
USER_ENT        equ 20

user_index_ptr:                 ; AL = index -> DI = user_tab + index*20
        push ax
        push cx
        xor ah, ah
        mov cl, USER_ENT
        mul cl
        mov di, user_tab
        add di, ax
        pop cx
        pop ax
        ret

user_find:                      ; SI -> name token -> AL = index, or FFh
        push bx
        push cx
        push dx
        push si
        push di
        xor bl, bl
.uf_l:
        cmp bl, [user_cnt]
        jae .uf_none
        mov al, bl
        call user_index_ptr
        push si
.uf_c:
        mov al, [si]
        cmp al, ' '
        je .uf_end
        test al, al
        jz .uf_end
        call upcase
        mov ah, al
        mov al, [di]
        call upcase
        cmp al, ah
        jne .uf_miss
        inc si
        inc di
        jmp .uf_c
.uf_end:
        cmp byte [di], 0
        jne .uf_miss
        pop si
        mov al, bl
        jmp .uf_done
.uf_miss:
        pop si
        inc bl
        jmp .uf_l
.uf_none:
        mov al, 0FFh
.uf_done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        ret

skip_token:                     ; SI advances to space/NUL
        mov al, [si]
        test al, al
        jz .st_done
        cmp al, ' '
        je .st_done
        inc si
        jmp skip_token
.st_done:
        ret

tok_eq:                         ; SI token vs DI NUL string -> AL=1 if equal
        push si
        push di
        push bx
.te_l:
        mov al, [si]
        cmp al, ' '
        je .te_end
        test al, al
        jz .te_end
        call upcase
        mov bl, al
        mov al, [di]
        call upcase
        cmp al, bl
        jne .te_no
        inc si
        inc di
        jmp .te_l
.te_end:
        cmp byte [di], 0
        jne .te_no
        pop bx
        pop di
        pop si
        mov al, 1
        ret
.te_no:
        pop bx
        pop di
        pop si
        xor al, al
        ret

copy_tok:                       ; SI token -> DI buffer; CF if >8 chars
        push ax
        push cx
        push di
        xor cx, cx
.ct_l:
        mov al, [si]
        cmp al, ' '
        je .ct_e
        test al, al
        jz .ct_e
        cmp cx, 8
        jae .ct_long
        call upcase
        stosb
        inc cx
        inc si
        jmp .ct_l
.ct_e:
        xor al, al
        stosb
        pop di
        pop cx
        pop ax
        clc
        ret
.ct_long:
        pop di
        pop cx
        pop ax
        stc
        ret

user_list:                      ; print "USERS: name name ..."
        push ax
        push bx
        push cx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov si, s_users_hdr
        call sys_begin
        call puts
        xor bl, bl
.ul_l:
        cmp bl, [user_cnt]
        jae .ul_done
        mov al, bl
        call user_index_ptr
        cmp byte [di], 0
        je .ul_next
        call user_name_copy
        mov si, ax
        call puts
        mov al, ' '
        call putc
.ul_next:
        inc bl
        jmp .ul_l
.ul_done:
        mov al, 10
        call putc
        pop es
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        ret

do_users:
        call check_elev
        cmp al, 0
        jne .gated
        call user_list
        ret
.gated:
        cmp al, 1
        je .conly
        mov si, s_priv_req
        call sys_begin
        call puts
        ret
.conly:
        mov si, s_user_conly
        call sys_begin
        call puts
        ret

do_user:                        ; console user management
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        call check_elev
        cmp al, 0
        je .console
        cmp al, 1
        je .gconly
        mov si, s_priv_req
        call sys_begin
        call puts
        jmp .ret
.gconly:
        mov si, s_user_conly
        call sys_begin
        call puts
        jmp .ret
.console:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .haveargs
        jmp .usage
.haveargs:
        mov [user_tok], si
        mov di, s_user_add
        call tok_eq
        cmp al, 1
        je .add
        mov si, [user_tok]
        mov di, s_user_del
        call tok_eq
        cmp al, 1
        je .del
        mov si, [user_tok]
        mov di, s_user_passcmd
        call tok_eq
        cmp al, 1
        je .pass
        mov si, [user_tok]
        mov di, s_user_list
        call tok_eq
        cmp al, 1
        je .list
        mov si, [user_tok]
        mov di, s_user_savecmd
        call tok_eq
        cmp al, 1
        je .save
        mov si, [user_tok]
        mov di, s_user_resetcmd
        call tok_eq
        cmp al, 1
        je .reset
        jmp .usage

.add:
        call parse_name
        jc .toolong
        test al, al
        jz .usage
        call parse_pass
        jc .toolong
        test al, al
        jz .usage
        cmp byte [user_cnt], MAXUSERS
        jae .full
        mov si, uname
        call user_find
        cmp al, 0FFh
        jne .exists
        mov al, [user_cnt]
        call user_index_ptr
        mov si, uname
        mov cx, 5
        rep movsw
        mov si, upass
        mov cx, 5
        rep movsw
        inc byte [user_cnt]
        mov si, s_user_added
        call sys_begin
        call puts
        mov si, uname
        call puts
        mov al, 10
        call putc
        call user_save_status
        jmp .ret

.del:
        mov si, [user_tok]
        call skip_token
        call skip_sp
        cmp byte [si], 0
        je .usage
        mov di, uname
        push di
        mov cx, 5
        xor ax, ax
        rep stosw
        pop di
        call copy_tok
        jc .toolong
        cmp byte [uname], 0
        je .usage
        mov si, uname
        call user_find
        cmp al, 0FFh
        je .nouser
        mov bl, al
        cmp byte [user_cnt], 1
        jbe .last
        mov al, [user_cnt]
        sub al, bl
        dec al
        xor ah, ah
        mov cl, USER_ENT
        mul cl
        mov cx, ax
        mov al, bl
        inc al
        call user_index_ptr
        mov si, di
        sub di, USER_ENT
        rep movsb
        dec byte [user_cnt]
        mov al, [user_cnt]
        call user_index_ptr
        mov cx, 10
        xor ax, ax
        rep stosw
        mov si, s_user_deleted
        call sys_begin
        call puts
        mov si, uname
        call puts
        mov al, 10
        call putc
        call user_save_status
        jmp .ret

.pass:
        call parse_name
        jc .toolong
        test al, al
        jz .usage
        call parse_pass
        jc .toolong
        test al, al
        jz .usage
        mov si, uname
        call user_find
        cmp al, 0FFh
        je .nouser
        call user_index_ptr
        add di, 10
        mov si, upass
        mov cx, 5
        rep movsw
        mov si, s_user_pw
        call sys_begin
        call puts
        mov si, uname
        call puts
        mov al, 10
        call putc
        call user_save_status
        jmp .ret

.list:
        call user_list
        jmp .ret
.save:
        call user_save_status
        jmp .ret
.reset:
        mov si, user_defaults
        mov di, user_tab
        mov cx, 30
        rep movsw
        mov byte [user_cnt], 3
        mov si, s_user_resetmsg
        call sys_begin
        call puts
        call user_save_status
        jmp .ret

.usage:
        mov si, s_user_usage
        call sys_begin
        call puts
        jmp .ret
.full:
        mov si, s_user_full
        call sys_begin
        call puts
        jmp .ret
.exists:
        mov si, s_user_exists
        call sys_begin
        call puts
        jmp .ret
.nouser:
        mov si, s_user_nouser
        call sys_begin
        call puts
        jmp .ret
.last:
        mov si, s_user_last
        call sys_begin
        call puts
        jmp .ret
.toolong:
        mov si, s_user_toolong
        call sys_begin
        call puts
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; parse name token after the subcommand into uname (SI advances)
parse_name:
        mov si, [user_tok]
        call skip_token
        call skip_sp
        cmp byte [si], 0
        je .pn_usage
        mov di, uname
        push di
        mov cx, 5
        xor ax, ax
        rep stosw
        pop di
        call copy_tok
        jc .pn_long
        cmp byte [uname], 0
        je .pn_usage
        mov al, 1
        clc
        ret
.pn_usage:
        xor al, al
        clc
        ret
.pn_long:
        stc
        ret

; parse password token after the name into upass (SI advances)
parse_pass:
        call skip_sp
        cmp byte [si], 0
        je .pp_usage
        mov di, upass
        push di
        mov cx, 5
        xor ax, ax
        rep stosw
        pop di
        call copy_tok
        jc .pp_long
        cmp byte [upass], 0
        je .pp_usage
        mov al, 1
        clc
        ret
.pp_usage:
        xor al, al
        clc
        ret
.pp_long:
        stc
        ret

USER_LBA        equ 700         ; reserved sector on the boot floppy

floppy_rw:                      ; AL=2 read / 3 write, USER_LBA -> ufsec; CF error
        push ax
        push bx
        push cx
        push dx
        push di
        push es
        mov di, ax
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, ufsec
        mov byte [fl_spt], 9            ; 360 KB image geometry (as boot.asm)
        mov byte [fl_heads], 2
        mov ax, USER_LBA
        xor dx, dx
        mov cl, [fl_spt]
        xor ch, ch
        div cx
        inc dl
        mov [fl_sec], dl
        xor dx, dx
        mov cl, [fl_heads]
        xor ch, ch
        div cx
        mov [fl_cyl], ax
        mov [fl_head], dl
        mov ax, [fl_cyl]
        mov bx, ax
        shr ax, 1
        shr ax, 1
        and al, 0xC0
        or al, [fl_sec]
        mov cl, al
        mov ch, bl
        mov dh, [fl_head]
        mov dl, [boot_dl]
        mov bx, ufsec                   ; restore DMA buffer offset (BX was reused)
        mov ax, di
        mov ah, al
        mov al, 1
        inc byte [crit]
        int 0x13
        dec byte [crit]
        jc .fail
        clc
        jmp .ret
.fail:
        stc
.ret:
        pop es
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

users_validate:                ; DX=bytes in ufbuf -> CF invalid, else AL=count
        cmp dx, 6
        jb .bad
        cmp byte [ufbuf], 'U'
        jne .bad
        cmp byte [ufbuf+1], 'M'
        jne .bad
        cmp byte [ufbuf+2], 'X'
        jne .bad
        cmp byte [ufbuf+3], 'U'
        jne .bad
        cmp byte [ufbuf+4], 1
        jne .bad
        mov al, [ufbuf+5]
        cmp al, MAXUSERS
        ja .bad
        mov bl, al
        xor bh, bh
        push ax
        push dx
        mov ax, 20
        mul bx
        add ax, 6
        pop dx
        cmp dx, ax
        pop ax
        jb .bad
        clc
        ret
.bad:
        stc
        ret

users_apply:                   ; copy the ufbuf image into the table
        mov al, [ufbuf+5]
        mov [user_cnt], al
        mov bl, al
        xor bh, bh
        mov ax, 20
        mul bx
        mov cx, ax
        mov si, ufbuf+6
        mov di, user_tab
        rep movsb
        ; The on-disk image may carry a name that fills its whole 10-byte
        ; field.  Force a terminator at the 8-byte account-name limit so no
        ; reader (API or console) can run on into the password at +10.
        mov cl, [user_cnt]
        xor ch, ch
        mov di, user_tab+8
.ua_l:
        test cx, cx
        jz .ua_d
        mov word [di], 0               ; name[8..9] = 0 (password starts at +10)
        add di, USER_ENT
        dec cx
        jmp .ua_l
.ua_d:
        ; clear the unused tail: a short file must not expose built-in names
        mov al, [user_cnt]
        mov bl, al
        xor bh, bh
        mov ax, USER_ENT
        mul bx
        mov di, user_tab
        add di, ax
        mov cx, MAXUSERS
        mov bl, [user_cnt]
        xor bh, bh
        sub cx, bx
        mov ax, USER_ENT
        mul cx
        mov cx, ax
        xor al, al
        rep stosb
        ret

users_load:                     ; boot-floppy sector first, then C:\USERS.DAT
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov al, 2                     ; try the boot floppy first, whatever we booted from
        call floppy_rw
        jc .file
        xor bx, bx
        xor cx, cx
.cs:
        xor ah, ah
        mov al, [ufsec+bx]
        add cx, ax
        inc bx
        cmp bx, 166
        jb .cs
        cmp cx, [ufsec+166]
        jne .file
        mov si, ufsec
        mov di, ufbuf
        mov cx, 83
        rep movsw
        mov dx, 166
        call users_validate
        jc .file
        call users_apply
        jmp .done
.file:
        cmp byte [fs_ok], 0
        je .done
        mov di, ufbuf
        xor ax, ax
        mov cx, 83
        rep stosw
        mov si, s_users_file
        mov di, namebuf
        mov cx, 11
        rep movsb
        call find_file
        jc .done
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, ufbuf
        mov cx, 166
        call load_file
        jc .done
        call users_validate
        jc .done
        call users_apply
.done:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

users_save:                    ; floppy sector + C: file; AL status
        push bx
        push cx
        push dx
        push si
        push di
        push es
        cmp byte [write_ok], 0
        je .nw
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, ufbuf
        xor ax, ax
        mov cx, 83
        rep stosw
        mov byte [ufbuf], 'U'
        mov byte [ufbuf+1], 'M'
        mov byte [ufbuf+2], 'X'
        mov byte [ufbuf+3], 'U'
        mov byte [ufbuf+4], 1
        mov al, [user_cnt]
        mov [ufbuf+5], al
        mov bl, al
        xor bh, bh
        mov ax, 20
        mul bx
        mov cx, ax
        mov si, user_tab
        mov di, ufbuf+6
        rep movsb
        mov byte [usv_fl], 0
        mov byte [usv_file], 0
        ; never write the users sector to a swapped-in FAT volume on the
        ; boot drive - it would land in the middle of the data area
        cmp byte [fs_ok], 0
        je .uf_ok
        cmp byte [disk_ram], 0
        jne .uf_ok
        mov al, [disk_dl]
        cmp al, [boot_dl]
        jne .uf_ok
        jmp .nof
.uf_ok:
        cmp byte [boot_dl], 2
        jae .nof
        mov di, ufsec
        xor ax, ax
        mov cx, 256
        rep stosw
        mov si, ufbuf
        mov di, ufsec
        mov cx, 83
        rep movsw
        xor bx, bx
        xor cx, cx
.cs2:
        xor ah, ah
        mov al, [ufsec+bx]
        add cx, ax
        inc bx
        cmp bx, 166
        jb .cs2
        mov [ufsec+166], cx
        mov al, 3
        call floppy_rw
        jc .nof
        mov byte [usv_fl], 1
.nof:
        cmp byte [fs_ok], 0
        je .nofile
        mov si, s_users_file
        mov di, namebuf
        mov cx, 11
        rep movsb
        mov word [sv_src], ufbuf
        mov word [sv_src_seg], KERNEL_SEG
        mov word [sv_size], 166
        call write_file
        jc .nofile
        mov byte [usv_file], 1
.nofile:
        cmp byte [usv_fl], 0
        je .tryfile
        xor al, al
        jmp .ret
.tryfile:
        cmp byte [usv_file], 0
        je .nosave
        mov al, 8
        jmp .ret
.nosave:
        cmp byte [boot_dl], 2
        jae .nofs
        mov al, 7
        jmp .ret
.nofs:
        mov al, 2
        jmp .ret
.nw:
        mov al, 1
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        ret

user_save_status:
        push ax
        push si
        call users_save
        cmp al, 0
        je .ok
        cmp al, 1
        je .nw
        cmp al, 2
        je .nf
        cmp al, 4
        je .e1
        cmp al, 5
        je .e2
        cmp al, 6
        je .e3
        cmp al, 7
        je .e4
        cmp al, 8
        je .e5
        mov si, s_user_saveerr
        jmp .p
.e1:
        mov si, s_user_nocl
        jmp .p
.e2:
        mov si, s_user_io
        jmp .p
.e3:
        mov si, s_user_dirfull
        jmp .p
.e4:
        mov si, s_user_flerr
        jmp .p
.e5:
        mov si, s_user_filesaved
.ok:
        mov si, s_user_saved
        jmp .p
.nw:
        mov si, s_user_nosave
        jmp .p
.nf:
        mov si, s_user_nofs
.p:
        call puts
        pop si
        pop ax
        ret

serial_login:
        call user_ptr
        mov byte [di], 0
        mov si, s_login_banner
        call puts
.try:
        mov si, s_user_prompt
        call puts
        call login_user_ptr
        call read_line_plain
        call login_user_ptr
        mov si, di
        call upcase_str
        mov si, di
        mov di, s_chat_user
        call streq
        cmp al, 1
        je .chat
        mov si, s_pass_prompt
        call puts
        call login_pass_ptr
        call read_secret
        call login_pass_ptr
        mov si, di
        call upcase_str
        call login_user_ptr
        mov si, di
        call user_find
        cmp al, 0FFh
        je .bad
        mov bl, al
        call login_pass_ptr
        mov si, di
        mov al, bl
        call user_index_ptr
        add di, 10
        call streq
        cmp al, 1
        je .ok
        jmp .bad
.bad:
        mov si, s_login_bad
        call puts
        jmp .try
.chat:
        call chat_enter
        jmp .try
.ok:
        ; publish the logged-on name for WHO/WHOAMI/PS
        call login_user_ptr
        mov si, di
        call user_ptr
        mov cx, 15
.ocl:
        lodsb
        stosb
        test al, al
        jz .ocd
        loop .ocl
.ocd:
        mov byte [di], 0
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        mov byte [sp_cleared+si], 0
        mov si, s_login_ok
        call puts
        mov si, s_log_logon
        call log_user_event
        ret

do_logoff:
        mov al, [cur_task]
        cmp al, 1
        jb .no
        cmp al, MAXSER
        ja .no
        mov si, s_log_logoff
        call log_user_event
        call serial_login
        ret
.no:
        mov si, s_logoff_no
        call puts
        ret

; =====================================================================
; CHAT ROOM - shared line chat between serial sessions (mux demo)
; Entered by typing CHAT at the USERID: prompt; /QUIT returns to logon.
; =====================================================================

chat_nick_ptr:                  ; -> DI = chat_nick + cur_task*10
        mov al, [cur_task]
chat_nick_slot_ptr:             ; AL = slot -> DI = chat_nick + slot*10
        push ax
        push cx
        xor ah, ah
        mov cl, 10
        mul cl
        mov di, chat_nick
        add di, ax
        pop cx
        pop ax
        ret

chat_is_sp:                     ; AL=1 if cur_task is a serial panel session
        push bx
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [task_out+bx], 1
        jne .no
        cmp byte [ser_panel+bx], 0
        je .no
        mov al, 1
        pop bx
        ret
.no:
        xor al, al
        pop bx
        ret

; print one chat line in the serial panel output area (cur_task's panel)
chat_panel_line_current:
        push ax
        push bx
        push cx
        push si
        mov bl, [cur_task]
        xor bh, bh
        mov al, [chat_row+bx]
        mov ch, al
        mov cl, 1
        call sp_cup
        mov si, sp_reset
        call sp_str
        pop si
        push si
        call sp_str
        mov al, 13
        call ser1
        mov al, 10
        call ser1
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [chat_row+bx], 23
        jae .max
        inc byte [chat_row+bx]
        jmp .done
.max:
        mov byte [chat_row+bx], 23
.done:
        pop si
        pop cx
        pop bx
        pop ax
        ret

chat_users_row:                 ; panel row 3: the room's nicknames
        push ax
        push bx
        push si
        push di
        call chat_is_sp
        cmp al, 1
        jne .ur_done
        mov ch, 3
        mov cl, 1
        call sp_cup
        mov si, sp_eol
        call sp_str
        mov si, sp_blue
        call sp_str
        mov si, s_users_pfx
        call sp_str
        xor bx, bx
.ur_loop:
        cmp byte [chat_on+bx], 0
        je .ur_next
        push bx
        push di
        mov al, bl
        call chat_nick_slot_ptr
        mov si, di
        pop di
        pop bx
        call sp_str
        mov al, ' '
        call ser1
.ur_next:
        inc bx
        cmp bx, MAXSER+1
        jb .ur_loop
.ur_done:
        pop di
        pop si
        pop bx
        pop ax
        ret

chat_redraw_current:
        push ax
        push bx
        push cx
        push si
        call chat_is_sp
        cmp al, 1
        jne .done
        mov ch, 24
        mov cl, 1
        call sp_cup
        mov si, sp_eol
        call sp_str
        mov si, sp_blue
        call sp_str
        call chat_nick_ptr
        mov si, di
        call sp_str
        mov al, '>'
        call ser1
        mov al, ' '
        call ser1
        mov al, [cur_task]
        xor ah, ah
        mov bx, 160
        mul bx
        add ax, shellbuf
        mov si, ax
        mov bl, [cur_task]
        xor bh, bh
        mov cl, [chat_ilen+bx]
        xor ch, ch
        jcxz .noin
.cp:
        lodsb
        call ser1
        loop .cp
.noin:
        mov si, sp_reset
        call sp_str
.done:
        pop si
        pop cx
        pop bx
        pop ax
        ret

; print a line on the current session, honouring panel mode
chat_say:
        push ax
        push si
        call chat_is_sp
        cmp al, 1
        je .pan
        call puts
        mov al, 10
        call putc
        jmp .done
.pan:
        call chat_panel_line_current
.done:
        pop si
        pop ax
        ret

; force a blocked chat reader to wake: push a CR into its RX ring
chat_wake_slot:                 ; AL = slot
        push ax
        push bx
        push cx
        push si
        pushf
        cli
        mov bl, al
        xor bh, bh
        cmp byte [task_in+bx], 1
        jne .wk_done
        mov al, [rx_tail+bx]
        mov ah, al
        inc ah
        and ah, MUX_RX_SIZE-1
        cmp ah, [rx_head+bx]
        je .wk_done
        mov cl, 8
        mov ax, bx
        shl ax, cl
        mov si, rx_buf
        add si, ax
        mov al, [rx_tail+bx]
        xor ah, ah
        add si, ax
        mov byte [si], 13
        inc byte [rx_tail+bx]
        and byte [rx_tail+bx], MUX_RX_SIZE-1
.wk_done:
        popf
        pop si
        pop cx
        pop bx
        pop ax
        ret

; deliver SI=line to AL=slot (temporarily make that slot current so the
; existing console/panel/framed routing applies to it)
chat_send_to_slot:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov bl, [cur_task]
        mov [chat_saved], bl
        mov [cur_task], al
        call chat_is_sp
        cmp al, 1
        je .pan
        call puts
        mov al, 10
        call putc
        jmp .done
.pan:
        call chat_panel_line_current
        call chat_redraw_current
.done:
        mov al, [chat_saved]
        mov [cur_task], al
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

chat_echo_char:                 ; AL=char at the input position
        push ax
        push bx
        call chat_is_sp
        cmp al, 1
        je .ser
        pop bx
        pop ax
        call putc
        ret
.ser:
        pop bx
        pop ax
        call ser1
        ret

chat_echo_bs:
        push ax
        mov al, 8
        call chat_echo_char
        mov al, ' '
        call chat_echo_char
        mov al, 8
        call chat_echo_char
        pop ax
        ret

; compose "NICK> <buffer>" into chat_linebuf (cur_task)
chat_compose_input:
        push ax
        push bx
        push cx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, chat_linebuf
        push di
        call chat_nick_ptr
        mov si, di
        pop di
.c1:
        lodsb
        test al, al
        jz .c2
        stosb
        jmp .c1
.c2:
        mov al, '>'
        stosb
        mov al, ' '
        stosb
        mov al, [cur_task]
        xor ah, ah
        mov bx, 160
        mul bx
        add ax, shellbuf
        mov si, ax
.c3:
        lodsb
        test al, al
        jz .c4
        stosb
        jmp .c3
.c4:
        xor al, al
        stosb
        pop es
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        ret

; input: SI=label (may be empty), DI=buffer -> returns CX=length
chat_read_prompt:
        push ax
        push bx
        push di
        push si
        call chat_is_sp
        cmp al, 1
        je .pan
        pop si
        push si
        call puts
        jmp .read
.pan:
        pop si
        push si
        cmp byte [si], 0
        je .read
        mov ch, 24
        mov cl, 1
        call sp_cup
        mov si, sp_eol
        call sp_str
        mov si, sp_blue
        call sp_str
        pop si
        push si
        call sp_str
        mov si, sp_reset
        call sp_str
.read:
        pop si
        xor cx, cx
        mov bl, [cur_task]
        xor bh, bh
        mov byte [chat_ilen+bx], 0
.rl:
        call getline_char
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [chat_kick+bx], 0
        jne .kicked
        cmp al, 13
        je .rd
        cmp al, 10
        je .rd
        cmp al, 8
        je .rb
        cmp al, 127
        je .rb
        cmp al, 32
        jb .rl
        cmp cx, 50
        jae .rl
        stosb
        inc cx
        mov bl, [cur_task]
        xor bh, bh
        mov [chat_ilen+bx], cl
        call chat_echo_char
        jmp .rl
.rb:
        test cx, cx
        jz .rl
        dec cx
        dec di
        mov bl, [cur_task]
        xor bh, bh
        mov [chat_ilen+bx], cl
        call chat_echo_bs
        jmp .rl
.kicked:
        mov byte [chat_kick+bx], 0
        mov byte [chat_kicked+bx], 1
        mov byte [di], 0
        xor cx, cx
        mov byte [chat_ilen+bx], 0
        call chat_redraw_current
        pop di
        pop bx
        pop ax
        ret
.rd:
        mov byte [di], 0
        call chat_is_sp
        cmp al, 1
        jne .rd2
        cmp byte [chat_echo_on], 0
        je .rd2
        call chat_compose_input
        mov si, chat_linebuf
        call chat_panel_line_current
.rd2:
        call chat_is_sp
        cmp al, 1
        je .rd3
        mov al, 10
        call putc
.rd3:
        mov bl, [cur_task]
        xor bh, bh
        mov byte [chat_ilen+bx], 0
        call chat_redraw_current
        pop di
        pop bx
        pop ax
        ret

; find the chat slot whose nickname matches the token at SI (up to space)
; -> AL = slot, or 0FFh
chat_find_nick:
        push bx
        push cx
        push dx
        push si
        push di
        mov byte [chat_i], 0
.cfn_l:
        mov al, [chat_i]
        cmp al, MAXSER
        ja .cfn_none
        mov bl, al
        xor bh, bh
        cmp byte [chat_on+bx], 0
        je .cfn_next
        mov al, [chat_i]
        call chat_nick_slot_ptr
        push si
.cfn_c:
        mov al, [si]
        cmp al, ' '
        je .cfn_e
        test al, al
        jz .cfn_e
        call upcase
        mov bl, al
        mov al, [di]
        call upcase
        cmp al, bl
        jne .cfn_m
        inc si
        inc di
        jmp .cfn_c
.cfn_e:
        cmp byte [di], 0
        jne .cfn_m
        pop si
        mov al, [chat_i]
        jmp .cfn_done
.cfn_m:
        pop si
.cfn_next:
        inc byte [chat_i]
        jmp .cfn_l
.cfn_none:
        mov al, 0FFh
.cfn_done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        ret

chat_clear_area:                ; blank panel output rows 3..23
        push ax
        push cx
        push si
        mov ch, 3
.clr:
        mov cl, 1
        call sp_cup
        mov si, sp_eol
        call sp_str
        inc ch
        cmp ch, 24
        jb .clr
        pop si
        pop cx
        pop ax
        ret

chat_nick_ok:                   ; AL=1 if 2+ alphanumeric chars
        push bx
        push si
        mov bx, 0
.nk_len:
        cmp byte [si+bx], 0
        je .nk_end
        inc bx
        jmp .nk_len
.nk_end:
        cmp bx, 2
        jb .nk_no
        xor bx, bx
.nk_chk:
        mov al, [si+bx]
        test al, al
        jz .nk_y
        cmp al, '0'
        jb .nk_alpha
        cmp al, '9'
        jbe .nk_nx
.nk_alpha:
        cmp al, 'A'
        jb .nk_no
        cmp al, 'Z'
        jbe .nk_nx
        cmp al, 'a'
        jb .nk_no
        cmp al, 'z'
        ja .nk_no
.nk_nx:
        inc bx
        jmp .nk_chk
.nk_y:
        mov al, 1
        pop si
        pop bx
        ret
.nk_no:
        xor al, al
        pop si
        pop bx
        ret

chat_enter:                     ; serial/CGA session enters the chat room
        push ax
        push bx
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        cmp byte [chat_enabled], 0
        je .ce_closed
        mov bl, [cur_task]
        xor bh, bh
        mov byte [pager_bypass+bx], 1   ; live chat is never paged
        ; Full-screen chat is disabled until CHAT.SYS exists: the 64-byte
        ; per-session TX ring cannot carry the ANSI sequences reliably.
        jmp .ce_nopan
.ce_panelq:
        call chat_is_sp
        cmp al, 1
        jne .ce_nopan
        call sp_prompt
        call chat_clear_area
        mov bl, [cur_task]
        xor bh, bh
        mov byte [chat_row+bx], 5
        call chat_users_row
        mov si, sp_chat_rgn
        call sp_str
        jmp .ce_nosyso
.ce_nopan:
        mov si, s_chat_box1
        call chat_say
        mov si, s_chat_box2
        call chat_say
        mov si, s_chat_box3
        call chat_say
        mov si, s_chat_sysline
        call chat_say
        mov si, cpu_line
        call chat_say
        mov si, s_chat_osline
        call chat_say
        mov si, s_chat_tech1
        call chat_say
        mov si, s_chat_box4
        call chat_say
        mov si, s_chat_box5
        call chat_say
        mov si, s_chat_box6
        call chat_say
        cmp byte [cur_task], 0
        jne .ce_nosyso
        mov si, s_chat_syso_line
        call chat_say
.ce_nosyso:
        mov byte [chat_echo_on], 0
        call chat_nick_ptr
        mov di, di
.ce_nick_again:
        mov si, s_chat_nick_prompt
        call chat_read_prompt
        call chat_nick_ptr
        mov si, di
        call upcase_str
        call chat_nick_ptr
        mov si, di
        call chat_nick_ok
        cmp al, 1
        je .ce_nick_ok
        mov si, s_nick_bad
        call puts
        jmp .ce_nick_again
.ce_nick_ok:
        ; SYSOP is reserved: only the console or a SYSTEM shell may claim it
        call chat_nick_ptr
        mov si, di
        mov di, s_nick_sysop
        call streq
        cmp al, 1
        jne .ce_chkzero
        call check_elev
        test al, al
        jz .ce_chkzero
        mov si, s_nick_reserved
        call chat_say
        jmp .ce_nosyso
.ce_chkzero:
        call chat_nick_ptr
        cmp byte [di], 0
        jne .ce_have
        mov byte [di], 'S'
        inc di
        mov al, [cur_task]
        add al, '0'
        stosb
        mov byte [di], 0
.ce_have:
        mov al, [cur_task]
        xor ah, ah
        mov bx, ax
        mov byte [chat_on+bx], 1
        cmp byte [cs_mode+bx], 0
        je .ce_nocs
.ce_nocs:
        call chat_users_row
        mov si, s_chat_joined
        call chat_broadcast
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [cs_mode+bx], 0
        jne .ch_loop
        call chat_is_sp
        cmp al, 1
        je .ch_loop
        call chat_who
.ch_loop:
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [cs_mode+bx], 0
        jne .ch_pan
        call chat_is_sp
        cmp al, 1
        je .ch_pan
        call chat_nick_ptr
        mov si, di
        call puts
        mov al, '>'
        call putc
        mov al, ' '
        call putc
        jmp .ch_read
.ch_pan:
        call chat_redraw_current
.ch_read:
        mov al, [cur_task]
        xor ah, ah
        mov bx, 160
        mul bx
        add ax, shellbuf
        mov di, ax
        mov si, s_chat_empty
        mov byte [chat_echo_on], 1
        call chat_read_prompt
        mov al, [cur_task]
        xor ah, ah
        mov bx, ax
        cmp byte [chat_kicked+bx], 0
        je .ch_normal
        mov byte [chat_kicked+bx], 0
        mov si, s_chat_kicked
        call chat_say
        jmp .ch_leave
.ch_normal:
        mov al, [cur_task]
        xor ah, ah
        mov bx, 160
        mul bx
        add ax, shellbuf
        mov si, ax
        call chat_line
        cmp al, 1
        jne .ch_loop
        mov al, [cur_task]
        xor ah, ah
        mov bx, ax
        mov byte [chat_on+bx], 0
        mov si, s_chat_left
        call chat_broadcast
        mov si, s_chat_bye
        call chat_say
.ch_leave:
        mov bl, [cur_task]
        xor bh, bh
        mov byte [pager_bypass+bx], 0
        pop es
        pop di
        pop bx
        pop ax
        ret
.ce_closed:
        mov si, s_chat_closed
        call puts
        pop es
        pop di
        pop bx
        pop ax
        ret

chat_who:                       ; readable user list (terminal + API)
        push ax
        push bx
        push cx
        push si
        push di
        push ds
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov si, s_chat_users_hdr
        call chat_say
        mov byte [chat_i], 0
.cw_l:
        mov al, [chat_i]
        cmp al, MAXSER
        ja .cw_api
        mov bl, al
        xor bh, bh
        cmp byte [chat_on+bx], 0
        je .cw_n
        mov di, chat_linebuf
        mov al, ' '
        stosb
        stosb
        mov al, [chat_i]
        push di
        call chat_nick_slot_ptr
        mov si, di
        pop di
.cw_cp:
        lodsb
        stosb
        test al, al
        jnz .cw_cp
        mov si, chat_linebuf
        call chat_say
.cw_n:
        inc byte [chat_i]
        jmp .cw_l
.cw_api:
        mov ax, CHATAPI_SEG            ; API users live in 0x2900
        mov ds, ax
        mov si, API_LIST
        cmp byte [si], 0
        je .cw_restore
        call puts
        mov al, 10
        call putc
.cw_restore:
        mov ax, KERNEL_SEG
        mov ds, ax
        pop es
        pop ds
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        ret

chat_line:                      ; SI = line, AL=1 to leave the room
        push ax
        push bx
        push di
        push si
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        cmp byte [si], 0               ; empty line: nothing to send
        jne .cl_notempty
        pop es
        pop si
        pop di
        pop bx
        pop ax
        xor al, al
        ret
.cl_notempty:
        cmp byte [si], '/'
        jne .cl_say
        mov di, s_chat_quit
        call streqi
        cmp al, 1
        je .cl_quit
        mov di, s_chat_who_cmd
        call streqi
        cmp al, 1
        je .cl_who
        mov di, s_chat_help_cmd
        call streqi
        cmp al, 1
        je .cl_help
        mov al, [si+1]
        call upcase
        cmp al, 'M'
        jne .try_ban
        mov al, [si+2]
        call upcase
        cmp al, 'S'
        jne .cl_unk
        mov al, [si+3]
        call upcase
        cmp al, 'G'
        jne .cl_unk
        mov al, [si+4]
        cmp al, 0
        je .cl_msg_body
        cmp al, ' '
        jne .cl_unk
        jmp .cl_msg_body
.try_ban:
        cmp al, 'B'
        jne .cl_unk
        mov al, [si+2]
        call upcase
        cmp al, 'A'
        jne .cl_unk
        mov al, [si+3]
        call upcase
        cmp al, 'N'
        jne .cl_unk
        mov al, [si+4]
        cmp al, 0
        je .cl_ban_body
        cmp al, ' '
        jne .cl_unk
        jmp .cl_ban_body
.cl_msg_body:
        add si, 4
        call skip_sp
        cmp byte [si], 0
        je .cl_msg_usage
        mov [chat_tok], si
.cm_t:
        mov al, [si]
        test al, al
        jz .cl_msg_usage
        cmp al, ' '
        je .cm_e
        inc si
        jmp .cm_t
.cm_e:
.cm_s:
        mov al, [si]
        cmp al, ' '
        jne .cm_text
        inc si
        jmp .cm_s
.cm_text:
        cmp byte [si], 0
        je .cl_msg_usage
        mov [chat_txt], si
        mov si, [chat_tok]
        call chat_find_nick
        cmp al, 0FFh
        je .cm_nouser
        mov [chat_target], al
        mov di, chat_out
        mov si, s_chat_priv_tag
.cm_p1:
        lodsb
        test al, al
        jz .cm_p2
        stosb
        jmp .cm_p1
.cm_p2:
        push di
        call chat_nick_ptr
        mov si, di
        pop di
.cm_p3:
        lodsb
        test al, al
        jz .cm_p4
        stosb
        jmp .cm_p3
.cm_p4:
        mov al, ':'
        stosb
        mov al, ' '
        stosb
        mov si, [chat_txt]
.cm_p5:
        lodsb
        test al, al
        jz .cm_p6
        stosb
        jmp .cm_p5
.cm_p6:
        xor al, al
        stosb
        inc byte [crit]
        mov al, [chat_target]
        mov si, chat_out
        call chat_send_to_slot
        dec byte [crit]
        mov di, chat_linebuf
        mov si, s_chat_priv_sent
.cm_c1:
        lodsb
        test al, al
        jz .cm_c2
        stosb
        jmp .cm_c1
.cm_c2:
        mov al, [chat_target]
        push di
        call chat_nick_slot_ptr
        mov si, di
        pop di
.cm_c3:
        lodsb
        test al, al
        jz .cm_c4
        stosb
        jmp .cm_c3
.cm_c4:
        xor al, al
        stosb
        mov si, chat_linebuf
        call chat_say
        jmp .cl_no
.cm_nouser:
        mov si, s_chat_priv_nf
        call chat_say
        jmp .cl_no
.cl_msg_usage:
        mov si, s_chat_priv_usage
        call chat_say
        jmp .cl_no
.cl_ban_body:
        call check_elev
        cmp al, 0
        je .ban_sysop
        cmp al, 1
        je .ban_conly
        mov si, s_ban_priv
        call chat_say
        jmp .cl_no
.ban_conly:
        mov si, s_chat_ban_only
        call chat_say
        jmp .cl_no
.ban_sysop:
        add si, 4
        call skip_sp
        cmp byte [si], 0
        je .ban_usage
        mov [chat_tok], si
.ban_t:
        mov al, [si]
        test al, al
        jz .ban_do
        cmp al, ' '
        je .ban_do
        inc si
        jmp .ban_t
.ban_do:
        mov si, [chat_tok]
        call chat_find_nick
        cmp al, 0FFh
        je .ban_nouser
        cmp al, 0
        je .ban_self
        mov [chat_target], al
        mov bl, al
        xor bh, bh
        mov byte [chat_on+bx], 0
        mov al, [chat_target]
        mov si, s_chat_banned
        call chat_send_to_slot
        mov bl, [chat_target]
        xor bh, bh
        mov byte [chat_kick+bx], 1
        mov al, [chat_target]
        call chat_wake_slot
        mov di, chat_linebuf
        mov si, s_chat_banned_ok
.ban_k1:
        lodsb
        test al, al
        jz .ban_k2
        stosb
        jmp .ban_k1
.ban_k2:
        mov al, [chat_target]
        push di
        call chat_nick_slot_ptr
        mov si, di
        pop di
.ban_k3:
        lodsb
        test al, al
        jz .ban_k4
        stosb
        jmp .ban_k3
.ban_k4:
        xor al, al
        stosb
        mov si, chat_linebuf
        call chat_say
        jmp .cl_no
.ban_self:
        mov si, s_chat_ban_self
        call chat_say
        jmp .cl_no
.ban_nouser:
        mov si, s_chat_priv_nf
        call chat_say
        jmp .cl_no
.ban_usage:
        mov si, s_chat_ban_usage
        call chat_say
        jmp .cl_no
.cl_unk:
        mov si, s_chat_unknown
        call chat_say
        jmp .cl_no
.cl_who:
        call chat_who
        jmp .cl_no
.cl_help:
        mov si, s_chat_box4
        call chat_say
        mov si, s_chat_box5
        call chat_say
        mov si, s_chat_box6
        call chat_say
        cmp byte [cur_task], 0
        jne .cl_no
        mov si, s_chat_ban_help
        call chat_say
        jmp .cl_no
.cl_say:
        call chat_broadcast
.cl_no:
        pop es
        pop si
        pop di
        pop bx
        pop ax
        xor al, al
        ret
.cl_quit:
        pop es
        pop si
        pop di
        pop bx
        pop ax
        mov al, 1
        ret

; Append SI=line (DS=KERNEL_SEG, NUL-terminated) to the chat history ring in
; CHATAPI_SEG.  Returns AX=seq (0 if the ring is unavailable, e.g. TCP/SLIP
; mode where 0x2900 holds TCP.SYS).
chat_append:
        push bx
        push cx
        push dx
        push si
        push di
        push es
        cmp byte [slip_mode], 0
        jne .ca_skip
        mov ax, CHATAPI_SEG
        mov es, ax
        mov bl, [es:CH_HEAD]
        xor bh, bh
        and bl, CH_N-1
        mov ax, bx
        mov cl, 6
        shl ax, cl                     ; *64
        mov dx, bx
        mov cl, 3
        shl dx, cl                     ; *8
        add ax, dx                     ; *72
        add ax, CH_ENT
        mov di, ax
        mov ax, [es:CH_SEQ]
        inc ax
        mov [es:CH_SEQ], ax
        mov [es:di], ax
        mov [chat_last_seq], ax
        add di, CH_LINE
        mov cx, 69
.ca_l:
        lodsb
        test al, al
        jz .ca_e
        stosb
        dec cx
        jnz .ca_l
.ca_e:
        mov byte [es:di], 0
        mov bl, [es:CH_HEAD]
        inc bl
        and bl, CH_N-1
        mov [es:CH_HEAD], bl
        cmp byte [es:CH_CNT], CH_N
        jae .ca_out
        inc byte [es:CH_CNT]
        jmp .ca_out
.ca_skip:
        mov ax, 0
.ca_out:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        ret

chat_broadcast:                 ; SI=text; sender=cur_task; to other chat slots
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, si
        call chat_nick_ptr
        mov si, di
        mov di, chat_out
.cb_n:
        lodsb
        test al, al
        jz .cb_s
        stosb
        jmp .cb_n
.cb_s:
        mov al, ':'
        stosb
        mov al, ' '
        stosb
        mov si, bx
.cb_t:
        lodsb
        test al, al
        jz .cb_e
        stosb
        jmp .cb_t
.cb_e:
        xor al, al
        stosb
        inc byte [crit]
        mov byte [chat_i], 0
.cb_l:
        mov al, [chat_i]
        cmp al, MAXSER
        ja .cb_d
        mov bl, al
        xor bh, bh
        cmp byte [chat_on+bx], 0
        je .cb_x
        mov al, [cur_task]
        cmp al, [chat_i]
        je .cb_x
        mov al, [chat_i]
        mov si, chat_out
        call chat_send_to_slot
.cb_x:
        inc byte [chat_i]
        jmp .cb_l
.cb_d:
        mov si, chat_out
        call chat_append
        dec byte [crit]
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; WHO / WHOAMI
; =====================================================================

puts_pad:                       ; SI = string, CL = width
        push si
        push cx
        mov dh, 0
        mov dl, cl
.pp:
        lodsb
        test al, al
        jz .pad
        call putc
        dec dx
        jmp .pp
.pad:
        test dx, dx
        jz .done
        mov al, ' '
        call putc
        dec dx
        jmp .pad
.done:
        pop cx
        pop si
        ret

do_whoami:
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        cmp byte [task_out+si], 1
        jne .console
        call user_ptr
        cmp byte [di], 0
        je .notlog
        mov si, di
        call puts
        mov al, 10
        call putc
        ret
.console:
        mov si, s_console
        call puts
        mov al, 10
        call putc
        ret
.notlog:
        mov si, s_notlogged
        call puts
        ret

do_who:
        mov si, s_who_hdr
        call puts
        mov si, s_who_rule
        call puts
        mov si, s_console
        mov cl, 12
        call puts_pad
        mov si, s_who_cga
        call puts
        mov byte [ed_tmp], 1
.wslot:
        mov al, [ed_tmp]
        cmp al, MAXSER
        ja .done
        mov bl, al
        xor bh, bh
        cmp byte [task_state+bx], 1
        jne .next
        mov al, [ed_tmp]
        call user_ptr_slot
        cmp byte [di], 0
        je .next
        mov si, di
        mov cl, 12
        call puts_pad
        mov si, s_who_com1
        call puts
.next:
        inc byte [ed_tmp]
        jmp .wslot
.done:
        ret

; =====================================================================
; Preemption: timer tick (INT 08h) switches tasks
; =====================================================================

int08_new:
        push ax
        mov al, 0x20
        out 0x20, al            ; EOI (no BIOS tick chain: it recurses)
        pop ax
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        push es
        mov ax, KERNEL_SEG
        mov ds, ax
        mov es, ax
        inc word [ticks]
        cmp byte [preempt_on], 0
        je .np
        cmp byte [crit], 0
        jne .np
        mov bl, [cur_task]
        xor bh, bh
        mov si, bx
        shl si, 1
        mov [task_sp+si], sp
        mov ax, ss
        mov [task_ss+si], ax
        call next_task
        mov al, bl
        mov [cur_task], al
        mov si, bx
        shl si, 1
        mov ax, [task_ss+si]
        mov ss, ax
        mov sp, [task_sp+si]
        pop es
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        iret
.np:
        pop es
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        iret

do_preempt:
        push ax
        push si
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_preempt_state
        call puts
        cmp byte [preempt_on], 0
        je .off
        mov si, s_on
        jmp .pp
.off:
        mov si, s_offstr
.pp:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .offcmd
        mov al, [si+1]
        call upcase
        cmp al, 'N'
        jne .offcmd
        mov byte [preempt_on], 1
        mov si, s_preempt_on
        call puts
        jmp .ret
.offcmd:
        cmp al, 'F'
        jne .ret
        mov al, [si+1]
        call upcase
        cmp al, 'F'
        jne .ret
        mov byte [preempt_on], 0
        mov si, s_preempt_off
        call puts
.ret:
        pop si
        pop ax
        ret

; =====================================================================
; MUX ON|OFF - console only; switch COM1 between raw and framed mux
; =====================================================================

do_web:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        cmp byte [cur_task], 0
        je .go
        mov si, s_web_conly
        call puts
        jmp .ret
.go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_web_state
        call puts
        cmp byte [web_enabled], 0
        je .off
        mov si, s_on
        jmp .pr
.off:
        mov si, s_offstr
.pr:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .ret
        inc si
        mov al, [si]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .ret
        mov byte [web_enabled], 0
        jmp .report
.on:
        mov byte [web_enabled], 1
.report:
        mov si, s_web_state
        call puts
        cmp byte [web_enabled], 0
        je .roff
        mov si, s_on
        jmp .rpr
.roff:
        mov si, s_offstr
.rpr:
        call puts
        mov al, 10
        call putc
.ret:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

do_weblog:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        call check_elev
        cmp al, 0
        je .go
        cmp al, 1
        jne .priv
        mov si, s_web_conly
        call puts
        jmp .ret
.priv:
        mov si, s_priv_req
        call puts
        jmp .ret
.go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_weblog_state
        call puts
        cmp byte [web_log], 0
        je .off
        mov si, s_on
        jmp .pr
.off:
        mov si, s_offstr
.pr:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'C'
        je .conly
        cmp al, 'S'
        je .sonly
        cmp al, 'O'
        jne .ret
        inc si
        mov al, [si]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .ret
        mov byte [web_log], 0
        mov byte [web_log_slot], 0
        jmp .report
.conly:
        mov byte [web_log_serial], 0
        mov byte [web_log], 1
        mov al, [cur_task]
        mov [web_log_slot], al
        jmp .report
.sonly:
        mov al, [cur_task]
        test al, al
        je .sok
        call check_elev
        cmp al, 0
        je .sok
        mov si, s_web_need_sys
        call puts
        jmp .ret
.sok:
        mov byte [web_log_serial], 1
        mov byte [web_log], 1
        mov al, [cur_task]
        mov [web_log_slot], al
        jmp .report
.on:
        mov byte [web_log_serial], 1
        mov byte [web_log], 1
        mov al, [cur_task]
        mov [web_log_slot], al
.report:
        mov si, s_weblog_state
        call puts
        cmp byte [web_log], 0
        je .roff
        mov si, s_on
        jmp .rpr
.roff:
        mov si, s_offstr
.rpr:
        call puts
        mov al, 10
        call putc
.ret:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

do_baud:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        cmp byte [cur_task], 0
        je .go
        mov si, s_baud_conly
        call puts
        jmp .ret
.go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_baud_state
        call puts
        mov ax, [baud_rate]
        call put_dec
        mov al, 10
        call putc
        jmp .ret
.set:
        xor bx, bx
        xor cx, cx
.p1:
        mov al, [si]
        cmp al, '0'
        jb .pdone
        cmp al, '9'
        ja .pdone
        sub al, '0'
        xor ah, ah
        push ax
        mov ax, bx
        mov dx, 10
        mul dx
        mov bx, ax
        pop ax
        add bx, ax
        inc cx
        inc si
        cmp cx, 5
        jb .p1
.pdone:
        cmp bx, 2400
        je .b2400
        cmp bx, 4800
        je .b4800
        cmp bx, 9600
        je .b9600
        cmp bx, 19200
        je .b19200
        cmp bx, 38400
        je .b38400
        jmp .usage
.b2400:
        mov bx, 48
        jmp .apply
.b4800:
        mov bx, 24
        jmp .apply
.b9600:
        mov bx, 12
        jmp .apply
.b19200:
        mov bx, 6
        jmp .apply
.b38400:
        mov bx, 3
.apply:
        mov ax, bx
        mov [baud_div], ax
        ; recompute the human rate for the message
        cmp bx, 48
        jne .r24
        mov word [baud_rate], 2400
        jmp .prog
.r24:
        cmp bx, 24
        jne .r48
        mov word [baud_rate], 4800
        jmp .prog
.r48:
        cmp bx, 12
        jne .r96
        mov word [baud_rate], 9600
        jmp .prog
.r96:
        cmp bx, 6
        jne .r192
        mov word [baud_rate], 19200
        jmp .prog
.r192:
        mov word [baud_rate], 38400
.prog:
        mov dx, 0x3FB
        mov al, 0x83
        out dx, al
        mov dx, 0x3F8
        mov al, bl
        out dx, al
        mov dx, 0x3F9
        xor al, al
        out dx, al
        mov dx, 0x3FB
        mov al, 0x03
        out dx, al
        cli
        mov byte [mux_state], 0
.bdrain:
        mov dx, 0x3FD
        in al, dx
        test al, 1
        jz .bdrained
        mov dx, 0x3F8
        in al, dx
        jmp .bdrain
.bdrained:
        mov bx, 1
.bclr:
        cmp bx, MAXSER
        ja .bclrdone
        mov byte [rx_head+bx], 0
        mov byte [rx_tail+bx], 0
        mov byte [tx_len+bx], 0
        mov byte [mux_open_pending+bx], 0
        mov byte [mux_close_pending+bx], 0
        mov byte [mux_app_pending+bx], 0
        inc bx
        jmp .bclr
.bclrdone:
        sti
        mov si, s_baud_ok
        call puts
        mov ax, [baud_rate]
        call put_dec
        mov al, 10
        call putc
        jmp .ret
.usage:
        mov si, s_baud_usage
        call puts
.ret:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

do_tcplog:
        push ax
        push es
        push si
        cmp byte [cur_task], 0
        je .go
        mov si, s_tcp_conly
        call puts
        jmp .ret
.go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_tcplog_state
        call puts
        cmp byte [tcp_log], 0
        je .off
        mov si, s_on
        jmp .pr
.off:
        mov si, s_offstr
.pr:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .ret
        inc si
        mov al, [si]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .ret
        mov byte [tcp_log], 0
        jmp .apply
.on:
        mov byte [tcp_log], 1
.apply:
        cmp byte [tcp_loaded], 0
        je .report
        mov ax, TCP_SEG
        mov es, ax
        mov al, [tcp_log]
        mov [es:0x1FFE], al
.report:
        mov si, s_tcplog_state
        call puts
        cmp byte [tcp_log], 0
        je .roff
        mov si, s_on
        jmp .rpr
.roff:
        mov si, s_offstr
.rpr:
        call puts
        mov al, 10
        call putc
.ret:
        pop si
        pop es
        pop ax
        ret

do_tcp:
        push ax
        push si
        push es
        cmp byte [cur_task], 0
        je .go
        mov si, s_tcp_conly
        call puts
        jmp .ret
.go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_tcp_state
        call puts
        cmp byte [tcp_loaded], 0
        je .off
        mov si, s_on
        jmp .pr
.off:
        mov si, s_offstr
.pr:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .ret
        inc si
        mov al, [si]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .ret
        mov byte [tcp_loaded], 0
        mov si, s_tcp_off
        call puts
        jmp .ret
.on:
        cmp byte [tcp_loaded], 0
        jne .already
        mov si, s_tcp_file
        call build83
        call find_file
        jc .missing
        mov ax, TCP_SEG
        mov es, ax
        xor bx, bx
        mov cx, 0x7000
        inc byte [crit]
        call load_file
        dec byte [crit]
        jc .missing
        mov byte [tcp_loaded], 1
        mov ax, TCP_SEG
        mov es, ax
        mov byte [es:0x2000], 0
        mov word [es:0x2001], 0
        mov al, [tcp_log]
        mov [es:0x1FFE], al
        mov si, s_tcp_on
        call puts
        jmp .ret
.missing:
        mov si, s_tcp_missing
        call puts
        jmp .ret
.already:
        mov si, s_tcp_already
        call puts
.ret:
        pop es
        pop si
        pop ax
        ret

do_slip:
        push ax
        push si
        cmp byte [cur_task], 0
        je .go
        mov si, s_slip_conly
        call puts
        jmp .ret
.go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        jmp .show
.set:
        mov al, [si]
        call upcase
        cmp al, 'S'
        je .show
        cmp al, 'O'
        jne .ret
        inc si
        mov al, [si]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .ret
        mov byte [slip_mode], 0
        mov byte [slip_esc], 0
        mov word [slip_len], 0
        call mux_hw_off                 ; back to the polled raw console
        mov si, s_slip_off
        call puts
        cmp byte [task_state+1], 1
        je .ret
        call spawn_shell1
        jmp .ret
.on:
        cmp byte [mux_mode], 0
        jne .muxon
        cmp byte [task_state+1], 1
        jne .on_go
        cmp byte [task_term+1], 0
        jne .on_go
        mov byte [task_state+1], 0
        mov al, 1
        call session_reset_slot
.on_go:
        mov byte [slip_esc], 0
        mov byte [slip_bad], 0
        mov word [slip_len], 0
        mov byte [slip_mode], 1
        call mux_hw_on                  ; IRQ4 on; the ISR now decodes SLIP
        mov si, s_slip_on
        call puts
        jmp .ret
.muxon:
        mov si, s_slip_mux
        call puts
        jmp .ret
.show:
        mov si, s_slip_state
        call puts
        cmp byte [slip_mode], 0
        je .show_off
        mov si, s_on
        call puts
        mov al, 10
        call putc
        mov si, s_slip_ip
        call puts
        mov si, ip_my_addr
        call put_ip
        mov si, s_slip_mtu
        call puts
        cmp byte [mux_mode], 0
        je .show_muxoff
        mov si, s_on
        jmp .show_mux
.show_muxoff:
        mov si, s_offstr
.show_mux:
        call puts
        mov al, 10
        call putc
        mov si, s_slip_rx
        call puts
        mov ax, [slip_rx_pkts]
        call put_dec
        mov si, s_slip_tx
        call puts
        mov ax, [slip_tx_pkts]
        call put_dec
        mov si, s_slip_err
        call puts
        mov ax, [slip_errors]
        call put_dec
        mov al, 10
        call putc
        jmp .ret
.show_off:
        mov si, s_offstr
        call puts
        mov al, 10
        call putc
.ret:
        pop si
        pop ax
        ret

do_mux:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        cmp byte [cur_task], 0
        je .console
        call sys_begin
        mov si, s_mux_console_only
        call puts
        jmp .ret
.console:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        call sys_begin
        mov si, s_mux_state
        call puts
        cmp byte [mux_mode], 0
        je .st_off
        mov si, s_on
        jmp .st_pr
.st_off:
        mov si, s_offstr
.st_pr:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .usage
        mov al, [si+1]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .usage
        mov al, [si+2]
        call upcase
        cmp al, 'F'
        jne .usage
        jmp .off
.usage:
        call sys_begin
        mov si, s_mux_usage
        call puts
        jmp .ret
.on:
        cmp byte [slip_mode], 0
        je .on_ok
        call sys_begin
        mov si, s_mux_slip
        call puts
        jmp .ret
.on_ok:
        cmp byte [mux_mode], 0
        jne .already_on
        ; stop the raw serial shell in slot 1 so a framed OPEN can claim it
        cmp byte [task_state+1], 1
        jne .on_hw
        cmp byte [task_term+1], 0
        jne .on_hw
        mov byte [task_state+1], 0
        mov al, 1
        call session_reset_slot
.on_hw:
        mov byte [mux_state], 0
        mov byte [mux_open_pending+1], 0
        mov byte [mux_open_pending+2], 0
        mov byte [mux_close_pending+1], 0
        mov byte [mux_close_pending+2], 0
        call mux_hw_on
        mov byte [mux_mode], 1
        call sys_begin
        mov si, s_mux_on_msg
        call puts
        jmp .ret
.already_on:
        call sys_begin
        mov si, s_mux_already
        call puts
        jmp .ret
.off:
        cmp byte [mux_mode], 0
        je .already_off
        cmp byte [task_state+1], 1
        jne .chk2
        cmp byte [task_term+1], 0
        jne .busy
.chk2:
        cmp byte [task_state+2], 1
        jne .off_go
        cmp byte [task_term+2], 0
        jne .busy
.off_go:
        mov byte [mux_mode], 0
        call mux_hw_off
        mov byte [mux_state], 0
        mov byte [task_state+1], 0
        mov byte [task_state+2], 0
        mov al, 1
        call session_reset_slot
        mov al, 2
        call session_reset_slot
        mov byte [task_term+1], 0
        mov byte [task_term+2], 0
        mov byte [chat_on+1], 0
        mov byte [chat_on+2], 0
        call spawn_shell1
        call sys_begin
        mov si, s_mux_off_msg
        call puts
        jmp .ret
.busy:
        call sys_begin
        mov si, s_mux_busy
        call puts
        jmp .ret
.already_off:
        call sys_begin
        mov si, s_mux_already_off
        call puts
.ret:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

check_elev:                     ; AL=0 allowed, 1 console-only, 2 SYSTEM priv off
        cmp byte [cur_task], 0
        je .yes
        call user_ptr
        mov si, di
        mov di, s_admin_user
        call streq
        cmp al, 1
        jne .conly
        cmp byte [priv_on], 0
        je .nopriv
.yes:
        xor al, al
        ret
.conly:
        mov al, 1
        ret
.nopriv:
        mov al, 2
        ret

; =====================================================================
; MORE ON|OFF|LINES - page all output for this session
; =====================================================================

do_more:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_pager_state
        call sys_begin
        call puts
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [pager_on+bx], 0
        je .st_off
        mov si, s_on
        call puts
        mov al, ' '
        call putc
        mov bl, [cur_task]
        xor bh, bh
        mov al, [pager_lines+bx]
        xor ah, ah
        call put_dec
        mov si, s_pager_lines
        call puts
        mov al, 10
        call putc
        jmp .ret
.st_off:
        mov si, s_offstr
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .num
        mov al, [si+1]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .usage
        mov al, [si+2]
        call upcase
        cmp al, 'F'
        jne .usage
        jmp .off
.on:
        mov bl, [cur_task]
        xor bh, bh
        mov byte [pager_on+bx], 1
        mov byte [pager_count+bx], 0
        cmp byte [pager_lines+bx], 0
        jne .onmsg
        mov byte [pager_lines+bx], 20
.onmsg:
        jmp .state
.off:
        mov bl, [cur_task]
        xor bh, bh
        mov byte [pager_on+bx], 0
        mov si, s_pager_off_msg
        call sys_begin
        call puts
        jmp .ret
.num:
        xor ax, ax
        xor cx, cx
.n1:
        mov dl, [si]
        cmp dl, '0'
        jb .nd
        cmp dl, '9'
        ja .nd
        sub dl, '0'
        xor dh, dh
        push dx
        mov dx, 10
        mul dx
        pop dx
        add ax, dx
        inc si
        inc cx
        cmp cx, 4
        jb .n1
.nd:
        test cx, cx
        jz .usage
        test ax, ax
        jz .off
        cmp ax, 200
        jbe .nok
        mov ax, 200
.nok:
        mov bl, [cur_task]
        xor bh, bh
        mov [pager_lines+bx], al
        mov byte [pager_on+bx], 1
        mov byte [pager_count+bx], 0
.state:
        mov si, s_pager_state
        call sys_begin
        call puts
        mov si, s_on
        call puts
        mov al, ' '
        call putc
        mov bl, [cur_task]
        xor bh, bh
        mov al, [pager_lines+bx]
        xor ah, ah
        call put_dec
        mov si, s_pager_lines
        call puts
        mov al, 10
        call putc
        jmp .ret
.usage:
        mov si, s_more_usage
        call sys_begin
        call puts
.ret:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; PRIV ON|OFF - console system privilege (default OFF)
; =====================================================================

do_priv:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        cmp byte [cur_task], 0
        je .console
        mov si, s_priv_conly
        call sys_begin
        call puts
        jmp .ret
.console:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_priv_state
        call sys_begin
        call puts
        cmp byte [priv_on], 0
        je .off
        mov si, s_on
        jmp .pr
.off:
        mov si, s_offstr
.pr:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .usage
        mov al, [si+1]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .usage
        mov al, [si+2]
        call upcase
        cmp al, 'F'
        jne .usage
        jmp .offcmd
.on:
        mov byte [priv_on], 1
        mov si, s_priv_on_msg
        call sys_begin
        call puts
        jmp .ret
.offcmd:
        mov byte [priv_on], 0
        mov si, s_priv_off_msg
        call sys_begin
        call puts
        jmp .ret
.usage:
        mov si, s_priv_usage
        call sys_begin
        call puts
.ret:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; CHAT [ON|OFF] - join, or console enable/disable the room
; =====================================================================

do_chat:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .args
        cmp byte [chat_ok], 0
        je .nooverlay
        mov bx, CHAT_SEG                ; a real overlay starts with a jmp
        mov es, bx
        cmp byte [es:0], 0xEB
        jne .nooverlay
        mov al, [cur_task]
        mov bx, cs
        push bx
        mov bx, .chret
        push bx
        mov bx, CHAT_SEG
        push bx
        xor bx, bx
        push bx
        retf
.chret:
        jmp .ret
.nooverlay:
        cmp byte [chat_enabled], 0
        je .disabled
        call chat_enter
        jmp .ret
.args:
        call check_elev
        cmp al, 0
        je .args_ok
        cmp al, 1
        je .conly
        mov si, s_priv_req
        call sys_begin
        call puts
        jmp .ret
.args_ok:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .usage
        mov al, [si+1]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .usage
        mov al, [si+2]
        call upcase
        cmp al, 'F'
        jne .usage
        jmp .off
.usage:
        mov si, s_chat_usage
        call sys_begin
        call puts
        jmp .ret
.conly:
        mov si, s_chat_conly
        call sys_begin
        call puts
        jmp .ret
.disabled:
        mov si, s_chat_closed
        call sys_begin
        call puts
        jmp .ret
.on:
        cmp byte [chat_enabled], 0
        jne .already
        mov byte [chat_enabled], 1
        mov si, s_chat_enabled_msg
        call sys_begin
        call puts
        jmp .ret
.already:
        mov si, s_chat_already
        call sys_begin
        call puts
        jmp .ret
.off:
        cmp byte [chat_enabled], 0
        je .already_off
        mov byte [chat_enabled], 0
        mov byte [chat_i], 0
.ej_l:
        mov al, [chat_i]
        cmp al, MAXSER
        ja .ej_done
        mov bl, al
        xor bh, bh
        cmp byte [chat_on+bx], 0
        je .ej_next
        mov byte [chat_on+bx], 0
        mov byte [chat_kick+bx], 1
        mov al, [chat_i]
        call chat_wake_slot
.ej_next:
        inc byte [chat_i]
        jmp .ej_l
.ej_done:
        mov si, s_chat_disabled_msg
        call sys_begin
        call puts
        jmp .ret
.already_off:
        mov si, s_chat_already_off
        call sys_begin
        call puts
.ret:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; QUANTUM [18|50|100|200|500|1000] - console scheduler rate
; =====================================================================

do_quantum:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        call check_elev
        cmp al, 0
        je .go
        cmp al, 1
        je .conly
        mov si, s_priv_req
        call sys_begin
        call puts
        jmp .ret
.go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        jmp .report
.set:
        xor bx, bx
        xor cx, cx
.p1:
        mov al, [si]
        cmp al, '0'
        jb .pdone
        cmp al, '9'
        ja .pdone
        sub al, '0'
        xor ah, ah
        push ax
        mov ax, bx
        mov dx, 10
        mul dx
        mov bx, ax
        pop ax
        add bx, ax
        inc cx
        inc si
        cmp cx, 4
        jb .p1
.pdone:
        cmp bx, 18
        je .q18
        cmp bx, 50
        je .q50
        cmp bx, 100
        je .q100
        cmp bx, 200
        je .q200
        cmp bx, 500
        je .q500
        cmp bx, 1000
        je .q1000
        jmp .usage
.q18:
        mov ax, 0
        mov dx, 18
        mov cx, 9
        jmp .apply
.q50:
        mov ax, 23864
        mov dx, 50
        mov cx, 25
        jmp .apply
.q100:
        mov ax, 11932
        mov dx, 100
        mov cx, 50
        jmp .apply
.q200:
        mov ax, 5966
        mov dx, 200
        mov cx, 100
        jmp .apply
.q500:
        mov ax, 2386
        mov dx, 500
        mov cx, 250
        jmp .apply
.q1000:
        mov ax, 1193
        mov dx, 1000
        mov cx, 500
.apply:
        mov [tick_div], ax
        mov [tick_hz], dx
        mov [mux_idle], cx
        mov al, 0x36
        out 0x43, al
        mov ax, [tick_div]
        out 0x40, al
        mov al, ah
        out 0x40, al
        jmp .report
.report:
        mov di, qbuf
        mov si, s_q_prefix
        call copyz
        mov ax, [tick_hz]
        call fmt_dec16
        mov si, s_q_mid
        call copyz
        mov ax, 1000
        xor dx, dx
        div word [tick_hz]
        call fmt_dec16
        mov si, s_q_ms
        call copyz
        mov si, qbuf
        call sys_begin
        call puts
        jmp .ret
.conly:
        mov si, s_q_conly
        call sys_begin
        call puts
        jmp .ret
.usage:
        mov si, s_q_usage
        call sys_begin
        call puts
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; =====================================================================
; CPU clock measurement: 8088 DEC/JNZ loop (18 clocks) vs the 18.2 Hz tick
; =====================================================================

measure_cpu:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov byte [cpu_known], 0
        mov word [cpu100], 0
        inc byte [crit]                 ; no task switches; IRQ0 still ticks
        mov bl, [ticks]
.mwait:
        mov al, [ticks]
        cmp al, bl
        je .mwait
        mov bl, al
        xor si, si
.mouter:
        mov cx, 64
.minner:
        dec cx
        jnz .minner
        add si, 64
        jc .mover
        mov al, [ticks]
        sub al, bl
        cmp al, 1
        jb .mouter
        jmp .mdone
.mover:
        dec byte [crit]
        jmp .mexit
.mdone:
        dec byte [crit]
        cmp word [tick_div], 0
        jne .mfast
        mov ax, si
        mov bx, 100
        mul bx                          ; DX:AX = N*100
        mov bx, 3051                    ; 54925.4/18 rounded (18 Hz tick)
        call div32_16
        jmp .mstore
.mfast:
        mov ax, si
        mov bx, 2148                    ; 18*1193182*100/1e6
        mul bx
        mov bx, [tick_div]
        call div32_16
.mstore:
        mov [cpu100], ax
        mov byte [cpu_known], 1
.mexit:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; DX:AX / BX -> AX quotient (must fit 16 bits), DX remainder
div32_16:
        push bx
        push cx
        push si
        mov si, bx
        mov cx, ax
        mov ax, dx
        xor dx, dx
        div si
        mov bx, ax
        mov ax, cx
        div si
        pop si
        pop cx
        pop bx
        ret

fmt_dec16:                      ; AX -> decimal at ES:DI
        push ax
        push bx
        push cx
        push dx
        mov bx, 10
        xor cx, cx
.fd1:
        xor dx, dx
        div bx
        push dx
        inc cx
        test ax, ax
        jnz .fd1
.fd2:
        pop ax
        add al, '0'
        stosb
        loop .fd2
        pop dx
        pop cx
        pop bx
        pop ax
        ret

build_cpu_line:                 ; cpu_line = "MEASURED CPU: x.xx MHZ"
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, cpu_line
        cmp byte [cpu_known], 0
        je .unknown
        mov si, s_cpu_prefix
        call copyz
        mov ax, [cpu100]
        xor dx, dx
        mov bx, 100
        div bx
        push dx
        call fmt_dec16
        mov al, '.'
        stosb
        pop ax
        xor ah, ah
        mov bl, 10
        div bl
        add al, '0'
        stosb
        mov al, ah
        add al, '0'
        stosb
        mov si, s_cpu_suffix
        call copyz
        jmp .done
.unknown:
        mov si, s_cpu_unknown
        call copyz
.done:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; -> AL=1 if Ctrl-C was pressed on the current console
check_break:
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [task_in+bx], 1
        je .ser
        mov ah, 1
        int 0x16
        jz .no
        mov ah, 0
        int 0x16
        cmp al, 3
        je .yes
        jmp .no
.ser:
        mov dx, 0x3FD
        in al, dx
        test al, 1
        jz .no
        mov dx, 0x3F8
        in al, dx
        cmp al, 3
        je .yes
.no:
        xor al, al
        ret
.yes:
        mov al, 1
        ret

; =====================================================================
; Serial session tasks (slots 1 and 2)
; =====================================================================

session_reset_slot:             ; AL = slot
        push ax
        push bx
        push cx
        mov bl, al
        xor bh, bh
        cmp byte [web_log_slot], bl
        jne .sr_no_web
        mov byte [web_log_slot], 0
.sr_no_web:
        cmp byte [ovl_owner], bl
        jne .sr_no_ovl
        mov byte [ovl_owner], 0xFF
.sr_no_ovl:
        mov byte [ser_panel+bx], 0
        mov byte [sp_cleared+bx], 0
        mov byte [chat_on+bx], 0
        mov byte [pin_len+bx], 0
        mov byte [pin_col+bx], 0
        mov byte [rx_head+bx], 0
        mov byte [rx_tail+bx], 0
        mov byte [tx_len+bx], 0
        mov byte [pager_on+bx], 0
        mov byte [pager_count+bx], 0
        mov byte [pager_bypass+bx], 0
        mov al, bl
        call user_ptr_slot
        mov byte [di], 0
        mov al, bl
        xor ah, ah
        mov cl, 5
        shl ax, cl
        mov di, login_user
        add di, ax
        mov byte [di], 0
        mov al, bl
        xor ah, ah
        mov cl, 5
        shl ax, cl
        mov di, login_pass
        add di, ax
        mov byte [di], 0
        pop cx
        pop bx
        pop ax
        ret

session_start:                  ; AL = slot
        push ax
        call session_reset_slot
        pop ax
        call spawn_session
        ret

spawn_session:                  ; AL = slot
        mov bl, al
        xor bh, bh
        mov si, bx
        shl si, 1
        ; The frame below is built on the NEW task's stack while cur_task still
        ; names the spawning task.  A timer tick in this window would save this
        ; half-built SP/SS into the spawning task's slot, corrupting its saved
        ; context.  crit stops int08_new from switching and cli keeps IRQ4 from
        ; pushing through the half-switched SS:SP (mov ss does not mask IRQs on
        ; an 8086).
        pushf
        cli
        inc byte [crit]
        mov [save_sp], sp
        mov ax, ss
        mov [save_ss], ax
        mov ax, [task_stk+si]
        mov ss, ax
        mov sp, 0x0FFE
        mov ax, 0x0202
        push ax
        mov ax, KERNEL_SEG
        push ax
        cmp byte [task_app+bx], 2
        jne .entry_chk3
        mov ax, web_entry
        jmp .entry_put
.entry_chk3:
        cmp byte [task_app+bx], 3
        jne .entry_con
        mov ax, upload_entry
        jmp .entry_put
.entry_con:
        mov ax, shell1_entry
.entry_put:
        push ax
        xor ax, ax
        push ax
        push ax
        push ax
        push ax
        push ax
        push ax
        push ax
        mov ax, KERNEL_SEG
        push ax
        push ax
        mov [task_sp+si], sp
        mov ax, ss
        mov [task_ss+si], ax
        mov ax, [save_ss]
        mov ss, ax
        mov sp, [save_sp]
        mov byte [task_out+bx], 1
        mov byte [task_in+bx], 1
        mov byte [task_state+bx], 1
        dec byte [crit]
        popf
        ret

spawn_shell1:                   ; raw-mode boot / slot 1
        mov al, 1
        jmp spawn_session

shell1_entry:
        mov si, s_serial
        call puts
        call serial_login
        jmp shell

; =====================================================================
; TFTP server (RFC 1350 + blksize option, 40-byte blocks)
;
; The IP receive path runs in the IRQ4 ISR (or with interrupts off), so it
; only copies the datagram into tf_rxbuf.  tftp_step runs from mux_poll in
; task context and does the FAT work.  One transfer at a time; the peer is
; locked after the first request.  GET streams from disk, PUT accumulates
; straight into the FAT (cluster per cluster) with no staging buffer.
; =====================================================================

TFTP_PORT       equ 69
TFTP_TID        equ 6969
TFTP_BLK        equ 192         ; 28+4+192 = 224, one frame, no stuffing
TFTP_WIN        equ 4           ; blocks per ACK (RFC 7440)
TFTP_RXMAX      equ 256
TFTP_TIMEOUT    equ 100         ; ticks
TF_ACK0         equ 1
TF_SEND         equ 2
TF_DATA         equ 3

tftp_step:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        cmp byte [tf_enabled], 0
        je .ts_out
        cmp byte [tf_pending], 0
        jne .ts_pkt
        cmp byte [tf_state], 0
        je .ts_out
        mov ax, [ticks]
        sub ax, [tf_last_tx]            ; elapsed since the last send
        cmp ax, [tf_to]
        jb .ts_out
        inc byte [tf_retries]
        cmp byte [tf_retries], 10
        ja .ts_abort
        cmp byte [tf_state], TF_SEND
        jne .ts_resend_one
        call tf_win_resend
        jmp .ts_out
.ts_resend_one:
        call tf_send                    ; resend the last OACK/ACK
        jmp .ts_out
.ts_abort:
        mov byte [tf_state], 0
        mov byte [tf_retries], 0
        jmp .ts_out
.ts_pkt:
        mov byte [tf_pending], 0
        call tftp_handle
.ts_out:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tftp_handle:
        push ax
        push bx
        push cx
        push dx
        push bp
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        mov si, tf_rxbuf
        mov ax, [si]
        xchg al, ah
        cmp ax, 1
        je .th_request
        cmp ax, 2
        je .th_request
        cmp byte [tf_state], 0
        je .th_out
        mov ax, [tf_qip]
        cmp ax, [tf_peer_ip]
        jne .th_out
        mov ax, [tf_qip+2]
        cmp ax, [tf_peer_ip+2]
        jne .th_out
        mov ax, [tf_qport]
        cmp ax, [tf_peer_port]
        jne .th_out
        mov ax, [si]
        xchg al, ah
        cmp ax, 3
        je .th_data
        cmp ax, 4
        je .th_ack
        jmp .th_out

.th_request:
        cmp byte [tf_state], 0
        je .th_new
        ; same client retransmitting the request: resend the OACK/ACK
        mov ax, [tf_qip]
        cmp ax, [tf_peer_ip]
        jne .th_busy
        mov ax, [tf_qip+2]
        cmp ax, [tf_peer_ip+2]
        jne .th_busy
        mov ax, [tf_qport]
        cmp ax, [tf_peer_port]
        jne .th_busy
        mov al, [tf_rxbuf+1]
        cmp al, [tf_op]
        jne .th_busy
        call tf_send
        jmp .th_out
.th_busy:
        mov si, s_tf_busy
        xor al, al
        call tf_error_q
        jmp .th_out
.th_new:
        mov ax, [tf_qip]
        mov [tf_peer_ip], ax
        mov [tf_dst_ip], ax
        mov ax, [tf_qip+2]
        mov [tf_peer_ip+2], ax
        mov [tf_dst_ip+2], ax
        mov ax, [tf_qport]
        mov [tf_peer_port], ax
        mov [tf_dst_port], ax
        mov si, tf_rxbuf
        mov al, [si+1]
        mov [tf_op], al
        add si, 2
        mov di, tf_name
        xor cx, cx
.th_name:
        lodsb
        test al, al
        jz .th_name_done
        cmp al, '\'
        je .th_badname
        cmp al, '/'
        je .th_badname
        cmp al, ':'
        je .th_badname
        cmp cx, 11
        jae .th_name_skip
        call upcase
        stosb
        inc cx
.th_name_skip:
        jmp .th_name
.th_name_done:
        test cx, cx
        jz .th_badname
        mov byte [di], 0
        mov al, [si]
        call upcase
        cmp al, 'O'                     ; octet only
        jne .th_badmode
.th_mode_end:
        lodsb
        test al, al
        jnz .th_mode_end
        mov byte [tf_have_blk], 0
        mov byte [tf_tsize], 0
        mov word [tf_tsize_val], 0
        mov byte [tf_win], 1
        mov byte [tf_have_win], 0
        mov byte [tf_blk], TFTP_BLK
.th_opt:
        cmp byte [si], 0
        je .th_opt_done
        mov di, tf_opt
        xor cx, cx
.th_oname:
        lodsb
        test al, al
        jz .th_oname_done
        cmp cx, 11
        jae .th_oname_skip
        call upcase
        stosb
        inc cx
.th_oname_skip:
        jmp .th_oname
.th_oname_done:
        mov byte [di], 0
        push si
        mov si, tf_opt
        mov di, s_blksize
        call streq
        pop si
        cmp al, 1
        jne .th_not_blk
        call tf_parse_dec
        cmp ax, 8
        jb .th_badopt
        cmp ax, TFTP_BLK
        jbe .th_blk_ok
        mov ax, TFTP_BLK
.th_blk_ok:
        mov [tf_blk], al
        mov byte [tf_have_blk], 1
        inc si                          ; skip the value's NUL
        jmp .th_opt
.th_not_blk:
        push si
        mov si, tf_opt
        mov di, s_tsize
        call streq
        pop si
        cmp al, 1
        jne .th_not_tsize
        call tf_parse_dec
        mov [tf_tsize_val], ax
        mov byte [tf_tsize], 1
        inc si
        jmp .th_opt
.th_not_tsize:
        push si
        mov si, tf_opt
        mov di, s_windowsize
        call streq
        pop si
        cmp al, 1
        jne .th_skip_val
        call tf_parse_dec
        cmp ax, 1
        jbe .th_win1
        cmp ax, TFTP_WIN
        jbe .th_win_ok
        mov ax, TFTP_WIN
        jmp .th_win_ok
.th_win1:
        mov ax, 1
.th_win_ok:
        mov [tf_win], al
        mov byte [tf_have_win], 1
        inc si
        jmp .th_opt
.th_skip_val:
        lodsb
        test al, al
        jnz .th_skip_val
        jmp .th_opt
.th_opt_done:
        cmp byte [tf_have_blk], 0
        je .th_noblk
        cmp byte [tf_op], 1
        je .th_rrq
        jmp .th_wrq

.th_badname:
        mov si, s_tf_name
        mov al, 2
        jmp .th_err
.th_badmode:
        mov si, s_tf_mode
        mov al, 4
        jmp .th_err
.th_badopt:
        mov si, s_tf_opt
        mov al, 8
        jmp .th_err
.th_noblk:
        mov si, s_tf_noblk
        mov al, 8
        jmp .th_err
.th_nofile:
        mov si, s_tf_nofile
        mov al, 1
        jmp .th_err
.th_acc:
        mov si, s_tf_acc
        mov al, 2
        jmp .th_err
.th_full:
        mov si, s_tf_full
        mov al, 3
.th_err:
        call tf_log_err
        call tf_error_peer
        jmp .th_out

; ---- read request: stream the file, block by block ----
.th_rrq:
        mov si, tf_name
        call tf_build83
        call find_file
        jc .th_nofile
        cmp word [file_size+2], 0       ; 64 KB limit (FAT low word)
        jne .th_nofile
        call tf_log_req
        mov ax, [file_size]
        mov [tf_left], ax
        mov [tf_tsize_out], ax
        mov ax, [file_cluster]
        mov [tf_cluster], ax
        mov word [tf_sec], 0FFFFh       ; force a load of sector 0 on first fill
        mov word [tf_off], 512
        mov word [tf_block], 0
        mov word [tf_wbase], 0
        mov word [tf_wnext], 0
        mov word [tf_wnum], 0
        mov byte [tf_final], 0
        mov byte [tf_retries], 0
        call tf_send_oack
        mov byte [tf_state], TF_ACK0
        jmp .th_out

; ---- write request: stream blocks straight into the FAT ----
.th_wrq:
        cmp byte [write_ok], 0
        je .th_acc
        cmp byte [tf_tsize], 0
        je .th_wrq_ok
        mov ax, [tf_tsize_val]
        cmp ax, 65000                   ; FAT size is a 16-bit word
        ja .th_full
.th_wrq_ok:
        mov si, tf_name
        call tf_build83
        mov si, namebuf
        mov di, tf_name83
        mov cx, 11
        rep movsb
        call tf_log_req
        inc byte [crit]
        call find_file
        jc .th_wrq_new
        mov byte [dir_new], 0
        mov ax, [file_cluster]
        call free_chain                 ; truncate the old file
        jmp .th_wrq_ent
.th_wrq_new:
        call free_dir                   ; reserve a root entry
        jc .th_wrq_nospace
.th_wrq_ent:
        mov word [sv_size], 0
        mov word [sv_first], 0
        mov word [sv_prev], 0
        mov word [sv_secs], 0
        mov word [tf_upfill], 0
        mov byte [recv_full], 0
        call tf_dir_write               ; commit a zero-byte entry now
        jc .th_wrq_ioerr
        dec byte [crit]
        mov word [tf_block], 0
        mov byte [tf_retries], 0
        mov ax, [tf_tsize_val]
        mov [tf_tsize_out], ax
        mov byte [tf_win], 1
        mov byte [tf_have_win], 0
        call tf_send_oack
        mov byte [tf_state], TF_DATA
        jmp .th_out
.th_wrq_nospace:
        dec byte [crit]
        jmp .th_full
.th_wrq_ioerr:
        dec byte [crit]
        jmp .th_full

; ---- RRQ: ACK of the OACK or of a DATA block ----
.th_ack:
        mov byte [tf_retries], 0        ; any ACK clears the consecutive timeout count
        mov si, tf_rxbuf
        mov ax, [si+2]
        xchg al, ah
        cmp byte [tf_state], TF_ACK0
        jne .th_ack_data
        test ax, ax
        jnz .th_out
        mov word [tf_wbase], 1
        mov word [tf_wnext], 1
        mov word [tf_wnum], 0
        mov byte [tf_final], 0
        call tf_win_fill
        mov ax, [tf_tsize_out]
        sub ax, [tf_left]
        mov bx, 1
        call tf_log_prog
        mov byte [tf_state], TF_SEND
        jmp .th_out
.th_ack_data:
        cmp byte [tf_state], TF_SEND
        jne .th_out
        cmp ax, [tf_wbase]
        jb .th_ack_old
        mov bx, [tf_wbase]
        add bx, [tf_wnum]
        cmp ax, bx
        jae .th_out                     ; ACK beyond what was sent
        ; cumulative ACK: drop everything up to and including AX
        mov bx, ax
        sub bx, [tf_wbase]
        inc bx
        mov ax, [tf_wbase]
        add ax, bx
        mov [tf_wbase], ax
        sub [tf_wnum], bx
        cmp word [tf_wnum], 0
        jne .th_ack_fill
        cmp byte [tf_final], 0
        jne .th_done
.th_ack_fill:
        call tf_win_fill
        mov ax, [tf_tsize_out]
        sub ax, [tf_left]
        mov bx, 1
        call tf_log_prog
        jmp .th_out
.th_ack_old:
        call tf_win_resend              ; old ACK: resend the whole window
        jmp .th_out
.th_done:
        mov ax, [tf_tsize_out]
        mov bx, 1
        call tf_log_done
        mov byte [tf_state], 0
        jmp .th_out

; ---- WRQ: DATA blocks ----
.th_data:
        cmp byte [tf_state], TF_DATA
        jne .th_out
        mov si, tf_rxbuf
        mov ax, [si+2]
        xchg al, ah
        mov dx, ax                      ; block
        mov cx, [tf_rxlen]
        sub cx, 4                       ; data bytes
        mov bx, [tf_block]
        inc bx
        cmp dx, bx
        jne .th_dup_chk
        mov bp, cx
        mov [tf_block], dx
        mov si, tf_rxbuf
        add si, 4
        inc byte [crit]
        call tf_put_bytes
        dec byte [crit]
        jc .th_wrerr
        mov ax, [sv_size]
        mov bx, 2
        call tf_log_prog
        mov al, [tf_blk]
        xor ah, ah
        cmp bp, ax
        je .th_data_more
        ; final (short) block: flush the partial sector, link, update entry
        inc byte [crit]
        call tf_put_final
        dec byte [crit]
        jc .th_wrerr
        mov ax, [sv_size]
        mov bx, 2
        call tf_log_done
        mov ax, [tf_block]
        call tf_send_ack
        mov byte [tf_state], 0
        jmp .th_out
.th_data_more:
        mov ax, [tf_block]
        call tf_send_ack
        mov byte [tf_state], TF_DATA
        mov byte [tf_retries], 0
        jmp .th_out
.th_wrerr:
        mov byte [tf_state], 0
        mov si, s_tf_full
        mov al, 3
        jmp .th_err
.th_dup_chk:
        cmp dx, [tf_block]              ; duplicate of the last block
        jne .th_out
        mov ax, dx
        call tf_send_ack
.th_out:
        pop es
        pop di
        pop si
        pop bp
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---------------------------------------------------------------
; helpers
; ---------------------------------------------------------------

tf_send:                                ; send tf_tx[tf_txlen] to tf_dst
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        call ip_tx_flush                ; drain a pending session packet first
        mov bx, TFTP_TID
        mov dx, [tf_dst_port]
        mov di, tf_dst_ip
        mov si, tf_tx
        mov cx, [tf_txlen]
        call udp_build_src
        call ip_tx_flush
        mov ax, [tick_hz]
        shl ax, 1                       ; ~2 s regardless of QUANTUM
        cmp ax, 18
        jae .ts_to
        mov ax, 18
.ts_to:
        mov [tf_to], ax
        mov ax, [ticks]
        mov [tf_last_tx], ax
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tf_send_ack:                            ; AX = block
        push di
        mov di, tf_tx
        mov byte [di], 0
        mov byte [di+1], 4
        xchg al, ah
        mov [di+2], ax
        mov word [tf_txlen], 4
        call tf_send
        pop di
        ret

tf_send_oack:
        push ax
        push cx
        push di
        push si
        mov di, tf_tx
        mov byte [di], 0
        mov byte [di+1], 6
        add di, 2
        mov si, s_blksize
        call tf_copyz                   ; name + NUL
        mov al, [tf_blk]
        xor ah, ah
        call tf_dec
        mov byte [di], 0
        inc di
        cmp byte [tf_tsize], 0
        je .to_done
        mov si, s_tsize
        call tf_copyz
        mov ax, [tf_tsize_out]
        call tf_dec
        mov byte [di], 0
        inc di
        cmp byte [tf_have_win], 0
        je .to_done
        cmp byte [tf_op], 1
        jne .to_done
        mov si, s_windowsize
        call tf_copyz
        mov al, [tf_win]
        xor ah, ah
        call tf_dec
        mov byte [di], 0
        inc di
.to_done:
        mov ax, di
        sub ax, tf_tx
        mov [tf_txlen], ax
        call tf_send
        pop si
        pop di
        pop cx
        pop ax
        ret

tf_copyz:                               ; SI -> ES:DI including NUL
        lodsb
        stosb
        test al, al
        jnz tf_copyz
        ret

tf_dec:                                 ; AX -> decimal at ES:DI
        push ax
        push bx
        push cx
        push dx
        mov bx, 10
        xor cx, cx
.td_l:
        xor dx, dx
        div bx
        push dx
        inc cx
        test ax, ax
        jnz .td_l
.td_p:
        pop ax
        add al, '0'
        stosb
        loop .td_p
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tf_parse_dec:                           ; SI -> digits; AX = value, SI at NUL
        push bx
        push cx
        push dx
        xor bx, bx
        xor cx, cx
.tp_l:
        mov al, [si]
        cmp al, '0'
        jb .tp_d
        cmp al, '9'
        ja .tp_d
        sub al, '0'
        xor ah, ah
        push ax
        mov ax, bx
        mov dx, 10
        mul dx
        mov bx, ax
        pop ax
        add bx, ax
        inc si
        inc cx
        cmp cx, 5
        jb .tp_l
.tp_d:
        mov ax, bx
        pop dx
        pop cx
        pop bx
        ret

tf_error_peer:                          ; AL = code, SI = NUL message
        push ax
        push cx
        push di
        push si
        mov di, tf_tx
        mov byte [di], 0
        mov byte [di+1], 5
        xor ah, ah
        mov [di+2], ah
        mov [di+3], al
        add di, 4
.tf_ec:
        lodsb
        stosb
        test al, al
        jnz .tf_ec
        mov ax, di
        sub ax, tf_tx
        mov [tf_txlen], ax
        call tf_send
        pop si
        pop di
        pop cx
        pop ax
        ret

tf_error_q:                            ; like tf_error_peer, to the requester
        push ax
        mov ax, [tf_qip]
        mov [tf_dst_ip], ax
        mov ax, [tf_qip+2]
        mov [tf_dst_ip+2], ax
        mov ax, [tf_qport]
        mov [tf_dst_port], ax
        pop ax
        jmp tf_error_peer

tf_win_fill:                           ; send up to tf_win blocks
        push ax
        push bx
        push cx
        push dx
        push si
        push di
.twf_l:
        cmp byte [tf_final], 0
        jne .twf_done
        mov ax, [tf_wnum]
        mov bl, [tf_win]
        xor bh, bh
        cmp ax, bx
        jae .twf_done
        call tf_emit
        jmp .twf_l
.twf_done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tf_emit:                               ; send block tf_wnext, buffer it
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov ax, [tf_wnext]
        mov di, tf_tx
        mov byte [di], 0
        mov byte [di+1], 3
        xchg al, ah
        mov [di+2], ax
        add di, 4
        mov cl, [tf_blk]
        xor ch, ch
        call tf_fill                    ; AX = data bytes, DI advanced
        mov [tf_last_len], ax
        mov [tf_txlen], ax
        add word [tf_txlen], 4
        ; slot = (wnext - wbase) & 3
        mov bx, [tf_wnext]
        sub bx, [tf_wbase]
        and bx, 3
        mov [tf_wlen+bx], al
        ; copy the data into the window slot
        push ax                         ; length
        push dx
        mov ax, 192
        mul bx
        mov di, ax
        push es
        mov ax, TFBUF_SEG
        mov es, ax
        mov si, tf_tx
        add si, 4
        pop dx
        pop cx
        rep movsb
        pop es
        mov ax, KERNEL_SEG
        mov es, ax
        call tf_send
        inc word [tf_wnext]
        inc word [tf_wnum]
        mov ax, [tf_last_len]
        mov bl, [tf_blk]
        xor bh, bh
        cmp ax, bx
        jae .te_done
        mov byte [tf_final], 1
.te_done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tf_win_resend:                         ; resend every in-flight block
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov cx, [tf_wnum]
        jcxz .twr_done
        mov dx, [tf_wbase]
.twr_l:
        push cx
        mov ax, dx
        sub ax, [tf_wbase]
        and ax, 3
        mov bx, ax                      ; slot
        mov di, tf_tx
        mov byte [di], 0
        mov byte [di+1], 3
        mov ax, dx
        xchg al, ah
        mov [di+2], ax
        mov cl, [tf_wlen+bx]
        xor ch, ch
        mov [tf_txlen], cx
        add word [tf_txlen], 4
        push dx
        mov ax, 192
        mul bx
        mov si, ax
        push ds
        mov ax, TFBUF_SEG
        mov ds, ax
        mov di, tf_tx
        add di, 4
        rep movsb
        pop ds
        pop dx
        call tf_send
        inc dx
        pop cx
        loop .twr_l
.twr_done:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tf_put_bytes:                          ; SI=data, CX=len -> stream to disk
        push ax
        push bx
        push cx
        push dx
        push si
        push di
.tpb_l:
        jcxz .tpb_done
        cmp word [sv_first], 0
        jne .tpb_have
        call alloc_cluster
        jc .tpb_full
        mov [sv_first], ax
        mov [sv_prev], ax
        mov [sv_cur], ax
        call recv_lba_for_cur
        mov al, [sec_per_clus]
        xor ah, ah
        mov [sv_secs], ax
.tpb_have:
        mov ax, 512
        sub ax, [tf_upfill]
        cmp ax, cx
        jbe .tpb_n
        mov ax, cx
.tpb_n:
        mov dx, ax
        mov di, secbuf
        add di, [tf_upfill]
        push cx
        mov cx, dx
        rep movsb
        pop cx
        sub cx, dx
        add [tf_upfill], dx
        add [sv_size], dx
        cmp word [sv_size], 65000
        ja .tpb_full
        cmp word [tf_upfill], 512
        jb .tpb_l
        call recv_write                 ; flush the full sector
        jc .tpb_err
        mov word [tf_upfill], 0
        cmp byte [recv_full], 0
        jne .tpb_full
        call tf_dir_write               ; keep a partial upload consistent
        jc .tpb_err
        jmp .tpb_l
.tpb_done:
        clc
        jmp .tpb_out
.tpb_err:
        stc
        jmp .tpb_out
.tpb_full:
        stc
.tpb_out:
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tf_put_final:
        push ax
        push cx
        push di
        cmp word [tf_upfill], 0
        je .tpf_link
        mov cx, 512
        sub cx, [tf_upfill]
        mov di, secbuf
        add di, [tf_upfill]
        xor al, al
        rep stosb
        call recv_write
        jc .tpf_err
        mov word [tf_upfill], 0
.tpf_link:
        cmp word [sv_first], 0
        je .tpf_ent
        mov ax, [sv_prev]
        mov dx, 0xFFFF
        call fat_set
.tpf_ent:
        call tf_dir_write
        jc .tpf_err
        clc
        jmp .tpf_out
.tpf_err:
        stc
.tpf_out:
        pop di
        pop cx
        pop ax
        ret

tf_dir_write:                           ; commit sv_first/sv_size to the entry
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, KERNEL_SEG
        mov es, ax
        inc byte [crit]
        mov ax, [ent_lba]
        call hdd_read
        jc .tdw_err
        mov di, secbuf
        add di, [ent_off]
        mov si, tf_name83
        mov cx, 11
        rep movsb
        mov al, 0x20
        stosb
        xor cx, cx
.tdw_z:
        xor al, al
        stosb
        inc cx
        cmp cx, 20
        jb .tdw_z
        mov di, secbuf
        add di, [ent_off]
        mov ax, [sv_first]
        mov [di+26], ax
        mov ax, [sv_size]
        mov [di+28], ax
        xor ax, ax
        mov [di+30], ax
        mov ax, [ent_lba]
        call hdd_write
        jc .tdw_err
        dec byte [crit]
        clc
        jmp .tdw_out
.tdw_err:
        dec byte [crit]
        stc
.tdw_out:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

tf_log_copy:                            ; SI -> ES:DI, DI left at the NUL
        lodsb
        stosb
        test al, al
        jnz tf_log_copy
        dec di
        ret

tf_log_flush:                           ; DI = NUL; CGA + optional SYSTEM slot
        push ax
        push bx
        push si
        mov byte [di], 0
        mov bl, [cur_task]
        xor bh, bh
        mov al, [task_out+bx]
        mov [tf_saved_out], al
        mov byte [task_out+bx], 0
        mov si, tf_log_buf
        call puts
        mov al, 10
        call putc
        mov bl, [cur_task]
        xor bh, bh
        mov al, [tf_saved_out]
        mov [task_out+bx], al
        mov bl, [tftp_log_slot]
        test bl, bl
        jz .tlf_ret
        mov si, tf_log_buf
        call slot_str
        mov al, 13
        call tx_slot_append
        mov al, 10
        call tx_slot_append
.tlf_ret:
        pop si
        pop bx
        pop ax
        ret

tf_log_req:                             ; request line: TFTP GET|PUT name
        cmp byte [tftp_log], 0
        je .tlr_ret
        push ax
        push di
        push si
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, tf_log_buf
        mov si, s_tftp_prefix
        call tf_log_copy
        cmp byte [tf_op], 1
        jne .tlr_put
        mov si, s_tftp_get
        jmp .tlr_v
.tlr_put:
        mov si, s_tftp_put
.tlr_v:
        call tf_log_copy
        mov si, tf_name
        call tf_log_copy
        call tf_log_flush
        mov word [tf_log_next], 4096
        pop si
        pop di
        pop ax
.tlr_ret:
        ret

tf_log_prog:                            ; AX=bytes, BX=1 GET / 2 PUT
        cmp byte [tftp_log], 0
        je .tlp_ret
        cmp ax, [tf_log_next]
        jb .tlp_ret
        push ax
        push bx
        push di
        push si
        mov [tf_log_num], ax
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, tf_log_buf
        mov si, s_tftp_prefix
        call tf_log_copy
        cmp bl, 1
        jne .tlp_put
        mov si, s_tftp_get
        jmp .tlp_v
.tlp_put:
        mov si, s_tftp_put
.tlp_v:
        call tf_log_copy
        mov si, tf_name
        call tf_log_copy
        mov al, ' '
        stosb
        mov ax, [tf_log_num]
        call tf_dec
        call tf_log_flush
        add word [tf_log_next], 4096
        pop si
        pop di
        pop bx
        pop ax
.tlp_ret:
        ret

tf_log_done:                            ; AX=size, BX=1 GET / 2 PUT
        cmp byte [tftp_log], 0
        je .tld_ret
        push ax
        push bx
        push di
        push si
        mov [tf_log_num], ax
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, tf_log_buf
        mov si, s_tftp_prefix
        call tf_log_copy
        cmp bl, 1
        jne .tld_put
        mov si, s_tftp_get
        jmp .tld_v
.tld_put:
        mov si, s_tftp_put
.tld_v:
        call tf_log_copy
        mov si, tf_name
        call tf_log_copy
        mov si, s_tftp_done
        call tf_log_copy
        mov ax, [tf_log_num]
        call tf_dec
        call tf_log_flush
        pop si
        pop di
        pop bx
        pop ax
.tld_ret:
        ret

tf_log_err:                             ; AL=code
        cmp byte [tftp_log], 0
        je .tle_ret
        push ax
        push di
        push si
        mov [tf_log_num], ax
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, tf_log_buf
        mov si, s_tftp_prefix
        call tf_log_copy
        mov si, s_tftp_err
        call tf_log_copy
        mov si, tf_name
        call tf_log_copy
        mov al, ' '
        stosb
        mov ax, [tf_log_num]
        xor ah, ah
        call tf_dec
        call tf_log_flush
        pop si
        pop di
        pop ax
.tle_ret:
        ret

tf_fill:                                ; ES:DI dest, CX max -> AX bytes
        push bx
        push cx
        push dx
        push si
        xor bx, bx
.tf_l:
        test cx, cx
        jz .tf_d
        cmp word [tf_left], 0
        je .tf_d
        cmp word [tf_off], 512
        jb .tf_have
        inc word [tf_sec]
        mov al, [sec_per_clus]
        xor ah, ah
        cmp word [tf_sec], ax
        jb .tf_lba
        mov ax, [tf_cluster]
        mov [cur_cluster], ax
        call fat_next
        jc .tf_d
        mov [tf_cluster], ax
        mov word [tf_sec], 0
.tf_lba:
        push cx                         ; CX = bytes still wanted for this block
        mov ax, [tf_cluster]
        sub ax, 2
        mov cl, [sec_per_clus]
        xor ch, ch
        mul cx
        add ax, [data_lba]
        add ax, [tf_sec]
        inc byte [crit]
        call hdd_read
        dec byte [crit]
        pop cx                          ; pop/inc/dec leave CF alone
        jc .tf_d
        mov word [tf_off], 0
.tf_have:
        mov ax, 512
        sub ax, [tf_off]
        cmp ax, cx
        jbe .tf_n1
        mov ax, cx
.tf_n1:
        cmp ax, [tf_left]
        jbe .tf_n2
        mov ax, [tf_left]
.tf_n2:
        mov dx, ax
        mov si, secbuf
        add si, [tf_off]
        push cx
        mov cx, dx
        rep movsb
        pop cx
        sub cx, dx
        add bx, dx
        add word [tf_off], dx
        sub word [tf_left], dx
        jmp .tf_l
.tf_d:
        mov ax, bx
        pop si
        pop dx
        pop cx
        pop bx
        ret

tf_build83:                             ; SI = name -> namebuf, no default ext
        push ax
        push cx
        push di
        mov di, namebuf
        mov cx, 11
.tb_fill:
        mov al, ' '
        stosb
        loop .tb_fill
        mov di, namebuf
        xor cx, cx
.tb_base:
        lodsb
        test al, al
        jz .tb_done
        cmp al, '.'
        je .tb_exts
        cmp cx, 8
        jae .tb_bskip
        call upcase
        mov [di], al
        inc di
        inc cx
.tb_bskip:
        jmp .tb_base
.tb_exts:
        mov di, namebuf+8
        xor cx, cx
.tb_ext:
        lodsb
        test al, al
        jz .tb_done
        cmp cx, 3
        jae .tb_done
        call upcase
        mov [di], al
        inc di
        inc cx
        jmp .tb_ext
.tb_done:
        pop di
        pop cx
        pop ax
        ret

do_tftplog:
        push ax
        push bx
        push si
        call check_elev
        cmp al, 0
        je .go
        cmp al, 1
        jne .priv
        mov si, s_tftp_conly
        call puts
        jmp .ret
.priv:
        mov si, s_priv_req
        call puts
        jmp .ret
.go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .set
        mov si, s_tftplog_state
        call puts
        cmp byte [tftp_log], 0
        je .off
        mov si, s_on
        jmp .pr
.off:
        mov si, s_offstr
.pr:
        call puts
        mov al, 10
        call putc
        jmp .ret
.set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .ret
        inc si
        mov al, [si]
        call upcase
        cmp al, 'N'
        je .on
        cmp al, 'F'
        jne .ret
        mov byte [tftp_log], 0
        mov byte [tftp_log_slot], 0
        jmp .report
.on:
        mov byte [tftp_log], 1
        mov al, [cur_task]
        mov [tftp_log_slot], al
.report:
        mov si, s_tftplog_state
        call puts
        cmp byte [tftp_log], 0
        je .roff
        mov si, s_on
        jmp .rpr
.roff:
        mov si, s_offstr
.rpr:
        call puts
        mov al, 10
        call putc
.ret:
        pop si
        pop bx
        pop ax
        ret

; Console command: TFTP [ON|OFF]  (console only, default OFF)
do_tftp:
        push ax
        push si
        cmp byte [cur_task], 0
        je .dt_go
        mov si, s_tftp_conly
        call puts
        jmp .dt_ret
.dt_go:
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .dt_set
        mov si, s_tftp_state
        call puts
        cmp byte [tf_enabled], 0
        je .dt_off
        mov si, s_on
        jmp .dt_pr
.dt_off:
        mov si, s_offstr
.dt_pr:
        call puts
        mov al, 10
        call putc
        jmp .dt_ret
.dt_set:
        mov al, [si]
        call upcase
        cmp al, 'O'
        jne .dt_ret
        inc si
        mov al, [si]
        call upcase
        cmp al, 'N'
        je .dt_on
        cmp al, 'F'
        jne .dt_ret
        mov byte [tf_enabled], 0
        mov byte [tf_state], 0
        mov byte [tf_pending], 0
        jmp .dt_report
.dt_on:
        mov byte [tf_enabled], 1
.dt_report:
        mov si, s_tftp_state
        call puts
        cmp byte [tf_enabled], 0
        je .dt_roff
        mov si, s_on
        jmp .dt_rpr
.dt_roff:
        mov si, s_offstr
.dt_rpr:
        call puts
        mov al, 10
        call putc
        cmp byte [tf_enabled], 0
        je .dt_ret
        mov si, s_tftp_hint
        call puts
.dt_ret:
        pop si
        pop ax
        ret

; =====================================================================
; Web session: wait for an HTTP request, send INDEX.HTM from the
; mounted volume, then ask the bridge to close the TCP connection.
; =====================================================================


; ===== upload session (app 3): "PUT NAME SIZE\n" + raw bytes =====
upload_entry:
        mov ax, [ticks]
        mov [web_start], ax
        call upload_run
        mov bl, [cur_task]
        xor bh, bh
        mov dl, [task_term+bx]
        mov al, 0x03
        call mux_send_ctl
        mov bl, [cur_task]
        xor bh, bh
        mov byte [task_state+bx], 0
        mov byte [task_term+bx], 0
        mov byte [task_app+bx], 0
.ue:
        mov ah, 7
        int 0x60
        jmp .ue

upload_run:
        xor cx, cx
.uh:
        call web_getc
        jc .u_io
        cmp al, 13
        je .uh
        cmp al, 10
        je .uhd
        cmp cx, 40
        jae .uh
        mov di, up_hdr
        add di, cx
        mov [di], al
        inc cx
        jmp .uh
.uhd:
        mov di, up_hdr
        add di, cx
        mov byte [di], 0
        mov si, up_hdr
        call skip_sp
        mov al, [si]
        call upcase
        cmp al, 'P'
        jne .u_syn
        inc si
        mov al, [si]
        call upcase
        cmp al, 'U'
        jne .u_syn
        inc si
        mov al, [si]
        call upcase
        cmp al, 'T'
        jne .u_syn
        inc si
        call skip_sp
        mov di, up_name
        xor cx, cx
.un:
        mov al, [si]
        test al, al
        jz .u_syn
        cmp al, ' '
        je .une
        cmp cx, 12
        jae .uns
        call upcase
        mov [di], al
        inc di
        inc cx
.uns:
        inc si
        jmp .un
.une:
        mov byte [di], 0
        call skip_sp
        xor bx, bx
        xor cx, cx
.usz:
        mov al, [si]
        cmp al, '0'
        jb .usze
        cmp al, '9'
        ja .usze
        sub al, '0'
        xor ah, ah
        push ax
        mov ax, bx
        mov dx, 10
        mul dx
        mov bx, ax
        pop ax
        add bx, ax
        inc cx
        inc si
        cmp cx, 5
        jb .usz
.usze:
        test bx, bx
        jz .u_syn
        cmp bx, 8192
        ja .u_big
        mov [up_size], bx
        cmp byte [write_ok], 0
        jne .urd
        mov si, s_up_off
        call puts
        ret
.urd:
        xor di, di
        mov cx, bx
.url:
        jcxz .uw
        push cx
        call web_getc
        pop cx
        jc .u_io
        push ds
        push ax
        mov ax, BUF_SEG
        mov ds, ax
        mov [di], al
        pop ax
        pop ds
        inc di
        dec cx
        jmp .url
.uw:
        mov si, up_name
        call build83
        inc byte [crit]
        mov word [sv_src], UPBUF_OFF
        mov word [sv_src_seg], BUF_SEG
        mov ax, [up_size]
        mov [sv_size], ax
        call write_file
        dec byte [crit]
        jc .u_werr
        mov si, s_up_ok
        call puts
        mov ax, [up_size]
        call put_dec
        mov si, s_up_bytes
        call puts
        ret
.u_io:
        mov si, s_up_io
        call puts
        ret
.u_big:
        mov si, s_up_big
        call puts
        ret
.u_werr:
        mov si, s_up_werr
        call puts
        ret
.u_syn:
        mov si, s_up_syn
        call puts
        ret

web_entry:
        call web_serve
        mov bl, [cur_task]
        xor bh, bh
        mov dl, [task_term+bx]
        mov al, 0x03
        call mux_send_ctl
        mov bl, [cur_task]
        xor bh, bh
        mov byte [task_state+bx], 0
        mov byte [task_term+bx], 0
        mov byte [task_app+bx], 0
.web_dead:
        mov ah, 7
        int 0x60
        jmp .web_dead

; read one byte from this session's mux ring; CF=1 on timeout/close
web_getc:
        push bx
        push cx
        push di
        mov bl, [cur_task]
        xor bh, bh
.wg_l:
        cmp byte [task_state+bx], 0
        je .wg_fail
        mov al, [rx_head+bx]
        cmp al, [rx_tail+bx]
        jne .wg_got
        mov ax, [ticks]
        sub ax, [web_start]
        cmp ax, 600
        ja .wg_fail
        call mux_poll
        cmp byte [task_state+bx], 0
        je .wg_fail
        mov al, [rx_head+bx]
        cmp al, [rx_tail+bx]
        jne .wg_got
        push bx
        mov ah, 7
        int 0x60
        pop bx
        jmp .wg_l
.wg_got:
        mov ax, bx
        mov cl, 8
        shl ax, cl
        mov di, rx_buf
        add di, ax
        mov al, [rx_head+bx]
        xor ah, ah
        add di, ax
        mov al, [di]
        inc byte [rx_head+bx]
        and byte [rx_head+bx], MUX_RX_SIZE-1
        clc
        jmp .wg_d
.wg_fail:
        stc
.wg_d:
        pop di
        pop cx
        pop bx
        ret

; wait for CRLFCRLF (or 2 KB), then serve the page
web_serve:
        mov byte [web_state], 0
        mov byte [web_ps], 0
        mov byte [web_pi], 0
        mov byte [web_path], 0
        mov byte [web_rl_len], 0
        mov byte [web_rl_done], 0
        mov byte [web_reqline], 0
        mov word [web_count], 0
        mov byte [web_method], 'G'
        mov ax, [ticks]
        mov [web_start], ax
.wr:
        call web_getc
        jc .done
        cmp word [web_count], 0
        jne .wm
        mov [web_method], al            ; first request byte: method initial
.wm:
        call web_path_byte
        cmp byte [web_log], 0
        je .nolog
        cmp byte [web_rl_done], 0
        jne .nolog
        cmp al, 13
        je .rldone
        cmp al, 10
        je .rldone
        cmp al, 32
        jb .nolog
        mov cl, [web_rl_len]
        cmp cl, 39
        jae .nolog
        mov di, web_reqline
        xor ch, ch
        add di, cx
        mov [di], al
        mov byte [di+1], 0
        inc byte [web_rl_len]
        jmp .nolog
.rldone:
        mov byte [web_rl_done], 1
.nolog:
        mov cl, [web_state]
        cmp cl, 0
        je .st0
        cmp cl, 1
        je .st1
        cmp cl, 2
        je .st2
        cmp al, 10
        jne .reset
        jmp .have
.st0:
        cmp al, 13
        jne .next
        mov byte [web_state], 1
        jmp .next
.st1:
        cmp al, 10
        je .st1ok
        cmp al, 13
        je .next
        jmp .reset
.st1ok:
        mov byte [web_state], 2
        jmp .next
.st2:
        cmp al, 13
        jne .reset
        mov byte [web_state], 3
        jmp .next
.reset:
        mov byte [web_state], 0
        cmp al, 13
        jne .next
        mov byte [web_state], 1
.next:
        inc word [web_count]
        cmp word [web_count], 2048
        jb .wr
.have:
        call web_log_request
        cmp byte [web_enabled], 0
        jne .serve
        mov si, s_http_503
        call web_send_str
        ret
.serve:
        cmp byte [web_path], '/'
        jne .notapi
        cmp byte [web_path+1], 'a'
        jne .notapi
        cmp byte [web_path+2], 'p'
        jne .notapi
        cmp byte [web_path+3], 'i'
        jne .notapi
        cmp byte [api_ok], 0
        je .badpath
        mov si, web_path
        mov al, [web_method]            ; AL = 'G' / 'P' / 'D'
        mov bx, cs
        push bx
        mov bx, .api_ret
        push bx
        mov bx, API_SEG
        push bx
        xor bx, bx
        push bx
        retf
.api_ret:
        jmp .done
.notapi:
        mov si, web_path+1              ; skip the leading '/'
        cmp byte [si], 0
        jne .wfn
        mov si, s_web_index            ; "/" -> INDEX.HTM
.wfn:
        inc byte [crit]
        call build83
        call find_file
        jc .nf
        mov ax, [file_size]
        cmp ax, 4000
        ja .nf
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, savebuf
        mov cx, 4000
        call load_file
        jc .nf
        mov [web_len], dx
        dec byte [crit]
        call web_send_ok
        mov si, savebuf
        mov cx, [web_len]
        call web_send_buf
        ret
.nf:
        dec byte [crit]
.badpath:
        ; any other request: serve 404.HTM if it is on C:
        inc byte [crit]
        mov si, s_web_404file
        call build83
        call find_file
        jc .nf404
        mov ax, KERNEL_SEG
        mov es, ax
        mov bx, savebuf
        mov cx, 4000
        call load_file
        jc .nf404
        mov [web_len], dx
        dec byte [crit]
        call web_send_404
        mov si, savebuf
        mov cx, [web_len]
        call web_send_buf
        ret
.nf404:
        dec byte [crit]
        mov si, s_http_404
        call web_send_str
.done:
        ret

; collect the request-target after the method
web_path_byte:
        push ax
        push cx
        push di
        mov cl, [web_ps]
        cmp cl, 0
        jne .pb1
        cmp al, ' '
        jne .pb_d
        mov byte [web_ps], 1
        jmp .pb_d
.pb1:
        cmp cl, 1
        jne .pb_d
        cmp al, ' '
        je .pb_end
        cmp al, 13
        je .pb_end
        cmp byte [web_pi], 39
        jae .pb_d
        mov di, web_path
        mov cl, [web_pi]
        xor ch, ch
        add di, cx
        mov [di], al
        inc byte [web_pi]
        jmp .pb_d
.pb_end:
        mov byte [web_ps], 2
        mov di, web_path
        mov cl, [web_pi]
        xor ch, ch
        add di, cx
        mov byte [di], 0
.pb_d:
        pop di
        pop cx
        pop ax
        ret

; print the request line on the CGA console when WEBLOG is on
web_log_request:
        cmp byte [web_log], 0
        je .ret
        cmp byte [web_rl_len], 0
        je .ret
        mov bl, [cur_task]
        xor bh, bh
        mov al, [task_out+bx]
        mov [web_saved_out], al
        mov byte [task_out+bx], 0
        push si
        mov si, s_web_state
        call puts
        mov si, web_reqline
        call puts
        mov al, 10
        call putc
        pop si
        mov bl, [cur_task]
        xor bh, bh
        mov al, [web_saved_out]
        mov [task_out+bx], al
        ; Mirror the log line to the session that enabled it, but only if that
        ; session is a SYSTEM login with privileges on.
        mov bl, [web_log_slot]
        test bl, bl
        jz .ret
        cmp byte [web_log_serial], 0
        je .ret
        cmp byte [priv_on], 0
        je .ret
        push bx
        mov al, bl
        call user_ptr_slot
        mov si, di
        mov di, s_admin_user
        call streq
        pop bx
        cmp al, 1
        jne .ret
        mov bl, [web_log_slot]         ; never draw a log line over the chat
        xor bh, bh
        cmp byte [cs_mode+bx], 0
        jne .ret
        push si
        mov si, s_web_state
        call slot_str
        mov si, web_reqline
        call slot_str
        mov al, 13
        call tx_slot_append
        mov al, 10
        call tx_slot_append
        pop si
.ret:
        ret

; AL=1 when the target is /, /index.htm or /index.html
; send a NUL-terminated string as DATA frames
web_send_str:
        push si
        mov di, si
        xor cx, cx
.ws_l:
        cmp byte [di], 0
        je .ws_d
        inc di
        inc cx
        jmp .ws_l
.ws_d:
        call web_send_buf
        pop si
        ret

; send SI/CX (<= 120 bytes per frame) to this session's terminal
web_send_buf:
        push ax
        push bx
        push cx
        push dx
        push si
        mov bl, [cur_task]
        xor bh, bh
        mov dl, [task_term+bx]
.wb_l:
        jcxz .wb_d
        mov ax, cx
        cmp ax, 120
        jbe .wb_c
        mov ax, 120
.wb_c:
        push ax
        push cx
        mov cx, ax
        mov al, 1
        inc byte [crit]
        call mux_send_frame
        dec byte [crit]
        pop cx
        pop ax
        add si, ax
        sub cx, ax
        jmp .wb_l
.wb_d:
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; 200 OK header: fixed prefix, decimal length, terminator
web_send_ok:
        mov si, s_http_ok
        jmp web_send_hdr
web_send_404:
        mov si, s_http_404hdr
web_send_hdr:
        call web_send_str
        push es
        mov ax, ds
        mov es, ax
        mov di, web_num
        mov ax, [web_len]
        call dec_to_buf
        pop es
        mov cx, di
        sub cx, web_num
        mov si, web_num
        call web_send_buf
        mov si, s_http_end
        call web_send_str
        ret

; =====================================================================
; RAM disk (64 KB, FAT12) - DRIVE M
; =====================================================================

dec_to_buf:                     ; AX = value, DI = buffer -> decimal, DI advanced
        push ax
        push bx
        push cx
        push dx
        mov bx, 10
        xor cx, cx
.dt_l:
        xor dx, dx
        div bx
        push dx
        inc cx
        test ax, ax
        jnz .dt_l
.dt_o:
        pop ax
        add al, '0'
        stosb
        loop .dt_o
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ram_read:                       ; AX = LBA -> secbuf
        cmp ax, RAMSECT
        jae .err
        push ax
        push bx
        push cx
        push si
        push di
        push ds
        push es
        mov bx, ax
        mov cl, 9
        shl bx, cl
        mov ax, RAMSEG
        mov ds, ax
        mov si, bx
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, secbuf
        mov cx, 512
        rep movsb
        pop es
        pop ds
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        clc
        ret
.err:
        stc
        ret

ram_write:                      ; AX = LBA, secbuf -> RAM
        cmp ax, RAMSECT
        jae .err
        push ax
        push bx
        push cx
        push si
        push di
        push ds
        push es
        mov bx, ax
        mov cl, 9
        shl bx, cl
        mov ax, KERNEL_SEG
        mov ds, ax
        mov si, secbuf
        mov ax, RAMSEG
        mov es, ax
        mov di, bx
        mov cx, 512
        rep movsb
        pop es
        pop ds
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        clc
        ret
.err:
        stc
        ret

; build an empty FAT12 volume in RAM: 128 sectors, 1 sec/cluster
ram_format:
        push ax
        push cx
        push di
        push si
        push es
        mov ax, RAMSEG
        mov es, ax
        xor di, di
        mov cx, RAMSECT*256
        xor ax, ax
        rep stosw
        mov ax, RAMSEG
        mov es, ax
        mov di, 0
        mov al, 0xEB
        stosb
        mov al, 0x3C
        stosb
        mov al, 0x90
        stosb
        mov si, s_ram_oem
        mov cx, 8
        rep movsb
        mov di, 11
        mov ax, 512
        stosw
        mov di, 13
        mov al, 1
        stosb
        mov di, 14
        mov ax, 1
        stosw
        mov di, 16
        mov al, 2
        stosb
        mov di, 17
        mov ax, 32
        stosw
        mov di, 19
        mov ax, RAMSECT
        stosw
        mov di, 21
        mov al, 0xF8
        stosb
        mov di, 22
        mov ax, 1
        stosw
        mov di, 24
        mov ax, 9
        stosw
        mov di, 26
        mov ax, 2
        stosw
        mov di, 510
        mov ax, 0xAA55
        stosw
        mov di, 512
        mov al, 0xF8
        stosb
        mov al, 0xFF
        stosb
        stosb
        mov di, 1024
        mov al, 0xF8
        stosb
        mov al, 0xFF
        stosb
        stosb
        pop es
        pop si
        pop di
        pop cx
        pop ax
        ret

; =====================================================================
; Kernel API - INT 60h
; =====================================================================

; set/clear CF in the caller's saved FLAGS (no [sp+x] on 8086)
set_cf_ret:
        push bp
        mov bp, sp
        or word [bp+8], 1
        pop bp
        ret
clr_cf_ret:
        push bp
        mov bp, sp
        and word [bp+8], 0xFFFE
        pop bp
        ret

int60:
        cld
        cmp ah, 0
        je .putc
        cmp ah, 1
        je .puts
        cmp ah, 2
        je .putdec
        cmp ah, 4
        je .loadf
        cmp ah, 5
        je .readlba
        cmp ah, 6
        je .fsinfo
        cmp ah, 7
        je api_yield
        cmp ah, 8
        je api_exit
        cmp ah, 9
        je .ticks
        cmp ah, 22
        je .syscnt
        cmp ah, 24
        je .sessinfo
        cmp ah, 25
        je .taskinfo
        cmp ah, 27
        je .userinfo
        cmp ah, 28
        je .speedinfo
        cmp ah, 29
        je .statusinfo
        cmp ah, 30
        je .chatinfo
        cmp ah, 31
        je .pacesend
        cmp ah, 32
        je .pollch
        cmp ah, 36
        je .apictl
        cmp ah, 33
        je .taskmeta
        cmp ah, 34
        je .chatpost
        cmp ah, 35
        je .chatnext
        cmp ah, 37
        je .chatflag

        cmp ah, 10
        je .getc
        cmp ah, 11
        je .runcmd
        cmp ah, 12
        je .savef
        cmp ah, 13
        je .mount
        cmp ah, 14
        je .brk
        cmp ah, 15
        je .cls
        cmp ah, 20
        je .sendslot

        cmp ah, 16
        je .ovl_lock
        cmp ah, 17
        je .ovl_unlock
        cmp ah, 18
        je .ver
        cmp ah, 19
        je .sendip
        call set_cf_ret
        iret
.sendip:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push ds
        mov ax, KERNEL_SEG
        mov ds, ax
        mov di, ipbuf
        xor bx, bx
.sp_l:
        test cx, cx
        jz .sp_d
        mov al, [es:si]
        mov [di], al
        inc si
        inc di
        inc bx
        dec cx
        jmp .sp_l
.sp_d:
        mov byte [ip_tx_pending], 1
        call ip_tx_flush
        pop ds
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        call clr_cf_ret
        iret

.putc:
        call putc
        call clr_cf_ret
        iret
.puts:
        push ax
        push si
        call puts
        pop si
        pop ax
        call clr_cf_ret
        iret
.putdec:
        push ax
        push bx
        push cx
        push dx
        mov ax, bx
        call put_dec
        pop dx
        pop cx
        pop bx
        pop ax
        call clr_cf_ret
        iret
.flushcur:
        push ds
        push bx
        mov ax, KERNEL_SEG
        mov ds, ax
        mov bl, [cur_task]
        xor bh, bh
        call mux_flush
        pop bx
        pop ds
        call clr_cf_ret
        iret
.chatinfo:                      ; AL=slot -> CF=0, AX=nick offset
        push bx
        push ds
        mov bx, KERNEL_SEG
        mov ds, bx
        cmp al, 13
        jae .cif_no
        mov bl, al
        xor bh, bh
        cmp byte [chat_on+bx], 0
        je .cif_no
        mov al, bl
        mov bl, 10
        mul bl
        add ax, chat_nick
        pop ds
        pop bx
        call clr_cf_ret
        iret
.cif_no:
        pop ds
        pop bx
        call set_cf_ret
        iret
.chatflag:                      ; AH=37 -> AX=chat_enabled (0/1)
        push ds
        mov ax, KERNEL_SEG
        mov ds, ax
        mov al, [chat_enabled]
        xor ah, ah
        pop ds
        call clr_cf_ret
        iret
.chatpost:                      ; AH=34: DS:SI="nick\0text" -> AX=seq (CF=1,AL=1 bad)
        push bx
        push cx
        push dx
        push si
        push di
        push ds                        ; caller DS (restored at .cp_ret)
        push es                        ; caller ES
        mov ax, KERNEL_SEG
        mov es, ax
        ; DI = chat_nick + cur_task*10 (ES=kernel, DS=caller)
        mov al, [es:cur_task]
        xor ah, ah
        mov bl, 10
        mul bl
        add ax, chat_nick
        mov di, ax
        mov cx, 9
.cp_nk:
        lodsb
        test al, al
        jz .cp_nke
        stosb
        dec cx
        jnz .cp_nk
.cp_nke:
        mov byte [es:di], 0
        mov di, chat_out2              ; text -> chat_out2 (chat_broadcast writes chat_out)
        mov cx, 50
.cp_tx:
        lodsb
        test al, al
        jz .cp_txe
        stosb
        dec cx
        jnz .cp_tx
.cp_txe:
        mov byte [es:di], 0
        mov al, [es:cur_task]          ; join the room for the broadcast
        xor ah, ah
        mov bx, ax
        mov byte [es:chat_on+bx], 1
        pop es
        mov ax, KERNEL_SEG            ; DS = kernel for chat_broadcast
        mov ds, ax
        mov si, chat_out2
        call chat_broadcast
        mov al, [cur_task]             ; leave again (web slots have no nick)
        xor ah, ah
        mov bx, ax
        mov byte [chat_on+bx], 0
        mov al, [cur_task]
        xor ah, ah
        mov bl, 10
        mul bl
        add ax, chat_nick
        mov di, ax
        mov byte [di], 0
        mov ax, [chat_last_seq]
.cp_ret:
        pop ds
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        call clr_cf_ret
        iret
.chatnext:                      ; AH=35: BX=since, ES:DI=buf -> AX=seq
        push bp
        push bx
        push cx
        push si
        push di
        push ds
        mov bp, bx
        mov ax, CHATAPI_SEG
        mov ds, ax
        mov al, [CH_CNT]
        xor ah, ah
        test ax, ax
        jz .cn_none
        mov bx, ax                     ; count
        mov al, [CH_HEAD]
        sub al, bl
        and al, CH_N-1
        xor ah, ah                     ; AX = oldest index
        mov dx, ax
        mov cl, 6
        shl ax, cl
        mov cl, 3
        shl dx, cl
        add ax, dx                     ; index*72
        add ax, CH_ENT
        mov si, ax
.cn_l:
        mov ax, [si]
        cmp ax, bp
        ja .cn_found
        add si, CH_ESZ
        cmp si, CH_ENT + CH_N*CH_ESZ
        jb .cn_nowrap
        mov si, CH_ENT
.cn_nowrap:
        dec bx
        jnz .cn_l
        jmp .cn_none
.cn_found:
        push ax                        ; save seq
        add si, CH_LINE
        mov bx, si
        xor cx, cx
.cn_len:
        cmp byte [bx], 0
        je .cn_ld
        inc bx
        inc cx
        cmp cx, 68
        jb .cn_len
.cn_ld:
        mov al, cl
        stosb                          ; length byte
        jcxz .cn_nul
.cn_cp:
        lodsb
        stosb
        dec cx
        jnz .cn_cp
.cn_nul:
        xor al, al
        stosb                          ; NUL terminator
        pop ax                         ; seq
        jmp .cn_out
.cn_none:
        xor ax, ax
.cn_out:
        pop ds
        pop di
        pop si
        pop cx
        pop bx
        pop bp
        call clr_cf_ret
        iret
.pacesend:                      ; AH=31: DS:SI buffer, CX len -> paced send
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        push ds
        mov dx, ds                      ; remember the caller's segment
        mov ax, KERNEL_SEG
        mov ds, ax
        mov es, dx
.ps_l:  jcxz .ps_d
        mov al, [es:si]
        cmp al, 10
        jne .ps_1
        mov al, 13                      ; CR before every LF, as putc does
        call .paced_byte
        mov al, 10
.ps_1:  call .paced_byte
        inc si
        dec cx
        jmp .ps_l
.ps_d:  mov bl, [cur_task]
        xor bh, bh
        mov al, bl
        call mux_flush                  ; always end on a frame boundary
        pop ds
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        call clr_cf_ret
        iret
.paced_byte:                     ; AL=char -> this task's ring, flush when full
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push ds
        push es
        mov ah, al                      ; keep the char in AH
        mov cx, KERNEL_SEG
        mov ds, cx
        mov es, cx
.pb_l:  mov bl, [cur_task]
        xor bh, bh
        cmp byte [tx_len+bx], MUX_TX_MAX
        jb .pb_put
        mov al, bl
        call mux_flush
        cmp byte [tx_len+bx], MUX_TX_MAX
        jb .pb_put
        push ax
        mov ax, 0x0700                  ; AH=7: yield, then retry
        int 0x60
        pop ax
        jmp .pb_l
.pb_put:
        mov al, ah
        call tx_slot_append
        pop es
        pop ds
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret
.statusinfo:                    ; AX=flags, BX=rx, CX=tx, DX=err
        push ds
        mov si, KERNEL_SEG
        mov ds, si
        xor ax, ax
        cmp byte [web_enabled], 0
        je .st1
        or al, 1
.st1:   cmp byte [web_log], 0
        je .st2
        or al, 2
.st2:   cmp byte [slip_mode], 0
        je .st3
        or al, 4
.st3:   cmp byte [mux_mode], 0
        je .st4
        or al, 8
.st4:   cmp byte [tf_enabled], 0
        je .st5
        or al, 16
.st5:   cmp byte [priv_on], 0
        je .st6
        or al, 32
.st6:   mov bx, [slip_rx_pkts]
        mov cx, [slip_tx_pkts]
        mov dx, [slip_errors]
        pop ds
        call clr_cf_ret
        iret
.speedinfo:                    ; AX=baud, BX=tick_hz, CX=cpu_line offset
        push ds
        mov dx, KERNEL_SEG
        mov ds, dx
        mov ax, [baud_rate]
        mov bx, [tick_hz]
        mov cx, cpu_line
        pop ds
        call clr_cf_ret
        iret
.userinfo:                     ; AL=index -> CF=0, AX=user record offset
        push bx
        push di
        push ds
        mov bx, KERNEL_SEG
        mov ds, bx
        cmp al, 16
        jae .uif_no
        call user_index_ptr
        cmp byte [di], 0
        je .uif_no
        call user_name_copy
        pop ds
        pop di
        pop bx
        call clr_cf_ret
        iret
.uif_no:
        pop ds
        pop di
        pop bx
        call set_cf_ret
        iret
.taskinfo:                     ; AL=slot -> CF=0, AX=name offset
        push bx
        push ds
        mov bx, KERNEL_SEG
        mov ds, bx
        cmp al, 12
        ja .tif_no
        mov bl, al
        xor bh, bh
        cmp byte [task_state+bx], 1
        jne .tif_no
        mov al, bl
        mov bl, 12                     ; task_name entries are 12 bytes
        mul bl
        add ax, task_name
        pop ds
        pop bx
        call clr_cf_ret
        iret
.tif_no:
        pop ds
        pop bx
        call set_cf_ret
        iret
.sessinfo:                     ; AL=slot -> CF clear, AX=name offset in KERNEL_SEG
        push bx
        push di
        push ds
        mov bx, KERNEL_SEG
        mov ds, bx
        mov bl, al
        xor bh, bh
        cmp bx, 13
        jae .sif_no
        cmp byte [task_state+bx], 1
        jne .sif_no
        mov al, bl
        call user_ptr_slot
        cmp byte [di], 0
        je .sif_no
        mov ax, di
        pop ds
        pop di
        pop bx
        call clr_cf_ret
        iret
.sif_no:
        pop ds
        pop di
        pop bx
        call set_cf_ret
        iret
.syscnt:
        push ds
        push bx
        push cx
        mov ax, KERNEL_SEG
        mov ds, ax
        xor bx, bx
        xor cx, cx
.sc_l:
        cmp byte [task_state+bx], 1
        jne .sc_n
        inc cx
.sc_n:
        inc bx
        cmp bx, 13
        jb .sc_l
        mov ax, cx
        pop cx
        pop bx
        pop ds
        call clr_cf_ret
        iret
.ticks:
        push ds
        mov ax, KERNEL_SEG
        mov ds, ax
        mov ax, [ticks]
        pop ds
        call clr_cf_ret
        iret
.getc:
        push ds
        mov ax, KERNEL_SEG
        mov ds, ax
        call getchar
        xor ah, ah
        pop ds
        call clr_cf_ret
        iret
.pollch:                        ; AH=32: non-blocking byte -> AL, CF=1 if none
        push ds
        push bx
        mov bx, KERNEL_SEG
        mov ds, bx
        call poll_byte
        pop bx
        pop ds
        jc .pch_no
        xor ah, ah
        call clr_cf_ret
        iret
.pch_no:
        call set_cf_ret
        iret
.taskmeta:                      ; AH=33: task table offsets in KERNEL_SEG
        mov ax, task_state
        mov bx, task_term
        mov cx, task_app
        mov dx, task_seg
        mov si, task_name
        mov di, task_out
        call clr_cf_ret
        iret
.apictl:                        ; AH=36: AL=0 disable API, AL=1 reload API.SYS
        push ds
        push ax
        push bx
        mov bx, KERNEL_SEG
        mov ds, bx
        mov byte [api_ok], 0
        mov byte [job_ok], 0
        test al, al
        jz .apic_d
        call load_api
.apic_d:
        pop bx
        pop ax
        pop ds
        call clr_cf_ret
        iret
.loadf:
        mov [cs:api_dest_seg], es
        mov [cs:api_dest_off], bx
        mov [cs:api_max], cx
        mov [cs:api_caller_ds], ds
        mov ax, ds
        mov es, ax
        mov ax, KERNEL_SEG
        mov ds, ax
        inc byte [crit]
        push si
        mov di, namebuf
        mov cx, 11
.cpn:
        mov al, es:[si]
        mov [di], al
        inc si
        inc di
        loop .cpn
        pop si
        call find_file
        jc .lerr
        mov ax, [cs:api_dest_seg]
        mov es, ax
        mov bx, [cs:api_dest_off]
        mov cx, [cs:api_max]
        call load_file
        jc .lerr
        dec byte [crit]
        mov ds, [cs:api_caller_ds]
        call clr_cf_ret
        iret
.lerr:
        dec byte [crit]
        mov ds, [cs:api_caller_ds]
        call set_cf_ret
        iret
.readlba:
        mov [cs:api_dest_seg], es
        mov [cs:api_dest_off], bx
        mov [cs:api_caller_ds], ds
        push di
        mov ax, KERNEL_SEG
        mov ds, ax
        pop ax
        call hdd_read
        jc .rerr
        mov ax, [cs:api_dest_seg]
        mov es, ax
        mov di, [cs:api_dest_off]
        push si
        mov si, secbuf
        mov cx, 512
        rep movsb
        pop si
        mov ds, [cs:api_caller_ds]
        call clr_cf_ret
        iret
.rerr:
        mov ds, [cs:api_caller_ds]
        call set_cf_ret
        iret
.fsinfo:
        mov [cs:api_caller_ds], ds
        push ds
        mov ax, KERNEL_SEG
        mov ds, ax
        mov si, root_lba
        mov di, bx
        mov cx, 3
        rep movsw
        pop ds
        call clr_cf_ret
        iret

.runcmd:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push es
        push ds
        mov [cs:api_caller_ds], ds
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, apicmd
        mov cx, 100
.cmd_cp:
        lodsb
        stosb
        test al, al
        jz .cmd_done
        dec cx
        jnz .cmd_cp
        xor al, al
        stosb
.cmd_done:
        mov ax, KERNEL_SEG
        mov ds, ax
        mov es, ax
        mov bp, apicmd
        call execute
        pop ds
        pop es
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        call clr_cf_ret
        iret

.savef:
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push es
        push ds
        mov [cs:api_dest_seg], es
        mov [cs:api_dest_off], bx
        mov [cs:api_max], cx
        mov [cs:api_caller_ds], ds
        mov ax, KERNEL_SEG
        mov ds, ax
        inc byte [crit]
        cmp byte [write_ok], 0
        jne .sf_copy
        mov al, 1
        jmp .sf_cf
.sf_copy:
        mov ax, [cs:api_caller_ds]
        mov ds, ax
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, namebuf
        mov cx, 11
        rep movsb
        mov ax, [cs:api_dest_seg]
        mov ds, ax
        mov si, [cs:api_dest_off]
        mov ax, KERNEL_SEG
        mov es, ax
        mov di, savebuf
        mov cx, [cs:api_max]
        cmp cx, 4096
        jbe .sf_sz
        mov cx, 4096
.sf_sz:
        rep movsb
        mov ax, KERNEL_SEG
        mov ds, ax
        mov es, ax
        mov ax, [cs:api_max]
        cmp ax, 4096
        jbe .sf_sv
        mov ax, 4096
.sf_sv:
        mov [sv_size], ax
        mov word [sv_src], savebuf
        mov word [sv_src_seg], KERNEL_SEG
        call write_file
        jc .sf_err
        xor al, al
        jmp .sf_cf
.sf_err:
        mov al, 2
.sf_cf:
        dec byte [crit]
        test al, al
        jnz .sf_bad
        pop ds
        pop es
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        call clr_cf_ret
        iret
.sf_bad:
        pop ds
        pop es
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        call set_cf_ret
        iret

.mount:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push es
        push ds
        mov [cs:api_caller_ds], ds
        mov bl, al
        mov ax, KERNEL_SEG
        mov ds, ax
        test bl, bl
        jz .m_ok
        mov al, [disk_ram]
        mov [copy_old_ram], al
        mov al, [disk_dl]
        mov [copy_old_dl], al
        mov al, bl
        call copy_mount
        jc .m_bad
.m_ok:
        pop ds
        pop es
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        call clr_cf_ret
        iret
.m_bad:
        pop ds
        pop es
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        call set_cf_ret
        iret

.brk:
        push bx
        push cx
        push dx
        push si
        push di
        push ds
        mov ax, KERNEL_SEG
        mov ds, ax
        cmp byte [mux_mode], 0
        je .brk_nomux
        mov bl, [cur_task]
        xor bh, bh
        mov al, [rx_head+bx]
        cmp al, [rx_tail+bx]
        je .brk_no
        mov cl, al
        xor ch, ch
        mov di, rx_buf
        mov al, bl
        xor ah, ah
        shl ax, 1
        shl ax, 1
        shl ax, 1
        shl ax, 1
        shl ax, 1
        shl ax, 1
        shl ax, 1
        shl ax, 1
        add di, ax
        add di, cx
        cmp byte [di], 3
        jne .brk_no
        inc byte [rx_head+bx]
        and byte [rx_head+bx], MUX_RX_SIZE-1
        mov al, 1
        jmp .brk_done
.brk_nomux:
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [task_in+bx], 1
        je .brk_ser
        mov ah, 1
        int 0x16
        jz .brk_no
        cmp al, 3
        jne .brk_no
        mov ah, 0
        int 0x16
        mov al, 1
        jmp .brk_done
.brk_ser:
        mov dx, 0x3FD
        in al, dx
        test al, 1
        jz .brk_no
        mov dx, 0x3F8
        in al, dx
        cmp al, 3
        jne .brk_no
        mov al, 1
        jmp .brk_done
.brk_no:
        xor al, al
.brk_done:
        pop ds
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        iret

.sysinfo:
        push cx
        push dx
        push si
        xor cx, cx
        xor si, si
.si_l:
        cmp byte [task_state+si], 1
        jne .si_n
        inc cx
.si_n:
        inc si
        cmp si, 13
        jb .si_l
        mov al, cl
        mov bx, [ticks]
        pop si
        pop dx
        pop cx
        call clr_cf_ret
        iret
.sendslot:
        push es
        push ds
        push ax
        push bx
        push si
        mov ax, KERNEL_SEG
        mov ds, ax
.ss_l:
        mov al, es:[si]
        inc si
        test al, al
        jz .ss_d
        push es
        call tx_slot_append
        pop es
        jmp .ss_l
.ss_d:
        pop si
        pop bx
        pop ax
        pop ds
        pop es
        call clr_cf_ret
        iret
.cls:
        push ax
        push bx
        push ds
        mov ax, KERNEL_SEG
        mov ds, ax
        call api_cls
        pop ds
        pop bx
        pop ax
        call clr_cf_ret
        iret

; Overlay command lock.  The owner is a task slot so a session reset or task
; exit can release it even if the overlay never returns (stuck or killed).
.ovl_lock:
        push bx
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [ovl_owner], bl
        je .ol_ok
        cmp byte [ovl_owner], 0xFF
        jne .ol_busy
        mov [ovl_owner], bl
.ol_ok:
        pop bx
        call clr_cf_ret
        iret
.ol_busy:
        pop bx
        call set_cf_ret
        iret
.ovl_unlock:
        push bx
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [ovl_owner], bl
        jne .ou_done
        mov byte [ovl_owner], 0xFF
.ou_done:
        pop bx
        call clr_cf_ret
        iret

; Compatibility probe: new overlays verify this before using AH=16/17.
.ver:
        mov ax, 0x554D          ; 'UM'
        mov bx, 0x0101          ; overlay API version
        call clr_cf_ret
        iret

api_cls:
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        cmp byte [task_out+si], 0
        jne .c2
        call panel_init
        ret
.c2:
        ; Serial session: clear that terminal, not the physical CGA.
        mov si, sp_clear
        call sp_str
        mov si, sp_reset
        call sp_str
        ret

; default INT 61h: command not handled
int61_default:
        call set_cf_ret
        iret

; =====================================================================
; Cooperative scheduler - INT 60h AH=7 (yield), AH=8 (exit)
; =====================================================================

api_yield:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        push es
        mov ax, KERNEL_SEG
        mov ds, ax
        mov es, ax
        mov bl, [cur_task]
        xor bh, bh
        mov si, bx
        shl si, 1
        mov [task_sp+si], sp
        mov ax, ss
        mov [task_ss+si], ax
        jmp switch_task

api_exit:
        mov ax, KERNEL_SEG
        mov ds, ax
        mov es, ax
        mov bl, [cur_task]
        xor bh, bh
        cmp byte [ovl_owner], bl
        jne .ae_no_ovl
        mov byte [ovl_owner], 0xFF
.ae_no_ovl:
        mov byte [task_state+bx], 0
        mov byte [task_term+bx], 0      ; release the terminal id as well
        mov byte [task_app+bx], 0
        mov ax, bx
        mov cx, 12
        mul cx
        mov di, task_name
        add di, ax
        mov byte [di], 0
        jmp switch_task

switch_task:
        call next_task
        mov al, bl
        mov [cur_task], al
        mov si, bx
        shl si, 1
        mov ax, [task_ss+si]
        mov ss, ax
        mov sp, [task_sp+si]
        pop es
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        iret

; -> BX = next ready slot (round robin from cur_task)
next_task:
        push cx
        mov bl, [cur_task]
        mov cx, NSLOTS
.try:
        inc bl
        cmp bl, NSLOTS
        jb .ok
        xor bl, bl
.ok:
        xor bh, bh
        cmp byte [task_state+bx], 1
        je .found
        loop .try
        mov bl, [cur_task]
        xor bh, bh
.found:
        pop cx
        ret

; =====================================================================
; RUN FILE.SYS [&] - load a task from C: and start it
; =====================================================================

skip_sp:
        mov al, [si]
        cmp al, ' '
        jne .r
        inc si
        jmp skip_sp
.r:
        ret

upcase:
        cmp al, 'a'
        jb .r
        cmp al, 'z'
        ja .r
        sub al, 32
.r:
        ret

; SI = name string, fills namebuf (default extension SYS)
build83:
        push ax
        push bx
        push cx
        push di
        mov di, namebuf
        mov cx, 11
.fill:
        mov al, ' '
        stosb
        loop .fill
        mov di, namebuf
        xor cx, cx
.base:
        mov al, [si]
        test al, al
        jz .defext
        cmp al, '.'
        je .exts
        cmp cx, 8
        jae .bskip
        call upcase
        mov [di], al
        inc di
        inc cx
.bskip:
        inc si
        jmp .base
.exts:
        inc si
        mov di, namebuf+8
        xor cx, cx
.ext:
        mov al, [si]
        test al, al
        jz .done
        cmp al, '?'
        je .done
        cmp cx, 3
        jae .done
        call upcase
        mov [di], al
        inc di
        inc cx
        inc si
        jmp .ext
.defext:
        mov al, 'S'
        mov [namebuf+8], al
        mov al, 'Y'
        mov [namebuf+9], al
        mov al, 'S'
        mov [namebuf+10], al
.done:
        pop di
        pop cx
        pop bx
        pop ax
        ret

; build83 with the default extension BAS
build83bas:
        push ax
        push bx
        push cx
        push di
        mov di, namebuf
        mov cx, 11
.b1:
        mov al, ' '
        stosb
        loop .b1
        mov di, namebuf
        xor cx, cx
.b2:
        mov al, [si]
        test al, al
        jz .bdef
        cmp al, '.'
        je .bext
        cmp cx, 8
        jae .bsk
        call upcase
        mov [di], al
        inc di
        inc cx
.bsk:
        inc si
        jmp .b2
.bext:
        inc si
        mov di, namebuf+8
        xor cx, cx
.b3:
        mov al, [si]
        test al, al
        jz .bdone
        cmp cx, 3
        jae .bdone
        call upcase
        mov [di], al
        inc di
        inc cx
        inc si
        jmp .b3
.bdef:
        mov al, 'B'
        mov [namebuf+8], al
        mov al, 'A'
        mov [namebuf+9], al
        mov al, 'S'
        mov [namebuf+10], al
.bdone:
        pop di
        pop cx
        pop bx
        pop ax
        ret

do_run:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov si, [bp+144]
        call skip_sp
        cmp byte [si], 0
        jne .have
        mov si, s_run_usage
        call puts
        jmp .ret
.have:
        mov di, fname
        xor cx, cx
.tok:
        mov al, [si]
        test al, al
        jz .tokend
        cmp al, ' '
        je .tokend
        cmp cx, 11
        jae .tskip
        call upcase
        stosb
        inc cx
.tskip:
        inc si
        jmp .tok
.tokend:
        mov byte [di], 0
        mov byte [run_bg], 0
.scan:
        mov al, [si]
        test al, al
        jz .parsed
        cmp al, '!'
        je .bg
        cmp al, '&'
        jne .snext
.bg:
        mov byte [run_bg], 1
        jmp .parsed
.snext:
        inc si
        jmp .scan
.parsed:
        mov bx, MAXSER+1
.slot:
        cmp bx, NSLOTS
        jae .noslot
        cmp byte [task_state+bx], 0
        je .free
        inc bx
        jmp .slot
.noslot:
        mov si, s_noslot
        call puts
        jmp .ret
.free:
        mov [run_slot], bl

        ; remember the process name for PS
        mov ax, KERNEL_SEG
        mov es, ax
        mov bl, [run_slot]
        xor bh, bh
        mov ax, bx
        mov cx, 12
        mul cx
        mov di, task_name
        add di, ax
        mov si, fname
        mov cx, 11
.namecp:
        lodsb
        stosb
        test al, al
        jz .named
        loop .namecp
        mov byte [di], 0
.named:

        mov si, fname
        call build83
        call find_file
        jc .nofile
        mov bl, [run_slot]
        xor bh, bh
        mov si, bx
        shl si, 1
        mov ax, [task_seg+si]
        mov es, ax
        xor bx, bx
        mov cx, 0xFFFF
        call load_file
        jc .nofile
        mov bl, [run_slot]
        xor bh, bh
        mov si, bx
        shl si, 1
        ; Same race as spawn_session: build the new frame without letting the
        ; timer ISR capture this half-built SP/SS as the running task's context.
        pushf
        cli
        inc byte [crit]
        mov [save_sp], sp
        mov ax, ss
        mov [save_ss], ax
        mov ax, [task_stk+si]
        mov ss, ax
        mov sp, 0x0FFE
        mov ax, 0x0202
        push ax
        mov ax, [task_seg+si]
        push ax
        xor ax, ax
        push ax
        push ax
        push ax
        push ax
        push ax
        push ax
        push ax
        push ax
        mov ax, [task_seg+si]
        push ax
        push ax
        mov [task_sp+si], sp
        mov ax, ss
        mov [task_ss+si], ax
        mov ax, [save_ss]
        mov ss, ax
        mov sp, [save_sp]
        mov bl, [run_slot]
        xor bh, bh
        mov al, [cur_task]
        xor ah, ah
        mov si, ax
        mov al, [task_out+si]
        mov [task_out+bx], al
        mov al, [task_in+si]
        mov [task_in+bx], al
        mov al, [task_term+si]
        mov [task_term+bx], al
        mov al, [cur_task]
        mov [task_inslot+bx], al
        mov byte [task_eat_lf+bx], 1
        mov byte [task_state+bx], 1
        dec byte [crit]
        popf
        cmp byte [run_bg], 0
        jne .ret
.wait:
        mov ah, 7
        int 0x60
        mov bl, [run_slot]
        xor bh, bh
        cmp byte [task_state+bx], 0
        jne .wait
        jmp .ret
.nofile:
        mov si, s_nofile2
        call puts
.ret:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---- data ----

banner  db 'UMIX/86 V0R138 - 8088 KERNEL', 10
s_boot_arrow    db '=> ', 0
s_boot_hello    db 'UMIX/86 V0R138 BOOTING', 10, 0
s_boot_disk     db 'C: MOUNTED', 10, 0
s_boot_ram      db 'NO C: - RAM DISK', 10, 0
s_boot_users    db 'USERS LOADED', 10, 0
s_boot_sys      db 'UMIX.SYS LOADED', 10, 0
s_boot_chat     db 'CHAT.SYS LOADED', 10, 0
s_boot_sessions db 'STARTING SESSIONS', 10, 0
s_boot_ready    db 'READY', 10, 0
        db '360K BOOT DISK - C: FAT + SYS + TASKS', 10, 0
prompt  db '* ', 0
s_echo   db 'ECHO', 0
s_cls    db 'CLS', 0
s_mem    db 'MEM', 0
s_time   db 'TIME', 0
s_ver    db 'VER', 0
s_run    db 'RUN', 0
s_save   db 'SAVE', 0
s_write  db 'WRITE', 0
s_drive  db 'DRIVE', 0
s_copy_cmd db 'COPY', 0
s_copy_usage db 'USAGE: COPY [C:|M:]SRC [C:|M:]DST', 10, 0
s_copy_nofile db 'COPY: SOURCE NOT FOUND', 10, 0
s_copy_werr db 'COPY: WRITE FAILED (DISK FULL OR I/O ERROR)', 10, 0
s_copy_ok db 'COPIED ', 0
s_copy_bytes db ' BYTES', 10, 0
s_logoff db 'LOGOFF', 0
s_who    db 'WHO', 0
s_whoami db 'WHOAMI', 0
s_preempt db 'PREEMPT', 0
s_panel  db 'PANEL', 0
s_video  db 'VIDEO', 0
s_edit   db 'EDIT', 0
s_del    db 'DELETE', 0
s_kill   db 'KILL', 0
s_sys    db 'SYS', 0
s_reboot db 'REBOOT', 0
s_halt   db 'HALT', 0
s_unknown db 'UNKNOWN COMMAND - TRY HELP', 10, 0
s_memory db 'CONVENTIONAL MEMORY: ', 0
s_kb     db ' KB', 0
s_time_is db 'TIME ', 0
s_colfat db ': FAT', 0
s_fat12  db '12', 0
s_fat16  db '16', 0
s_nocdrive db 'NO MOUNTABLE VOLUME', 10, 0
s_sysload db 'UMIX.SYS LOADED (', 0
s_bytes  db ' BYTES)', 10, 0
s_nosys  db 'NO UMIX.SYS ON THE MOUNTED VOLUME (DIR/TYPE UNAVAILABLE)', 10, 0
s_serial db 'UMIX/86 V0R138 - SERIAL CONSOLE', 10, 0
s_web_cmd db 'WEB', 0
s_tftp_cmd db 'TFTP', 0
s_tftp_conly db 'TFTP: CONSOLE ONLY', 10, 0
s_tftp_state db 'TFTP: ', 0
s_tftplog_cmd db 'TFTPLOG', 0
s_tftplog_state db 'TFTPLOG: ', 0
s_tftp_prefix db 'TFTP ', 0
s_tftp_get db 'GET ', 0
s_tftp_put db 'PUT ', 0
s_tftp_done db ' DONE ', 0
s_tftp_err db 'ERR ', 0
s_tftp_hint db 'TFTP PORT 69, BLKSIZE 192, WINDOW 4 - TFTP ON|OFF', 10, 0
s_blksize db 'BLKSIZE', 0
s_tsize db 'TSIZE', 0
s_windowsize db 'WINDOWSIZE', 0
s_tf_busy db 'BUSY', 0
s_tf_nofile db 'FILE NOT FOUND', 0
s_tf_name db 'BAD NAME', 0
s_tf_mode db 'ONLY OCTET MODE', 0
s_tf_opt db 'BLKSIZE 8..40', 0
s_tf_noblk db 'BLKSIZE REQUIRED (MAX 192)', 0
s_tf_acc db 'WRITE ON REQUIRED', 0
s_tf_full db 'DISK FULL OR 64 KB LIMIT', 0
s_weblog_cmd db 'WEBLOG', 0
s_web_conly db 'WEB: CONSOLE ONLY', 10, 0
s_web_state db '[WEB] ', 0
s_weblog_state db '[WEBLOG] ', 0
s_web_need_sys db 'WEBLOG SERIAL: SYSTEM + PRIV ONLY', 10, 0
s_http_503 db 'HTTP/1.0 503 Service Unavailable', 13, 10, 'Content-Type: text/plain', 13, 10, 'Content-Length: 14', 13, 10, 'Connection: close', 13, 10, 13, 10, 'WEB DISABLED', 13, 10, 0
s_up_off db 'ERR WRITE OFF', 10, 0
s_up_big db 'ERR TOO BIG', 10, 0
s_up_io db 'ERR I/O', 10, 0
s_up_werr db 'ERR WRITE', 10, 0
s_up_syn db 'ERR SYNTAX', 10, 0
s_up_ok db 'OK ', 0
s_up_bytes db ' BYTES', 10, 0
s_web_index db 'INDEX.HTM', 0
s_web_404file db '404.HTM', 0
s_web_path1 db '/index.htm', 0
s_web_path2 db '/index.html', 0
s_http_ok db 'HTTP/1.0 200 OK', 13, 10, 'Content-Type: text/html', 13, 10, 'Content-Length: ', 0
s_http_404hdr db 'HTTP/1.0 404 Not Found', 13, 10, 'Content-Type: text/html', 13, 10, 'Content-Length: ', 0
s_http_end db 13, 10, 'Connection: close', 13, 10, 13, 10, 0
s_http_404 db 'HTTP/1.0 404 Not Found', 13, 10, 'Content-Type: text/html', 13, 10, 'Content-Length: 11', 13, 10, 'Connection: close', 13, 10, 13, 10, 'NOT FOUND', 13, 10, 0
s_run_usage db 'USAGE: RUN FILE.SYS [!]', 10, 0

s_killed db 'KILLED SLOT ', 0
s_notask db 'SLOT NOT RUNNING (2-4)', 10, 0
s_kill_usage db 'USAGE: KILL n  (n = PROGRAM SLOT)', 10, 0
s_noslot db 'NO FREE TASK SLOT', 10, 0
s_nofile2 db 'FILE NOT FOUND', 10, 0
s_video_state db 'VIDEO ', 0
s_mono db 'MONO (B000, MODE 7)', 10, 0
s_color db 'COLOR (B800, MODE 3)', 10, 0
s_video_set db 'VIDEO SET', 10, 0
s_video_usage db 'USAGE: VIDEO MONO|COLOR', 10, 0
s_panel_state db 'PANEL ', 0
s_panel_on db 'PANEL ON', 10, 0
s_panel_off db 'PANEL OFF', 10, 0
sp_clear db 27, '[2J', 27, '[H', 0
sp_eol db 27, '[2K', 0
sp_blue db 27, '[1;37;44m', 0
sp_green db 27, '[32m', 0
sp_white db 27, '[37m', 0
sp_reset db 27, '[0m', 0
sp_noautowrap db 27, '[?7l', 0
sp_autowrap  db 27, '[?7h', 0
sp_rst_rgn   db 27, '[r', 0
sp_eol2      db 27, '[K', 0
sp_inv       db 27, '[7m', 0
sp_rgn db 27, '[3;23r', 0
sp_chat_rgn db 27, '[5;23r', 27, '[5;1H', 0
s_users_pfx db 'users: ', 0
sp_rule80 db '================================================================================', 0
sp_fill67 db '___________________________________________________________________', 0
s_title_left db 'UMIX/86 V0R138', 0
s_title_center db 'SYSTEM CONSOLE', 0
s_sysid db 'SYSID UCS1  ', 0
s_cmdprompt db 'COMMAND ===> ', 0
s_oia1 db '4A', 0
s_oia2 db 'X SYSTEM', 0
month_days dw 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334
s_break db 'BREAK', 10, 0
s_speed db 'SPEED', 0
s_quantum db 'QUANTUM', 0
s_priv_cmd db 'PRIV', 0
s_priv_state db 'SYSTEM PRIV ', 0
s_priv_on_msg db 'SYSTEM PRIVILEGES ON - SERIAL SYSTEM MAY USE CONSOLE COMMANDS', 10, 0
s_priv_off_msg db 'SYSTEM PRIVILEGES OFF', 10, 0
s_priv_conly db 'PRIV: CONSOLE ONLY', 10, 0
s_priv_usage db 'USAGE: PRIV ON|OFF', 10, 0
s_priv_req db 'SYSTEM PRIV OFF - ASK THE CONSOLE', 10, 0
s_admin_user db 'SYSTEM', 0
s_ban_priv db 'BAN: SYSTEM PRIV OFF', 0
s_nick_sysop    db 'SYSOP', 0
s_nick_reserved db 'SYSOP IS RESERVED - CONSOLE OR SYSTEM ONLY', 10, 0
s_more_cmd db 'MORE', 0
s_baud_cmd db 'BAUD', 0
s_baud_conly db 'BAUD: CONSOLE ONLY', 10, 0
s_baud_state db 'BAUD ', 0
s_baud_ok db 'BAUD SET - RESTART THE BRIDGE WITH --baud ', 0
s_baud_usage db 'USAGE: BAUD 2400|4800|9600|19200|38400', 10, 0
s_pager_state db 'PAGER ', 0
s_pager_lines db ' LINES', 0
s_pager_off_msg db 'PAGER OFF', 10, 0
s_pager_prompt db '-- MORE -- (ENTER=CONTINUE, OTHER=QUIT)', 10, 0
s_more_usage db 'USAGE: MORE ON|OFF|LINES', 10, 0
s_q_prefix db 'SCHEDULER ', 0
s_q_mid db ' HZ (', 0
s_q_ms db ' MS QUANTUM)', 0
s_q_conly db 'QUANTUM: CONSOLE ONLY', 10, 0
s_q_usage db 'USAGE: QUANTUM 18|50|100|200|500|1000', 10, 0
s_cpu_prefix db 'MEASURED CPU: ', 0
s_cpu_suffix db ' MHZ', 0
s_cpu_unknown db 'MEASURED CPU: N/A (TOO FAST)', 0
s_mux_cmd db 'MUX', 0
s_slip_cmd db 'SLIP', 0
s_tcp_cmd db 'TCP', 0
s_tcplog_cmd db 'TCPLOG', 0
s_tcplog_state db 'TCPLOG: ', 0
s_tcp_state db 'TCP: ', 0
s_tcp_on db 'TCP: ON (HTTP :80)', 10, 0
s_tcp_off db 'TCP: OFF', 10, 0
s_tcp_missing db 'TCP: TCP.SYS MISSING', 10, 0
s_tcp_already db 'TCP: ALREADY ON', 10, 0
s_tcp_conly db 'TCP: CONSOLE ONLY', 10, 0
s_tcp_file db 'TCP.SYS', 0
s_slip_state db 'SLIP: ', 0
s_slip_on db 'SLIP: ON (9600 8N1, MTU 250)', 10, 0
s_slip_off db 'SLIP: OFF', 10, 0
s_slip_ip db 'IP ', 0
s_slip_mtu db '  MTU 250  MUX ', 0
s_slip_rx db '  RX ', 0
s_slip_tx db '  TX ', 0
s_slip_err db '  ERR ', 0
s_slip_conly db 'SLIP: CONSOLE ONLY', 10, 0
s_slip_mux db 'SLIP: MUX IS ON - MUX OFF FIRST', 10, 0
s_mux_slip db 'MUX: SLIP IS ON - SLIP OFF FIRST', 10, 0
s_mux_state db 'MUX ', 0
s_mux_on_msg db 'SERIAL MULTIPLEXER ON - FRAMED (USE tools/serial_mux.py)', 10, 0
s_mux_off_msg db 'SERIAL MULTIPLEXER OFF - RAW SINGLE-COM CONSOLE', 10, 0
s_mux_already db 'MUX ALREADY ON', 10, 0
s_mux_already_off db 'MUX ALREADY OFF', 10, 0
s_mux_console_only db 'MUX: CONSOLE ONLY', 10, 0
s_mux_busy db 'MUX: SERIAL SESSIONS ACTIVE - DISCONNECT FIRST', 10, 0
s_mux_usage db 'USAGE: MUX ON|OFF', 10, 0
s_preempt_state db 'PREEMPT ', 0
s_preempt_on db 'PREEMPT ON', 10, 0
s_preempt_off db 'PREEMPT OFF', 10, 0
s_console db 'CONSOLE', 0
s_notlogged db 'NOT LOGGED ON', 10, 0
s_who_hdr db 'USERID      CONSOLE', 10, 0
s_who_rule db '===================', 10, 0
s_who_cga db 'CGA', 10, 0
s_who_com1 db 'COM1', 10, 0
s_login_banner db 'SERIAL CONSOLE LOGON', 10, 'TYPE CHAT AT USERID FOR THE CHAT ROOM', 10, 0
s_chat_user db 'CHAT', 0
s_chat_nick_prompt db 'NICKNAME: ', 0
s_nick_bad db '2+ LETTERS OR DIGITS ONLY', 10, 0
s_chat_joined db 'JOINED CHAT', 0
s_chat_left db 'LEFT CHAT', 0
s_chat_bye db 'LEFT THE CHAT ROOM', 0
s_chat_quit db '/QUIT', 0
s_chat_who_cmd db '/WHO', 0
s_chat_msg_cmd db '/MSG', 0
s_chat_help_cmd db '/HELP', 0
s_chat_unknown db 'UNKNOWN CHAT COMMAND - TRY /HELP', 0
s_chat_box1 db '****************************************', 0
s_chat_box2 db '*      UMIX/86 CHAT SYSTEM             *', 0
s_chat_box3 db '****************************************', 0
s_chat_sysline db 'RUNNING ON A PC/8088 - 640 KB RAM', 0
s_chat_osline db 'UMIX/86 OS V0R138 - MULTITASKING FAT12/16 BASIC', 0
s_chat_tech1 db 'MUX V1.0 FRAMED SERIAL LINK', 0
s_chat_box4 db 'TYPE A MESSAGE AND PRESS ENTER.', 0
s_chat_box5 db '/WHO LIST USERS   /MSG NICK TEXT PRIVATE MSG', 0
s_chat_box6 db '/HELP SHOW HELP   /QUIT LEAVE THE ROOM', 0
s_chat_users_hdr db 'USERS IN CHAT:', 0
s_chat_syso_line db 'SYSO CONSOLE - /BAN NICK REMOVES A USER', 0
s_chat_ban_help db '/BAN NICK  REMOVE A USER FROM THE ROOM (SYSO)', 0
s_chat_ban_only db 'BAN: SYSO ON CONSOLE ONLY', 0
s_chat_ban_self db 'CANNOT BAN THE SYSO', 0
s_chat_ban_usage db 'USAGE: /BAN NICK', 0
s_chat_banned db '*** REMOVED FROM CHAT BY SYSO ***', 0
s_chat_banned_ok db 'BANNED ', 0
s_chat_kicked db 'REMOVED FROM CHAT BY SYSO', 0
s_chat_enabled_msg db 'CHAT ENABLED', 10, 0
s_chat_disabled_msg db 'CHAT DISABLED - ALL USERS REMOVED', 10, 0
s_chat_already db 'CHAT ALREADY ENABLED', 10, 0
s_chat_already_off db 'CHAT ALREADY DISABLED', 10, 0
s_chat_usage db 'USAGE: CHAT [ON|OFF]', 10, 0
s_chat_conly db 'CHAT: CONSOLE ONLY TO ENABLE/DISABLE', 10, 0
s_chat_closed db 'CHAT DISABLED BY CONSOLE', 10, 0
s_chat_priv_tag db '[PRIVATE] ', 0
s_chat_priv_sent db 'PRIVATE MESSAGE SENT TO ', 0
s_chat_priv_nf db 'NO SUCH USER IN CHAT', 0
s_chat_priv_usage db 'USAGE: /MSG NICK TEXT', 0
s_chat_empty db 0
s_users_cmd db 'USERS', 0
s_user_cmd db 'USER', 0
s_user_add db 'ADD', 0
s_user_del db 'DEL', 0
s_user_passcmd db 'PASS', 0
s_user_list db 'LIST', 0
s_users_hdr db 'USERS: ', 0
s_user_conly db 'USER: CONSOLE ONLY', 10, 0
s_user_usage db 'USAGE: USER ADD|DEL|PASS NAME [PASS] | USER SAVE|RESET | USERS', 10, 0
s_user_added db 'USER ADDED: ', 0
s_user_deleted db 'USER DELETED: ', 0
s_user_pw db 'PASSWORD CHANGED: ', 0
s_user_exists db 'USER EXISTS', 10, 0
s_user_nouser db 'NO SUCH USER', 10, 0
s_user_full db 'USER TABLE FULL', 10, 0
s_user_last db 'CANNOT DELETE THE LAST USER', 10, 0
s_user_toolong db 'NAME/PASSWORD TOO LONG (MAX 8)', 10, 0
s_user_savecmd db 'SAVE', 0
s_user_saved db '  SAVED TO BOOT FLOPPY', 10, 0
s_user_nosave db '  NOT SAVED (WRITE ON)', 10, 0
s_user_nofs db '  NOT SAVED (NO C:)', 10, 0
s_user_saveerr db '  SAVE ERROR', 10, 0
s_user_nocl db '  SAVE ERROR: NO FREE CLUSTER', 10, 0
s_user_io db '  SAVE ERROR: I/O', 10, 0
s_user_dirfull db '  SAVE ERROR: DIR FULL', 10, 0
s_user_flerr db '  SAVE ERROR: FLOPPY', 10, 0
s_user_filesaved db '  SAVED TO USERS.DAT (C:)', 10, 0
s_user_resetcmd db 'RESET', 0
s_user_resetmsg db 'DEFAULTS RESTORED', 10, 0
s_users_file db 'USERS   DAT'
s_user_prompt db 'USERID: ', 0
s_pass_prompt db 'PASSWORD: ', 0
s_login_bad db 'LOGON INCORRECT', 10, 0
s_login_ok db 'READY', 10, 0
user_cnt db 3
user_tab:
db 'SYSTEM',0,0,0,0,'SYS1',0,0,0,0,0,0
db 'USER',0,0,0,0,0,0,'USER',0,0,0,0,0,0
db 'USER2',0,0,0,0,0,'USER2',0,0,0,0,0
times (MAXUSERS-3)*USER_ENT db 0
uname times 10 db 0
upass times 10 db 0
uname_safe times 12 db 0    ; standalone NUL-terminated copy for readers
user_tok dw 0
user_p_tok dw 0
ufbuf times 166 db 0
ufsec times 512 db 0
boot_dl       db 0
fl_spt        db 0
fl_heads      db 0
fl_sec        db 0
fl_head       db 0
fl_cyl        dw 0
usv_fl        db 0
usv_file      db 0

user_defaults:
        db 'SYSTEM',0,0,0,0,'SYS1',0,0,0,0,0,0
        db 'USER',0,0,0,0,0,0,'USER',0,0,0,0,0,0
        db 'USER2',0,0,0,0,0,'USER2',0,0,0,0,0
s_log_logon db 'COM1 LOGON ', 0
s_log_logoff db 'COM1 LOGOFF ', 0
s_ed_usage db 'USAGE: EDIT FILE.TXT', 10, 0
s_ed_onlycga db 'EDIT: CGA CONSOLE ONLY', 10, 0
s_ed_done db 'EDIT DONE', 10, 0
s_ed_help db 'F1 SAVE  F2 QUIT  ARROWS  INS  DEL  ^N LINE  ^Y DELLINE', 0
s_ed_title db 'EDIT ', 0
s_ed_ln db '  LN ', 0
s_ed_col db '  COL ', 0
s_ed_sp2 db '  ', 0
s_ed_ins db 'INS', 0
s_ed_ovr db 'OVR', 0
s_ed_unsaved db 'UNSAVED - F2 AGAIN TO QUIT, F1 TO SAVE', 0
s_ed_saved db 'SAVED ', 0
s_ed_bytes2 db ' BYTES', 0
s_ed_saveerr db 'SAVE ERROR', 0
s_ed_wr_off db 'WRITE OFF - USE WRITE ON', 0
s_logoff_no db 'LOGOFF NOT REQUIRED ON THIS CONSOLE', 10, 0
s_drive_usage db 'USAGE: DRIVE A|B|C|M', 10, 0
s_ram_oem db 'UMIXRAM '
s_wr_off db 'WRITES DISABLED - USE WRITE ON', 10, 0
s_wr_on db 'WRITES ENABLED', 10, 0
s_wr_off2 db 'WRITES DISABLED', 10, 0
s_wr_console_only db 'WRITE: CONSOLE ONLY', 10, 0
s_wr_state db 'WRITES ', 0
s_sys_hdr db '** ', 0
s_on db 'ON', 0
s_offstr db 'OFF', 0
s_save_usage db 'USAGE: SAVE FILE.SYS', 10, 0
s_save_hint db 'TYPE LINES, END WITH A LINE CONTAINING .', 10, 0
s_save_full db 'BUFFER FULL - WRITING', 10, 0
s_saved db 'SAVED ', 0
s_saved_bytes db ' BYTES', 10, 0
s_no_space db 'NO SPACE ON C:', 10, 0
s_io_err db 'C: I/O ERROR', 10, 0
s_del_usage db 'USAGE: DELETE FILE.SYS', 10, 0
s_deleted db 'DELETED', 10, 0
s_nofile3 db 'FILE NOT FOUND ON C:', 10, 0
s_vol_ro  db 'VOLUME BEYOND 32 MB - WRITES DISABLED (16-BIT LBA LIMIT)', 10, 0
sys_name db 'UMIX    SYS'
s_fmt_cmd db 'FORMAT', 0
s_api_name db 'API     SYS'
s_chat_name db 'CHAT    SYS'
chat_ok     db 0
api_ok      db 0
s_fmt_usage db 'USAGE: FORMAT A: or FORMAT B:', 10, 0
s_fmt_cap   db 'CAPACITY: 1=360K 2=720K 3=1440K ? ', 0
s_fmt_det   db 'GEOMETRY ', 0
s_fmt_x     db 'X', 0
s_fmt_secs  db ' SECTORS', 10, 0
s_fmt_ask   db 'FORMAT? (Y/N) ', 0
s_fmt_abort db 'ABORTED', 10, 0
s_fmt_bootdisk db 'THIS IS THE BOOT DISK - REFUSED', 10, 0
s_fmt_done  db 'FORMAT COMPLETE', 10, 0
s_fmt_ioerr db 'FORMAT I/O ERROR ', 0
s_nl        db 10, 0
s_fmt_oem   db 'UMIX86  '
s_fmt_label db 'UMIX86 FLPY'
s_fmt_fatname db 'FAT12   '
s_mode_prompt db 13, 10, 'BOOT MODE: [N]ORMAL [T]TRANSFER (11s) ', 0
s_mode_prompt2 db 'BOOT MODE: PRESS T ON SERIAL FOR TRANSFER (11s)', 10, 0
s_tm_insert   db 'REMOVE BOOT DISK, INSERT DATA DISK, PRESS ENTER', 10, 0
s_tm_notfat   db 'NOT A FAT VOLUME - FORMAT (Y/N)? ', 0
s_tm_ready    db 'VOLUME OK', 10, 0
s_tm_name     db 'FILE NAME: ', 0
s_tm_send     db 'READY - SEND FILE NOW', 10, 0
s_tm_ok       db 'OK ', 0
s_tm_bytes    db ' BYTES', 10, 0
s_tm_full     db '  (TRUNCATED)', 10, 0
s_tm_nofree   db 'ERR NO FREE CLUSTER', 10, 0
s_tm_ioerr    db 'ERR I/O', 10, 0
s_tm_first    db '  FIRST BYTE ', 0
s_tm_drv      db 'TRANSFER MODE WRITES TO A: ONLY', 10, 0
mode_start    dw 0
tm_name       times 16 db 0
recv_last     dw 0
recv_ch       db 0
recv_first    db 0
ip_tx_pending db 0
ip_len        dw 0
ip_tx_len     dw 0
ipbuf         times 256 db 0
ipesc         times 256 db 0
ip_my_addr    db 192,168,99,1
udp_ulen      dw 0
req_ip        times 4 db 0
req_port      dw 0
ses_tr        times MAXSER+1 db 0   ; 0 = mux terminal, 1 = UDP session
ses_ip        times (MAXSER+1)*4 db 0
ses_port      times (MAXSER+1)*2 db 0
ub_pay        times 104 db 0        ; 2-byte session header + payload
ub_sport      dw UDP_SESS_PORT      ; source port used by udp_build_core
ub_si         dw 0
ub_cx         dw 0
ub_dx         dw 0
ub_di         dw 0
ub_n          dw 0
ub_rem        dw 0
udp_cand      db 0
mux_esc       db 0
mux_rcnt      db 0
key_scan      db 0
raw_rx_on     db 0
raw_head      dw 0
raw_tail      dw 0
recv_cnt      dw 0
recv_full     db 0
part_cnt      dw 0
boot_sig    times 4 db 0
fmt_drv     db 0
fmt_cyl     dw 0
fmt_spt     dw 0
fmt_heads   dw 0
fmt_total   dw 0
fmt_root    dw 0
fmt_spc     db 0
fmt_media   db 0
fmt_rootsec dw 0
fmt_fatsec  dw 0
fmt_lba     dw 0
fmt_copy    db 0
startup_name db 'STARTUP.JCL', 0
s_startup_hdr db 'STARTUP.JCL', 10, 0
startup_done  db 0
startup_buf   times STARTUP_MAX db 0
sys_entry dd 0x20000000

shellbuf times NSLOTS*160 db 0 ; per shell: linebuf(128) + cmd(16) + arg(2)
disk_dl       db 0x80
disk_ro       db 0              ; 1 = volume beyond the 16-bit LBA limit
disk_err      db 0              ; last INT 13h error code
disk_ram      db 0
login_user    times NSLOTS*32 db 0
login_pass    times NSLOTS*32 db 0
prow          db 2
pcol          db 0
ph_total      dw 0
ph_view       dw 0
ph_start      dw 0
ph_row        db 0
ph_len        db 0
ph_cur        times 80 db ' '
p_tmp         times 81 db 0
pin_col       times NSLOTS db 0
pin_len       times NSLOTS db 0
sp_cleared    times NSLOTS db 0
ser_panel     times NSLOTS db 0
cga_panel     db 1
pv_out        db 0
mono          db 0
vid_seg       dw 0xB800
vp_col        db 0
tb_i          dw 0
tb_day        db 0
tbuf          times 48 db 0
old08         dd 0
ticks         dw 0
preempt_on    db 1
crit          db 0
eat_lf        db 0            ; swallow the LF of a CRLF pair
serial_user   times NSLOTS*16 db 0
logbuf        times 80 db 0
ed_buf        times 8000 db 0
ed_rows       db 1
ed_row        db 0
ed_col        db 0
ed_top        db 0
ed_mod        db 0
ed_ins        db 1
ed_active     db 0
ed_quitarmed  db 0
ed_tmp        db 0
ed_name       times 12 db 0
ed_ptr        dw 0
ed_pdx        dw 0
write_ok      db 0
priv_on       db 0            ; SYSTEM user privilege (PRIV ON)
pager_on      times NSLOTS db 0
pager_lines   times NSLOTS db 20
pager_count   times NSLOTS db 0
slip_mode     db 0
slip_len      dw 0
slip_esc      db 0
slip_bad      db 0
slip_rx_pkts  dw 0
slip_tx_pkts  dw 0
slip_errors   dw 0
tcp_loaded    db 0
tcp_log       db 0
tcp_entry     dw 0, TCP_SEG
pager_bypass  times NSLOTS db 0     ; 1 = interactive output (chat) never pages
pager_hold    db 0
max_cluster   dw 0
ent_lba       dw 0
ent_off       dw 0
fs_val        dw 0
fs_soff       dw 0
fs_off        dw 0
fs_lba_w      dw 0
fat_cache_lba dw 0FFFFh
fat_cache_ok  db 0
fat_buf       times 512 db 0
fs_i          db 0
fs_cl         dw 0
dir_new       db 0
sv_size       dw 0
sv_src        dw 0
sv_src_seg    dw KERNEL_SEG
sv_first      dw 0
sv_prev       dw 0
sv_cnt        dw 0
sv_cur        dw 0
sv_off        dw 0
sv_secs       dw 0
sv_lba        dw 0
svline        times 128 db 0
savebuf       times 4096 db 0
task_out      times NSLOTS db 0
task_in       times NSLOTS db 0
task_inslot   times NSLOTS db 0
task_eat_lf   times NSLOTS db 0
task_term     times NSLOTS db 0
task_app      times NSLOTS db 0
task_name:
        db 'CGA-SHELL',0,0,0
        times MAXSER db 'SER-SHELL',0,0,0
        times 2 db 0,0,0,0,0,0,0,0,0,0,0,0

tick_div         dw 0            ; PIT divisor; 0 = 65536 (18 Hz)
tick_hz          dw 18
mux_idle         dw 9            ; ~0.5 s in ticks
qbuf             times 48 db 0
cpu100           dw 0
cpu_known        db 0
cpu_line         times 40 db 0
baud_rate        dw 9600
baud_div         dw 12
copysrc          times 16 db 0
copydst          times 16 db 0
copy_src_name    dw 0
copy_dst_name    dw 0
copy_src_drv     db 0
copy_dst_drv     db 0
copy_old_ram     db 0
copy_old_dl      db 0
copy_size        dw 0
copy_locked      db 0
mux_mode         db 0            ; 0 = raw single-COM console, 1 = framed mux (MUX ON)
ser_term         db 0
mux_id           db 0
mux_slot         db 0
mux_open_pending times MAXSER+1 db 0
mux_close_pending times MAXSER+1 db 0
mux_app_pending  times MAXSER+1 db 0
web_state        db 0
web_enabled      db 1
web_log          db 0
web_log_slot     db 0
web_log_serial   db 1
web_reqline      times 42 db 0
web_rl_len       db 0
web_rl_done      db 0
web_saved_out    db 0
up_name          times 13 db 0
up_size          dw 0
up_len           dw 0
up_hdr           times 48 db 0
web_count        dw 0
web_start        dw 0
web_len          dw 0
web_num          times 8 db 0
web_path         times 40 db 0
web_ps           db 0
web_pi           db 0
web_method       db 'G'          ; first byte of the request line
; --- API job pump (API.SYS advertises its entry at load time) ---
job_ok           db 0
job_vec          dw 0, 0         ; offset, segment
; --- TFTP server state (see tftp_step) ---
tf_enabled       db 0            ; TFTP ON|OFF (console only, default OFF)
tf_state         db 0            ; 0 idle, TF_ACK0, TF_SEND, TF_DATA
tf_pending       db 0            ; one datagram queued by the RX path
tf_op            db 0            ; 1 = RRQ, 2 = WRQ
tf_have_blk      db 0            ; client negotiated blksize
tf_tsize         db 0            ; client sent tsize
tf_blk           db TFTP_BLK     ; negotiated block size (<= 192)
tf_win           db 1            ; negotiated windowsize (1..4)
tf_have_win      db 0
tf_wbase         dw 0            ; first unacknowledged block
tf_wnext         dw 0            ; next block to send
tf_wnum          dw 0            ; blocks in flight
tf_final         db 0            ; final (short) block has been sent
tf_wlen          times TFTP_WIN db 0
tf_retries       db 0
tf_tid           dw TFTP_TID     ; server transfer id (UDP source port)
tf_last_tx       dw 0            ; ticks at the last OACK/ACK/DATA send
tf_to            dw 36           ; retransmit timeout in ticks (~2 s)
tf_block         dw 0            ; last DATA sent (RRQ) / last acked (WRQ)
tf_last_len      dw 0            ; data bytes in the last DATA block
tf_left          dw 0            ; RRQ: bytes left to read
tf_size          dw 0            ; WRQ: bytes collected (legacy)
tf_upfill        dw 0            ; WRQ: bytes buffered in secbuf
tftp_log         db 0            ; TFTPLOG ON|OFF
tftp_log_slot    db 0
tf_log_next      dw 4096
tf_log_num       dw 0
tf_saved_out     db 0
tf_log_buf       times 48 db 0
tf_cluster       dw 0
tf_sec           dw 0
tf_off           dw 0
tf_tsize_val     dw 0
tf_tsize_out     dw 0
tf_rxlen         dw 0
tf_txlen         dw 0
tf_qip           times 4 db 0
tf_qport         dw 0
tf_peer_ip       times 4 db 0
tf_peer_port     dw 0
tf_dst_ip        times 4 db 0
tf_dst_port      dw 0
tf_name          times 12 db 0
tf_name83        times 11 db 0
tf_opt           times 12 db 0
tf_rxbuf         times TFTP_RXMAX db 0
tf_tx            times 256 db 0
mux_state        db 0
mux_type         db 0
mux_term         db 0
mux_len          db 0
mux_idx          dw 0
mux_sum          db 0
mux_last_tick    dw 0
mux_rx_overflows dw 0
mux_payload      times 256 db 0
rx_head          times NSLOTS db 0
rx_tail          times NSLOTS db 0
rx_buf           times NSLOTS*MUX_RX_SIZE db 0
tx_len           times NSLOTS db 0
tx_buf           times NSLOTS*128 db 0
chat_enabled     db 1
chat_kick        times NSLOTS db 0
chat_kicked      times NSLOTS db 0
chat_on          times NSLOTS db 0
chat_nick        times NSLOTS*10 db 0
chat_row         times NSLOTS db 0
chat_ilen        times NSLOTS db 0
chat_out         times 64 db 0
chat_linebuf     times 40 db 0
chat_tok         dw 0
chat_txt         dw 0
chat_target      db 0
chat_saved       db 0
chat_slot        db 0
chat_snd         dw 0
chat_out2        times 64 db 0
cs_mode          times NSLOTS db 0
chat_echo_on     db 0
chat_i           db 0
chat_last_seq    dw 0            ; seq of the last ring append (AH=34 reply)

part_lba      dw 0
sec_per_clus  db 1
rsvd_secs     dw 1
num_fats      db 2
root_ents     dw 0
root_secs     dw 0
root_lba      dw 0
fat_lba       dw 0
fat_secs      dw 0
data_lba      dw 0
total_secs    dw 0
spt           dw 17
heads         dw 4
fat_type      db 12
fs_ok         db 0
scan_lba      dw 0
root_left     dw 0
ent_left      dw 0
file_cluster  dw 0
file_size     dw 0, 0
cur_cluster   dw 0
cur_lba       dw 0
secs_left     dw 0
copy_left     dw 0
ret_size      dw 0
api_dest_seg  dw 0
api_dest_off  dw 0
api_max       dw 0
api_caller_ds dw 0
apicmd        times 160 db 0
namebuf       times 11 db 0
secbuf        times 512 db 0
fname         times 12 db 0
run_bg        db 0
run_slot      db 0
save_sp       dw 0
save_ss       dw 0
cur_task      db 0
ovl_owner     db 0xFF
task_sp       times NSLOTS dw 0
task_ss       times NSLOTS dw 0
task_state    times NSLOTS db 0
task_seg      dw 0x1000, 0x1000, 0x1000, 0x1000, 0x1000, 0x1000, 0x1000, 0x1000, 0x1000, 0x1000, 0x1000, 0x3000, 0x4000
task_stk      dw 0, 0x6000, 0x6100, 0x6200, 0x6300, 0x6400, 0x6500, 0x6600, 0x6700, 0x6800, 0x6900, 0x6A00, 0x6B00
