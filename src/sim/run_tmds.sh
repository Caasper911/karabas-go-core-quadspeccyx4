#!/bin/bash
# tmds_oserdes.v with the unisim models of PLL, BUFPLL, OSERDES2 (ISim): every word of the lanes read back.
set -e -o pipefail
cd "$(dirname "$0")"
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$PATH"
	mkdir -p work_t/tmp
	export TEMP="$(cygpath -m "$PWD")/work_t/tmp" TMP="$(cygpath -m "$PWD")/work_t/tmp"
	GLBL="$(cygpath -m "$XILINX")/verilog/src/glbl.v"
	EXE=./tb_tmds.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	GLBL="$XILINX/verilog/src/glbl.v"
	EXE=./tb_tmds ;;
esac
mkdir -p work_t
cat > work_t/tb.prj <<PRJ
verilog work "../../../modules/rtl/clk/kg_pll.v"
verilog work "../../rtl/video/tmds_oserdes.v"
verilog work "../tb_tmds.v"
verilog work "$GLBL"
PRJ
cd work_t
fuse -intstyle silent -prj tb.prj -L unisims_ver -o $EXE work.tb_tmds work.glbl > fuse.log 2>&1 || { grep -E "ERROR" fuse.log | head -20; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -E "tb_tmds|latency|word|only" | head -20
grep -q "tb_tmds: .* 0 errors" sim.log
