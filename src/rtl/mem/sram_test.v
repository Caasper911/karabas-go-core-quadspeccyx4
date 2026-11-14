`timescale 1ns / 1ps
`default_nettype none

/*
 sram_test.v

 A self test of the SRAM through the CPU port of sram_ctrl (bring-up of the board): after start (a pulse) it writes
 every word 0 .. 2^AW - 1 as two byte writes (the path of the CPU: low byte, then high byte, a request a clock), then
 reads every word back and compares it with the pattern
     p(a) = a[15:0] ^ {a[20:16], a[20:16], a[20:16], 1'b0}      (every address bit changes some data bit)
 bad: the data bits that were wrong in some word; first: the first word that was wrong. active while it runs (the
 machines are held in reset meanwhile and the port is the test's). AW = 21: the whole 2M x 16, 6.3 M clocks (0.22 s).
*/

module sram_test #(
	parameter AW = 21
) (
	input wire clk,
	input wire start,

	output reg active = 1'b0,
	output reg done = 1'b0,
	output reg ok = 1'b0,
	output reg [15:0] bad = 16'd0,
	output reg [20:0] first = 21'd0,

	output reg c_req = 1'b0,
	output reg c_we = 1'b0,
	output reg [21:0] c_addr = 22'd0,
	output reg [7:0] c_din = 8'd0,
	input wire [15:0] q
);

function [15:0] pat;
	input [20:0] a;
	pat = a[15:0] ^ {a[20:16], a[20:16], a[20:16], 1'b0};
endfunction

localparam [20:0] LAST = (21'd1 << AW) - 1'd1;

reg [1:0] st = 2'd0;              // 0 idle, 1 write, 2 read, 3 the last words come
reg [20:0] a = 21'd0;
reg hi = 1'b0;
// the word of a read asked in clock k (c_req of this register) is q in clock k + 2: a1 / a2 / a3 follow it
reg [20:0] a1 = 21'd0, a2 = 21'd0, a3 = 21'd0;
reg v1 = 1'b0, v2 = 1'b0, v3 = 1'b0;
reg [1:0] tail = 2'd0;
wire [15:0] pa = pat(a);

always @(posedge clk) begin
	c_req <= 1'b0;
	c_we <= 1'b0;
	v1 <= 1'b0;
	{v2, a2} <= {v1, a1};
	{v3, a3} <= {v2, a2};
	if (v3 && q != pat(a3)) begin
		ok <= 1'b0;
		bad <= bad | (q ^ pat(a3));
		if (ok)
			first <= a3;
	end
	case (st)
		2'd0: if (start) begin
			active <= 1'b1;
			done <= 1'b0;
			ok <= 1'b1;
			bad <= 16'd0;
			first <= 21'd0;
			a <= 21'd0;
			hi <= 1'b0;
			st <= 2'd1;
		end
		2'd1: begin
			c_req <= 1'b1;
			c_we <= 1'b1;
			c_addr <= {a, hi};
			c_din <= hi ? pa[15:8] : pa[7:0];
			hi <= ~hi;
			if (hi) begin
				a <= (a == LAST) ? 21'd0 : a + 1'd1;
				if (a == LAST)
					st <= 2'd2;
			end
		end
		2'd2: begin
			c_req <= 1'b1;
			c_addr <= {a, 1'b0};
			a1 <= a;
			v1 <= 1'b1;
			a <= a + 1'd1;
			if (a == LAST) begin
				st <= 2'd3;
				tail <= 2'd0;
			end
		end
		default: begin
			tail <= tail + 1'd1;
			if (tail == 2'd3) begin
				active <= 1'b0;
				done <= 1'b1;
				st <= 2'd0;
			end
		end
	endcase
end

endmodule
