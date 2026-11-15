`timescale 1ns / 1ps
`default_nettype none

/*
 sram_arb.v

 The SRAM for two engines (zx_oct, BASE 0 and 1): each gives at most one request a clock (e_req for one clock), the
 SRAM (sram_ctrl) does one access a clock, so each engine has a queue (16 entries, distributed RAM) and the arbiter
 takes one entry a clock, from the two queues in turn when both have one. A taken entry goes to sram_ctrl through a
 register (c_*); the word of a read is q two clocks after that, given back as the byte of the request (address bit 0)
 with its engine and machine (rv, re, rm, rd: one clock, combinational from q). The machine comes with the request
 (e_m): the address does not tell it for the ROMs (shared) and the DivMMC.

 Wait: an engine asks at most once a clock and a machine at most once per 3 T-states (24 clocks), so the eight machines
 of an engine give at most 8 requests in 8 clocks; both engines at once 16 in 8 clocks, served one a clock in turn: a
 request waits at most 8 clocks. Its data is written 6 clocks after the request (queue, register, SRAM) + the wait:
 at most 14, the CPU takes it 15 clocks after the request (zx_oct; late there if not).
*/

module sram_arb (
	input wire clk,

	input wire [1:0] e_req,
	input wire [1:0] e_we,
	input wire [43:0] e_addr,           // engine e: e_addr[e*22 +: 22], byte {BASE, machine, page, offset}
	input wire [15:0] e_din,
	input wire [5:0] e_m,               // engine e: its machine, e_m[e*3 +: 3]

	output reg c_req = 1'b0,
	output reg c_we = 1'b0,
	output reg [21:0] c_addr = 22'd0,
	output reg [7:0] c_din = 8'd0,
	input wire [15:0] q,

	output wire rv,                     // the byte of a read: its engine, machine
	output wire re,
	output wire [2:0] rm,
	output wire [7:0] rd
);

// the queues: {machine, we, addr, din}
reg [33:0] fq0 [0:15];
reg [33:0] fq1 [0:15];
reg [3:0] wp0 = 4'd0, wp1 = 4'd0, rp0 = 4'd0, rp1 = 4'd0;
wire ne0 = wp0 != rp0;
wire ne1 = wp1 != rp1;
reg turn = 1'b0;                    // 1: queue 1 first when both have an entry

always @(posedge clk) begin
	if (e_req[0]) begin
		fq0[wp0] <= {e_m[2:0], e_we[0], e_addr[21:0], e_din[7:0]};
		wp0 <= wp0 + 1'd1;
	end
	if (e_req[1]) begin
		fq1[wp1] <= {e_m[5:3], e_we[1], e_addr[43:22], e_din[15:8]};
		wp1 <= wp1 + 1'd1;
	end
end

wire take1 = ne1 && (!ne0 || turn);
wire take0 = ne0 && !take1;
reg [33:0] head;                    // (wp in the list: ISim missed the write of the entry at the head of an empty queue)
always @(take1 or rp0 or rp1 or wp0 or wp1 or fq0[rp0] or fq1[rp1])
	head = take1 ? fq1[rp1] : fq0[rp0];

// the tag of a read in flight: {valid, engine, machine, byte}; taken in clock j, c_req in j + 1, q in j + 3
reg t1v = 1'b0, t2v = 1'b0, t3v = 1'b0, t1e = 1'b0, t2e = 1'b0, t3e = 1'b0, t1h = 1'b0, t2h = 1'b0, t3h = 1'b0;
reg [2:0] t1m = 3'd0, t2m = 3'd0, t3m = 3'd0;

always @(posedge clk) begin
	c_req <= take0 | take1;
	c_we <= head[30];
	c_addr <= head[29:8];
	c_din <= head[7:0];
	if (take0) rp0 <= rp0 + 1'd1;
	if (take1) rp1 <= rp1 + 1'd1;
	if (take0 | take1) turn <= take0;
	t1v <= (take0 | take1) && !head[30];
	t1e <= take1;
	t1m <= head[33:31];
	t1h <= head[8];
	{t2v, t2e, t2m, t2h} <= {t1v, t1e, t1m, t1h};
	{t3v, t3e, t3m, t3h} <= {t2v, t2e, t2m, t2h};
end

assign rv = t3v;
assign re = t3e;
assign rm = t3m;
assign rd = t3h ? q[15:8] : q[7:0];

endmodule
