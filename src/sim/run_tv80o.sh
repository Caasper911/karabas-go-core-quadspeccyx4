#!/bin/bash
# The equivalence test of tv80_oct with eight tv80_core (ISim): ./run_tv80o.sh [clocks]
# SEED=<n> the random seed; NOGEN=1 keeps tv80o_core.v (a hand mutation); FUSE_DEFS / SHOW: defines and the grep
# of the output (TRACE_CPU, TRACE_FROM: tb_tv80o.v)
# Regenerates rtl/tv80/tv80o_core.v / tv80o_reg.v from tv80_core.v first (tools/mkctx.py).
set -e -o pipefail
cd "$(dirname "$0")"
CLOCKS=${1:-2000000}
PY=${PYTHON:-python3}
[ -n "$NOGEN" ] || $PY ../../tools/mkctx.py ../rtl/tv80/tv80_core.v ../rtl/tv80 8
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_o/tmp
	export TEMP="$(cygpath -m "$PWD")/work_o/tmp" TMP="$(cygpath -m "$PWD")/work_o/tmp"
	EXE=./tb_tv80o.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_tv80o ;;
esac
mkdir -p work_o
cat > work_o/tb.prj <<PRJ
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80_reg.v"
verilog work "../../rtl/tv80/tv80_core.v"
verilog work "../../rtl/tv80/tv80o_reg.v"
verilog work "../../rtl/tv80/tv80o_core.v"
verilog work "../../rtl/tv80/tv80_oct.v"
verilog work "../tb_tv80o.v"
PRJ
cd work_o
fuse -intstyle silent -incremental -prj tb.prj -o $EXE -d CLOCKS=$CLOCKS -d SEED=${SEED:-1} ${FUSE_DEFS} work.tb_tv80o > fuse.log 2>&1 || { tail -30 fuse.log; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -E "${SHOW:-tb_tv80o|differs|oct A|ERROR}" || true
grep -q "tb_tv80o: 0 errors" sim.log
