`timescale 1ns / 1ps
`default_nettype none

/*
 tb_ps.v

 zx_oct after synthesis (XST, netgen: zx_oct_ps) against the RTL zx_oct, clock for clock: the same inputs (the ROM 128
 loaded through the loader port, the machines out of reset together, then INT of the raster), each engine on its own
 sram_ctrl and SRAM model. Every output of both compared every clock. Prints "tb_ps: <n> errors".
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
initial $readmemh("roms.hex", romw);
reg rom_we = 1'b0;
reg [14:0] rom_wa = 15'd0;
reg [7:0] rom_wd = 8'd0;
reg [15:0] li = 16'd0;
reg [7:0] reset = 8'hFF;
integer n = 0, k;
reg [2:0] sel = 3'd0;
always @(posedge clk_bus) begin
	n = n + 1;
	rom_we <= 1'b0;
	if (li < 16'd32768) begin
		rom_we <= 1'b1;
		rom_wa <= li[14:0];
		rom_wd <= li[0] ? romw[li[14:1]][15:8] : romw[li[14:1]][7:0];
		li <= li + 1'd1;
	end
	for (k = 0; k < 8; k = k + 1)
		if (n == 40000 + 2000 * k) reset[k] <= 1'b0;
	if (n % 300000 == 0) sel <= sel + 1'd1;
end

// two engines, each on its own SRAM
wire [1:0] e_req, e_we;
wire [43:0] e_addr;
wire [15:0] e_din;
wire [31:0] e_q;
wire [15:0] e_beeper, e_mic, e_late;
wire [5:0] e_vb;
wire [1:0] e_scr7, e_ayw;
wire [7:0] e_aywa;
wire [15:0] e_aywd, e_ayrd;
wire [31:0] e_pc;
wire [11:0] e_7ffd, e_ev;

zx_oct rtl (
	.clk(clk_bus), .slot(slot), .int_n(int_n), .reset(reset), .nmi(8'd0),
	.sel(sel), .keys(40'd0), .tape_in(1'b0), .kempston(8'd0),
	.m_req(e_req[0]), .m_we(e_we[0]), .m_addr(e_addr[21:0]), .m_din(e_din[7:0]), .m_q(e_q[15:0]),
	.rom_we(rom_we), .rom_wa(rom_wa), .rom_wd(rom_wd),
	.beeper(e_beeper[7:0]), .mic(e_mic[7:0]), .v_m(sel), .v_border(e_vb[2:0]), .v_scr7(e_scr7[0]),
	.ay_we(e_ayw[0]), .ay_wa(e_aywa[3:0]), .ay_wd(e_aywd[7:0]), .ay_ra(slot ^ 4'd5), .ay_rd(e_ayrd[7:0]),
	.late(e_late[7:0]), .dbg_pc(e_pc[15:0]), .dbg_7ffd(e_7ffd[5:0]), .dbg_ev(e_ev[5:0])
);

zx_oct_ps syn (
	.clk(clk_bus), .slot(slot), .int_n(int_n), .reset(reset), .nmi(8'd0),
	.sel(sel), .keys(40'd0), .tape_in(1'b0), .kempston(8'd0),
	.m_req(e_req[1]), .m_we(e_we[1]), .m_addr(e_addr[43:22]), .m_din(e_din[15:8]), .m_q(e_q[31:16]),
	.rom_we(rom_we), .rom_wa(rom_wa), .rom_wd(rom_wd),
	.beeper(e_beeper[15:8]), .mic(e_mic[15:8]), .v_m(sel), .v_border(e_vb[5:3]), .v_scr7(e_scr7[1]),
	.ay_we(e_ayw[1]), .ay_wa(e_aywa[7:4]), .ay_wd(e_aywd[15:8]), .ay_ra(slot ^ 4'd5), .ay_rd(e_ayrd[15:8]),
	.late(e_late[15:8]), .dbg_pc(e_pc[31:16]), .dbg_7ffd(e_7ffd[11:6]), .dbg_ev(e_ev[11:6])
);

genvar e;
generate
	for (e = 0; e < 2; e = e + 1) begin : g_mem
		wire [20:0] MA;
		wire [15:0] MD;
		wire [1:0] MRD_N, MWR_N;
		sram_ctrl sram (
			.clk_bus(clk_bus), .clk_sys(clk_sys),
			.c_req(e_req[e]), .c_we(e_we[e]), .c_addr(e_addr[e*22 +: 22]), .c_din(e_din[e*8 +: 8]),
			.v_req(1'b0), .v_addr(21'd0), .v_ack(), .q(e_q[e*16 +: 16]),
			.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
		);
		sram_model model (.A(MA), .DQ(MD), .RD_N(MRD_N), .WR_N(MWR_N), .drv(sram.md_oe[0]));
	end
endgenerate

integer i;
initial
	for (i = 0; i < (1 << 21); i = i + 1) begin
		g_mem[0].model.mem[i] = i[15:0];
		g_mem[1].model.mem[i] = i[15:0];
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
