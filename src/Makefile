# Command line build of the SpeccyWall core (ISE 14.7), after karabas-go-core-tsconf/src/Makefile.
#
#   make                 all the boards (speccywall.kg): Karabas Go for now
#   make go             one board: synthesis, implementation, bitstream, its part of speccywall.kg
#   make go-xst          one step: <board>-xst (.ngc), <board>-impl (.bin), <board>-core (.kg)
#   make go-report       LUTs, slices, block RAMs and the timing result of the last build
#   tail -f karabas_go_build.log   the progress of a build: every ISE step writes there too (the synthesis
#                        starts it again, each step adds a header with the time)
#   make clean          the intermediate files (not the .bin / .kg files, they are in git)
#
# Inputs per board: karabas_<board>.prj (the source list, the shared modules as "../modules/rtl/..."),
# .xst, .ucf, .ut. A step runs again when one of its inputs is newer than its output.
#
# ISE: Linux sources $(ISE_SETTINGS); Windows (MSYS2 / Git Bash make) runs the nt64 binaries of
# $(XILINX_DIR) and the 32-bit bitgen (the nt64 one fails on Windows 10).

PART = xc6slx25-ftg256-2
BOARDS = go

SHELL = /bin/bash
.SHELLFLAGS = -e -o pipefail -c
.NOTPARALLEL:

UNAME := $(shell uname -s)
ifneq ($(filter MINGW% MSYS% CYGWIN%,$(UNAME)),)
XILINX_DIR ?= /c/Xilinx/14.7/ISE_DS
ISE_BIN ?= $(XILINX_DIR)/ISE/bin/nt64
BITGEN_BIN ?= $(XILINX_DIR)/ISE/bin/nt
# MSYS2 make started from Git Bash passes no TEMP / TMP / XILINXD_LICENSE_FILE to its recipes (the two
# msys runtimes); ISE needs a temp dir and map / par the license (Windows paths)
ISE_TMP := $(shell cygpath -m "$(CURDIR)")/xst/tmp
ISE_LIC ?= $(shell cygpath -m "$(XILINX_DIR)")/.xinstall/xilinx_ise.lic
ISE_ENV = mkdir -p xst/tmp; export TEMP="$(ISE_TMP)" TMP="$(ISE_TMP)" XILINXD_LICENSE_FILE="$(ISE_LIC)"
XIL = $(ISE_ENV) XILINX="$(XILINX_DIR)/ISE" PATH="$(ISE_BIN):$(XILINX_DIR)/ISE/lib/nt64:$(XILINX_DIR)/common/bin/nt64:$(XILINX_DIR)/common/lib/nt64:$$$$PATH";
XIL_BITGEN = $(ISE_ENV) XILINX="$(XILINX_DIR)/ISE" PATH="$(BITGEN_BIN):$(XILINX_DIR)/ISE/lib/nt:$(XILINX_DIR)/common/bin/nt:$(XILINX_DIR)/common/lib/nt:$$$$PATH";
PYTHON ?= python
# the same make passes no USERPROFILE / APPDATA / LOCALAPPDATA either: without them the Python install manager
# behind `python` installs a new Python into the current directory
WIN_HOME := $(shell cygpath -m "$(HOME)")
export USERPROFILE ?= $(WIN_HOME)
export APPDATA ?= $(WIN_HOME)/AppData/Roaming
export LOCALAPPDATA ?= $(WIN_HOME)/AppData/Local
else
ISE_SETTINGS ?= /opt/Xilinx/14.7/ISE_DS/settings64.sh
# settings64.sh takes the arguments of the shell that sources it: none here
XIL = source $(ISE_SETTINGS) > /dev/null;
XIL_BITGEN = $(XIL)
PYTHON ?= python3
endif

# karabas-go-tools must be checked out next to this repository
MAKE_CORE ?= ../../karabas-go-tools/make_core/make_core.py
KG = speccywall.kg
JSON = core.json

MAP_T_go = 2


# map single-threaded (-mt off): with -mt 2 map crashed now and then in its Global Placement without a message (four
# times in a day, then on every run of one netlist; the same netlist went through with -mt off)
MAP_OPT = -logic_opt off -ol high -xe n -xt 0 -register_duplication off -r 4 -global_opt off -mt off -detail -ir off -pr b -lc off -power off
PAR_OPT = -ol high -xe n -mt 4

# included or read by the sources, not in the prj
INCLUDES = $(wildcard ../modules/rtl/mcu/*.vh)

.PHONY: all clean $(BOARDS) $(BOARDS:=-xst) $(BOARDS:=-impl) $(BOARDS:=-core) $(BOARDS:=-report)

all: $(BOARDS)

define board
SRC_$(1) := $$(shell sed -n 's/^[a-z]* work "\(.*\)"/\1/p' karabas_$(1).prj)

karabas_$(1).ngc: karabas_$(1).prj karabas_$(1).xst $$(SRC_$(1)) $(INCLUDES)
	mkdir -p xst/projnav.tmp
	echo "=== $$$$(date '+%F %T') karabas_$(1): synthesis" > karabas_$(1)_build.log
	$(XIL) xst -intstyle ise -ifn karabas_$(1).xst -ofn karabas_$(1).syr 2>&1 | tee -a karabas_$(1)_build.log

karabas_$(1).bin: karabas_$(1).ngc karabas_$(1).ucf karabas_$(1).ut
	echo "=== $$$$(date '+%T') ngdbuild" | tee -a karabas_$(1)_build.log
	$(XIL) ngdbuild -intstyle ise -dd _ngo -nt timestamp -uc karabas_$(1).ucf -p $(PART) karabas_$(1).ngc karabas_$(1).ngd 2>&1 | tee -a karabas_$(1)_build.log
	echo "=== $$$$(date '+%T') map" | tee -a karabas_$(1)_build.log
	$(XIL) map -intstyle ise -p $(PART) -w $(MAP_OPT) -t $(MAP_T_$(1)) -o karabas_$(1)_map.ncd karabas_$(1).ngd karabas_$(1).pcf 2>&1 | tee -a karabas_$(1)_build.log
	echo "=== $$$$(date '+%T') par" | tee -a karabas_$(1)_build.log
	$(XIL) par -w -intstyle ise $(PAR_OPT) karabas_$(1)_map.ncd karabas_$(1).ncd karabas_$(1).pcf 2>&1 | tee -a karabas_$(1)_build.log
	echo "=== $$$$(date '+%T') trce" | tee -a karabas_$(1)_build.log
	$(XIL) trce -intstyle ise -v 3 -s 2 -n 3 -fastpaths -xml karabas_$(1).twx karabas_$(1).ncd -o karabas_$(1).twr karabas_$(1).pcf -ucf karabas_$(1).ucf 2>&1 | tee -a karabas_$(1)_build.log
	echo "=== $$$$(date '+%T') bitgen" | tee -a karabas_$(1)_build.log
	rm -f karabas_$(1).bin karabas_$(1).bit
	{ $(XIL_BITGEN) bitgen -intstyle ise -f karabas_$(1).ut karabas_$(1).ncd || \
		{ test -s karabas_$(1).bin && echo "bitgen failed after it wrote karabas_$(1).bin (ISE 14.7 on Windows 10), taken"; }; } 2>&1 | tee -a karabas_$(1)_build.log
	echo "=== $$$$(date '+%T') done: karabas_$(1).bin" | tee -a karabas_$(1)_build.log

kg_$(1).stamp: karabas_$(1).bin $(JSON) $$(wildcard roms/*)
	$(PYTHON) $(MAKE_CORE) $(JSON) $(KG) --boards $(1) 2>&1 | tee -a karabas_$(1)_build.log
	touch $$@

$(1): kg_$(1).stamp
$(1)-xst: karabas_$(1).ngc
$(1)-impl: karabas_$(1).bin
$(1)-core: kg_$(1).stamp
$(1)-report:
	@grep -E "Number of (Slice LUTs|occupied Slices|RAMB16BWERs|RAMB8BWERs):" karabas_$(1)_map.mrp
	@grep -E "constraints? (was|were) met|constraints? not met|Timing Score" karabas_$(1).par | sort -u
endef

$(foreach b,$(BOARDS),$(eval $(call board,$(b))))

clean:
	rm -f kg_*.stamp
	rm -rf xst _ngo _xmsgs xlnx_auto_0_xdb iseconfig
	rm -f $(foreach b,$(BOARDS),$(addprefix karabas_$(b),.ngc .ngd .ngr .syr .lso .bld .pcf .ncd _map.ncd _map.ngm \
		_map.map _map.mrp _map.xrpt .par .pad _pad.csv _pad.txt .twr .twx .unroutes .xpi .ptwx .bgn .bit .drc \
		_bitgen.xwbt _summary.xml _usage.xml _xst.xrpt _ngdbuild.xrpt _par.xrpt _guide.ncd))
	rm -f usage_statistics_webtalk.html webtalk.log webtalk_pn.xml par_usage_statistics.html
