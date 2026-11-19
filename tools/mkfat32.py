"""mkfat32.py dir out.img [MB]: an SD card image (MBR, one FAT32 LBA partition from sector 2048, 4 KB clusters,
smaller ones if the size needs them) with
the files of dir (subdirectories too). A name that is not a valid 8.3 name gets a long name (LFN entries) and a
short one: its leading digits if the name starts with digits and they are unique in the directory (0001 - aeon.trd
-> 0001.TRD), else BASE~N.EXT as Windows does. MB: the size, 512 by default (FAT32 needs 65525 clusters at least:
260 MB with 4 KB clusters, so a smaller image gets 2 KB or 1 KB clusters; 66 MB at least). The file is written sparse (zeros are not written)."""
import os
import re
import struct
import sys

SEC = 512
SPC = 8                                          # sectors per cluster (main() lowers it for a small image)
CL = SEC * SPC
VALID83 = re.compile(r"^[A-Z0-9_$~!#%&'()@^`{}-]{1,8}(\.[A-Z0-9_$~!#%&'()@^`{}-]{1,3})?$")


def short_name(name, used):
    """(the 11-byte short name, True if a long name is needed)"""
    if VALID83.match(name) and name != '.' and name != '..':
        base, _, ext = name.partition('.')
        sfn = (base.ljust(8) + ext.ljust(3)).encode('ascii')
        if sfn not in used:
            return sfn, False
    base, dot, ext = name.rpartition('.')
    if not dot:
        base, ext = name, ''
    clean = lambda s: re.sub(r"[^A-Z0-9_$~!#%&'()@^`{}-]", '', s.upper())
    ext = clean(ext)[:3]
    m = re.match(r'\d+', name)
    if m and len(m.group()) <= 8:
        sfn = (m.group().ljust(8) + ext.ljust(3)).encode('ascii')
        if sfn not in used:
            return sfn, True
    b = clean(base) or 'FILE'
    for n in range(1, 1000000):
        t = '~%d' % n
        sfn = ((b[:8 - len(t)] + t).ljust(8) + ext.ljust(3)).encode('ascii')
        if sfn not in used:
            return sfn, True
    raise ValueError(name)


def lfn_entries(name, sfn):
    s = 0                                        # the checksum of the short name
    for c in sfn:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    u = name.encode('utf-16-le')
    chars = [u[i:i + 2] for i in range(0, len(u), 2)]
    n = (len(chars) + 12) // 13
    chars += [b'\x00\x00'] if len(chars) % 13 else []
    chars += [b'\xff\xff'] * (n * 13 - len(chars))
    out = []
    for i in range(n, 0, -1):                    # the last part first
        c = chars[(i - 1) * 13:i * 13]
        e = bytes([i | (0x40 if i == n else 0)]) + b''.join(c[0:5]) + bytes([0x0F, 0, s]) + b''.join(c[5:11]) \
            + b'\x00\x00' + b''.join(c[11:13])
        out.append(e)
    return b''.join(out)


def main():
    global SPC, CL
    src, out = sys.argv[1], sys.argv[2]
    total = int(sys.argv[3]) * 2048 if len(sys.argv) > 3 else 512 * 2048
    start = 2048
    psec = total - start
    reserved, nfat = 32, 2
    while True:
        fatsec = ((psec // SPC + 2) * 4 + SEC - 1) // SEC
        clusters = (psec - reserved - nfat * fatsec) // SPC
        if clusters >= 65525 or SPC == 2:
            break
        SPC //= 2
    CL = SEC * SPC
    assert clusters >= 65525, 'too small for FAT32'
    data0 = start + reserved + nfat * fatsec     # the sector of cluster 2
    f = open(out, 'wb')
    f.truncate(total * SEC)

    def put(sector, data):
        f.seek(sector * SEC)
        f.write(data)

    # MBR
    put(0, b'\x00' * 446 + struct.pack('<B3sB3sII', 0x00, b'\xfe\xff\xff', 0x0C, b'\xfe\xff\xff', start, psec)
        + b'\x00' * 48 + b'\x55\xaa')
    fat = [0x0FFFFFF8, 0x0FFFFFFF]

    def alloc(n):
        first = len(fat)
        for i in range(n):
            fat.append(first + i + 1 if i < n - 1 else 0x0FFFFFFF)
        assert len(fat) - 2 <= clusters, 'the files do not fit'
        return first

    def write_clusters(first, data):
        put(data0 + (first - 2) * SPC, data)

    def entry(sfn, attr, clus, size):
        return sfn + struct.pack('<BBBHHHHHHHI', attr, 0, 0, 0, 0x5A71, 0x5A71, clus >> 16, 0, 0x5A71,
                                 clus & 0xFFFF, size)

    nfiles = [0, 0]

    def build(path, clus, parent):
        """the directory path at cluster clus (allocated by the caller): its children, then itself"""
        names = sorted(os.listdir(path))
        used = set()
        ents = []
        if parent is not None:
            ents.append(entry(b'.          ', 0x10, clus, 0))
            ents.append(entry(b'..         ', 0x10, parent, 0))
        else:
            ents.append(entry(b'QSPECCYX4  ', 0x08, 0, 0))
        kids = []
        for n in names:
            sfn, lfn = short_name(n, used)
            used.add(sfn)
            p = os.path.join(path, n)
            if os.path.isdir(p):
                c = alloc(1)                     # grown below if needed
                kids.append((p, c))
                ents.append((lfn_entries(n, sfn) if lfn else b'') + entry(sfn, 0x10, c, 0))
                nfiles[1] += 1
            else:
                data = open(p, 'rb').read()
                c = alloc((len(data) + CL - 1) // CL) if data else 0
                if data:
                    write_clusters(c, data)
                ents.append((lfn_entries(n, sfn) if lfn else b'') + entry(sfn, 0x20, c, len(data)))
                nfiles[0] += 1
        d = b''.join(ents)
        n = max(1, (len(d) + CL - 1) // CL)
        # the first cluster is clus; more clusters for a big directory chained after it
        prev = clus
        for i in range(1, n):
            c = alloc(1)
            fat[prev] = c
            prev = c
        fat[prev] = 0x0FFFFFFF
        chain = [clus]
        while fat[chain[-1]] != 0x0FFFFFFF:
            chain.append(fat[chain[-1]])
        d = d.ljust(n * CL, b'\x00')
        for i, c in enumerate(chain):
            write_clusters(c, d[i * CL:(i + 1) * CL])
        for p, c in kids:
            build(p, c, 0 if parent is None else clus)   # .. of a child of the root is 0

    root = alloc(1)
    build(src, root, None)
    used = len(fat) - 2

    # boot sector, FSInfo, their backups
    bs = bytearray(SEC)
    bs[0:3] = b'\xeb\x58\x90'
    bs[3:11] = b'MKFAT32 '
    struct.pack_into('<HBHBHHBHHHII', bs, 11, SEC, SPC, reserved, nfat, 0, 0, 0xF8, 0, 63, 255, start, psec)
    struct.pack_into('<IHHIHH12sBBBI11s8s', bs, 36, fatsec, 0, 0, root, 1, 6, b'\x00' * 12, 0x80, 0, 0x29,
                     0x51A7C0DE, b'QSPECCYX4  ', b'FAT32   ')
    bs[510:512] = b'\x55\xaa'
    fsi = bytearray(SEC)
    struct.pack_into('<I', fsi, 0, 0x41615252)
    struct.pack_into('<III', fsi, 484, 0x61417272, clusters - used, len(fat))
    fsi[510:512] = b'\x55\xaa'
    for o in (0, 6):
        put(start + o, bytes(bs))
        put(start + o + 1, bytes(fsi))
        put(start + o + 2, b'\x00' * 510 + b'\x55\xaa')
    fb = struct.pack('<%dI' % len(fat), *fat)
    for i in range(nfat):
        put(start + reserved + i * fatsec, fb)
    f.close()
    print('%s: %d MB, %d files, %d directories, %d of %d clusters (%d KB) used'
          % (out, total // 2048, nfiles[0], nfiles[1], used, clusters, CL // 1024))


if __name__ == '__main__':
    main()
