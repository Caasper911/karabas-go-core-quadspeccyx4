; .RNDTRD <dir> - run a random *.TRD of a directory (ESXDOS 0.8.x dot command, TR-DOS emulation).
;
; Counts the *.TRD files of <dir>, takes a random one (FRAMES and R), mounts it as drive A of the
; ESXDOS TR-DOS emulator (BETADISK.SYS) with the ESXDOS command "vdisk 0 <dir>/<file>" (M_EXECCMD,
; from a stub on the machine stack: VDISK takes the dot command area 2000h-3FFFh) and then runs
;       10 RANDOMIZE USR 15619: REM : RUN
; as a program: after VDISK the stub puts this line in place of the BASIC program (the variables
; and E_LINE go), sets NEWPPC = 10, NSPPC = 0 (a GO TO after this statement) and returns to
; ESXDOS as any dot command. TR-DOS runs the command after REM : only when the emulation was
; left in order: going out of ESXDOS the way .RNDTAP does left 15619 doing nothing ("0 OK, 0:1")
; or failing with "Disc Error". RUN without a name runs "boot" (/SYS/TRDBOOT.BIN with
; AlwaysBoot=1 in TRDOS.CFG when the disk has none). Needs the SYS files of the ESXDOS 0.8.9
; distribution (others reset the machine in a loop at boot). Checked in ZEsarUX (Pentagon,
; DivMMC, src/roms/esxdos089.bin): from AUTOBOOT.BAS and typed in 48 BASIC.
;
; Build: sjasmplus rndtrd.asm (writes RNDTRD). Copy it to /BIN of the SD card.

                device  zxspectrum48

                define  CMDWORD "vdisk 0 "
EXT1            equ     't'
EXT2            equ     'r'
EXT3            equ     'd'

E_LINE          equ     5C59h
K_CUR           equ     5C5Bh
NEWPPC          equ     5C42h
NSPPC           equ     5C44h
WORKSP          equ     5C61h
STKBOT          equ     5C63h
STKEND          equ     5C65h
TRDOS_CMD       equ     15619           ; 3D03h: a TR-DOS command from BASIC (after REM :)
PROG            equ     5C53h
VARS            equ     5C4Bh

                org     2000h

                include "rndsel.inc"

; the stub (relocatable: copied and run in main RAM)
stub:
st_ix:          ld      ix,0            ; from main RAM rst 08h takes IX
st_hl:          ld      hl,0
                rst     08h
                db      M_EXECCMD       ; vdisk 0 <dir>/<file>
st_sp:          ld      sp,0            ; flags and A (the error) stay
                ret     c               ; not mounted: the error to BASIC
; the program becomes the line, the variables and E_LINE go, GO TO 10 after this statement
; (STMT-RET looks at NSPPC); back to BASIC through ESXDOS as any dot command (leaving it any
; other way, as .RNDTAP does, leaves the TR-DOS emulation broken: 15619 returns at once, or
; "Disc Error")
                call    .here
.here:          pop     hl
                ld      bc,line - .here
                add     hl,bc
                ld      de,(PROG)
                ld      bc,line_len
                ldir
                ld      (VARS),de
                ex      de,hl
                ld      (hl),80h        ; no variables
                inc     hl
                ld      (E_LINE),hl     ; an empty E_LINE
                ld      (K_CUR),hl
                ld      (hl),0Dh
                inc     hl
                ld      (hl),80h
                inc     hl
                ld      (WORKSP),hl
                ld      (STKBOT),hl
                ld      (STKEND),hl
                ld      hl,10
                ld      (NEWPPC),hl
                xor     a               ; nc: no error
                ld      (NSPPC),a
                ret
; 10 RANDOMIZE USR 15619: REM : RUN, tokenized, the number with its hidden form. RUN without a
; name runs "boot" (or /SYS/TRDBOOT.BIN with AlwaysBoot=1 in TRDOS.CFG when the disk has none).
line:           db      0, 10
                dw      line_end - line - 4
                db      0F9h, 0C0h, "15619", 0Eh, 0, 0, low TRDOS_CMD, high TRDOS_CMD, 0
                db      ':', 0EAh, ':', 0F7h, 0Dh
line_end:
line_len        equ     $ - line
stub_len        equ     $ - stub

msg_use:        db      ".RNDTRD <dir>", 13
                db      "runs a random *.TRD of <dir>", 13
                db      "(TR-DOS emulation, RUN boot;", 13
                db      "the BASIC program is lost)", 13, 0
msg_none:       db      "No .TRD file", 's' + 80h

                savebin "RNDTRD", start, $ - start
