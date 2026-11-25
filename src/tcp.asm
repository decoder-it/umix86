; =====================================================================
; TCP.SYS - minimal TCP server + HTTP/1.0 for UMIX/86
;
; Loaded at 0x2900, entry at offset 0.  The kernel provides:
;   INT 60h AH=19  send IP packet: ES:SI = packet, CX = length
;   INT 60h AH=4   load file: ES:SI = 11-byte 8.3 name, ES:BX = dest,
;                  CX = max -> DX = size, CF on error
;   INT 60h AH=9   ticks
; Mailbox at 0x2000: flag(1), length(2), IP packet (the kernel fills it).
;
; One connection at a time, server port 80, MSS 200, stop-and-wait.
; =====================================================================
        bits 16
        cpu 8086
        org 0

MBOX    equ 0x2000
LOG     equ 0x1F00
LOGFLAG equ 0x1FFE
MB_DATA equ 0x2003
RXBUF   equ 0x2100
TXBUF   equ 0x2200
REQBUF  equ 0x2300
BODYBUF equ 0x2400               ; 8 KB file body
RESPBUF equ 0x4800               ; ~9 KB response (header + body)
MSS     equ 200
WINDOW  equ 600                 ; bytes allowed in flight (3 segments)

tcp_entry:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push ds
        push es
        mov ax, cs
        mov ds, ax
        mov es, ax
        cld
        ; announce this build once, on the first tick after TCP ON
        cmp byte [msg_done], 0
        jne .announced
        mov byte [msg_done], 1
        mov si, s_tcpver
        mov ah, 1
        int 0x60
.announced:
        cmp byte [pend_ok], 0
        je .nopend
        cmp byte [state], 0
        jne .nopend
        mov byte [pend_ok], 0
        mov si, pend_syn
        mov di, RXBUF
        mov cx, 40
        rep movsb
        mov word [rx_len], 40
        call tcp_input
.nopend:
        cmp byte [MBOX], 0
        je .norx
        mov byte [MBOX], 0
        mov ax, [MBOX+1]
        mov [rx_len], ax
        test ax, ax
        jz .norx
        mov cx, ax
        mov si, MB_DATA
        mov di, RXBUF
        rep movsb
        call tcp_input
.norx:
        call tcp_timer
        pop es
        pop ds
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        retf

; ---------------------------------------------------------------------
tcp_input:
        cmp word [rx_len], 40
        jb .out
        ; IP fragment (MF set or offset != 0): there is no reassembly here, so
        ; a fragment is never a whole segment.  Treating the first fragment as
        ; one made the server ACK 204 bytes it had not received.
        test byte [RXBUF+6], 0x3F
        jnz .out
        mov ax, [RXBUF+22]              ; dest port (wire)
        xchg al, ah
        cmp ax, 80
        jne .out
        mov al, [RXBUF+33]
        mov [in_flags], al
        mov ax, [rx_len]
        sub ax, 20
        mov [tcplen], ax
        test byte [in_flags], 0x04      ; RST: only the owning peer may close
        jnz .rst
        test byte [in_flags], 0x02      ; SYN: reset only if idle/stale/other peer
        jz .not_syn
        jmp .syn
.rst:
        ; Chrome closes abandoned preconnect sockets with RST.  Without the
        ; peer check that wiped whatever connection was being served.
        cmp byte [state], 0
        je .out
        mov ax, [RXBUF+12]
        cmp ax, [peer_ip]
        jne .out
        mov ax, [RXBUF+14]
        cmp ax, [peer_ip+2]
        jne .out
        mov ax, [RXBUF+20]
        cmp ax, [peer_port]
        jne .out
        mov al, 'R'
        call log_reset
        jmp reset
.not_syn:
        cmp byte [state], 0
        je .listen
        cmp byte [state], 1
        je .synrcvd
        cmp byte [state], 2
        je .est
        cmp byte [state], 3
        jne .out
        test byte [in_flags], 0x01      ; TIME_WAIT: peer FIN really closes it
        jz .out
        jmp .finnew
.syn:
        cmp byte [state], 0
        je .listen
        ; same 4-tuple: re-handshake (client lost the SYN-ACK/ACK)
        mov ax, [RXBUF+12]
        cmp ax, [peer_ip]
        jne .syn_other
        mov ax, [RXBUF+14]
        cmp ax, [peer_ip+2]
        jne .syn_other
        mov ax, [RXBUF+20]
        cmp ax, [peer_port]
        jne .syn_other
        ; same socket: re-handshake while the handshake is unfinished or the
        ; peer is stale - a late SYN retransmit must not wipe a live page
        cmp byte [state], 1
        je .listen
        call now_ticks
        sub ax, [last_rx]
        cmp ax, 50
        jae .listen
        ; busy: keep this SYN in a one-slot backlog so it is answered the
        ; moment the current connection ends (no wait for its RTO)
        mov si, RXBUF
        mov di, pend_syn
        mov cx, 40
        rep movsb
        mov byte [pend_ok], 1
        jmp .out
.syn_other:
        cmp byte [state], 3            ; TIME_WAIT: old connection is done
        je .listen
        ; A browser opens ~6 sockets; only one carries the GET.  A TCB that
        ; has not seen a request yet is disposable - hand it to the new SYN
        ; immediately (this is what made browsers work).  Once a request is
        ; being served, keep it until the peer has been silent for ~3 s.
        cmp byte [req_done], 0
        je .listen
        call now_ticks
        sub ax, [last_rx]
        cmp byte [last_pending], 0
        je .syn_idle
        cmp ax, 300                    ; data unacknowledged: be very patient
        jae .listen
        jmp .syn_busy
.syn_idle:
        cmp ax, 50
        jae .listen
.syn_busy:
        ; busy: keep this SYN in a one-slot backlog so it is answered the
        ; moment the current connection ends (no wait for its RTO)
        mov si, RXBUF
        mov di, pend_syn
        mov cx, 40
        rep movsb
        mov byte [pend_ok], 1
        jmp .out

.listen:
        test byte [in_flags], 0x02
        jz .out
        cmp byte [state], 0
        je .no_steal
        mov al, 'S'
        call log_reset
.no_steal:
        call reset
        mov ax, [RXBUF+12]
        mov [peer_ip], ax
        mov ax, [RXBUF+14]
        mov [peer_ip+2], ax
        mov ax, [RXBUF+20]
        mov [peer_port], ax
        mov ax, [RXBUF+24]
        xchg al, ah
        mov [cli_hi], ax
        mov ax, [RXBUF+26]
        xchg al, ah
        mov [cli_lo], ax
        mov word [snd_nxt], 0
        mov word [req_len], 0
        mov word [resp_len], 0
        mov word [resp_off], 0
        mov byte [last_pending], 0
        inc word [cli_lo]               ; ACK the client's SYN
        jnc .syn_inc
        inc word [cli_hi]
.syn_inc:
        call send_synack                ; seq 0, ack cli+1, MSS
        call now_ticks
        mov [last_rx], ax
        mov byte [state], 1
        jmp .out
.finnew:
        ; only the peer that owns the TCB may close it: browsers hold several
        ; sockets (favicon, preconnect) and a stray FIN from one of them must
        ; not abort the page the real connection is still receiving
        cmp byte [state], 0
        je .out
        mov ax, [RXBUF+12]
        cmp ax, [peer_ip]
        jne .out
        mov ax, [RXBUF+14]
        cmp ax, [peer_ip+2]
        jne .out
        mov ax, [RXBUF+20]
        cmp ax, [peer_port]
        jne .out
        inc word [cli_lo]
        jnc .fin1
        inc word [cli_hi]
.fin1:
        call send_ack
        mov al, 'F'
        call log_reset
        jmp reset

.synrcvd:
        test byte [in_flags], 0x10
        jz .out
        mov ax, [RXBUF+30]
        xchg al, ah
        cmp ax, [snd_nxt]
        jne .out
        mov byte [state], 2
        mov byte [last_pending], 0
        call now_ticks
        mov [last_rx], ax
        jmp .datachk                    ; the same segment may carry the GET
.est:
        call now_ticks
        mov [last_rx], ax
        test byte [in_flags], 0x10
        jz .datachk
        mov ax, [RXBUF+30]
        xchg al, ah
        mov [acktmp], ax
        cmp byte [LOGFLAG], 0
        je .no_acklog
        call log_ack
.no_acklog:
        mov ax, [acktmp]
        cmp byte [last_pending], 0
        je .datachk
        test byte [last_flags], 0x01
        jz .dataack
        ; FIN outstanding: its ACK closes our side
        cmp ax, [snd_nxt]
        jne .datachk
        mov byte [last_pending], 0
        mov byte [state], 3
        call now_ticks
        mov [last_tick], ax
        jmp .datachk
.dataack:
        ; cumulative: the ACK is the first byte the peer does not have yet
        dec ax                          ; -> bytes acknowledged
        cmp ax, [resp_off]
        jbe .datachk                    ; stale / duplicate: never resend here
        cmp ax, [resp_len]
        jbe .setoff
        mov ax, [resp_len]
.setoff:
        mov [resp_off], ax
        mov byte [stall_done], 0
        mov byte [retries], 0
        call now_ticks
        mov [last_tick], ax
        call send_next                  ; top the window up
        jmp .datachk
.datachk:
        ; payload length = rx_len - 20 - data_offset
        mov al, [RXBUF+32]
        mov cl, 4
        shr al, cl
        xor ah, ah
        shl ax, 1
        shl ax, 1
        mov bp, ax                      ; data offset bytes
        mov bx, [rx_len]
        sub bx, 20
        sub bx, bp
        jbe .finonly
        ; accept only seq == cli_seq (retransmits are re-ACKed, not re-appended)
        mov ax, [RXBUF+24]
        xchg al, ah
        cmp ax, [cli_hi]
        jne .seqbad
        mov ax, [RXBUF+26]
        xchg al, ah
        cmp ax, [cli_lo]
        jne .seqbad
        ; Copy what fits into the 220-byte parse buffer, but always advance the
        ; client's sequence past the WHOLE segment.  A browser request can be
        ; 500+ bytes (cookies); if the tail is never acknowledged the client
        ; retransmits it forever and the page never completes.
        mov dx, bx                      ; dx = full payload length
        mov ax, [req_len]
        cmp ax, 219
        jae .advance                    ; parse buffer full, nothing to copy
        mov cx, 220
        sub cx, ax
        cmp cx, dx
        jbe .cpfill
        mov cx, dx
.cpfill:
        mov si, RXBUF+20
        add si, bp
        mov di, REQBUF
        add di, ax
        add [req_len], cx
        rep movsb
.advance:
        add [cli_lo], dx
        jnc .noinc
        inc word [cli_hi]
.noinc:
        call send_ack
        cmp byte [req_done], 0
        jne .finchk
        cmp byte [req_len], 5
        jb .finchk
        cmp byte [REQBUF], 'G'
        jne .finchk
        cmp byte [REQBUF+1], 'E'
        jne .finchk
        cmp byte [REQBUF+2], 'T'
        jne .finchk
        mov byte [req_done], 1
        cmp byte [LOGFLAG], 0
        je .nolog
        call log_request
.nolog:
        call build_response
        call send_next
        jmp .finchk
.finonly:
        ; FIN without payload: it is only valid at the current sequence
        test byte [in_flags], 0x01
        jz .out
        mov ax, [RXBUF+24]
        xchg al, ah
        cmp ax, [cli_hi]
        jne .out
        mov ax, [RXBUF+26]
        xchg al, ah
        cmp ax, [cli_lo]
        jne .out
        jmp .fconsume
.finchk:
        ; A browser may close its side right after the request (FIN on the
        ; last data segment).  The data above is already consumed, so ACK the
        ; FIN by consuming its sequence number - but keep the TCB alive until
        ; the response has been sent, otherwise the page dies half way.
        test byte [in_flags], 0x01
        jz .out
.fconsume:
        inc word [cli_lo]
        jnc .fack
        inc word [cli_hi]
.fack:
        call send_ack
        mov ax, [resp_off]
        cmp ax, [resp_len]
        jb .out
        mov al, 'F'
        call log_reset
        jmp reset
.seqbad:
        call send_ack
        jmp .out
.out:   ret

; ---------------------------------------------------------------------
send_next:
.sl:
        mov ax, [snd_nxt]
        dec ax                          ; offset of the next byte to send
        cmp ax, [resp_len]
        jb .more
        ; all bytes queued: send FIN once they are all acknowledged
        mov ax, [resp_off]
        cmp ax, [resp_len]
        jb .out
        test byte [last_pending], 0xFF
        jz .fin
        test byte [last_flags], 0x01
        jnz .out                        ; FIN already in flight
.fin:
        jmp send_fin
.more:
        mov cx, ax
        sub cx, [resp_off]
        cmp cx, WINDOW                  ; in-flight bytes
        jae .out
        mov cx, [resp_len]
        sub cx, ax
        cmp cx, MSS
        jbe .len
        mov cx, MSS
.len:
        mov si, RESPBUF
        add si, ax
        call send_data
        jmp .sl
.out:   ret

send_synack:
        mov byte [seg_flags], 0x12
        mov word [seg_len], 0
        mov byte [seg_mss], 1
        mov byte [seg_ctrl], 0
        jmp send_segment

send_ack:
        mov byte [seg_flags], 0x10
        mov word [seg_len], 0
        mov byte [seg_mss], 0
        mov byte [seg_ctrl], 1
        call send_segment
        mov byte [seg_ctrl], 0
        ret

send_data:                              ; SI = payload, CX = length
        mov [seg_ptr], si
        mov [seg_len], cx
        mov byte [seg_flags], 0x18
        mov byte [seg_mss], 0
        mov byte [seg_ctrl], 0
        jmp send_segment

send_fin:
        mov byte [seg_flags], 0x11
        mov word [seg_len], 0
        mov byte [seg_mss], 0
        mov byte [seg_ctrl], 0
        call send_segment
        ret

; ---------------------------------------------------------------------
send_segment:
        mov di, TXBUF
        ; IP header
        mov byte [di], 0x45
        mov byte [di+1], 0
        mov ax, 20+20
        add ax, [seg_len]
        cmp byte [seg_mss], 0
        je .nomss
        add ax, 4
.nomss:
        mov [segtotal], ax
        mov ax, [segtotal]
        xchg al, ah
        mov [di+2], al
        mov [di+3], ah
        xor ax, ax
        mov [di+4], ax
        mov [di+6], ax
        mov byte [di+8], 64
        mov byte [di+9], 6
        mov [di+10], ax
        mov byte [di+12], 192
        mov byte [di+13], 168
        mov byte [di+14], 99
        mov byte [di+15], 1
        mov ax, [peer_ip]
        mov [di+16], ax
        mov ax, [peer_ip+2]
        mov [di+18], ax
        xor bx, bx
        mov si, TXBUF
        mov cx, 20
        call sum_words
        mov ax, bx
        not ax
        mov [di+10], ah
        mov [di+11], al
        ; TCP header
        mov di, TXBUF+20
        mov byte [di], 0                ; source port 80 (big-endian)
        mov byte [di+1], 80
        mov ax, [peer_port]
        mov [di+2], ax
        mov byte [di+4], 0
        mov byte [di+5], 0
        mov byte [di+6], 0
        mov al, [snd_nxt+1]
        mov [di+6], al
        mov al, [snd_nxt]
        mov [di+7], al
        mov al, [cli_hi+1]
        mov [di+8], al
        mov al, [cli_hi]
        mov [di+9], al
        mov al, [cli_lo+1]
        mov [di+10], al
        mov al, [cli_lo]
        mov [di+11], al
        mov al, 5
        cmp byte [seg_mss], 0
        je .do5
        mov al, 6
.do5:
        mov cl, 4
        shl al, cl
        mov [di+12], al
        mov al, [seg_flags]
        mov [di+13], al
        mov byte [di+14], 0x10
        mov byte [di+15], 0
        mov word [di+16], 0
        mov word [di+18], 0
        mov byte [di+20], 2
        mov byte [di+21], 4
        mov byte [di+22], 0
        mov byte [di+23], MSS
        ; payload
        cmp word [seg_len], 0
        je .nopay
        mov si, [seg_ptr]
        mov di, TXBUF+20
        add di, 20
        cmp byte [seg_mss], 0
        je .noms2
        add di, 4
.noms2:
        mov cx, [seg_len]
        rep movsb
.nopay:
        ; TCP checksum
        mov ax, [segtotal]
        sub ax, 20
        mov [tcplen], ax
        xor bx, bx
        add bx, 0xC0A8
        adc bx, 0
        add bx, 0x6301
        adc bx, 0
        mov ax, [peer_ip]
        xchg al, ah
        add bx, ax
        adc bx, 0
        mov ax, [peer_ip+2]
        xchg al, ah
        add bx, ax
        adc bx, 0
        add bx, 6
        adc bx, 0
        mov ax, [tcplen]
        add bx, ax
        adc bx, 0
        mov si, TXBUF+20
        mov cx, [tcplen]
        call sum_words
        mov ax, bx
        not ax
        mov [TXBUF+36], ah
        mov [TXBUF+37], al
        ; send
        call send_raw
        ; state
        cmp byte [seg_ctrl], 0
        jne .done
        mov word [last_len], 0
        mov al, [seg_flags]
        test al, 0x01
        jz .nosyn
        inc word [snd_nxt]
        jmp .store
.nosyn:
        test al, 0x02
        jz .nodata
        inc word [snd_nxt]
        jmp .store
.nodata:
        mov ax, [seg_len]
        add [snd_nxt], ax
        mov [last_len], ax
.store:
        mov al, [seg_flags]
        mov [last_flags], al
        mov byte [last_pending], 1
        call now_ticks
        mov [last_tick], ax
        mov byte [retries], 0
        mov ax, [segtotal]
        mov [last_total], ax
.done:
        ret

send_raw:
        mov ax, [segtotal]
        mov cx, ax
        mov si, TXBUF
        mov ax, cs
        mov es, ax
        mov ah, 19
        int 0x60
        ret

; ---------------------------------------------------------------------
build_response:
        mov ax, cs
        mov es, ax
        call is_ico
        jnc .notico
        ; favicon and friends: answer with a 66-byte 404, never touch the disk
        mov si, s_ico404
        mov di, RESPBUF
        call copy_str
        mov ax, di
        sub ax, RESPBUF
        mov [resp_len], ax
        mov word [resp_off], 0
        ret
.notico:
        mov si, s_ok
        cmp byte [REQBUF+4], '/'
        jne .bad
        mov al, [REQBUF+5]
        cmp al, ' '
        je .good
        cmp al, '?'
        je .good
        cmp al, 13
        jne .bad
.good:
        mov si, s_indexname
        jmp .load
.bad:
        mov si, s_404name
.load:
        mov bx, BODYBUF
        mov cx, 8900
        mov ax, cs
        mov es, ax
        mov ah, 4
        int 0x60
        jc .def
        mov [body_len], dx
        jmp .build
.def:
        mov ax, cs
        mov es, ax
        mov si, s_default
        mov di, BODYBUF
        xor cx, cx
.dl:
        lodsb
        test al, al
        jz .dd
        stosb
        inc cx
        jmp .dl
.dd:
        mov [body_len], cx
.build:
        mov ax, cs
        mov es, ax
        mov di, RESPBUF
        cmp byte [REQBUF+4], '/'
        jne .b404
        mov al, [REQBUF+5]
        cmp al, ' '
        je .b200
        cmp al, '?'
        je .b200
.b404:
        mov si, s_404hdr
        jmp .bh
.b200:
        mov si, s_okhdr
.bh:
        call copy_str
        mov ax, [body_len]
        call append_dec
        mov si, s_hdrend
        call copy_str
        mov si, BODYBUF
        mov cx, [body_len]
        rep movsb
        mov ax, di
        sub ax, RESPBUF
        mov [resp_len], ax
        mov word [resp_off], 0
        ret

log_reset:                             ; AL = reason code, prints on the panel
        push ax
        mov [s_reset+10], al
        mov si, s_reset
        mov ah, 1
        int 0x60
        pop ax
        ret

copy_str:
        lodsb
        test al, al
        jz .d
        stosb
        jmp copy_str
.d:     ret

is_ico:                                ; CF=1 when the request line has ".ico"
        push ax
        push cx
        push si
        mov cx, [req_len]
        sub cx, 4
        jbe .no
        mov si, REQBUF
.l:
        cmp byte [si], 13               ; only the request line, not headers
        je .no
        cmp byte [si], 10
        je .no
        cmp byte [si], '.'
        jne .nx
        mov al, [si+1]
        or al, 0x20
        cmp al, 'i'
        jne .nx
        mov al, [si+2]
        or al, 0x20
        cmp al, 'c'
        jne .nx
        mov al, [si+3]
        or al, 0x20
        cmp al, 'o'
        jne .nx
        stc
        jmp .d
.nx:
        inc si
        dec cx
        jnz .l
.no:    clc
.d:     pop si
        pop cx
        pop ax
        ret

append_dec:                            ; AX -> DI
        push ax
        push bx
        push cx
        push dx
        mov bx, 10
        xor cx, cx
.adl:
        xor dx, dx
        div bx
        push dx
        inc cx
        test ax, ax
        jnz .adl
.adp:
        pop ax
        add al, '0'
        stosb
        loop .adp
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---------------------------------------------------------------------
log_request:                            ; TCP <ip>:<port> <request line>
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push es
        mov ax, cs
        mov es, ax
        cld
        mov di, LOG
        mov si, s_logprefix
        call copy_str
        mov si, peer_ip
        mov cx, 4
.lip:
        mov al, [si]
        xor ah, ah
        call append_dec
        inc si
        dec cx
        jz .lport
        mov al, '.'
        stosb
        jmp .lip
.lport:
        mov al, ':'
        stosb
        mov ax, [peer_port]
        xchg al, ah
        call append_dec
        mov al, ' '
        stosb
        mov si, REQBUF
        mov cx, 48
.lreq:
        lodsb
        test al, al
        jz .lend
        cmp al, 13
        je .lend
        cmp al, 10
        je .lend
        stosb
        loop .lreq
.lend:
        mov al, 13
        stosb
        mov al, 10
        stosb
        xor al, al
        stosb
        mov si, LOG
        mov ah, 1
        int 0x60
        pop es
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret

; ---------------------------------------------------------------------
tcp_timer:
        cmp byte [state], 0
        je .ret
        cmp byte [state], 3
        jne .pend
        call now_ticks
        sub ax, [last_tick]
        cmp ax, 50
        jb .ret
        jmp reset
.pend:
        cmp byte [last_pending], 0
        jne .pend_wait
        call stall_probe
        ret
.pend_wait:
        call now_ticks
        sub ax, [last_tick]
        cmp ax, 100
        jb .ret
        inc byte [retries]
        cmp byte [retries], 5
        jbe .retry
        mov al, 'T'
        call log_reset
        jmp reset
.retry:
        mov al, 'r'
        call log_reset
        call now_ticks
        mov [last_tick], ax
        test byte [last_flags], 0x01
        jnz .refin
        ; go back to the first unacknowledged byte and refill the window
        mov ax, [resp_off]
        inc ax
        mov [snd_nxt], ax
        call send_next
        ret
.refin:
        mov ax, [last_total]
        mov cx, ax
        mov si, TXBUF
        mov ax, cs
        mov es, ax
        mov ah, 19
        int 0x60
.ret:   ret

reset:
        mov byte [stall_done], 0
        mov byte [state], 0
        mov byte [req_done], 0
        mov byte [last_pending], 0
        mov word [req_len], 0
        mov word [resp_len], 0
        mov word [resp_off], 0
        ret

log_ack:                               ; AX already stored in acktmp
        push ax
        push di
        push si
        mov di, LOG
        mov si, s_ack
        call copy_str
        mov ax, [acktmp]
        dec ax
        call append_dec
        mov si, s_off
        call copy_str
        mov ax, [resp_off]
        call append_dec
        mov al, 13
        stosb
        mov al, 10
        stosb
        mov byte [di], 0
        mov si, LOG
        mov ah, 1
        int 0x60
        pop si
        pop di
        pop ax
        ret

stall_probe:
        cmp byte [stall_done], 0
        jne .sp_out
        mov ax, [snd_nxt]
        dec ax
        cmp ax, [resp_len]             ; everything already sent?
        jae .sp_out
        cmp word [resp_len], 0
        je .sp_out
        mov byte [stall_done], 1
        mov di, LOG
        mov si, s_stall
        call copy_str
        mov ax, [snd_nxt]
        dec ax
        call append_dec
        mov al, '/'
        stosb
        mov ax, [resp_len]
        call append_dec
        mov al, ' '
        stosb
        mov ax, [resp_off]
        call append_dec
        mov al, 13
        stosb
        mov al, 10
        stosb
        mov byte [di], 0
        mov si, LOG
        mov ah, 1
        int 0x60
.sp_out:
        ret

now_ticks:
        push bx
        push cx
        push dx
        mov ah, 9
        int 0x60
        pop dx
        pop cx
        pop bx
        ret

; ---------------------------------------------------------------------
sum_words:                             ; SI buf, CX len, BX accumulator
.swl:
        cmp cx, 2
        jb .odd
        mov ax, [si]
        xchg al, ah
        add bx, ax
        adc bx, 0
        add si, 2
        sub cx, 2
        jmp .swl
.odd:
        test cx, cx
        jz .swd
        xor ax, ax
        mov al, [si]
        mov ah, al
        xor al, al
        add bx, ax
        adc bx, 0
.swd:   ret

; ---------------------------------------------------------------------
s_ok:           db 0                       ; unused selector
s_okhdr:        db 'HTTP/1.0 200 OK',13,10,'Content-Type: text/html',13,10,'Content-Length: ',0
s_404hdr:       db 'HTTP/1.0 404 Not Found',13,10,'Content-Type: text/html',13,10,'Content-Length: ',0
s_hdrend:       db 13,10,'Connection: close',13,10,13,10,0
s_indexname:    db 'INDEX   HTM'
s_404name:      db '404     HTM'
s_ico404:       db 'HTTP/1.0 404 Not Found',13,10,'Content-Length: 0',13,10,'Connection: close',13,10,13,10,0
s_default:      db '<html><body><h1>UMIX/86 TCP</h1></body></html>',0
s_logprefix:    db 'TCP ',0
s_tcpver:       db 'TCP.SYS V0R138 - HTTP SERVER ON :80',13,10,0
s_reset:        db 'TCP RESET ?',13,10,0
s_stall:        db 'TCP STALL ',0
s_ack:          db 'TCP ACK ',0
s_off:          db ' off ',0

state           db 0
in_flags        db 0
peer_ip         times 4 db 0
peer_port       dw 0
cli_lo          dw 0
cli_hi          dw 0
snd_nxt         dw 0
rx_len          dw 0
tcplen          dw 0
req_len         dw 0
resp_len        dw 0
resp_off        dw 0
body_len        dw 0
last_len        dw 0
last_flags      db 0
last_pending    db 0
last_total      dw 0
last_tick       dw 0
last_rx         dw 0
pend_ok         db 0
pend_syn        times 40 db 0
stall_done      db 0
acktmp          dw 0
retries         db 0
segtotal        dw 0
seg_len         dw 0
seg_ptr         dw 0
seg_flags       db 0
seg_mss         db 0
seg_ctrl        db 0
req_done        db 0
msg_done        db 0
