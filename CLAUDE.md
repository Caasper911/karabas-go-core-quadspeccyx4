# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

QuadSpeccyX4 for the Karabas Go / Mini / Mini G boards (Xilinx Spartan-6 XC6SLX25, ISE 14.7, XST): 16 Pentagon 128 on
one FPGA, shown on one screen (1280 x 800, frame locked to the Pentagon frame, 48.88 Hz: total 1568 x 960, pixel
clock 21/8 clk_bus = 73.6 MHz, 3 VGA lines per Spectrum line) as a 4 x 4 grid (paper 256 x 192 1:1, a 1 pixel
border) or the selected one full screen at scale 3 (decided 2026-11-14, docs/ARCHITECTURE.md "Видео"). Follows karabas-go-quadspeccy (`../karabas-go-quadspeccy`, 4 machines), but a machine is not a module
any more: one CPU and one bus logic serve eight machines, the state of each machine is a context in distributed
RAM. Board infrastructure as QuadSpeccy / karabas-go-core-tsconf: the git submodule `modules/`
(karabas-go-modules; its `modules/CLAUDE.md` has the rules: Verilog-2001 for XST, no coregen, tests), MCU link v2,
Makefile build, `core.json`.

Documentation (Russian) is part of the work: `docs/ARCHITECTURE.md` (what is built and the target design: memory,
video, resource budget), `docs/PLAN.md` (milestones with checkboxes, open questions), `README.md`. Update them in the
same change as the code they describe.

## State

Milestones 1 (the CPU), 2 (eight machines on SRAM), 3 (the first Go core), 4 (the wall) and 6 (16 machines) done;
milestone 5 (Mini / Mini G) done: works on all three boards (2026-11-15).
- DivMMC + SD (2026-11-15, docs/PLAN.md "DivMMC и SD-карта"; the user decided: all in SRAM, 128 KB DivMMC per machine,
  64 KB for the 16th, ROMs in the 64 KB left, one image for all): ROMs in SRAM at byte 0x3F0000 (128, 48, ESXDOS at
  0x3F8000; the block RAM ROMs are gone), DivMMC RAM at {1, BASE, m, bank 4, off 13}. `sram_arb` carries the machine
  of a request (`e_m` from `m_m` of zx_oct), not address bits. `rtl/sd/sd_oct.v`: the cards of an engine (kg_sd_emu's
  FSM in contexts, sector buffer 4 KB per engine, WAIT on an #EB read while the card waits: `c_ebw`);
  `rtl/sd/sd_host.v`: 16 cards on kg_mcu2 img slot 0 (ENABLE_IMG 1), 32-sector cache. DivMMC RAM cleared after start
  and Reset All (`dw_*` in quadspeccyx4.v).
- Milestone 5: `karabas_{mini,minig}_top.v` (QuadSpeccy's), HDMI `rtl/video/hdmi_out.v` = `hdmi_enc.vhd` (zhdmi_tx of
  the modules without its serializers, GPL) + `tmds_oserdes.v` (PLL x10 on pclk, BUFPLL, OSERDES2 master/slave per
  lane, XAPP495 style; the fabric serializer at 368 MHz failed). pclk now from a DCM (CLKFX 21/8 of clk_bus): the
  XC6SLX25 has two PLLs, the main one and the HDMI one. `src/sim/run_tmds.sh` checks the bit order of the serializer. Milestone 3: the first core for the Go
(`src/quadspeccyx4.kg`: eight machines, the selected one full screen, 720 x 576 or 1280 x 800) works on the Go
(2026-11-14; the user tests on the board).

- XST 14.7 mis-synthesized a context array written in both branches of `if (reset) ... else ...` (a RAM16X1D that
  wrote only zeros; no machine ran on the board). Write each context array with one assignment per clock (next
  values `n_*` combinational), and run `src/sim/run_ps.sh` (the XST netlist of zx_oct against the RTL) after changing
  context logic: the RTL tests cannot see this.

- Frame buffer of the wall (2026-11-15, the user wants exact multicolour in the cells, docs/ARCHITECTURE.md "Буфер
  кадра стены"): `rtl/video/zx_vid.v` per engine: the raster of machine g is 13 g T after zx_timing (STAGGER: 16
  rasters at once need 50 % of the SRAM in the paper, the CPUs take ~52 %), its INT too (zx_oct takes `int_n` of the
  CPU of the slot now; zx_oct gives the border / #7FFD of machine slot - 4, no `v_m`); slot gm + 4 draws two pixels of
  machine gm (screen pairs asked 4 T ahead through `rtl/video/vid_fetch.v` on the video port of sram_ctrl), the cell
  words (320 x 200, the left border from the line before) and the full screen pixels of the selected machine.
  `rtl/video/fb_sdram.v` (clk_sys): the SDRAM (timing of sdram_ctrl of QuadSpeccy, BL1, a command a clock: a cell line
  = ACTIVE + 80 words), triple buffered frames per machine (fw / fc / fd), the rows of the wall into a row buffer for
  vga_out. zx_scr.v and wall_fetch.v are gone.
- `src/rtl/quadspeccyx4.v` (the core) and `karabas_go_top.v`; `rtl/video/vga_out.v` (pclk = 21/8 clk_bus from a second
  PLL, 73.6 MHz, locked to the Pentagon frame, two rasters; the full screen from 4 line buffers written by zx_vid, the
  wall from the row buffer of fb_sdram), `rtl/hid/zx_kbd.v` / `rtl/sound/ay_psg.v` from QuadSpeccy
  (zx_kbd: sel 4 bits, Win+1..8, arrows on 4 columns x ROWS).
- Milestone 6 (16 machines) works on the Go (2026-11-14): two zx_oct (`g_eng`, BASE 0 / 1, machine m = engine m[3]),
  `rtl/mem/sram_arb.v` (a queue per engine, one SRAM access a clock, returns {engine, machine, byte}); zx_oct takes
  SRAM data with a variable latency (`m_rv`/`m_rm`/`m_rd` into context `c_ramd`; ROM fixed into `c_romd`;
  `c_fromrom` chooses). Shift+Win+1..8 = machines 9..16. 1885 slices (50 %), clk_bus 24.0 ns, pclk 13.19 of 13.59
  (the video outputs have their own register after the OSD overlay: the overlay blend into an IOB register failed).
- Milestone 4 (the wall): Win+` wall / full screen; 1280 x 800 is the default video (wall_fetch.v read the rows from
  the screens at VGA time until the frame buffer).

- `src/rtl/tv80`: tv80 (as QuadSpeccy, from karabas_go_v6z80p with its fixes, marked `karabas:`). `tv80_oct.v`: one
  tv80 for eight CPUs, ONE clock per CPU (slot k of 8 = cen of CPU k; a T-state is 8 clocks of clk_bus 28 MHz). The
  outputs of CPU k come from a second read port of its state in slot k + 1 (`pth = slot - 1`) and a second
  `tv80_mcode` for IORQ / NoRead / Write, kept until the next slot k + 1 (QuadSpeccy's `tv80_quad` needed a second
  "peek" clock per CPU instead).
- `tv80o_core.v` / `tv80o_reg.v` are GENERATED by `tools/mkctx.py` from `tv80_core.v` (`mkctx.py tv80_core.v
  <dir> [N]`, N = 8): never edit them; change the generator or `tv80_core.v` and run `src/sim/run_tv80o.sh`, which
  regenerates. The register file is not written while reset_n is low (the synchronous reset sees the old state in
  that clock; the asynchronous reference writes nothing).
- `src/rtl/zx/zx_oct.v`: eight Pentagon 128 on one `tv80o_core` and one bus logic, the machine state in contexts
  (distributed RAM indexed by the machine). Slot k = cen of CPU k (inputs from the contexts of machine k); slot k + 1
  = bus logic of machine k on the live outputs `p_*` (decode as `pentagon.v` of QuadSpeccy at `cen_d`). One memory
  request a clock at most, so no queue and no WAIT: a read at the start of T1 returns 3 clocks later (`c_mdat`), the
  CPU takes it 15 clocks after the request; the shared ROM (block RAM, 32 KB, loader port) is delayed to the same
  latency. RAM of machine m at SRAM byte {BASE, m, page, offset}. Ports #FE, #7FFD, AY copy (#FFFD / #BFFD, writes of
  the selected machine out), Kempston #1F, #5A73 (read only, all 16 bits: the machine number 0..15; 2026-11-17); INT = its value at slot 0 for all CPUs; a reset must last 16 T (AY clear).
- `src/rtl/mem/sram_ctrl.v`: the SRAM (2M x 16, 10 ns, MRD_N / MWR_N per byte), one access per clk_bus: MA / MRD_N
  in clk_bus IOB registers for the whole clock, the read word taken at the next clk_bus edge (35.7 ns, as TS-Conf);
  a write: MWR_N low from the 1st to the 2nd clk_sys edge of the clock, data from the 1st to the 3rd (clk_sys
  registers; the phase from a clk_bus toggle sampled on clk_sys). Video port takes clocks without a CPU request.
  Word q two clocks after the request clock.
- `src/rtl/zx/zx_timing.v`: the raster of QuadSpeccy (slot 0 = the clock of ce_cpu: `slot <= ce_cpu ? 1 : slot + 1`).

## Build

- `cd src && make` builds go, mini, minig into `quadspeccyx4.kg`; `make go` as QuadSpeccy (see its CLAUDE.md: MSYS2 make from Git Bash, `make_core.py` of the sibling
  `../karabas-go-tools`, `make go-report`). map sometimes stops in Global Placement without a message (as in
  QuadSpeccy): run make again. About 10 minutes. The `.bin` / `.kg`
  are the release, committed. Check the `.syr` Clock Information (pclk, clk_bus, clk_sys, MCU_SCK only).
- Measured (frame buffer + Win+F11, 2026-11-15): Go 2516 slices (66 %), Mini 2956 (78 %), Mini G 2919 (77 %), 19 RAMB16
  + 8 RAMB8; clk_bus 28.0-33.5 ns of 35.7, pclk 13.1-13.2 of 13.59, clk_sys 10.4-11.0 of 11.9. Placement moves these by
  a few ns from build to build.
- `src/sim/run_tv80o.sh [clocks]` (ISim of ISE 14.7, Windows or Linux; `PYTHON=python` on Windows): eight
  `tv80_core` against `tv80_oct` clock for clock on random code with random WAIT / INT / NMI / pauses / resets; all
  outputs every clock, the state (ACC, F, PC, SP, I, register file) once per T-state. Prints `tb_tv80o: 0 errors`.
  Env: `SEED=<n>`, `NOGEN=1` (keep a hand-mutated `tv80o_core.v`), `FUSE_DEFS="-d TRACE_CPU=k -d TRACE_FROM=<clock>"`
  with `SHOW=.` for a trace. Default 2 M clocks takes about 4 minutes.
- `src/test/run_timing.sh [cpu8]`: XST / map / par of `cpu8_top.v` (tv80_oct, the PLL of the core, LFSR inputs, outputs
  folded into one pin) on the XC6SLX25 with the options of QuadSpeccy; prints the utilization and the minimum
  period (clk_bus budget 35.7 ns). About 1 minute. Measured: 22.7-24.4 ns, 564-582 slices; `tv80_quad` in the same harness
  21.2 ns (31.4 ns inside the full QuadSpeccy core).
- `src/sim/run_wall.sh [clocks]`: `zx_oct` + `sram_ctrl` + `sram_model.v` (async SRAM with tAA, tWP, tAS / tAW /
  tDW / tDH and bus fight checks; X accesses of uninitialized CPU registers counted apart) against eight golden
  machines (`tv80_core` + a behavioural bus written again in `tb_wall.v`, writes at the start of T2 as the engine);
  all CPU outputs every T-state, at the end the 128 KB of each machine, border, beeper, MIC, #7FFD, AY registers;
  `late` never; a random video reader checked. `FUSE_DEFS="-d IDPORT"`: the random code reads the machine number
  port #5A73 every 32 bytes (both engines checked). Random code by default (2 M clocks ~ 4 min); `ROM=1` the ROM 128
  (~45 s per frame of 573440 clocks; machines out of reset 1000 T apart; `work_w/screens.png` via
  `tools/render_wall.py`); `SEED`, `FUSE_DEFS="-d WATCH=22'h<addr>"` traces the writes of one byte.
- `src/test/run_timing.sh wall8` (out of date: `wall8_top.v` has the ports of milestone 4, before sram_arb): `zx_oct` + `sram_ctrl` on the SRAM pins of the Go (`wall8.ucf` with the SRAM
  constraints of TS-Conf): 1679 LUT, 563 slices, 16 RAMB16, clk_bus 21.3 ns.
- `src/sim/run_video.sh [frames]`: the video path: two zx_vid + vid_fetch + sram_ctrl + the SRAM model (the CPU port
  as busy as 16 machines make it, `BUSY=0` random), fb_sdram + `sdram_model.v` (QuadSpeccy's, checks the SDRAM
  timing) + vga_out 1280 x 800; the border of each machine a function of its raster position and (`CFT=1`) its cell
  frame: every pixel of the wall against the memory / the function, a cell from one frame of its machine (no
  tearing); `NB=1` the wall without the border (OSD Wall border, Menu+B: the papers one field of 1024 x 768, black
  around; the frame shown of each cell row must change every VGA frame, so 6 frames); `WALL=0` the full screen of
  machine `FS`; late screen words, queue overflows, the longest wait of a
  screen word (21 clocks). About 1.6 min per frame.
- `src/sim/run_int.sh [frames]` (`SHORT=1`): the frame interrupt of the 16 machines: position (17988 T before the
  paper), 32 T, period, acknowledges per frame. `src/sim/run_sna.sh <file.sna> [frames]`: a 48K or 128K snapshot (the picture of each frame in work_s/screen.png)
  (`tools/sna2sim.py`: the RAM into machine 0, a 48 ROM with a loader of the registers in place of SA-BYTES) on the
  two engines; per frame the acknowledges and the ports. `src/sim/run_r.sh`: the R register of tv80_core against
  the Z80 (tv80 had no R without TV80_REFRESH: LD A,R = 0, fixed 2026-11-15; the tests compare R now).
- R after a reset is not 0 (user's request 2026-11-15): tv80_core input `rseed` (karabas change, 0 in tb_r / tv80_oct);
  zx_oct: a 16-bit LFSR every clock (`LFSR_INIT`, another per engine), `c_seed[m]` takes it in the bus slot while
  machine m is in reset, the CPU loads R = `c_seed[th]` in its reset slots. tb_wall gives the golden CPU what the
  engine loads in slot g (`g_rseed`); eng1 with the LFSR of eng (lock step).
- `src/sim/run_sd.sh [frames]`: 16 machines boot ESXDOS from an image (`tools/mkimg.py`, FAT16 of SYS / BIN from
  `../v6z80p/V6_SD_card`, `SDDIR`) through sd_host and a model of the file mounter (`LAT`, `STAGGER`); every byte a
  card gives of a sector against the image; `work_d/screens.png`. ~2 min per frame. The test ROM copy has ESXDOS's
  long loops shortened (power-on delay, RAM clears, the 12800-byte response poll; `FAST=0` the ROM as it is): without
  that the card is reached after ~25 frames, and after sector 0 ESXDOS probes the second card (#E7 bit 1) for ~60. tb_wall / tb_ps / tb_int / tb_sna have the card off (`sd_en` 0); `DIVMMC=1 run_wall.sh`
  checks the DivMMC map and ports, `FUSE_DEFS="-d DIVMMC" run_ps.sh` the netlist with ESXDOS.
- ISim 14.7 missed the write of the head entry of an empty queue through a continuous assignment / always @* of a
  memory word (`sram_arb` head): give such a mux an explicit sensitivity list with the pointers.
- `src/sim/run_ps.sh [clocks]`: (`FUSE_DEFS="-d INTROM"` the IM 1 program of tb_int, `-d SNA` the snapshot of
  work_ps/rom.hex, ram.hex) XST + netgen of zx_oct, tb_ps.v boots the ROM 128 in the netlist and the RTL, all
  outputs every clock (`TRACE=n` the first PC changes; `XST_SED` edits the XST options). 1.5 M clocks ~10 min.
- `src/sim/run_core.sh [clocks]`: the whole core (PLLs, kg_mcu2 idle, busy forced off) on the SRAM model, prints
  the diagnostics vector every 100 000 clocks; slow (~100 k clocks a minute or two).
- ISim 14.7 has no `$writememh` / `$clog2`.
