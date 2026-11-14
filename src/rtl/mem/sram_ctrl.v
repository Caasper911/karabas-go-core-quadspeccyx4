`timescale 1ns / 1ps
`default_nettype none

/*
 sram_ctrl.v

 The asynchronous SRAM of the boards (2M x 16, 10 ns, /RD and /WR per byte: MRD_N, MWR_N; the chip select is tied):
 one access every clock of clk_bus (28 MHz, 35.7 ns), clk_sys (84 MHz) = clk_bus * 3 for the write strobe.

 A request in clock n (c_req, one clock; else v_req of the video, taken with v_ack in a clock without c_req):
   n + 1   MA and MRD_N from their registers on clk_bus (IOB): the whole clock for the access. A read has both /RD low;
           its word is taken with the clk_bus edge at the end of n + 1 (IOB): 35.7 ns = 12 ns out + 10 ns tAA + 12 ns in
           + board, as the SRAM of TS-Conf (rtl/tsconf/dram/sram.v there: three clk_sys).
           A write: /WR of the byte low from the first to the second clk_sys edge after the start of n + 1 (11.9 ns), the
           data driven from the first to the third (registers on clk_sys, IOB): address set up and held one clk_sys
           around /WR, the data one clk_sys before its end and after it; in a write /RD stays high, so the SRAM stops
           driving at the start of n + 1 and the data goes out one clk_sys later (no fight after a read).
   n + 2   q: the word of a read of n (CPU or video)

 The phase of clk_sys in a clock of clk_bus: bt toggles with clk_bus, bts samples it with clk_sys; bt != bts in the
 first clk_sys of the clock (both clocks from one PLL, every edge of clk_bus is an edge of clk_sys).
*/

module sram_ctrl (
	input wire clk_bus,
	input wire clk_sys,

	// CPU port: a request for one clock, its read word in q two clocks after it
	input wire c_req,
	input wire c_we,
	input wire [21:0] c_addr,       // byte: word c_addr[21:1], byte c_addr[0] (1: bits 15..8)
	input wire [7:0] c_din,

	// video port: v_req held until v_ack (a clock without c_req); its word in q two clocks after v_ack
	input wire v_req,
	input wire [20:0] v_addr,       // word
	output wire v_ack,

	output wire [15:0] q,

	// pins
	output reg [20:0] MA = 21'd0,
	inout wire [15:0] MD,
	output reg [1:0] MRD_N = 2'b11,
	output reg [1:0] MWR_N = 2'b11
);

assign v_ack = v_req & ~c_req;

// ---------------------------------------------------------------------------------------------
// clk_bus: the address, /RD, the data of a write (fabric), the read word

reg w_go = 1'b0;                // this clock writes
reg [1:0] w_lane = 2'b00;
reg [15:0] w_data = 16'd0;
reg [15:0] md_i = 16'd0;
reg bt = 1'b0;

always @(posedge clk_bus) begin
	bt <= ~bt;
	w_go <= c_req & c_we;
	if (c_req) begin
		MA <= c_addr[21:1];
		MRD_N <= c_we ? 2'b11 : 2'b00;
		w_lane <= c_addr[0] ? 2'b10 : 2'b01;
		w_data <= {c_din, c_din};
	end else if (v_req) begin
		MA <= v_addr;
		MRD_N <= 2'b00;
	end else
		MRD_N <= 2'b11;
	md_i <= MD;
end
assign q = md_i;

// ---------------------------------------------------------------------------------------------
// clk_sys: /WR and the data out of a write

reg bts = 1'b0;
reg f2 = 1'b0, f3 = 1'b0;      // the second / third clk_sys edge of the clock of clk_bus comes
wire f1 = bt ^ bts;             // the first comes
reg [15:0] md_o = 16'd0;
reg [15:0] md_oe = 16'd0;       // one per bit: the tristate of each IOB

always @(posedge clk_sys) begin
	bts <= bt;
	f2 <= f1;
	f3 <= f2;
	if (f1 && w_go) begin
		MWR_N <= ~w_lane;
		md_o <= w_data;
		md_oe <= 16'hFFFF;
	end
	if (f2)
		MWR_N <= 2'b11;
	if (f3)
		md_oe <= 16'h0000;
end

genvar k;
generate
	for (k = 0; k < 16; k = k + 1) begin : g_md
		assign MD[k] = md_oe[k] ? md_o[k] : 1'bz;
	end
endgenerate

endmodule
