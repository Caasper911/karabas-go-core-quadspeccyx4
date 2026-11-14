`timescale 1ns / 1ps
`default_nettype none

/*
 vga_out.v

 The picture of one machine full screen on the pixel clock pclk = 21/8 clk_bus (73.6 MHz, the second PLL), locked to
 the Pentagon frame: 573440 clocks of clk_bus = 1505280 of pclk. Two rasters (mode, static: taken through two
 registers and applied by the next frame lock):

   mode 1  1280 x 800, total 1568 x 960 (48.88 Hz, 3 VGA lines per Spectrum line); the picture at scale 3: 352 x 266
           Spectrum pixels (48 of border left and right, 37 lines top and bottom) = 1056 x 798 at x 112, y 1; around it
           a 1 pixel grey frame on the edges of the 1280 x 800 and black, or with stripes = 1 vertical stripes of 1
           pixel (the phase of the monitor). hsync 128 (front porch 64, back 96) low, vsync 6 lines (front 3, back 151)
           high, as CVT 1280x800.
   mode 0  the raster of QuadSpeccy (720 x 576 p50 porches, 48.88 Hz): total 2352 x 640 pclk (896 x 640 of 28 MHz),
           2 VGA lines per Spectrum line, a Spectrum pixel 5.25 pclk (4 / 21 a clock): visible 368 x 288 Spectrum
           pixels (56 + 256 + 56, 48 + 192 + 48) = 1932 pclk x 576; hsync 168 (front 42, back 210), vsync 4 lines,
           both low.

 The lines: pix (zx_scr.v, the colour of hc / vc two ce7 before) goes into a ring of 4 line buffers (vc[1:0]) on
 clk_bus; VGA row py shows Spectrum line py / 3 (py / 2) while the Spectrum writes line py / 3 + 2: the counters of
 pclk are set to row 0 when the Spectrum is at line 2, pixel 0 (a toggle through three registers; set again only
 when they are more than 7 clocks off, so the lock does not jitter by the clock of the synchroniser).

 The wall (mode 1 and wall_i): instead of the full screen a grid of 4 x 4 cells of 320 x 200, the whole 1280 x 800:
 the paper of machine 4 cr + c at 1:1 in the middle (x 32..287, lines 4..195) and its border colour around it; cell
 rows from ROWS on are grey (not built); the outer pixel of the selected cell blinks white with flash_i. The rows come from wall_fetch.v: a row buffer
 of 2 x 4 x 16 entries of {attribute word, bitmap word} of a pair of characters (written on clk_bus, read on pclk),
 entry {py[0], c, pair}, and the border colours brd_i[py[0]*12 + c*3 +: 3]; the cell row and the line in the cell
 count with py (py 0 is y 112: cell row 0, line 112).

 Out: rgb, hs / vs / de high active (the OSD overlay takes them so), hs_neg / vs_neg the polarity of the pins; 2 clocks
 of latency after the counters.
*/

module vga_out #(
	parameter ROWS = 2                  // the cell rows of machines in the wall
) (
	// clk_bus side
	input wire clk,
	input wire ce7,
	input wire [8:0] hc,
	input wire [8:0] vc,
	input wire [3:0] pix,
	input wire mode_i,                  // 1: 1280 x 800
	input wire stripes_i,
	input wire wall_i,                  // the wall (mode 1 only)
	input wire [3:0] sel_i,             // the selected machine
	input wire flash_i,                 // frame[4]: the flash of attributes, the blink of the selected cell
	input wire wb_we,                   // the row buffer of the wall (wall_fetch.v)
	input wire [6:0] wb_addr,
	input wire [31:0] wb_data,
	input wire [23:0] brd_i,

	// pclk side
	input wire pclk,
	output reg [7:0] r = 8'd0,
	output reg [7:0] g = 8'd0,
	output reg [7:0] b = 8'd0,
	output reg hs = 1'b0,
	output reg vs = 1'b0,
	output reg de = 1'b0,
	output reg hs_neg = 1'b1,
	output reg vs_neg = 1'b1
);

// ---------------------------------------------------------------------------------------------
// clk_bus: the line buffers, the frame mark

reg [8:0] hd1 = 9'd0, hd2 = 9'd0;
reg [1:0] vd1 = 2'd0, vd2 = 2'd0;
reg fe_t = 1'b0;

always @(posedge clk)
	if (ce7) begin
		hd1 <= hc;
		hd2 <= hd1;
		vd1 <= vc[1:0];
		vd2 <= vd1;
		if (vc == 9'd2 && hc == 9'd0)
			fe_t <= ~fe_t;
	end

wire [3:0] lb_q;
reg [10:0] lb_ra = 11'd0;

kg_sdpram #(.DW(4), .AW(11)) linebuf (
	.clka(clk),
	.wea(ce7),
	.addra({vd2, hd2}),
	.dina(pix),
	.clkb(pclk),
	.enb(1'b1),
	.addrb(lb_ra),
	.doutb(lb_q)
);

// ---------------------------------------------------------------------------------------------
// pclk: the raster

reg [2:0] fe_s = 3'd0;
reg [1:0] mode_s = 2'd0, str_s = 2'd0, wall_s = 2'd0, fl_s = 2'd0;
reg [3:0] sel_s = 4'd0;
always @(posedge pclk) begin
	fe_s <= {fe_s[1:0], fe_t};
	mode_s <= {mode_s[0], mode_i};
	str_s <= {str_s[0], stripes_i};
	wall_s <= {wall_s[0], wall_i};
	fl_s <= {fl_s[0], flash_i};
	sel_s <= sel_i;
end
wire wall = wall_s[1] && mode;
wire frame_ev = fe_s[2] ^ fe_s[1];
wire mode = mode_s[1];

wire [11:0] H = mode ? 12'd1568 : 12'd2352;
wire [1:0] LPL = mode ? 2'd3 : 2'd2;          // VGA lines per Spectrum line
wire [11:0] X0 = mode ? 12'd112 : 12'd0;      // the first pclk of the picture
wire [8:0] LB = mode ? 9'd48 : 9'd56;         // Spectrum pixels of the left border shown
wire [4:0] NUM = mode ? 5'd1 : 5'd4;          // a Spectrum pixel is DEN / NUM pclk
wire [4:0] DEN = mode ? 5'd3 : 5'd21;

reg [11:0] hx = 12'd0;
reg [9:0] py = 10'd0;
reg [8:0] sl = 9'd0;                           // the Spectrum line shown: py / LPL
reg [1:0] sub = 2'd0;
reg [8:0] sx = 9'd0;                           // the Spectrum pixel from the left of the picture
reg [4:0] acc = 5'd0;
reg [9:0] gy = 10'd112;                        // the wall: visible y of this row, its cell row and line in the cell
reg [2:0] gcr = 3'd0;
reg [7:0] glc = 8'd112;
reg [1:0] gcc = 2'd0;                          // the cell column and the pixel in the cell of this clock
reg [8:0] gcx = 9'd0;
wire [8:0] gpx = gcx - 6'd32;                   // the paper pixel 0..255 (gcx 32..287)
reg [6:0] rb_ra = 7'd0;
wire [31:0] rb_q;

wire [11:0] x_start = (X0 == 12'd0) ? H - 1'd1 : X0 - 1'd1;
wire [8:0] sx_hc = (sx < LB) ? sx + 9'd448 - LB : sx - LB;

always @(posedge pclk) begin
	if (frame_ev && (py != 10'd0 || hx > 12'd7)) begin
		hx <= 12'd0;
		py <= 10'd0;
		sl <= 9'd0;
		sub <= 2'd0;
		gy <= 10'd112;
		gcr <= 3'd0;
		glc <= 8'd112;
	end else if (hx == H - 1'd1) begin
		hx <= 12'd0;
		gy <= (gy == 10'd959) ? 10'd0 : gy + 1'd1;
		if (gy == 10'd959) begin
			gcr <= 3'd0;
			glc <= 8'd0;
		end else if (glc == 8'd199) begin
			glc <= 8'd0;
			gcr <= gcr + 1'd1;
		end else
			glc <= glc + 1'd1;
		if (sub == LPL - 1'd1) begin
			sub <= 2'd0;
			sl <= (sl == 9'd319) ? 9'd0 : sl + 1'd1;
			py <= (sl == 9'd319) ? 10'd0 : py + 1'd1;
		end else begin
			sub <= sub + 1'd1;
			py <= py + 1'd1;
		end
	end else
		hx <= hx + 1'd1;

	if (hx == x_start) begin
		sx <= 9'd0;
		acc <= 5'd0;
	end else if (acc + NUM >= DEN) begin
		sx <= sx + 1'd1;
		acc <= acc + NUM - DEN;
	end else
		acc <= acc + NUM;

	lb_ra <= {sl[1:0], sx_hc};

	if (hx == H - 1'd1) begin
		gcc <= 2'd0;
		gcx <= 9'd0;
	end else if (gcx == 9'd319) begin
		gcc <= gcc + 1'd1;
		gcx <= 9'd0;
	end else
		gcx <= gcx + 1'd1;
	rb_ra <= {py[0], gcc, gpx[7:4]};
end

// the row buffer of the wall
kg_sdpram #(.DW(32), .AW(7)) rowbuf (
	.clka(clk),
	.wea(wb_we),
	.addra(wb_addr),
	.dina(wb_data),
	.clkb(pclk),
	.enb(1'b1),
	.addrb(rb_ra),
	.doutb(rb_q)
);

// the windows of this clock (hx, py): visible, picture, syncs, frame
wire vis_x = mode ? (hx < 12'd1280) : (hx < 12'd1932);
wire vis_y = mode ? (py >= 10'd848 || py < 10'd688) : (py >= 10'd544 || py < 10'd480);
wire pic_x = mode ? (hx >= 12'd112 && hx < 12'd1168) : vis_x;
wire pic_y = mode ? (py >= 10'd849 || py < 10'd687) : vis_y;
wire hs_x = mode ? (hx >= 12'd1344 && hx < 12'd1472) : (hx >= 12'd1974 && hx < 12'd2142);
wire vs_y = mode ? (py >= 10'd691 && py < 10'd697) : (py >= 10'd484 && py < 10'd488);
wire edge_px = hx == 12'd0 || hx == 12'd1279 || py == 10'd848 || py == 10'd687;
wire g_in = wall && hx < 12'd1280 && gy < 10'd800;
wire g_brdx = gcx < 9'd32 || gcx >= 9'd288 || glc < 8'd4 || glc >= 8'd196;
wire g_edge = gcx == 9'd0 || gcx == 9'd319 || glc == 8'd0 || glc == 8'd199;

// stage a (the address of the line buffer is out), stage b (its colour)
reg vis_a = 1'b0, pic_a = 1'b0, hs_a = 1'b0, vs_a = 1'b0, edge_a = 1'b0, str_a = 1'b0;
reg vis_b = 1'b0, pic_b = 1'b0, hs_b = 1'b0, vs_b = 1'b0, edge_b = 1'b0, str_b = 1'b0;
reg g_a = 1'b0, gb_a = 1'b0, gabs_a = 1'b0, gsel_a = 1'b0, gh_a = 1'b0;   // the wall: in a cell, its border, absent,
reg g_b = 1'b0, gb_b = 1'b0, gabs_b = 1'b0, gsel_b = 1'b0, gh_b = 1'b0;   // selected, the high byte of the word
reg [2:0] gbit_a = 3'd0, gbit_b = 3'd0, gbc_a = 3'd0, gbc_b = 3'd0;      // the bit, the border colour
wire [7:0] g_bm = gh_b ? rb_q[15:8] : rb_q[7:0];
wire [7:0] g_at = gh_b ? rb_q[31:24] : rb_q[23:16];
wire g_ink = g_bm[3'd7 - gbit_b] ^ (g_at[7] & fl_s[1]);
wire [3:0] g_pix = g_ink ? {g_at[6], g_at[2:0]} : {g_at[6], g_at[5:3]};

always @(posedge pclk) begin
	vis_a <= vis_x && vis_y;
	pic_a <= pic_x && pic_y;
	hs_a <= hs_x;
	vs_a <= vs_y;
	edge_a <= mode && edge_px;
	str_a <= mode && str_s[1] && hx[0];
	{vis_b, pic_b, hs_b, vs_b, edge_b, str_b} <= {vis_a, pic_a, hs_a, vs_a, edge_a, str_a};
	g_a <= g_in;
	gb_a <= g_brdx;
	gabs_a <= gcr >= ROWS;
	gsel_a <= {gcr[1:0], gcc} == sel_s && fl_s[1] && g_edge;
	gh_a <= gpx[3];
	gbit_a <= gpx[2:0];
	gbc_a <= brd_i[{py[0], gcc} * 3 +: 3];
	{g_b, gb_b, gabs_b, gsel_b, gh_b, gbit_b, gbc_b} <= {g_a, gb_a, gabs_a, gsel_a, gh_a, gbit_a, gbc_a};

	hs <= hs_b;
	vs <= vs_b;
	de <= vis_b;
	hs_neg <= 1'b1;
	vs_neg <= ~mode;
	if (!vis_b) begin
		r <= 8'd0; g <= 8'd0; b <= 8'd0;
	end else if (g_b) begin
		if (gabs_b) begin
			r <= 8'h30; g <= 8'h30; b <= 8'h30;
		end else if (gb_b && gsel_b) begin
			r <= 8'hFF; g <= 8'hFF; b <= 8'hFF;
		end else if (gb_b) begin
			r <= gbc_b[1] ? 8'hCA : 8'd0;
			g <= gbc_b[2] ? 8'hCA : 8'd0;
			b <= gbc_b[0] ? 8'hCA : 8'd0;
		end else begin
			r <= g_pix[1] ? (g_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
			g <= g_pix[2] ? (g_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
			b <= g_pix[0] ? (g_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
		end
	end else if (pic_b && !wall) begin
		r <= lb_q[1] ? (lb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
		g <= lb_q[2] ? (lb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
		b <= lb_q[0] ? (lb_q[3] ? 8'hFF : 8'hCA) : 8'd0;
	end else if (edge_b) begin
		r <= 8'h80; g <= 8'h80; b <= 8'h80;
	end else if (str_b) begin
		r <= 8'hFF; g <= 8'hFF; b <= 8'hFF;
	end else begin
		r <= 8'd0; g <= 8'd0; b <= 8'd0;
	end
end

endmodule
