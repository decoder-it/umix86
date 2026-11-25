; =====================================================================
; CHAT.SYS - UMIX/86 chat overlay
; Loaded at segment 0x2900 (the 28 KB gap between UMIX.SYS at 0x2000
; and the task code segment at 0x3000).
;
; Stage 1: entry stub only.  The chat implementation still lives in the
; kernel; this file exists so the load path and segment are proven before
; any code moves.
; =====================================================================
        cpu 8086
        bits 16
        org 0

chat_entry:
        retf
