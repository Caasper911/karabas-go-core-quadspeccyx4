`timescale 1ns / 1ps
`default_nettype none

/*
 speccywall.v

 SpeccyWall (docs/PLAN.md): sixteen Pentagon 128 on two engines (zx_oct, eight machines each: machine m = engine
 m[3], machine m[2:0] in it) in the SRAM (sram_arb: a queue per engine, sram_ctrl), on the screen the wall
 (1280 x 800: 4 x 4 cells, the paper of each machine at 1:1, wall_fetch reads the rows through the video port of
 sram_ctrl) or the selected machine full screen (zx_scr: its screen through the video port; 1280 x 800 at scale 3 or
 720 x 576), vga_out on the pixel clock; the keyboard, beeper and the one AY of the selected machine. Everything of the
 core but the board: karabas_go_top.v puts video, sound and the FT812 / MCU lines on its pins.

 Clocks:
   PLL 1 on CLK_50MHZ (VCO 925 MHz, as QuadSpeccy): clk_sys 84.09 MHz (/11, the write strobe of sram_ctrl), clk_bus
   28.03 MHz (/33: the machines, the MCU link, the line buffer writes), clk_8 7.97 MHz (/116, the FT812 of the Mini).
   A DCM on clk_bus: pclk = clk_bus * 21 / 8 = 73.6 MHz (CLKFX; CLK0 feedback, so pclk is aligned with clk_bus every 8
   of its clocks): the VGA raster, the OSD overlay, the DAC. Not a PLL: the XC6SLX25 has two, the second one is the
   HDMI of the Mini boards (x 10 on pclk, tmds_oserdes.v).

 Hotkeys (zx_kbd): Win + 1..8 the machine with the keyboard and the sound (Shift + Win + 1..8: 9..16), Win + arrows
 the machine next to it (4 columns, 4 rows), Win + ` the wall / the selected machine full screen (the wall after the start; 720 x 576 is always
 full screen).
 OSD (core.json "osd", the "index" of the items): 0 joystick L, 1 joystick R, 2 video (0 720 x 576, 1 1280 x 800: the default),
 3 reset of the selected machine (F12), 4 reset of all (Menu+F12), 5 the colour of the frame of the selected cell
 in the wall (0..7 ZX colours, default 4 green; 8 transparent: shown 1 s after a move), 6 NMI of the selected machine (F11), 7 AY mix (0 ABC, 1 ACB), as QuadSpeccy: 8 Tape in (0 Board: every
 machine hears TAPE_IN; 1 Core: every machine but the Tape out one hears the MIC of that one, it TAPE_IN), 9 Tape out
 (machine n: its MIC on TAPE_OUT; make_core allows 16 options, so no "selected"), 10 Keys to (0 the selected machine, 1 all, in the
 wall only). The diagnostics squares: parameter DIAG.

 ROM loader: the 32 KB of the shared ROM (128 editor at 0, 48 BASIC at 16384) written straight into the block RAM of
 zx_oct, the machines held in reset meanwhile.

 MCU: link v2 (kg_mcu2 of modules), MCU_INT on the IO1 line of the board.
*/

module speccywall #(
	parameter MEMTEST_AW = 21,          // the words of the SRAM self test (sram_test.v)
	parameter DIAG = 0                  // 1: the diagnostics squares of the bring-up (zx_scr, below) on the screen
) (
	input wire CLK_50MHZ,

	output wire clk_bus,
	output wire clk_8,
	output wire pclk,                   // the pixel clock: the VGA DAC takes the picture with it
	output wire areset,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MRD_N,
	output wire [1:0] MWR_N,

	input wire mcu_cs_n,
	input wire mcu_sck,
	input wire mcu_mosi,
	output wire mcu_miso,
	input wire mcu_ft_ss,
	input wire mcu_sd2_ss,
	output wire mcu_int,
	output wire dvi_only,

	output wire ft_spi_on,
	output wire ft_vga_on,
	output wire ft_sck,
	output wire ft_mosi,
	output wire ft_cs_n,
	output wire ft_reset,
	input wire ft_miso,

	input wire tape_in,
	output wire tape_out,
	output wire beeper,

	// the picture with the OSD (pclk), the syncs with the polarity of the raster
	output reg [7:0] video_r = 8'd0,
	output reg [7:0] video_g = 8'd0,
	output reg [7:0] video_b = 8'd0,
	output reg video_hs = 1'b1,
	output reg video_vs = 1'b1,
	output reg video_de = 1'b0,

	// the sound of the selected machine (clk_bus, signed)
	output reg [15:0] audio_l = 16'd0,
	output reg [15:0] audio_r = 16'd0
);

// ---------------------------------------------------------------------------------------------
// clocks

wire clk_sys, locked, locked_p;
wire [5:0] pll_clk;

kg_pll #(
	.DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37),
	.CLKOUT0_DIVIDE(11), .CLKOUT1_DIVIDE(33), .CLKOUT2_DIVIDE(116),
	.BUFG_MASK(6'b000101)
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(locked)
);
assign clk_sys = pll_clk[0];
assign clk_8 = pll_clk[2];
BUFG bufg_clk_bus(.I(pll_clk[1]), .O(clk_bus));

assign areset = ~locked;

// pclk = 28.03 * 21 / 8 = 73.6 MHz
kg_dcm #(.CLKIN_PERIOD(35.677), .CLKFX_MULTIPLY(21), .CLKFX_DIVIDE(8)) dcm_p(
	.clk_in(clk_bus),
	.rst(~locked),
	.clk_fx(pclk),
	.clk_fx180(),
	.clk_0(),
	.locked(locked_p)
);

// ---------------------------------------------------------------------------------------------
// MCU

wire [7:0] kb_status, kb_dat0, kb_dat1, kb_dat2, kb_dat3, kb_dat4, kb_dat5;
wire [15:0] mcu_joy_l, mcu_joy_r;
wire [5:0] mcu_btns;
wire [1:0] hw_btn = mcu_btns[1:0];
wire mcu_busy;
wire [1:0] ld_kind;
wire ld_active, ld_wr_mcu;
wire [31:0] ld_addr_mcu;
wire [7:0] ld_data_mcu;
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

// the OSD switches: 11 registers of 8 bits, switch n = softsw[n*8 +: 8]; SW_INIT the defaults of core.json
wire [11*8-1:0] softsw;

kg_mcu2 #(
	.CAPS(16'h0010),             // bit 4: LD_READY (always ready: the ROM is written a byte a clock)
	.SW_N(11),
	.SW_INIT(88'h00_00_00_00_00_04_00_00_01_01_00),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(0),
	.ENABLE_FT(1),
	.ENABLE_SD2(0)
) mcu (
	.CLK(clk_bus),
	.N_RESET(~areset),

	.MCU_SCK(mcu_sck),
	.MCU_MOSI(mcu_mosi),
	.MCU_MISO(mcu_miso),
	.MCU_SS(mcu_cs_n),
	.MCU_INT(mcu_int),
	.MCU_SPI_FT_SS(mcu_ft_ss),
	.MCU_SPI_SD2_SS(mcu_sd2_ss),

	.SW(softsw), .SW_WR(), .SW_INDEX(), .SW_VALUE(),
	.HW_ID(), .DVI_ONLY(dvi_only), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(mcu_busy),
	.BTNS(mcu_btns),
	.RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),

	.KBD({kb_dat5, kb_dat4, kb_dat3, kb_dat2, kb_dat1, kb_dat0, kb_status}), .KBD_WR(),
	.PS2_CODE(), .PS2_KIND(), .PS2_WR(),
	.MS_X(), .MS_Y(), .MS_Z(), .MS_B(), .MS_WR(),
	.JOY_L(mcu_joy_l), .JOY_R(mcu_joy_r), .JOY_WR(),
	.PS2_CMD(16'd0), .PS2_CMD_WR(1'b0),

	.LD_KIND(ld_kind), .LD_SLOT(), .LD_SIZE(), .LD_START(), .LD_ACTIVE(ld_active), .LD_END(),
	.LD_ADDR(ld_addr_mcu), .LD_DATA(ld_data_mcu), .LD_WR(ld_wr_mcu), .LD_READY(1'b1),

	.OSD_WR(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha),
	.OSD_PX(osd_px), .OSD_PY(osd_py), .OSD_PW(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

	.SDC_IMG_MOUNTED(), .SDC_IMG_SIZE(),
	.SDC_RD(8'd0), .SDC_WR(8'd0), .SDC_SECTOR(32'd0),
	.SDC_BUSY(), .SDC_DONE(), .SDC_ERROR(), .SDC_SLOT(),
	.SDC_BYTE_IN_STROBE(), .SDC_BYTE_ADDR(), .SDC_BYTE_IN_DATA(),
	.SDC_BYTE_OUT_DATA(8'd0),
	.IMG_WP(), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(), .FDD_CHNG_WR(), .FDD_CHNG(),
	.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0),
	.BK_MOUNT(1'b0), .BK_FLUSHED(1'b0), .BK_SLOT(3'd0), .BK_SIZE(32'd0), .BK_KIND(8'd0), .BK_RESULT(8'd0),
	.IMG_ACTIVE(),

	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'd0),
	.PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0), .PORT_CFG(128'd0), .PORT_IN_FULL(), .PORT_STAT(), .PORT_STAT_WR(),

	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_CS(1'b0), .RTC_WR_N(1'b1), .RTC_DO(),
	.MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0), .DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0),

	.FT_SPI_ON(ft_spi_on), .FT_VGA_ON(ft_vga_on), .FT_RESET(ft_reset),
	.FT_SCK(ft_sck), .FT_MOSI(ft_mosi), .FT_MISO(ft_miso), .FT_CS_N(ft_cs_n),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

wire [2:0] joy_type_l = softsw[2:0];
wire [2:0] joy_type_r = softsw[10:8];
wire sw_video = softsw[16];
wire sw_reset = softsw[24];
wire sw_reset_all = softsw[32];
wire [3:0] sw_frame_col = softsw[43:40];
wire sw_tape_core = softsw[64];         // Tape in: 0 Board, 1 Core
wire [3:0] sw_tape_out = softsw[75:72]; // Tape out: the machine
wire sw_keys_all = softsw[80];          // Keys to: 0 Selected, 1 All (the wall only)
wire sw_nmi = softsw[48];
wire sw_acb = softsw[56];

// ---------------------------------------------------------------------------------------------
// keyboard

wire [39:0] kbd_keys;
wire [7:0] kbd_kempston;
wire [3:0] kbd_sel;
wire kbd_full_tgl;

zx_kbd #(.ROWS(4)) kbd(
	.clk(clk_bus),
	.reset(areset),
	.kb_status(kb_status),
	.kb_dat0(kb_dat0),
	.kb_dat1(kb_dat1),
	.kb_dat2(kb_dat2),
	.kb_dat3(kb_dat3),
	.kb_dat4(kb_dat4),
	.kb_dat5(kb_dat5),
	.joy_type_l(joy_type_l),
	.joy_type_r(joy_type_r),
	.joy_l(mcu_joy_l[12:0]),
	.joy_r(mcu_joy_r[12:0]),
	.keys(kbd_keys),
	.kempston(kbd_kempston),
	.sel(kbd_sel),
	.full_tgl(kbd_full_tgl)
);

wire [3:0] sel = kbd_sel;
wire [2:0] sm = sel[2:0];             // the machine in its engine

// the wall or the selected machine full screen (Win + `); 720 x 576 has no wall
reg full = 1'b0;
always @(posedge clk_bus)
	if (kbd_full_tgl)
		full <= ~full;
wire show_full = full | ~sw_video;

// ---------------------------------------------------------------------------------------------
// resets: the loader, the start, Reset All (OSD, Menu+F12, the button 1) all machines; Reset (OSD, F12, button 0)
// the selected one. A reset lasts 255 clocks (32 T-states) at least: zx_oct clears the AY copy one register a T-state.

wire ld_hold = (ld_active && ld_kind == 2'd0) | mcu_busy;
wire mt_active;
wire rst_all = areset | ld_hold | sw_reset_all | hw_btn[1] | mt_active;
wire rst_sel = sw_reset | hw_btn[0];
reg [15:0] m_reset = 16'hFFFF;
reg [7:0] rst_cnt = 8'hFF;

always @(posedge clk_bus)
	if (rst_all || rst_sel) begin
		m_reset <= m_reset | (rst_all ? 16'hFFFF : (16'd1 << sel));
		rst_cnt <= 8'hFF;
	end else if (rst_cnt != 8'd0)
		rst_cnt <= rst_cnt - 1'd1;
	else
		m_reset <= 16'h0000;

// the ROM: kind 0, the first 32 KB of the address space of the MCU
wire rom_we = ld_wr_mcu && ld_kind == 2'd0 && ld_addr_mcu[31:15] == 17'd0;

// ---------------------------------------------------------------------------------------------
// the machines

wire ce7, ce_cpu, ce14, int_n, vga_half;
wire [8:0] hc, vc, vga_x;
wire [9:0] vga_p, vga_l;
wire [4:0] frame;

zx_timing timing(
	.clk(clk_bus), .reset(areset), .ce7(ce7), .ce_cpu(ce_cpu), .ce14(ce14), .hc(hc), .vc(vc), .int_n(int_n),
	.frame(frame), .vga_x(vga_x), .vga_half(vga_half), .vga_p(vga_p), .vga_l(vga_l)
);

reg [2:0] slot = 3'd0;
always @(posedge clk_bus)
	slot <= ce_cpu ? 3'd1 : slot + 1'd1;

wire [15:0] m_q;
wire [15:0] m_beeper, m_mic, m_late;
wire [2:0] v_border;
wire v_scr7;
wire ay_we;
wire [3:0] ay_wa, ay_ra;
wire [7:0] ay_wd, ay_rd;
wire [15:0] dbg_pc;
wire [5:0] dbg_7ffd, dbg_ev;

// the tape: TAPE_IN through two registers; Tape in = Board: every machine hears it; = Core: every machine but the Tape
// out one hears the MIC of that one (a SAVE there is a LOAD in the others), the Tape out one TAPE_IN (QuadSpeccy)
reg [1:0] tape_s = 2'b00;
always @(posedge clk_bus)
	tape_s <= {tape_s[0], tape_in};
wire [3:0] tape_core = sw_tape_out;
wire [15:0] m_tape_in;
genvar gt;
generate
	for (gt = 0; gt < 16; gt = gt + 1) begin : g_tape
		assign m_tape_in[gt] = (sw_tape_core && tape_core != gt) ? m_mic[tape_core] : tape_s[1];
	end
endgenerate

// the two engines: machines 0..7 (BASE 0: the first MB of the SRAM) and 8..15 (BASE 1)
wire [1:0] e_req, e_we, e_scr7, e_ayw;
wire [43:0] e_addr;
wire [15:0] e_din, e_aywd, e_ayrd;
wire [5:0] e_vb;
wire [7:0] e_aywa;
wire [31:0] e_pc;
wire [11:0] e_7ffd, e_ev;
wire a_rv, a_re;                     // a byte of a read from sram_arb: its engine, machine
wire [2:0] a_rm;
wire [7:0] a_rd;
wire [3:0] v_m;

genvar ge;
generate
	for (ge = 0; ge < 2; ge = ge + 1) begin : g_eng
		zx_oct #(.BASE(ge)) eng (
			.clk(clk_bus), .slot(slot), .int_n(int_n), .reset(m_reset[ge*8 +: 8]),
			.nmi((sw_nmi && sel[3] == ge) ? (8'd1 << sm) : 8'd0),
			.sel_en(sel[3] == ge), .sel(sm), .keys(kbd_keys), .keys_all(sw_keys_all & ~show_full),
			.tape_in(m_tape_in[ge*8 +: 8]), .kempston(kbd_kempston),
			.m_req(e_req[ge]), .m_we(e_we[ge]), .m_addr(e_addr[ge*22 +: 22]), .m_din(e_din[ge*8 +: 8]),
			.m_rv(a_rv && a_re == ge), .m_rm(a_rm), .m_rd(a_rd),
			.rom_we(rom_we), .rom_wa(ld_addr_mcu[14:0]), .rom_wd(ld_data_mcu),
			.beeper(m_beeper[ge*8 +: 8]), .mic(m_mic[ge*8 +: 8]),
			.v_m(v_m[2:0]), .v_border(e_vb[ge*3 +: 3]), .v_scr7(e_scr7[ge]),
			.ay_we(e_ayw[ge]), .ay_wa(e_aywa[ge*4 +: 4]), .ay_wd(e_aywd[ge*8 +: 8]), .ay_ra(ay_ra),
			.ay_rd(e_ayrd[ge*8 +: 8]), .late(m_late[ge*8 +: 8]),
			.dbg_pc(e_pc[ge*16 +: 16]), .dbg_7ffd(e_7ffd[ge*6 +: 6]), .dbg_ev(e_ev[ge*6 +: 6])
		);
	end
endgenerate

// the context read port of the engine of v_m, the AY and the debug of the engine of the selected machine
assign v_border = v_m[3] ? e_vb[5:3] : e_vb[2:0];
assign v_scr7 = v_m[3] ? e_scr7[1] : e_scr7[0];
assign ay_we = sel[3] ? e_ayw[1] : e_ayw[0];
assign ay_wa = sel[3] ? e_aywa[7:4] : e_aywa[3:0];
assign ay_wd = sel[3] ? e_aywd[15:8] : e_aywd[7:0];
assign ay_rd = sel[3] ? e_ayrd[15:8] : e_ayrd[7:0];
assign dbg_pc = sel[3] ? e_pc[31:16] : e_pc[15:0];
assign dbg_7ffd = sel[3] ? e_7ffd[11:6] : e_7ffd[5:0];
assign dbg_ev = sel[3] ? e_ev[11:6] : e_ev[5:0];

wire a_req, a_we;
wire [21:0] a_addr;
wire [7:0] a_din;
sram_arb arb(
	.clk(clk_bus),
	.e_req(e_req), .e_we(e_we), .e_addr(e_addr), .e_din(e_din),
	.c_req(a_req), .c_we(a_we), .c_addr(a_addr), .c_din(a_din), .q(m_q),
	.rv(a_rv), .re(a_re), .rm(a_rm), .rd(a_rd)
);

wire v_req, v_ack, s_req, w_req;
wire [20:0] v_addr, s_addr, w_addr;
wire [3:0] w_m;
// the video port and the context read port of the engines: the full screen reader or the wall reader
assign v_req = show_full ? s_req : w_req;
assign v_addr = show_full ? s_addr : w_addr;
assign v_m = show_full ? sel : w_m;

// the self test of the SRAM (bring-up): after the start of the core and at Reset All (OSD, Menu+F12, button 1), the
// machines in reset meanwhile
wire mt_done, mt_ok, mt_req, mt_we;
wire [15:0] mt_bad;
wire [20:0] mt_first;
wire [21:0] mt_addr;
wire [7:0] mt_din;
reg areset_d = 1'b1, rall_d = 1'b0;
always @(posedge clk_bus) begin
	areset_d <= areset;
	rall_d <= sw_reset_all | hw_btn[1];
end
wire mt_start = (areset_d & ~areset) | ((sw_reset_all | hw_btn[1]) & ~rall_d);

sram_test #(.AW(MEMTEST_AW)) mtest(
	.clk(clk_bus), .start(mt_start),
	.active(mt_active), .done(mt_done), .ok(mt_ok), .bad(mt_bad), .first(mt_first),
	.c_req(mt_req), .c_we(mt_we), .c_addr(mt_addr), .c_din(mt_din), .q(m_q)
);

sram_ctrl sram(
	.clk_bus(clk_bus), .clk_sys(clk_sys),
	.c_req(mt_active ? mt_req : a_req), .c_we(mt_active ? mt_we : a_we), .c_addr(mt_active ? mt_addr : a_addr),
	.c_din(mt_active ? mt_din : a_din),
	.v_req(v_req), .v_addr(v_addr), .v_ack(v_ack), .q(m_q),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
);

// ---------------------------------------------------------------------------------------------
// diagnostics of the bring-up (zx_scr: four rows of 16 squares in the top border, bit 15 on the left, green 1)
//   row 0: 15 PLL 2 locked, 14 the loader was active, 13 a ROM byte was written, 12 a non-zero ROM byte, 11 the loader
//          does not hold the machines now, 10 MCU not busy now, 9 machine sel not in reset now, 8 a CPU write to the
//          SRAM was made, 7 a CPU read of the SRAM gave a non-zero word, 6 a video read gave a non-zero word, 5 the
//          border of sel is not 0, 4 no late read (sticky), 3 the frame blinks (frame[4]), 2..0 sel
//   row 1: the SRAM self test: 15 done, 14 no error, 13 32768 ROM bytes written, 4..0 the first wrong word, bits 20..16
//   row 2: the self test: the data bits that were wrong
//   row 3: the self test: the first wrong word, bits 15..0
//   row 4 (bottom border): the address of the last opcode fetch of machine sel (taken at the start of the frame)
//   row 5: 15..10 #7FFD of sel, 9..7 its border, 6 a CPU read of the SRAM gave a non-zero word, 5..0 events of sel
//          since its reset (zx_oct dbg_ev: 5 INT acknowledge, 4 opcode from RAM, 3 I/O write, 2 memory write,
//          1 #7FFD write, 0 #FE write)

reg dg_ld = 1'b0, dg_rom = 1'b0, dg_romnz = 1'b0, dg_wr = 1'b0, dg_rdnz = 1'b0, dg_vnz = 1'b0, dg_late = 1'b0;
reg [15:0] dg_romcnt = 16'd0, dg_addr = 16'd0, dg_q = 16'd0;
reg [1:0] dg_rd = 2'b00, dg_v = 2'b00, dg_cap = 2'b00;
reg dg_arm = 1'b0;

always @(posedge clk_bus) begin
	dg_rd <= {dg_rd[0], a_req & ~a_we};
	dg_v <= {dg_v[0], v_ack};
	dg_cap <= {dg_cap[0], 1'b0};
	if (ld_active) dg_ld <= 1'b1;
	if (rom_we) begin
		dg_rom <= 1'b1;
		dg_romcnt <= dg_romcnt + 1'd1;
		if (ld_data_mcu != 8'd0) dg_romnz <= 1'b1;
	end
	if (a_req && a_we) dg_wr <= 1'b1;
	if (dg_rd[1] && m_q != 16'd0) dg_rdnz <= 1'b1;
	if (dg_v[1] && m_q != 16'd0) dg_vnz <= 1'b1;
	if (|m_late) dg_late <= 1'b1;
	if (ce7 && hc == 9'd0 && vc == 9'd0)
		dg_arm <= 1'b1;
	else if (dg_arm && a_req && !a_we && a_addr[20:17] == sel) begin
		dg_arm <= 1'b0;
		dg_addr <= a_addr[16:1];
		dg_cap[0] <= 1'b1;
	end
	if (dg_cap[1])
		dg_q <= m_q;
end

reg [15:0] dg_pc = 16'd0;
always @(posedge clk_bus)
	if (ce7 && hc == 9'd0 && vc == 9'd0)
		dg_pc <= dbg_pc;

wire [95:0] diag = {
	dbg_7ffd, v_border, dg_rdnz, dbg_ev, dg_pc, mt_first[15:0], mt_bad,
	mt_done, mt_ok, dg_romcnt == 16'h8000, 8'd0, mt_first[20:16],
	locked_p, dg_ld, dg_rom, dg_romnz, ~ld_hold, ~mcu_busy, ~m_reset[sel], dg_wr,
	dg_rdnz, dg_vnz, v_border != 3'd0, ~dg_late, frame[4], sm
};

// ---------------------------------------------------------------------------------------------
// video: the selected machine full screen

// the raster of the selected machine: machine m of an engine runs m clocks after machine 0 (its CPU in slot m, its INT taken in
// slot 0 as for all), so its picture is exact on the raster of zx_timing delayed by m clocks
reg [7:1] rd_ce7 = 7'd0, rd_fl = 7'd0;
reg [8:0] rd_hc [1:7];
reg [8:0] rd_vc [1:7];
integer ri;
initial for (ri = 1; ri < 8; ri = ri + 1) begin rd_hc[ri] = 9'd0; rd_vc[ri] = 9'd0; end
always @(posedge clk_bus) begin
	rd_ce7 <= {rd_ce7[6:1], ce7};
	rd_fl <= {rd_fl[6:1], frame[4]};
	rd_hc[1] <= hc;
	rd_vc[1] <= vc;
	for (ri = 2; ri < 8; ri = ri + 1) begin
		rd_hc[ri] <= rd_hc[ri - 1];
		rd_vc[ri] <= rd_vc[ri - 1];
	end
end
wire s_ce7 = (sm == 3'd0) ? ce7 : rd_ce7[sm];
wire [8:0] s_hc = (sm == 3'd0) ? hc : rd_hc[sm];
wire [8:0] s_vc = (sm == 3'd0) ? vc : rd_vc[sm];
wire s_fl = (sm == 3'd0) ? frame[4] : rd_fl[sm];

wire [3:0] pix;

zx_scr scr(
	.clk(clk_bus), .ce7(s_ce7), .hc(s_hc), .vc(s_vc), .flash(s_fl),
	.m(sel), .scr7(v_scr7), .border(v_border), .diag_en(DIAG != 0), .diag(diag),
	.v_req(s_req), .v_addr(s_addr), .v_ack(v_ack & show_full), .q(m_q),
	.pix(pix)
);

wire wb_we;
wire [6:0] wb_addr;
wire [31:0] wb_data;
wire [23:0] w_brd;

wall_fetch #(.ROWS(4)) wall(
	.clk(clk_bus), .en(~show_full), .ce7(ce7), .hc(hc), .vc(vc),
	.v_m(w_m), .v_border(v_border), .v_scr7(v_scr7),
	.v_req(w_req), .v_addr(w_addr), .v_ack(v_ack & ~show_full), .q(m_q),
	.wb_we(wb_we), .wb_addr(wb_addr), .wb_data(wb_data), .brd(w_brd)
);

wire [7:0] vo_r, vo_g, vo_b;
wire vo_hs, vo_vs, vo_de, hs_neg, vs_neg;

vga_out #(.ROWS(4)) vga(
	.clk(clk_bus), .ce7(ce7), .hc(hc), .vc(vc), .w_ce7(s_ce7), .w_hc(s_hc), .w_vc(s_vc), .pix(pix),
	.mode_i(sw_video),
	.wall_i(~show_full), .sel_i(sel), .flash_i(frame[4]), .frame_col(sw_frame_col),
	.wb_we(wb_we), .wb_addr(wb_addr), .wb_data(wb_data), .brd_i(w_brd),
	.pclk(pclk),
	.r(vo_r), .g(vo_g), .b(vo_b), .hs(vo_hs), .vs(vo_vs), .de(vo_de), .hs_neg(hs_neg), .vs_neg(vs_neg)
);

// the bitmap OSD of link v2, centred on de; it takes high active syncs and delays everything by 2 clocks
wire ov_hs, ov_vs, ov_de;
wire [23:0] ov_rgb;
// (a copy of kg_l2_osd_overlay with a horizontal scale: in 720 x 576 a pixel is 2.625 clocks of pclk, the OSD is 2 lines
// and 5 clocks an OSD pixel there; 1280 x 800 as the modules: from the area, 4)
osd_overlay overlay(
	.wclk(clk_bus),
	.osd_wr(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha),
	.osd_px(osd_px), .osd_py(osd_py), .osd_pw(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.s_force(sw_video ? 4'd0 : 4'd2), .sx_force(sw_video ? 4'd0 : 4'd5),
	.icon_on(8'd0), .icon_act(8'd0),
	.clk(pclk),
	.rgb_i({vo_r, vo_g, vo_b}), .hs_i(vo_hs), .vs_i(vo_vs), .de_i(vo_de),
	.rgb_o(ov_rgb), .hs_o(ov_hs), .vs_o(ov_vs), .de_o(ov_de)
);

// the output registers (the IOB of the pins): the blend of the overlay gets a whole clock in the fabric (with its
// output register in the IOB the path to the pin did not always meet the 13.6 ns)
always @(posedge pclk) begin
	{video_r, video_g, video_b} <= ov_rgb;
	video_hs <= ov_hs ^ hs_neg;
	video_vs <= ov_vs ^ vs_neg;
	video_de <= ov_de;
end

// ---------------------------------------------------------------------------------------------
// sound: beeper, MIC, tape input and the AY of the selected machine

// the AY: the writes of the selected machine; when sel changes its 16 registers are loaded from the copy in zx_oct
// (the writes of zx_oct go first, the loading waits for a clock without one)
reg [3:0] ay_sel = 4'd0;
reg [4:0] ay_ld = 5'd16;          // the register being loaded, 16: none
always @(posedge clk_bus)
	if (sel != ay_sel) begin
		ay_sel <= sel;
		ay_ld <= 5'd0;
	end else if (!ay_ld[4] && !ay_we)
		ay_ld <= ay_ld + 1'd1;
assign ay_ra = ay_ld[3:0];

wire [7:0] ch_a, ch_b, ch_c;
ay_psg ay(
	.clk(clk_bus),
	.we(ay_we | (!ay_ld[4] && sel == ay_sel)),
	.wa(ay_we ? ay_wa : ay_ld[3:0]),
	.wd(ay_we ? ay_wd : ay_rd),
	.ch_a(ch_a),
	.ch_b(ch_b),
	.ch_c(ch_c)
);

// ABC: left 2A + B, right 2C + B; ACB: left 2A + C, right 2B + C (as turbosound.v), x 16; the beeper 0x2000, MIC 0x800,
// the tape input 0x400 (QuadSpeccy)
wire [9:0] ay_l = {1'b0, ch_a, 1'b0} + (sw_acb ? ch_c : ch_b);
wire [9:0] ay_r = sw_acb ? {1'b0, ch_b, 1'b0} + ch_c : {1'b0, ch_c, 1'b0} + ch_b;
wire [15:0] beeps = {2'b00, m_beeper[sel], 1'b0, m_mic[sel], m_tape_in[sel], 10'd0};
always @(posedge clk_bus) begin
	audio_l <= beeps + {2'b00, ay_l, 4'd0};
	audio_r <= beeps + {2'b00, ay_r, 4'd0};
end

assign beeper = m_beeper[sel];
assign tape_out = m_mic[tape_core];

endmodule
