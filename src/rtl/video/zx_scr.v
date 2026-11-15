`timescale 1ns / 1ps
`default_nettype none

/*
 zx_scr.v

 The picture of one machine (the selected one, m) on the raster of zx_timing: the screen fetch through the video port
 of sram_ctrl and the pixels, as the fetcher of pentagon.v of QuadSpeccy, but a word of the SRAM holds two
 characters: a fetch is a pair of characters 2j, 2j + 1 (the bitmap word, then the attribute word) into one of two
 pair buffers (j[0]). clk = clk_bus.

 A fetch of pair j of the next line starts at the end of a line (hc 436) for j = 0, else when hc + 16 >= 16 j: the
 buffer of j was last read at hc 16 j - 24. A read waits for a clock without a CPU request (at most 8 in a row: one
 request a clock, every machine at most one per 3 T-states) and its word is in q two clocks after v_ack, so a pair
 takes under 24 clocks of the 64 it has.

 The raster is that of machine m: zx_timing delayed by m clocks (speccywall.v), so border effects and multicolour are
 exact.

 pix is the colour of the pixel hc / vc of two ce7 before (as pentagon.v), {bright, G, R, B}. The border colour goes
 through two more ce7 (one T-state): zx_oct writes #FE at the start of T2 of the OUT, the Pentagon shows the new
 colour two pixels later; without it the border effects of RageEnd stood 2 pixels left of the paper they continue
 (src/sim/run_sna.sh, 2026-11-15).

 Diagnostics (diag_en): six rows of 16 squares, four in the top border (lines 284, 292, 300, 308) and two in the
 bottom one (196, 204), 6 lines each, squares 12 x 6 pixels every 16 from hc 0; row r shows diag[r*16 +: 16], bit 15
 on the left: 1 bright green, 0 bright red.
*/

module zx_scr (
	input wire clk,
	input wire ce7,
	input wire [8:0] hc,
	input wire [8:0] vc,
	input wire flash,                   // frame[4] of zx_timing

	input wire [3:0] m,                 // the machine: bit 3 the engine (the MB of SRAM), 2..0 the machine in it
	input wire scr7,                    // #7FFD bit 3 of machine m
	input wire [2:0] border,
	input wire diag_en,
	input wire [95:0] diag,

	output reg v_req = 1'b0,
	output reg [20:0] v_addr = 21'd0,
	input wire v_ack,
	input wire [15:0] q,

	output reg [3:0] pix = 4'd0
);

reg [8:0] tl = 9'd0;                // target line
reg [4:0] fj = 5'd16;               // pair being fetched, 16: none
reg [15:0] bmp0 = 16'd0, bmp1 = 16'd0, atr0 = 16'd0, atr1 = 16'd0;
reg [2:0] fst = 3'd0;               // 0 idle, 1 bitmap asked, 2/3 its word comes, 4 attribute asked, 5/6 its word
reg [12:0] bw = 13'd0;              // the word offsets in the page (byte offset / 2)
reg [12:0] aw = 13'd0;

wire [8:0] next_line = (vc == 9'd319) ? 9'd0 : vc + 1'd1;
wire fetch_ok = (fj == 5'd0) || ((vc == tl) && ({1'b0, hc} + 10'd16 >= {1'b0, fj[3:0], 4'b0000}));

always @(posedge clk) begin
	if (ce7 && hc == 9'd436) begin
		tl <= next_line;
		fj <= (next_line < 9'd192) ? 5'd0 : 5'd16;
		fst <= 3'd0;
		v_req <= 1'b0;
	end else begin
		case (fst)
			3'd0: if (!fj[4] && fetch_ok) begin
				// byte offsets: bitmap {tl[7:6], tl[2:0], tl[5:3], 2j}, attribute {110, tl[7:3], 2j}
				v_addr <= {1'b0, m, scr7 ? 3'd7 : 3'd5, 1'b0, tl[7:6], tl[2:0], tl[5:3], fj[3:0]};
				aw <= {1'b0, 3'b110, tl[7:3], fj[3:0]};
				v_req <= 1'b1;
				fst <= 3'd1;
			end
			3'd1: if (v_ack) begin
				v_req <= 1'b0;
				fst <= 3'd2;
			end
			3'd2: fst <= 3'd3;
			3'd3: begin
				if (fj[0]) bmp1 <= q; else bmp0 <= q;
				v_addr <= {1'b0, m, scr7 ? 3'd7 : 3'd5, aw};
				v_req <= 1'b1;
				fst <= 3'd4;
			end
			3'd4: if (v_ack) begin
				v_req <= 1'b0;
				fst <= 3'd5;
			end
			3'd5: fst <= 3'd6;
			default: begin
				if (fj[0]) atr1 <= q; else atr0 <= q;
				fj <= fj + 1'd1;
				fst <= 3'd0;
			end
		endcase
	end
end

// ---------------------------------------------------------------------------------------------
// pixels: stage 1 loads / shifts, stage 2 makes the colour (pentagon.v)

wire paper = (vc < 9'd192) && (hc < 9'd256);
wire blank = (hc >= 9'd320 && hc < 9'd384) || (vc >= 9'd240 && vc < 9'd256);
wire [15:0] bmp_w = hc[4] ? bmp1 : bmp0;
wire [15:0] atr_w = hc[4] ? atr1 : atr0;

reg [7:0] shreg = 8'd0;
reg [7:0] attr_r = 8'd0;
reg pap_r = 1'b0, blank_r = 1'b0;
reg [2:0] brd_r = 3'd0;
reg [2:0] brd_d1 = 3'd0, brd_d2 = 3'd0;     // the border one T-state later
// the diagnostics square of this pixel
wire dg_top = vc >= 9'd284 && vc < 9'd314;
wire dg_bot = vc >= 9'd196 && vc < 9'd210;
wire [8:0] dv = vc - (dg_top ? 9'd284 : 9'd196);
wire dg_on = diag_en && (dg_top || dg_bot) && dv[2:0] < 3'd6 && hc < 9'd256 && hc[3:0] < 4'd12;
wire [2:0] dg_row = dg_top ? {1'b0, dv[4:3]} : {2'b10, dv[3]};
wire [6:0] dg_i = {dg_row, ~hc[7:4]};
reg dg_r = 1'b0, dg_b = 1'b0;

always @(posedge clk)
	if (ce7) begin
		pap_r <= paper;
		blank_r <= blank;
		brd_d1 <= border;
		brd_d2 <= brd_d1;
		brd_r <= brd_d2;
		if (paper && hc[2:0] == 3'd0) begin
			shreg <= hc[3] ? bmp_w[15:8] : bmp_w[7:0];
			attr_r <= hc[3] ? atr_w[15:8] : atr_w[7:0];
		end else
			shreg <= {shreg[6:0], 1'b0};

		dg_r <= dg_on;
		dg_b <= diag[dg_i];
		if (dg_r)
			pix <= dg_b ? 4'b1100 : 4'b1010;
		else if (blank_r)
			pix <= 4'd0;
		else if (pap_r)
			pix <= (shreg[7] ^ (attr_r[7] & flash)) ? {attr_r[6], attr_r[2:0]} : {attr_r[6], attr_r[5:3]};
		else
			pix <= {1'b0, brd_r};
	end

endmodule
