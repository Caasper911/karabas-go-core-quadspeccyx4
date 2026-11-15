; The common part of RNDSNA / RNDTAP (ESXDOS 0.8.x dot commands): the argument <dir>, a random
; *.<EXT> of it, the ESXDOS command line CMDWORD "<dir>/<file>" and the stub that runs it.
;
; The including file defines: CMDWORD (define, the ESXDOS command and a space), EXT1..EXT3 (the
; extension, lower case), stub / stub_len / st_ix / st_hl / st_sp (the stub: run in main RAM,
; st_ix + 2 and st_hl + 1 get the address of the command line, st_sp + 1 the SP of the caller),
; msg_use (0-terminated), msg_none (last char + 80h).

M_GETSETDRV     equ     89h
M_EXECCMD       equ     8Fh
F_CLOSE         equ     9Bh
F_OPENDIR       equ     0A3h
F_READDIR       equ     0A4h
F_REWINDDIR     equ     0A7h

FRAMES          equ     5C78h
PATHMAX         equ     128             ; with the terminating 0
NAMEMAX         equ     256             ; with the terminating 0
AREA            equ     stub_len + cmd_max + 16

start:          ld      a,h
                or      l
                jp      z,usage

; ---- the argument: skip spaces, optional quotes, end at 0, 0Dh, ':' or a space ----
                call    skipsp
                ld      c,0             ; c = closing quote or 0
                cp      '"'
                jr      nz,.noq
                ld      c,a
                inc     hl
.noq:           ld      de,path
                ld      b,PATHMAX - 2   ; room for a '/' and the 0
.cp:            ld      a,(hl)
                or      a
                jr      z,.end
                cp      0Dh
                jr      z,.end
                cp      c
                jr      z,.end
                ld      a,c
                or      a
                ld      a,(hl)
                jr      nz,.st          ; inside quotes everything goes
                cp      ':'
                jr      z,.end
                cp      ' '
                jr      z,.end
.st:            ld      (de),a
                inc     de
                inc     hl
                djnz    .cp
                ld      hl,msg_long
                jp      err
.end:           ld      a,e
                cp      low path
                jp      z,usage         ; empty
                xor     a
                ld      (de),a
                ld      (pathend),de

; ---- open the directory, count the files ----
                xor     a
                rst     08h
                db      M_GETSETDRV     ; a = the current drive
                ld      hl,path
                rst     08h
                db      F_OPENDIR
                ret     c
                ld      (dirh),a

                ld      hl,0
                ld      (count),hl
.count:         call    nextfile
                jr      c,.cerr
                jr      z,.counted
                ld      hl,(count)
                inc     hl
                ld      (count),hl
                jr      .count
.cerr:          push    af
                call    closedir
                pop     af
                ret
.counted:       ld      hl,(count)
                ld      a,h
                or      l
                jr      nz,.some
                call    closedir
                ld      hl,msg_none
                jp      err

; ---- index = random mod count ----
.some:          call    random          ; hl
                ld      de,(count)
                call    mod16           ; hl = hl mod de
                ld      (index),hl

                ld      a,(dirh)
                rst     08h
                db      F_REWINDDIR
                jr      c,.cerr
.find:          call    nextfile
                jr      c,.cerr
                jr      z,.gone         ; the directory changed between the passes
                ld      hl,(index)
                ld      a,h
                or      l
                jr      z,.found
                dec     hl
                ld      (index),hl
                jr      .find
.gone:          call    closedir
                ld      hl,msg_none
                jp      err
.found:         call    closedir

; ---- the command line: CMDWORD path ['/'] name ----
                ld      hl,(pathend)
                dec     hl
                ld      a,(hl)
                inc     hl
                ex      de,hl           ; de = end of the path
                cp      '/'
                jr      z,.sl
                cp      5Ch             ; backslash
                jr      z,.sl
                ld      a,'/'
                ld      (de),a
                inc     de
.sl:            ld      hl,ent + 1      ; the name after the attribute byte
.nm:            ld      a,(hl)
                ld      (de),a
                inc     de
                inc     hl
                or      a
                jr      nz,.nm
                ld      (cmdend),de

; ---- the stub with the command line below the current SP, then run it ----
                ld      hl,0
                add     hl,sp
                ld      (st_sp + 1),hl  ; back to the ESXDOS caller after a failure
                ld      de,-AREA
                add     hl,de           ; hl = the base of the area
                push    hl
                ld      de,stub_len
                add     hl,de           ; the command line after the stub
                ld      (st_ix + 2),hl
                ld      (st_hl + 1),hl
                pop     de              ; de = the base
                push    de
                ld      hl,stub
                ld      bc,stub_len
                ldir
                ld      hl,(cmdend)
                ld      bc,cmd
                or      a
                sbc     hl,bc
                ld      b,h
                ld      c,l             ; bc = the length of the command line
                ld      hl,cmd
                ldir
                pop     hl
                ld      sp,hl           ; the stack goes on below the area
                jp      (hl)

; ---- nextfile: the next *.SNA entry into ent; cy = error (a), z = the end ----
nextfile:        ld      a,(dirh)
                ld      hl,ent
                rst     08h
                db      F_READDIR
                ret     c
                or      a
                ret     z               ; a = 0: no more entries
                ld      a,(ent)
                and     10h             ; a directory
                jr      nz,nextfile
                ld      hl,ent + 1
                ld      bc,0
.len:           ld      a,(hl)
                or      a
                jr      z,.ln
                inc     hl
                inc     bc
                jr      .len
.ln:            ld      a,c             ; at least "X.EXT"
                cp      5
                ld      a,b
                sbc     a,0
                jr      c,nextfile
                dec     hl
                ld      a,(hl)
                or      20h
                cp      EXT3
                jr      nz,nextfile
                dec     hl
                ld      a,(hl)
                or      20h
                cp      EXT2
                jr      nz,nextfile
                dec     hl
                ld      a,(hl)
                or      20h
                cp      EXT1
                jr      nz,nextfile
                dec     hl
                ld      a,(hl)
                cp      '.'
                jr      nz,nextfile
                or      a               ; nz, nc: found
                ret

closedir:       ld      a,(dirh)
                rst     08h
                db      F_CLOSE
                ret

skipsp:         ld      a,(hl)
                cp      ' '
                ret     nz
                inc     hl
                jr      skipsp

; ---- random: hl from FRAMES and R, xorshift 7, 9, 8 ----
random:         ld      a,r
                ld      hl,(FRAMES)
                xor     l
                ld      l,a
                ld      a,(FRAMES + 2)
                xor     h
                ld      h,a
                ld      a,r
                rlca
                xor     h
                ld      h,a
                or      l
                jr      nz,.x
                inc     hl
.x:             ld      b,3
.r:             push    bc
                ld      a,h             ; hl ^= hl << 7
                rra
                ld      a,l
                rra
                xor     h
                ld      h,a
                ld      a,l
                rra
                ld      a,h             ; hl ^= hl >> 9
                rra
                xor     l
                ld      l,a
                xor     h               ; hl ^= hl << 8
                ld      h,a
                pop     bc
                djnz    .r
                ret

; ---- mod16: hl = hl mod de (de > 0) ----
mod16:          ld      b,h
                ld      c,l             ; bc = the dividend
                ld      hl,0
                ld      a,16
.m:             sla     c
                rl      b
                adc     hl,hl
                jr      c,.ov           ; past 16 bits (de > 8000h): above de
                sbc     hl,de           ; cy is 0 here
                jr      nc,.k
                add     hl,de
                jr      .k
.ov:            ccf
                sbc     hl,de
.k:             dec     a
                jr      nz,.m
                ret

; ---- messages ----
usage:          ld      hl,msg_use
.p:             ld      a,(hl)
                or      a
                ret     z               ; nc: back to BASIC
                rst     10h
                inc     hl
                jr      .p

err:            xor     a               ; a = 0, cy: hl = the message (last char + 80h)
                scf
                ret

msg_long:       db      "Path too lon", 'g' + 80h

cmd:            db      CMDWORD
path:           ds      PATHMAX + 1 + NAMEMAX
cmd_max         equ     $ - cmd

pathend:        dw      0
cmdend:         dw      0
count:          dw      0
index:          dw      0
dirh:           db      0
ent:            ds      1 + NAMEMAX + 8 ; attribute, name, date, size

                assert  $ <= 3DE0h, "the command does not fit"
