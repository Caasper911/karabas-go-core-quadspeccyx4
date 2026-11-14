#!/bin/bash
# The R register of tv80_core against the Z80 (tb_r.v, ISim). Prints "tb_r: ... 0 errors".
set -e -o pipefail
cd "$(dirname "$0")"
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_r/tmp
	export TEMP="$(cygpath -m "$PWD")/work_r/tmp" TMP="$(cygpath -m "$PWD")/work_r/tmp"
	EXE=./tb_r.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	EXE=./tb_r ;;
esac
mkdir -p work_r
printf 'verilog work "../../rtl/tv80/tv80_alu.v"\nverilog work "../../rtl/tv80/tv80_mcode.v"\nverilog work "../../rtl/tv80/tv80_reg.v"\nverilog work "../../rtl/tv80/tv80_core.v"\nverilog work "../tb_r.v"\n' > work_r/tb.prj
cd work_r
fuse -intstyle silent -prj tb.prj -o $EXE work.tb_r > fuse.log 2>&1 || { grep ERROR fuse.log | head; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -E "tb_r|LD A,R|flags"
grep -q "tb_r: .* 0 errors" sim.log
