#!/usr/bin/env python3
"""render_frame.py: screen.hex of src/sim/tb_sna.v (the whole Pentagon raster, 448 x 320 values {bright, G, R, B},
line vc 0..319, pixel hc 0..447: paper at hc 0..255 of lines 0..191) into a PNG, scaled 2x, rotated so that the
picture reads as on a screen (left border hc 384..447 of the line before first, top border lines 256..319 first)."""
import sys
import zlib
import struct


def main():
    src, dst = sys.argv[1:3]
    v = [int(x, 16) if x.strip() not in ('x', 'X') else 0 for x in open(src) if x.strip()]
    W, H = 448, 320
    cols = lambda p: tuple((0xFF if p & 8 else 0xCA) if p & m else 0 for m in (2, 4, 1))
    rows = []
    for y in range(H):
        vc = (y + 256) % H
        line = bytearray()
        for x in range(W):
            hc = (x + 384) % W
            # the left border (hc 384..447) is drawn before the paper of the next line: from the line before
            lv = (vc - 1) % H if hc >= 384 else vc
            c = cols(v[lv * W + hc])
            line += bytes(c) * 2
        rows.append(bytes(line))
        rows.append(bytes(line))
    raw = b''.join(b'\x00' + r for r in rows)
    png = b'\x89PNG\r\n\x1a\n'
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', W * 2, H * 2, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    open(dst, 'wb').write(png)


if __name__ == '__main__':
    main()
