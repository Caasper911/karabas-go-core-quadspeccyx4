; .RNDTAP <dir> - load and run a random *.TAP of a directory (ESXDOS 0.8.x dot command).
;
; Counts the *.TAP files of <dir>, takes a random one (FRAMES and R), inserts it with the
; ESXDOS command "tapein <dir>/<file>" (M_EXECCMD, from a stub on the machine stack: TAPEIN
; takes the dot command area 2000h-3FFFh) and then runs LOAD "" as if typed: the stub puts
; LOAD "" into E_LINE and leaves ESXDOS the way its error exit does (SP from ERR_SP, #E3 back,
; jp (hl) at 1FFBh pages DivMMC out) into MAIN-3 (12CFh) of the 48 BASIC ROM. In 128 BASIC
; it pages that ROM in (unless the paging is locked): the tape runs in 48 BASIC.
;
; Build: sjasmplus rndtap.asm (writes RNDTAP). Copy it to /BIN of the SD card.

                device  zxspectrum48

                define  CMDWORD "tapein "
EXT1            equ     't'
EXT2            equ     'a'
EXT3            equ     'p'

ERR_SP          equ     5C3Dh
FLAGS           equ     5C3Bh
E_LINE          equ     5C59h
WORKSP          equ     5C61h
STKBOT          equ     5C63h
STKEND          equ     5C65h
BANKM           equ     5B5Ch
ESX_E3          equ     3DF8h           ; #E3 of the caller (the ESXDOS exit writes it back)
MAIN_3          equ     12CFh           ; the 48 BASIC main loop: run E_LINE
ESX_JPHL        equ     1FFBh           ; jp (hl) in the DivMMC off area of ESXDOS 0.8.9

                org     2000h

                include "rndsel.inc"

; the stub (relocatable: copied and run in main RAM)
stub:
st_ix:          ld      ix,0            ; from main RAM rst 08h takes IX
st_hl:          ld      hl,0
                rst     08h
                db      M_EXECCMD       ; tapein <dir>/<file>
st_sp:          ld      sp,0            ; flags and A (the error) stay
                ret     c               ; no tape: the error to BASIC
                di
                ld      iy,5C3Ah
                ld      hl,(E_LINE)     ; E_LINE = LOAD "" (the current line is done with)
                ld      (hl),0EFh       ; LOAD
                inc     hl
                ld      (hl),'"'
                inc     hl
                ld      (hl),'"'
                inc     hl
                ld      (hl),0Dh
                inc     hl
                ld      (hl),80h
                inc     hl
                ld      (WORKSP),hl
                ld      (STKBOT),hl
                ld      (STKEND),hl
                ld      hl,(ERR_SP)     ; the level of the main loop: LINE-RUN returns
                inc     hl              ; through (ERR_SP) to MAIN-4
                inc     hl
                ld      sp,hl
                res     4,(iy + 1)      ; FLAGS: 48 BASIC
                ld      a,(BANKM)
                bit     5,a
                jr      nz,.lk          ; locked (48 mode)
                or      10h             ; ROM 1 (48 BASIC)
                ld      (BANKM),a
                ld      bc,7FFDh
                out     (c),a
.lk:            ld      a,(ESX_E3)
                out     (0E3h),a
                ld      hl,MAIN_3
                ei
                jp      ESX_JPHL
stub_len        equ     $ - stub

msg_use:        db      ".RNDTAP <dir>", 13
                db      "loads a random *.TAP of <dir>", 13, 0
msg_none:       db      "No .TAP file", 's' + 80h

                savebin "RNDTAP", start, $ - start
