`timescale 1ns / 1ps
`default_nettype none

/*
 ay_psg.v

 The sound generator of an AY-3-8910 (AY only: 16 volume steps, 16-step envelope), write only: the registers
 are written by index (we, wa, wd), the reads of the CPU are answered by the register copies of the machine
 (pentagon.v), the I/O ports R14 / R15 are not here. The logic follows ym2149.v of MikeJ / Sorgelig (the
 counters count up, period 0 as 1), the envelope is a 16-step ramp with the shape bits of R13.

 Clock: clk_bus 28 MHz; the AY clock 1.75 MHz = clk / 16; tone counters at 1.75 MHz / 8 (every 128 clocks),
 noise and envelope at 1.75 MHz / 16 (every 256 clocks).
*/

module ay_psg (
	input wire clk,
	input wire we,
	input wire [3:0] wa,
	input wire [7:0] wd,
	output reg [7:0] ch_a = 8'd0,
	output reg [7:0] ch_b = 8'd0,
	output reg [7:0] ch_c = 8'd0
);

// registers (only the bits the AY has)
reg [11:0] tp_a = 12'd0, tp_b = 12'd0, tp_c = 12'd0;
reg [4:0] np = 5'd0;
reg [5:0] mix = 6'd0;           // R7 bits 5..0: 1 = tone / noise of A, B, C off
reg [4:0] vol_a = 5'd0, vol_b = 5'd0, vol_c = 5'd0;
reg [15:0] ep = 16'd0;
reg [3:0] shape = 4'd0;         // R13: C, At, Al, H
reg env_rst = 1'b0;

always @(posedge clk) begin
	env_rst <= 1'b0;
	if (we)
		case (wa)
			4'd0: tp_a[7:0] <= wd;
			4'd1: tp_a[11:8] <= wd[3:0];
			4'd2: tp_b[7:0] <= wd;
			4'd3: tp_b[11:8] <= wd[3:0];
			4'd4: tp_c[7:0] <= wd;
			4'd5: tp_c[11:8] <= wd[3:0];
			4'd6: np <= wd[4:0];
			4'd7: mix <= wd[5:0];
			4'd8: vol_a <= wd[4:0];
			4'd9: vol_b <= wd[4:0];
			4'd10: vol_c <= wd[4:0];
			4'd11: ep[7:0] <= wd;
			4'd12: ep[15:8] <= wd;
			4'd13: begin shape <= wd[3:0]; env_rst <= 1'b1; end
			default: ;
		endcase
end

// dividers: tick 1.75 MHz / 8, tick2 every second tick
reg [7:0] div = 8'd0;
always @(posedge clk)
	div <= div + 1'd1;
wire tick = (div[6:0] == 7'd0);
wire tick2 = (div == 8'd0);

// tones
reg [11:0] tc_a = 12'd0, tc_b = 12'd0, tc_c = 12'd0;
reg to_a = 1'b0, to_b = 1'b0, to_c = 1'b0;
always @(posedge clk)
	if (tick) begin
		if (tc_a + 1'd1 >= tp_a) begin tc_a <= 12'd0; to_a <= ~to_a; end else tc_a <= tc_a + 1'd1;
		if (tc_b + 1'd1 >= tp_b) begin tc_b <= 12'd0; to_b <= ~to_b; end else tc_b <= tc_b + 1'd1;
		if (tc_c + 1'd1 >= tp_c) begin tc_c <= 12'd0; to_c <= ~to_c; end else tc_c <= tc_c + 1'd1;
	end

// noise: 17-bit LFSR (taps 0, 3)
reg [4:0] nc = 5'd0;
reg [16:0] lfsr = 17'd1;
always @(posedge clk)
	if (tick2) begin
		if (nc + 1'd1 >= np) begin
			nc <= 5'd0;
			lfsr <= {lfsr[0] ^ lfsr[3], lfsr[16:1]};
		end else
			nc <= nc + 1'd1;
	end
wire no = lfsr[0];

// envelope: step s of the 16 of a ramp, par = the ramps so far are odd (alternate), hold
reg [15:0] ec = 16'd0;
reg [3:0] es = 4'd0;
reg epar = 1'b0;
reg ehold = 1'b0;
always @(posedge clk)
	if (env_rst) begin
		ec <= 16'd0;
		es <= 4'd0;
		epar <= 1'b0;
		ehold <= 1'b0;
	end else if (tick2) begin
		if (ec + 1'd1 >= ep) begin
			ec <= 16'd0;
			if (!ehold) begin
				es <= es + 1'd1;
				if (es == 4'd15) begin
					if (!shape[3] || shape[0])
						ehold <= 1'b1;
					else
						epar <= epar ^ shape[1];
				end
			end
		end else
			ec <= ec + 1'd1;
	end
// ramp: up when At ^ par; after the end (hold): 0 (C = 0), else At ^ Al = 1 -> 15
wire [3:0] env = ehold ? {4{shape[3] & (shape[2] ^ shape[1])}} : ((shape[2] ^ epar) ? es : ~es);

// mixer and volume (the levels of the AY: pairs of the 32 steps of ym2149.v)
function [7:0] level;
	input [3:0] v;
	case (v)
		4'd0: level = 8'h00;  4'd1: level = 8'h03;  4'd2: level = 8'h04;  4'd3: level = 8'h06;
		4'd4: level = 8'h0A;  4'd5: level = 8'h0F;  4'd6: level = 8'h15;  4'd7: level = 8'h22;
		4'd8: level = 8'h28;  4'd9: level = 8'h41;  4'd10: level = 8'h5B; 4'd11: level = 8'h72;
		4'd12: level = 8'h90; 4'd13: level = 8'hB5; 4'd14: level = 8'hD7; default: level = 8'hFF;
	endcase
endfunction

wire on_a = (mix[0] | to_a) & (mix[3] | no);
wire on_b = (mix[1] | to_b) & (mix[4] | no);
wire on_c = (mix[2] | to_c) & (mix[5] | no);

always @(posedge clk) begin
	ch_a <= on_a ? level(vol_a[4] ? env : vol_a[3:0]) : 8'd0;
	ch_b <= on_b ? level(vol_b[4] ? env : vol_b[3:0]) : 8'd0;
	ch_c <= on_c ? level(vol_c[4] ? env : vol_c[3:0]) : 8'd0;
end

endmodule
