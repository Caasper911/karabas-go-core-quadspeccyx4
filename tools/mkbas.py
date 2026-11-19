"""mkbas.py out.bas line text [line text ...]: a BASIC program file with a +3DOS header (as SAVE * of ESXDOS writes
it), autostart at the first line. The text is stored as it is (no keyword tokens): enough for dot commands
(10 ".rndtrd /DEMOTRD"), which ESXDOS runs from a program line."""
import struct
import sys


def main():
    out, args = sys.argv[1], sys.argv[2:]
    prog = b''
    for num, text in zip(args[0::2], args[1::2]):
        body = text.encode('ascii') + b'\x0d'
        prog += struct.pack('>H', int(num)) + struct.pack('<H', len(body)) + body
    hdr = bytearray(128)
    hdr[0:8] = b'PLUS3DOS'
    hdr[8:11] = b'\x1a\x01\x00'
    struct.pack_into('<I', hdr, 11, 128 + len(prog))
    # the +3 BASIC header: type 0 (program), length, autostart line, the start of the variables
    struct.pack_into('<BHHH', hdr, 15, 0, len(prog), int(args[0]), len(prog))
    hdr[127] = sum(hdr[:127]) & 0xFF
    open(out, 'wb').write(bytes(hdr) + prog)


if __name__ == '__main__':
    main()
