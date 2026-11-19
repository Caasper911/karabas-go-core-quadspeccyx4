#!/bin/bash
# The video path (ISim): two zx_vid (16 machines, staggered rasters) + vid_fetch + sram_ctrl + the SRAM model,
# fb_sdram + the SDRAM model, vga_out 1280 x 800; every visible pixel checked (tb_video.v):
#   ./run_video.sh [frames]     WALL=1 (default) the wall, WALL=0 the full screen of machine FS (5); NB=1 the wall
#                               without the border (6 frames to see the check of the frames shown); CFT=0 the border
#                               without the cell frame; BUSY=0 the CPU port busy at random; MODE=2 1280 x 800 at
#                               60 Hz (not locked: the full screen the cell of FS at scale 4)
# Prints "tb_video: <n> errors". About a minute and a half per frame.
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
DEFS="-d FRAMES=${1:-4} -d WALL=${WALL:-1} -d FS=${FS:-5} -d BUSY=${BUSY:-1} -d CFT=${CFT:-1} -d NB=${NB:-0} -d MODE=${MODE:-1}"
cat > work_v/tb.prj <<PRJ
verilog work "../../../modules/rtl/mem/kg_sdpram.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/mem/sram_ctrl.v"
verilog work "../../rtl/video/zx_vid.v"
verilog work "../../rtl/video/vid_fetch.v"
verilog work "../../rtl/video/fb_sdram.v"
verilog work "../../rtl/video/vga_out.v"
verilog work "../sram_model.v"
verilog work "../sdram_model.v"
verilog work "../tb_video.v"
verilog work "$(cygpath -m "$XILINX" 2>/dev/null || echo "$XILINX")/verilog/src/glbl.v"
PRJ
cd work_v
fuse -intstyle silent -lib unisims_ver -prj tb.prj -o $EXE $DEFS work.tb_video work.glbl > fuse.log 2>&1 || { grep -E "ERROR|WARNING:HDLCompiler" fuse.log | head -30; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -vE "^(Stopped|INFO)" | head -60 || true
grep -q "tb_video: 0 errors" sim.log
