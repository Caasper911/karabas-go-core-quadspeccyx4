`timescale 1ns / 1ps
`default_nettype none

/*
 vga_out.v

 The picture of one machine full screen, or the wall, on the pixel clock pclk = 21/8 clk_bus (73.6 MHz), locked to
 the Pentagon frame: 573440 clocks of clk_bus = 1505280 of pclk. Two rasters (mode, static: taken through two
 registers and applied by the next frame lock):

   mode 1  1280 x 800, total 1568 x 960 (48.88 Hz, 3 VGA lines per Spectrum line); the picture at scale 3 fills it:
           426 x 266 Spectrum pixels, the paper at x 255..1022, the border of the line around it (64 Spectrum pixels
           left and right, x 63..254 and 1023..1214; the pixels further out repeat the outermost one: x 0..62 that
           of hc 384, x 1215..1279 that of hc 319), lines 282..319 and 0..229 (the first and last of the 800 rows
           show a third of their line). hsync 128 (front porch 64, back 96) low, vsync 6 lines (front 3, back 151)
           high, as CVT 1280x800.
   mode 0  the raster of QuadSpeccy (720 x 576 p50 porches, 48.88 Hz): total 2352 x 640 pclk (896 x 640 of 28 MHz),
           2 VGA lines per Spectrum line, a Spectrum pixel 5.25 pclk (4 / 21 a clock): visible 368 x 288 Spectrum
           pixels (56 + 256 + 56, 48 + 192 + 48) = 1932 pclk x 576; hsync 168 (front 42, back 210), vsync 4 lines,
           both low.

 The lines: the pixels of the machine shown come from its raster (zx_vid.v, two a write: lb_we, lb_wa {line[1:0],
 pixel / 2}, lb_wd bits 3..0 the even pixel) into a ring of 4 line buffers on clk_bus; VGA row py shows Spectrum line
 py / 3 (py / 2) while zx_timing is at line py / 3 + 2 (the raster of the machine shown is up to 0.9 of a line
 behind: it writes line py / 3 + 1 or + 2): the counters of pclk are set to row 0 when zx_timing is at line 2, pixel
 0 (a toggle through three registers; set again only when they are more than 7 clocks off, so the lock does not
 jitter by the clock of the synchroniser). The left border (hc 384..447) of a row is that of the line before: the
 beam draws it before the paper of the next line.

 The wall (mode 1 and wall_i): instead of the full screen a grid of 4 x 4 cells of 320 x 200, the whole 1280 x 800,
 from the frame buffer (fb_sdram.v): at the start of each row the next one is asked for (rq_t toggles with rq_cr /
 rq_lc / rq_half), the four cells of a row come into the row buffer there (rb_addr {row parity, column, word}, rb_q
 4 pixels, bits 15..12 the leftmost); cell rows from ROWS on are grey (not built); the outer 2 pixels of the
 selected cell are in frame_col (bright, ZX colour {G, R, B}) while rim_on (the frame fade of the core hides it 2 s
 after a choice). py 0 is y 112: cell row 0, line 112.
 Without the border (nb_i, taken at the frame lock): the papers only, side by side, one field of 1024 x 768 in the
 middle (x 128..1151, y 16..783; black around): a cell is 256 x 192 (cell x 32..287, line 4..195 of the row
 buffer), the frame of the selected one on the outer 2 pixels of its paper; rq_f marks the first line shown of a
 cell row (line 0, without the border 4: fb_sdram takes the frame to show there).

 Out: rgb, hs / vs / de high active (the OSD overlay takes them so), hs_neg / vs_neg the polarity of the pins; 2 clocks
 of latency after the counters.
*/

module vga_out #(
	parameter ROWS = 4                  // the cell rows of machines in the wall
) (
	// clk_bus side
	input wire clk,
	input wire ce7,                     // the raster of zx_timing: the frame mark
	input wire [8:0] hc,
	input wire [8:0] vc,
	input wire lb_we,                   // the machine shown full screen: two pixels
	input wire [9:0] lb_wa,
	input wire [7:0] lb_wd,
	input wire mode_i,                  // 1: 1280 x 800
	input wire wall_i,                  // the wall (mode 1 only)
	input wire [3:0] sel_i,             // the selected machine
	input wire [2:0] frame_col,         // the frame of the selected cell: a ZX colour {G, R, B}
	input wire rim_on,                  // the frame is shown (static, clk_bus)
	input wire nb_i,                    // the wall without the border (static)

	// pclk side
	input wire pclk,
	// the frame buffer
	output reg rq_t = 1'b0,
	output reg [1:0] rq_cr = 2'd0,
	output reg [7:0] rq_lc = 8'd0,
	output reg rq_half = 1'b0,
	output reg rq_f = 1'b0,
	output reg [9:0] rb_addr = 10'd0,
	input wire [15:0] rb_q,

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

reg fe_t = 1'b0;
always @(posedge clk)
	if (ce7 && vc == 9'd2 && hc == 9'd0)
		fe_t <= ~fe_t;

wire [7:0] lb_q;
reg [9:0] lb_ra = 10'd0;
reg lb_hi = 1'b0, lb_hi_d = 1'b0;   // the odd pixel of the pair

kg_sdpram #(.DW(8), .AW(10)) linebuf (
	.clka(clk),
	.wea(lb_we),
	.addra(lb_wa),
	.dina(lb_wd),
	.clkb(pclk),
	.enb(1'b1),
	.addrb(lb_ra),
	.doutb(lb_q)
);
wire [3:0] lb_px = lb_hi_d ? lb_q[7:4] : lb_q[3:0];

// ---------------------------------------------------------------------------------------------
// pclk: the raster

reg [2:0] fe_s = 3'd0;
reg [1:0] mode_s = 2'd0, wall_s = 2'd0;
reg [3:0] sel_s = 4'd0;
reg [2:0] fcol_s = 3'd4;
reg [1:0] rim_s = 2'b11;
reg [1:0] nb_s = 2'b00;
reg nb = 1'b0;                                 // the wall without the border: nb_s at the frame lock
always @(posedge pclk) begin
	fe_s <= {fe_s[1:0], fe_t};
	mode_s <= {mode_s[0], mode_i};
	wall_s <= {wall_s[0], wall_i};
	sel_s <= sel_i;
	fcol_s <= frame_col;
	rim_s <= {rim_s[0], rim_on};
	nb_s <= {nb_s[0], nb_i};
end
wire wall = wall_s[1] && mode;
wire frame_ev = fe_s[2] ^ fe_s[1];
wire mode = mode_s[1];

wire [11:0] H = mode ? 12'd1568 : 12'd2352;
wire [1:0] LPL = mode ? 2'd3 : 2'd2;          // VGA lines per Spectrum line
wire [8:0] LB = mode ? 9'd85 : 9'd56;         // Spectrum pixels left of the paper (mode 1: 64 of them real)
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

wire [11:0] x_start = H - 1'd1;
// the Spectrum pixel of sx: the paper from LB, its border left (hc 384..447) and right (256..319), further out the
// outermost border pixel (mode 1: 21 pixels left, 22 right)
wire [8:0] sx_hc = (sx + 9'd64 < LB) ? 9'd384 : (sx < LB) ? sx + 9'd448 - LB :
                   (sx - LB >= 9'd320) ? 9'd319 : sx - LB;
// the left border (hc 384..447) of the line before: the beam draws it before the paper of the next line, so a border
// change in the blank (RageEnd) was a step of a line at the left of the paper (QuadSpeccy 6dd1362). Line sl - 1 is in
// the ring (the machine writes sl + 1 or sl + 2)
wire [1:0] sx_ln = (sx < LB) ? sl[1:0] - 1'd1 : sl[1:0];

always @(posedge pclk) begin
	if (frame_ev && (py != 10'd0 || hx > 12'd7)) begin
		hx <= 12'd0;
		py <= 10'd0;
		sl <= 9'd0;
		sub <= 2'd0;
		gy <= 10'd112;
		gcr <= 3'd0;
		glc <= nb_s[1] ? 8'd100 : 8'd112;
		nb <= nb_s[1];
	end else if (hx == H - 1'd1) begin
		hx <= 12'd0;
		gy <= (gy == 10'd959) ? 10'd0 : gy + 1'd1;
		gcr <= gcr_n;
		glc <= glc_n;
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

	lb_ra <= {sx_ln, sx_hc[8:1]};
	lb_hi <= sx_hc[0];
	lb_hi_d <= lb_hi;

	// (without the border the row starts at cell x 416 = -96: x 128 is cell x 32 of column 0)
	if (hx == H - 1'd1) begin
		gcc <= 2'd0;
		gcx <= nb ? 9'd416 : 9'd0;
	end else if (gcx == (nb ? 9'd287 : 9'd319)) begin
		gcc <= gcc + 1'd1;
		gcx <= nb ? 9'd32 : 9'd0;
	end else
		gcx <= gcx + 1'd1;
	rb_addr <= {gy[0], gcc, gcx[8:2]};

	// at the start of a row the next one into the other half of the row buffer
	if (hx == 12'd0) begin
		rq_t <= ~rq_t;
		rq_half <= ~gy[0];
		rq_cr <= gcr_n[1:0];
		rq_lc <= glc_n;
		rq_f <= glc_n == glc_first;
	end
end

// the windows of this clock (hx, py): visible, picture, syncs, frame
wire vis_x = mode ? (hx < 12'd1280) : (hx < 12'd1932);
wire vis_y = mode ? (py >= 10'd848 || py < 10'd688) : (py >= 10'd544 || py < 10'd480);
wire hs_x = mode ? (hx >= 12'd1344 && hx < 12'd1472) : (hx >= 12'd1974 && hx < 12'd2142);
wire vs_y = mode ? (py >= 10'd691 && py < 10'd697) : (py >= 10'd484 && py < 10'd488);
wire g_in = wall && hx < 12'd1280 && gy < 10'd800;
// without the border: the field of the papers (outside it black)
wire g_fld = !nb || (hx >= 12'd128 && hx < 12'd1152 && gy >= 10'd16 && gy < 10'd784);
wire g_edge = nb ? (gcx < 9'd34 || gcx >= 9'd286 || glc < 8'd6 || glc >= 8'd194) :
                   (gcx < 9'd2 || gcx >= 9'd318 || glc < 8'd2 || glc >= 8'd198);
// the cell row and line of the next VGA row (without the border the lines 4..195 of a cell; y 0 is line 244 = -12,
// so y 16 is line 4 of row 0)
wire [7:0] glc_last = nb ? 8'd195 : 8'd199;
wire [7:0] glc_first = nb ? 8'd4 : 8'd0;
wire [2:0] gcr_n = (gy == 10'd959) ? 3'd0 : (glc == glc_last) ? gcr + 1'd1 : gcr;
wire [7:0] glc_n = (gy == 10'd959) ? (nb ? 8'd244 : 8'd0) : (glc == glc_last) ? glc_first : glc + 1'd1;

// stage a (the addresses of the buffers are out), stage b (their words)
reg vis_a = 1'b0, hs_a = 1'b0, vs_a = 1'b0;
reg vis_b = 1'b0, hs_b = 1'b0, vs_b = 1'b0;
reg g_a = 1'b0, gabs_a = 1'b0, gsel_a = 1'b0;   // the wall: in a cell, absent, the frame of the selected one
reg g_b = 1'b0, gabs_b = 1'b0, gsel_b = 1'b0;
reg gfld_a = 1'b1, gfld_b = 1'b1;               // in the field of the papers (always with the border)
reg [1:0] gn_a = 2'd0, gn_b = 2'd0;             // the pixel in the word
wire [3:0] g_pix = (gn_b == 2'd0) ? rb_q[15:12] : (gn_b == 2'd1) ? rb_q[11:8] : (gn_b == 2'd2) ? rb_q[7:4] : rb_q[3:0];

always @(posedge pclk) begin
	vis_a <= vis_x && vis_y;
	hs_a <= hs_x;
	vs_a <= vs_y;
	{vis_b, hs_b, vs_b} <= {vis_a, hs_a, vs_a};
	g_a <= g_in;
	gabs_a <= gcr >= ROWS;
	gsel_a <= {gcr[1:0], gcc} == sel_s && g_edge && rim_s[1];
	gn_a <= gcx[1:0];
	{g_b, gabs_b, gsel_b, gn_b} <= {g_a, gabs_a, gsel_a, gn_a};
	gfld_a <= g_fld;
	gfld_b <= gfld_a;

	hs <= hs_b;
	vs <= vs_b;
	de <= vis_b;
	hs_neg <= 1'b1;
	vs_neg <= ~mode;
	if (!vis_b) begin
		r <= 8'd0; g <= 8'd0; b <= 8'd0;
	end else if (g_b) begin
		if (!gfld_b) begin
			r <= 8'd0; g <= 8'd0; b <= 8'd0;
		end else if (gabs_b) begin
			r <= 8'h30; g <= 8'h30; b <= 8'h30;
		end else if (gsel_b) begin
			r <= fcol_s[1] ? 8'hFF : 8'd0;
			g <= fcol_s[2] ? 8'hFF : 8'd0;
			b <= fcol_s[0] ? 8'hFF : 8'd0;
		end else begin
			r <= g_pix[1] ? (g_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
			g <= g_pix[2] ? (g_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
			b <= g_pix[0] ? (g_pix[3] ? 8'hFF : 8'hCA) : 8'd0;
		end
	end else begin
		r <= lb_px[1] ? (lb_px[3] ? 8'hFF : 8'hCA) : 8'd0;
		g <= lb_px[2] ? (lb_px[3] ? 8'hFF : 8'hCA) : 8'd0;
		b <= lb_px[0] ? (lb_px[3] ? 8'hFF : 8'hCA) : 8'd0;
	end
end

endmodule
