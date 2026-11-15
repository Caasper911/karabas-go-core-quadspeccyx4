; .RNDSNA <dir> - run a random *.SNA of a directory (ESXDOS 0.8.x dot command).
;
; Counts the *.SNA files of <dir>, takes a random one (FRAMES and R) and runs it with the
; ESXDOS command "snapload <dir>/<file>" (M_EXECCMD). The dot command area 2000h-3FFFh is
; taken by SNAPLOAD then, so the call runs from a stub on the machine stack (main RAM).
;
; Build: sjasmplus rndsna.asm (writes RNDSNA). Copy it to /BIN of the SD card.

                device  zxspectrum48

                define  CMDWORD "snapload "
EXT1            equ     's'
EXT2            equ     'n'
EXT3            equ     'a'

                org     2000h

                include "rndsel.inc"

; the stub (relocatable: copied and run in main RAM)
stub:
st_ix:          ld      ix,0            ; from main RAM rst 08h takes IX
st_hl:          ld      hl,0
                rst     08h
                db      M_EXECCMD       ; does not return when the snapshot runs
st_sp:          ld      sp,0            ; flags and A (the error) stay
                ret
stub_len        equ     $ - stub

msg_use:        db      ".RNDSNA <dir>", 13
                db      "runs a random *.SNA of <dir>", 13, 0
msg_none:       db      "No .SNA file", 's' + 80h

                savebin "RNDSNA", start, $ - start
