#!/bin/bash
# The full screen video path (ISim): zx_scr + sram_ctrl + the SRAM model + vga_out, every visible pixel checked:
#   ./run_video.sh [frames]     MODE=1 (1280 x 800, default) or MODE=0 (720 x 576); STRIPES=1, SCR7=1, BUSY=0
# Prints "tb_video: <n> errors".
set -e -o pipefail
cd "$(dirname "$0")"
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_v/tmp
	export TEMP="$(cygpath -m "$PWD")/work_v/tmp" TMP="$(cygpath -m "$PWD")/work_v/tmp"
	EXE=./tb_video.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_video ;;
esac
mkdir -p work_v
DEFS="-d FRAMES=${1:-3} -d MODE=${MODE:-1} -d WALL=${WALL:-0} -d SEL=${SEL:-5} -d STRIPES=${STRIPES:-0} -d SCR7=${SCR7:-0} -d BUSY=${BUSY:-1}"
cat > work_v/tb.prj <<PRJ
verilog work "../../../modules/rtl/mem/kg_sdpram.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/mem/sram_ctrl.v"
verilog work "../../rtl/video/zx_scr.v"
verilog work "../../rtl/video/wall_fetch.v"
verilog work "../../rtl/video/vga_out.v"
verilog work "../sram_model.v"
verilog work "../tb_video.v"
PRJ
cd work_v
fuse -intstyle silent -prj tb.prj -o $EXE $DEFS work.tb_video > fuse.log 2>&1 || { grep -E "ERROR|WARNING:HDLCompiler" fuse.log | head -30; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -vE "^(Stopped|INFO)" | head -40 || true
grep -q "tb_video: 0 errors" sim.log
