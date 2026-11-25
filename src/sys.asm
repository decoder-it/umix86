; UMIX.SYS - overlay loaded from C:\UMIX.SYS by the kernel (2000:0000).
; Installs INT 61h for shell commands and uses the INT 60h kernel API:
;   DIR          list the C: root directory
;   TYPE FILE    print a file from C:

        cpu 8086
        bits 16
        org 0

SYS_SEG equ 0x2000
KSEG    equ 0x1000              ; real kernel segment (AH=24/25/33 offsets)

start:
        mov ax, SYS_SEG
        mov ds, ax
        mov es, ax
        ; hook INT 61h
        push es
        xor ax, ax
        mov es, ax
        mov word [es:0x184], int61
        mov word [es:0x186], SYS_SEG
        mov word [es:0x188], api62
        mov word [es:0x18A], SYS_SEG
        mov word [es:0x000], panic0
        mov word [es:0x002], SYS_SEG
        mov word [es:0x018], panic6
        mov word [es:0x01A], SYS_SEG
        pop es
        mov si, banner
        call kputs
        retf

; ---- fault handlers: print instead of silently resetting ----
panic0:
        cli
        push ax
        push si
        push ds
        mov ax, SYS_SEG
        mov ds, ax
        mov si, s_panic0
        jmp panic_print
panic6:
        cli
        push ax
        push si
        push ds
        mov ax, SYS_SEG
        mov ds, ax
        mov si, s_panic6
panic_print:
        mov ah, 1
        int 0x60
        pop ds
        pop si
        pop ax
.h:     hlt
        jmp .h

; ---- INT 62h: serve one hardcoded BASIC route -----------------------------
; in:  DS:SI = path, ES:DI = output buffer, CX = max
; out: AX = bytes, CF=0; CF=1 + AL: 1 no route, 2 busy, 3 route error
api62:
        push ds
        push es
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        mov [cs:apic_method], al
        mov [cs:apic_blen], bx
        mov [cs:apic_boff], dx
        push ds                 ; caller DS (path source)
        mov ax, SYS_SEG
        mov ds, ax
        mov [apic_seg], es
        mov [apic_off], di
        mov [apic_max], cx
        mov es, ax              ; ES = SYS (path destination)
        pop ax                  ; AX = caller DS
        mov ds, ax              ; DS = caller (path source)
        mov di, apipath
        mov cx, 24
.ap_cp:
        lodsb
        stosb
        test al, al
        jz .ap_cpd
        loop .ap_cp
        mov byte [di], 0
.ap_cpd:
        ; copy the POST body from the caller (DS:DX, len in apic_blen)
        mov cx, [cs:apic_blen]
        test cx, cx
        jz .ap_bd0
        cmp cx, 63
        jbe .ap_bc
        mov cx, 63
.ap_bc:
        mov si, [cs:apic_boff]
        mov di, api_bstr
        rep movsb
        xor al, al
        stosb
        jmp .ap_bd2
.ap_bd0:
        mov di, api_bstr
        xor al, al
        stosb
.ap_bd2:
        mov ax, SYS_SEG
        mov ds, ax
        ; build M$ text
        mov al, [apic_method]
        cmp al, 'P'
        je .ap_mp
        cmp al, 'D'
        je .ap_md
        mov si, s_m_get
        jmp .ap_mc
.ap_mp:
        mov si, s_m_post
        jmp .ap_mc
.ap_md:
        mov si, s_m_del
.ap_mc:
        mov di, api_mstr
        mov cx, 6
        call copy_z
        ; split /path?query: apipath becomes the path, api_qstr the query
        mov si, apipath
        mov byte [api_qstr], 0
.ap_qs:
        mov al, [si]
        test al, al
        jz .ap_qd
        cmp al, '?'
        je .ap_qf
        inc si
        jmp .ap_qs
.ap_qf:
        mov byte [si], 0
        inc si
        mov di, api_qstr
        mov cx, 23
        call copy_z
.ap_qd:
        mov si, apipath
        mov di, s__routes
        call streq
        cmp al, 1
        je .ap_enum
        ; route table first
        mov bx, routes
        mov cx, ROUTE_MAX
.ap_rt:
        cmp byte [bx], 0
        je .ap_rn
        mov si, apipath
        mov di, bx
        call streq
        cmp al, 1
        je .ap_rf
.ap_rn:
        add bx, ROUTE_SZ
        loop .ap_rt
        ; built-in demo route
        mov si, apipath
        mov di, s_apipath
        call streq
        cmp al, 1
        je .ap_builtin
        jmp .ap_nf
.ap_enum:
        ; JSON fragment of registered route paths into the caller's buffer
        mov byte [cap_on], 1
        mov byte [cap_err], 0
        mov word [cap_len], 0
        mov ax, [apic_seg]
        mov [cap_seg], ax
        mov ax, [apic_off]
        mov [cap_off], ax
        mov ax, [apic_max]
        mov [cap_max], ax
        mov bx, routes
        mov cx, ROUTE_MAX
        xor dx, dx
.ap_en_l:
        cmp byte [bx], 0
        je .ap_en_n
        test dx, dx
        jz .ap_en_q
        mov al, ','
        call cap_store
.ap_en_q:
        mov dx, 1
        mov al, '"'
        call cap_store
        mov si, bx
.ap_en_p:
        mov al, [si]
        test al, al
        jz .ap_en_pd
        call cap_store
        inc si
        jmp .ap_en_p
.ap_en_pd:
        mov al, '"'
        call cap_store
.ap_en_n:
        add bx, ROUTE_SZ
        loop .ap_en_l
        mov byte [cap_on], 0
        mov ax, [cap_len]
        clc
        jmp .ap_out
.ap_nf:
        mov al, 1
        stc
        jmp .ap_out
.ap_rf:
        mov [ap_ent], bx
        mov byte [ap_load], 1
        jmp .ap_start
.ap_builtin:
        mov byte [ap_load], 0
        mov ax, SYS_SEG
        mov es, ax
        mov di, basprog
        xor ax, ax
        mov cx, MAXLINES*32
        rep stosw
        mov si, api_prog
        mov di, basprog
        mov cx, 128
        rep movsb
.ap_start:
        push ds
        mov ax, 0x1000          ; AH=16/17 read kernel data: caller DS must be KERNEL
        mov ds, ax
        mov ah, 16
        int 0x60
        pop ds
        jc .ap_busy
        mov byte [cap_on], 1
        mov byte [cap_err], 0
        mov word [cap_len], 0
        mov ax, [apic_seg]
        mov [cap_seg], ax
        mov ax, [apic_off]
        mov [cap_off], ax
        mov ax, [apic_max]
        mov [cap_max], ax
        mov ah, 9
        int 0x60
        mov [cap_start], ax
        cmp byte [ap_load], 0
        je .ap_run
        call bas_new
        mov ax, [ap_ent]
        add ax, 20
        mov [tokptr], ax
        call st_load
        mov word [cap_len], 0   ; discard LOADED / loader messages
        cmp word [basprog], 0
        je .ap_lfail
.ap_run:
        mov word [bas_start], 0
        call bas_run
        mov byte [cap_on], 0
        push ds
        mov ax, 0x1000
        mov ds, ax
        mov ah, 17
        int 0x60
        pop ds
        mov ax, [cap_len]
        cmp byte [cap_err], 0
        jne .ap_err
        clc
        jmp .ap_out
.ap_lfail:
        mov byte [cap_on], 0
        push ds
        mov ax, 0x1000
        mov ds, ax
        mov ah, 17
        int 0x60
        pop ds
        mov al, 3
        stc
        jmp .ap_out
.ap_err:
        mov al, 3
        stc
        jmp .ap_out
.ap_busy:
        mov al, 2
        stc
.ap_out:
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop es
        pop ds
        jc .ap_scf
        call clr_cf
        iret
.ap_scf:
        call set_cf
        iret

; ---- helpers for API routes ----

copy_z:                         ; SI src, DI dst, CX max -> NUL-terminated copy
        jcxz .cz_d
        mov al, [si]
        test al, al
        jz .cz_d
        mov [di], al
        inc si
        inc di
        dec cx
        jmp copy_z
.cz_d:
        mov byte [di], 0
        ret

skip_sp_si:
        cmp byte [si], ' '
        jne .ss_d
        inc si
        jmp skip_sp_si
.ss_d:
        ret

set_str_var:                    ; SI source, DI slot -> [DI]=len, chars at DI+1
        push ax
        push bx
        push cx
        push si
        push di
        mov bx, di
        inc di
        xor cx, cx
.sv_l:
        cmp cx, 63
        jae .sv_d
        mov al, [si]
        test al, al
        jz .sv_d
        mov [di], al
        inc si
        inc di
        inc cx
        jmp .sv_l
.sv_d:
        mov [bx], cl
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        ret

copy_tok_name:                  ; SI token, DI dst, CX max -> token, SI at delimiter
        jcxz .ct_d
        mov al, [si]
        test al, al
        jz .ct_d
        cmp al, ' '
        je .ct_d
        mov [di], al
        inc si
        inc di
        dec cx
        jmp copy_tok_name
.ct_d:
        mov byte [di], 0
        ret

kw_prefix:                      ; SI arg, DI keyword -> AL=1 and SI after the space
        push di
.kp_l:
        mov al, [di]
        test al, al
        jz .kp_end
        cmp al, [si]
        jne .kp_no
        inc si
        inc di
        jmp .kp_l
.kp_end:
        mov al, [si]
        test al, al
        jz .kp_yes
        cmp al, ' '
        jne .kp_no
        inc si
.kp_sp:
        cmp byte [si], ' '
        jne .kp_yes
        inc si
        jmp .kp_sp
.kp_yes:
        mov al, 1
        pop di
        ret
.kp_no:
        xor al, al
        pop di
        ret

; ---- kernel API wrappers ----

kputc:
        mov ah, 0
        int 0x60
        ret
kputs:
        mov ah, 1
        int 0x60
        ret
kputdec:
        mov bx, ax
        mov ah, 2
        int 0x60
        ret
kread:                          ; DI = LBA, ES:BX = dest
        mov ah, 5
        int 0x60
        ret
kload:                          ; DS:SI = 11-byte name, ES:BX = dest, CX = max
        mov ah, 4
        int 0x60
        ret
kfsinfo:                        ; ES:BX = root_lba, root_secs, root_ents
        mov ah, 6
        int 0x60
        ret

; ---- INT 61h: shell command hook ----

int61:
        push ds
        push es
        push ax
        push bx
        push cx
        push dx
        push si
        push di

        ; Refuse to run against a boot floppy older than this overlay.
        ; AH=18 exists only in the current kernel; old kernels return CF=1.
        mov dx, di              ; arg pointer (kernel DS)
        mov ah, 18
        int 0x60
        jc .old_kernel
        cmp ax, 0x554D
        jne .old_kernel

        ; One overlay command at a time: the BASIC interpreter and the
        ; command buffers live in this single SYS segment.  The lock owner is
        ; tracked by the kernel so a reset/closed session releases it.
.wait_lock:
        mov ah, 16
        int 0x60
        jnc .got_lock
        mov ah, 7
        int 0x60
        jmp .wait_lock
.got_lock:
        sti                     ; let IRQ0 preempt the overlay from now on
        mov bx, si              ; cmd pointer (still in SI)
        mov ax, SYS_SEG
        mov es, ax
        mov di, cmdbuf
        mov cx, 15
.cc:
        mov al, [bx]
        stosb
        test al, al
        jz .ccd
        inc bx
        loop .cc
.ccd:
        mov si, dx
        mov di, argbuf
        mov cx, 47
.ac:
        mov al, [si]
        stosb
        test al, al
        jz .acd
        inc si
        loop .ac
.acd:
        mov ax, SYS_SEG
        mov ds, ax
        mov es, ax

        mov si, cmdbuf
        mov di, s_dir
        call streq
        cmp al, 1
        je .dir
        mov si, cmdbuf
        mov di, s_help_cmd
        call streq
        cmp al, 1
        je .help
        mov si, cmdbuf
        mov di, s_type
        call streq
        cmp al, 1
        je .type
        mov si, cmdbuf
        mov di, s_jcl_cmd
        call streq
        cmp al, 1
        je .jcl
        mov si, cmdbuf
        mov di, s_api_cmd
        call streq
        cmp al, 1
        je .apicmd
        mov si, cmdbuf
        mov di, s_ps_cmd
        call streq
        cmp al, 1
        je .ps
        mov si, cmdbuf
        mov di, s_basic_cmd
        call streq
        cmp al, 1
        je .basic
        stc
        jmp .out
.help:
        mov si, help_text
        mov ah, 1
        int 0x60
        clc
        jmp .out
.dir:
        call do_dir
        clc
        jmp .out
.type:
        call do_type
        clc
        jmp .out
.jcl:
        call do_jcl
        clc
        jmp .out
.basic:
        call do_basic
        clc
        jmp .out
.ps:
        call do_ps
        clc
        jmp .out
.apicmd:                        ; API [ON|RELOAD|OFF|ROUTE p f|ROUTES|DEL p]
        ; uppercase the subcommand token only (the path/file keep their case)
        mov si, argbuf
.ap_up:
        mov al, [si]
        test al, al
        jz .ap_upd
        cmp al, ' '
        je .ap_upd
        call upcase
        mov [si], al
        inc si
        jmp .ap_up
.ap_upd:
        cmp byte [argbuf], 0
        je .api_on
        mov si, argbuf
        mov di, s_off
        call kw_prefix
        cmp al, 1
        je .api_off
        mov si, argbuf
        mov di, s_kw_routes
        call kw_prefix
        cmp al, 1
        je .api_routes
        mov si, argbuf
        mov di, s_kw_route
        call kw_prefix
        cmp al, 1
        je .api_route
        mov si, argbuf
        mov di, s_kw_del
        call kw_prefix
        cmp al, 1
        je .api_del
.api_on:
        mov al, 1
        jmp .api_go
.api_off:
        xor al, al
.api_go:
        mov ah, 36
        int 0x60
        mov si, s_api_done
        mov ah, 1
        int 0x60
        clc
        jmp .out

.api_route:
        call skip_sp_si
        mov di, rtmp_path
        mov cx, 19
        call copy_tok_name
        cmp byte [rtmp_path], '/'
        jne .api_rusage
        cmp word [rtmp_path+1], 0x7061   ; 'ap'
        jne .api_rusage
        cmp word [rtmp_path+3], 0x2F69   ; 'i/'
        jne .api_rusage
        cmp byte [rtmp_path+5], 0
        je .api_rusage
        mov al, [si]
        test al, al
        jz .api_rusage
        cmp al, ' '
        jne .api_rusage
        call skip_sp_si
        cmp byte [si+0], 0
        je .api_rusage
        mov di, rtmp_file
        mov cx, 15
        call copy_tok_name
        mov al, [si]
        test al, al
        jz .ar_ok
        cmp al, ' '
        jne .api_rusage
.ar_ok:
        mov bx, routes
        mov cx, ROUTE_MAX
.ar_l:
        cmp byte [bx], 0
        je .ar_use
        mov si, rtmp_path
        mov di, bx
        call streq
        cmp al, 1
        je .ar_use
        add bx, ROUTE_SZ
        loop .ar_l
        mov si, s_route_full
        call puts
        clc
        jmp .out
.ar_use:
        mov di, bx
        xor ax, ax
        mov cx, ROUTE_SZ/2
        rep stosw
        mov si, rtmp_path
        mov di, bx
.ar_p:
        mov al, [si]
        mov [di], al
        inc si
        inc di
        test al, al
        jnz .ar_p
        mov si, rtmp_file
        mov di, bx
        add di, 20
.ar_f:
        mov al, [si]
        mov [di], al
        inc si
        inc di
        test al, al
        jnz .ar_f
        mov si, s_route_added
        call puts
        clc
        jmp .out
.api_rusage:
        mov si, s_route_usage
        call puts
        clc
        jmp .out

.api_routes:
        mov si, s_routes_hdr
        call puts
        mov bx, routes
        mov cx, ROUTE_MAX
.ars_l:
        cmp byte [bx], 0
        je .ars_n
        mov si, bx
        call puts
        mov al, ' '
        call putc
        mov si, bx
        add si, 20
        call puts
        mov al, 10
        call putc
.ars_n:
        add bx, ROUTE_SZ
        loop .ars_l
        clc
        jmp .out

.api_del:
        call skip_sp_si
        mov di, rtmp_path
        mov cx, 19
        call copy_tok_name
        mov bx, routes
        mov cx, ROUTE_MAX
.ad_l:
        cmp byte [bx], 0
        je .ad_n
        mov si, rtmp_path
        mov di, bx
        call streq
        cmp al, 1
        je .ad_del
.ad_n:
        add bx, ROUTE_SZ
        loop .ad_l
        mov si, s_route_none
        call puts
        clc
        jmp .out
.ad_del:
        mov byte [bx], 0
        mov si, s_route_del
        call puts
        clc
        jmp .out

.old_kernel:
        push ds
        mov ax, SYS_SEG
        mov ds, ax
        mov si, s_old_kernel
        mov ah, 1
        int 0x60
        pop ds
        clc
        jmp .out

.out:
        ; Release the overlay lock without disturbing the command's CF.
        pushf
        push ds
        mov ax, 0x1000          ; AH=17 touches kernel data: DS must be KERNEL
        mov ds, ax
        mov ah, 17
        int 0x60
        pop ds
        popf
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        pop es
        pop ds
        jc .setcf
        call clr_cf
        iret
.setcf:
        call set_cf
        iret

set_cf:
        push bp
        mov bp, sp
        or word [bp+8], 1
        pop bp
        ret
clr_cf:
        push bp
        mov bp, sp
        and word [bp+8], 0xFFFE
        pop bp
        ret

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

; ---- DIR ----

do_dir:
        mov ax, SYS_SEG
        mov es, ax
        mov bx, fsinfo
        call kfsinfo
        jc .fail
        mov si, hdr
        call kputs
        mov si, dir_rule
        call kputs
        mov ax, [fsinfo]
        mov [cur_lba], ax
        mov ax, [fsinfo+2]
        mov [sec_left], ax
.sector:
        mov ax, SYS_SEG
        mov es, ax
        mov bx, secbuf
        mov di, [cur_lba]
        call kread
        jc .fail
        mov si, secbuf
        mov word [ent_left], 16
.entry:
        mov al, [si]
        test al, al
        jz .done
        cmp al, 0xE5
        je .next
        test byte [si+11], 0x08
        jnz .next
        call print_entry
.next:
        add si, 32
        dec word [ent_left]
        jnz .entry
        inc word [cur_lba]
        dec word [sec_left]
        jnz .sector
.done:
        ret
.fail:
        mov si, s_noio
        call kputs
        ret

; SI = directory entry
print_entry:
        push si
        push bx
        push cx
        mov bx, si
        xor cx, cx
.b:
        mov al, [bx]
        cmp al, ' '
        je .bend
        call kputc
        inc bx
        inc cx
        cmp cx, 8
        jb .b
.bend:
        cmp byte [si+8], ' '
        je .noext
        mov al, '.'
        call kputc
        lea bx, [si+8]
        xor cx, cx
.e:
        mov al, [bx]
        cmp al, ' '
        je .noext
        call kputc
        inc bx
        inc cx
        cmp cx, 3
        jb .e
.noext:
        mov al, ' '
        call kputc
        mov al, ' '
        call kputc
        test byte [si+11], 0x10
        jz .size
        mov si, s_dirattr
        call kputs
        jmp .nl
.size:
        mov ax, [si+0x1C]
        call kputdec
.nl:
        mov al, 10
        call kputc
        pop cx
        pop bx
        pop si
        ret

; ---- TYPE ----

do_type:
        mov al, [argbuf]
        test al, al
        jnz .have
        mov si, s_usage
        call kputs
        ret
.have:
        mov di, namebuf
        mov cx, 11
.fill:
        mov al, ' '
        stosb
        loop .fill
        mov si, argbuf
        mov di, namebuf
        xor cx, cx
.base:
        mov al, [si]
        test al, al
        jz .done_name
        cmp al, '.'
        je .ext_start
        cmp cx, 8
        jae .skip_base
        call toupper
        mov [di], al
        inc di
        inc cx
.skip_base:
        inc si
        jmp .base
.ext_start:
        inc si
        mov di, namebuf+8
        xor cx, cx
.ext:
        mov al, [si]
        test al, al
        jz .done_name
        cmp cx, 3
        jae .done_name
        call toupper
        mov [di], al
        inc di
        inc cx
        inc si
        jmp .ext
.done_name:
        mov ax, SYS_SEG
        mov es, ax
        mov bx, filebuf
        mov cx, 8192
        mov si, namebuf
        call kload
        jc .notfound
        mov si, filebuf
        mov cx, dx
.print:
        test cx, cx
        jz .ret
        mov al, [si]
        call kputc
        inc si
        dec cx
        jmp .print
.ret:
        ret
.notfound:
        mov si, s_nofile
        call kputs
        ret

; =====================================================================
; JCL FILE.JCL - job control, runs here in UMIX.SYS
; The kernel API AH=11 executes one command line in the kernel.
; =====================================================================

krun:
        mov ah, 11
        int 0x60
        ret

do_jcl:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        push bp
        cmp byte [injcl], 0
        je .ok
        mov si, s_jcl_busy
        call kputs
        jmp .ret
.ok:
        mov byte [injcl], 1
        mov byte [jclseen], 0
        mov si, argbuf
        call sskip
        cmp byte [si], 0
        jne .have
        mov si, s_jcl_usage
        call kputs
        jmp .ret
.have:
        call build83_sys
        mov ax, SYS_SEG
        mov es, ax
        mov bx, jclbuf
        mov cx, 1535
        mov si, name83
        call kload
        jc .nofile
        mov ax, SYS_SEG
        mov es, ax
        mov di, jclbuf
        add di, dx
        mov byte [di], 0
        mov word [jclptr], jclbuf
.nextline:
        mov si, [jclptr]
        cmp byte [si], 0
        je .eof
        call jcl_line
        mov [jclptr], di
        call ustr_sys
        cmp byte [si], '/'
        jne .nextline
        cmp byte [si+1], '/'
        jne .nextline
        add si, 2
        call sskip
        cmp byte [si], '*'
        je .nextline
        mov di, jclstep
        xor cx, cx
.sn:
        mov al, [si]
        test al, al
        jz .snd
        cmp al, ' '
        je .snd
        cmp al, ','
        je .snd
        cmp cx, 8
        jae .snskip
        call up_sys
        stosb
        inc cx
.snskip:
        inc si
        jmp .sn
.snd:
        mov byte [di], 0
        call sskip
        cmp byte [si], 'J'
        je .op_job
        cmp byte [si], 'E'
        je .op_e
        call jcl_eoj
        jc .eoj
        jmp .nextline
.op_job:
        cmp byte [si+1], 'O'
        jne .nextline
        cmp byte [si+2], 'B'
        jne .nextline
        mov si, s_jcl_job
        call kputs
        mov si, jclstep
        call kputs
        mov si, s_jcl_started
        call kputs
        mov byte [jclseen], 1
        jmp .nextline
.op_e:
        cmp byte [si+1], 'X'
        je .op_exec
        cmp byte [si+1], 'O'
        jne .nextline
        cmp byte [si+2], 'J'
        je .eoj
        jmp .nextline
.op_exec:
        add si, 3
        call sskip
        mov di, si
.find:
        mov al, [di]
        test al, al
        jz .nocmd
        cmp al, 'P'
        jne .fc
        cmp byte [di+1], 'G'
        jne .fc
        cmp byte [di+2], 'M'
        jne .fc
        cmp byte [di+3], '='
        jne .fc
        lea si, [di+4]
        jmp .pgm
.fc:
        cmp al, 'C'
        jne .fn
        cmp byte [di+1], 'M'
        jne .fn
        cmp byte [di+2], 'D'
        jne .fn
        cmp byte [di+3], '='
        jne .fn
        lea si, [di+4]
        jmp .cmd
.fn:
        inc di
        jmp .find
.nocmd:
        mov si, s_jcl_step
        call kputs
        mov si, jclstep
        call kputs
        mov si, s_jcl_nocmd
        call kputs
        jmp .nextline
.pgm:
        mov di, jclcmd
        xor cx, cx
.pcopy:
        mov al, [si]
        test al, al
        jz .pdone
        cmp al, ','
        je .pdone
        cmp al, ' '
        je .pdone
        cmp cx, 60
        jae .pdone
        stosb
        inc cx
        inc si
        jmp .pcopy
.pdone:
        mov byte [di], 0
        cmp byte [si], ','
        jne .prun
        inc si
        call sskip
        cmp byte [si], 'P'
        jne .prun
        cmp byte [si+1], 'A'
        jne .prun
        cmp byte [si+2], 'R'
        jne .prun
        cmp byte [si+3], 'M'
        jne .prun
        cmp byte [si+4], '='
        jne .prun
        add si, 5
        mov al, ' '
        stosb
        cmp byte [si], 39
        jne .pq
        inc si
.pq:
        cmp byte [si], 39
        je .pqend
        mov al, [si]
        test al, al
        jz .pqend
        stosb
        inc si
        jmp .pq
.pqend:
        mov byte [di], 0
        jmp .prun
.cmd:
        cmp byte [si], 39
        jne .ccopy
        inc si
.ccopy:
        mov di, jclcmd
        xor cx, cx
.cl:
        mov al, [si]
        test al, al
        jz .cdone
        cmp al, 39
        je .cdone
        cmp cx, 100
        jae .cdone
        stosb
        inc cx
        inc si
        jmp .cl
.cdone:
        mov byte [di], 0
.prun:
        cmp byte [jclcmd], 0
        je .nocmd
        mov si, s_jcl_step
        call kputs
        mov si, jclstep
        call kputs
        mov al, ' '
        call kputc
        mov si, jclcmd
        call kputs
        mov al, 10
        call kputc
        mov byte [jclseen], 1
        mov si, jclcmd
        call krun
        mov si, s_jcl_step
        call kputs
        mov si, jclstep
        call kputs
        mov si, s_jcl_rc
        call kputs
        jmp .nextline
.eoj:
        mov si, s_jcl_end
        call kputs
        jmp .ret
.eof:
        cmp byte [jclseen], 0
        je .ret
        mov si, s_jcl_end
        call kputs
        jmp .ret
.nofile:
        mov si, s_jcl_nofile
        call kputs
.ret:
        mov byte [injcl], 0
        pop bp
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

sskip:
        mov al, [si]
        cmp al, ' '
        jne .d
        inc si
        jmp sskip
.d:
        ret

up_sys:
        cmp al, 'a'
        jb .r
        cmp al, 'z'
        ja .r
        sub al, 32
.r:
        ret

ustr_sys:
        push si
        push ax
.u:
        mov al, [si]
        test al, al
        jz .ud
        call up_sys
        mov [si], al
        inc si
        jmp .u
.ud:
        pop ax
        pop si
        ret

jcl_line:
        mov [jclcur], si
        mov di, si
.scan:
        mov al, [di]
        test al, al
        jz .endbuf
        cmp al, 10
        je .eol
        cmp al, 13
        je .eol
        inc di
        jmp .scan
.eol:
        mov byte [di], 0
        inc di
        cmp al, 13
        jne .done
        cmp byte [di], 10
        jne .done
        inc di
.done:
        mov [jclnext], di
        mov si, [jclcur]
        clc
        ret
.endbuf:
        mov byte [di], 0
        mov [jclnext], di
        mov si, [jclcur]
        stc
        ret

jcl_eoj:
        mov di, jclstep
        cmp byte [di], 'E'
        jne .no
        cmp byte [di+1], 'O'
        jne .no
        cmp byte [di+2], 'J'
        jne .no
        cmp byte [di+3], 0
        jne .no
        stc
        ret
.no:
        clc
        ret

build83_sys:
        push ax
        push bx
        push cx
        push di
        mov di, name83
        mov cx, 11
        mov al, ' '
.fill:
        stosb
        loop .fill
        mov di, name83
        xor cx, cx
.copy:
        mov al, [si]
        test al, al
        jz .def
        cmp al, ' '
        je .def
        cmp al, '.'
        je .ext
        cmp cx, 8
        jae .skip
        call up_sys
        mov [di], al
        inc di
        inc cx
.skip:
        inc si
        jmp .copy
.ext:
        inc si
        mov di, name83+8
        xor cx, cx
.extc:
        mov al, [si]
        test al, al
        jz .done
        cmp al, ' '
        je .done
        cmp cx, 3
        jae .done
        call up_sys
        mov [di], al
        inc di
        inc cx
        inc si
        jmp .extc
.def:
        mov byte [name83+8], 'J'
        mov byte [name83+9], 'C'
        mov byte [name83+10], 'L'
.done:
        pop di
        pop cx
        pop bx
        pop ax
        ret

toupper:
        cmp al, 'a'
        jb .r
        cmp al, 'z'
        ja .r
        sub al, 32
.r:
        ret

; ---- data ----

banner  db 'UMIX.SYS V0R138 - C: COMMANDS: DIR TYPE JCL BASIC', 10, 0

help_text:
db 'COMMANDS:', 10
db '  HELP     THIS LIST', 10
db '  ECHO     PRINT TEXT', 10
db '  CHAT     ENTER CHAT ROOM (CONSOLE+PRIV: CHAT ON|OFF)', 10
db '  CLS      CLEAR SCREEN', 10
db '  MEM      CONVENTIONAL MEMORY', 10
db '  TIME     CMOS CLOCK', 10
db '  VER      VERSION', 10
db '  DRIVE    DRIVE A|B|C|M - MOUNT A VOLUME (M=RAM DISK)', 10
db '  WRITE    WRITE ON|OFF (CONSOLE+PRIV: ENABLE SAVE/DELETE)', 10
db '  VIDEO    VIDEO MONO|COLOR (TEXT ADAPTER)', 10
db '  PANEL    PANEL ON|OFF (PANEL ON THIS CONSOLE)', 10
db '  PREEMPT  PREEMPT ON|OFF (TIMER TASK SWITCH)', 10
db '  MUX      MUX ON|OFF (CONSOLE: FRAMED SERIAL LINK)', 10
db '  FORMAT   FORMAT A:|B: (CONSOLE+WRITE: MAKE FAT12 FLOPPY)', 10
db '  BAUD     BAUD 2400|4800|9600|19200|38400 (CONSOLE)', 10
db '  WEB      WEB ON|OFF (CONSOLE: ENABLE/DISABLE WEB)', 10
db '  WEBLOG   WEBLOG ON|OFF (CONSOLE: LOG WEB REQUESTS)', 10
db '  SPEED    MEASURE CPU CLOCK', 10
db '  QUANTUM  SCHEDULER RATE (CONSOLE+PRIV: 18|50|100|200|500|1000)', 10
db '  PRIV     PRIV ON|OFF (CONSOLE: SYSTEM USER PRIVILEGES)', 10
db '  MORE     MORE ON|OFF|LINES (PAGE ALL OUTPUT)', 10
db '  USERS    LIST USER ACCOUNTS (CONSOLE+PRIV)', 10
db '  USER     ADD|DEL|PASS|SAVE|RESET NAME [PASS] (CONSOLE+PRIV)', 10
db '  WHO      LIST CONSOLES', 10
db '  WHOAMI   CURRENT CONSOLE USER', 10
db '  LOGOFF   SERIAL CONSOLE LOGOFF', 10
db '  BASIC    UMIX BASIC INTERPRETER', 10
db '  COPY     COPY [C:|M:]SRC [C:|M:]DST (M: = RAM DISK)', 10
db '  SAVE     SAVE FILE.SYS ON C: (END WITH .)', 10
db '  DELETE   DELETE FILE.SYS ON C:', 10
db '  RUN      RUN FILE.SYS [!] FROM C:', 10
db '  JCL      RUN JOB CONTROL SCRIPT', 10
db '  EDIT     FULL-SCREEN FILE EDITOR', 10
db '  PS       LIST TASKS (NAME USER CON)', 10
db '  KILL n   FREE TASK SLOT n', 10
db '  SYS      RELOAD UMIX.SYS FROM C:', 10
db '  REBOOT   RESTART', 10
db '  HALT     STOP', 10
db 'DIR and TYPE are provided by UMIX.SYS on C:', 10, 0

s_jcl_cmd db 'JCL', 0
s_jcl_usage db 'USAGE: JCL FILE.JCL', 10, 0
s_jcl_busy db 'JCL ALREADY RUNNING', 10, 0
s_jcl_nofile db 'JOB FILE NOT FOUND', 10, 0
s_jcl_job db 'JOB ', 0
s_jcl_started db ' STARTED', 10, 0
s_jcl_step db 'STEP ', 0
s_jcl_rc db ' RC=0', 10, 0
s_jcl_end db 'JOB ENDED', 10, 0
s_jcl_nocmd db ' NO COMMAND', 10, 0
s_dir   db 'DIR', 0
s_api_cmd db 'API', 0
s_off   db 'OFF', 0
s_api_done db 'API UPDATED', 10, 0
s_panic0 db 'PANIC: DIVIDE ERROR - REBOOT', 10, 0
s_panic6 db 'PANIC: INVALID OPCODE - REBOOT', 10, 0
s_help_cmd db 'HELP', 0
s_type  db 'TYPE', 0
s_usage db 'USAGE: TYPE FILE.EXT', 10, 0
s_nofile db 'FILE NOT FOUND', 10, 0
s_noio  db 'C: READ ERROR', 10, 0
s_dirattr db '<DIR>', 0
hdr     db 'NAME        SIZE', 10, 0
dir_rule db '================', 10, 0
cmdbuf  times 16 db 0
argbuf  times 48 db 0
namebuf times 11 db 0
fsinfo  dw 0, 0, 0
cur_lba dw 0
sec_left dw 0
ent_left dw 0
secbuf  times 512 db 0
filebuf times 8192 db 0
jclbuf  times 1536 db 0
jclcmd  times 104 db 0
jclstep times 10 db 0
jclptr  dw 0
jclcur  dw 0
jclnext dw 0
injcl   db 0
jclseen db 0
name83  times 11 db 0


; ===== BASIC in UMIX.SYS: API wrappers and helpers =====
KERNEL_SEG equ SYS_SEG
MAXLINES equ 48

putc:
        cmp byte [cap_on], 0
        jne cap_store
        mov ah, 0
        int 0x60
        ret
puts:
        cmp byte [cap_on], 0
        jne .cap
        mov ah, 1
        int 0x60
        ret
.cap:
        push si
.cap_l:
        mov al, [si]
        test al, al
        jz .cap_d
        call cap_store
        inc si
        jmp .cap_l
.cap_d:
        pop si
        ret
put_dec:
        cmp byte [cap_on], 0
        jne .cap
        mov bx, ax
        mov ah, 2
        int 0x60
        ret
.cap:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        push ds
        pop es                  ; dec_to_buf uses ES:DI
        mov di, decbuf
        call dec_to_buf
        mov si, decbuf
.cap_l:
        cmp si, di
        jae .cap_d
        mov al, [si]
        call cap_store
        inc si
        jmp .cap_l
.cap_d:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

cap_store:                      ; AL = char -> API output buffer (LF only)
        push ax
        push bx
        push di
        push es
        cmp al, 13
        je .cs_d
        mov di, [cap_len]
        cmp di, [cap_max]
        jae .cs_ov
        add di, [cap_off]
        mov bx, [cap_seg]
        mov es, bx
        stosb
        inc word [cap_len]
        jmp .cs_d
.cs_ov:
        mov byte [cap_err], 1
.cs_d:
        pop es
        pop di
        pop bx
        pop ax
        ret

check_break:
        cmp byte [cap_on], 0
        je .normal
        mov ah, 9
        int 0x60
        sub ax, [cap_start]
        cmp ax, 90
        jb .ok
        mov byte [cap_err], 2
        mov al, 1
        ret
.ok:
        xor al, al
        ret
.normal:
        mov ah, 14
        int 0x60
        ret
ksave:
        mov ah, 12
        int 0x60
        ret
kmount:
        mov ah, 13
        int 0x60
        ret

getline_char:
        mov ah, 10
        int 0x60
        cmp al, 128
        jb .low
        jmp getline_char
.low:
        cmp al, 10
        jne .nl
        cmp byte [eat_lf], 0
        je .ret
        mov byte [eat_lf], 0
        jmp getline_char
.nl:
        cmp al, 13
        jne .other
        mov byte [eat_lf], 1
        ret
.other:
        mov byte [eat_lf], 0
.ret:
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
skip_sp_ptr:
        push ax
        push si
        mov si, [tokptr]
.l:
        mov al, [si]
        cmp al, ' '
        jne .d
        inc si
        jmp .l
.d:
        mov [tokptr], si
        pop si
        pop ax
        ret

kw:
        push si
        push di
        mov di, [tokptr]
.kl:
        mov al, [si]
        test al, al
        jz .kd
        mov ah, [di]
        cmp al, 'a'
        jb .a1
        cmp al, 'z'
        ja .a1
        sub al, 32
.a1:
        cmp ah, 'a'
        jb .a2
        cmp ah, 'z'
        ja .a2
        sub ah, 32
.a2:
        cmp al, ah
        jne .kn
        inc si
        inc di
        jmp .kl
.kd:
        mov al, [di]
        cmp al, 0
        je .ko
        cmp al, ' '
        je .ko
        cmp al, 13
        je .ko
        jmp .kn
.ko:
        mov [tokptr], di
        call skip_sp_ptr
        pop di
        pop si
        mov al, 1
        ret
.kn:
        pop di
        pop si
        mov al, 0
        ret

parse_num_ptr:
        push bx
        push cx
        push dx
        push si
        xor bx, bx
        mov si, [tokptr]
.pl:
        mov al, [si]
        cmp al, '0'
        jb .pd
        cmp al, '9'
        ja .pd
        sub al, '0'
        xor ah, ah
        mov cx, ax
        mov ax, bx
        mov dx, 10
        mul dx
        add ax, cx
        mov bx, ax
        inc si
        jmp .pl
.pd:
        mov [tokptr], si
        mov ax, bx
        pop si
        pop dx
        pop cx
        pop bx
        ret

; ---- expression evaluator ----
; OR < AND < NOT < comparison < + - < * / MOD < unary < ^ < primary
; 16-bit signed; true = -1, false = 0

; ---- typed expression evaluator ----
; OR < AND < NOT < comparison < +- < */MOD < unary < ^ < primary
; ev_type: 0 = number, 1 = string; rt_* = right operand; true = -1

ev_setnum:                      ; AX = number
        mov word [ev_type], 0
        mov [ev_val], ax
        mov word [ev_len], 0
        ret

ev_setstr:                      ; BX = ptr, CX = len
        mov word [ev_type], 1
        mov [ev_val], bx
        mov [ev_len], cx
        ret

%macro EVPUSH 0
        mov ax, [ev_type]
        push ax
        mov ax, [ev_val]
        push ax
        mov ax, [ev_len]
        push ax
%endmacro

%macro EVPOP 0
        pop ax
        mov [ev_len], ax
        pop ax
        mov [ev_val], ax
        pop ax
        mov [ev_type], ax
%endmacro

ev_save_rt:
        mov ax, [ev_type]
        mov [rt_type], ax
        mov ax, [ev_val]
        mov [rt_val], ax
        mov ax, [ev_len]
        mov [rt_len], ax
        ret

ev_typeerr:
        mov si, s_bas_type
        call puts
        mov byte [basstop], 1
        xor ax, ax
        call ev_setnum
        ret

eval_num:
        jmp eval_or

eval_or:
        call eval_and
.or_l:
        call skip_sp_ptr
        mov si, k_or
        call kwx
        cmp al, 1
        jne .or_d
        EVPUSH
        call eval_and
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .or_e
        cmp word [rt_type], 0
        jne .or_e
        mov ax, [ev_val]
        test ax, ax
        jnz .or_t
        mov ax, [rt_val]
        test ax, ax
        jz .or_f
.or_t:
        mov ax, 0xFFFF
        jmp .or_s
.or_f:
        xor ax, ax
.or_s:
        call ev_setnum
        jmp .or_l
.or_e:
        call ev_typeerr
        jmp .or_l
.or_d:
        ret

eval_and:
        call eval_not
.an_l:
        call skip_sp_ptr
        mov si, k_and
        call kwx
        cmp al, 1
        jne .an_d
        EVPUSH
        call eval_not
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .an_e
        cmp word [rt_type], 0
        jne .an_e
        mov ax, [ev_val]
        test ax, ax
        jz .an_f
        mov ax, [rt_val]
        test ax, ax
        jz .an_f
        mov ax, 0xFFFF
        jmp .an_s
.an_f:
        xor ax, ax
.an_s:
        call ev_setnum
        jmp .an_l
.an_e:
        call ev_typeerr
        jmp .an_l
.an_d:
        ret

eval_not:
        call skip_sp_ptr
        mov si, k_not
        call kwx
        cmp al, 1
        jne .not_c
        call eval_not
        cmp word [ev_type], 0
        jne .not_e
        mov ax, [ev_val]
        test ax, ax
        jz .not_t
        xor ax, ax
        jmp .not_s
.not_t:
        mov ax, 0xFFFF
.not_s:
        call ev_setnum
        ret
.not_e:
        call ev_typeerr
        ret
.not_c:
        jmp eval_cmp

eval_cmp:
        call eval_add
        EVPUSH
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        mov byte [cmp_op], 0xFF
        cmp al, '='
        je .eqo
        cmp al, '<'
        je .lto
        cmp al, '>'
        je .gto
        jmp .none
.eqo:
        inc word [tokptr]
        mov byte [cmp_op], 0
        jmp .right
.lto:
        inc word [tokptr]
        mov si, [tokptr]
        mov al, [si]
        cmp al, '>'
        je .neo
        cmp al, '='
        je .leo
        mov byte [cmp_op], 3
        jmp .right
.neo:
        inc word [tokptr]
        mov byte [cmp_op], 1
        jmp .right
.leo:
        inc word [tokptr]
        mov byte [cmp_op], 2
        jmp .right
.gto:
        inc word [tokptr]
        mov si, [tokptr]
        cmp byte [si], '='
        jne .gtonly
        inc word [tokptr]
        mov byte [cmp_op], 4
        jmp .right
.gtonly:
        mov byte [cmp_op], 5
.right:
        call eval_add
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .cstr
        cmp word [rt_type], 0
        jne .cerr
        mov ax, [ev_val]
        mov bx, [rt_val]
        cmp ax, bx
        je .ceq
        jl .clt
        mov dl, 2
        jmp .apply
.ceq:
        xor dl, dl
        jmp .apply
.clt:
        mov dl, 1
        jmp .apply
.cstr:
        cmp word [rt_type], 0
        je .cerr
        call str_cmp
        mov dl, al
        jmp .apply
.cerr:
        call ev_typeerr
        ret
.apply:
        mov cl, [cmp_op]
        cmp cl, 0
        je .a_eq
        cmp cl, 1
        je .a_ne
        cmp cl, 2
        je .a_le
        cmp cl, 3
        je .a_lt
        cmp cl, 4
        je .a_ge
        cmp dl, 2
        je .ct
        jmp .cf
.a_eq:
        cmp dl, 0
        je .ct
        jmp .cf
.a_ne:
        cmp dl, 0
        jne .ct
        jmp .cf
.a_le:
        cmp dl, 1
        je .ct
        cmp dl, 0
        je .ct
        jmp .cf
.a_lt:
        cmp dl, 1
        je .ct
        jmp .cf
.a_ge:
        cmp dl, 2
        je .ct
        cmp dl, 0
        je .ct
        jmp .cf
.ct:
        mov ax, 0xFFFF
        call ev_setnum
        ret
.cf:
        xor ax, ax
        call ev_setnum
        ret
.none:
        EVPOP
        ret

eval_add:
        call eval_term
.en:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        cmp al, '+'
        je .add
        cmp al, '-'
        je .sub
        ret
.add:
        inc word [tokptr]
        EVPUSH
        call eval_term
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .adds
        cmp word [rt_type], 0
        jne .err
        mov ax, [ev_val]
        add ax, [rt_val]
        call ev_setnum
        jmp .en
.adds:
        cmp word [rt_type], 0
        je .err
        call str_concat
        jmp .en
.sub:
        inc word [tokptr]
        EVPUSH
        call eval_term
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .err
        cmp word [rt_type], 0
        jne .err
        mov ax, [ev_val]
        sub ax, [rt_val]
        call ev_setnum
        jmp .en
.err:
        call ev_typeerr
        ret

eval_term:
        call eval_factor
.et:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        cmp al, '*'
        je .mul
        cmp al, '/'
        je .div
        mov si, k_mod
        call kwx
        cmp al, 1
        je .mod
        ret
.mul:
        inc word [tokptr]
        EVPUSH
        call eval_factor
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .terr
        cmp word [rt_type], 0
        jne .terr
        mov ax, [ev_val]
        mul word [rt_val]
        call ev_setnum
        jmp .et
.div:
        inc word [tokptr]
        EVPUSH
        call eval_factor
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .terr
        cmp word [rt_type], 0
        jne .terr
        mov bx, [rt_val]
        test bx, bx
        jz .divz
        mov ax, [ev_val]
        cmp ax, 0x8000
        jne .dvd
        cmp bx, -1
        jne .dvd
        jmp .dset
.dvd:
        cwd
        idiv bx
.dset:
        call ev_setnum
        jmp .et
.mod:
        EVPUSH
        call eval_factor
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .terr
        cmp word [rt_type], 0
        jne .terr
        mov bx, [rt_val]
        test bx, bx
        jz .divz
        mov ax, [ev_val]
        cmp ax, 0x8000
        jne .mdd
        cmp bx, -1
        jne .mdd
        xor ax, ax
        jmp .mset
.mdd:
        cwd
        idiv bx
        mov ax, dx
.mset:
        call ev_setnum
        jmp .et
.divz:
        mov si, s_bas_div0
        call puts
        mov byte [basstop], 1
        xor ax, ax
        call ev_setnum
        ret
.terr:
        call ev_typeerr
        ret

eval_factor:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        cmp al, '+'
        je .pos
        cmp al, '-'
        je .neg
        jmp eval_power
.pos:
        inc word [tokptr]
        call eval_factor
        ret
.neg:
        inc word [tokptr]
        call eval_factor
        cmp word [ev_type], 0
        jne .ferr
        mov ax, [ev_val]
        neg ax
        call ev_setnum
        ret
.ferr:
        call ev_typeerr
        ret

eval_power:
        call eval_primary
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '^'
        jne .pd
        cmp word [ev_type], 0
        jne .perr
        inc word [tokptr]
        EVPUSH
        call eval_factor
        call ev_save_rt
        EVPOP
        cmp word [ev_type], 0
        jne .perr
        cmp word [rt_type], 0
        jne .perr
        mov ax, [ev_val]
        mov bx, [rt_val]
        call int_pow
        call ev_setnum
        ret
.pd:
        ret
.perr:
        call ev_typeerr
        ret

int_pow:                        ; AX = base, BX = exponent -> AX
        push cx
        push dx
        mov cx, ax
        mov ax, 1
        test bx, bx
        js .ip_z
.ip_l:
        test bx, bx
        jz .ip_d
        test bx, 1
        jz .ip_e
        mul cx
.ip_e:
        push ax
        mov ax, cx
        mul cx
        mov cx, ax
        pop ax
        shr bx, 1
        jmp .ip_l
.ip_z:
        xor ax, ax
.ip_d:
        pop dx
        pop cx
        ret

eval_primary:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        cmp al, '('
        je .paren
        cmp al, '"'
        je .strlit
        mov si, k_abs
        call fn_match
        cmp al, 1
        je .f_abs
        mov si, k_int
        call fn_match
        cmp al, 1
        je .f_int
        mov si, k_sgn
        call fn_match
        cmp al, 1
        je .f_sgn
        mov si, k_sqr
        call fn_match
        cmp al, 1
        je .f_sqr
        mov si, k_rnd
        call fn_match
        cmp al, 1
        je .f_rnd
        mov si, k_len
        call fn_match
        cmp al, 1
        je .f_len
        mov si, k_lefts
        call fn_match
        cmp al, 1
        je .f_lefts
        mov si, k_rights
        call fn_match
        cmp al, 1
        je .f_rights
        mov si, k_mids
        call fn_match
        cmp al, 1
        je .f_mids
        mov si, k_instr
        call fn_match
        cmp al, 1
        je .f_instr
        mov si, k_ucases
        call fn_match
        cmp al, 1
        je .f_ucase
        mov si, k_lcases
        call fn_match
        cmp al, 1
        je .f_lcase
        mov si, k_chrs
        call fn_match
        cmp al, 1
        je .f_chrs
        mov si, k_asc
        call fn_match
        cmp al, 1
        je .f_asc
        mov si, k_strs
        call fn_match
        cmp al, 1
        je .f_strs
        mov si, k_vals
        call fn_match
        cmp al, 1
        je .f_vals
        mov si, [tokptr]
        mov al, [si]
        cmp al, '0'
        jb .var
        cmp al, '9'
        ja .var
        call parse_num_ptr
        call ev_setnum
        ret
.paren:
        inc word [tokptr]
        call eval_num
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], ')'
        jne .pdone
        inc word [tokptr]
.pdone:
        ret
.strlit:
        inc word [tokptr]
        mov bx, [tokptr]
        mov si, bx
        xor cx, cx
.sl:
        mov al, [si]
        test al, al
        jz .se
        cmp al, '"'
        je .sq
        inc si
        inc cx
        jmp .sl
.sq:
        inc si
        mov [tokptr], si
        jmp .sset
.se:
        mov [tokptr], si
.sset:
        call ev_setstr
        ret
.var:
        mov si, [tokptr]
        mov al, [si]
        call upcase
        cmp al, 'A'
        jb .zero
        cmp al, 'Z'
        ja .zero
        sub al, 'A'
        xor ah, ah
        mov [tmp_len], ax
        inc word [tokptr]
        mov si, [tokptr]
        cmp byte [si], '$'
        je .strvar
        cmp byte [si], '('
        je .arrnum
        mov ax, [tmp_len]
        shl ax, 1
        mov si, ax
        mov ax, [basvar+si]
        call ev_setnum
        ret
.strvar:
        inc word [tokptr]
        mov si, [tokptr]
        cmp byte [si], '('
        je .arrstr
        mov ax, [tmp_len]
        call str_slot
        mov cl, [bx]
        xor ch, ch
        inc bx
        call ev_setstr
        ret
.arrstr:
        mov ax, [tmp_len]
        call sarr_ensure
        jc .zero
        inc word [tokptr]
        mov ax, [tmp_len]
        push ax
        call get_num_arg
        pop bx
        jc .arrbad
        call eat_rparen
        shl bx, 1
        mov cx, [sarr_cnt+bx]
        test ax, ax
        js .arrbad
        cmp ax, cx
        jae .arrbad
        mov dx, ax
        mov cl, 5
        shl dx, cl
        add dx, [sarr_base+bx]
        mov si, sarr_arena
        add si, dx
        mov cl, [si]
        xor ch, ch
        inc si
        mov bx, si
        call ev_setstr
        ret
.arrnum:
        mov ax, [tmp_len]
        call arr_ensure
        jc .zero
        inc word [tokptr]
        mov ax, [tmp_len]
        push ax
        call get_num_arg
        pop bx
        jc .arrbad
        call eat_rparen
        shl bx, 1
        mov cx, [arr_cnt+bx]
        test ax, ax
        js .arrbad
        cmp ax, cx
        jae .arrbad
        add ax, [arr_base+bx]
        shl ax, 1
        mov si, ax
        mov ax, [arr_arena+si]
        call ev_setnum
        ret
.arrbad:
        mov si, s_bas_subscript
        call puts
        mov byte [basstop], 1
        xor ax, ax
        call ev_setnum
        ret
.zero:
        mov si, [tokptr]
        cmp byte [si], 0
        je .zr
        inc word [tokptr]
.zr:
        xor ax, ax
        call ev_setnum
        ret
.f_abs:
        call get_num_arg
        jc .f_zero
        test ax, ax
        jns .fa_r
        neg ax
.fa_r:
        call ev_setnum
        call eat_rparen
        ret
.f_int:
        call get_num_arg
        jc .f_zero
        call ev_setnum
        call eat_rparen
        ret
.f_sgn:
        call get_num_arg
        jc .f_zero
        test ax, ax
        jz .fs_r
        js .fs_m
        mov ax, 1
        jmp .fs_r
.fs_m:
        mov ax, -1
.fs_r:
        call ev_setnum
        call eat_rparen
        ret
.f_sqr:
        call get_num_arg
        jc .f_zero
        test ax, ax
        jle .f_zero
        mov cx, ax
        xor bx, bx
.sq_l:
        mov ax, bx
        inc ax
        mul ax
        test dx, dx
        jnz .sq_d
        cmp ax, cx
        ja .sq_d
        inc bx
        jmp .sq_l
.sq_d:
        mov ax, bx
        call ev_setnum
        call eat_rparen
        ret
.f_rnd:
        call get_num_arg
        jc .f_zero
        mov bx, ax
        test bx, bx
        jle .f_zero
        mov ax, [bas_seed]
        mov cx, 25173
        mul cx
        add ax, 13849
        mov [bas_seed], ax
        xor dx, dx
        div bx
        mov ax, dx
        call ev_setnum
        call eat_rparen
        ret
.f_zero:
        xor ax, ax
        call ev_setnum
        call eat_rparen
        ret
.f_len:
        call get_str_arg
        jc .f_zero
        mov ax, cx
        call ev_setnum
        call eat_rparen
        ret
.f_lefts:
        call get_str_arg
        jc .f_emptyz
        push cx
        push bx
        call eat_comma
        call get_num_arg
        pop bx
        pop cx
        jc .f_emptyz
        test ax, ax
        jle .f_emptyz
        cmp ax, cx
        jbe .fl_ok
        mov ax, cx
.fl_ok:
        mov cx, ax
        call str_copy_alloc
        call eat_rparen
        ret
.f_rights:
        call get_str_arg
        jc .f_emptyz
        push cx
        push bx
        call eat_comma
        call get_num_arg
        pop bx
        pop cx
        jc .f_emptyz
        test ax, ax
        jle .f_emptyz
        cmp ax, cx
        jbe .fr_ok
        mov ax, cx
.fr_ok:
        mov dx, cx
        mov cx, ax
        sub dx, ax
        add bx, dx
        call str_copy_alloc
        call eat_rparen
        ret
.f_mids:
        call get_str_arg
        jc .f_emptyz
        push cx
        push bx
        call eat_comma
        call get_num_arg
        pop bx
        pop cx
        jc .f_emptyz
        dec ax
        cmp ax, 0
        jge .fm_s
        xor ax, ax
.fm_s:
        push ax
        push cx
        push bx
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], ','
        jne .fm_all
        inc word [tokptr]
        call get_num_arg
        pop bx
        pop cx
        pop dx
        jc .f_emptyz
        cmp dx, cx
        jae .f_emptyz
        sub cx, dx
        cmp ax, cx
        jbe .fm_have
        mov ax, cx
.fm_have:
        test ax, ax
        jle .f_emptyz
        mov cx, ax
        add bx, dx
        call str_copy_alloc
        call eat_rparen
        ret
.fm_all:
        pop bx
        pop cx
        pop dx
        cmp dx, cx
        jae .f_emptyz
        mov ax, cx
        sub ax, dx
        jmp .fm_have
.f_instr:
        call get_str_arg
        jc .f_zero
        push cx
        push bx
        call eat_comma
        call get_str_arg
        pop di
        pop dx
        jc .f_zero
        mov [tmp_ptr], di
        mov [tmp_len], dx
        mov [tmp4], bx
        mov [tmp3], cx
        mov word [tmp2], 0
.in_i:
        mov ax, [tmp_len]
        sub ax, [tmp2]
        cmp ax, [tmp3]
        jb .in_no
        xor bx, bx
.in_j:
        cmp bx, [tmp3]
        jae .in_yes
        mov si, [tmp_ptr]
        add si, [tmp2]
        add si, bx
        mov al, [si]
        mov di, [tmp4]
        add di, bx
        cmp al, [di]
        jne .in_nx
        inc bx
        jmp .in_j
.in_nx:
        inc word [tmp2]
        jmp .in_i
.in_yes:
        mov ax, [tmp2]
        inc ax
        call ev_setnum
        call eat_rparen
        ret
.in_no:
        xor ax, ax
        call ev_setnum
        call eat_rparen
        ret
.f_ucase:
        call get_str_arg
        jc .f_emptyz
        call str_copy_alloc
        mov si, [ev_val]
        mov cx, [ev_len]
.uc_l:
        jcxz .uc_d
        mov al, [si]
        cmp al, 'a'
        jb .uc_n
        cmp al, 'z'
        ja .uc_n
        sub al, 32
        mov [si], al
.uc_n:
        inc si
        dec cx
        jmp .uc_l
.uc_d:
        call eat_rparen
        ret
.f_lcase:
        call get_str_arg
        jc .f_emptyz
        call str_copy_alloc
        mov si, [ev_val]
        mov cx, [ev_len]
.lc_l:
        jcxz .lc_d
        mov al, [si]
        cmp al, 'A'
        jb .lc_n
        cmp al, 'Z'
        ja .lc_n
        add al, 32
        mov [si], al
.lc_n:
        inc si
        dec cx
        jmp .lc_l
.lc_d:
        call eat_rparen
        ret
.f_chrs:
        call get_num_arg
        jc .f_emptyz
        test ax, ax
        jz .f_emptyz
        mov [tmp2], ax
        mov cx, 1
        call str_alloc
        mov al, [tmp2]
        mov [bx], al
        mov cx, 1
        call ev_setstr
        call eat_rparen
        ret
.f_asc:
        call get_str_arg
        jc .f_zero
        test cx, cx
        jz .f_zero
        mov al, [bx]
        xor ah, ah
        call ev_setnum
        call eat_rparen
        ret
.f_strs:
        call get_num_arg
        jc .f_emptyz
        mov [tmp2], ax
        mov cx, 6
        call str_alloc
        mov [tmp_ptr], bx
        push es
        mov ax, ds
        mov es, ax
        mov di, bx
        mov ax, [tmp2]
        call dec_to_buf
        pop es
        mov cx, di
        sub cx, [tmp_ptr]
        mov bx, [tmp_ptr]
        call ev_setstr
        call eat_rparen
        ret
.f_vals:
        call get_str_arg
        jc .f_zero
        mov si, bx
        mov word [tmp_ptr], 0
        mov word [tmp_val], 0
        cmp cx, 0
        je .va_end
        mov al, [si]
        cmp al, '-'
        jne .va_plus
        mov word [tmp_ptr], 1
        inc si
        dec cx
        jmp .va_l
.va_plus:
        cmp al, '+'
        jne .va_l
        inc si
        dec cx
.va_l:
        jcxz .va_end
        mov al, [si]
        cmp al, '0'
        jb .va_end
        cmp al, '9'
        ja .va_end
        sub al, '0'
        xor ah, ah
        mov [tmp2], ax
        mov ax, [tmp_val]
        mov dx, 10
        mul dx
        add ax, [tmp2]
        mov [tmp_val], ax
        inc si
        dec cx
        jmp .va_l
.va_end:
        mov ax, [tmp_val]
        cmp word [tmp_ptr], 0
        je .va_set
        neg ax
.va_set:
        call ev_setnum
        call eat_rparen
        ret
.f_emptyz:
        xor cx, cx
        mov bx, str_arena
        call ev_setstr
        call eat_rparen
        ret

get_num_arg:
        call eval_num
        cmp word [ev_type], 0
        jne .gn_e
        mov ax, [ev_val]
        clc
        ret
.gn_e:
        call ev_typeerr
        stc
        ret

get_str_arg:
        call eval_num
        cmp word [ev_type], 1
        jne .gs_e
        mov bx, [ev_val]
        mov cx, [ev_len]
        clc
        ret
.gs_e:
        call ev_typeerr
        stc
        ret

eat_comma:
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], ','
        jne .ec_r
        inc word [tokptr]
.ec_r:
        ret

eat_rparen:
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], ')'
        jne .er_r
        inc word [tokptr]
.er_r:
        ret

; AX = letter index 0..25 -> BX = string slot
str_slot:
        push cx
        mov cl, 6
        shl ax, cl
        mov bx, bas_str
        add bx, ax
        pop cx
        ret

; BX = slot, ev_* = string -> copy (max 63) and set the length byte
str_store_slot:
        push si
        push di
        push cx
        mov di, bx
        mov cx, [ev_len]
        cmp cx, 63
        jbe .ss1
        mov cx, 63
.ss1:
        mov [di], cl
        inc di
        mov si, [ev_val]
.ss2:
        jcxz .ss3
        mov al, [si]
        mov [di], al
        inc si
        inc di
        dec cx
        jmp .ss2
.ss3:
        pop cx
        pop di
        pop si
        ret

; BX = source, CX = length -> allocate and set ev string
str_copy_alloc:
        push bx
        push cx
        call str_alloc
        pop cx
        pop si
        push bx
        push cx
        mov di, bx
.sc_l:
        jcxz .sc_d
        mov al, [si]
        mov [di], al
        inc si
        inc di
        dec cx
        jmp .sc_l
.sc_d:
        pop cx
        pop bx
        call ev_setstr
        ret

; CX = length -> BX = buffer, CF on overflow (message printed)
str_alloc:
        mov ax, [sa_ptr]
        add ax, cx
        cmp ax, 512
        ja .sa_e
        mov bx, str_arena
        add bx, [sa_ptr]
        mov [sa_ptr], ax
        clc
        ret
.sa_e:
        mov si, s_bas_str
        call puts
        mov byte [basstop], 1
        xor cx, cx
        mov bx, str_arena
        stc
        ret

; concatenate ev_* and rt_* -> ev_* (max 63 chars)
str_concat:
        mov ax, [ev_len]
        add ax, [rt_len]
        cmp ax, 63
        jbe .cc_ok
        mov ax, 63
.cc_ok:
        mov [tmp_len], ax
        mov cx, ax
        call str_alloc
        mov [tmp_ptr], bx
        mov di, bx
        mov si, [ev_val]
        mov cx, [ev_len]
        cmp cx, 63
        jbe .cc_c1
        mov cx, 63
.cc_c1:
        jcxz .cc_c2
        mov al, [si]
        mov [di], al
        inc si
        inc di
        dec cx
        jmp .cc_c1
.cc_c2:
        mov cx, [ev_len]
        cmp cx, 63
        jbe .cc_c2b
        mov cx, 63
.cc_c2b:
        mov ax, [tmp_len]
        sub ax, cx
        jbe .cc_c4
        mov cx, ax
        mov si, [rt_val]
.cc_c3:
        jcxz .cc_c4
        mov al, [si]
        mov [di], al
        inc si
        inc di
        dec cx
        jmp .cc_c3
.cc_c4:
        mov bx, [tmp_ptr]
        mov cx, [tmp_len]
        call ev_setstr
        ret

; compare ev_* with rt_* -> AX = 0 equal, 1 less, 2 greater
str_cmp:
        push si
        push di
        push cx
        push dx
        mov si, [ev_val]
        mov di, [rt_val]
        mov cx, [ev_len]
        mov dx, [rt_len]
.cp_l:
        cmp cx, 0
        je .cp_le
        cmp dx, 0
        je .cp_gt
        mov al, [si]
        mov ah, [di]
        cmp al, ah
        jb .cp_lt
        ja .cp_gt
        inc si
        inc di
        dec cx
        dec dx
        jmp .cp_l
.cp_le:
        cmp dx, 0
        je .cp_eq
        jmp .cp_lt
.cp_eq:
        xor ax, ax
        jmp .cp_d
.cp_lt:
        mov ax, 1
        jmp .cp_d
.cp_gt:
        mov ax, 2
.cp_d:
        pop dx
        pop cx
        pop di
        pop si
        ret

; AX = letter index -> allocate 11 numeric elements if not dimensioned
arr_ensure:
        push bx
        push cx
        push dx
        push si
        mov bx, ax
        shl bx, 1
        cmp word [arr_cnt+bx], 0
        jne .ae_ok
        mov ax, [arr_next]
        add ax, 11
        cmp ax, 512
        ja .ae_e
        mov dx, [arr_next]
        mov [arr_base+bx], dx
        mov word [arr_cnt+bx], 11
        mov [arr_next], ax
        mov si, dx
        shl si, 1
        mov cx, 11
.ae_z:
        mov word [arr_arena+si], 0
        add si, 2
        loop .ae_z
.ae_ok:
        clc
        jmp .ae_d
.ae_e:
        mov si, s_bas_array
        call puts
        mov byte [basstop], 1
        stc
.ae_d:
        pop si
        pop dx
        pop cx
        pop bx
        ret

; AX = letter index -> allocate 11 string elements (32 bytes each) if needed
sarr_ensure:
        push bx
        push cx
        push dx
        push si
        mov bx, ax
        shl bx, 1
        cmp word [sarr_cnt+bx], 0
        jne .se_ok
        mov ax, [sarr_next]
        add ax, 11*32
        cmp ax, 1024
        ja .se_e
        mov dx, [sarr_next]
        mov [sarr_base+bx], dx
        mov word [sarr_cnt+bx], 11
        mov [sarr_next], ax
        mov si, sarr_arena
        add si, dx
        mov cx, 11*32
        xor al, al
.se_z:
        mov [si], al
        inc si
        loop .se_z
.se_ok:
        clc
        jmp .se_d
.se_e:
        mov si, s_bas_array
        call puts
        mov byte [basstop], 1
        stc
.se_d:
        pop si
        pop dx
        pop cx
        pop bx
        ret

; keyword match for expressions: word boundary, advances tokptr + spaces
kwx:
        push si
        push di
        mov di, [tokptr]
.kl:
        mov al, [si]
        test al, al
        jz .kd
        mov ah, [di]
        cmp ah, 'a'
        jb .a1
        cmp ah, 'z'
        ja .a1
        sub ah, 32
.a1:
        call upcase
        cmp al, ah
        jne .kn
        inc si
        inc di
        jmp .kl
.kd:
        mov al, [di]
        cmp al, 'A'
        jb .lo
        cmp al, 'Z'
        jbe .kn
        cmp al, 'a'
        jb .ok
        cmp al, 'z'
        jbe .kn
        jmp .ok
.lo:
        cmp al, '$'
        je .kn
        cmp al, '0'
        jb .ok
        cmp al, '9'
        jbe .kn
.ok:
        mov [tokptr], di
        call skip_sp_ptr
        pop di
        pop si
        mov al, 1
        ret
.kn:
        pop di
        pop si
        xor al, al
        ret

; function name + '(' : consumes the '('
fn_match:
        push bx
        mov bx, [tokptr]
        call kwx
        cmp al, 1
        jne .fm_n
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '('
        je .fm_y
        mov [tokptr], bx
.fm_n:
        xor al, al
        pop bx
        ret
.fm_y:
        inc word [tokptr]
        mov al, 1
        pop bx
        ret

print_num:
        test ax, ax
        jns .p
        push ax
        mov al, '-'
        call putc
        pop ax
        neg ax
.p:
        call put_dec
        ret

bas_readline:
        mov di, basline
        xor cx, cx
bas_readline_at:
.rl:
        call getline_char
        cmp al, 3
        je .rc
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
        cmp cx, 120
        jae .rl
        stosb
        inc cx
        call putc
        jmp .rl
.rb:
        test cx, cx
        jz .rl
        dec cx
        dec di
        mov al, 8
        call putc
        mov al, ' '
        call putc
        mov al, 8
        call putc
        jmp .rl
.rc:
        mov al, 10
        call putc
        xor cx, cx
        mov di, basline
        mov byte [di], 0
        ret
.rd:
        mov al, 10
        call putc
        mov byte [di], 0
        ret

bas_find_line:
        mov [bas_target], ax
        push bx
        push cx
        push di
        xor di, di
        mov cx, MAXLINES
.fl:
        mov ax, [basprog+di]
        cmp ax, [bas_target]
        je .ff
        add di, 64
        loop .fl
        mov ax, 0xFFFF
        jmp .fo
.ff:
        mov ax, di
        mov cl, 6
        shr ax, cl
.fo:
        pop di
        pop cx
        pop bx
        ret

bas_store:
        mov [tokptr], si
        call parse_num_ptr
        mov [bas_target], ax
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], 0
        jne .ins
        mov ax, [bas_target]
        call bas_find_line
        cmp ax, 0xFFFF
        je .sdone
        mov bx, ax
        mov cx, MAXLINES
        sub cx, bx
        dec cx
        jcxz .zero
        mov si, bx
        inc si
        mov cl, 6
        shl si, cl
        add si, basprog
        mov di, bx
        shl di, cl
        add di, basprog
        mov dx, cx
        push cx
        mov cl, 6
        shl dx, cl
        pop cx
        mov cx, dx
        cld
        rep movsb
.zero:
        mov di, (MAXLINES-1)*64
        add di, basprog
        mov cx, 32
        xor ax, ax
        rep stosw
        jmp .sdone
.ins:
        mov ax, [bas_target]
        call bas_find_line
        cmp ax, 0xFFFF
        je .new
        mov di, ax
        mov cl, 6
        shl di, cl
        add di, basprog+2
        mov si, [tokptr]
        mov cx, 61
.cp:
        mov al, [si]
        test al, al
        jz .cpz
        mov [di], al
        inc si
        inc di
        dec cx
        jnz .cp
.cpz:
        mov byte [di], 0
        jmp .sdone
.new:
        xor di, di
        xor bx, bx
        mov cx, MAXLINES
.scan:
        mov ax, [basprog+di]
        test ax, ax
        jz .insert
        cmp ax, [bas_target]
        ja .insert
        add di, 64
        inc bx
        loop .scan
        mov si, s_bas_full
        call puts
        jmp .sdone
.insert:
        mov cx, MAXLINES
        sub cx, bx
        dec cx
        jcxz .put
        mov si, (MAXLINES-2)*64+63
        add si, basprog
        mov di, si
        add di, 64
        mov dx, cx
        push cx
        mov cl, 6
        shl dx, cl
        pop cx
        mov cx, dx
        std
        rep movsb
        cld
.put:
        mov di, bx
        mov cl, 6
        shl di, cl
        add di, basprog
        mov ax, [bas_target]
        mov [di], ax
        add di, 2
        mov si, [tokptr]
        mov cx, 61
.cp2:
        mov al, [si]
        test al, al
        jz .cp2z
        mov [di], al
        inc si
        inc di
        dec cx
        jnz .cp2
.cp2z:
        mov byte [di], 0
.sdone:
        ret

bas_new:
        mov di, basprog
        mov cx, MAXLINES*32
        xor ax, ax
        rep stosw
        mov di, basvar
        mov cx, 26
        rep stosw
        mov di, arr_cnt
        mov cx, 26
        rep stosw
        mov di, sarr_cnt
        mov cx, 26
        rep stosw
        mov word [arr_next], 0
        mov word [sarr_next], 0
        mov word [sa_ptr], 0
        mov di, bas_str
        mov cx, 26
.bn_clr:
        mov byte [di], 0
        add di, 64
        loop .bn_clr
        mov byte [bas_for_sp], 0
        mov byte [bas_gsub_sp], 0
        mov byte [bas_else_stop], 0
        ret

bas_list:
        push cx
        push di
        xor di, di
        mov cx, MAXLINES
.ll:
        mov ax, [basprog+di]
        test ax, ax
        jz .ln
        call print_num
        mov al, ' '
        call putc
        push cx
        push di
        mov si, di
        add si, basprog+2
.lp:
        mov al, [si]
        test al, al
        jz .lpz
        call putc
        inc si
        jmp .lp
.lpz:
        mov al, 10
        call putc
        pop di
        pop cx
.ln:
        add di, 64
        loop .ll
        pop di
        pop cx
        ret

bas_run:
        push es
        mov ax, ds
        mov es, ax
        mov di, basvar
        mov cx, 26
        xor ax, ax
        rep stosw
        mov di, arr_cnt
        mov cx, 26
        rep stosw
        mov di, sarr_cnt
        mov cx, 26
        rep stosw
        mov word [arr_next], 0
        mov word [sarr_next], 0
        mov word [sa_ptr], 0
        pop es
        mov di, bas_str
        mov cx, 26
.brs_clr:
        mov byte [di], 0
        add di, 64
        loop .brs_clr
        cmp byte [cap_on], 0
        je .brs_np
        mov si, apipath
        mov di, bas_str + 15*64     ; P$
        call set_str_var
        mov si, api_qstr
        mov di, bas_str + 16*64     ; Q$
        call set_str_var
        mov si, api_mstr
        mov di, bas_str + 12*64     ; M$
        call set_str_var
        mov si, api_bstr
        mov di, bas_str + 1*64      ; B$
        call set_str_var
.brs_np:
        mov byte [bas_for_sp], 0
        mov byte [bas_gsub_sp], 0
        mov byte [bas_else_stop], 0
        mov ax, [bas_start]
        mov [runidx], ax
        mov byte [basstop], 0
        mov byte [inrun], 1
        mov byte [bas_yield], 128
        jmp bas_loop
bas_run_at:
        mov byte [basstop], 0
        mov byte [inrun], 1
bas_loop:
        ; Give the other tasks (chat, shells) a slice even if the tick
        ; happens to be delayed; the INT 61h lock keeps this interpreter
        ; single-instance.
        dec byte [bas_yield]
        jnz .by_continue
        mov byte [bas_yield], 128
        mov ah, 7
        int 0x60
.by_continue:
        mov ax, [runidx]
        cmp ax, MAXLINES
        jae .bdone
        mov bx, ax
        mov cl, 6
        shl bx, cl
        add bx, basprog
        mov ax, [bx]
        test ax, ax
        jz .bnext
        add bx, 2
        mov [tokptr], bx
        mov word [jumpidx], 0xFFFF
        call check_break
        test al, al
        jz .bnobrk
        mov si, s_break
        call puts
        jmp .bdone
.bnobrk:
        mov byte [bas_else_stop], 0
        call bas_exec_seq
        cmp byte [basstop], 0
        jne .bdone
        cmp word [jumpidx], 0xFFFF
        je .badv
        mov ax, [jumpidx]
        mov [runidx], ax
        jmp bas_loop
.badv:
        inc word [runidx]
        jmp bas_loop
.bnext:
        inc word [runidx]
        jmp bas_loop
.bdone:
        mov byte [inrun], 0
        ret

st_end:
        mov byte [basstop], 1
        ret

st_cls:
        mov ah, 15
        int 0x60
        ret

st_goto:
        call parse_num_ptr
        call bas_find_line
        cmp ax, 0xFFFF
        je .gbad
        mov [jumpidx], ax
        cmp byte [inrun], 0
        jne .gret
        mov [runidx], ax
        call bas_run_at
.gret:
        ret
.gbad:
        mov si, s_bas_noline
        call puts
        ret
st_input:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        call upcase
        cmp al, 'A'
        jb .ibad
        cmp al, 'Z'
        ja .ibad
        sub al, 'A'
        xor ah, ah
        mov [tmp_len], ax
        inc word [tokptr]
        mov si, [tokptr]
        cmp byte [si], '$'
        je .istr
        mov ax, [tmp_len]
        shl ax, 1
        mov [bas_vidx], ax
        mov al, '?'
        call putc
        mov al, ' '
        call putc
        call bas_readline
        mov word [tokptr], basline
        call parse_num_ptr
        mov bx, [bas_vidx]
        mov [basvar+bx], ax
        ret
.istr:
        inc word [tokptr]
        mov al, '?'
        call putc
        mov al, ' '
        call putc
        mov ax, [tmp_len]
        call str_slot
        mov di, bx
        inc di
        xor cx, cx
.is_rl:
        call getline_char
        cmp al, 13
        je .is_d
        cmp al, 10
        je .is_d
        cmp al, 8
        je .is_b
        cmp al, 127
        je .is_b
        cmp al, 32
        jb .is_rl
        cmp cx, 63
        jae .is_rl
        mov [di], al
        inc di
        inc cx
        call putc
        jmp .is_rl
.is_b:
        test cx, cx
        jz .is_rl
        dec cx
        dec di
        mov al, 8
        call putc
        mov al, ' '
        call putc
        mov al, 8
        call putc
        jmp .is_rl
.is_d:
        mov al, 10
        call putc
        mov ax, [tmp_len]
        call str_slot
        mov [bx], cl
        ret
.ibad:
        mov si, s_bas_syntax
        call puts
        ret
st_let:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        call upcase
        cmp al, 'A'
        jb .lbad
        cmp al, 'Z'
        ja .lbad
        sub al, 'A'
        xor ah, ah
        mov [tmp_len], ax
        inc word [tokptr]
        mov si, [tokptr]
        cmp byte [si], '$'
        je .lstr
        cmp byte [si], '('
        je .larr
        mov ax, [tmp_len]
        shl ax, 1
        mov [bas_vidx], ax
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '='
        jne .lbad
        inc word [tokptr]
        call eval_num
        cmp word [ev_type], 0
        jne .ltype
        mov bx, [bas_vidx]
        mov ax, [ev_val]
        mov [basvar+bx], ax
        ret
.lstr:
        inc word [tokptr]
        mov si, [tokptr]
        cmp byte [si], '('
        je .lsarr
        mov ax, [tmp_len]
        call str_slot
        push bx
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '='
        jne .lbad_pop
        inc word [tokptr]
        call eval_num
        cmp word [ev_type], 1
        pop bx
        jne .ltype
        call str_store_slot
        ret
.lbad_pop:
        pop bx
        jmp .lbad
.lsarr:
        mov ax, [tmp_len]
        call sarr_ensure
        jc .lbad
        inc word [tokptr]
        mov ax, [tmp_len]
        push ax
        call get_num_arg
        pop bx
        jc .lbad
        call eat_rparen
        shl bx, 1
        mov cx, [sarr_cnt+bx]
        test ax, ax
        js .lbad
        cmp ax, cx
        jae .lbad
        mov dx, ax
        mov cl, 5
        shl dx, cl
        add dx, [sarr_base+bx]
        mov si, sarr_arena
        add si, dx
        push si
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '='
        jne .lbad_pop3
        inc word [tokptr]
        call eval_num
        cmp word [ev_type], 1
        pop di
        jne .ltype
        mov cx, [ev_len]
        cmp cx, 31
        jbe .ls_ok
        mov cx, 31
.ls_ok:
        mov [di], cl
        inc di
        mov si, [ev_val]
        jcxz .ls_done
.ls_cp:
        mov al, [si]
        mov [di], al
        inc si
        inc di
        dec cx
        jnz .ls_cp
.ls_done:
        ret
.lbad_pop3:
        pop si
        jmp .lbad
.larr:
        mov ax, [tmp_len]
        call arr_ensure
        jc .lbad
        inc word [tokptr]
        mov ax, [tmp_len]
        push ax
        call get_num_arg
        pop bx
        jc .lbad
        call eat_rparen
        shl bx, 1
        mov cx, [arr_cnt+bx]
        test ax, ax
        js .lbad
        cmp ax, cx
        jae .lbad
        add ax, [arr_base+bx]
        shl ax, 1
        push ax
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '='
        jne .lbad_pop2
        inc word [tokptr]
        call eval_num
        cmp word [ev_type], 0
        pop si
        jne .ltype
        mov ax, [ev_val]
        mov [arr_arena+si], ax
        ret
.lbad_pop2:
        pop si
        jmp .lbad
.ltype:
        mov si, s_bas_type
        call puts
        mov byte [basstop], 1
        ret
.lbad:
        mov si, s_bas_syntax
        call puts
        ret
st_print:
        mov byte [prsemi], 0
.pl:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        test al, al
        jz .pend
        mov byte [prsemi], 0
        cmp al, '"'
        je .pstr
        call eval_num
        cmp word [ev_type], 1
        je .pstrv
        mov ax, [ev_val]
        call print_num
        jmp .psep
.pstrv:
        mov si, [ev_val]
        mov cx, [ev_len]
.pv_l:
        jcxz .psep
        mov al, [si]
        call putc
        inc si
        dec cx
        jmp .pv_l
.pstr:
        inc word [tokptr]
        mov si, [tokptr]
.psl:
        mov al, [si]
        test al, al
        jz .psend
        cmp al, 34
        je .psc
        call putc
        inc si
        jmp .psl
.psc:
        inc si
        mov [tokptr], si
        jmp .psep
.psend:
        mov [tokptr], si
.psep:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        cmp al, ','
        je .pcoma
        cmp al, ';'
        je .psemi
        jmp .pend
.pcoma:
        inc word [tokptr]
        mov byte [prsemi], 1
        jmp .pl
.psemi:
        inc word [tokptr]
        mov byte [prsemi], 1
        jmp .pl
.pend:
        cmp byte [prsemi], 0
        jne .pret
        mov al, 10
        call putc
.pret:
        ret

st_if:
        call eval_num
        cmp word [ev_type], 0
        jne .iftype
        mov ax, [ev_val]
        push ax
        call skip_sp_ptr
        mov si, k_then
        call kw
        cmp al, 1
        je .have
        pop ax
        mov si, s_bas_syntax
        call puts
        ret
.have:
        pop ax
        test ax, ax
        jnz .true
        call find_else
        cmp ax, 0
        je .if_done
        mov [tokptr], ax
        call .clause
        ret
.true:
        mov byte [bas_else_stop], 1
        call bas_exec_seq
        mov byte [bas_else_stop], 0
        call find_else
        cmp ax, 0
        je .if_done
        call skip_to_eol
.if_done:
        ret
.iftype:
        call ev_typeerr
        ret
.clause:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        cmp al, '0'
        jb .cl_stmt
        cmp al, '9'
        ja .cl_stmt
        jmp st_goto
.cl_stmt:
        jmp bas_exec_seq

; AX = pointer after ELSE, or 0. Quoted strings are skipped.
find_else:
        push si
        mov si, [tokptr]
        xor dl, dl
.fe_l:
        mov al, [si]
        test al, al
        jz .fe_n
        cmp al, '"'
        jne .fe_q
        xor dl, 1
        inc si
        jmp .fe_l
.fe_q:
        test dl, dl
        jnz .fe_nx
        mov al, [si]
        call upcase
        cmp al, 'E'
        jne .fe_nx
        mov al, [si+1]
        call upcase
        cmp al, 'L'
        jne .fe_nx
        mov al, [si+2]
        call upcase
        cmp al, 'S'
        jne .fe_nx
        mov al, [si+3]
        call upcase
        cmp al, 'E'
        jne .fe_nx
        mov al, [si+4]
        cmp al, 'A'
        jb .fe_lo
        cmp al, 'Z'
        jbe .fe_nx
        cmp al, 'a'
        jb .fe_ok
        cmp al, 'z'
        jbe .fe_nx
        jmp .fe_ok
.fe_lo:
        cmp al, '$'
        je .fe_nx
        cmp al, '0'
        jb .fe_ok
        cmp al, '9'
        jbe .fe_nx
.fe_ok:
        mov ax, si
        add ax, 4
        jmp .fe_d
.fe_nx:
        inc si
        jmp .fe_l
.fe_n:
        xor ax, ax
.fe_d:
        pop si
        ret

skip_to_eol:
        mov si, [tokptr]
.st_l:
        cmp byte [si], 0
        je .st_d
        inc si
        jmp .st_l
.st_d:
        mov [tokptr], si
        ret

; execute statements separated by ':'
bas_exec_seq:
.seq_l:
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], 0
        je .seq_d
        cmp byte [bas_else_stop], 0
        je .seq_x
        mov si, k_else
        call kwx
        cmp al, 1
        je .seq_d
.seq_x:
        call bas_exec
        cmp byte [basstop], 0
        jne .seq_d
        cmp word [jumpidx], 0xFFFF
        jne .seq_d
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], ':'
        jne .seq_d
        inc word [tokptr]
        jmp .seq_l
.seq_d:
        ret

; ---- GOSUB / RETURN ----
st_gosub:
        call parse_num_ptr
        call bas_find_line
        cmp ax, 0xFFFF
        je .gs_bad
        cmp byte [inrun], 0
        je .gs_inter
        mov bl, [bas_gsub_sp]
        cmp bl, 16
        jae .gs_full
        xor bh, bh
        shl bx, 1
        mov dx, [runidx]
        mov [bas_gsub_stk+bx], dx
        inc byte [bas_gsub_sp]
        mov [jumpidx], ax
        ret
.gs_inter:
        mov [runidx], ax
        call bas_run_at
        ret
.gs_bad:
        mov si, s_bas_noline
        call puts
        ret
.gs_full:
        mov si, s_bas_gosub
        call puts
        mov byte [basstop], 1
        ret

st_return:
        cmp byte [inrun], 0
        je .rt_done
        mov bl, [bas_gsub_sp]
        test bl, bl
        jz .rt_bad
        dec byte [bas_gsub_sp]
        dec bl
        xor bh, bh
        shl bx, 1
        mov ax, [bas_gsub_stk+bx]
        inc ax
        mov [jumpidx], ax
        ret
.rt_bad:
        mov si, s_bas_return
        call puts
        mov byte [basstop], 1
.rt_done:
        ret

; ---- FOR / NEXT ----
parse_var:                      ; -> AX = variable byte offset, CF on error
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        call upcase
        cmp al, 'A'
        jb .pv_bad
        cmp al, 'Z'
        ja .pv_bad
        sub al, 'A'
        xor ah, ah
        shl ax, 1
        inc word [tokptr]
        clc
        ret
.pv_bad:
        stc
        ret

st_for:
        call parse_var
        jc .fr_syn
        mov [bas_vidx], ax
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '='
        jne .fr_syn
        inc word [tokptr]
        call eval_num
        cmp word [ev_type], 0
        jne .fr_syn
        mov ax, [ev_val]
        mov [bas_tmp0], ax
        call skip_sp_ptr
        mov si, k_to
        call kwx
        cmp al, 1
        jne .fr_syn
        call eval_num
        cmp word [ev_type], 0
        jne .fr_syn
        mov ax, [ev_val]
        mov [bas_tmp1], ax
        mov word [bas_tmp2], 1
        call skip_sp_ptr
        mov si, k_step
        call kwx
        cmp al, 1
        jne .fr_nostep
        call eval_num
        cmp word [ev_type], 0
        jne .fr_syn
        mov ax, [ev_val]
        mov [bas_tmp2], ax
.fr_nostep:
        mov bx, [bas_vidx]
        mov ax, [bas_tmp0]
        mov [basvar+bx], ax
        mov cx, [bas_tmp2]
        test cx, cx
        js .fr_neg
        cmp ax, [bas_tmp1]
        jg .fr_skip
        jmp .fr_enter
.fr_neg:
        cmp ax, [bas_tmp1]
        jl .fr_skip
.fr_enter:
        mov bl, [bas_for_sp]
        cmp bl, 16
        jae .fr_full
        xor bh, bh
        mov si, bx
        shl si, 1
        mov ax, [bas_vidx]
        mov [bas_for_var+si], ax
        mov ax, [bas_tmp1]
        mov [bas_for_lim+si], ax
        mov ax, [bas_tmp2]
        mov [bas_for_step+si], ax
        mov ax, [runidx]
        mov [bas_for_line+si], ax
        inc byte [bas_for_sp]
        ret
.fr_skip:
        jmp bas_skip_for
.fr_full:
        mov si, s_bas_for
        call puts
        mov byte [basstop], 1
        ret
.fr_syn:
        mov si, s_bas_syntax
        call puts
        ret

st_next:
        call skip_sp_ptr
        mov byte [bas_tmp6], 0
        mov si, [tokptr]
        mov al, [si]
        call upcase
        cmp al, 'A'
        jb .nx_novar
        cmp al, 'Z'
        ja .nx_novar
        call parse_var
        mov [bas_tmp5], ax
        mov byte [bas_tmp6], 1
        call skip_sp_ptr
.nx_novar:
        mov bl, [bas_for_sp]
        test bl, bl
        jz .nx_bad
        dec bl
        xor bh, bh
        mov si, bx
        shl si, 1
        cmp byte [bas_tmp6], 0
        je .nx_match
        mov ax, [bas_tmp5]
        cmp ax, [bas_for_var+si]
        jne .nx_bad
.nx_match:
        mov di, [bas_for_var+si]
        mov ax, [basvar+di]
        add ax, [bas_for_step+si]
        mov [basvar+di], ax
        mov cx, [bas_for_step+si]
        test cx, cx
        js .nx_neg
        cmp ax, [bas_for_lim+si]
        jle .nx_again
        jmp .nx_fin
.nx_neg:
        cmp ax, [bas_for_lim+si]
        jge .nx_again
.nx_fin:
        dec byte [bas_for_sp]
        ret
.nx_again:
        mov ax, [bas_for_line+si]
        inc ax
        mov [jumpidx], ax
        ret
.nx_bad:
        mov si, s_bas_next
        call puts
        mov byte [basstop], 1
        ret

; classify a line's text: AL=1 FOR, 2 NEXT, 0 other
bas_line_kind:
        push bx
        push si
        push di
        mov bx, [tokptr]
        mov [tokptr], si
        mov si, k_for
        call kw
        cmp al, 1
        je .lk_for
        mov si, k_next
        call kw
        cmp al, 1
        je .lk_next
        xor al, al
        jmp .lk_d
.lk_for:
        mov al, 1
        jmp .lk_d
.lk_next:
        mov al, 2
.lk_d:
        mov [tokptr], bx
        pop di
        pop si
        pop bx
        ret

; skip the body of a FOR whose start value is already past its limit
bas_skip_for:
        mov word [bas_tmp3], 0
        mov ax, [runidx]
        inc ax
.sf_l:
        cmp ax, MAXLINES
        jae .sf_err
        mov [bas_tmp4], ax
        mov bx, ax
        mov cl, 6
        shl bx, cl
        add bx, basprog
        cmp word [bx], 0
        je .sf_err
        mov si, bx
        add si, 2
        call bas_line_kind
        cmp al, 1
        je .sf_inc
        cmp al, 2
        je .sf_dec
        jmp .sf_next
.sf_inc:
        inc word [bas_tmp3]
        jmp .sf_next
.sf_dec:
        cmp word [bas_tmp3], 0
        je .sf_found
        dec word [bas_tmp3]
.sf_next:
        mov ax, [bas_tmp4]
        inc ax
        jmp .sf_l
.sf_found:
        mov ax, [bas_tmp4]
        inc ax
        mov [jumpidx], ax
        ret
.sf_err:
        mov si, s_bas_next
        call puts
        mov byte [basstop], 1
        ret

st_dim:
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        call upcase
        cmp al, 'A'
        jb .dm_bad
        cmp al, 'Z'
        ja .dm_bad
        sub al, 'A'
        xor ah, ah
        mov [tmp_len], ax
        inc word [tokptr]
        mov si, [tokptr]
        cmp byte [si], '$'
        je .dm_str
        mov ax, [tmp_len]
        shl ax, 1
        mov [bas_vidx], ax
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '('
        jne .dm_bad
        inc word [tokptr]
        call get_num_arg
        jc .dm_bad
        call eat_rparen
        test ax, ax
        js .dm_bad
        inc ax
        mov [tmp2], ax
        mov bx, [bas_vidx]
        mov dx, [arr_next]
        add dx, ax
        cmp dx, 512
        ja .dm_full
        mov ax, [arr_next]
        mov [arr_base+bx], ax
        mov ax, [tmp2]
        mov [arr_cnt+bx], ax
        add [arr_next], ax
        mov si, [arr_base+bx]
        shl si, 1
        mov cx, [tmp2]
.dm_z:
        mov word [arr_arena+si], 0
        add si, 2
        loop .dm_z
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], ','
        jne .dm_ok
        inc word [tokptr]
        jmp st_dim
.dm_ok:
        ret
.dm_str:
        inc word [tokptr]
        mov ax, [tmp_len]
        shl ax, 1
        mov [bas_vidx], ax
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], '('
        jne .dm_bad
        inc word [tokptr]
        call get_num_arg
        jc .dm_bad
        call eat_rparen
        test ax, ax
        js .dm_bad
        inc ax
        cmp ax, 32
        ja .dm_full
        mov [tmp2], ax
        mov bx, [bas_vidx]
        mov ax, [tmp2]
        mov cl, 5
        shl ax, cl
        mov dx, [sarr_next]
        add dx, ax
        cmp dx, 1024
        ja .dm_full
        mov ax, [sarr_next]
        mov [sarr_base+bx], ax
        mov ax, [tmp2]
        mov [sarr_cnt+bx], ax
        mov ax, [tmp2]
        mov cl, 5
        shl ax, cl
        add [sarr_next], ax
        mov si, [sarr_base+bx]
        add si, sarr_arena
        mov cx, [tmp2]
        mov dx, cx
        mov cl, 5
        shl dx, cl
        mov cx, dx
        xor al, al
.dm_sz:
        mov [si], al
        inc si
        loop .dm_sz
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], ','
        jne .dm_ok2
        inc word [tokptr]
        jmp st_dim
.dm_ok2:
        ret
.dm_full:
        mov si, s_bas_array
        call puts
        mov byte [basstop], 1
        ret
.dm_bad:
        mov si, s_bas_syntax
        call puts
        ret

st_randomize:
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], 0
        je .rz_tick
        call eval_num
        cmp word [ev_type], 0
        jne .rz_bad
        mov ax, [ev_val]
        jmp .rz_set
.rz_tick:
        mov ah, 9
        int 0x60
.rz_set:
        mov [bas_seed], ax
        ret
.rz_bad:
        mov si, s_bas_type
        call puts
        mov byte [basstop], 1
        ret

; =====================================================================
; LOAD / SAVE [A:|B:|C:|M:] NAME   (default extension .BAS)
; =====================================================================

; parse an optional drive prefix; mount it and keep the old drive on error
; optional drive prefix already in fname ("C:NAME"): mount and strip it
bas_name_drive:
        cmp byte [fname+1], ':'
        jne .nd_none
        mov al, [fname]
        call upcase
        cmp al, 'A'
        je .nd_ok
        cmp al, 'B'
        je .nd_ok
        cmp al, 'C'
        je .nd_ok
        cmp al, 'M'
        je .nd_ok
        jmp .nd_none
.nd_ok:
        call kmount
        jc .nd_fail
        mov si, fname+2
        mov di, fname
.nd_cp:
        mov al, [si]
        mov [di], al
        test al, al
        jz .nd_done
        inc si
        inc di
        jmp .nd_cp
.nd_done:
        clc
        ret
.nd_fail:
        stc
        ret
.nd_none:
        clc
        ret

; copy a (possibly quoted) file name from tokptr into fname, upcased
bas_get_name:
        call skip_sp_ptr
        mov si, [tokptr]
        mov di, fname
        xor cx, cx
        cmp byte [si], '"'
        je .gn_q
.gn_p:
        mov al, [si]
        test al, al
        jz .gn_end
        cmp al, ' '
        je .gn_end
        cmp al, '"'
        je .gn_end
        cmp cx, 15
        jae .gn_skip
        call upcase
        mov [di], al
        inc di
        inc cx
.gn_skip:
        inc si
        jmp .gn_p
.gn_q:
        inc si
.gn_ql:
        mov al, [si]
        test al, al
        jz .gn_end
        cmp al, '"'
        je .gn_qe
        cmp cx, 15
        jae .gn_qs
        call upcase
        mov [di], al
        inc di
        inc cx
.gn_qs:
        inc si
        jmp .gn_ql
.gn_qe:
        inc si
.gn_end:
        mov byte [di], 0
        mov [tokptr], si
        test cx, cx
        jz .gn_err
        clc
        ret
.gn_err:
        stc
        ret

st_load:
        call bas_get_name
        jc .ld_usage
        call bas_name_drive
        jc .ld_ret
        mov si, fname
        call build83bas
        mov si, namebuf
        mov ax, SYS_SEG
        mov es, ax
        mov bx, basfile
        mov cx, 3199
        call kload
        jc .ld_nf
        mov bx, dx
        mov byte [basfile+bx], 0
        call bas_new
        mov si, basfile
.ld_line:
        mov al, [si]
        test al, al
        jz .ld_ok
        cmp al, 10
        je .ld_skip1
        cmp al, 13
        je .ld_skip1
        mov di, si
.ld_find:
        mov al, [di]
        test al, al
        jz .ld_eol
        cmp al, 10
        je .ld_eol
        cmp al, 13
        je .ld_eol
        inc di
        jmp .ld_find
.ld_eol:
        mov dl, [di]
        mov byte [di], 0
        mov bx, si
.ld_sp:
        cmp byte [bx], ' '
        jne .ld_dig
        inc bx
        jmp .ld_sp
.ld_dig:
        mov al, [bx]
        cmp al, '0'
        jb .ld_adv
        cmp al, '9'
        ja .ld_adv
        push si
        push dx
        push di
        mov si, bx
        call bas_store
        pop di
        pop dx
        pop si
.ld_adv:
        mov si, di
        cmp dl, 0
        je .ld_ok
        cmp dl, 13
        jne .ld_next
        cmp byte [si+1], 10
        jne .ld_next
        inc si
.ld_next:
        inc si
        jmp .ld_line
.ld_skip1:
        inc si
        jmp .ld_line
.ld_ok:
        mov si, s_bas_loaded
        call puts
.ld_ret:
        ret
.ld_nf:
        mov si, s_bas_nofile
        call puts
        ret
.ld_usage:
        mov si, s_bas_usage
        call puts
        ret
.ld_io:
        mov si, s_io_err
        call puts
        ret

st_save:
        call bas_get_name
        jc .sv_usage
        call bas_name_drive
        jc .sv_ret
        mov si, fname
        call build83bas
        push es
        mov ax, ds
        mov es, ax
        mov di, bassave
        mov word [bas_tmp7], 0
.sv_loop:
        mov bx, [bas_tmp7]
        add bx, basprog
        mov ax, [bx]
        test ax, ax
        jz .sv_end
        call dec_to_buf
        mov al, ' '
        stosb
        add bx, 2
.sv_copy:
        mov al, [bx]
        test al, al
        jz .sv_nl
        stosb
        inc bx
        jmp .sv_copy
.sv_nl:
        mov al, 10
        stosb
        add word [bas_tmp7], 64
        mov ax, di
        sub ax, bassave
        cmp ax, 4000
        jb .sv_loop
.sv_end:
        mov ax, di
        sub ax, bassave
        mov [bas_tmp7], ax
        pop es
        mov si, namebuf
        mov bx, bassave
        mov cx, [bas_tmp7]
        call ksave
        jc .sv_werr
        mov si, s_saved
        call puts
        mov ax, [bas_tmp7]
        call put_dec
        mov si, s_saved_bytes
        call puts
        ret
.sv_werr:
        cmp al, 1
        jne .sv_io
        mov si, s_wr_off
        call puts
        ret
.sv_io:
        mov si, s_io_err
        call puts
        ret
.sv_usage:
        mov si, s_bas_usage
        call puts
        ret
.sv_ret:
        ret

; AX = number, DI = buffer -> decimal digits, DI advanced; BX/CX/DX/AX restored
dec_to_buf:
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

bas_exec:
        mov word [sa_ptr], 0
        call skip_sp_ptr
        mov si, k_print
        call kw
        cmp al, 1
        je st_print
        mov si, k_let
        call kw
        cmp al, 1
        je st_let
        mov si, k_if
        call kw
        cmp al, 1
        je st_if
        mov si, k_goto
        call kw
        cmp al, 1
        je st_goto
        mov si, k_input
        call kw
        cmp al, 1
        je st_input
        mov si, k_end
        call kw
        cmp al, 1
        je st_end
        mov si, k_stop
        call kw
        cmp al, 1
        je st_end
        mov si, k_rem
        call kw
        cmp al, 1
        je .rem
        mov si, [tokptr]
        cmp byte [si], 39
        je .rem
        mov si, k_cls
        call kw
        cmp al, 1
        je st_cls
        mov si, k_dim
        call kw
        cmp al, 1
        je st_dim
        mov si, k_gosub
        call kw
        cmp al, 1
        je st_gosub
        mov si, k_return
        call kw
        cmp al, 1
        je st_return
        mov si, k_for
        call kw
        cmp al, 1
        je st_for
        mov si, k_next
        call kw
        cmp al, 1
        je st_next
        mov si, k_randomize
        call kw
        cmp al, 1
        je st_randomize
        mov si, [tokptr]
        mov al, [si]
        cmp al, 'a'
        jb .u1
        cmp al, 'z'
        ja .u1
        sub al, 32
.u1:
        cmp al, 'A'
        jb .unk
        cmp al, 'Z'
        ja .unk
        mov si, [tokptr]
        inc si
        cmp byte [si], '='
        je st_let
        cmp byte [si], '$'
        je st_let
        cmp byte [si], '('
        je st_let
.unk:
        mov si, s_bas_what
        call puts
        ret
.rem:
        call skip_to_eol
        ret

do_auto_cmd:
        mov ax, 10
        mov bx, 10
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], 0
        je .ac_set
        call parse_num_ptr
        mov [auto_next], ax
        mov word [auto_step], 10
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], ','
        jne .ac_on
        inc word [tokptr]
        call parse_num_ptr
        test ax, ax
        jnz .ac_st
        mov ax, 10
.ac_st:
        mov [auto_step], ax
        jmp .ac_on
.ac_set:
        mov [auto_next], ax
        mov [auto_step], bx
.ac_on:
        mov byte [auto_on], 1
        ret

; ---- expanded console PS: slot/name/app/term/user/console/state/seg ----
do_ps:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push es
        mov ax, KSEG
        mov es, ax
        mov ah, 33
        int 0x60
        mov [ps_state], ax
        mov [ps_term], bx
        mov [ps_app], cx
        mov [ps_seg], dx
        mov [ps_out], di
        mov si, s_ps_hdr
        call puts
        mov si, s_ps_rule
        call puts
        mov si, s_ps_svc
        call puts
        mov ah, 29
        int 0x60
        mov [ps_flags], ax
        mov si, s_ps_web
        mov bl, 1
        call ps_bit
        mov si, s_ps_weblog
        mov bl, 2
        call ps_bit
        mov si, s_ps_slip
        mov bl, 4
        call ps_bit
        mov si, s_ps_mux
        mov bl, 8
        call ps_bit
        mov si, s_ps_tftp
        mov bl, 16
        call ps_bit
        mov si, s_ps_priv
        mov bl, 32
        call ps_bit
        mov al, 10
        call putc
        xor bp, bp
.ps_slot:
        cmp bp, 13
        jae .ps_done
        mov ax, bp
        call put_dec
        mov si, s_ps_col
        call puts
        mov si, bp
        add si, [ps_state]
        mov al, [es:si]
        test al, al
        jz .ps_free
        ; name (ES:SI in KERNEL_SEG; DS stays SYS so putc's cap_on is correct)
        mov ax, bp
        mov ah, 25
        int 0x60
        mov si, ax
        mov cx, 13
        call ps_kpad
        ; app
        mov si, bp
        add si, [ps_app]
        mov al, [es:si]
        cmp bp, 11
        jb .ps_am
        mov si, s_app_pgm
        jmp .ps_ap
.ps_am: cmp al, 1
        jne .ps_a2
        mov si, s_app_ser
        jmp .ps_ap
.ps_a2: cmp al, 2
        jne .ps_a3
        mov si, s_app_web
        jmp .ps_ap
.ps_a3: cmp al, 3
        jne .ps_a0
        mov si, s_app_up
        jmp .ps_ap
.ps_a0: mov si, s_app_cons
.ps_ap: mov cx, 9
        call ps_pad
        ; term
        mov si, bp
        add si, [ps_term]
        mov al, [es:si]
        xor ah, ah
        call put_dec
        mov al, ' '
        call putc
        ; user (ES:SI in KERNEL_SEG; DS stays SYS)
        mov ax, bp
        test ax, ax
        jz .ps_uc
        mov ah, 24
        int 0x60
        jc .ps_ud
        mov si, ax
        mov cx, 12
        call ps_kpad
        jmp .ps_ud
.ps_uc: mov si, s_ps_console
        mov cx, 12
        call ps_pad
.ps_ud: ; console
        mov si, bp
        add si, [ps_out]
        mov al, [es:si]
        cmp al, 1
        jne .ps_c2
        mov si, s_con_com1
        jmp .ps_cp
.ps_c2: cmp al, 2
        jne .ps_c0
        mov si, s_con_both
        jmp .ps_cp
.ps_c0: mov si, s_con_cga
.ps_cp: mov cx, 6
        call ps_pad
        mov si, s_ps_rdy
        mov cx, 7
        call ps_pad
        mov si, bp
        shl si, 1
        add si, [ps_seg]
        mov ax, [es:si]
        call ps_hex
        mov al, 10
        call putc
        inc bp
        jmp .ps_slot
.ps_free:
        mov si, s_ps_dash
        mov cx, 13
        call ps_pad
        mov cx, 9
        call ps_pad
        mov cx, 3
        call ps_pad
        mov cx, 12
        call ps_pad
        mov cx, 6
        call ps_pad
        mov si, s_ps_free
        mov cx, 7
        call ps_pad
        mov si, bp
        shl si, 1
        add si, [ps_seg]
        mov ax, [es:si]
        call ps_hex
        mov al, 10
        call putc
        inc bp
        jmp .ps_slot
.ps_done:
        pop es
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

ps_pad:                         ; DS:SI string, CX width
        push ax
        push cx
        push si
.pp_l:  jcxz .pp_d
        mov al, [si]
        test al, al
        jz .pp_s
        push cx
        call putc
        pop cx
        inc si
        dec cx
        jmp .pp_l
.pp_s:  mov al, ' '
        push cx
        call putc
        pop cx
        dec cx
        jmp .pp_l
.pp_d:  pop si
        pop cx
        pop ax
        ret

ps_kpad:                        ; ES:SI kernel string, CX width, DS = SYS
        push ax
        push cx
        push si
.kp_l:  jcxz .kp_d
        mov al, [es:si]
        test al, al
        jz .kp_s
        push cx
        call putc
        pop cx
        inc si
        dec cx
        jmp .kp_l
.kp_s:  mov al, ' '
        push cx
        call putc
        pop cx
        dec cx
        jmp .kp_l
.kp_d:  pop si
        pop cx
        pop ax
        ret

ps_hex:                         ; AX -> 4 hex digits
        push ax
        push bx
        push cx
        mov bx, ax
        mov cx, 4
.ph_l:  rol bx, 1
        rol bx, 1
        rol bx, 1
        rol bx, 1
        mov al, bl
        and al, 0x0F
        cmp al, 10
        jb .ph_d
        add al, 7
.ph_d:  add al, '0'
        push bx
        push cx
        call putc
        pop cx
        pop bx
        dec cx
        jnz .ph_l
        pop cx
        pop bx
        pop ax
        ret

ps_bit:                         ; SI label, BL mask; print label + 0/1
        push bx
        call puts
        pop bx
        mov ax, [ps_flags]
        test ax, bx
        jz .pb_0
        mov al, '1'
        jmp .pb_p
.pb_0:  mov al, '0'
.pb_p:  call putc
        ret

do_basic:
        push si
        mov si, s_bas_banner
        call puts
.rep:
        mov si, s_bas_prompt
        call puts
        cmp byte [auto_on], 0
        je .plain
        mov ax, [auto_next]
        push ax
        call put_dec
        mov al, ' '
        call putc
        pop ax
        push es
        mov dx, ds
        mov es, dx
        mov di, basline
        call dec_to_buf
        mov al, ' '
        stosb
        pop es
        mov cx, di
        sub cx, basline
        mov [auto_len], cx
        mov di, basline
        add di, cx
        call bas_readline_at
        mov si, basline
        mov [tokptr], si
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        cmp al, '0'
        jb .auto_plain
        cmp al, '9'
        ja .auto_plain
        call parse_num_ptr
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], 0
        je .auto_off
        mov [auto_rest], si
        mov [tokptr], si
        mov si, k_run
        call kw
        cmp al, 1
        je .auto_cmd
        mov si, k_list
        call kw
        cmp al, 1
        je .auto_cmd
        mov si, k_new
        call kw
        cmp al, 1
        je .auto_cmd
        mov si, k_auto
        call kw
        cmp al, 1
        je .auto_cmd
        mov si, k_load
        call kw
        cmp al, 1
        je .auto_cmd
        mov si, k_save
        call kw
        cmp al, 1
        je .auto_cmd
        mov si, k_system
        call kw
        cmp al, 1
        je .auto_cmd
        mov si, k_quit
        call kw
        cmp al, 1
        je .auto_cmd
        mov si, basline
        call bas_store
        mov ax, [auto_next]
        add ax, [auto_step]
        mov [auto_next], ax
        jmp .rep
.auto_off:
        mov byte [auto_on], 0
        jmp .rep
.auto_plain:
        mov si, [tokptr]
        cmp byte [si], 0
        jne .auto_plain2
        mov byte [auto_on], 0
        jmp .rep
.auto_plain2:
        mov si, basline
        mov [tokptr], si
        jmp .cmd
.auto_cmd:
        mov si, [auto_rest]
        mov di, basline
.acp:
        mov al, [si]
        mov [di], al
        test al, al
        jz .acpd
        inc si
        inc di
        jmp .acp
.acpd:
        mov si, basline
        mov [tokptr], si
        jmp .cmd
.plain:
        call bas_readline
        mov si, basline
        mov [tokptr], si
        call skip_sp_ptr
        mov si, [tokptr]
        cmp byte [si], 0
        je .rep
        mov al, [si]
        cmp al, '0'
        jb .cmd
        cmp al, '9'
        ja .cmd
        mov si, basline
        call bas_store
        jmp .rep
.cmd:
        mov si, k_run
        call kw
        cmp al, 1
        je .run
        mov si, k_list
        call kw
        cmp al, 1
        je .list
        mov si, k_new
        call kw
        cmp al, 1
        je .new
        mov si, k_auto
        call kw
        cmp al, 1
        je .auto
        mov si, k_system
        call kw
        cmp al, 1
        je .out
        mov si, k_quit
        call kw
        cmp al, 1
        je .out
        mov si, k_load
        call kw
        cmp al, 1
        je .load
        mov si, k_save
        call kw
        cmp al, 1
        je .save
        call bas_exec_seq
        jmp .rep
.load:
        call st_load
        jmp .rep
.save:
        call st_save
        jmp .rep
.run:
        xor ax, ax
        call skip_sp_ptr
        mov si, [tokptr]
        mov al, [si]
        cmp al, '0'
        jb .run_zero
        cmp al, '9'
        ja .run_zero
        call parse_num_ptr
        call bas_find_line
        cmp ax, 0xFFFF
        je .run_bad
        jmp .run_go
.run_zero:
        xor ax, ax
.run_go:
        mov [bas_start], ax
        call bas_run
        jmp .rep
.run_bad:
        mov si, s_bas_noline
        call puts
        jmp .rep
.list:
        call bas_list
        jmp .rep
.new:
        call bas_new
        jmp .rep
.auto:
        call do_auto_cmd
        jmp .rep
.out:
        pop si
        ret

; =====================================================================
; Serial console logon (CGA console needs none)
; =====================================================================
k_print db 'PRINT', 0
k_let   db 'LET', 0
k_if    db 'IF', 0
k_goto  db 'GOTO', 0
k_input db 'INPUT', 0
k_end   db 'END', 0
k_stop  db 'STOP', 0
k_rem   db 'REM', 0
k_cls   db 'CLS', 0
k_gosub db 'GOSUB', 0
k_return db 'RETURN', 0
k_for   db 'FOR', 0
k_next  db 'NEXT', 0
k_randomize db 'RANDOMIZE', 0
k_else  db 'ELSE', 0
k_to    db 'TO', 0
k_step  db 'STEP', 0
k_or    db 'OR', 0
k_and   db 'AND', 0
k_not   db 'NOT', 0
k_mod   db 'MOD', 0
k_abs   db 'ABS', 0
k_int   db 'INT', 0
k_sgn   db 'SGN', 0
k_sqr   db 'SQR', 0
k_rnd   db 'RND', 0
k_len   db 'LEN', 0
k_lefts db 'LEFT$', 0
k_rights db 'RIGHT$', 0
k_mids  db 'MID$', 0
k_instr db 'INSTR', 0
k_ucases db 'UCASE$', 0
k_lcases db 'LCASE$', 0
k_chrs  db 'CHR$', 0
k_asc   db 'ASC', 0
k_strs  db 'STR$', 0
k_vals  db 'VAL', 0
k_dim   db 'DIM', 0
k_then  db 'THEN', 0
k_run   db 'RUN', 0
k_list  db 'LIST', 0
k_new   db 'NEW', 0
k_auto  db 'AUTO', 0
k_load  db 'LOAD', 0
k_save  db 'SAVE', 0
k_system db 'SYSTEM', 0
k_quit  db 'QUIT', 0
s_bas_banner db 'UMIX BASIC V2 - SYSTEM TO EXIT', 10, 0
s_bas_prompt db '> ', 0
s_bas_what db '?WHAT', 10, 0
s_bas_syntax db '?SYNTAX', 10, 0
s_bas_noline db '?LINE', 10, 0
s_bas_full db '?FULL', 10, 0
s_bas_div0 db '?DIV/0', 10, 0
s_bas_gosub db '?GOSUB STACK', 10, 0
s_bas_return db '?RETURN', 10, 0
s_bas_for db '?FOR STACK', 10, 0
s_bas_next db '?NEXT', 10, 0
s_bas_usage db 'USE LOAD/SAVE [A:|B:|C:|M:] NAME', 10, 0
s_bas_loaded db 'LOADED', 10, 0
s_bas_nofile db '?FILE NOT FOUND', 10, 0
s_bas_type db '?TYPE MISMATCH', 10, 0
s_bas_array db '?ARRAY', 10, 0
s_bas_subscript db '?SUBSCRIPT', 10, 0
s_bas_str db '?STRING TOO LONG', 10, 0
basprog       times MAXLINES*64 db 0
basvar        times 26 dw 0
basline       times 128 db 0
tokptr        dw 0
runidx        dw 0
jumpidx       dw 0xFFFF
basstop       db 0
inrun         db 0
prsemi        db 0
bas_start     dw 0
bas_gsub_stk  times 16 dw 0
bas_gsub_sp   db 0
bas_for_var   times 16 dw 0
bas_for_lim   times 16 dw 0
bas_for_step  times 16 dw 0
bas_for_line  times 16 dw 0
bas_for_sp    db 0
bas_seed      dw 0
bas_else_stop db 0
bas_tmp0      dw 0
bas_tmp1      dw 0
bas_tmp2      dw 0
bas_tmp3      dw 0
bas_tmp4      dw 0
bas_tmp5      dw 0
bas_tmp6      db 0
bas_tmp7      dw 0
ev_type       dw 0
ev_val        dw 0
ev_len        dw 0
rt_type       dw 0
rt_val        dw 0
rt_len        dw 0
tmp_ptr       dw 0
tmp_len       dw 0
tmp2          dw 0
tmp3          dw 0
tmp4          dw 0
tmp_val       dw 0
sa_ptr        dw 0
auto_on       db 0
auto_next     dw 10
auto_step     dw 10
auto_len      dw 0
auto_rest     dw 0
str_arena     times 512 db 0
bas_str       times 26*64 db 0
arr_base      times 26 dw 0
arr_cnt       times 26 dw 0
arr_next      dw 0
arr_arena     times 512 dw 0
sarr_base     times 26 dw 0
sarr_cnt      times 26 dw 0
sarr_next     dw 0
sarr_arena    times 1024 db 0
pd_old_ram    db 0
pd_old_dl     db 0
bas_target    dw 0
bas_vidx      dw 0
bas_yield     db 128
; --- API BASIC route state (milestone 1) ---
apic_seg      dw 0
apic_off      dw 0
apic_max      dw 0
cap_on        db 0
cap_err       db 0
cap_len       dw 0
cap_seg       dw 0
cap_off       dw 0
cap_max       dw 0
cap_start     dw 0
apipath       times 25 db 0
decbuf        times 7 db 0
s_apipath     db '/api/hello', 0
api_prog:
api_l1:
        dw 10
        db 'PRINT "{";CHR$(34);"hello";CHR$(34);":1,"', 0
        times 64-($-api_l1) db 0
api_l2:
        dw 20
        db 'PRINT CHR$(34);"n";CHR$(34);":42}"', 0
        times 64-($-api_l2) db 0
; --- API BASIC routes (milestone 2) ---
ROUTE_MAX     equ 4
ROUTE_SZ      equ 40             ; path[20] + file[16] + pad
routes        times ROUTE_MAX*ROUTE_SZ db 0
rtmp_path     times 20 db 0
rtmp_file     times 16 db 0
ap_ent        dw 0
ap_load       db 0
apic_method   db 'G'
apic_blen     dw 0
apic_boff     dw 0
api_mstr      times 7 db 0
api_bstr      times 64 db 0
api_qstr      times 24 db 0
s__routes     db '/__routes', 0
s_m_get       db 'GET', 0
s_m_post      db 'POST', 0
s_m_del       db 'DELETE', 0
s_kw_route    db 'ROUTE', 0
s_kw_routes   db 'ROUTES', 0
s_kw_del      db 'DEL', 0
s_route_usage db 'USAGE: API ROUTE /api/name FILE.BAS', 10, 0
s_route_full  db 'ROUTE TABLE FULL', 10, 0
s_route_added db 'ROUTE ADDED', 10, 0
s_route_del   db 'ROUTE DELETED', 10, 0
s_route_none  db 'NO SUCH ROUTE', 10, 0
s_routes_hdr  db 'ROUTES:', 10, 0
s_route_missing db 'BASIC FILE MISSING', 10, 0
cmp_l         dw 0
cmp_op        db 0xFF

s_basic_cmd db 'BASIC', 0
s_old_kernel db 'BOOT FLOPPY TOO OLD - REWRITE UMIX86.IMG', 13, 10, 0
s_break db 'BREAK', 10, 0
s_wr_off db 'WRITES DISABLED - USE WRITE ON', 10, 0
s_saved db 'SAVED ', 0
s_saved_bytes db ' BYTES', 10, 0
s_no_space db 'NO SPACE ON C:', 10, 0
s_io_err db 'C: I/O ERROR', 10, 0
fname times 16 db 0
basfile times 3200 db 0
bassave times 4096 db 0
eat_lf db 0
s_ps_cmd db 'PS', 0
ps_state dw 0
ps_term dw 0
ps_app dw 0
ps_seg dw 0
ps_out dw 0
ps_flags dw 0
s_ps_hdr db 'SLOT NAME         APP      T  USER        CON  STATE  SEG', 10, 0
s_ps_rule db '=============================================================', 10, 0
s_ps_col db '    ', 0
s_ps_svc db 'SERVICES:', 0
s_ps_web db ' WEB=', 0
s_ps_weblog db ' WEBLOG=', 0
s_ps_slip db ' SLIP=', 0
s_ps_mux db ' MUX=', 0
s_ps_tftp db ' TFTP=', 0
s_ps_priv db ' PRIV=', 0
s_app_cons db 'console', 0
s_app_ser db 'serial', 0
s_app_web db 'web', 0
s_app_up db 'upload', 0
s_app_pgm db 'program', 0
s_con_cga db 'CGA', 0
s_con_com1 db 'COM1', 0
s_con_both db 'BOTH', 0
s_ps_console db 'CONSOLE', 0
s_ps_rdy db 'READY', 0
s_ps_free db 'FREE', 0
s_ps_dash db '-', 0

