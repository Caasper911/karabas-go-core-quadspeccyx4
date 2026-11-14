#!/bin/bash
# Timing tests on the XC6SLX25: ./run_timing.sh [cpu8|wall8]
#   cpu8 (default)  tv80_oct alone (cpu8_top.v)
#   wall8           zx_oct, eight machines, with sram_ctrl on the SRAM pins of the Go (wall8_top.v)
# XST with the options of the core, map / par as the Makefile, then the utilization, the minimum periods (clk_bus
# 28.03 MHz = 35.7 ns) and whether all constraints are met. Regenerates tv80o_core.v / tv80o_reg.v first.
set -e -o pipefail
cd "$(dirname "$0")"
T=${1:-cpu8}
PY=${PYTHON:-python3}
$PY ../../tools/mkctx.py ../rtl/tv80/tv80_core.v ../rtl/tv80 8 > /dev/null
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

{
	echo 'verilog work "../../modules/rtl/clk/kg_pll.v"'
	echo 'verilog work "../rtl/tv80/tv80_alu.v"'
	echo 'verilog work "../rtl/tv80/tv80_mcode.v"'
	echo 'verilog work "../rtl/tv80/tv80o_reg.v"'
	echo 'verilog work "../rtl/tv80/tv80o_core.v"'
	case $T in
	cpu8)
		echo 'verilog work "../rtl/tv80/tv80_oct.v"' ;;
	wall8)
		echo 'verilog work "../rtl/zx/zx_timing.v"'
		echo 'verilog work "../rtl/zx/zx_oct.v"'
		echo 'verilog work "../rtl/mem/sram_ctrl.v"' ;;
	*)
		echo "unknown test $T" >&2; exit 1 ;;
	esac
	echo "verilog work \"${T}_top.v\""
} > work/$T.prj
sed -e "s/cpu8/$T/g" cpu8.xst > work/$T.xst

xst -intstyle silent -ifn work/$T.xst -ofn work/$T.syr > /dev/null || { grep ERROR work/$T.syr | head; exit 1; }
cd work
ngdbuild -intstyle silent -dd _ngo -uc ../$T.ucf -p xc6slx25-ftg256-2 $T.ngc $T.ngd > ngdbuild.log
map -intstyle silent -p xc6slx25-ftg256-2 -w -logic_opt off -ol high -xe n -t 2 -xt 0 -register_duplication off \
	-r 4 -global_opt off -mt off -detail -ir off -pr b -lc off -power off -o ${T}_map.ncd $T.ngd $T.pcf > map.log
par -intstyle silent -w -ol high -xe n -mt 4 ${T}_map.ncd $T.ncd $T.pcf > par.log
trce -intstyle silent -v 3 -s 2 -n 3 -fastpaths -xml $T.twx $T.ncd -o $T.twr $T.pcf > trce.log
grep -E "Number of (Slice LUTs|occupied Slices|Slice Registers|RAMB16BWERs|RAMB8BWERs)|used as Memory" ${T}_map.mrp
grep -E "^Timing constraint|Minimum period is|constraints were met|Timing Score|not met" $T.twr | head -20
