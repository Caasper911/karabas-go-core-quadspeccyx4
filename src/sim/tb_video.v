`timescale 1ns / 1ps
`default_nettype none

/*
 tb_video.v

 The full screen path of the core: zx_timing, zx_scr (the screen of machine M through the video port of sram_ctrl,
 the SRAM model with random screen pages), vga_out on pclk = 21/8 clk_bus. The CPU port of sram_ctrl is busy as the
 eight machines can make it at most (8 reads in a row every 3 T-states, from clocks 0..7 of the T-state; BUSY=0:
 random, one clock of two). Every visible pixel of VGA is compared with the picture computed from the memory; the
 lines, rows and the frame period are checked (the frame of Pentagon: 1505280 pclk), after the first lock.

 WALL=1 (mode 1): the wall instead (wall_fetch.v): eight machines (two cell rows), machine m with the screen page
 7 when m[0] ^ m[2] and the border colour 3 m + 1; every pixel of the grid against the memory, SEL the selected cell.

 Defines: MODE (1: 1280 x 800, 0: 720 x 576), SCR7, FRAMES (default 3), BUSY, WALL, SEL. Prints "tb_video: <n> errors".
*/

`ifndef MODE
`define MODE 1
`endif
`ifndef FRAMES
`define FRAMES 3
`endif
`ifndef SCR7
`define SCR7 0
`endif
`ifndef BUSY
`define BUSY 1
`endif
`ifndef WALL
`define WALL 0
`endif
`ifndef SEL
`define SEL 5
`endif

module tb_video;

localparam [2:0] M = 3'd5;
localparam [2:0] BORDER = 3'd2;

// clocks: clk_sys half 7 ticks, pclk half 8 ticks of 0.849 ns (exact in ps), clk_bus = clk_sys / 3
reg clk_sys = 1'b0;
always #5.943 clk_sys = ~clk_sys;
reg pclk = 1'b0;
always #6.792 pclk = ~pclk;
reg clk_bus = 1'b0;
reg [1:0] div = 2'd0;
always @(posedge clk_sys) begin
	div <= (div == 2'd2) ? 2'd0 : div + 1'd1;
	if (div == 2'd2) clk_bus <= 1'b1;
	if (div == 2'd0) clk_bus <= 1'b0;
end

wire ce7, ce_cpu, ce14, vga_half, int_n;
wire [8:0] hc, vc, vga_x;
wire [4:0] frame;
wire [9:0] vga_p, vga_l;
zx_timing timing (
	.clk(clk_bus), .reset(1'b0), .ce7(ce7), .ce_cpu(ce_cpu), .ce14(ce14), .hc(hc), .vc(vc), .int_n(int_n),
	.frame(frame), .vga_x(vga_x), .vga_half(vga_half), .vga_p(vga_p), .vga_l(vga_l)
);
reg [2:0] slot = 3'd0;
always @(posedge clk_bus)
	slot <= ce_cpu ? 3'd1 : slot + 1'd1;

// the CPU port: reads only (the screen stays as loaded)
reg c_req = 1'b0;
reg [21:0] c_addr = 22'd0;
reg [4:0] t3 = 5'd0;              // clocks in 3 T-states
integer seed = 1;
always @(posedge clk_bus) begin
	t3 <= (ce_cpu && t3 >= 5'd16) ? 5'd0 : t3 + 1'd1;
	c_req <= `BUSY ? (t3 < 5'd8) : ($random(seed) & 1);
	c_addr <= $random(seed);
end

wire v_req, v_ack, s_req, w_req;
wire [20:0] v_addr, s_addr, w_addr;
assign v_req = (`WALL != 0) ? w_req : s_req;
assign v_addr = (`WALL != 0) ? w_addr : s_addr;
wire [15:0] q;
wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MRD_N, MWR_N;

sram_ctrl sram (
	.clk_bus(clk_bus), .clk_sys(clk_sys),
	.c_req(c_req), .c_we(1'b0), .c_addr(c_addr), .c_din(8'd0),
	.v_req(v_req), .v_addr(v_addr), .v_ack(v_ack), .q(q),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
);
sram_model model (.A(MA), .DQ(MD), .RD_N(MRD_N), .WR_N(MWR_N), .drv(sram.md_oe[0]));

wire [3:0] pix;
zx_scr scr (
	.clk(clk_bus), .ce7(ce7), .hc(hc), .vc(vc), .flash(frame[4]),
	.m({1'b0, M}), .scr7(`SCR7 != 0), .border(BORDER), .diag_en(1'b0), .diag(96'd0),
	.v_req(s_req), .v_addr(s_addr), .v_ack(v_ack & (`WALL == 0)), .q(q),
	.pix(pix)
);

// the wall: the border and the screen page of machine v_m as zx_oct gives them
wire [3:0] w_m;
wire wb_we;
wire [6:0] wb_addr;
wire [31:0] wb_data;
wire [23:0] brd;
function [2:0] m_brd;
	input [3:0] m;
	m_brd = 3 * m + 1;
endfunction
function m_scr7;
	input [3:0] m;
	m_scr7 = m[0] ^ m[2];
endfunction
wall_fetch #(.ROWS(2)) wall (
	.clk(clk_bus), .en(`WALL != 0), .ce7(ce7), .hc(hc), .vc(vc),
	.v_m(w_m), .v_border(m_brd(w_m)), .v_scr7(m_scr7(w_m)),
	.v_req(w_req), .v_addr(w_addr), .v_ack(v_ack & (`WALL != 0)), .q(q),
	.wb_we(wb_we), .wb_addr(wb_addr), .wb_data(wb_data), .brd(brd)
);

wire [7:0] r, g, b;
wire hs, vs, de, hs_neg, vs_neg;
vga_out vga (
	.clk(clk_bus), .ce7(ce7), .hc(hc), .vc(vc), .w_ce7(ce7), .w_hc(hc), .w_vc(vc), .pix(pix), .mode_i(`MODE != 0),
	.wall_i(`WALL != 0), .sel_i(4'd`SEL), .flash_i(frame[4]), .frame_col(3'd4), .rim_on(1'b1),
	.wb_we(wb_we), .wb_addr(wb_addr), .wb_data(wb_data), .brd_i(brd),
	.pclk(pclk), .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .de(de), .hs_neg(hs_neg), .vs_neg(vs_neg)
);

// ---------------------------------------------------------------------------------------------
// the screen pages 5 and 7 of machine M: random

integer i;
initial
	for (i = 0; i < (1 << 21); i = i + 1)
		model.mem[i] = $random(seed);

function [7:0] mbyte;              // byte o of the page of the screen of machine M
	input [13:0] o;
	reg [15:0] w;
	begin
		w = model.mem[{2'b00, M, (`SCR7 != 0) ? 3'd7 : 3'd5, o[13:1]}];
		mbyte = o[0] ? w[15:8] : w[7:0];
	end
endfunction

// the colour {bright, G, R, B} of Spectrum line sl, pixel hc (frame[4] is 0 in the first 16 frames: no flash)
function [3:0] zx_pix;
	input [8:0] sl;
	input [8:0] h;
	reg [7:0] bm, at;
	begin
		if ((h >= 9'd320 && h < 9'd384) || (sl >= 9'd240 && sl < 9'd256))
			zx_pix = 4'd0;
		else if (sl < 9'd192 && h < 9'd256) begin
			bm = mbyte({1'b0, sl[7:6], sl[2:0], sl[5:3], h[7:3]});
			at = mbyte({1'b0, 3'b110, sl[7:3], h[7:3]});
			zx_pix = bm[3'd7 - h[2:0]] ? {at[6], at[2:0]} : {at[6], at[5:3]};
		end else
			zx_pix = {1'b0, BORDER};
	end
endfunction

function [23:0] rgb;
	input [3:0] p;
	begin
		rgb[23:16] = p[1] ? (p[3] ? 8'hFF : 8'hCA) : 8'h00;
		rgb[15:8] = p[2] ? (p[3] ? 8'hFF : 8'hCA) : 8'h00;
		rgb[7:0] = p[0] ? (p[3] ? 8'hFF : 8'hCA) : 8'h00;
	end
endfunction

// the wall: the colour of paper pixel px, line pr of machine m
function [3:0] wall_pix;
	input [3:0] m;
	input [7:0] pr;
	input [7:0] px;
	reg [15:0] wb, wa;
	reg [7:0] bm, at;
	begin
		wb = model.mem[{2'b00, m[2:0], m_scr7(m) ? 3'd7 : 3'd5, 1'b0, pr[7:6], pr[2:0], pr[5:3], px[7:4]}];
		wa = model.mem[{2'b00, m[2:0], m_scr7(m) ? 3'd7 : 3'd5, 1'b0, 3'b110, pr[7:3], px[7:4]}];
		bm = px[3] ? wb[15:8] : wb[7:0];
		at = px[3] ? wa[15:8] : wa[7:0];
		wall_pix = bm[3'd7 - px[2:0]] ? {at[6], at[2:0]} : {at[6], at[5:3]};
	end
endfunction

// the expected colour of visible pixel x, y
function [23:0] expect_rgb;
	input integer x;
	input integer y;
	integer py, sx, cc, cx, cr, lc;
	reg [8:0] sl, h;
	begin
		if (`WALL != 0) begin
			cc = x / 320;
			cx = x % 320;
			cr = y / 200;
			lc = y % 200;
			if (cr >= 2)
				expect_rgb = 24'h303030;
			else if (cr * 4 + cc == `SEL && (cx < 2 || cx >= 318 || lc < 2 || lc >= 198))
				expect_rgb = 24'h00FF00;     // the frame of the selected cell: green
			else if (cx < 32 || cx >= 288 || lc < 4 || lc >= 196)
				expect_rgb = rgb({1'b0, m_brd(cr * 4 + cc)});
			else
				expect_rgb = rgb(wall_pix(cr * 4 + cc, lc - 4, cx - 32));
		end else if (`MODE != 0) begin
			py = (848 + y) % 960;
			// the whole 1280 x 800 at scale 3: the paper at x 255, its border 64 pixels each side, further out the
			// outermost border pixel of the line
			sl = py / 3;
			sx = x / 3;
			h = (sx < 21) ? 384 : (sx < 85) ? sx + 363 : (sx >= 405) ? 319 : sx - 85;
			expect_rgb = rgb(zx_pix(sl, h));
		end else begin
			py = (544 + y) % 640;
			sl = py / 2;
			sx = (4 * x) / 21;
			h = (sx < 56) ? sx + 392 : sx - 56;
			expect_rgb = rgb(zx_pix(sl, h));
		end
	end
endfunction

// ---------------------------------------------------------------------------------------------
// checks on pclk

localparam integer W = (`MODE != 0) ? 1280 : 1932;
localparam integer HROWS = (`MODE != 0) ? 800 : 576;
localparam integer HT = (`MODE != 0) ? 1568 : 2352;

integer errors = 0, shown = 0;
integer x = 0, y = 0, frames = 0, pix_checked = 0;
integer hs_n = 0, vs_n = 0, last_hs = -1, last_vs = -1, clk_n = 0;
reg de_d = 1'b0, hs_d = 1'b0, vs_d = 1'b0;
reg [23:0] e;

always @(posedge pclk) begin
	clk_n = clk_n + 1;
	de_d <= de;
	hs_d <= hs;
	vs_d <= vs;
	if (hs && !hs_d) begin
		if (frames >= 2 && last_hs >= 0 && clk_n - last_hs != HT) begin
			errors = errors + 1;
			$display("line of %0d pclk (frame %0d)", clk_n - last_hs, frames);
		end
		last_hs = clk_n;
	end
	if (vs && !vs_d) begin
		if (frames >= 2 && clk_n - last_vs != 1505280) begin
			errors = errors + 1;
			$display("frame of %0d pclk", clk_n - last_vs);
		end
		if (frames >= 2 && y != HROWS) begin
			errors = errors + 1;
			$display("frame %0d: %0d rows", frames, y);
		end
		last_vs = clk_n;
		frames = frames + 1;
		y = 0;
		if (frames == `FRAMES + 2) begin
			$display("tb_video: mode %0d, %0d frames, %0d pixels checked", `MODE, `FRAMES, pix_checked);
			$display("tb_video: %0d errors", errors);
			$finish;
		end
	end
	if (de) begin
		if (frames >= 2) begin
			e = expect_rgb(x, y);
			pix_checked = pix_checked + 1;
			if ({r, g, b} !== e) begin
				errors = errors + 1;
				if (shown < 20) begin
					shown = shown + 1;
					$display("frame %0d x %0d y %0d: %h, expected %h", frames, x, y, {r, g, b}, e);
				end
			end
		end
		x = x + 1;
	end else if (de_d) begin
		if (frames >= 2 && x != W) begin
			errors = errors + 1;
			$display("frame %0d row %0d: %0d pixels", frames, y, x);
		end
		x = 0;
		y = y + 1;
	end
	if (frames >= 2 && (hs_neg !== 1'b1 || vs_neg !== (`MODE == 0))) begin
		if (shown < 20) begin shown = shown + 1; $display("sync polarity"); end
		errors = errors + 1;
	end
end

endmodule
