`timescale 1ns / 1ps
`default_nettype none

/*
 tv80_oct.v

 One tv80 logic for eight CPUs (tv80o_core, made by tools/mkctx.py out of tv80_core), one clock per CPU: a slot of 8
 clocks is one T-state of the 3.5 MHz CPUs at 28 MHz, slot k is CPU k.

   slot k      CPU k: its cen (its machine gives it in this clock only), every input is taken, the state of CPU k
               is read and written
   slot k + 1  the second read port shows the new state of CPU k (pth = slot - 1): its outputs go to machine k
               straight (live) in this clock and are kept for it until the same slot of the next T-state

 So machine k sees its CPU as a tv80_core whose cen is in slot k: the outputs change with the clock of cen (from the
 next clock on, as a tv80_core), the asynchronous reset is synchronous (reset_n of CPU k in its slot). The quad core
 of karabas-go-quadspeccy (tv80_quad) needed two clocks per CPU, its cen and a "peek" with the same logic.
 src/sim/tb_tv80o.v compares tv80_oct with eight tv80_core clock for clock.
*/

module tv80_oct #(
	parameter Mode = 0,
	parameter IOWait = 1
) (
	input wire clk,
	input wire [2:0] slot,          // the slot of this clock: k = cen of CPU k

	// CPU k: bits k (k*8, k*16...)
	input wire [7:0] reset_n,
	input wire [7:0] cen,           // high in slot k only
	input wire [7:0] wait_n,
	input wire [7:0] int_n,
	input wire [7:0] nmi_n,
	input wire [8*8-1:0] dinst,
	input wire [8*8-1:0] di,

	output wire [8*16-1:0] A,
	output wire [8*8-1:0] dout,
	output wire [8*7-1:0] mc,
	output wire [8*7-1:0] ts,
	output wire [7:0] m1_n,
	output wire [7:0] iorq,
	output wire [7:0] no_read,
	output wire [7:0] write,
	output wire [7:0] intcycle_n,
	output wire [7:0] halt_n
);

wire [2:0] th = slot;
wire [2:0] pth = slot - 3'd1;

wire [15:0] p_A;
wire [7:0] p_dout;
wire [6:0] p_mc, p_ts;
wire p_m1_n, p_iorq, p_no_read, p_write, p_intcycle_n, p_halt_n;

tv80o_core #(.Mode(Mode), .IOWait(IOWait)) core (
	.th(th),
	.pth(pth),
	.reset_n(reset_n[th]), .rseed(8'd0),
	.clk(clk),
	.cen(cen[th]),
	.wait_n(wait_n[th]),
	.int_n(int_n[th]),
	.nmi_n(nmi_n[th]),
	.busrq_n(1'b1),
	.dinst(dinst[th*8 +: 8]),
	.di(di[th*8 +: 8]),
	.m1_n(),
	.iorq(),
	.no_read(),
	.write(),
	.rfsh_n(),
	.halt_n(),
	.busak_n(),
	.A(),
	.dout(),
	.mc(),
	.ts(),
	.intcycle_n(),
	.IntE(),
	.stop(),
	.p_A(p_A),
	.p_dout(p_dout),
	.p_m1_n(p_m1_n),
	.p_mc(p_mc),
	.p_ts(p_ts),
	.p_halt_n(p_halt_n),
	.p_intcycle_n(p_intcycle_n),
	.p_iorq(p_iorq),
	.p_no_read(p_no_read),
	.p_write(p_write)
);

// the outputs of CPU k: live in slot k + 1, kept from it after
localparam OW = 16 + 8 + 7 + 7 + 6;
wire [OW-1:0] live = {p_A, p_dout, p_mc, p_ts, p_m1_n, p_iorq, p_no_read, p_write, p_intcycle_n, p_halt_n};

genvar k;
generate
	for (k = 0; k < 8; k = k + 1) begin : g_cpu
		reg [OW-1:0] kept = {OW{1'b0}};
		always @(posedge clk)
			if (pth == k)
				kept <= live;
		wire [OW-1:0] o = (pth == k) ? live : kept;
		assign {A[k*16 +: 16], dout[k*8 +: 8], mc[k*7 +: 7], ts[k*7 +: 7], m1_n[k], iorq[k], no_read[k], write[k],
			intcycle_n[k], halt_n[k]} = o;
	end
endgenerate

endmodule
