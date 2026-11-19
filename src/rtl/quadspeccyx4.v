`timescale 1ns / 1ps
`default_nettype none

/*
 quadspeccyx4.v

 QuadSpeccyX4 (docs/PLAN.md): sixteen Pentagon 128 on two engines (zx_oct, eight machines each: machine m = engine
 m[3], machine m[2:0] in it) in the SRAM (sram_arb: a queue per engine, sram_ctrl). The video: each machine draws its
 picture on its own raster (zx_vid.v in each engine, the rasters staggered, the screens read through vid_fetch and the
 video port of sram_ctrl); the cells of the wall go into the frame buffer in the SDRAM (fb_sdram.v), vga_out shows
 the wall (1280 x 800: 4 x 4 cells of 320 x 200) from there, or the selected machine full screen from its line
 buffers (1280 x 800 at scale 3 or 720 x 576); the keyboard, beeper and the one AY of the selected machine.
 Everything of the core but the board: karabas_go_top.v puts video, sound, the SDRAM and the FT812 / MCU lines on its
 pins.

 Clocks:
   PLL 1 on CLK_50MHZ (VCO 925 MHz, as QuadSpeccy): clk_sys 84.09 MHz (/11, the write strobe of sram_ctrl, the SDRAM), clk_bus
   28.03 MHz (/33: the machines, the MCU link, the line buffer writes), clk_8 7.97 MHz (/116, the FT812 of the Mini).
   A DCM on clk_bus: pclk = clk_bus * 21 / 8 = 73.6 MHz (CLKFX; CLK0 feedback, so pclk is aligned with clk_bus every 8
   of its clocks): the VGA raster, the OSD overlay, the DAC. Not a PLL: the XC6SLX25 has two, the second one is the
   HDMI of the Mini boards (x 10 on pclk, tmds_oserdes.v).

 Hotkeys (zx_kbd): Win + 1..8 the machine with the keyboard and the sound (Shift + Win + 1..8: 9..16), Win + arrows
 the machine next to it (4 columns, 4 rows), Win + F11 NMI of all machines, Win + ` the wall / the selected machine full screen (the wall after the start; 720 x 576 is always
 full screen).
 OSD (core.json "osd", the "index" of the items): 0 joystick L, 1 joystick R, 2 video (0 720 x 576, 1 1280 x 800 locked to the Pentagon frame,
 48.88 Hz, 2 1280 x 800 at 60 Hz: the default),
 3 reset of the selected machine (F12), 4 reset of all (Menu+F12), 5 the colour of the frame of the selected cell
 in the wall (0..7 ZX colours, default 4 green), 6 NMI of the selected machine (F11), 7 AY mix (0 ABC, 1 ACB), as QuadSpeccy: 8 Tape in (0 Board: every
 machine hears TAPE_IN; 1 Core: every machine but the Tape out one hears the MIC of that one, it TAPE_IN), 9 Tape out
 (machine n: its MIC on TAPE_OUT; make_core allows 16 options, so no "selected"), 10 Keys to (0 the selected machine, 1 all, in the
 wall only), 11 Frame fade (0 off, 1 the frame hides 2 s after a choice of a machine, as QuadSpeccy), 12 DivMMC, 13 NMI of all
 machines (Menu+F11: the item is before NMI in core.json, the firmware takes the first item that matches), 14 Wall
 border (Menu+B; 0 shown, 1 hidden: the papers side by side, one field of 1024 x 768, vga_out nb_i).
 The diagnostics squares: parameter DIAG.

 ROM loader: the 32 KB of the shared ROM (128 editor at 0, 48 BASIC at 16384) written straight into the block RAM of
 zx_oct, the machines held in reset meanwhile.

 MCU: link v2 (kg_mcu2 of modules), MCU_INT on the IO1 line of the board.
*/

module quadspeccyx4 #(
	parameter MEMTEST_AW = 21,          // the words of the SRAM self test (sram_test.v)
	parameter DIAG = 0                  // 1: the diagnostics squares of the bring-up (below) on the full screen
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

	output wire SDR_CLK,
	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire [1:0] SDR_DQM,
	output wire SDR_RAS_N,
	output wire SDR_CAS_N,
	output wire SDR_WE_N,
	inout wire [15:0] SDR_DQ,

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

// the OSD switches: 15 registers of 8 bits, switch n = softsw[n*8 +: 8]; SW_INIT the defaults of core.json
wire [15*8-1:0] softsw;

// the file mounter, slot 0: the image of the SD cards of all machines (sd_host, below)
wire [7:0] sdc_img_mounted;
wire [63:0] sdc_img_size;
wire sdc_rd, sdc_wr, sdc_busy, sdc_done, sdc_error, sdc_strobe;
wire [31:0] sdc_sector;
wire [8:0] sdc_byte_addr;
wire [7:0] sdc_byte_in, sdc_byte_out;

kg_mcu2 #(
	.CAPS(16'h0010),             // bit 4: LD_READY (always ready: the ROM is written a byte a clock)
	.SW_N(15),
	.SW_INIT(120'h00_00_01_00_00_00_00_00_00_04_00_00_01_01_00),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(1),                 // slot 0: the image of the SD cards (sd_host)
	.IMG_OUT_LATENCY(3),
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

	.SDC_IMG_MOUNTED(sdc_img_mounted), .SDC_IMG_SIZE(sdc_img_size),
	.SDC_RD({7'd0, sdc_rd}), .SDC_WR({7'd0, sdc_wr}), .SDC_SECTOR(sdc_sector),
	.SDC_BUSY(sdc_busy), .SDC_DONE(sdc_done), .SDC_ERROR(sdc_error), .SDC_SLOT(),
	.SDC_BYTE_IN_STROBE(sdc_strobe), .SDC_BYTE_ADDR(sdc_byte_addr), .SDC_BYTE_IN_DATA(sdc_byte_in),
	.SDC_BYTE_OUT_DATA(sdc_byte_out),
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
wire [1:0] sw_video = softsw[17:16];   // 0 720 x 576, 1 1280 x 800 48.88 Hz, 2 1280 x 800 60 Hz
wire sw_reset = softsw[24];
wire sw_reset_all = softsw[32];
wire [2:0] sw_frame_col = softsw[42:40];
wire sw_fade = softsw[88];              // Frame fade: 0 off, 1 on
wire sw_noborder = softsw[112];         // Wall border: 0 shown, 1 hidden (the papers one field of 1024 x 768)
wire sw_divmmc = softsw[96];            // DivMMC: 0 off, 1 on (all machines)
wire sw_tape_core = softsw[64];         // Tape in: 0 Board, 1 Core
wire [3:0] sw_tape_out = softsw[75:72]; // Tape out: the machine
wire sw_keys_all = softsw[80];          // Keys to: 0 Selected, 1 All (the wall only)
wire sw_nmi = softsw[48];
wire sw_nmi_all = softsw[104];         // NMI All (Menu+F11): all machines, as Win+F11 of zx_kbd
wire sw_acb = softsw[56];

// ---------------------------------------------------------------------------------------------
// keyboard

wire [39:0] kbd_keys;
wire [7:0] kbd_kempston;
wire [3:0] kbd_sel;
wire kbd_full_tgl, kbd_sel_hit, kbd_nmi_all;

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
	.full_tgl(kbd_full_tgl),
	.nmi_all(kbd_nmi_all),
	.sel_hit(kbd_sel_hit)
);

wire [3:0] sel = kbd_sel;
wire [2:0] sm = sel[2:0];             // the machine in its engine

// the wall or the selected machine full screen (Win + `); 720 x 576 has no wall
reg full = 1'b0;
always @(posedge clk_bus)
	if (kbd_full_tgl)
		full <= ~full;
wire show_full = full | (sw_video == 2'd0);

// ---------------------------------------------------------------------------------------------
// resets: the loader, the start, Reset All (OSD, Menu+F12, the button 1) all machines; Reset (OSD, F12, button 0)
// the selected one. A reset lasts 255 clocks (32 T-states) at least: zx_oct clears the AY copy one register a T-state.

wire ld_hold = (ld_active && ld_kind == 2'd0) | mcu_busy;
wire mt_active;
// the DivMMC RAM of every machine cleared after the start and after Reset All (as QuadSpeccy: ESXDOS boots on what
// it finds there), a byte a clock (73 ms; the ROM loader and the self test first), the machines held meanwhile
reg [20:0] dw_a = 21'd0;
reg dw_on = 1'b0, dw_d = 1'b0;
wire dw_trig = areset | sw_reset_all | hw_btn[1];
wire dw_we;
always @(posedge clk_bus) begin
	dw_d <= dw_trig;
	if (dw_d && !dw_trig) begin
		dw_on <= 1'b1;
		dw_a <= 21'd0;
	end else if (dw_we) begin
		dw_a <= dw_a + 1'd1;
		if (dw_a == 21'h1EFFFF)                    // below the ROMs ({111111, ...})
			dw_on <= 1'b0;
	end
end
wire rst_all = areset | ld_hold | sw_reset_all | hw_btn[1] | mt_active | dw_on;
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
// the ROMs (core.json: 128 at 0, 48 at 4000, ESXDOS at 8000) go into the SRAM, {111111, address} (zx_oct), a byte a
// clock while the loader holds the machines in reset
wire rom_we = ld_wr_mcu && ld_kind == 2'd0 && ld_addr_mcu[31:16] == 16'd0 && ld_addr_mcu[15:13] < 3'd5;

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
reg [2:0] v_border = 3'd0;          // the border of the selected machine (diagnostics)
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

// the two engines: machines 0..7 (BASE 0: the first MB of the SRAM) and 8..15 (BASE 1), each with its video (zx_vid)
wire [1:0] e_int, f_req, r_v, fw_we, fl_done, e_pwe;
wire [41:0] f_addr;
wire [7:0] f_tag;
wire [3:0] r_tag;
wire [15:0] r_q, e_vlate;
wire [21:0] fw_addr;
wire [31:0] fw_data;
wire [5:0] fl_m;
wire [15:0] fl_lc;
wire [19:0] e_pa;
wire [15:0] e_pd;
wire [17:0] e_pv, e_pe;
wire [1:0] e_req, e_we, e_scr7, e_ayw;
wire [43:0] e_addr;
wire [15:0] e_din, e_aywd, e_ayrd;
wire [5:0] e_vb, e_m;
wire [7:0] e_aywa;
wire [31:0] e_pc;
wire [11:0] e_7ffd, e_ev;
wire a_rv, a_re;                     // a byte of a read from sram_arb: its engine, machine
wire [2:0] a_rm;
wire [7:0] a_rd;

// the SD cards of the engines (sd_oct in zx_oct) on the one image (sd_host)
wire [15:0] h_pend, h_wr, h_q;
wire [63:0] h_lba;
wire [2:0] h_m;
wire [1:0] h_done, h_we;
wire [8:0] h_a;
wire [7:0] h_d;
wire [21:0] sd_csize;
sd_host sdh (
	.clk(clk_bus), .pend(h_pend), .wr(h_wr), .h_m(h_m), .lba(h_lba), .done(h_done), .we(h_we), .a(h_a), .d(h_d),
	.q(h_q), .img_mounted(sdc_img_mounted[0]), .img_size(sdc_img_size), .sdc_rd(sdc_rd), .sdc_wr(sdc_wr),
	.sdc_sector(sdc_sector), .sdc_busy(sdc_busy), .sdc_done(sdc_done), .sdc_error(sdc_error),
	.sdc_byte_in_strobe(sdc_strobe), .sdc_byte_addr(sdc_byte_addr), .sdc_byte_in_data(sdc_byte_in),
	.sdc_byte_out_data(sdc_byte_out), .c_size(sd_csize), .active()
);

genvar ge;
generate
	for (ge = 0; ge < 2; ge = ge + 1) begin : g_eng
		// the video of the engine: the rasters of its machines, their INT, pictures, screen reads
		zx_vid #(.BASE(ge)) vid (
			.clk(clk_bus), .slot(slot), .hc(hc), .vc(vc), .frame(frame), .int_th(e_int[ge]),
			.gm(), .g_border(e_vb[ge*3 +: 3]), .g_scr7(e_scr7[ge]),
			.f_req(f_req[ge]), .f_addr(f_addr[ge*21 +: 21]), .f_tag(f_tag[ge*4 +: 4]), .r_v(r_v[ge]), .r_tag(r_tag),
			.r_q(r_q),
			.w_we(fw_we[ge]), .w_addr(fw_addr[ge*11 +: 11]), .w_data(fw_data[ge*16 +: 16]), .l_done(fl_done[ge]),
			.l_m(fl_m[ge*3 +: 3]), .l_lc(fl_lc[ge*8 +: 8]),
			.fs_en(sel[3] == ge), .fs_m(sm), .p_we(e_pwe[ge]), .p_addr(e_pa[ge*10 +: 10]), .p_data(e_pd[ge*8 +: 8]),
			.p_v(e_pv[ge*9 +: 9]), .p_e(e_pe[ge*9 +: 9]), .late(e_vlate[ge*8 +: 8])
		);

		zx_oct #(.BASE(ge)) eng (
			.clk(clk_bus), .slot(slot), .int_n(e_int[ge]), .reset(m_reset[ge*8 +: 8]),
			.nmi(((sw_nmi && sel[3] == ge) ? (8'd1 << sm) : 8'd0) | {8{kbd_nmi_all | sw_nmi_all}}),
			.sel_en(sel[3] == ge), .sel(sm), .keys(kbd_keys), .keys_all(sw_keys_all & ~show_full),
			.tape_in(m_tape_in[ge*8 +: 8]), .kempston(kbd_kempston),
			.m_req(e_req[ge]), .m_we(e_we[ge]), .m_addr(e_addr[ge*22 +: 22]), .m_din(e_din[ge*8 +: 8]),
			.m_m(e_m[ge*3 +: 3]), .m_rv(a_rv && a_re == ge), .m_rm(a_rm), .m_rd(a_rd),
			.divmmc_en(sw_divmmc), .dv_clear(areset | ld_hold),
			.sd_en(1'b1), .sd_csize(sd_csize), .h_pend(h_pend[ge*8 +: 8]), .h_wr(h_wr[ge*8 +: 8]), .h_m(h_m),
			.h_lba(h_lba[ge*32 +: 32]), .h_done(h_done[ge]), .h_we(h_we[ge]), .h_a(h_a), .h_d(h_d),
			.h_q(h_q[ge*8 +: 8]),
			.beeper(m_beeper[ge*8 +: 8]), .mic(m_mic[ge*8 +: 8]),
			.v_border(e_vb[ge*3 +: 3]), .v_scr7(e_scr7[ge]),
			.ay_we(e_ayw[ge]), .ay_wa(e_aywa[ge*4 +: 4]), .ay_wd(e_aywd[ge*8 +: 8]), .ay_ra(ay_ra),
			.ay_rd(e_ayrd[ge*8 +: 8]), .late(m_late[ge*8 +: 8]),
			.dbg_pc(e_pc[ge*16 +: 16]), .dbg_7ffd(e_7ffd[ge*6 +: 6]), .dbg_ev(e_ev[ge*6 +: 6])
		);
	end
endgenerate

// the AY and the debug of the engine of the selected machine
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
	.e_req(e_req), .e_we(e_we), .e_addr(e_addr), .e_din(e_din), .e_m(e_m),
	.c_req(a_req), .c_we(a_we), .c_addr(a_addr), .c_din(a_din), .q(m_q),
	.rv(a_rv), .re(a_re), .rm(a_rm), .rd(a_rd)
);

// the screen reads of the engines on the video port of the SRAM
wire v_req, v_ack, vf_over;
wire [20:0] v_addr;
vid_fetch vfetch(
	.clk(clk_bus), .f_req(f_req), .f_addr(f_addr), .f_tag(f_tag),
	.v_req(v_req), .v_addr(v_addr), .v_ack(v_ack), .q(m_q),
	.r_v(r_v), .r_tag(r_tag), .r_q(r_q), .over(vf_over)
);

// the self test of the SRAM (bring-up): after the start of the core only (at Reset All it held the machines and the
// video port 0.2 s; the user wants Reset All to reset the Z80s only), the machines in reset meanwhile
assign dw_we = dw_on && !mt_active && !rom_we;
wire mt_done, mt_ok, mt_req, mt_we;
wire [15:0] mt_bad;
wire [20:0] mt_first;
wire [21:0] mt_addr;
wire [7:0] mt_din;
reg areset_d = 1'b1;
always @(posedge clk_bus)
	areset_d <= areset;
wire mt_start = (DIAG != 0) && areset_d && !areset;   // with the diagnostics only (it would overwrite the ROMs)

sram_test #(.AW(MEMTEST_AW)) mtest(
	.clk(clk_bus), .start(mt_start),
	.active(mt_active), .done(mt_done), .ok(mt_ok), .bad(mt_bad), .first(mt_first),
	.c_req(mt_req), .c_we(mt_we), .c_addr(mt_addr), .c_din(mt_din), .q(m_q)
);

sram_ctrl sram(
	.clk_bus(clk_bus), .clk_sys(clk_sys),
	.c_req(mt_active ? mt_req : rom_we | dw_on | a_req), .c_we(mt_active ? mt_we : rom_we | dw_on | a_we),
	.c_addr(mt_active ? mt_addr : rom_we ? {6'b111111, ld_addr_mcu[15:0]} : dw_on ? {1'b1, dw_a} : a_addr),
	.c_din(mt_active ? mt_din : rom_we ? ld_data_mcu : dw_on ? 8'd0 : a_din),
	.v_req(v_req), .v_addr(v_addr), .v_ack(v_ack), .q(m_q),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
);

// ---------------------------------------------------------------------------------------------
// diagnostics of the bring-up (the full screen: four rows of 16 squares in the top border, bit 15 on the left, green 1)
//   row 0: 15 PLL 2 locked, 14 the loader was active, 13 a ROM byte was written, 12 a non-zero ROM byte, 11 the loader
//          does not hold the machines now, 10 MCU not busy now, 9 machine sel not in reset now, 8 a CPU write to the
//          SRAM was made, 7 a CPU read of the SRAM gave a non-zero word, 6 a video read gave a non-zero word, 5 the
//          border of sel is not 0, 4 no late read (sticky), 3 the frame blinks (frame[4]), 2..0 sel
//   row 1 bits 12..9: 12 the SDRAM is ready, 11 no line queue overflow, 10 no screen read queue overflow, 9 no screen
//          word late (zx_vid, sticky)
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
	mt_done, mt_ok, dg_romcnt == 16'h8000, fb_ready, ~fb_over, ~vf_over, e_vlate == 16'd0, 4'd0, mt_first[20:16],
	locked_p, dg_ld, dg_rom, dg_romnz, ~ld_hold, ~mcu_busy, ~m_reset[sel], dg_wr,
	dg_rdnz, dg_vnz, v_border != 3'd0, ~dg_late, frame[4], sm
};

// ---------------------------------------------------------------------------------------------
// video: the selected machine full screen (its pixels from zx_vid into the line buffers of vga_out), the wall from the
// frame buffer

always @(posedge clk_bus)
	if (slot - 3'd4 == sm)
		v_border <= sel[3] ? e_vb[5:3] : e_vb[2:0];

wire p_we = sel[3] ? e_pwe[1] : e_pwe[0];
wire [9:0] p_addr = sel[3] ? e_pa[19:10] : e_pa[9:0];
wire [7:0] p_data = sel[3] ? e_pd[15:8] : e_pd[7:0];
wire [8:0] p_v = sel[3] ? e_pv[17:9] : e_pv[8:0];
wire [8:0] p_e = sel[3] ? e_pe[17:9] : e_pe[8:0];

// the diagnostics squares (DIAG): six rows of 16 squares, four in the top border (lines 284, 292, 300, 308) and two in
// the bottom one (196, 204), 6 lines each, squares 12 x 6 pixels every 16 from hc 0; row r shows diag[r*16 +: 16],
// bit 15 on the left: 1 bright green, 0 bright red
wire dg_top = p_v >= 9'd284 && p_v < 9'd314;
wire dg_bot = p_v >= 9'd196 && p_v < 9'd210;
wire [8:0] dv = p_v - (dg_top ? 9'd284 : 9'd196);
wire dg_on = (DIAG != 0) && (dg_top || dg_bot) && dv[2:0] < 3'd6 && p_e < 9'd256 && p_e[3:0] < 4'd12;
wire [2:0] dg_row = dg_top ? {1'b0, dv[4:3]} : {2'b10, dv[3]};
wire [3:0] dg_px = diag[{dg_row, ~p_e[7:4]}] ? 4'b1100 : 4'b1010;
wire [7:0] lb_wd = dg_on ? {dg_px, dg_px} : p_data;

// the frame buffer of the wall
wire rq_t, rq_half, rq_f, fb_ready, fb_over;
wire [1:0] rq_cr;
wire [7:0] rq_lc;
wire [9:0] rb_addr;
wire [15:0] rb_q;
fb_sdram fb(
	.clk(clk_sys), .clk_bus(clk_bus), .pclk(pclk),
	.w_we(fw_we), .w_addr(fw_addr), .w_data(fw_data), .l_done(fl_done), .l_m(fl_m), .l_lc(fl_lc),
	.rq_t(rq_t), .rq_cr(rq_cr), .rq_lc(rq_lc), .rq_half(rq_half), .rq_f(rq_f), .rb_addr(rb_addr), .rb_q(rb_q),
	.ready(fb_ready), .over(fb_over),
	.SDR_CLK(SDR_CLK), .SDR_BA(SDR_BA), .SDR_A(SDR_A), .SDR_DQM(SDR_DQM), .SDR_RAS_N(SDR_RAS_N),
	.SDR_CAS_N(SDR_CAS_N), .SDR_WE_N(SDR_WE_N), .SDR_DQ(SDR_DQ)
);

// the frame fade (QuadSpeccy): the frame of the selected cell is shown 98 frames (2 s) after every choice of a machine
// (sel_hit: Win + 1..8, Win + arrow, also at the edge), then hidden; always with Frame fade off
reg [6:0] rim_show = 7'd0;
always @(posedge clk_bus)
	if (kbd_sel_hit)
		rim_show <= 7'd98;
	else if (rim_show != 7'd0 && ce7 && vc == 9'd0 && hc == 9'd0)
		rim_show <= rim_show - 1'd1;
wire rim_on = !sw_fade || rim_show != 7'd0;

wire [7:0] vo_r, vo_g, vo_b;
wire vo_hs, vo_vs, vo_de, hs_neg, vs_neg;

vga_out #(.ROWS(4)) vga(
	.clk(clk_bus), .ce7(ce7), .hc(hc), .vc(vc), .lb_we(p_we), .lb_wa(p_addr), .lb_wd(lb_wd),
	.mode_i(sw_video),
	.wall_i(~show_full), .sel_i(sel), .frame_col(sw_frame_col), .rim_on(rim_on), .nb_i(sw_noborder),
	.pclk(pclk),
	.rq_t(rq_t), .rq_cr(rq_cr), .rq_lc(rq_lc), .rq_half(rq_half), .rq_f(rq_f), .rb_addr(rb_addr), .rb_q(rb_q),
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
	.s_force(sw_video != 2'd0 ? 4'd0 : 4'd2), .sx_force(sw_video != 2'd0 ? 4'd0 : 4'd5),
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
