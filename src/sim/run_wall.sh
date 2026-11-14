#!/bin/bash
# The eight machines of zx_oct on sram_ctrl and the SRAM model against eight golden machines (ISim):
#   ./run_wall.sh [clocks]      random code (default 2 000 000 clocks); ROM=1: the ROM 128 (clocks: e.g. 8 frames =
#                               4587520), the screens of the machines in work_w/screens.png; with SAME=1 all
#                               machines out of reset at once (one code in lock step)
# SEED=<n> the random seed. Regenerates tv80o_core.v first (tools/mkctx.py). Prints "tb_wall: <n> errors".
set -e -o pipefail
cd "$(dirname "$0")"
CLOCKS=${1:-2000000}
PY=${PYTHON:-python3}
$PY ../../tools/mkctx.py ../rtl/tv80/tv80_core.v ../rtl/tv80 8 > /dev/null
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_w/tmp
	export TEMP="$(cygpath -m "$PWD")/work_w/tmp" TMP="$(cygpath -m "$PWD")/work_w/tmp"
	EXE=./tb_wall.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_wall ;;
esac
mkdir -p work_w
DEFS="-d CLOCKS=$CLOCKS -d SEED=${SEED:-1} ${FUSE_DEFS}"
if [ "${ROM:-0}" = 1 ]; then
	$PY ../../tools/rom2hex.py ../roms/128.rom ../roms/48.rom work_w/roms.hex
	DEFS="$DEFS -d MODE_ROM"
	[ "${SAME:-0}" = 1 ] && DEFS="$DEFS -d SAME_START"
fi
cat > work_w/tb.prj <<PRJ
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80_reg.v"
verilog work "../../rtl/tv80/tv80_core.v"
verilog work "../../rtl/tv80/tv80o_reg.v"
verilog work "../../rtl/tv80/tv80o_core.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/zx/zx_oct.v"
verilog work "../../rtl/mem/sram_ctrl.v"
verilog work "../../rtl/mem/sram_arb.v"
verilog work "../sram_model.v"
verilog work "../tb_wall.v"
PRJ
cd work_w
fuse -intstyle silent -incremental -prj tb.prj -o $EXE $DEFS work.tb_wall > fuse.log 2>&1 || { grep -E "ERROR|WARNING:HDLCompiler" fuse.log | head -30; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -vE "^(Stopped|INFO)" | head -${SHOWN:-60} || true
if [ "${ROM:-0}" = 1 ] && [ -f screens.hex ]; then $PY ../../../tools/render_wall.py screens.hex screens.png; fi
grep -q "tb_wall: 0 errors" sim.log
