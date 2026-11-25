; UMIX/86 API.SYS - HTTP API dispatcher overlay
; loaded at API_SEG (0x9000); entered with DS = KERNEL_SEG, SI = request path;
; returns with retf.  Writes the HTTP response through INT 60h.
        cpu 8086
        KERNEL_SEG equ 0x1000
        org 0

; Chat history + API chat sessions live in the 0x2900 window (SYS zero padding;
; mutually exclusive with TCP.SYS - see kernel.asm).
CHATAPI_SEG equ 0x2900
CH_N        equ 16
CH_ESZ      equ 72
CH_HEAD     equ 0
CH_CNT      equ 1
CH_SEQ      equ 2
CH_ENT      equ 4
SESS_N      equ 8
SESS_SZ     equ 14              ; used(1) token(2) nick(10) pad(1)
SESS_ENT    equ CH_ENT + CH_N*CH_ESZ
SESS_NEXT   equ SESS_ENT + SESS_N*SESS_SZ
API_LIST    equ 0x500           ; '  API: nick ...' read by the kernel /WHO

        jmp entry

pathbuf times 64 db 0
bodybuf times 1792 db 0         ; whole response body (PS/messages are largest)
b_ptr   dw 0
ps_state dw 0                    ; AH=33 task-table offsets (kernel segment)
ps_term  dw 0
ps_app   dw 0
ps_seg   dw 0
chat_token dw 0
chat_since dw 0
chat_latest dw 0
b_nl    db 0
w_n     db 0
req_method db 0
resp_hdr dw hdr_200

; --- job manager state (model A: one running job, pumped by the kernel) ---
JOB_MAX  equ 8
JOB_SIZE equ 20
STR_MAX  equ 12                  ; strings per strsort job
STR_LEN  equ 16                  ; bytes per string (15 chars + NUL)
JBUF_MAX equ 768
jobs      times JOB_MAX*JOB_SIZE db 0
job_next  dw 1
job_busy  db 0                  ; set while an HTTP request is handled
job_in    db 0                  ; pump re-entrancy
job_id    dw 0
job_app   db 0
path_kind db 0
job_x     dw 0
jbuf      times JBUF_MAX db 0
jlen      dw 0
jstart    dw 0
brace     db 0
instr     db 0                  ; body reader: inside a JSON string
esc       db 0                  ; body reader: previous byte was backslash
body_err  db 0                  ; 0 ok, 1 bad/timeout, 2 too large
keybuf    times 9 db 0
appbuf    times 12 db 0
chattext times 64 db 0
plimit    dw 0
pseed     dw 0
have_app  db 0
vcount    db 0                  ; parsed "values" strings
have_values db 0                ; "values" key was present
vals      times STR_MAX*STR_LEN db 0
vdata     times 256 db 0        ; parsed "data" string (or concatenated values)
dlen      dw 0
have_data db 0
strpool   times JOB_MAX*STR_MAX*STR_LEN db 0
crcdat    times JOB_MAX*256 db 0
sort_arr  times 32 dw 0

hdr_200 db 'HTTP/1.0 200 OK',10,'Content-Type: application/json',10,'X-API-Version: 13',10,'Content-Length: ',0
hdr_202 db 'HTTP/1.0 202 Accepted',10,'Content-Type: application/json',10,'X-API-Version: 13',10,'Content-Length: ',0
hdr_400 db 'HTTP/1.0 400 Bad Request',10,'Content-Type: application/json',10,'X-API-Version: 13',10,'Content-Length: ',0
hdr_404 db 'HTTP/1.0 404 Not Found',10,'Content-Type: application/json',10,'X-API-Version: 13',10,'Content-Length: ',0
hdr_409 db 'HTTP/1.0 409 Conflict',10,'Content-Type: application/json',10,'X-API-Version: 13',10,'Content-Length: ',0
hdr_413 db 'HTTP/1.0 413 Payload Too Large',10,'Content-Type: application/json',10,'X-API-Version: 13',10,'Content-Length: ',0
hdr_503 db 'HTTP/1.0 503 Service Unavailable',10,'Content-Type: application/json',10,'X-API-Version: 13',10,'Content-Length: ',0
hdr_500 db 'HTTP/1.0 500 Internal Server Error',10,'Content-Type: application/json',10,'X-API-Version: 13',10,'Content-Length: ',0
hdr_pre equ hdr_200
hdr_end db 10,'Connection: close',10,10,0
nf    db 'HTTP/1.0 404 Not Found',10,'Content-Type: text/plain',10,'X-API-Version: 13',10,'Content-Length: 11',10,'Connection: close',10,10,'not found',10,0
p_api db '/api',0
p_sys db '/api/system',0
p_tk  db '/api/tasks',0
p_mem db '/api/memory',0
p_who db '/api/who',0
p_whom db '/api/whoami',0
p_ps  db '/api/ps',0
p_usr db '/api/users',0
p_spd db '/api/speed',0
p_tim db '/api/time',0
p_ver db '/api/version',0
p_sta db '/api/status',0
p_cha db '/api/chat',0
p_jobs db '/api/jobs',0
p_routes db '/api/routes',0
s__routes db '/__routes',0
p_apps db '/api/apps',0
p_res db '/result',0
j_nk  db ',"nicks":[',0
st_fl dw 0
st_rx dw 0
st_tx dw 0
st_er dw 0
j_w3a db '{"web":',0
j_wl  db ',"weblog":',0
j_sl  db ',"slip":',0
j_mx  db ',"mux":',0
j_tf  db ',"tftp":',0
j_pv  db ',"priv":',0
j_rx  db ',"rx":',0
j_tx  db ',"tx":',0
j_er  db ',"err":',0
j_t1 db '{"h":',0
j_t2 db ',"m":',0
j_t3 db ',"s":',0
j_ver db '{"os":"UMIX","version":"0.3","kernel":"V0R138"',10,',"api":13,"cpu":"Intel 8088","ram_kb":640}',10,0
j_sp1 db '{"baud":',0
j_sp2 db ',"tick_hz":',0
j_sp3 db ',"cpu":"',0
j_uu  db ',"users":[',0
j_nm2 db ',"names":[',0
j_w1  db '{"count":',0
j_w2  db ',"users":[',0
j_quo db '"',0
j_cma db ',',0
j_usr db '{"user":"',0
j_list_a db '{"endpoints":[',10,'"/api/system","/api/tasks","/api/memory","/api/who"',10,',"/api/whoami","/api/ps","/api/users","/api/speed"',10,',"/api/time","/api/version","/api/status","/api/chat"',10,',"/api/apps","/api/jobs","/api/hello","/api/routes"',10,',"/api/chat/join","/api/chat/send","/api/chat/messages"',0
j_list_b db ']}',10,0
j_routes db '{"routes":[',0
j_sys db '{"os":"UMIX","version":"0.3","cpu":"Intel 8088","ram_kb":640,"tasks":',0
j_up  db ',"uptime":',0
j_end db '}',10,0
j_w3  db ']}',10,0
j_tk  db '{"count":',0
j_mem db '{"ram_kb":640,"status":"ok"}',10,0
s_ver db 'API.SYS V13 - POST+ROUTES+CHAT',10,0

; --- /api/ps fragments ---
j_ps        db '{"count":',0
j_ps_svc    db ',"services":{"web":',0
j_ps_weblog db ',"weblog":',0
j_ps_slip   db ',"slip":',0
j_ps_mux    db ',"mux":',0
j_ps_tftp   db ',"tftp":',0
j_ps_priv   db ',"priv":',0
j_ps_tasks  db '},"tasks":[',0
j_task_o    db '{"slot":',0
j_task_nm   db ',"name":"',0
j_task_app  db '","app":"',0
j_task_term db '","term":',0
j_task_state db ',"state":"ready"',0
j_task_seg  db ',"seg":"',0
j_task_user db ',"user":"',0
j_task_end  db '}',0
s_app_cons  db 'console',0
s_app_ser   db 'serial',0
s_app_web   db 'web',0
s_app_up    db 'upload',0
s_app_pgm   db 'program',0
s_ps_console db 'CONSOLE',0

; --- chat API fragments ---
p_chatjoin  db '/api/chat/join',0
p_chatsend  db '/api/chat/send',0
p_chatmsgs  db '/api/chat/messages',0
k_nick      db 'nick',0
k_text      db 'text',0
k_token     db 'token',0
s_sysop     db 'SYSOP',0
j_token     db '{"token":',0
j_seq       db '{"seq":',0
j_oktrue    db '{"ok":true}',0
j_latest    db '{"latest":',0
j_messages  db ',"messages":[',0
j_text      db ',"text":"',0
j_mend      db '}',0
j_api       db ',"api":[',0
j_latest2   db '],"latest":',0
j_brk       db ']',0
j_endnl     db '}',10,0
s_api_pfx   db '  API: ',0
s_chat_joinmsg db 'JOINED CHAT',0
s_chat_leftmsg db 'LEFT CHAT',0
e_chat      db '{"error":"chat unavailable"}',10,0
e_btok      db '{"error":"bad token"}',10,0
e_bnick     db '{"error":"bad nick"}',10,0
e_nuse      db '{"error":"nick in use"}',10,0

; --- job/app JSON fragments ---
j_jobs  db '{"jobs":[',0
j_jobid db '{"job_id":',0
j_app   db ',"app":"',0
j_stat  db '","status":"',0
j_stat2 db ',"status":"',0
j_res   db ',"result":',0
j_exe   db ',"execution_ticks":',0
j_apps  db '{"applications":[',0
j_aid   db '{"id":"',0
j_adesc db '","description":"',0
j_rp    db '{"prime_count":',0
j_rs    db '{"count":',0
j_rck   db ',"checksum":',0
j_rc    db '{"crc":',0
j_vcnt  db '{"count":',0
j_vlist db ',"values":[',0
j_vend  db ']}',0
j_cb    db '}',0
s_queued  db 'queued',0
s_running db 'running',0
s_done    db 'completed',0
s_canc    db 'cancelled',0
s_failed  db 'failed',0
s_creq    db 'cancel_requested',0
e_nf    db '{"error":"not found"}',10,0
e_bad   db '{"error":"bad request"}',10,0
e_conf  db '{"error":"not ready"}',10,0
e_fin   db '{"error":"already finished"}',10,0
e_full  db '{"error":"queue full"}',10,0
e_busy  db '{"error":"route busy"}',10,0
e_rerr  db '{"error":"route failed"}',10,0
body_timeout dw 120
rbuf    times 256 db 0
e_big   db '{"error":"body too large"}',10,0
k_app   db 'app',0
k_params db 'params',0
k_limit db 'limit',0
k_seed  db 'seed',0
k_values db 'values',0
k_data  db 'data',0
a_prime db 'prime',0
a_sort  db 'sort',0
a_crc16 db 'crc16',0
d_prime db 'Prime number calculation',0
d_sort  db 'Integer array or string list sorting',0
d_crc16 db 'CRC16 of generated or supplied data',0

puts:
        mov ah, 1
        int 0x60
        ret

putnum:                         ; BX = value
        mov ah, 2
        int 0x60
        ret

bcd8:                           ; AL = BCD byte -> append decimal value
        push ax
        push bx
        mov bl, al
        shr al, 1
        shr al, 1
        shr al, 1
        shr al, 1
        mov ah, 10
        mul ah
        and bx, 0x0f
        add ax, bx
        call b_num
        pop bx
        pop ax
        ret

st_bit:                         ; print bit CL of st_fl
        push ax
        push bx
        mov ax, [st_fl]
        shr ax, cl
        and ax, 1
        call b_num
        pop bx
        pop ax
        ret

b_str:                          ; append DS:SI to bodybuf
        push ax
        push di
        mov di, [b_ptr]
        add di, bodybuf
.b_s:
        lodsb
        test al, al
        jz .b_sd
        stosb
        jmp .b_s
.b_sd:
        mov ax, di
        sub ax, bodybuf
        mov [b_ptr], ax
        pop di
        pop ax
        ret

b_name:                         ; AX = offset in KERNEL_SEG, CX = max chars
        push ax
        push bx
        push cx
        push dx
        push si
        push es
        push di
        mov si, ax
        mov bx, KERNEL_SEG
        mov es, bx
        mov di, [b_ptr]
        add di, bodybuf
        mov dx, cx
.b_nm:
        test dx, dx
        jz .b_nmd
        mov al, es:[si]
        test al, al
        jz .b_nmd
        inc si
        push es
        push ax
        mov ax, cs
        mov es, ax
        pop ax
        stosb
        inc word [b_ptr]
        pop es
        dec dx
        jmp .b_nm
.b_nmd:
        pop di
        pop es
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

b_num:                          ; append AX in decimal
        push ax
        push bx
        push cx
        push dx
        push di
        mov bx, 10
        xor cx, cx
.b_nd:
        xor dx, dx
        div bx
        push dx
        inc cx
        test ax, ax
        jnz .b_nd
.b_np:
        pop ax
        add al, '0'
        mov di, [b_ptr]
        add di, bodybuf
        mov [di], al
        inc word [b_ptr]
        loop .b_np
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

b_hex:                          ; append AX as four upper-case hex digits
        push ax
        push bx
        push cx
        push dx
        push di
        mov dx, ax
        mov cx, 4
.b_hx:
        rol dx, 1
        rol dx, 1
        rol dx, 1
        rol dx, 1
        mov al, dl
        and al, 0x0F
        cmp al, 10
        jb .b_hd
        add al, 7
.b_hd:
        add al, '0'
        mov di, [b_ptr]
        add di, bodybuf
        mov [di], al
        inc word [b_ptr]
        dec cx
        jnz .b_hx
        pop di
        pop dx
        pop cx
        pop bx
        pop ax
        ret

k_byte:                         ; SI = offset in KERNEL_SEG -> AL (ES preserved)
        push es
        push bx
        mov bx, KERNEL_SEG
        mov es, bx
        mov al, [es:si]
        pop bx
        pop es
        ret

k_word:                         ; SI = offset in KERNEL_SEG -> AX (ES preserved)
        push es
        push bx
        mov bx, KERNEL_SEG
        mov es, bx
        mov ax, [es:si]
        pop bx
        pop es
        ret

; =====================================================================
; Chat API helpers
; =====================================================================

jfind:                          ; DI=key literal, SI=body -> CF=0 SI=value, CF=1
        push ax
        push bx
        push di
        call jw
        cmp byte [si], '{'
        jne .jf_no
        inc si
.jf_l:
        call jw
        mov al, [si]
        cmp al, '}'
        je .jf_no
        cmp al, ','
        jne .jf_key
        inc si
        jmp .jf_l
.jf_key:
        cmp al, '"'
        jne .jf_no
        inc si
        push di
        mov di, keybuf
        mov cx, 8
        call jstr
        pop di
        jc .jf_no
        call jw
        cmp byte [si], ':'
        jne .jf_no
        inc si
        call jw
        call keq
        cmp al, 1
        je .jf_yes
        call jskipv
        jmp .jf_l
.jf_yes:
        pop di
        pop bx
        pop ax
        clc
        ret
.jf_no:
        pop di
        pop bx
        pop ax
        stc
        ret

nickok:                         ; SI=nick -> AL=1 if 2..9 alnum (upcased), not SYSOP
        push bx
        push di
        push si
        mov di, si
        xor bx, bx
.nk_l:
        mov al, [si]
        test al, al
        jz .nk_end
        cmp al, 'a'
        jb .nk_ch
        cmp al, 'z'
        ja .nk_ch
        sub al, 32
        mov [si], al
.nk_ch:
        cmp al, 'A'
        jb .nk_dig
        cmp al, 'Z'
        jbe .nk_nx
        jmp .nk_no
.nk_dig:
        cmp al, '0'
        jb .nk_no
        cmp al, '9'
        ja .nk_no
.nk_nx:
        inc si
        inc bx
        cmp bx, 10
        jb .nk_l
        jmp .nk_no
.nk_end:
        cmp bx, 2
        jb .nk_no
        mov si, di
        mov di, s_sysop
        call streq
        cmp al, 1
        je .nk_no
        mov al, 1
        jmp .nk_out
.nk_no:
        xor al, al
.nk_out:
        pop si
        pop di
        pop bx
        ret

chat_ok:                        ; AL=1 if chat enabled, MUX on, SLIP/TCP off
        mov ah, 37
        int 0x60
        test ax, ax
        jz .co_no
        mov ah, 29
        int 0x60
        test ax, 8
        jz .co_no
        test ax, 4
        jnz .co_no
        mov al, 1
        ret
.co_no:
        xor al, al
        ret

kceq:                           ; DI=CS string, AX=kernel offset -> AL=1 equal
        push si
        push es
        mov si, ax
        mov ax, KERNEL_SEG
        mov es, ax
.ke_l:
        mov al, [di]
        cmp al, [es:si]
        jne .ke_n
        test al, al
        jz .ke_y
        inc di
        inc si
        jmp .ke_l
.ke_n:
        xor al, al
        pop es
        pop si
        ret
.ke_y:
        mov al, 1
        pop es
        pop si
        ret

sess_nick:                     ; AX=token, DI=dest(CS) -> CF=0 found, CF=1
        push ax
        push bx
        push cx
        push dx
        push si
        push es
        mov bx, SESS_ENT
        mov cx, SESS_N
        mov dx, CHATAPI_SEG
        mov es, dx
.sn_l:
        cmp byte [es:bx], 0
        je .sn_n
        cmp [es:bx+1], ax
        je .sn_f
.sn_n:
        add bx, SESS_SZ
        dec cx
        jnz .sn_l
        pop es
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        stc
        ret
.sn_f:
        mov si, bx
        add si, 3
        mov cx, 9
.sn_c:
        mov al, [es:si]
        mov [di], al
        test al, al
        jz .sn_d
        inc si
        inc di
        dec cx
        jnz .sn_c
        mov byte [di], 0
.sn_d:
        pop es
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        clc
        ret

sess_alloc:                    ; DI=nick(CS) -> AX=token; CF=1 if full
        push bx
        push cx
        push dx
        push si
        push es
        mov bx, SESS_ENT
        mov cx, SESS_N
        mov dx, CHATAPI_SEG
        mov es, dx
.sa_l:
        cmp byte [es:bx], 0
        je .sa_f
        add bx, SESS_SZ
        dec cx
        jnz .sa_l
        pop es
        pop si
        pop dx
        pop cx
        pop bx
        stc
        ret
.sa_f:
        inc word [es:SESS_NEXT]
        mov ax, [es:SESS_NEXT]
        test ax, ax
        jnz .sa_t
        inc word [es:SESS_NEXT]
        mov ax, [es:SESS_NEXT]
.sa_t:
        mov byte [es:bx], 1
        mov [es:bx+1], ax
        mov si, di
        mov di, bx
        add di, 3
        mov cx, 9
.sa_c:
        mov dl, [si]
        mov [es:di], dl
        test dl, dl
        jz .sa_d
        inc si
        inc di
        dec cx
        jnz .sa_c
        mov byte [es:di], 0
.sa_d:
        pop es
        pop si
        pop dx
        pop cx
        pop bx
        clc
        ret

sess_free:                    ; AX=token -> CF=0 freed, CF=1 not found
        push bx
        push cx
        push dx
        push es
        mov bx, SESS_ENT
        mov cx, SESS_N
        mov dx, CHATAPI_SEG
        mov es, dx
.sf_l:
        cmp byte [es:bx], 0
        je .sf_n
        cmp [es:bx+1], ax
        je .sf_h
.sf_n:
        add bx, SESS_SZ
        dec cx
        jnz .sf_l
        pop es
        pop dx
        pop cx
        pop bx
        stc
        ret
.sf_h:
        mov byte [es:bx], 0
        pop es
        pop dx
        pop cx
        pop bx
        clc
        ret

nick_inuse:                    ; AL=1 if appbuf matches a terminal or API nick
        push bx
        push cx
        push dx
        push si
        push di
        push es
        xor bx, bx
.ni_t:
        cmp bx, 13
        jae .ni_api
        mov al, bl
        mov ah, 30
        int 0x60
        jc .ni_tn
        mov di, appbuf
        call kceq
        cmp al, 1
        je .ni_y
.ni_tn:
        inc bx
        jmp .ni_t
.ni_api:
        mov dx, CHATAPI_SEG
        mov es, dx
        mov bx, SESS_ENT
        mov cx, SESS_N
.ni_a:
        cmp byte [es:bx], 0
        je .ni_an
        mov si, bx
        add si, 3
        mov di, appbuf
.ni_c:
        mov al, [di]
        cmp al, [es:si]
        jne .ni_an
        test al, al
        jz .ni_y
        inc di
        inc si
        jmp .ni_c
.ni_an:
        add bx, SESS_SZ
        dec cx
        jnz .ni_a
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        xor al, al
        ret
.ni_y:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        mov al, 1
        ret

san_text:                      ; sanitize chattext: \ -> /, drop <32, 127, "
        push ax
        push si
        push di
        mov si, chattext
        mov di, chattext
.st_l:
        mov al, [si]
        test al, al
        jz .st_d
        cmp al, 0x5C
        jne .st_q
        mov al, '/'
.st_q:
        cmp al, 0x20
        jb .st_s
        cmp al, 0x7F
        je .st_s
        cmp al, '"'
        je .st_s
        stosb
.st_s:
        inc si
        jmp .st_l
.st_d:
        mov byte [di], 0
        pop di
        pop si
        pop ax
        ret

emit_api:                      ; append API session nicks to the JSON body
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov byte [w_n], 0
        xor bx, bx
.ea_l:
        cmp bx, SESS_N
        jae .ea_d
        mov ax, bx
        mov dx, ax
        mov cl, 4
        shl ax, cl
        mov cl, 1
        shl dx, cl
        sub ax, dx                    ; *14
        add ax, SESS_ENT
        push es
        mov dx, CHATAPI_SEG
        mov es, dx
        mov si, ax
        cmp byte [es:si], 0
        je .ea_ns
        add si, 3
        mov di, appbuf
        mov cx, 9
.ea_c:
        mov al, [es:si]
        mov [di], al
        test al, al
        jz .ea_ce
        inc si
        inc di
        dec cx
        jnz .ea_c
        mov byte [di], 0
.ea_ce:
        pop es
        cmp byte [w_n], 0
        je .ea_nc
        mov si, j_cma
        call b_str
.ea_nc:
        mov byte [w_n], 1
        mov si, j_quo
        call b_str
        mov si, appbuf
        call b_str
        mov si, j_quo
        call b_str
        jmp .ea_n
.ea_ns:
        pop es
.ea_n:
        inc bx
        jmp .ea_l
.ea_d:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret


api_list_build:                 ; rebuild "  API: nick nick" at CHATAPI:API_LIST
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov dx, CHATAPI_SEG
        mov es, dx
        mov di, API_LIST
        mov si, s_api_pfx
.ap_p:
        lodsb
        test al, al
        jz .ap_init
        mov [es:di], al
        inc di
        jmp .ap_p
.ap_init:
        mov byte [w_n], 0
        xor bx, bx
.ap_l:
        cmp bx, SESS_N
        jae .ap_end
        mov ax, bx
        mov dx, ax
        mov cl, 4
        shl ax, cl
        mov cl, 1
        shl dx, cl
        sub ax, dx
        add ax, SESS_ENT
        mov si, ax
        cmp byte [es:si], 0
        je .ap_n
        cmp byte [w_n], 0
        je .ap_first
        mov al, ' '
        mov [es:di], al
        inc di
.ap_first:
        mov byte [w_n], 1
        add si, 3
        mov cx, 9
.ap_c:
        mov al, [es:si]
        test al, al
        jz .ap_n
        mov [es:di], al
        inc si
        inc di
        dec cx
        jnz .ap_c
.ap_n:
        inc bx
        jmp .ap_l
.ap_end:
        cmp byte [w_n], 0
        jne .ap_term
        mov byte [es:API_LIST], 0
        jmp .ap_out
.ap_term:
        mov byte [es:di], 0
.ap_out:
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

chat_announce:                 ; SI=text, DI=nick -> AH=34 broadcast "nick: text"
        push ax
        push bx
        push si
        push di
        push es
        mov bx, si
        mov si, di
        mov ax, cs
        mov es, ax
        mov di, rbuf
.ca_n:
        lodsb
        stosb
        test al, al
        jnz .ca_n
        mov si, bx
.ca_t:
        lodsb
        stosb
        test al, al
        jnz .ca_t
        mov si, rbuf
        mov ah, 34
        int 0x60
        pop es
        pop di
        pop si
        pop bx
        pop ax
        ret

finish:                         ; NUL-terminate, send headers+body paced
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov di, [b_ptr]
        add di, bodybuf
        mov byte [di], 0
        ; count the LFs: every one goes out as CR+LF, so Length = body + LFs
        xor cx, cx
        mov si, bodybuf
.fs_l:
        cmp si, di
        jae .fs_d
        cmp byte [si], 10
        jne .fs_n
        inc cx
.fs_n:
        inc si
        jmp .fs_l
.fs_d:
        mov [b_nl], cl
        mov si, [resp_hdr]
        call pstr
        mov bl, [b_nl]
        xor bh, bh
        add bx, [b_ptr]                ; body bytes + inserted CRs
        call putnum
        mov si, hdr_end
        call pstr
        mov si, bodybuf
        call pstr
        mov ah, 23
        int 0x60
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

pstr:                           ; DS:SI NUL string -> AH=31 paced send
        push ax
        push bx
        push cx
        push si
        push di
        mov di, si
        xor cx, cx
.ps_l:
        cmp byte [di], 0
        je .ps_d
        inc di
        inc cx
        jmp .ps_l
.ps_d:
        mov ah, 31
        int 0x60
        pop di
        pop si
        pop cx
        pop bx
        pop ax
        ret

streq:                          ; SI vs DI -> AL=1 if equal
        push si
        push di
.sq:
        mov al, [si]
        cmp al, [di]
        jne .no
        test al, al
        jz .yes
        inc si
        inc di
        jmp .sq
.no:
        xor al, al
        pop di
        pop si
        ret
.yes:
        mov al, 1
        pop di
        pop si
        ret

; =====================================================================
; Job manager helpers
; =====================================================================

pfx:                            ; SI path, DI prefix -> AL=1 if exact or prefix + '/'
        push si
        push di
.pf_l:
        mov al, [di]
        test al, al
        jz .pf_end
        cmp al, [si]
        jne .pf_no
        inc si
        inc di
        jmp .pf_l
.pf_end:
        mov al, [si]
        test al, al
        jz .pf_yes
        cmp al, '/'
        je .pf_yes
.pf_no:
        xor al, al
        pop di
        pop si
        ret
.pf_yes:
        mov al, 1
        pop di
        pop si
        ret

keq:                            ; DI literal, keybuf -> AL=1 if equal (SI untouched)
        push si
        push di
        mov si, keybuf
.kq_l:
        mov al, [si]
        cmp al, [di]
        jne .kq_n
        test al, al
        jz .kq_y
        inc si
        inc di
        jmp .kq_l
.kq_n:
        xor al, al
        pop di
        pop si
        ret
.kq_y:
        mov al, 1
        pop di
        pop si
        ret

jw:                             ; skip whitespace at SI
        mov al, [si]
        cmp al, ' '
        je .jw_s
        cmp al, 9
        je .jw_s
        cmp al, 10
        je .jw_s
        cmp al, 13
        jne .jw_d
.jw_s:
        inc si
        jmp jw
.jw_d:
        ret

jstr:                           ; SI after quote, DI dest, CX max chars -> CF=1 if bad
        push bx
        xor bx, bx
.js_l:
        mov al, [si]
        test al, al
        jz .js_e
        cmp al, '"'
        je .js_d
        cmp bx, cx
        jae .js_e
        mov [di], al
        inc di
        inc bx
        inc si
        jmp .js_l
.js_d:
        mov byte [di], 0
        inc si
        pop bx
        clc
        ret
.js_e:
        pop bx
        stc
        ret

jnum:                           ; SI digits -> AX, SI advanced; CF=1 if none
        xor bx, bx
        xor ax, ax
.jn_l:
        mov cl, [si]
        cmp cl, '0'
        jb .jn_d
        cmp cl, '9'
        ja .jn_d
        sub cl, '0'
        push dx
        mov dx, 10
        mul dx
        pop dx
        xor ch, ch
        add ax, cx
        inc si
        inc bx
        jmp .jn_l
.jn_d:
        test bx, bx
        jz .jn_e
        clc
        ret
.jn_e:
        stc
        ret

jskipv:                         ; skip one JSON value at SI
        call jw
        mov al, [si]
        cmp al, '"'
        je .jv_str
        cmp al, '{'
        je .jv_obj
.jv_num:
        mov al, [si]
        cmp al, ','
        je .jv_d
        cmp al, '}'
        je .jv_d
        cmp al, ']'
        je .jv_d
        test al, al
        jz .jv_d
        inc si
        jmp .jv_num
.jv_str:
        inc si
.jv_sl:
        mov al, [si]
        test al, al
        jz .jv_d
        cmp al, '"'
        je .jv_sd
        inc si
        jmp .jv_sl
.jv_sd:
        inc si
        ret
.jv_obj:
        xor cx, cx
.jv_ol:
        mov al, [si]
        test al, al
        jz .jv_d
        cmp al, '{'
        jne .jv_o2
        inc cx
.jv_o2:
        cmp al, '}'
        jne .jv_o3
        dec cx
        jz .jv_od
.jv_o3:
        inc si
        jmp .jv_ol
.jv_od:
        inc si
.jv_d:
        ret

jparse:                         ; parse the body in jbuf -> appbuf/plimit/pseed; CF=1 bad
        mov si, jbuf
        call jw
        cmp byte [si], '{'
        jne .jp_bad
        inc si
        mov byte [have_app], 0
        mov word [plimit], 1000
        mov word [pseed], 1
        mov byte [vcount], 0
        mov byte [have_values], 0
        mov byte [have_data], 0
        mov word [dlen], 0
.jp_l:
        call jw
        mov al, [si]
        cmp al, '}'
        je .jp_done
        cmp al, ','
        jne .jp_key
        inc si
        jmp .jp_l
.jp_key:
        cmp al, '"'
        jne .jp_bad
        inc si
        mov di, keybuf
        mov cx, 8
        call jstr
        jc .jp_bad
        call jw
        cmp byte [si], ':'
        jne .jp_bad
        inc si
        call jw
        mov di, k_app
        call keq
        cmp al, 1
        je .jp_app
        mov di, k_params
        call keq
        cmp al, 1
        je .jp_params
        call jskipv
        jmp .jp_l
.jp_app:
        cmp byte [si], '"'
        jne .jp_bad
        inc si
        mov di, appbuf
        mov cx, 8
        call jstr
        jc .jp_bad
        mov byte [have_app], 1
        jmp .jp_l
.jp_params:
        cmp byte [si], '{'
        jne .jp_bad
        inc si
.jp_pl:
        call jw
        mov al, [si]
        cmp al, '}'
        je .jp_pd
        cmp al, ','
        jne .jp_pk
        inc si
        jmp .jp_pl
.jp_pk:
        cmp al, '"'
        jne .jp_bad
        inc si
        mov di, keybuf
        mov cx, 8
        call jstr
        jc .jp_bad
        call jw
        cmp byte [si], ':'
        jne .jp_bad
        inc si
        call jw
        mov di, k_limit
        call keq
        cmp al, 1
        je .jp_lim
        mov di, k_seed
        call keq
        cmp al, 1
        je .jp_sd
        mov di, k_data
        call keq
        cmp al, 1
        je .jp_data
        mov di, k_values
        call keq
        cmp al, 1
        je .jp_values
        call jskipv
        jmp .jp_pl
.jp_lim:
        call jnum
        jc .jp_bad
        mov [plimit], ax
        jmp .jp_pl
.jp_sd:
        call jnum
        jc .jp_bad
        mov [pseed], ax
        jmp .jp_pl
.jp_data:
        cmp byte [si], '"'
        jne .jp_bad
        inc si
        mov di, vdata
        mov cx, 255
        call jstr
        jc .jp_bad
        mov ax, di
        sub ax, vdata
        mov [dlen], ax
        mov byte [have_data], 1
        jmp .jp_pl
.jp_values:
        cmp byte [si], '['
        jne .jp_bad
        inc si
        mov byte [vcount], 0
        mov byte [have_values], 1
.jp_vl:
        call jw
        mov al, [si]
        cmp al, ']'
        je .jp_vd
        cmp al, ','
        jne .jp_vs
        inc si
        jmp .jp_vl
.jp_vs:
        cmp al, '"'
        jne .jp_bad
        inc si
        mov al, [vcount]
        cmp al, STR_MAX
        jae .jp_bad
        xor ah, ah
        mov cl, 4
        shl ax, cl
        mov di, vals
        add di, ax
        mov cx, STR_LEN-1
        call jstr
        jc .jp_bad
        inc byte [vcount]
        call jw
        mov al, [si]
        cmp al, ','
        je .jp_vc
        cmp al, ']'
        je .jp_vd
        jmp .jp_bad
.jp_vc:
        inc si
        jmp .jp_vl
.jp_vd:
        inc si
        jmp .jp_pl
.jp_pd:
        inc si
        jmp .jp_l
.jp_done:
        inc si
        call jw
        cmp byte [si], 0
        jne .jp_bad
        cmp byte [have_app], 0
        je .jp_bad
        clc
        ret
.jp_bad:
        stc
        ret

read_body:                      ; fill jbuf from the session; CF=1 bad, body_err set
        mov word [jlen], 0
        mov byte [body_err], 1
        mov byte [brace], 0
        mov byte [instr], 0
        mov byte [esc], 0
        mov ah, 9
        int 0x60
        mov [jstart], ax
.rb_l:
        mov ah, 32
        int 0x60
        jnc .rb_got
        mov ah, 9
        int 0x60
        sub ax, [jstart]
        cmp ax, [body_timeout]
        ja .rb_err
        mov ah, 7
        int 0x60
        jmp .rb_l
.rb_got:
        mov di, [jlen]
        cmp di, JBUF_MAX-1
        jae .rb_big
        mov [jbuf+di], al
        inc word [jlen]
        ; braces inside JSON strings do not count
        cmp byte [esc], 0
        je .rb_ne
        mov byte [esc], 0
        jmp .rb_l
.rb_ne:
        cmp byte [instr], 0
        je .rb_ns
        cmp al, '\'
        jne .rb_nq
        mov byte [esc], 1
        jmp .rb_l
.rb_nq:
        cmp al, '"'
        jne .rb_l
        mov byte [instr], 0
        jmp .rb_l
.rb_ns:
        cmp al, '"'
        jne .rb_nb
        mov byte [instr], 1
        jmp .rb_l
.rb_nb:
        cmp al, '{'
        jne .rb_c
        inc byte [brace]
        jmp .rb_l
.rb_c:
        cmp al, '}'
        jne .rb_l
        dec byte [brace]
        cmp byte [brace], 0
        jne .rb_l
        mov di, [jlen]
        mov byte [jbuf+di], 0
        mov byte [body_err], 0
        clc
        ret
.rb_err:
        stc
        ret
.rb_big:
        mov byte [body_err], 2
        stc
        ret

find_job:                      ; AX=id -> CF=0, DI=entry
        push bx
        push cx
        mov di, jobs
        mov cx, JOB_MAX
.fj_l:
        cmp byte [di+2], 0
        je .fj_n
        cmp [di], ax
        je .fj_y
.fj_n:
        add di, JOB_SIZE
        loop .fj_l
        pop cx
        pop bx
        stc
        ret
.fj_y:
        pop cx
        pop bx
        clc
        ret

app_name_ptr:                  ; AL=app -> SI
        cmp al, 0
        jne .an_1
        mov si, a_prime
        ret
.an_1:
        cmp al, 1
        je .an_s
        cmp al, 3
        je .an_s
        mov si, a_crc16
        ret
.an_s:
        mov si, a_sort
        ret

state_ptr:                     ; AL=state -> SI
        cmp al, 1
        jne .st_2
        mov si, s_queued
        ret
.st_2:
        cmp al, 2
        jne .st_3
        mov si, s_running
        ret
.st_3:
        cmp al, 3
        jne .st_4
        mov si, s_done
        ret
.st_4:
        cmp al, 4
        jne .st_6
        mov si, s_canc
        ret
.st_6:
        cmp al, 6
        jne .st_f
        mov si, s_creq
        ret
.st_f:
        mov si, s_failed
        ret

b_job_brief:                   ; BX=entry -> {"job_id":..,"app":"..","status":".."}
        push ax
        push si
        cmp byte [w_n], 0
        je .bb_nc
        mov si, j_cma
        call b_str
.bb_nc:
        mov byte [w_n], 1
        mov si, j_jobid
        call b_str
        mov ax, [bx]
        call b_num
        mov si, j_app
        call b_str
        mov al, [bx+3]
        call app_name_ptr
        call b_str
        mov si, j_stat
        call b_str
        mov al, [bx+2]
        call state_ptr
        call b_str
        mov si, j_quo
        call b_str
        mov si, j_cb
        call b_str
        pop si
        pop ax
        ret

b_result:                     ; BX=entry (completed) -> app result object
        mov al, [bx+3]
        cmp al, 0
        je .br_p
        cmp al, 1
        je .br_s
        cmp al, 3
        je .br_v
        mov si, j_rc
        call b_str
        mov ax, [bx+12]
        call b_num
        mov si, j_cb
        call b_str
        ret
.br_v:
        push bp
        mov si, j_vcnt
        call b_str
        mov ax, [bx+4]
        call b_num
        mov si, j_vlist
        call b_str
        mov di, [bx+6]
        mov bp, [bx+4]
        mov byte [w_n], 0
.br_v_l:
        test bp, bp
        jz .br_v_d
        cmp byte [w_n], 0
        je .br_v_nc
        mov si, j_cma
        call b_str
.br_v_nc:
        mov byte [w_n], 1
        mov si, j_quo
        call b_str
        mov si, di
        call b_str
        mov si, j_quo
        call b_str
        add di, STR_LEN
        dec bp
        jmp .br_v_l
.br_v_d:
        mov si, j_vend
        call b_str
        pop bp
        ret
.br_p:
        mov si, j_rp
        call b_str
        mov ax, [bx+12]
        call b_num
        mov si, j_cb
        call b_str
        ret
.br_s:
        mov si, j_rs
        call b_str
        mov ax, [bx+12]
        call b_num
        mov si, j_rck
        call b_str
        mov ax, [bx+14]
        call b_num
        mov si, j_cb
        call b_str
        ret

; --- scheduler pump: called from the kernel idle hook ---
job_pump:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push bp
        push ds
        push es
        mov ax, cs
        mov ds, ax
        mov es, ax
        cmp byte [job_busy], 0
        jne .jpu_out
        mov al, 1
        xchg al, [job_in]
        test al, al
        jnz .jpu_out
        ; find a running (or cancel-requested) job
        mov bx, jobs
        mov cx, JOB_MAX
.jpu_scan:
        mov al, [bx+2]
        cmp al, 2
        je .jpu_run
        cmp al, 6
        je .jpu_run
        add bx, JOB_SIZE
        loop .jpu_scan
        ; none: dispatch the oldest queued
        xor dx, dx
        xor si, si
        mov bx, jobs
        mov cx, JOB_MAX
.jpu_q:
        cmp byte [bx+2], 1
        jne .jpu_qn
        mov ax, [bx]
        test dx, dx
        jz .jpu_best
        cmp ax, dx
        jae .jpu_qn
.jpu_best:
        mov dx, ax
        mov si, bx
.jpu_qn:
        add bx, JOB_SIZE
        loop .jpu_q
        test dx, dx
        jz .jpu_out2
        mov di, si
        mov byte [di+2], 2
        mov ah, 9
        int 0x60
        mov [di+16], ax
        call app_init
        call app_step
        jc .jpu_done
        jmp .jpu_out2
.jpu_run:
        mov di, bx
        cmp byte [bx+2], 6
        je .jpu_cancel
        call app_step
        jc .jpu_done
        jmp .jpu_out2
.jpu_cancel:
        mov byte [di+2], 4
        mov ah, 9
        int 0x60
        mov [di+18], ax
        jmp .jpu_out2
.jpu_done:
        mov byte [di+2], 3
        mov ah, 9
        int 0x60
        mov [di+18], ax
.jpu_out2:
        mov byte [job_in], 0
.jpu_out:
        pop es
        pop ds
        pop bp
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        retf

app_init:                       ; DI = job entry
        push ax
        push cx
        push si
        mov al, [di+3]
        cmp al, 0
        je .ai_p
        cmp al, 1
        je .ai_s
        cmp al, 3
        je .ai_v
        mov word [di+8], 0
        mov word [di+12], 0xFFFF
        jmp .ai_d
.ai_v:
        mov word [di+8], 0
        mov word [di+10], 0
        jmp .ai_d
.ai_p:
        mov word [di+8], 2
        mov word [di+10], 0
        jmp .ai_d
.ai_s:
        mov cx, [di+4]
        mov word [di+8], 0
        mov word [di+10], 0
        mov word [di+12], cx
        mov ax, [di+6]
        mov si, sort_arr
.ai_sl:
        test cx, cx
        jz .ai_d
        mov dx, 25173
        mul dx
        add ax, 13849
        mov [si], ax
        add si, 2
        dec cx
        jmp .ai_sl
.ai_d:
        pop si
        pop cx
        pop ax
        ret

scmp:                           ; SI,BX strings -> CF=1 if [SI] > [BX]
        push si
        push bx
        push ax
        push cx
.sc_l:
        mov al, [si]
        mov cl, [bx]
        cmp al, cl
        jne .sc_ne
        test al, al
        jz .sc_eq
        inc si
        inc bx
        jmp .sc_l
.sc_ne:
        ja .sc_gt
.sc_eq:
        clc
        jmp .sc_out
.sc_gt:
        stc
.sc_out:
        pop cx
        pop ax
        pop bx
        pop si
        ret

sswap:                          ; swap STR_LEN bytes at SI and BX
        push ax
        push cx
        push dx
        push si
        push bx
        mov cx, STR_LEN/2
.ss_l:
        mov ax, [si]
        mov dx, [bx]
        mov [si], dx
        mov [bx], ax
        add si, 2
        add bx, 2
        loop .ss_l
        pop bx
        pop si
        pop dx
        pop cx
        pop ax
        ret

app_step:                       ; DI = job entry -> CF=1 when complete
        mov al, [di+3]
        cmp al, 0
        je .as_p
        cmp al, 1
        je .as_s
        cmp al, 2
        je .as_c
        cmp al, 3
        je .as_v
        jmp .as_d4

.as_p:
        mov bp, 8
.as_p_l:
        mov ax, [di+8]
        cmp ax, [di+4]
        ja .as_pdone
        cmp ax, 2
        je .as_pyes
        cmp ax, 2
        jb .as_pnext
        test ax, 1
        jz .as_pnext
        mov bx, 3
.as_p_d:
        push ax
        mov ax, bx
        mul bx
        mov cx, ax
        pop ax
        cmp cx, ax
        ja .as_pyes
        push ax
        xor dx, dx
        div bx
        test dx, dx
        pop ax
        jz .as_pnext
        add bx, 2
        jmp .as_p_d
.as_pyes:
        inc word [di+10]
.as_pnext:
        inc word [di+8]
        dec bp
        jnz .as_p_l
        clc
        ret
.as_pdone:
        mov ax, [di+10]
        mov [di+12], ax
        stc
        ret

.as_s:
        mov cx, [di+12]
        mov bp, 64
.as_s_l:
        mov ax, [di+8]
        cmp ax, cx
        jae .as_sdone
        mov bx, [di+10]
        mov si, bx
        inc si
        cmp si, cx
        jae .as_snext
        shl bx, 1
        mov ax, [sort_arr+bx]
        mov dx, [sort_arr+bx+2]
        cmp ax, dx
        jbe .as_sns
        mov [sort_arr+bx], dx
        mov [sort_arr+bx+2], ax
.as_sns:
        inc word [di+10]
        dec bp
        jnz .as_s_l
        clc
        ret
.as_snext:
        inc word [di+8]
        mov word [di+10], 0
        dec bp
        jnz .as_s_l
        clc
        ret
.as_sdone:
        mov cx, [di+12]
        mov si, sort_arr
        xor ax, ax
.as_ssum:
        add ax, [si]
        add si, 2
        loop .as_ssum
        mov [di+14], ax
        stc
        ret

.as_v:
        mov cx, [di+4]              ; string count
        mov bp, 32
.as_v_l:
        mov ax, [di+8]              ; pass
        cmp ax, cx
        jae .as_vdone
        mov bx, [di+10]             ; j
        mov si, bx
        inc si
        cmp si, cx
        jae .as_vnext
        mov si, [di+6]              ; pool base
        mov ax, bx
        shl ax, 1
        shl ax, 1
        shl ax, 1
        shl ax, 1                   ; j*16
        add si, ax
        mov bx, si
        add bx, STR_LEN
        call scmp
        jnc .as_vns
        call sswap
.as_vns:
        inc word [di+10]
        dec bp
        jnz .as_v_l
        clc
        ret
.as_vnext:
        inc word [di+8]
        mov word [di+10], 0
        dec bp
        jnz .as_v_l
        clc
        ret
.as_vdone:
        stc
        ret

.as_d4:
        mov bp, 32
.as_d4l:
        mov ax, [di+8]              ; position
        cmp ax, [di+4]              ; length
        jae .as_d4done
        mov si, [di+6]
        add si, ax
        mov al, [si]
        mov ah, al
        xor al, al
        xor ax, [di+12]
        mov dx, ax
        mov cl, 8
.as_d4b:
        shl dx, 1
        jnc .as_d4n
        xor dx, 0x1021
.as_d4n:
        dec cl
        jnz .as_d4b
        mov [di+12], dx
        inc word [di+8]
        dec bp
        jnz .as_d4l
        clc
        ret
.as_d4done:
        stc
        ret

.as_c:
        mov bp, 32
.as_c_l:
        mov ax, [di+8]
        cmp ax, [di+4]
        jae .as_cdone
        mov ax, [di+6]
        mov dx, 25173
        mul dx
        add ax, 13849
        mov [di+6], ax
        mov ah, al
        xor al, al
        xor ax, [di+12]
        mov dx, ax
        mov cl, 8
.as_cbit:
        shl dx, 1
        jnc .as_cbn
        xor dx, 0x1021
.as_cbn:
        dec cl
        jnz .as_cbit
        mov [di+12], dx
        inc word [di+8]
        dec bp
        jnz .as_c_l
        clc
        ret
.as_cdone:
        stc
        ret

build_cdata:                    ; concatenate vals strings -> vdata, set dlen
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        mov di, vdata
        mov si, vals
        mov cl, [vcount]
        xor ch, ch
        test cx, cx
        jz .bc_d
.bc_s:
        mov bx, si
        mov dx, STR_LEN
.bc_c:
        mov al, [bx]
        test al, al
        jz .bc_n
        cmp di, vdata+255
        jae .bc_e
        mov [di], al
        inc di
        inc bx
        dec dx
        jnz .bc_c
.bc_n:
        add si, STR_LEN
        dec cx
        jnz .bc_s
.bc_d:
        mov ax, di
        sub ax, vdata
        mov [dlen], ax
        clc
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret
.bc_e:
        stc
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

job_slot_off:                  ; BX = entry -> AX = slot index
        push dx
        push cx
        mov ax, bx
        sub ax, jobs
        xor dx, dx
        mov cx, JOB_SIZE
        div cx
        pop cx
        pop dx
        ret

enum_routes:                    ; AX=len, CF=0; fragment in rbuf
        push si
        push di
        push cx
        push es
        mov ax, 0
        mov es, ax
        cmp word [es:0x18A], 0x2000
        jne .er_nf
        push cs
        pop es
        mov si, s__routes
        mov di, rbuf
        mov cx, 255
        xor bx, bx
        xor dx, dx
        mov al, 'G'
        int 0x62
        jnc .er_ok
.er_nf:
        xor ax, ax
        stc
.er_ok:
        pop es
        pop cx
        pop di
        pop si
        ret

entry:
        cmp al, 0FFh
        jne .normal
        ; init call from load_api: announce the build, then return
        push ax
        push si
        push ds
        mov ax, cs
        mov ds, ax
        mov si, s_ver
        mov ah, 1
        int 0x60
        pop ds
        pop si
        pop ax
        mov bx, job_pump               ; advertise the job pump entry
        mov dx, 0x4A42                 ; 'BJ'
        retf
.normal:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        push ds                        ; the kernel's web task keeps using DS
        mov bl, al                     ; BL = method char
        ; serialize request handling: the overlay uses global buffers
.acq:
        mov al, 1
        xchg al, [cs:job_busy]         ; atomic test-and-set
        test al, al
        jz .acq_ok
        mov ax, 0x0700
        int 0x60                       ; yield, then retry
        jmp .acq
.acq_ok:
        ; copy the path out of the kernel segment (DS) into ours
        push ds
        mov ax, cs
        mov es, ax
        pop ds
        mov di, pathbuf
        mov cx, 63
.cp:
        lodsb
        stosb
        test al, al
        jz .cpd
        dec cx
        jnz .cp
.cpd:
        mov ax, cs
        mov ds, ax
        mov [req_method], bl
        mov word [resp_hdr], hdr_200

        ; method first: POST /api/jobs, DELETE /api/jobs/<id>
        cmp bl, 'P'
        je .post
        cmp bl, 'D'
        je .dele
        ; GET: explicit routes listing, then job routes
        mov si, pathbuf
        mov di, p_routes
        call streq
        cmp al, 1
        je .routes
        mov si, pathbuf
        mov di, p_jobs
        call pfx
        cmp al, 1
        je .jobs_get
        mov si, pathbuf
        mov di, p_apps
        call streq
        cmp al, 1
        je .apps
        mov si, pathbuf
        mov di, p_chatmsgs
        call pfx
        cmp al, 1
        je .chat_msgs

        mov si, pathbuf
        mov di, p_api
        call streq
        cmp al, 1
        je .list
        mov si, pathbuf
        mov di, p_sys
        call streq
        cmp al, 1
        je .sys
        mov si, pathbuf
        mov di, p_tk
        call streq
        cmp al, 1
        je .tasks
        mov si, pathbuf
        mov di, p_who
        call streq
        cmp al, 1
        je .who
        mov si, pathbuf
        mov di, p_cha
        call streq
        cmp al, 1
        je .chat
        mov si, pathbuf
        mov di, p_sta
        call streq
        cmp al, 1
        je .status
        mov si, pathbuf
        mov di, p_tim
        call streq
        cmp al, 1
        je .time
        mov si, pathbuf
        mov di, p_ver
        call streq
        cmp al, 1
        je .version
        mov si, pathbuf
        mov di, p_spd
        call streq
        cmp al, 1
        je .speed
        mov si, pathbuf
        mov di, p_usr
        call streq
        cmp al, 1
        je .users
        mov si, pathbuf
        mov di, p_ps
        call streq
        cmp al, 1
        je .ps
        mov si, pathbuf
        mov di, p_whom
        call streq
        cmp al, 1
        je .whoami
        mov si, pathbuf
        mov di, p_mem
        call streq
        cmp al, 1
        je .mem
        ; no built-in match: try a GET BASIC route
        xor bx, bx
        xor dx, dx
        mov al, 'G'
        jmp .route_go

.route_go:
        call .callroute
        jnc .route_ok
        cmp al, 2
        je .route_busy
        cmp al, 3
        je .route_err
        jmp .noroute
.route_ok:
        mov [b_ptr], ax
        mov word [resp_hdr], hdr_200
        call finish
        jmp .out
.route_busy:
        mov word [resp_hdr], hdr_503
        mov word [b_ptr], 0
        mov si, e_busy
        call b_str
        call finish
        jmp .out
.route_err:
        mov word [resp_hdr], hdr_500
        mov word [b_ptr], 0
        mov si, e_rerr
        call b_str
        call finish
        jmp .out
.callroute:
        push ax
        push bx
        push dx
        mov ax, 0
        mov es, ax
        cmp word [es:0x18A], 0x2000
        jne .cr_nf
        push cs
        pop es
        mov si, pathbuf
        mov di, bodybuf
        mov cx, 767
        pop dx
        pop bx
        pop ax
        int 0x62
        ret
.cr_nf:
        pop dx
        pop bx
        pop ax
        mov al, 1
        stc
        ret
.noroute:
        mov si, nf
        call puts
        jmp .out

; ---------------------------------------------------------------------
; Job routes
; ---------------------------------------------------------------------
.post:
        mov si, pathbuf
        mov di, p_jobs
        call streq
        cmp al, 1
        jne .post_join
        jmp .job_create
.post_join:
        mov si, pathbuf
        mov di, p_chatjoin
        call streq
        cmp al, 1
        jne .post_send
        jmp .chat_join
.post_send:
        mov si, pathbuf
        mov di, p_chatsend
        call streq
        cmp al, 1
        jne .route_post
        jmp .chat_send

.dele:
        mov si, pathbuf
        mov di, p_jobs
        call pfx
        cmp al, 1
        jne .del_chat
        mov si, pathbuf+9
        cmp byte [si], '/'
        jne .badreq
        inc si
        call jnum
        jc .badreq
        test ax, ax
        jz .badreq
        mov [job_id], ax
        cmp byte [si], 0
        jne .badreq
        jmp .job_cancel
.del_chat:
        mov si, pathbuf
        mov di, p_chatjoin
        call pfx
        cmp al, 1
        jne .route_del
        mov si, pathbuf+14
        cmp byte [si], '/'
        jne .badreq
        inc si
        call jnum
        jc .badreq
        test ax, ax
        jz .badreq
        mov [chat_token], ax
        cmp byte [si], 0
        jne .badreq
        jmp .chat_leave

.jobs_get:
        mov si, pathbuf
        mov di, p_jobs
        call streq
        cmp al, 1
        je .jobs_list
        mov si, pathbuf+9
        cmp byte [si], '/'
        jne .badreq
        inc si
        call jnum
        jc .badreq
        test ax, ax
        jz .badreq
        mov [job_id], ax
        cmp byte [si], 0
        je .job_detail
        mov di, p_res
        call streq
        cmp al, 1
        jne .badreq
        jmp .job_result

.badreq:
        mov word [resp_hdr], hdr_400
        mov word [b_ptr], 0
        mov si, e_bad
        call b_str
        call finish
        jmp .out
.e404:
        mov word [resp_hdr], hdr_404
        mov word [b_ptr], 0
        mov si, e_nf
        call b_str
        call finish
        jmp .out
.e409:
        mov si, e_conf
.e409m:
        mov word [resp_hdr], hdr_409
        mov word [b_ptr], 0
        call b_str
        call finish
        jmp .out
.e503:
        mov word [resp_hdr], hdr_503
        mov word [b_ptr], 0
        mov si, e_full
        call b_str
        call finish
        jmp .out
.job_bad:
        cmp byte [body_err], 2
        jne .badreq
        mov word [resp_hdr], hdr_413
        mov word [b_ptr], 0
        mov si, e_big
        call b_str
        call finish
        jmp .out

.route_post:
        mov word [body_timeout], 30
        call read_body
        mov word [body_timeout], 120
        cmp byte [body_err], 2
        je .job_bad
        mov bx, [jlen]
        test bx, bx
        jz .route_post_e
        mov dx, jbuf
        mov al, 'P'
        jmp .route_go
.route_post_e:
        xor bx, bx
        xor dx, dx
        mov al, 'P'
        jmp .route_go
.route_del:
        xor bx, bx
        xor dx, dx
        mov al, 'D'
        jmp .route_go

.job_create:
        call read_body
        jc .job_bad
        call jparse
        jc .badreq
        mov si, appbuf
        mov di, a_prime
        call streq
        cmp al, 1
        je .jc_a0
        mov si, appbuf
        mov di, a_sort
        call streq
        cmp al, 1
        jne .jc_lc
        cmp byte [have_values], 0
        je .jc_a1
        mov al, 3                       ; sort with caller-supplied strings
        jmp .jc_app
.jc_lc:
        mov si, appbuf
        mov di, a_crc16
        call streq
        cmp al, 1
        jne .badreq
        cmp byte [have_data], 0
        jne .jc_a4
        cmp byte [have_values], 0
        jne .jc_a4
        jmp .jc_a2
.jc_a0:
        xor al, al
        jmp .jc_app
.jc_a1:
        mov al, 1
        jmp .jc_app
.jc_a2:
        mov al, 2
        jmp .jc_app
.jc_a4:
        mov al, 4                       ; crc16 over caller-supplied data
.jc_app:
        mov [job_app], al
        mov ax, [plimit]
        cmp byte [job_app], 0
        jne .jc_c1
        cmp ax, 2
        jae .jc_p2
        mov ax, 2
.jc_p2:
        cmp ax, 5000
        jbe .jc_clim
        mov ax, 5000
        jmp .jc_clim
.jc_c1:
        cmp byte [job_app], 1
        jne .jc_c2
        cmp ax, 2
        jae .jc_s2
        mov ax, 2
.jc_s2:
        cmp ax, 32
        jbe .jc_clim
        mov ax, 32
        jmp .jc_clim
.jc_c2:
        cmp byte [job_app], 2
        jne .jc_c3
        cmp ax, 1
        jae .jc_r2
        mov ax, 1
.jc_r2:
        cmp ax, 1024
        jbe .jc_clim
        mov ax, 1024
        jmp .jc_clim
.jc_c3:
        cmp byte [job_app], 3
        jne .jc_c4
        mov al, [vcount]
        xor ah, ah
        test ax, ax
        jz .badreq
        jmp .jc_clim
.jc_c4:
        cmp byte [have_data], 0
        jne .jc_c4d
        call build_cdata
        jc .badreq
.jc_c4d:
        mov ax, [dlen]
        test ax, ax
        jz .badreq
        cmp ax, 255
        jbe .jc_clim
        mov ax, 255
.jc_clim:
        mov [plimit], ax
        mov bx, jobs
        mov cx, JOB_MAX
.jc_free:
        cmp byte [bx+2], 0
        je .jc_use
        add bx, JOB_SIZE
        loop .jc_free
        xor dx, dx
        xor si, si
        mov bx, jobs
        mov cx, JOB_MAX
.jc_old:
        mov al, [bx+2]
        cmp al, 3
        je .jc_oldc
        cmp al, 4
        je .jc_oldc
        cmp al, 5
        jne .jc_oldn
.jc_oldc:
        mov ax, [bx]
        test dx, dx
        jz .jc_oldb
        cmp ax, dx
        jae .jc_oldn
.jc_oldb:
        mov dx, ax
        mov si, bx
.jc_oldn:
        add bx, JOB_SIZE
        loop .jc_old
        test dx, dx
        jz .e503
        mov bx, si
.jc_use:
        mov ax, [job_next]
        inc word [job_next]
        test ax, ax
        jnz .jc_idok
        mov ax, 1
        mov [job_next], ax
.jc_idok:
        mov [bx], ax
        mov byte [bx+2], 1
        mov al, [job_app]
        mov [bx+3], al
        mov ax, [plimit]
        mov [bx+4], ax
        mov ax, [pseed]
        mov [bx+6], ax
        mov word [bx+8], 0
        mov word [bx+10], 0
        mov word [bx+12], 0
        mov word [bx+14], 0
        mov word [bx+16], 0
        mov word [bx+18], 0
        cmp byte [bx+3], 3
        je .jc_pool
        cmp byte [bx+3], 4
        je .jc_cdat
        jmp .jc_ready
.jc_pool:
        call job_slot_off                 ; AX = slot
        mov cx, STR_MAX*STR_LEN
        mul cx
        mov di, strpool
        add di, ax
        mov [bx+6], di                    ; pool offset
        push es
        push cs
        pop es
        mov si, vals
        mov cl, [vcount]
        xor ch, ch
        shl cx, 1
        shl cx, 1
        shl cx, 1
        shl cx, 1
        rep movsb
        pop es
        jmp .jc_ready
.jc_cdat:
        call job_slot_off
        mov cl, 8
        shl ax, cl                       ; slot * 256
        mov di, crcdat
        add di, ax
        mov [bx+6], di                    ; data offset
        push es
        push cs
        pop es
        mov si, vdata
        mov cx, [plimit]
        rep movsb
        pop es
.jc_ready:
        mov word [resp_hdr], hdr_202
        mov word [b_ptr], 0
        mov si, j_jobid
        call b_str
        mov ax, [bx]
        call b_num
        mov si, j_stat2
        call b_str
        mov si, s_queued
        call b_str
        mov si, j_quo
        call b_str
        mov si, j_end
        call b_str
        call finish
        jmp .out

.jobs_list:
        mov word [resp_hdr], hdr_200
        mov word [b_ptr], 0
        mov si, j_jobs
        call b_str
        mov byte [w_n], 0
        mov bx, jobs
        mov cx, JOB_MAX
.jl_l:
        cmp byte [bx+2], 0
        je .jl_n
        call b_job_brief
.jl_n:
        add bx, JOB_SIZE
        loop .jl_l
        mov si, j_w3
        call b_str
        call finish
        jmp .out

.job_detail:
        mov ax, [job_id]
        call find_job
        jc .e404
        mov bx, di
        mov word [resp_hdr], hdr_200
        mov word [b_ptr], 0
        mov si, j_jobid
        call b_str
        mov ax, [bx]
        call b_num
        mov si, j_app
        call b_str
        mov al, [bx+3]
        call app_name_ptr
        call b_str
        mov si, j_stat
        call b_str
        mov al, [bx+2]
        call state_ptr
        call b_str
        mov si, j_quo
        call b_str
        cmp byte [bx+2], 3
        jne .jd_ticks
        mov si, j_res
        call b_str
        call b_result
.jd_ticks:
        cmp word [bx+16], 0
        je .jd_done
        mov si, j_exe
        call b_str
        mov ax, [bx+16]
        mov cx, [bx+18]
        test cx, cx
        jnz .jd_end
        push bx
        mov ah, 9
        int 0x60
        pop bx
        mov cx, ax
.jd_end:
        sub cx, ax
        mov ax, cx
        test ax, ax
        jnz .jd_num
        mov ax, 1                     ; finished inside one tick: report 1
.jd_num:
        call b_num
.jd_done:
        mov si, j_end
        call b_str
        call finish
        jmp .out

.job_result:
        mov ax, [job_id]
        call find_job
        jc .e404
        cmp byte [di+2], 3
        jne .e409
        mov bx, di
        mov word [resp_hdr], hdr_200
        mov word [b_ptr], 0
        mov si, j_jobid
        call b_str
        mov ax, [bx]
        call b_num
        mov si, j_res
        call b_str
        call b_result
        mov si, j_end
        call b_str
        call finish
        jmp .out

.job_cancel:
        mov ax, [job_id]
        call find_job
        jc .e404
        mov bx, di
        mov al, [bx+2]
        cmp al, 1
        je .jcq
        cmp al, 2
        je .jcr
        cmp al, 6
        je .jcr
        mov si, e_fin
        jmp .e409m
.jcq:
        mov byte [bx+2], 4
        jmp .jcok
.jcr:
        mov byte [bx+2], 6
.jcok:
        mov word [resp_hdr], hdr_200
        mov word [b_ptr], 0
        mov si, j_jobid
        call b_str
        mov ax, [bx]
        call b_num
        mov si, j_stat2
        call b_str
        mov si, s_creq
        call b_str
        mov si, j_quo
        call b_str
        mov si, j_end
        call b_str
        call finish
        jmp .out

.apps:
        mov word [resp_hdr], hdr_200
        mov word [b_ptr], 0
        mov si, j_apps
        call b_str
        mov si, j_aid
        call b_str
        mov si, a_prime
        call b_str
        mov si, j_adesc
        call b_str
        mov si, d_prime
        call b_str
        mov si, j_quo
        call b_str
        mov si, j_cb
        call b_str
        mov si, j_cma
        call b_str
        mov si, j_aid
        call b_str
        mov si, a_sort
        call b_str
        mov si, j_adesc
        call b_str
        mov si, d_sort
        call b_str
        mov si, j_quo
        call b_str
        mov si, j_cb
        call b_str
        mov si, j_cma
        call b_str
        mov si, j_aid
        call b_str
        mov si, a_crc16
        call b_str
        mov si, j_adesc
        call b_str
        mov si, d_crc16
        call b_str
        mov si, j_quo
        call b_str
        mov si, j_cb
        call b_str
        mov si, j_w3
        call b_str
        call finish
        jmp .out

.list:
        mov word [b_ptr], 0
        mov si, j_list_a
        call b_str
        call enum_routes
        jc .list_end
        test ax, ax
        jz .list_end
        mov di, rbuf
        add di, ax
        mov byte [di], 0
        mov si, j_cma
        call b_str
        mov si, rbuf
        call b_str
.list_end:
        mov si, j_list_b
        call b_str
        call finish
        jmp .out

.routes:
        mov word [b_ptr], 0
        mov si, j_routes
        call b_str
        call enum_routes
        jc .routes_end
        mov di, rbuf
        add di, ax
        mov byte [di], 0
        mov si, rbuf
        call b_str
.routes_end:
        mov si, j_w3
        call b_str
        call finish
        jmp .out

.sys:
        mov word [b_ptr], 0
        mov si, j_sys
        call b_str
        mov ah, 22
        int 0x60
        call b_num
        mov si, j_up
        call b_str
        mov ah, 9
        int 0x60
        xor dx, dx
        mov cx, 18
        div cx
        call b_num
        mov si, j_end
        call b_str
        call finish
        jmp .out

.tasks:
        mov word [b_ptr], 0
        mov si, j_tk
        call b_str
        mov ah, 22
        int 0x60
        call b_num
        mov si, j_end
        call b_str
        call finish
        jmp .out

.who:
        mov word [b_ptr], 0
        xor bx, bx
        xor cx, cx
.w_c1:
        mov al, bl
        mov ah, 24
        int 0x60
        jc .w_c1n
        inc cx
.w_c1n:
        inc bx
        cmp bx, 13
        jb .w_c1
        mov si, j_w1
        call b_str
        mov ax, cx
        call b_num
        mov si, j_w2
        call b_str
        mov byte [w_n], 0
        xor bx, bx
.w_l:
        mov al, bl
        mov ah, 24
        int 0x60
        jc .w_ln
        cmp byte [w_n], 0
        je .w_nc
        push ax
        mov si, j_cma
        call b_str
        pop ax
.w_nc:
        mov byte [w_n], 1
        push ax
        mov si, j_quo
        call b_str
        pop ax
        mov cx, 16
        call b_name
        mov si, j_quo
        call b_str
.w_ln:
        inc bx
        cmp bx, 13
        jb .w_l
        mov si, j_w3
        call b_str
        call finish
        jmp .out

.chat:
        call chat_ok
        cmp al, 1
        jne .chat_unavail
        mov word [b_ptr], 0
        xor bx, bx
        xor cx, cx
.c_c1:
        mov al, bl
        mov ah, 30
        int 0x60
        jc .c_c1n
        inc cx
.c_c1n:
        inc bx
        cmp bx, 13
        jb .c_c1
        mov si, j_w1
        call b_str
        mov ax, cx
        call b_num
        mov si, j_nk
        call b_str
        mov byte [w_n], 0
        xor bx, bx
.c_l:
        mov al, bl
        mov ah, 30
        int 0x60
        jc .c_ln
        cmp byte [w_n], 0
        je .c_nc
        push ax
        mov si, j_cma
        call b_str
        pop ax
.c_nc:
        mov byte [w_n], 1
        push ax
        mov si, j_quo
        call b_str
        pop ax
        mov cx, 10
        call b_name
        mov si, j_quo
        call b_str
.c_ln:
        inc bx
        cmp bx, 13
        jb .c_l
        mov si, j_brk
        call b_str
        mov si, j_api
        call b_str
        call emit_api
        mov si, j_latest2
        call b_str
        push es
        mov ax, CHATAPI_SEG
        mov es, ax
        mov ax, [es:CH_SEQ]
        pop es
        call b_num
        mov si, j_endnl
        call b_str
        call finish
        jmp .out

; ---------------------------------------------------------------------
; Chat over HTTP (needs MUX on, SLIP/TCP off)
; ---------------------------------------------------------------------
.chat_join:
        call chat_ok
        cmp al, 1
        jne .chat_unavail
        mov word [body_timeout], 30
        call read_body
        mov word [body_timeout], 120
        cmp byte [body_err], 2
        je .job_bad
        mov si, jbuf
        mov di, k_nick
        call jfind
        jc .badreq
        cmp byte [si], '"'
        jne .badreq
        inc si
        mov di, appbuf
        mov cx, 9
        call jstr
        jc .chat_badnick
        mov si, appbuf
        call nickok
        cmp al, 1
        jne .chat_badnick
        call nick_inuse
        cmp al, 1
        je .chat_nused
        mov di, appbuf
        call sess_alloc
        jc .chat_nused
        mov [chat_token], ax
        call api_list_build
        mov si, s_chat_joinmsg          ; announce into the shared history
        mov di, appbuf
        call chat_announce
        mov word [b_ptr], 0
        mov si, j_token
        call b_str
        mov ax, [chat_token]
        call b_num
        mov si, j_end
        call b_str
        call finish
        jmp .out

.chat_send:
        call chat_ok
        cmp al, 1
        jne .chat_unavail
        mov word [body_timeout], 30
        call read_body
        mov word [body_timeout], 120
        cmp byte [body_err], 2
        je .job_bad
        mov si, jbuf
        mov di, k_token
        call jfind
        jc .badreq
        call jnum
        jc .badreq
        mov [chat_token], ax
        mov si, jbuf
        mov di, k_text
        call jfind
        jc .badreq
        cmp byte [si], '"'
        jne .badreq
        inc si
        mov di, chattext
        mov cx, 50
        call jstr
        jc .badreq
        call san_text
        mov ax, [chat_token]
        mov di, appbuf
        call sess_nick
        jc .chat_btok
        push es
        mov ax, cs
        mov es, ax
        mov di, rbuf
        mov si, appbuf
.cs_n:
        lodsb
        stosb
        test al, al
        jnz .cs_n
        mov si, chattext
.cs_t:
        lodsb
        stosb
        test al, al
        jnz .cs_t
        pop es
        mov si, rbuf
        mov ah, 34
        int 0x60
        mov [chat_latest], ax
        mov word [b_ptr], 0
        mov si, j_seq
        call b_str
        mov ax, [chat_latest]
        call b_num
        mov si, j_end
        call b_str
        call finish
        jmp .out

.chat_msgs:
        call chat_ok
        cmp al, 1
        jne .chat_unavail
        mov word [chat_since], 0
        mov si, pathbuf+18
        cmp byte [si], '/'
        jne .cms_have
        inc si
        call jnum
        jc .badreq
        mov [chat_since], ax
        cmp byte [si], 0
        jne .badreq
.cms_have:
        push es
        mov ax, CHATAPI_SEG
        mov es, ax
        mov ax, [es:CH_SEQ]
        pop es
        mov [chat_latest], ax
        mov word [b_ptr], 0
        mov si, j_latest
        call b_str
        mov ax, [chat_latest]
        call b_num
        mov si, j_messages
        call b_str
        mov byte [w_n], 0
        xor cx, cx
.cms_l:
        cmp cx, CH_N
        jae .cms_d
        mov ax, [b_ptr]
        cmp ax, 1650
        jae .cms_d
        mov bx, [chat_since]
        mov di, rbuf
        push es
        mov ax, cs
        mov es, ax
        mov ah, 35
        int 0x60
        pop es
        test ax, ax
        jz .cms_d
        mov [chat_since], ax
        cmp byte [w_n], 0
        je .cms_nc
        push ax
        mov si, j_cma
        call b_str
        pop ax
.cms_nc:
        mov byte [w_n], 1
        push ax
        mov si, j_seq
        call b_str
        mov ax, [chat_since]
        call b_num
        mov si, j_text
        call b_str
        mov si, rbuf+1
        call b_str
        mov si, j_quo
        call b_str
        mov si, j_mend
        call b_str
        pop ax
        inc cx
        jmp .cms_l
.cms_d:
        mov si, j_brk
        call b_str
        mov si, j_endnl
        call b_str
        call finish
        jmp .out

.chat_leave:
        call chat_ok
        cmp al, 1
        jne .chat_unavail
        mov ax, [chat_token]
        mov di, appbuf
        call sess_nick
        jc .chat_btok
        mov si, s_chat_leftmsg
        mov di, appbuf
        call chat_announce
        mov ax, [chat_token]
        call sess_free
        jc .chat_btok
        call api_list_build
        mov word [b_ptr], 0
        mov si, j_oktrue
        call b_str
        call finish
        jmp .out

.chat_unavail:
        mov word [resp_hdr], hdr_503
        mov word [b_ptr], 0
        mov si, e_chat
        call b_str
        call finish
        jmp .out
.chat_badnick:
        mov word [resp_hdr], hdr_400
        mov word [b_ptr], 0
        mov si, e_bnick
        call b_str
        call finish
        jmp .out
.chat_nused:
        mov word [resp_hdr], hdr_409
        mov word [b_ptr], 0
        mov si, e_nuse
        call b_str
        call finish
        jmp .out
.chat_btok:
        mov word [resp_hdr], hdr_400
        mov word [b_ptr], 0
        mov si, e_btok
        call b_str
        call finish
        jmp .out

.status:
        mov word [b_ptr], 0
        mov ah, 29
        int 0x60
        mov [st_fl], ax
        mov [st_rx], bx
        mov [st_tx], cx
        mov [st_er], dx
        mov si, j_w3a
        call b_str
        mov cl, 0
        call st_bit
        mov si, j_wl
        call b_str
        mov cl, 1
        call st_bit
        mov si, j_sl
        call b_str
        mov cl, 2
        call st_bit
        mov si, j_mx
        call b_str
        mov cl, 3
        call st_bit
        mov si, j_tf
        call b_str
        mov cl, 4
        call st_bit
        mov si, j_pv
        call b_str
        mov cl, 5
        call st_bit
        mov si, j_rx
        call b_str
        mov ax, [st_rx]
        call b_num
        mov si, j_tx
        call b_str
        mov ax, [st_tx]
        call b_num
        mov si, j_er
        call b_str
        mov ax, [st_er]
        call b_num
        mov si, j_end
        call b_str
        call finish
        jmp .out

.time:
        mov word [b_ptr], 0
        mov ah, 2
        int 0x1a                      ; CH=h, CL=m, DH=s (BCD)
        push cx
        push dx
        mov si, j_t1
        call b_str
        mov al, ch
        call bcd8
        mov si, j_t2
        call b_str
        pop dx
        pop cx
        push cx
        push dx
        mov al, cl
        call bcd8
        mov si, j_t3
        call b_str
        pop dx
        mov al, dh
        call bcd8
        mov si, j_end
        call b_str
        call finish
        jmp .out

.version:
        mov word [b_ptr], 0
        mov si, j_ver
        call b_str
        call finish
        jmp .out

.speed:
        mov word [b_ptr], 0
        mov ah, 28
        int 0x60
        push cx                        ; cpu_line offset
        push bx                        ; tick_hz
        push ax                        ; baud
        mov si, j_sp1
        call b_str
        pop ax
        call b_num
        mov si, j_sp2
        call b_str
        pop ax
        call b_num
        mov si, j_sp3
        call b_str
        pop ax
        mov cx, 39
        call b_name
        mov si, j_quo
        call b_str
        mov si, j_end
        call b_str
        call finish
        jmp .out

.users:
        mov word [b_ptr], 0
        xor bx, bx
        xor cx, cx
.u_c1:
        mov al, bl
        mov ah, 27
        int 0x60
        jc .u_cdone
        inc cx
        inc bx
        cmp bx, 16
        jb .u_c1
.u_cdone:
        mov si, j_w1
        call b_str
        mov ax, cx
        call b_num
        mov si, j_uu
        call b_str
        mov byte [w_n], 0
        xor bx, bx
.u_l:
        mov al, bl
        mov ah, 27
        int 0x60
        jc .u_ldone
        cmp byte [w_n], 0
        je .u_nc
        push ax
        mov si, j_cma
        call b_str
        pop ax
.u_nc:
        mov byte [w_n], 1
        push ax
        mov si, j_quo
        call b_str
        pop ax
        mov cx, 8                       ; account-name limit; never +10 password
        call b_name
        mov si, j_quo
        call b_str
        inc bx
        cmp bx, 16
        jb .u_l
.u_ldone:
        mov si, j_w3
        call b_str
        call finish
        jmp .out

.ps:
        mov word [b_ptr], 0
        ; task-table offsets live in KERNEL_SEG
        mov ah, 33
        int 0x60
        mov [ps_state], ax
        mov [ps_term], bx
        mov [ps_app], cx
        mov [ps_seg], dx
        ; count of active tasks
        mov si, j_ps
        call b_str
        mov ah, 22
        int 0x60
        call b_num
        ; services (same bitfield as /api/status)
        mov si, j_ps_svc
        call b_str
        mov ah, 29
        int 0x60
        mov [st_fl], ax
        mov cl, 0
        call st_bit
        mov si, j_ps_weblog
        call b_str
        mov cl, 1
        call st_bit
        mov si, j_ps_slip
        call b_str
        mov cl, 2
        call st_bit
        mov si, j_ps_mux
        call b_str
        mov cl, 3
        call st_bit
        mov si, j_ps_tftp
        call b_str
        mov cl, 4
        call st_bit
        mov si, j_ps_priv
        call b_str
        mov cl, 5
        call st_bit
        mov si, j_ps_tasks
        call b_str
        ; walk all slots; emit the active ones.
        ; NOTE: b_str/b_num write through ES:DI, and ES is CS here.  The task
        ; tables live in KERNEL_SEG, so read them with the k_byte/k_word
        ; accessors (they temporarily borrow ES and restore it).
        mov byte [w_n], 0
        xor bx, bx
.psx_loop:
        cmp bx, 13
        jae .psx_done
        mov si, bx
        add si, [ps_state]
        call k_byte
        test al, al
        jz .psx_next
        cmp byte [w_n], 0
        je .psx_nosep
        mov si, j_cma
        call b_str
.psx_nosep:
        mov byte [w_n], 1
        ; {"slot":N
        mov si, j_task_o
        call b_str
        mov ax, bx
        call b_num
        ; ,"name":"..."
        mov si, j_task_nm
        call b_str
        mov al, bl
        mov ah, 25
        int 0x60
        jc .psx_noname
        mov cx, 12
        call b_name
.psx_noname:
        ; ","app":"..."
        mov si, j_task_app
        call b_str
        mov si, bx
        add si, [ps_app]
        call k_byte
        cmp bx, 11
        jb .psx_am
        mov si, s_app_pgm
        jmp .psx_ap
.psx_am:
        cmp al, 1
        jne .psx_a2
        mov si, s_app_ser
        jmp .psx_ap
.psx_a2:
        cmp al, 2
        jne .psx_a3
        mov si, s_app_web
        jmp .psx_ap
.psx_a3:
        cmp al, 3
        jne .psx_a0
        mov si, s_app_up
        jmp .psx_ap
.psx_a0:
        mov si, s_app_cons
.psx_ap:
        call b_str
        ; ","term":N
        mov si, j_task_term
        call b_str
        mov si, bx
        add si, [ps_term]
        call k_byte
        xor ah, ah
        call b_num
        ; ,"state":"ready"
        mov si, j_task_state
        call b_str
        ; ,"seg":"XXXX"
        mov si, j_task_seg
        call b_str
        mov si, bx
        shl si, 1
        add si, [ps_seg]
        call k_word
        call b_hex
        mov si, j_quo
        call b_str
        ; ,"user":"..."
        mov si, j_task_user
        call b_str
        mov ax, bx
        test ax, ax
        jz .psx_console
        mov al, bl
        mov ah, 24
        int 0x60
        jc .psx_ue
        mov cx, 12
        call b_name
        jmp .psx_ue
.psx_console:
        mov si, s_ps_console
        call b_str
.psx_ue:
        mov si, j_quo
        call b_str
        mov si, j_task_end
        call b_str
.psx_next:
        inc bx
        jmp .psx_loop
.psx_done:
        mov si, j_w3
        call b_str
        call finish
        jmp .out

.whoami:
        mov word [b_ptr], 0
        mov si, j_usr
        call b_str
        xor al, al
        mov ah, 24
        int 0x60
        jc .wm_none
        mov cx, 16
        call b_name
.wm_none:
        mov si, j_quo
        call b_str
        mov si, j_end
        call b_str
        call finish
        jmp .out

.mem:
        mov word [b_ptr], 0
        mov si, j_mem
        call b_str
        call finish
        jmp .out

.out:
        dec byte [job_busy]
        pop ds
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        retf
