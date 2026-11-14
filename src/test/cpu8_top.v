`timescale 1ns / 1ps
`default_nettype none

/*
 cpu8_top.v

 Timing test of tv80_oct on the XC6SLX25 (src/test/run_timing.sh): the clk_bus of QuadSpeccy (one PLL on
 CLK_50MHZ: VCO 925 MHz, /33 = 28.03 MHz), the slot counter registered as cslot of QuadSpeccy, the inputs of the
 eight CPUs from an LFSR through registers (as the data register of a memory would give them), every output folded
 by XOR into one register on a pin, so XST keeps all of the CPU logic. Not for the board: only the timing report
 and the utilization of the CPU count.
*/

module cpu8_top (
	input wire CLK_50MHZ,
	output wire TAPE_OUT
);

wire [5:0] pll_clk;
wire clk;
kg_pll #(
	.DIVCLK_DIVIDE(2), .CLKFBOUT_MULT(37),
	.CLKOUT0_DIVIDE(11), .CLKOUT1_DIVIDE(33), .CLKOUT2_DIVIDE(116),
	.BUFG_MASK(6'b000000)
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked()
);
BUFG bufg_clk(.I(pll_clk[1]), .O(clk));

reg [2:0] slot = 3'd0;
always @(posedge clk)
	slot <= slot + 1'd1;

// the stimulus: a 64-bit LFSR, its bits into the input registers
reg [63:0] lfsr = 64'h0123_4567_89AB_CDEF;
always @(posedge clk)
	lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};

reg [7:0] rst_n = 8'h00, wait_n = 8'hFF, int_n = 8'hFF, nmi_n = 8'hFF, cen = 8'h00;
reg [8*8-1:0] di = 0;
always @(posedge clk) begin
	rst_n <= rst_n | lfsr[7:0];
	wait_n <= lfsr[15:8] | lfsr[23:16];
	int_n <= lfsr[31:24] | lfsr[39:32];
	nmi_n <= lfsr[47:40] | lfsr[55:48] | lfsr[63:56];
	cen <= 8'd1 << (slot + 3'd1);           // cen of the CPU of the next slot, registered
	di <= {di[8*8-9:0], lfsr[7:0] ^ lfsr[63:56]};
end

wire [8*16-1:0] A;
wire [8*8-1:0] dout;
wire [8*7-1:0] mc, ts;
wire [7:0] m1_n, iorq, no_read, write, intcycle_n, halt_n;

tv80_oct #(.Mode(0), .IOWait(1)) cpus (
	.clk(clk), .slot(slot),
	.reset_n(rst_n), .cen(cen), .wait_n(wait_n), .int_n(int_n), .nmi_n(nmi_n), .dinst(di), .di(di),
	.A(A), .dout(dout), .mc(mc), .ts(ts), .m1_n(m1_n), .iorq(iorq), .no_read(no_read), .write(write),
	.intcycle_n(intcycle_n), .halt_n(halt_n)
);

reg fold = 1'b0;
always @(posedge clk)
	fold <= ^{A, dout, mc, ts, m1_n, iorq, no_read, write, intcycle_n, halt_n};
assign TAPE_OUT = fold;

endmodule
