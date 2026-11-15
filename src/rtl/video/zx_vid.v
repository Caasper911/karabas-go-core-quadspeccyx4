`timescale 1ns / 1ps
`default_nettype none

/*
 zx_vid.v

 The video of the eight machines of an engine (zx_oct, BASE), one logic for all, the state of each machine in contexts
 (distributed RAM indexed by the machine), as the bus logic of zx_oct. clk = clk_bus.

 Staggered rasters. Machine g = {BASE, k} runs its raster OFF(g) = 2 * STAGGER * g pixels (STAGGER * g T-states) after
 zx_timing (and k clocks, its slot, as before): the screens of the sixteen machines are read on their rasters from the
 SRAM, and not all at once (docs/ARCHITECTURE.md, "Буфер кадра"). Its INT too: int_th is the INT of the CPU of this
 slot (th = slot) as the raster of zx_timing at slot 0 (the value zx_oct took for all) gives it OFF earlier.

 Slot gm + 4 (gm = slot - 4) is the video of machine gm: the pixels e (even), e + 1 of its line v, e = hc of zx_timing
 at slot 4 - OFF (its raster delayed by gm clocks gives the same; the border is c_border of gm in this clock: after
 its bus slot gm + 1, as the old full screen sampled it for both pixels, at slots gm + 4 and gm + 8).

 Paper (v < 192, e < 256): a pair of characters (16 pixels) is one word of bitmap and one of attributes (the SRAM is
 16 bits). The pair j + 1 is asked at e = 16 j + FETCH_B (bitmap) and 16 j + FETCH_B + 2 (attribute) into the next
 pair buffer (nb, na: written by the returns of vid_fetch), pair 0 of the next line at e = 432 + FETCH_B; at
 e = 16 j the pair goes to the current one (cb, ca: written in the slot), its pixels from there. A word not back by
 then: late (sticky, debug).

 Out:
   the cell of the wall (320 x 200: paper 256 x 192 at x 32, line 4; the left border (x 0..31) is the pixels 416..447
   of the line before, the beam draws it before the paper): a word of 4 pixels (bits 15..12 the leftmost) for every
   other slot, w_* {machine, line parity, word}, and l_done when the last word of a cell line is out (x 316..319).
   The line lc 0..199 of the cell is the line 316..319, 0..195 of the machine.
   The full screen (fs_en, machine fs_m): its two pixels, p_* {v[1:0], e / 2} (bits 3..0 pixel e), and p_v, p_e.
   A pixel is {bright, G, R, B}; the blank (hc 320..383, lines 240..255) is 0.
*/

module zx_vid #(
	parameter BASE = 0,
	parameter STAGGER = 13,             // T-states between the rasters of machine g and g + 1
	parameter FETCH_B = 6               // the bitmap of the next pair asked at e[3:0] = FETCH_B, the attribute 2 later
	                                    // (4 T before the pair is shown; a word waits at most 21 clocks, tb_video)
) (
	input wire clk,
	input wire [2:0] slot,
	input wire [8:0] hc,
	input wire [8:0] vc,
	input wire [4:0] frame,

	output wire int_th,                 // INT (low active) of the CPU of this slot

	// the contexts of machine gm (zx_oct, read in this clock)
	output wire [2:0] gm,
	input wire [2:0] g_border,
	input wire g_scr7,

	// the screen reads (vid_fetch): one a clock; the words come back with their tag {machine, attribute}
	output reg f_req = 1'b0,
	output reg [20:0] f_addr = 21'd0,
	output reg [3:0] f_tag = 4'd0,
	input wire r_v,
	input wire [3:0] r_tag,
	input wire [15:0] r_q,

	// the cell of the wall
	output reg w_we = 1'b0,
	output reg [10:0] w_addr = 11'd0,
	output reg [15:0] w_data = 16'd0,
	output reg l_done = 1'b0,
	output reg [2:0] l_m = 3'd0,
	output reg [7:0] l_lc = 8'd0,

	// the full screen
	input wire fs_en,
	input wire [2:0] fs_m,
	output reg p_we = 1'b0,
	output reg [9:0] p_addr = 10'd0,
	output reg [7:0] p_data = 8'd0,
	output reg [8:0] p_v = 9'd0,
	output reg [8:0] p_e = 9'd0,

	output reg [7:0] late = 8'd0
);

// ---------------------------------------------------------------------------------------------
// the raster of a machine: zx_timing OFF pixels before (OFF < 448: at most a line back)

function [8:0] off_of;
	input [2:0] k;
	off_of = 2 * STAGGER * (8 * BASE + k);
endfunction

// {v, h} of the raster (V, H) OFF pixels before; borrow: the line before
function [18:0] back;
	input [8:0] V;
	input [8:0] H;
	input [8:0] OFF;
	reg [9:0] d;
	begin
		d = {1'b0, H} - {1'b0, OFF};
		if (d[9])
			back = {1'b1, (V == 9'd0) ? 9'd319 : V - 1'd1, H + 9'd448 - OFF};
		else
			back = {1'b0, V, d[8:0]};
	end
endfunction

// INT: the raster at slot 0, OFF of the CPU of this slot earlier: low for hc 313..375 of line 239 at slot 0 (zx_timing)
reg [8:0] h0r = 9'd0, v0r = 9'd0;
always @(posedge clk)
	if (slot == 3'd0) begin
		h0r <= hc;
		v0r <= vc;
	end
wire [18:0] ip = back((slot == 3'd0) ? vc : v0r, (slot == 3'd0) ? hc : h0r, off_of(slot));
assign int_th = !(ip[17:9] == 9'd239 && ip[8:0] >= 9'd313 && ip[8:0] <= 9'd375);

// the video slot: machine gm, the raster at slot 4
assign gm = slot - 3'd4;
reg [8:0] h4r = 9'd0, v4r = 9'd0;
reg [4:0] f4r = 5'd0;
always @(posedge clk)
	if (slot == 3'd4) begin
		h4r <= hc;
		v4r <= vc;
		f4r <= frame;
	end
wire [8:0] H4 = (slot == 3'd4) ? hc : h4r;
wire [8:0] V4 = (slot == 3'd4) ? vc : v4r;
wire [4:0] F4 = (slot == 3'd4) ? frame : f4r;
wire [18:0] gp = back(V4, H4, off_of(gm));
wire [8:0] v = gp[17:9];
wire [8:0] e = gp[8:0];
// the frame counts at the end of line 239: a machine still in it is a frame before
wire flash = (gp[18] && V4 == 9'd240) ? (F4[4] ^ (F4[3:0] == 4'd0)) : F4[4];

// ---------------------------------------------------------------------------------------------
// contexts

integer i;
reg [15:0] nb [0:7];                // the next pair: bitmap, attributes (written by the returns)
reg [15:0] na [0:7];
reg [15:0] cb [0:7];                // the pair shown (written in the slot)
reg [15:0] ca [0:7];
reg [7:0] gath [0:7];               // the first two pixels of a word of the cell
reg iss_b [0:7], iss_a [0:7], ret_b [0:7], ret_a [0:7];   // toggles: asked / back (pending = differ)
initial
	for (i = 0; i < 8; i = i + 1) begin
		nb[i] = 16'd0; na[i] = 16'd0; cb[i] = 16'd0; ca[i] = 16'd0; gath[i] = 8'd0;
		iss_b[i] = 1'b0; iss_a[i] = 1'b0; ret_b[i] = 1'b0; ret_a[i] = 1'b0;
	end

always @(posedge clk)
	if (r_v) begin
		if (r_tag[0]) begin
			na[r_tag[3:1]] <= r_q;
			ret_a[r_tag[3:1]] <= ~ret_a[r_tag[3:1]];
		end else begin
			nb[r_tag[3:1]] <= r_q;
			ret_b[r_tag[3:1]] <= ~ret_b[r_tag[3:1]];
		end
	end

// ---------------------------------------------------------------------------------------------
// the two pixels of machine gm

wire paper = (v < 9'd192) && (e < 9'd256);
wire blank = (e >= 9'd320 && e < 9'd384) || (v >= 9'd240 && v < 9'd256);
wire load = paper && e[3:0] == 4'd0;
wire [15:0] bm_w = load ? nb[gm] : cb[gm];
wire [15:0] at_w = load ? na[gm] : ca[gm];
wire [7:0] bm = e[3] ? bm_w[15:8] : bm_w[7:0];
wire [7:0] at = e[3] ? at_w[15:8] : at_w[7:0];
wire [2:0] bi = 3'd7 - e[2:0];       // the bit of pixel e (e[0] = 0), e + 1 the one below
wire ink0 = bm[bi] ^ (at[7] & flash);
wire ink1 = bm[bi - 1'd1] ^ (at[7] & flash);
wire [3:0] pp0 = ink0 ? {at[6], at[2:0]} : {at[6], at[5:3]};
wire [3:0] pp1 = ink1 ? {at[6], at[2:0]} : {at[6], at[5:3]};
wire [3:0] px0 = blank ? 4'd0 : paper ? pp0 : {1'b0, g_border};
wire [3:0] px1 = blank ? 4'd0 : paper ? pp1 : {1'b0, g_border};

// the cell: line lc, x (even)
reg c_in;
reg [7:0] lc;
reg [8:0] x;
always @* begin
	c_in = 1'b0;
	lc = 8'd0;
	x = 9'd0;
	if (e < 9'd288) begin
		x = e + 9'd32;
		if (v >= 9'd316) begin
			c_in = 1'b1;
			lc = v - 9'd316;
		end else if (v < 9'd196) begin
			c_in = 1'b1;
			lc = v + 9'd4;
		end
	end else if (e >= 9'd416) begin
		// the left border of the next line
		x = e - 9'd416;
		if (v >= 9'd315 && v != 9'd319) begin
			c_in = 1'b1;
			lc = v - 9'd315;
		end else if (v == 9'd319) begin
			c_in = 1'b1;
			lc = 8'd4;
		end else if (v < 9'd195) begin
			c_in = 1'b1;
			lc = v + 9'd5;
		end
	end
end

// the screen reads: the next pair of this line, or pair 0 of the next one
wire [8:0] nl = (v == 9'd319) ? 9'd0 : v + 1'd1;
wire f_in = (v < 9'd192) && (e < 9'd240) && (e[3:0] == FETCH_B || e[3:0] == FETCH_B + 2);
wire f_nx = (nl < 9'd192) && (e == 9'd432 + FETCH_B || e == 9'd434 + FETCH_B);
wire f_attr = (e[3:0] == FETCH_B + 2);
wire [8:0] fl = f_nx ? nl : v;
wire [3:0] fj = f_nx ? 4'd0 : e[7:4] + 1'd1;
wire [3:0] fm = {BASE[0], gm};

always @(posedge clk) begin
	f_req <= f_in | f_nx;
	f_tag <= {gm, f_attr};
	f_addr <= f_attr ? {1'b0, fm, g_scr7 ? 3'd7 : 3'd5, 1'b0, 3'b110, fl[7:3], fj} :
	                   {1'b0, fm, g_scr7 ? 3'd7 : 3'd5, 1'b0, fl[7:6], fl[2:0], fl[5:3], fj};
	if (f_in | f_nx) begin
		if (f_attr)
			iss_a[gm] <= ~iss_a[gm];
		else
			iss_b[gm] <= ~iss_b[gm];
	end
	if (load) begin
		cb[gm] <= nb[gm];
		ca[gm] <= na[gm];
		if (iss_b[gm] != ret_b[gm] || iss_a[gm] != ret_a[gm])
			late[gm] <= 1'b1;
	end

	w_we <= 1'b0;
	l_done <= 1'b0;
	if (c_in) begin
		if (!x[1])
			gath[gm] <= {px0, px1};
		else begin
			w_we <= 1'b1;
			w_addr <= {gm, lc[0], x[8:2]};
			w_data <= {gath[gm], px0, px1};
			if (x == 9'd318) begin
				l_done <= 1'b1;
				l_m <= gm;
				l_lc <= lc;
			end
		end
	end

	p_we <= fs_en && gm == fs_m;
	p_addr <= {v[1:0], e[8:1]};
	p_data <= {px1, px0};
	p_v <= v;
	p_e <= e;
end

endmodule
