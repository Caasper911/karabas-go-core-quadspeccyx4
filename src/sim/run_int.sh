#!/bin/bash
# The frame interrupt of the 16 machines (tb_int.v, ISim): ./run_int.sh [frames]; SHORT=1 the handler EI / RET.
set -e -o pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3}
$PY ../../tools/mkctx.py ../rtl/tv80/tv80_core.v ../rtl/tv80 8 > /dev/null
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_i/tmp
	export TEMP="$(cygpath -m "$PWD")/work_i/tmp" TMP="$(cygpath -m "$PWD")/work_i/tmp"
	EXE=./tb_int.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_int ;;
esac
mkdir -p work_i
cat > work_i/tb.prj <<PRJ
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80o_reg.v"
verilog work "../../rtl/tv80/tv80o_core.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/zx/zx_oct.v"
verilog work "../../rtl/mem/sram_ctrl.v"
verilog work "../../rtl/mem/sram_arb.v"
verilog work "../sram_model.v"
verilog work "../tb_int.v"
PRJ
cd work_i
fuse -intstyle silent -prj tb.prj -o $EXE -d FRAMES=${1:-4} -d SHORT=${SHORT:-0} work.tb_int > fuse.log 2>&1 || { grep -E "ERROR" fuse.log | head -20; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -vE "^(Stopped|INFO|WARNING|ISim|This is|Time res|Simulator|Finished|---|\s*$)" | grep -v "^ " | head -40
grep -q "tb_int: 0 errors" sim.log
