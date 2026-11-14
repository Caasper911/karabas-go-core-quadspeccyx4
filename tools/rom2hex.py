"""rom2hex.py rom... out.hex: the ROM files one after the other as 16-bit little endian words, one hex word per
line ($readmemh of the SDRAM model, src/sim)."""
import sys

data = b"".join(open(f, "rb").read() for f in sys.argv[1:-1])
if len(data) % 2:
    data += b"\xff"
with open(sys.argv[-1], "w") as out:
    for i in range(0, len(data), 2):
        out.write("%04x\n" % (data[i] | data[i + 1] << 8))
