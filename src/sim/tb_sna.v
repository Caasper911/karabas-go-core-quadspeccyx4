`timescale 1ns / 1ps
`default_nettype none

/*
 tb_sna.v

 A 48K snapshot (tools/sna2sim.py: work_s/rom.hex, ram.hex) in machine 0 of two zx_oct on sram_arb, sram_ctrl, the
 SRAM model, the others in reset; the ROM a 48 ROM with a loader of the registers. Per frame: the interrupt
 acknowledges of machine 0 and its port reads and writes (port, value, count), the PC at the start of INT; at the end
 the screen (work_s/screen.hex). FRAMES (default 5).
*/

`ifndef FRAMES
`define FRAMES 5
`endif

module tb_sna;

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

// the ROM (words) and the RAM of machine 0 (pages 5, 2, 0 = 4000..FFFF)
reg [15:0] romw [0:16383];
reg [15:0] ramw [0:24575];
reg [7:0] rom [0:32767];
integer i, a;
initial begin
	$readmemh("rom.hex", romw);
	$readmemh("ram.hex", ramw);
	for (i = 0; i < 16384; i = i + 1) begin
		rom[2*i] = romw[i][7:0];
		rom[2*i+1] = romw[i][15:8];
	end
	for (i = 0; i < 24576; i = i + 1) begin
		a = 16'h4000 + 2 * i;
		model.mem[{2'b00, 3'd0, (a < 16'h8000) ? 3'd5 : (a < 16'hC000) ? 3'd2 : 3'd0, a[13:1]}] = ramw[i];
	end
end

integer n = 0;
reg rom_we = 1'b0;
reg [14:0] rom_wa = 15'd0;
reg [7:0] rom_wd = 8'd0;
reg [15:0] reset = 16'hFFFF;
always @(posedge clk_bus) begin
	n = n + 1;
	rom_we <= 1'b0;
	if (n <= 32768) begin
		rom_we <= 1'b1;
		rom_wa <= n - 1;
		rom_wd <= rom[n - 1];
	end
	if (n == 40000)
		reset <= 16'hFFFE;           // machine 0 only
end

// two engines on the arbiter and the SRAM
wire [1:0] e_req, e_we;
wire [43:0] e_addr;
wire [15:0] e_din;
wire a_rv, a_re;
wire [2:0] a_rm;
wire [7:0] a_rd;
wire [15:0] q;

genvar ge;
generate
	for (ge = 0; ge < 2; ge = ge + 1) begin : g_eng
		zx_oct #(.BASE(ge)) eng (
			.clk(clk_bus), .slot(slot), .int_n(int_n), .reset(reset[ge*8 +: 8]), .nmi(8'd0),
			.sel_en(ge == 0), .sel(3'd0), .keys(40'd0), .keys_all(1'b0), .tape_in(8'd0), .kempston(8'd0),
			.m_req(e_req[ge]), .m_we(e_we[ge]), .m_addr(e_addr[ge*22 +: 22]), .m_din(e_din[ge*8 +: 8]),
			.m_rv(a_rv && a_re == ge), .m_rm(a_rm), .m_rd(a_rd),
			.rom_we(rom_we), .rom_wa(rom_wa), .rom_wd(rom_wd),
			.beeper(), .mic(), .v_m(3'd0), .v_border(), .v_scr7(),
			.ay_we(), .ay_wa(), .ay_wd(), .ay_ra(4'd0), .ay_rd(), .late(),
			.dbg_pc(), .dbg_7ffd(), .dbg_ev()
		);
	end
endgenerate

wire c_req, c_we;
wire [21:0] c_addr;
wire [7:0] c_din;
sram_arb arb (
	.clk(clk_bus), .e_req(e_req), .e_we(e_we), .e_addr(e_addr), .e_din(e_din),
	.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_din(c_din), .q(q),
	.rv(a_rv), .re(a_re), .rm(a_rm), .rd(a_rd)
);
wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MRD_N, MWR_N;
sram_ctrl sram (
	.clk_bus(clk_bus), .clk_sys(clk_sys),
	.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_din(c_din),
	.v_req(1'b0), .v_addr(21'd0), .v_ack(), .q(q),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
);
sram_model model (.A(MA), .DQ(MD), .RD_N(MRD_N), .WR_N(MWR_N), .drv(sram.md_oe[0]));

// ---------------------------------------------------------------------------------------------
// machine 0: the acknowledges, the ports per frame

integer frames = 0, acks = 0, ins = 0, outs = 0, m1s = 0, halts = 0;
integer pin [0:65535];
integer pout [0:65535];
reg [7:0] vin [0:65535];
reg [7:0] vout [0:65535];
reg int_d = 1'b1;
reg in_ack = 1'b0;
integer k;
initial for (k = 0; k < 65536; k = k + 1) begin pin[k] = 0; pout[k] = 0; end

wire m0 = slot == 3'd1 && !reset[0];      // the bus slot of machine 0
wire [15:0] pA = g_eng[0].eng.p_A;
wire pm1 = g_eng[0].eng.p_mc[0];
wire pio = g_eng[0].eng.p_iorq;
wire pwr = g_eng[0].eng.p_write;
wire pt2 = g_eng[0].eng.p_ts[2];
wire pic = !g_eng[0].eng.p_intcycle_n;

always @(posedge clk_bus) begin
	if (m0) begin
		if (pm1 && pic && !in_ack) begin
			in_ack = 1'b1;
			acks = acks + 1;
			$display("frame %0d: an interrupt acknowledge at line %0d pixel %0d (PC %h)", frames, vc, hc, pA);
		end else if (!(pm1 && pic))
			in_ack = 1'b0;
		if (pm1 && pt2 && !pic)
			m1s = m1s + 1;
		if (!pm1 && pio && pt2 && !g_eng[0].eng.c_wrdone[0]) begin
			if (pwr) begin
				pout[pA] = pout[pA] + 1;
				vout[pA] = g_eng[0].eng.p_dout;
				outs = outs + 1;
			end else begin
				pin[pA] = pin[pA] + 1;
				vin[pA] = g_eng[0].eng.port_q;
				ins = ins + 1;
			end
		end
	end
	int_d <= int_n;
	if (!int_n && int_d && n > 40000) begin
		$display("frame %0d: %0d acknowledges, %0d M1, %0d port reads, %0d writes", frames, acks, m1s, ins, outs);
		for (k = 0; k < 65536; k = k + 1) begin
			if (pin[k] != 0) $display("   IN  %h x %0d (last %h)", k[15:0], pin[k], vin[k]);
			if (pout[k] != 0) $display("   OUT %h x %0d (last %h)", k[15:0], pout[k], vout[k]);
			pin[k] = 0;
			pout[k] = 0;
		end
		acks = 0; ins = 0; outs = 0; m1s = 0;
		frames = frames + 1;
		if (frames == `FRAMES + 1) begin
			$display("tb_sna: %0d frames", `FRAMES);
			$finish;
		end
	end
end

endmodule
