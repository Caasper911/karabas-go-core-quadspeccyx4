`timescale 1ns / 1ps
`default_nettype none

/*
 vid_fetch.v

 The screen reads of the two engines (zx_vid: one request a clock each, f_*) on the video port of sram_ctrl, which
 takes a clock without a CPU request (the CPUs first, their data has a deadline): a queue per engine (16 entries,
 distributed RAM), the two in turn; a word comes two clocks after v_ack (q of sram_ctrl), back to its engine with its
 tag (r_v[e], r_tag, r_q). clk = clk_bus.

 The load (docs/ARCHITECTURE.md, "Буфер кадра"): a machine asks 2 words a pair of characters (8 T-states) in its
 paper, with the staggered rasters about 9 of the 16 at a time: 18 words in 64 clocks; the CPUs take about half of
 the clocks (at most 43 of 64, measured). A word has 6 T-states.
*/

module vid_fetch (
	input wire clk,

	input wire [1:0] f_req,
	input wire [41:0] f_addr,           // engine e: f_addr[e*21 +: 21], a word
	input wire [7:0] f_tag,             // f_tag[e*4 +: 4]

	output wire v_req,
	output wire [20:0] v_addr,
	input wire v_ack,
	input wire [15:0] q,

	output reg [1:0] r_v = 2'b00,
	output reg [3:0] r_tag = 4'd0,
	output wire [15:0] r_q,

	output reg over = 1'b0              // a queue overflowed (sticky, debug)
);

reg [24:0] fq0 [0:15];
reg [24:0] fq1 [0:15];
reg [3:0] wp0 = 4'd0, wp1 = 4'd0, rp0 = 4'd0, rp1 = 4'd0;
wire ne0 = wp0 != rp0;
wire ne1 = wp1 != rp1;
reg turn = 1'b0;                    // 1: queue 1 first when both have an entry

always @(posedge clk) begin
	if (f_req[0]) begin
		fq0[wp0] <= {f_tag[3:0], f_addr[20:0]};
		wp0 <= wp0 + 1'd1;
		if (wp0 + 1'd1 == rp0) over <= 1'b1;
	end
	if (f_req[1]) begin
		fq1[wp1] <= {f_tag[7:4], f_addr[41:21]};
		wp1 <= wp1 + 1'd1;
		if (wp1 + 1'd1 == rp1) over <= 1'b1;
	end
end

wire use1 = ne1 && (!ne0 || turn);
reg [24:0] head;                    // (the pointers in the list: ISim misses an array word in an always @*)
always @(use1 or rp0 or rp1 or wp0 or wp1 or fq0[rp0] or fq1[rp1])
	head = use1 ? fq1[rp1] : fq0[rp0];

assign v_req = ne0 | ne1;
assign v_addr = head[20:0];

// the tag of a read in flight: taken with v_ack in clock j, its word is q in j + 2
reg t1v = 1'b0, t1e = 1'b0;
reg [3:0] t1t = 4'd0;
always @(posedge clk) begin
	if (v_ack) begin
		if (use1) rp1 <= rp1 + 1'd1; else rp0 <= rp0 + 1'd1;
		turn <= ~use1;
	end
	t1v <= v_ack;
	t1e <= use1;
	t1t <= head[24:21];
	r_v <= {t1v & t1e, t1v & ~t1e};
	r_tag <= t1t;
end
assign r_q = q;

endmodule
