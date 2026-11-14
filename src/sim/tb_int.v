`timescale 1ns / 1ps
`default_nettype none

/*
 tb_int.v

 The frame interrupt as the 16 machines (two zx_oct on sram_arb, sram_ctrl, the SRAM model) take it. The ROM of all
 machines (through the loader port):

   0000  DI / LD SP,8000 / IM 1 / EI
   0007  HALT / JR 0007
   0038  the handler: SHORT=0 a normal one (PUSH AF, a delay of 16 x 13 T, POP AF, EI, RET: about 240 T),
         SHORT=1 EI / RET (27 T after the start of the acknowledge, while INT (32 T) still is low)

 Every interrupt acknowledge of every machine (the M1 with IORQ, bus slot of the machine) is logged with the T-state
 of the frame where it starts, counted from the start of INT (zx_timing: line 239, pixel 312) and taken back by the
 slot of the machine (machine m runs m clocks after machine 0). Checked: the low time of INT (32 T) and its period
 (71680 T: one frame), every machine acknowledges once a frame (SHORT=0; SHORT=1 twice: the Z80 takes INT again
 when it is still low after EI / RET, as on the Pentagon), each acknowledge of a machine in a HALT 0..3 T after the
 start of INT, all frames at the same T; the first paper pixel 17988 T after the start of INT. Prints "tb_int: <n> errors".
*/

`ifndef FRAMES
`define FRAMES 4
`endif
`ifndef SHORT
`define SHORT 0
`endif

module tb_int;

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

// the ROM
reg [7:0] rom [0:32767];
integer i;
initial begin
	for (i = 0; i < 32768; i = i + 1) rom[i] = 8'h00;
	{rom[0], rom[1], rom[2], rom[3], rom[4], rom[5], rom[6]} = {8'hF3, 8'h31, 8'h00, 8'h80, 8'hED, 8'h56, 8'hFB};
	{rom[7], rom[8], rom[9]} = {8'h76, 8'h18, 8'hFD};
	if (`SHORT != 0)
		{rom['h38], rom['h39]} = {8'hFB, 8'hC9};
	else
		{rom['h38], rom['h39], rom['h3A], rom['h3B], rom['h3C], rom['h3D], rom['h3E], rom['h3F]} =
			{8'hF5, 8'h06, 8'h10, 8'h10, 8'hFE, 8'hF1, 8'hFB, 8'hC9};
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
		reset <= 16'h0000;
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
			.sel_en(ge == 0), .sel(3'd0), .keys(40'd0), .tape_in(1'b0), .kempston(8'd0),
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
// INT of zx_timing: its start (the clock), low time, period; the first paper pixel after it

integer errors = 0;
integer int_start = -1, int_prev = -1, int_count = 0, paper_after = -1;
reg int_d = 1'b1;
always @(posedge clk_bus) begin
	int_d <= int_n;
	if (!int_n && int_d) begin
		if (int_prev >= 0 && n - int_prev != 573440) begin
			errors = errors + 1;
			$display("INT period %0d clocks, not 573440 (71680 T)", n - int_prev);
		end
		int_prev = n;
		int_start = n;
		int_count = int_count + 1;
		paper_after = -1;
	end
	if (int_n && !int_d && int_start >= 0 && n - int_start != 256) begin
		errors = errors + 1;
		$display("INT low %0d clocks, not 256 (32 T)", n - int_start);
	end
	if (ce7 && vc == 9'd0 && hc == 9'd0 && int_start >= 0 && paper_after < 0) begin
		paper_after = n - int_start;
		// int_start is the clock after the edge that lowered INT, this the 4th clock after hc became 0: + 3
		if (paper_after != 17988 * 8 + 3) begin
			errors = errors + 1;
			$display("the first paper pixel %0d clocks after the start of INT, not %0d (17988 T)", paper_after, 17988 * 8);
		end else if (int_count == 2)
			$display("the first paper pixel 17988 T after the start of INT");
	end
end

// ---------------------------------------------------------------------------------------------
// the acknowledges: machine b of engine e in its bus slot (slot b + 1), the T-state from the start of INT

integer acks [0:15];
integer at_t [0:15];             // T after INT of the first acknowledge in the last frame
integer frame_acks [0:15];
integer k, t;
initial for (k = 0; k < 16; k = k + 1) begin acks[k] = 0; at_t[k] = -1; frame_acks[k] = 0; end
wire [2:0] bm = slot - 1'd1;
reg [15:0] in_ack = 16'd0;       // the machine is in an acknowledge M1 (tv80 holds its T1 in the automatic waits)

generate
	for (ge = 0; ge < 2; ge = ge + 1) begin : g_chk
		always @(posedge clk_bus)
			if (g_eng[ge].eng.p_mc[0] && !g_eng[ge].eng.p_intcycle_n && !in_ack[ge*8 + bm] && !reset[ge*8 + bm] &&
				int_start >= 0) begin
				in_ack[ge*8 + bm] = 1'b1;
				// the clock of the start of T1 of this machine: its cen was in slot bm, 1 clock before this one;
				// machine bm runs bm clocks after machine 0, so its T relative to INT
				t = (n - 1 - bm - int_start) / 8;
				acks[ge*8 + bm] = acks[ge*8 + bm] + 1;
				frame_acks[ge*8 + bm] = frame_acks[ge*8 + bm] + 1;
				if (frame_acks[ge*8 + bm] == 1) begin
					if (t < 0 || t > 3) begin
						errors = errors + 1;
						$display("machine %0d: an acknowledge %0d T after the start of INT (in a HALT: 0..3)", ge*8 + bm, t);
					end
					at_t[ge*8 + bm] = t;
				end else
					if (`SHORT == 0 || frame_acks[ge*8 + bm] > 2) $display("machine %0d: acknowledge %0d of the frame at T %0d after INT", ge*8 + bm,
						frame_acks[ge*8 + bm], t);
			end else if (!(g_eng[ge].eng.p_mc[0] && !g_eng[ge].eng.p_intcycle_n))
				in_ack[ge*8 + bm] = 1'b0;
	end
endgenerate

// at each start of INT: the acknowledges of the frame before
always @(posedge clk_bus)
	if (!int_n && int_d) begin
		if (int_count > 1)
			for (k = 0; k < 16; k = k + 1)
				if (frame_acks[k] != ((`SHORT != 0) ? 2 : 1)) begin
					errors = errors + 1;
					$display("frame %0d: machine %0d acknowledged %0d times", int_count - 1, k, frame_acks[k]);
				end
		for (k = 0; k < 16; k = k + 1) frame_acks[k] = 0;
		if (int_count == `FRAMES + 1) begin
			$display("tb_int: %0d frames, acknowledges per machine %0d (SHORT=%0d), the first at T %0d .. %0d after INT",
				`FRAMES, acks[0], `SHORT, at_t[0], at_t[15]);
			$display("tb_int: %0d errors", errors);
			$finish;
		end
	end

endmodule
