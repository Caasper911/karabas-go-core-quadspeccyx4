#!/bin/bash
# Timing test of tv80_oct alone on the XC6SLX25 (cpu8_top.v): ./run_timing.sh
# XST with the options of the core, map / par as the Makefile, then the minimum period of clk_bus (28.03 MHz,
# 35.7 ns) and the utilization. Regenerates tv80o_core.v / tv80o_reg.v first (tools/mkctx.py).
set -e -o pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3}
$PY ../../tools/mkctx.py ../rtl/tv80/tv80_core.v ../rtl/tv80 8
mkdir -p work/xst/projnav.tmp work/tmp
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	XILINX_DIR=${XILINX_DIR:-/c/Xilinx/14.7/ISE_DS}
	export XILINX="$XILINX_DIR/ISE" PATH="$XILINX_DIR/ISE/bin/nt64:$XILINX_DIR/ISE/lib/nt64:$XILINX_DIR/common/bin/nt64:$XILINX_DIR/common/lib/nt64:$PATH"
	export TEMP="$(cygpath -m "$PWD")/work/tmp" TMP="$(cygpath -m "$PWD")/work/tmp"
	export XILINXD_LICENSE_FILE=${XILINXD_LICENSE_FILE:-$(cygpath -m "$XILINX_DIR")/.xinstall/xilinx_ise.lic} ;;
*)
	source ${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh} > /dev/null ;;
esac
cat > cpu8.prj <<PRJ
verilog work "../../modules/rtl/clk/kg_pll.v"
verilog work "../rtl/tv80/tv80_alu.v"
verilog work "../rtl/tv80/tv80_mcode.v"
verilog work "../rtl/tv80/tv80o_reg.v"
verilog work "../rtl/tv80/tv80o_core.v"
verilog work "../rtl/tv80/tv80_oct.v"
verilog work "cpu8_top.v"
PRJ
xst -intstyle silent -ifn cpu8.xst -ofn work/cpu8.syr > /dev/null
cd work
ngdbuild -intstyle silent -dd _ngo -uc ../cpu8.ucf -p xc6slx25-ftg256-2 cpu8.ngc cpu8.ngd > ngdbuild.log
map -intstyle silent -p xc6slx25-ftg256-2 -w -logic_opt off -ol high -xe n -t 2 -xt 0 -register_duplication off \
	-r 4 -global_opt off -mt off -detail -ir off -pr b -lc off -power off -o cpu8_map.ncd cpu8.ngd cpu8.pcf > map.log
par -intstyle silent -w -ol high -xe n -mt 4 cpu8_map.ncd cpu8.ncd cpu8.pcf > par.log
trce -intstyle silent -v 3 -s 2 -n 3 -fastpaths -xml cpu8.twx cpu8.ncd -o cpu8.twr cpu8.pcf > trce.log
grep -E "Number of (Slice LUTs|occupied Slices|Slice Registers)|used as Memory" cpu8_map.mrp
grep -E "Minimum period is|constraints were met|Timing Score" cpu8.twr | head -6
