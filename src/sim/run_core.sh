#!/bin/bash
# The whole core with its PLLs on the SRAM model (ISim): ./run_core.sh [clocks of clk_bus]; the diagnostics of the
# core every 100 000 clocks. The ROM is put into zx_oct directly, the MCU link is idle.
set -e -o pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3}
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_c/tmp
	export TEMP="$(cygpath -m "$PWD")/work_c/tmp" TMP="$(cygpath -m "$PWD")/work_c/tmp"
	EXE=./tb_core.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_core ;;
esac
mkdir -p work_c
$PY ../../tools/rom2hex.py ../roms/128.rom ../roms/48.rom work_c/roms.hex
{
	sed -n 's/^verilog work "\(.*\)"/verilog work "..\/..\/\1"/p' ../karabas_go.prj | grep -v karabas_go_top
	echo 'verilog work "../sram_model.v"'
	echo 'verilog work "../tb_core.v"'
	echo "verilog work \"$(cygpath -m "$XILINX" 2>/dev/null || echo "$XILINX")/verilog/src/glbl.v\""
} > work_c/tb.prj
cd work_c
fuse -intstyle silent -prj tb.prj -L unisims_ver -o $EXE -d CLOCKS=${1:-1500000} work.tb_core work.glbl > fuse.log 2>&1 || { grep -E "ERROR" fuse.log | head -30; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -vE "^(Stopped|INFO|WARNING|ISim|This is|Time res|Simulator|Finished|---|\s*$)" | head -60 || true
