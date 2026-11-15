#!/bin/bash
# The DivMMC with the SD cards (tb_sd.v, ISim): ./run_sd.sh [frames]. The sixteen machines boot ESXDOS from an
# image made by tools/mkimg.py of the directory SDDIR (default: an SYS / BIN of ESXDOS, ../../../v6z80p/V6_SD_card);
# the screens in work_d/screens.png. Env: LAT (clocks of the MCU before the bytes of a sector, 20000), STAGGER
# (clocks between the machines out of reset, 20000).
set -e -o pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3}
$PY ../../tools/mkctx.py ../rtl/tv80/tv80_core.v ../rtl/tv80 8 > /dev/null
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_d/tmp
	export TEMP="$(cygpath -m "$PWD")/work_d/tmp" TMP="$(cygpath -m "$PWD")/work_d/tmp"
	EXE=./tb_sd.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_sd ;;
esac
mkdir -p work_d
SDDIR=${SDDIR:-../../../v6z80p/V6_SD_card}
rm -rf work_d/sd && mkdir -p work_d/sd
for d in SYS BIN; do [ -d "$SDDIR/$d" ] && cp -r "$SDDIR/$d" work_d/sd/; done
$PY ../../tools/mkimg.py work_d/sd work_d/img.bin 4
$PY -c "import sys; open(sys.argv[2], 'w').write('\n'.join('%02x' % b for b in open(sys.argv[1], 'rb').read()) + '\n')" work_d/img.bin work_d/img.hex
$PY ../../tools/rom2hex.py ../roms/128.rom ../roms/48.rom work_d/roms.hex
# the simulation only (FAST=0: the ROM as it is): the loops of ESXDOS 0.8.9 before the card made short, the power-on
# delay (0101 LD BC,2A30) and the clears of the screen (0133 LD BC,1EFF) and of the banks (0143 LD BC,1FFF): ~20 frames;
# the poll of a response (1E55 LD BC,0032: 12800 bytes FF, ~8 frames; it times out on the second OCR byte FF and on
# the probe of the second card, #E7 bit 1, 8 x CMD0: ~60 frames) 512 bytes
$PY -c "
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
if sys.argv[3] != '0':
    assert d[0x101:0x104] == bytes([1, 0x30, 0x2A]) and d[0x133:0x136] == bytes([1, 0xFF, 0x1E]) and d[0x143:0x146] == bytes([1, 0xFF, 0x1F])
    assert d[0x1E55:0x1E58] == bytes([1, 0x32, 0])
    d[0x101:0x104] = bytes([1, 0x10, 0]); d[0x133:0x136] = bytes([1, 0x10, 0]); d[0x143:0x146] = bytes([1, 0x10, 0])
    d[0x1E55:0x1E58] = bytes([1, 2, 0])
open(sys.argv[2], 'wb').write(d)" ../roms/esxdos089.bin work_d/esx.bin ${FAST:-1}
$PY ../../tools/rom2hex.py work_d/esx.bin work_d/esx.hex
cat > work_d/tb.prj <<PRJ
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80o_reg.v"
verilog work "../../rtl/tv80/tv80o_core.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/zx/zx_oct.v"
verilog work "../../rtl/video/zx_vid.v"
verilog work "../../rtl/video/vid_fetch.v"
verilog work "../../rtl/sd/sd_oct.v"
verilog work "../../rtl/sd/sd_host.v"
verilog work "../../../modules/rtl/mem/kg_tdpram.v"
verilog work "../../../modules/rtl/mem/kg_spram.v"
verilog work "../../rtl/mem/sram_ctrl.v"
verilog work "../../rtl/mem/sram_arb.v"
verilog work "../sram_model.v"
verilog work "../tb_sd.v"
PRJ
cd work_d
fuse -intstyle silent -prj tb.prj -o $EXE -i .. -d FRAMES=${1:-8} ${LAT:+-d LAT=$LAT} ${STAGGER:+-d STAGGER=$STAGGER} ${FUSE_DEFS} work.tb_sd > fuse.log 2>&1 || { grep -E "ERROR" fuse.log | head -20; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -vE "^(Stopped|INFO|WARNING|ISim|This is|Time res|Simulator|Finished|---|\s*$)" | head -80
[ -f screens.hex ] && $PY ../../../tools/render_wall.py screens.hex screens.png
grep -q "tb_sd: 0 errors" sim.log
