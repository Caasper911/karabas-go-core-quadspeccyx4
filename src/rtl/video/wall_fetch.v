`timescale 1ns / 1ps
`default_nettype none

/*
 wall_fetch.v

 The reader of the wall (1280 x 800, vga_out.v mode 1, wall): before every VGA row of the grid it reads the Spectrum
 line of the four machines of the cell row into the row buffer (in vga_out, written here on clk_bus, read on pclk).

 The grid (vga_out): 4 x 4 cells of 258 x 194 at x 124, y 12 of the visible 1280 x 800: the paper 256 x 192 at 1:1
 and a border of 1 pixel around it in the border colour of the machine; cell row cr, column c is machine 4 cr + c.
 Visible row y is VGA row py = (y + 848) mod 960; py 0 starts when the Spectrum is at line 2, pixel 0 (vga_out), and a
 row lasts 1568 pclk = 597 1/3 clocks of clk_bus: here rows of 597, 597, 598 clocks from that point.

 Eight clocks after the start of row R it reads for row R + 1 (target): for each of the four machines (ROWS cell rows
 are built; the others are not read) v_m = machine, two clocks later its border colour and screen page (v_border,
 v_scr7 of zx_oct) are taken; for a paper row (line lc 1..192 of the cell: Spectrum line lc - 1) the 16 bitmap and
 16 attribute words (pairs of characters) through the video port of sram_ctrl: v_req held, a word asked in every clock
 with v_ack, the word in q two clocks after its v_ack. Entry {par, c, w} of the row buffer = {attribute word, bitmap
 word} of pair w; par = the parity of the target row (vga_out reads the parity of its row). 128 reads in under
 600 clocks: the CPUs leave at least 2 of 3 clocks (one request a clock, a machine one per 3 T-states).

 The picture is the screen memory when it is read (not the exact moment of the beam: multicolour is not exact in the
 wall, the full screen is exact).
*/

module wall_fetch #(
	parameter ROWS = 2                  // the cell rows of machines (4 machines each)
) (
	input wire clk,
	input wire en,                      // the wall is shown: the video port and v_m are ours
	input wire ce7,
	input wire [8:0] hc,
	input wire [8:0] vc,

	output reg [3:0] v_m = 4'd0,
	input wire [2:0] v_border,
	input wire v_scr7,
	output reg v_req = 1'b0,
	output wire [20:0] v_addr,
	input wire v_ack,
	input wire [15:0] q,

	// the row buffer (vga_out): entry {par, c, w}
	output reg wb_we = 1'b0,
	output reg [6:0] wb_addr = 7'd0,
	output reg [31:0] wb_data = 32'd0,
	// the border colours of the four machines of the row of each parity: brd[par*12 + c*3 +: 3]
	output reg [23:0] brd = 24'd0
);

// ---------------------------------------------------------------------------------------------
// the rows: R the VGA row now, the target row R + 1: its visible y, cell row, line in the cell, parity

reg [9:0] rclk = 10'd0;             // clock in the row
reg [1:0] rsub = 2'd0;              // the row in the Spectrum line (597, 597, 598 clocks)
reg [9:0] ty = 10'd113;             // the target row: visible y (0..959, visible 0..799)
reg [2:0] tcr = 3'd0;               // its cell row (grid rows from y 12)
reg [7:0] tlc = 8'd101;             // its line in the cell, 0..193
reg tpar = 1'b1;

wire frame_ev = ce7 && vc == 9'd2 && hc == 9'd0;
wire row_end = rclk == ((rsub == 2'd2) ? 10'd597 : 10'd596);
wire start = rclk == 10'd8;      // well after the display of row R - 1 (the same parity as R + 1) ended

always @(posedge clk)
	if (frame_ev) begin
		// row 0 starts: the target row 1 is y (1 - 848) mod 960 = 113: cell row 0, line 101
		rclk <= 10'd0;
		rsub <= 2'd0;
		ty <= 10'd113;
		tcr <= 3'd0;
		tlc <= 8'd101;
		tpar <= 1'b1;
	end else if (row_end) begin
		rclk <= 10'd0;
		rsub <= (rsub == 2'd2) ? 2'd0 : rsub + 1'd1;
		tpar <= ~tpar;
		ty <= (ty == 10'd959) ? 10'd0 : ty + 1'd1;
		if (ty == 10'd11) begin
			tcr <= 3'd0;
			tlc <= 8'd0;
		end else if (tlc == 8'd193) begin
			tlc <= 8'd0;
			tcr <= tcr + 1'd1;
		end else
			tlc <= tlc + 1'd1;
	end else
		rclk <= rclk + 1'd1;

wire t_grid = ty >= 10'd12 && ty < 10'd788 && tcr < ROWS;

// ---------------------------------------------------------------------------------------------
// the reads of a row

reg [2:0] st = 3'd0;                // 0 idle, 1 v_m set, 2 its border / page come, 3 reads, 4 the last words come
reg [1:0] c = 2'd0;                 // the machine of the row being read
reg [1:0] cr = 2'd0;
reg [7:0] pr = 8'd0;                // its Spectrum line
reg paper = 1'b0;
reg par = 1'b0;
reg scr7 = 1'b0;
reg [3:0] w = 4'd0;                 // the pair asked
reg atr = 1'b0;                     // the attribute word of the pair is asked
reg [2:0] dn = 3'd0;                // clocks of the drain
reg [15:0] bmp = 16'd0;

// the asks in flight: {valid, attribute, pair} of the v_ack one and two clocks before
reg d1 = 1'b0, d2 = 1'b0, d1a = 1'b0, d2a = 1'b0;
reg [3:0] d1w = 4'd0, d2w = 4'd0;

wire [3:0] m = {cr, c};
wire [1:0] base = {1'b0, m[3]};      // machines 8..15: the second engine (milestone 6)
assign v_addr = atr ? {base, m[2:0], scr7 ? 3'd7 : 3'd5, 1'b0, 3'b110, pr[7:3], w}
                    : {base, m[2:0], scr7 ? 3'd7 : 3'd5, 1'b0, pr[7:6], pr[2:0], pr[5:3], w};

always @(posedge clk) begin
	wb_we <= 1'b0;
	{d2, d2a, d2w} <= {d1, d1a, d1w};
	d1 <= 1'b0;

	// a word comes
	if (d2) begin
		if (!d2a)
			bmp <= q;
		else begin
			wb_we <= 1'b1;
			wb_addr <= {par, c, d2w};
			wb_data <= {q, bmp};
		end
	end

	case (st)
		3'd0: if (start && t_grid && en) begin
			cr <= tcr[1:0];
			paper <= tlc != 8'd0 && tlc != 8'd193;
			pr <= tlc - 1'd1;
			par <= tpar;
			c <= 2'd0;
			st <= 3'd1;
		end
		3'd1: begin
			v_m <= m;
			st <= 3'd2;
		end
		3'd2: st <= 3'd3;
		3'd3: begin
			brd[{par, c} * 3 +: 3] <= v_border;
			scr7 <= v_scr7;
			w <= 4'd0;
			atr <= 1'b0;
			if (paper) begin
				v_req <= 1'b1;
				st <= 3'd4;
			end else
				st <= 3'd6;
		end
		3'd4: if (v_ack) begin
			d1 <= 1'b1;
			d1a <= atr;
			d1w <= w;
			atr <= ~atr;
			if (atr)
				w <= w + 1'd1;
			if (atr && w == 4'd15) begin
				v_req <= 1'b0;
				dn <= 3'd0;
				st <= 3'd5;
			end
		end
		3'd5: begin
			// the last word comes two clocks after its v_ack, written one later
			dn <= dn + 1'd1;
			if (dn == 3'd2)
				st <= 3'd6;
		end
		default: begin
			c <= c + 1'd1;
			st <= (c == 2'd3) ? 3'd0 : 3'd1;
		end
	endcase
end

endmodule
