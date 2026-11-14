"""render_wall.py screens.hex out.png: the screens of the machines (src/sim/tb_wall.v with MODE_ROM: per machine
6912 bytes of its screen page, one hex byte per line, machine after machine; the page and the border of each in a
line "@ <page> <border>" before it) as a PNG, four in a row, the border of each around it. No libraries."""
import struct
import sys
import zlib

PAL = [(0, 0, 0), (0, 0, 0xCA), (0xCA, 0, 0), (0xCA, 0, 0xCA), (0, 0xCA, 0), (0, 0xCA, 0xCA), (0xCA, 0xCA, 0),
       (0xCA, 0xCA, 0xCA)]
B = 8   # border width


def load(path):
    scr = []
    for line in open(path):
        line = line.strip()
        if line.startswith("@"):
            scr.append((int(line.split()[2]), bytearray()))
        elif line:
            scr[-1][1].append(int(line, 16))
    return scr


def pixels(border, scr):
    bc = PAL[border & 7]
    rows = [[bc] * (256 + 2 * B) for _ in range(B)]
    for y in range(192):
        row = [bc] * B
        for x in range(256):
            b = scr[((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (x >> 3)]
            a = scr[0x1800 + (y >> 3) * 32 + (x >> 3)]
            ink = (b >> (7 - (x & 7))) & 1
            col = PAL[(a & 7) if ink else ((a >> 3) & 7)]
            if a & 0x40:
                col = tuple(0xFF if v else 0 for v in col)
            row.append(col)
        rows.append(row + [bc] * B)
    rows += [[bc] * (256 + 2 * B) for _ in range(B)]
    return rows


def png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = b"".join(b"\0" + b"".join(bytes(p) for p in r) for r in rows)

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


screens = [pixels(b, s) for b, s in load(sys.argv[1])]
gap = 4
grey = (0x40, 0x40, 0x40)
w = 256 + 2 * B
out = []
for r in range(0, len(screens), 4):
    row_s = screens[r:r + 4]
    for y in range(192 + 2 * B):
        line = []
        for s in row_s:
            line += s[y] + [grey] * gap
        out.append(line + [grey] * ((w + gap) * (4 - len(row_s))))
    out += [[grey] * ((w + gap) * 4)] * gap
png(sys.argv[2], out)
