#!/bin/bash
# zx_oct after synthesis against the RTL (ISim): ./run_ps.sh [clocks]. XST with the options of the core (no I/O
# buffers, top zx_oct), netgen -sim, tb_ps.v boots the ROM 128 in both and compares every output every clock.
set -e -o pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3}
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$XILINX_DIR/common/bin/nt64:$XILINX_DIR/common/lib/nt64:$PATH"
	mkdir -p work_ps/tmp
	export TEMP="$(cygpath -m "$PWD")/work_ps/tmp" TMP="$(cygpath -m "$PWD")/work_ps/tmp"
	export XILINXD_LICENSE_FILE=${XILINXD_LICENSE_FILE:-$(cygpath -m "$XILINX_DIR")/.xinstall/xilinx_ise.lic}
	GLBL="$(cygpath -m "$XILINX")/verilog/src/glbl.v"
	EXE=./tb_ps.exe ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null
	GLBL="$XILINX/verilog/src/glbl.v"
	EXE=./tb_ps ;;
esac
mkdir -p work_ps/xst/projnav.tmp
$PY ../../tools/rom2hex.py ../roms/128.rom ../roms/48.rom work_ps/roms.hex
cd work_ps
cat > zx_oct.prj <<PRJ
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80o_reg.v"
verilog work "../../rtl/tv80/tv80o_core.v"
verilog work "../../rtl/zx/zx_oct.v"
PRJ
sed -e 's|work/xst|xst|g' -e 's|-ifn work/cpu8.prj|-ifn zx_oct.prj|' -e 's|-ofn work/cpu8|-ofn zx_oct|' \
	-e 's|-top cpu8_top|-top zx_oct|' -e 's|-iobuf YES|-iobuf NO|' ${XST_SED:+-e "$XST_SED"} ../../test/cpu8.xst > zx_oct.xst
xst -intstyle silent -ifn zx_oct.xst -ofn zx_oct.syr > /dev/null || { grep ERROR zx_oct.syr | head; exit 1; }
netgen -intstyle silent -sim -ofmt verilog -w zx_oct.ngc zx_oct_ps.v > netgen.log
sed -i 's/^module zx_oct /module zx_oct_ps /; s/^module zx_oct(/module zx_oct_ps(/' zx_oct_ps.v
cat > tb.prj <<PRJ
verilog work "../../rtl/tv80/tv80_alu.v"
verilog work "../../rtl/tv80/tv80_mcode.v"
verilog work "../../rtl/tv80/tv80o_reg.v"
verilog work "../../rtl/tv80/tv80o_core.v"
verilog work "../../rtl/zx/zx_oct.v"
verilog work "../../rtl/zx/zx_timing.v"
verilog work "../../rtl/mem/sram_ctrl.v"
verilog work "../../rtl/mem/sram_arb.v"
verilog work "zx_oct_ps.v"
verilog work "../sram_model.v"
verilog work "../tb_ps.v"
verilog work "$GLBL"
PRJ
fuse -intstyle silent -prj tb.prj -L unisims_ver -L simprims_ver -o $EXE -d CLOCKS=${1:-2000000} -d TRACE=${TRACE:-0} ${FUSE_DEFS} work.tb_ps work.glbl > fuse.log 2>&1 || { grep -E "ERROR" fuse.log | head -30; exit 1; }
printf 'run all\nquit\n' > run.tcl
$EXE -intstyle silent -tclbatch run.tcl | tee sim.log | grep -vE "^(Stopped|INFO|WARNING|ISim|This is|Time res|Simulator|Finished|---|\s*$)" | head -60 || true
grep -q "tb_ps: 0 errors" sim.log
