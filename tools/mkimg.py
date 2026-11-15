"""mkimg.py dir out.img [MB]: an SD card image (MBR, one FAT16 partition, 1 sector clusters) with the files of
dir (subdirectories too, 8.3 names in upper case), for the simulation of the DivMMC (src/sim/run_sd.sh). MB: the
size, 4 by default (FAT16 needs 4085 clusters at least)."""
import os
import struct
import sys

SEC = 512


def name83(n):
    base, _, ext = n.upper().partition('.')
    return (base[:8].ljust(8) + ext[:3].ljust(3)).encode('ascii')


def main():
    src, out = sys.argv[1], sys.argv[2]
    total = int(sys.argv[3]) * 2048 if len(sys.argv) > 3 else 8192
    start = 63                                   # the partition
    psec = total - start
    reserved, nfat, rootent = 1, 2, 512
    rootsec = rootent * 32 // SEC
    clusters = psec                              # upper bound
    fatsec = (clusters + 2) * 2 // SEC + 1
    clusters = psec - reserved - nfat * fatsec - rootsec
    assert clusters >= 4085, 'too small for FAT16'
    img = bytearray(total * SEC)
    # MBR
    pe = struct.pack('<B3sB3sII', 0x00, b'\x00\x00\x00', 0x06, b'\x00\x00\x00', start, psec)
    img[446:462] = pe
    img[510:512] = b'\x55\xaa'
    # boot sector
    bs = bytearray(SEC)
    bs[0:3] = b'\xeb\x3c\x90'
    bs[3:11] = b'MKIMG   '
    struct.pack_into('<HBHBHHBHHHII', bs, 11, SEC, 1, reserved, nfat, rootent,
                     psec if psec < 65536 else 0, 0xF8, fatsec, 63, 255, start, psec if psec >= 65536 else 0)
    struct.pack_into('<BBBI11s8s', bs, 36, 0x80, 0, 0x29, 0x12345678, b'QSPECCYX4  ', b'FAT16   ')
    bs[510:512] = b'\x55\xaa'
    p0 = start * SEC
    img[p0:p0 + SEC] = bs
    fat = [0xFFF8, 0xFFFF]
    data0 = start + reserved + nfat * fatsec + rootsec   # the sector of cluster 2

    def alloc(data):
        n = max(1, (len(data) + SEC - 1) // SEC)
        first = len(fat)
        for i in range(n):
            fat.append(first + i + 1 if i < n - 1 else 0xFFFF)
        assert len(fat) - 2 <= clusters
        o = (data0 + first - 2) * SEC
        img[o:o + len(data)] = data
        return first

    def entry(name, attr, clus, size):
        return name + struct.pack('<BBBHHHHHHHI', attr, 0, 0, 0, 0x5A21, 0x5A21, 0, 0, 0x5A21, clus, size)

    def build(path, parent):
        # a directory: its entries (. and .. first for a subdirectory); the clusters of the directory itself are
        # allocated before its children so that . can name them
        names = sorted(os.listdir(path))
        nent = len(names) + (2 if parent is not None else 0)
        dsize = max(1, (nent * 32 + SEC - 1) // SEC) * SEC
        me = alloc(bytes(dsize)) if parent is not None else 0
        ents = []
        if parent is not None:
            ents.append(entry(b'.          ', 0x10, me, 0))
            ents.append(entry(b'..         ', 0x10, parent, 0))
        for n in names:
            f = os.path.join(path, n)
            if os.path.isdir(f):
                c = build(f, me)
                ents.append(entry(name83(n), 0x10, c, 0))
            else:
                d = open(f, 'rb').read()
                c = alloc(d) if d else 0
                ents.append(entry(name83(n), 0x20, c, len(d)))
        raw = b''.join(ents)
        if parent is None:
            o = (start + reserved + nfat * fatsec) * SEC
            assert len(raw) <= rootsec * SEC
        else:
            o = (data0 + me - 2) * SEC
        img[o:o + len(raw)] = raw
        return me

    build(src, None)
    fb = b''.join(struct.pack('<H', x) for x in fat)
    for k in range(nfat):
        o = (start + reserved + k * fatsec) * SEC
        img[o:o + len(fb)] = fb
    open(out, 'wb').write(img)
    print('%s: %d sectors, %d clusters, %d used' % (out, total, clusters, len(fat) - 2))


main()
