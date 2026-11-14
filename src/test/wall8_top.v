`timescale 1ns / 1ps
`default_nettype none

/*
 wall8_top.v

 Timing test of zx_oct (eight machines) with sram_ctrl on the XC6SLX25 (src/test/run_timing.sh wall8): the clocks
 of the core (one PLL on CLK_50MHZ: clk_sys 84.09 MHz, clk_bus 28.03 MHz), zx_timing and the slots, the SRAM on its
 pins of the Karabas Go, the other inputs (resets, keys, the ROM loader, the video reader) from an LFSR through
 registers, the other outputs folded by XOR into one pin. Not for the board: the timing report and the utilization.
*/

module wall8_top (
	input wire CLK_50MHZ,
	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MRD_N,
	output wire [1:0] MWR_N,
	output wire TAPE_OUT
);

wire [5:0] pll_clk;
wire clk_sys, clk_bus;
kg_pll #(
	.DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37),
	.CLKOUT0_DIVIDE(11), .CLKOUT1_DIVIDE(33), .CLKOUT2_DIVIDE(116),
	.BUFG_MASK(6'b000001)
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked()
);
assign clk_sys = pll_clk[0];
BUFG bufg_clk_bus(.I(pll_clk[1]), .O(clk_bus));

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

reg [63:0] lfsr = 64'h0123_4567_89AB_CDEF;
always @(posedge clk_bus)
	lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};

reg [7:0] reset = 8'hFF, nmi = 8'h00, kempston = 8'h00, rom_wd = 8'h00;
reg [2:0] sel = 3'd0, v_m = 3'd0;
reg [39:0] keys = 40'd0;
reg tape_in = 1'b0, rom_we = 1'b0, v_req = 1'b0;
reg [14:0] rom_wa = 15'd0;
reg [20:0] v_addr = 21'd0;
always @(posedge clk_bus) begin
	reset <= lfsr[7:0] & lfsr[15:8] & lfsr[23:16];
	nmi <= lfsr[31:24] & lfsr[39:32] & lfsr[47:40];
	sel <= lfsr[50:48];
	keys <= {keys[31:0], lfsr[7:0]};
	tape_in <= lfsr[51];
	kempston <= lfsr[63:56];
	rom_we <= lfsr[52] & lfsr[53];
	rom_wa <= lfsr[14:0];
	rom_wd <= lfsr[22:15];
	v_req <= lfsr[54];
	v_addr <= lfsr[44:24];
	v_m <= lfsr[57:55];
end

wire m_req, m_we;
wire [21:0] m_addr;
wire [7:0] m_din;
wire [15:0] m_q;
wire [7:0] beeper, mic, late;
wire [2:0] v_border;
wire v_scr7, ay_we, v_ack;
wire [3:0] ay_wa;
wire [7:0] ay_wd;

zx_oct #(.BASE(2'd0)) eng (
	.clk(clk_bus), .slot(slot), .int_n(int_n), .reset(reset), .nmi(nmi),
	.sel(sel), .keys(keys), .tape_in(tape_in), .kempston(kempston),
	.m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_din(m_din), .m_q(m_q),
	.rom_we(rom_we), .rom_wa(rom_wa), .rom_wd(rom_wd),
	.beeper(beeper), .mic(mic), .v_m(v_m), .v_border(v_border), .v_scr7(v_scr7),
	.ay_we(ay_we), .ay_wa(ay_wa), .ay_wd(ay_wd), .ay_ra(4'd0), .ay_rd(), .late(late)
);

sram_ctrl sram (
	.clk_bus(clk_bus), .clk_sys(clk_sys),
	.c_req(m_req), .c_we(m_we), .c_addr(m_addr), .c_din(m_din),
	.v_req(v_req), .v_addr(v_addr), .v_ack(v_ack), .q(m_q),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
);

reg fold = 1'b0;
always @(posedge clk_bus)
	fold <= ^{beeper, mic, late, v_border, v_scr7, ay_we, ay_wa, ay_wd, v_ack, m_q};
assign TAPE_OUT = fold;

endmodule
