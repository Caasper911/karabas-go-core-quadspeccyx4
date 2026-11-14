#!/usr/bin/env python3
"""sna2sim.py: a 48K .sna snapshot for the simulation of zx_oct (src/sim/tb_sna.v).

    sna2sim.py <file.sna> <48.rom> <out dir>

Writes <out dir>/rom.hex (16384 words: the 32 KB of the ROM of the engine, both halves the 48 ROM) and ram.hex
(the 48 KB as 24576 words: pages 5, 2 and 0 of machine 0, word w = bytes 2w, 2w + 1 of 4000..FFFF).

The registers go back by a loader in the ROM in place of SA-BYTES (04C2; the tape save routine, which a loaded game
does not call) and a jump to it at 0000: DI, the alternate registers and AF' popped from a block of words after the
code (SP pointed into the ROM), HL, DE, BC, IY, IX, I, IM, AF popped, SP of the snapshot, EI if IFF2, RETN: the PC
of the snapshot is on its stack.
"""
import sys


def main():
    sna, rom48, out = sys.argv[1:4]
    d = open(sna, 'rb').read()
    if len(d) != 27 + 49152:
        sys.exit('not a 48K .sna: %d bytes' % len(d))
    h, ram = d[:27], d[27:]
    w = lambda i: h[i] | (h[i + 1] << 8)
    I = h[0]
    hl_, de_, bc_, af_ = w(1), w(3), w(5), w(7)
    hl, de, bc, iy, ix = w(9), w(11), w(13), w(15), w(17)
    iff2 = (h[19] >> 2) & 1
    af, sp, im = w(21), w(23), h[25]

    rom = bytearray(open(rom48, 'rb').read())
    assert len(rom) == 16384
    base = 0x04C2
    code = bytearray()
    lo = lambda v: v & 0xFF
    hi = lambda v: v >> 8
    blk = base + 64                                            # the block of words
    code += bytes([0xF3, 0x31, lo(blk), hi(blk)])               # DI; LD SP,blk
    code += bytes([0xF1, 0x08, 0xE1, 0xD1, 0xC1, 0xD9])         # POP AF; EX AF,AF'; POP HL; POP DE; POP BC; EXX
    code += bytes([0x21, lo(hl), hi(hl), 0x11, lo(de), hi(de), 0x01, lo(bc), hi(bc)])
    code += bytes([0xFD, 0x21, lo(iy), hi(iy), 0xDD, 0x21, lo(ix), hi(ix)])
    code += bytes([0x3E, I, 0xED, 0x47])                        # LD A,I; LD I,A
    code += bytes([0xED, {0: 0x46, 1: 0x56, 2: 0x5E}[im]])     # IM n
    code += bytes([0xF1])                                       # POP AF
    code += bytes([0x31, lo(sp), hi(sp)])                       # LD SP,sp
    if iff2:
        code += bytes([0xFB])                                   # EI
    code += bytes([0xED, 0x45])                                 # RETN
    assert len(code) <= 64
    rom[base:base + len(code)] = code
    words = [af_, hl_, de_, bc_, af]
    for i, v in enumerate(words):
        rom[blk + 2 * i] = lo(v)
        rom[blk + 2 * i + 1] = hi(v)
    rom[0:3] = bytes([0xC3, lo(base), hi(base)])               # JP the loader

    rom32 = rom + rom
    with open(out + '/rom.hex', 'w') as f:
        for i in range(0, 32768, 2):
            f.write('%02x%02x\n' % (rom32[i + 1], rom32[i]))
    with open(out + '/ram.hex', 'w') as f:
        for i in range(0, 49152, 2):
            f.write('%02x%02x\n' % (ram[i + 1], ram[i]))
    pc = ram[sp - 0x4000] | (ram[sp - 0x4000 + 1] << 8)
    print('sna2sim: PC %04X SP %04X I %02X IM %d IFF2 %d AF %04X' % (pc, sp, I, im, iff2, af))


if __name__ == '__main__':
    main()
