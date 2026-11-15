#!/usr/bin/env python3
"""sna2sim.py: a 48K or 128K .sna snapshot for the simulation of zx_oct (src/sim/tb_sna.v).

    sna2sim.py <file.sna> <48.rom> <out dir>

Writes <out dir>/rom.hex (16384 words: the 32 KB of the ROM of the engine, both halves the 48 ROM) and ram.hex
(the 8 pages of 16 KB of machine 0 as 65536 words, page p at word p * 8192, word w = bytes 2w, 2w + 1; a 48K
snapshot fills pages 5, 2 and 0).

The registers go back by a loader in the ROM in place of SA-BYTES (04C2; the tape save routine, which a loaded game
does not call) and a jump to it at 0000: DI, (128K: #7FFD written), the alternate registers and AF' popped from a
block of words after the code (SP pointed into the ROM), HL, DE, BC, IY, IX, I, IM, AF popped, SP of the snapshot,
EI if IFF2, then RETN (48K: the PC is on the stack) or JP to the PC of the extension (128K). Both halves of the ROM
are the same patched 48 ROM, so the write of #7FFD does not change the code under the loader.
"""
import sys


def main():
    sna, rom48, out = sys.argv[1:4]
    d = open(sna, 'rb').read()
    if len(d) not in (27 + 49152, 131103, 147487):
        sys.exit('not a 48K / 128K .sna: %d bytes' % len(d))
    h, ram = d[:27], d[27:27 + 49152]
    w = lambda i: h[i] | (h[i + 1] << 8)
    I = h[0]
    hl_, de_, bc_, af_ = w(1), w(3), w(5), w(7)
    hl, de, bc, iy, ix = w(9), w(11), w(13), w(15), w(17)
    iff2 = (h[19] >> 2) & 1
    af, sp, im = w(21), w(23), h[25]

    pages = [bytes(16384)] * 8
    is128 = len(d) > 27 + 49152
    p7ffd = 0
    if is128:
        x = d[27 + 49152:]
        pc = x[0] | (x[1] << 8)
        p7ffd = x[2]
        top = p7ffd & 7
        pages[5], pages[2], pages[top] = ram[0:16384], ram[16384:32768], ram[32768:49152]
        rest = x[4:]
        k = 0
        for p in range(8):
            if p in (2, 5, top):
                continue
            pages[p] = rest[k * 16384:(k + 1) * 16384]
            k += 1
    else:
        pages[5], pages[2], pages[0] = ram[0:16384], ram[16384:32768], ram[32768:49152]
        pc = ram[sp - 0x4000] | (ram[sp - 0x4000 + 1] << 8)

    rom = bytearray(open(rom48, 'rb').read())
    assert len(rom) == 16384
    base = 0x04C2
    lo = lambda v: v & 0xFF
    hi = lambda v: v >> 8
    blk = base + 72                                             # the block of words
    code = bytearray([0xF3])                                    # DI
    if is128:
        code += bytes([0x01, 0xFD, 0x7F, 0x3E, p7ffd, 0xED, 0x79])  # LD BC,7FFD; LD A,n; OUT (C),A
    code += bytes([0x31, lo(blk), hi(blk)])                     # LD SP,blk
    code += bytes([0xF1, 0x08, 0xE1, 0xD1, 0xC1, 0xD9])         # POP AF; EX AF,AF'; POP HL; POP DE; POP BC; EXX
    code += bytes([0x21, lo(hl), hi(hl), 0x11, lo(de), hi(de), 0x01, lo(bc), hi(bc)])
    code += bytes([0xFD, 0x21, lo(iy), hi(iy), 0xDD, 0x21, lo(ix), hi(ix)])
    code += bytes([0x3E, I, 0xED, 0x47])                        # LD A,I; LD I,A
    code += bytes([0xED, {0: 0x46, 1: 0x56, 2: 0x5E}[im]])     # IM n
    code += bytes([0xF1])                                       # POP AF
    code += bytes([0x31, lo(sp), hi(sp)])                       # LD SP,sp
    if iff2:
        code += bytes([0xFB])                                   # EI
    if is128:
        code += bytes([0xC3, lo(pc), hi(pc)])                   # JP pc
    else:
        code += bytes([0xED, 0x45])                             # RETN
    assert len(code) <= 72
    rom[base:base + len(code)] = code
    for i, v in enumerate([af_, hl_, de_, bc_, af]):
        rom[blk + 2 * i] = lo(v)
        rom[blk + 2 * i + 1] = hi(v)
    rom[0:3] = bytes([0xC3, lo(base), hi(base)])               # JP the loader

    rom32 = rom + rom
    with open(out + '/rom.hex', 'w') as f:
        for i in range(0, 32768, 2):
            f.write('%02x%02x\n' % (rom32[i + 1], rom32[i]))
    with open(out + '/ram.hex', 'w') as f:
        for p in range(8):
            for i in range(0, 16384, 2):
                f.write('%02x%02x\n' % (pages[p][i + 1], pages[p][i]))
    print('sna2sim: %s PC %04X SP %04X I %02X IM %d IFF2 %d AF %04X 7FFD %02X' % (
        '128K' if is128 else '48K', pc, sp, I, im, iff2, af, p7ffd))


if __name__ == '__main__':
    main()
