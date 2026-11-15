#!/bin/bash
# A 48K snapshot in machine 0 (tb_sna.v, ISim): ./run_sna.sh <file.sna> [frames]
set -e -o pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3}
$PY ../../tools/mkctx.py ../rtl/tv80/tv80_core.v ../rtl/tv80 8 > /dev/null
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_s/tmp
	export TEMP="$(cygpath -m "$PWD")/work_s/tmp" TMP="$(cygpath -m "$PWD")/work_s/tmp"
	EXE=./tb_sna.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_sna ;;
esac
mkdir -p work_s
$PY ../../tools/sna2sim.py "$1" ../roms/48.rom work_s
cat > work_s/tb.prj <<PRJ
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80o_reg.v"
verilog work "../../rtl/tv80/tv80o_core.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/zx/zx_oct.v"
verilog work "../../rtl/sd/sd_oct.v"
verilog work "../../../modules/rtl/mem/kg_tdpram.v"
verilog work "../../rtl/mem/sram_ctrl.v"
verilog work "../../rtl/mem/sram_arb.v"
verilog work "../../rtl/video/zx_scr.v"
verilog work "../sram_model.v"
verilog work "../tb_sna.v"
PRJ
cd work_s
fuse -intstyle silent -prj tb.prj -o $EXE -d FRAMES=${2:-5} work.tb_sna > fuse.log 2>&1 || { grep -E "ERROR" fuse.log | head -20; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -vE "^(Stopped|INFO|WARNING|ISim|This is|Time res|Simulator|Finished|---|\s*$)" | grep -v "^ " | head -40
[ -f screen.hex ] && $PY ../../../tools/render_frame.py screen.hex screen.png
grep -q "tb_sna:" sim.log
