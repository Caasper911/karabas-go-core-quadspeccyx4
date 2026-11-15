`timescale 1ns / 1ps
`default_nettype none

/*
 tb_ps.v

 zx_oct after synthesis (XST, netgen: zx_oct_ps) against the RTL zx_oct, clock for clock: the same inputs (the ROM 128
 loaded through the loader port, the machines out of reset together, then INT of the raster), each engine on its own
 sram_arb (the second input idle), sram_ctrl and SRAM model. INTROM: the program of tb_int.v instead of the ROM 128 (the
 interrupts every frame). Every output of both compared every clock. Prints "tb_ps: <n> errors".
*/

`ifndef TRACE
`define TRACE 0
`endif
`ifndef CLOCKS
`define CLOCKS 2000000
`endif

module tb_ps;

reg clk_sys = 1'b0;
always #5.946 clk_sys = ~clk_sys;
reg clk_bus = 1'b0;
reg [1:0] div = 2'd0;
always @(posedge clk_sys) begin
	div <= (div == 2'd2) ? 2'd0 : div + 1'd1;
	if (div == 2'd2) clk_bus <= 1'b1;
	if (div == 2'd0) clk_bus <= 1'b0;
end

wire ce7, ce_cpu, ce14, vga_half, int_n;
wire [8:0] hc, vc, vga_x;
wire [4:0] frame;
wire [9:0] vga_p, vga_l;
zx_timing timing (
	.clk(clk_bus), .reset(1'b0), .ce7(ce7), .ce_cpu(ce_cpu), .ce14(ce14), .hc(hc), .vc(vc), .int_n(int_n),
	.frame(frame), .vga_x(vga_x), .vga_half(vga_half), .vga_p(vga_p), .vga_l(vga_l)
);
reg [2:0] slot = 3'd0;
always @(posedge clk_bus)
	slot <= ce_cpu ? 3'd1 : slot + 1'd1;

// the ROM through the loader port, then the machines out of reset (machine k 2000 clocks after k - 1)
reg [15:0] romw [0:16383];
integer ri;
initial begin
	$readmemh("roms.hex", romw);
`ifdef INTROM
	// the program of tb_int.v (IM 1, EI, HALT loop; the handler PUSH AF / delay / POP AF / EI / RET): the interrupts
	for (ri = 0; ri < 16384; ri = ri + 1) romw[ri] = 16'h0000;
	romw[0] = 16'h31F3; romw[1] = 16'h8000; romw[2] = 16'h56ED; romw[3] = 16'h76FB; romw[4] = 16'hFD18;
	romw['h1C] = 16'h06F5; romw['h1D] = 16'h1010; romw['h1E] = 16'hF1FE; romw['h1F] = 16'hC9FB;
`endif
`ifdef SNA
	// a snapshot (tools/sna2sim.py): its ROM; its RAM into machine 0 of both models (below)
	$readmemh("rom.hex", romw);
`endif
end
reg [7:0] reset = 8'hFF;
integer n = 0, k;
reg [2:0] sel = 3'd0;
always @(posedge clk_bus) begin
	n = n + 1;
`ifdef SNA
	if (n == 40000) reset[0] <= 1'b0;      // machine 0 only
`else
	for (k = 0; k < 8; k = k + 1)
		if (n == 40000 + 2000 * k) reset[k] <= 1'b0;
`endif
	if (n % 300000 == 0) sel <= sel + 1'd1;
end

// two engines, each on its own SRAM
wire [1:0] e_req, e_we;
wire [43:0] e_addr;
wire [15:0] e_din;
wire [5:0] e_m;
wire [31:0] e_q;
wire [1:0] e_rv;
wire [5:0] e_rm;
wire [15:0] e_rd;
wire [15:0] e_beeper, e_mic, e_late;
wire [5:0] e_vb;
wire [1:0] e_scr7, e_ayw;
wire [7:0] e_aywa;
wire [15:0] e_aywd, e_ayrd;
wire [31:0] e_pc;
wire [11:0] e_7ffd, e_ev;

// INT of the CPU of each slot: the value at slot 0 for all (zx_vid staggers it in the core)
reg int_t = 1'b1;
always @(posedge clk_bus)
	if (slot == 3'd0)
		int_t <= int_n;
wire s_int_n = (slot == 3'd0) ? int_n : int_t;

zx_oct rtl (
	.clk(clk_bus), .slot(slot), .int_n(s_int_n), .reset(reset), .nmi(8'd0),
	.sel_en(1'b1), .sel(sel), .keys(40'd0), .keys_all(1'b0), .tape_in(8'd0), .kempston(8'd0),
	.m_req(e_req[0]), .m_we(e_we[0]), .m_addr(e_addr[21:0]), .m_din(e_din[7:0]),
	.m_m(e_m[2:0]), .m_rv(e_rv[0]), .m_rm(e_rm[2:0]), .m_rd(e_rd[7:0]),
	.divmmc_en(divmmc_en), .dv_clear(1'b0),
	.sd_en(1'b0), .sd_csize(22'd0), .h_pend(), .h_wr(), .h_m(3'd0), .h_lba(), .h_done(1'b0), .h_we(1'b0), .h_a(9'd0),
	.h_d(8'd0), .h_q(),
	.beeper(e_beeper[7:0]), .mic(e_mic[7:0]), .v_border(e_vb[2:0]), .v_scr7(e_scr7[0]),
	.ay_we(e_ayw[0]), .ay_wa(e_aywa[3:0]), .ay_wd(e_aywd[7:0]), .ay_ra(slot ^ 4'd5), .ay_rd(e_ayrd[7:0]),
	.late(e_late[7:0]), .dbg_pc(e_pc[15:0]), .dbg_7ffd(e_7ffd[5:0]), .dbg_ev(e_ev[5:0])
);

zx_oct_ps syn (
	.clk(clk_bus), .slot(slot), .int_n(s_int_n), .reset(reset), .nmi(8'd0),
	.sel_en(1'b1), .sel(sel), .keys(40'd0), .keys_all(1'b0), .tape_in(8'd0), .kempston(8'd0),
	.m_req(e_req[1]), .m_we(e_we[1]), .m_addr(e_addr[43:22]), .m_din(e_din[15:8]),
	.m_m(e_m[5:3]), .m_rv(e_rv[1]), .m_rm(e_rm[5:3]), .m_rd(e_rd[15:8]),
	.divmmc_en(divmmc_en), .dv_clear(1'b0),
	.sd_en(1'b0), .sd_csize(22'd0), .h_pend(), .h_wr(), .h_m(3'd0), .h_lba(), .h_done(1'b0), .h_we(1'b0), .h_a(9'd0),
	.h_d(8'd0), .h_q(),
	.beeper(e_beeper[15:8]), .mic(e_mic[15:8]), .v_border(e_vb[5:3]), .v_scr7(e_scr7[1]),
	.ay_we(e_ayw[1]), .ay_wa(e_aywa[7:4]), .ay_wd(e_aywd[15:8]), .ay_ra(slot ^ 4'd5), .ay_rd(e_ayrd[15:8]),
	.late(e_late[15:8]), .dbg_pc(e_pc[31:16]), .dbg_7ffd(e_7ffd[11:6]), .dbg_ev(e_ev[11:6])
);

genvar e;
generate
	for (e = 0; e < 2; e = e + 1) begin : g_mem
		wire [20:0] MA;
		wire [15:0] MD;
		wire [1:0] MRD_N, MWR_N;
		wire c_req, c_we;
		wire [21:0] c_addr;
		wire [7:0] c_din;
		sram_arb arb (
			.clk(clk_bus),
			.e_req({1'b0, e_req[e]}), .e_we({1'b0, e_we[e]}), .e_addr({22'd0, e_addr[e*22 +: 22]}),
			.e_din({8'd0, e_din[e*8 +: 8]}), .e_m({3'd0, e_m[e*3 +: 3]}),
			.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_din(c_din), .q(e_q[e*16 +: 16]),
			.rv(e_rv[e]), .re(), .rm(e_rm[e*3 +: 3]), .rd(e_rd[e*8 +: 8])
		);
		sram_ctrl sram (
			.clk_bus(clk_bus), .clk_sys(clk_sys),
			.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_din(c_din),
			.v_req(1'b0), .v_addr(21'd0), .v_ack(), .q(e_q[e*16 +: 16]),
			.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
		);
		sram_model model (.A(MA), .DQ(MD), .RD_N(MRD_N), .WR_N(MWR_N), .drv(sram.md_oe[0]));
	end
endgenerate

integer i, sa;
// DIVMMC: DivMMC on (ESXDOS at the NMI and the automap entries; the card answers FF)
`ifdef DIVMMC
wire divmmc_en = 1'b1;
`else
wire divmmc_en = 1'b0;
`endif
reg [15:0] esxw [0:4095];
`ifdef SNA
reg [15:0] ramw [0:65535];
`endif
initial begin
	#1;                                    // after the $readmemh of romw
	for (i = 0; i < (1 << 21); i = i + 1) begin
		g_mem[0].model.mem[i] = i[15:0];
		g_mem[1].model.mem[i] = i[15:0];
	end
	// the ROMs in the SRAM as the loader of the core puts them there: {111111, byte}, words 1F8000 (128, 48), 1FC000
	$readmemh("esx.hex", esxw);
	for (i = 0; i < 16384; i = i + 1) begin
		g_mem[0].model.mem[21'h1F8000 + i] = romw[i];
		g_mem[1].model.mem[21'h1F8000 + i] = romw[i];
	end
	for (i = 0; i < 4096; i = i + 1) begin
		g_mem[0].model.mem[21'h1FC000 + i] = esxw[i];
		g_mem[1].model.mem[21'h1FC000 + i] = esxw[i];
	end
`ifdef SNA
	$readmemh("ram.hex", ramw);
	for (i = 0; i < 65536; i = i + 1) begin            // the 8 pages of machine 0
		g_mem[0].model.mem[{2'b00, 3'd0, i[15:0]}] = ramw[i];
		g_mem[1].model.mem[{2'b00, 3'd0, i[15:0]}] = ramw[i];
	end
`endif
end

wire [7:0] r_out = {e_req[0], e_we[0], e_scr7[0], e_ayw[0]};
integer errors = 0, tr0 = 0, tr1 = 0;
reg [15:0] lp0 = 16'hFFFF, lp1 = 16'hFFFF;
always @(posedge clk_bus) begin
`ifdef PROBE
`endif
	if (e_pc[15:0] != lp0 && tr0 < `TRACE) begin lp0 = e_pc[15:0]; tr0 = tr0 + 1; $display("%0d rtl pc %h", n, lp0); end
	if (e_pc[31:16] != lp1 && tr1 < `TRACE) begin lp1 = e_pc[31:16]; tr1 = tr1 + 1; $display("%0d syn pc %h", n, lp1); end
	if (n > 10 && ({e_req[0], e_we[0], e_scr7[0], e_ayw[0], e_beeper[7:0], e_mic[7:0], e_late[7:0], e_vb[2:0],
			e_pc[15:0], e_7ffd[5:0], e_ev[5:0], e_ayrd[7:0]} !==
			{e_req[1], e_we[1], e_scr7[1], e_ayw[1], e_beeper[15:8], e_mic[15:8], e_late[15:8], e_vb[5:3],
			e_pc[31:16], e_7ffd[11:6], e_ev[11:6], e_ayrd[15:8]} ||
			(e_req[0] && (e_addr[21:0] !== e_addr[43:22] || (e_we[0] && e_din[7:0] !== e_din[15:8]))) ||
			(e_ayw[0] && {e_aywa[3:0], e_aywd[7:0]} !== {e_aywa[7:4], e_aywd[15:8]}))) begin
		errors = errors + 1;
		if (errors < 20)
			$display("%0d: rtl req %b we %b addr %h din %h pc %h 7ffd %h ev %b b %h | syn req %b we %b addr %h din %h pc %h 7ffd %h ev %b b %h",
				n, e_req[0], e_we[0], e_addr[21:0], e_din[7:0], e_pc[15:0], e_7ffd[5:0], e_ev[5:0], e_vb[2:0],
				e_req[1], e_we[1], e_addr[43:22], e_din[15:8], e_pc[31:16], e_7ffd[11:6], e_ev[11:6], e_vb[5:3]);
	end
	if (n % 500000 == 0)
		$display("%0d: pc %h / %h, 7ffd %h / %h, border %0d / %0d, errors %0d", n, e_pc[15:0], e_pc[31:16],
			e_7ffd[5:0], e_7ffd[11:6], e_vb[2:0], e_vb[5:3], errors);
	if (n == `CLOCKS) begin
		$display("tb_ps: %0d errors", errors);
		$finish;
	end
end

endmodule
