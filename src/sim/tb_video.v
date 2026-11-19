`timescale 1ns / 1ps

/*
 tb_video.v

 The video path of the core: zx_timing, two zx_vid (16 machines, staggered rasters) reading their screens through
 vid_fetch from the SRAM (sram_ctrl + sram_model, the CPU port as busy as 16 machines make it: BUSY), the frame
 buffer (fb_sdram + sdram_model) and vga_out, 1280 x 800. Every visible pixel is checked:
   WALL=1 (default) the wall: cell (cr, c) shows machine 4 cr + c, its paper from the memory (random, page 7 when
          g[0] ^ g[2]) and its border, which the testbench gives each machine as a function of its raster position
          (the position written again here) and, with CFT=1, of its cell frame (counted when its raster passes line
          315, pixel 416, where line 0 of a cell starts): all pixels of a cell in one VGA frame must come from one
          frame of the machine (no tearing).
   NB=1   the wall without the border: the papers side by side, one field of 1024 x 768 at x 128, y 16, black
          around; the border is not seen, so the frame shown of each cell row (fb_sdram fd) must change every VGA
          frame (the frame is taken at the first line shown, line 4 then).
   WALL=0 the full screen of machine FS (scale 3), the left border from the line before.
   MODE=2 1280 x 800 at 60 Hz (vga_out mode 2, not locked to the machines): the wall as above (but the frame shown
          of a cell row changes in most VGA frames only), the full screen (WALL=0) the cell of FS at scale 4, from
          one frame of the machine (CFT); the raster 1488 x 824 checked.
 Also the SDRAM model checks its timing, vid_fetch and zx_vid say when a word was late or a queue overflowed.
 Prints "tb_video: <n> errors".
*/

`ifndef FRAMES
`define FRAMES 4
`endif
`ifndef WALL
`define WALL 1
`endif
`ifndef FS
`define FS 5
`endif
`ifndef BUSY
`define BUSY 1
`endif
`ifndef CFT
`define CFT 1
`endif
`ifndef NB
`define NB 0
`endif
`ifndef MODE
`define MODE 1
`endif

module tb_video;

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

// ---------------------------------------------------------------------------------------------
// the machines as the testbench sees them

function scr7_of;
	input [3:0] g;
	scr7_of = g[0] ^ g[2];
endfunction

// the raster position of machine g given the raster (V, H) of zx_timing: 26 g pixels before (STAGGER 13)
function [17:0] mpos;
	input [3:0] g;
	input [8:0] V;
	input [8:0] H;
	integer off;
	begin
		off = 26 * g;
		if (H >= off)
			mpos = {V, H - off[8:0]};
		else
			mpos = {(V == 0) ? 9'd319 : V - 1'd1, H + 9'd448 - off[8:0]};
	end
endfunction

function [2:0] hash;
	input [3:0] g;
	input [8:0] v;
	input [8:0] e;
	hash = (v[2:0] ^ e[3:1] ^ e[6:4] ^ v[5:3]) + 3 * g;
endfunction

integer cf [0:15];                  // the cell frame of each machine
integer ci;
initial for (ci = 0; ci < 16; ci = ci + 1) cf[ci] = 0;

reg [8:0] h4r = 9'd0, v4r = 9'd0;
always @(posedge clk_bus)
	if (slot == 3'd4) begin
		h4r <= hc;
		v4r <= vc;
	end
wire [8:0] H4 = (slot == 3'd4) ? hc : h4r;
wire [8:0] V4 = (slot == 3'd4) ? vc : v4r;
wire [2:0] tgm = slot - 3'd4;
wire [17:0] p0 = mpos({1'b0, tgm}, V4, H4);
wire [17:0] p1 = mpos({1'b1, tgm}, V4, H4);
wire n0 = p0 == {9'd315, 9'd416};      // a new cell frame starts with this pair
wire n1 = p1 == {9'd315, 9'd416};
wire [2:0] brd0 = hash({1'b0, tgm}, p0[17:9], p0[8:0]) + ((`CFT != 0) ? cf[{1'b0, tgm}] + n0 : 0);
wire [2:0] brd1 = hash({1'b1, tgm}, p1[17:9], p1[8:0]) + ((`CFT != 0) ? cf[{1'b1, tgm}] + n1 : 0);
always @(posedge clk_bus) begin
	if (n0) cf[{1'b0, tgm}] = cf[{1'b0, tgm}] + 1;
	if (n1) cf[{1'b1, tgm}] = cf[{1'b1, tgm}] + 1;
end

// ---------------------------------------------------------------------------------------------
// the design

wire [1:0] f_req, w_we, l_done, r_v;
wire [41:0] f_addr;
wire [7:0] f_tag;
wire [3:0] r_tag;
wire [15:0] r_q;
wire [21:0] w_addr;
wire [31:0] w_data;
wire [5:0] l_m, gm;
wire [15:0] l_lc;
wire [7:0] late0, late1;
wire [1:0] p_we;
wire [19:0] p_addr;
wire [15:0] p_data;
wire it0, it1;

zx_vid #(.BASE(0)) vid0 (
	.clk(clk_bus), .slot(slot), .hc(hc), .vc(vc), .frame(frame), .int_th(it0),
	.gm(gm[2:0]), .g_border(brd0), .g_scr7(scr7_of({1'b0, gm[2:0]})),
	.f_req(f_req[0]), .f_addr(f_addr[20:0]), .f_tag(f_tag[3:0]), .r_v(r_v[0]), .r_tag(r_tag), .r_q(r_q),
	.w_we(w_we[0]), .w_addr(w_addr[10:0]), .w_data(w_data[15:0]), .l_done(l_done[0]), .l_m(l_m[2:0]), .l_lc(l_lc[7:0]),
	.fs_en(`FS < 8), .fs_m(`FS % 8), .p_we(p_we[0]), .p_addr(p_addr[9:0]), .p_data(p_data[7:0]), .p_v(), .p_e(),
	.late(late0)
);
zx_vid #(.BASE(1)) vid1 (
	.clk(clk_bus), .slot(slot), .hc(hc), .vc(vc), .frame(frame), .int_th(it1),
	.gm(gm[5:3]), .g_border(brd1), .g_scr7(scr7_of({1'b1, gm[5:3]})),
	.f_req(f_req[1]), .f_addr(f_addr[41:21]), .f_tag(f_tag[7:4]), .r_v(r_v[1]), .r_tag(r_tag), .r_q(r_q),
	.w_we(w_we[1]), .w_addr(w_addr[21:11]), .w_data(w_data[31:16]), .l_done(l_done[1]), .l_m(l_m[5:3]),
	.l_lc(l_lc[15:8]),
	.fs_en(`FS >= 8), .fs_m(`FS % 8), .p_we(p_we[1]), .p_addr(p_addr[19:10]), .p_data(p_data[15:8]), .p_v(), .p_e(),
	.late(late1)
);

// the CPU port: reads only (the screens stay as loaded), at most one a clock, 16 machines at one per 3 T-states
reg c_req = 1'b0;
reg [21:0] c_addr = 22'd0;
reg [4:0] t3 = 5'd0;
integer seed = 1;
always @(posedge clk_bus) begin
	t3 <= (ce_cpu && t3 >= 5'd16) ? 5'd0 : t3 + 1'd1;
	c_req <= `BUSY ? (t3 < 5'd16) : ($random(seed) & 1);
	c_addr <= $random(seed);
end

wire v_req, v_ack, over_f;
wire [20:0] v_addr;
wire [15:0] q;
wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MRD_N, MWR_N;

vid_fetch vf (
	.clk(clk_bus), .f_req(f_req), .f_addr(f_addr), .f_tag(f_tag),
	.v_req(v_req), .v_addr(v_addr), .v_ack(v_ack), .q(q),
	.r_v(r_v), .r_tag(r_tag), .r_q(r_q), .over(over_f)
);
sram_ctrl sram (
	.clk_bus(clk_bus), .clk_sys(clk_sys),
	.c_req(c_req), .c_we(1'b0), .c_addr(c_addr), .c_din(8'd0),
	.v_req(v_req), .v_addr(v_addr), .v_ack(v_ack), .q(q),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
);
sram_model model (.A(MA), .DQ(MD), .RD_N(MRD_N), .WR_N(MWR_N), .drv(sram.md_oe[0]));

wire rq_t, rq_half, rq_f, fb_ready, over_l;
wire [1:0] rq_cr;
wire [7:0] rq_lc;
wire [9:0] rb_addr;
wire [15:0] rb_q;
wire SDR_CLK, SDR_RAS_N, SDR_CAS_N, SDR_WE_N;
wire [1:0] SDR_BA, SDR_DQM;
wire [12:0] SDR_A;
wire [15:0] SDR_DQ;

fb_sdram #(.INIT_WAIT(16'd200)) fb (
	.clk(clk_sys), .clk_bus(clk_bus), .pclk(pclk),
	.w_we(w_we), .w_addr(w_addr), .w_data(w_data), .l_done(l_done), .l_m(l_m), .l_lc(l_lc),
	.rq_t(rq_t), .rq_cr(rq_cr), .rq_lc(rq_lc), .rq_half(rq_half), .rq_f(rq_f), .rb_addr(rb_addr), .rb_q(rb_q),
	.ready(fb_ready), .over(over_l),
	.SDR_CLK(SDR_CLK), .SDR_BA(SDR_BA), .SDR_A(SDR_A), .SDR_DQM(SDR_DQM), .SDR_RAS_N(SDR_RAS_N),
	.SDR_CAS_N(SDR_CAS_N), .SDR_WE_N(SDR_WE_N), .SDR_DQ(SDR_DQ)
);
sdram_model #(.ROWS(1024), .RB(10)) sdram (
	.clk(SDR_CLK), .ba(SDR_BA), .a(SDR_A), .dqm(SDR_DQM), .ras_n(SDR_RAS_N), .cas_n(SDR_CAS_N), .we_n(SDR_WE_N),
	.dq(SDR_DQ)
);

wire [7:0] r, g, b;
wire hs, vs, de, hs_neg, vs_neg;
vga_out vga (
	.clk(clk_bus), .ce7(ce7), .hc(hc), .vc(vc),
	.lb_we(|p_we), .lb_wa(p_we[1] ? p_addr[19:10] : p_addr[9:0]), .lb_wd(p_we[1] ? p_data[15:8] : p_data[7:0]),
	.mode_i(`MODE), .wall_i(`WALL != 0), .sel_i(`FS), .frame_col(3'd4), .rim_on(1'b0), .nb_i(`NB != 0),
	.pclk(pclk), .rq_t(rq_t), .rq_cr(rq_cr), .rq_lc(rq_lc), .rq_half(rq_half), .rq_f(rq_f), .rb_addr(rb_addr), .rb_q(rb_q),
	.r(r), .g(g), .b(b), .hs(hs), .vs(vs), .de(de), .hs_neg(hs_neg), .vs_neg(vs_neg)
);

// the wait of a screen read: from the request of zx_vid to its word (the most, in clocks)
integer rq_at [0:31];
integer rq_max = 0, nclk = 0;
always @(posedge clk_bus) begin
	nclk = nclk + 1;
	if (f_req[0]) rq_at[{1'b0, f_tag[3:0]}] = nclk;
	if (f_req[1]) rq_at[{1'b1, f_tag[7:4]}] = nclk;
	if (r_v[0] && nclk - rq_at[{1'b0, r_tag}] > rq_max) rq_max = nclk - rq_at[{1'b0, r_tag}];
	if (r_v[1] && nclk - rq_at[{1'b1, r_tag}] > rq_max) rq_max = nclk - rq_at[{1'b1, r_tag}];
end

// ---------------------------------------------------------------------------------------------
// the screens: random

integer i;
initial
	for (i = 0; i < (1 << 21); i = i + 1)
		model.mem[i] = $random(seed);

function [7:0] mbyte;              // byte o of the screen of machine g
	input [3:0] g;
	input [13:0] o;
	reg [15:0] w;
	begin
		w = model.mem[{1'b0, g, scr7_of(g) ? 3'd7 : 3'd5, o[13:1]}];
		mbyte = o[0] ? w[15:8] : w[7:0];
	end
endfunction

// the paper pixel h of line v of machine g
function [3:0] paper_pix;
	input [3:0] g;
	input [8:0] v;
	input [8:0] h;
	reg [7:0] bm, at;
	begin
		bm = mbyte(g, {1'b0, v[7:6], v[2:0], v[5:3], h[7:3]});
		at = mbyte(g, {1'b0, 3'b110, v[7:3], h[7:3]});
		paper_pix = bm[3'd7 - h[2:0]] ? {at[6], at[2:0]} : {at[6], at[5:3]};
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

// ---------------------------------------------------------------------------------------------
// checks on pclk

integer errors = 0, shown = 0, checked = 0;
integer x = 0, y = 0, frames = 0;
reg de_d = 1'b0, vs_d = 1'b0;
integer cell_cf [0:15];             // the frame a cell shows in this VGA frame (-1: not seen yet)
reg [23:0] ex;
reg [3:0] pg;
reg [8:0] pv, pe, sl, hh;
integer cr, cc, lc, cx, sx, py, k;
reg is_brd;
reg [2:0] fsb;                      // the border expected full screen (3 bits: it wraps as the machine's)
reg [31:0] fd_prev = 32'd0;         // the frames shown (fb_sdram fd) at the start of the VGA frame before
integer fr, fd_same = 0;
integer hcnt = 0, hlen = 0, vrows = 0;  // the raster: clocks of a line (hs to hs), lines of a frame

task bad;
	input [8*48-1:0] what;
	begin
		errors = errors + 1;
		if (shown < 20) begin
			shown = shown + 1;
			$display("frame %0d x %0d y %0d: %0s (%h, expected %h)", frames, x, y, what, {r, g, b}, ex);
		end
	end
endtask

reg hs_d = 1'b0;
always @(posedge pclk) begin
	de_d <= de;
	vs_d <= vs;
	hs_d <= hs;
	hcnt = hcnt + 1;
	if (hs && !hs_d) begin
		if (frames >= 3 && hcnt != ((`MODE == 2) ? 1488 : 1568)) begin
			errors = errors + 1;
			$display("frame %0d: a line of %0d clocks", frames, hcnt);
		end
		hcnt = 0;
		vrows = vrows + 1;
	end
	if (vs && !vs_d) begin
		if (frames >= 3 && vrows != ((`MODE == 2) ? 824 : 960)) begin
			errors = errors + 1;
			$display("frame %0d: %0d lines", frames, vrows);
		end
		vrows = 0;
		frames = frames + 1;
		y = 0;
		// (60 Hz: a frame of a machine is shown once or twice: count the VGA frames that show the frames before)
		if (`WALL != 0 && frames >= 5)
			for (fr = 0; fr < 4; fr = fr + 1)
				if (fb.fd[fr*8 +: 8] == fd_prev[fr*8 +: 8]) begin
					if (`MODE == 2)
						fd_same = fd_same + 1;
					else begin
						errors = errors + 1;
						$display("frame %0d: cell row %0d shows the frames of the VGA frame before", frames - 1, fr);
					end
				end
		fd_prev = fb.fd;
		if (`WALL != 0 && frames >= 4)
			$display("frame %0d: the cells show the frames %0d %0d %0d %0d / %0d %0d %0d %0d / %0d %0d %0d %0d / %0d %0d %0d %0d of their machines (mod 8), now at %0d",
				frames - 1, cell_cf[0], cell_cf[1], cell_cf[2], cell_cf[3], cell_cf[4], cell_cf[5], cell_cf[6], cell_cf[7],
				cell_cf[8], cell_cf[9], cell_cf[10], cell_cf[11], cell_cf[12], cell_cf[13], cell_cf[14], cell_cf[15], cf[0]);
		for (k = 0; k < 16; k = k + 1) cell_cf[k] = -1;
		if (frames == `FRAMES + 3) begin
			$display("tb_video: mode %0d, wall %0d, %0d frames, %0d pixels checked; late %h %h, overflow %b %b, SDRAM model errors %0d, a screen word waited at most %0d clocks; cell rows showing the frame before %0d",
				`MODE, `WALL, `FRAMES, checked, late1, late0, over_f, over_l, sdram.errors, rq_max, fd_same);
			errors = errors + sdram.errors + over_f + over_l + (late0 != 0) + (late1 != 0);
			$display("tb_video: %0d errors", errors);
			$finish;
		end
	end
	if (de) begin
		if (frames >= 3) begin
			checked = checked + 1;
			if (`WALL != 0 && `NB != 0 && (x < 128 || x >= 1152 || y < 16 || y >= 784)) begin
				ex = 24'd0;
				if ({r, g, b} !== ex) bad("outside the field");
			end else if (`WALL != 0 || `MODE == 2) begin
				if (`WALL == 0) begin
					cr = `FS / 4; lc = y / 4; cc = `FS % 4; cx = x / 4;
				end else if (`NB != 0) begin
					cr = (y - 16) / 192; lc = 4 + (y - 16) % 192; cc = (x - 128) / 256; cx = 32 + (x - 128) % 256;
				end else begin
					cr = y / 200; lc = y % 200; cc = x / 320; cx = x % 320;
				end
				pg = 4 * cr + cc;
				pv = (lc < 4) ? 316 + lc : lc - 4;
				if (cx < 32) begin
					pe = cx + 416;
					pv = (pv == 0) ? 319 : pv - 1;
				end else
					pe = cx - 32;
				is_brd = !(pv < 192 && pe < 256);
				if (!is_brd) begin
					ex = rgb(paper_pix(pg, pv, pe));
					if ({r, g, b} !== ex) bad("paper");
				end else begin
					// the border: the frame of the cell from the colour, the same for the whole cell
					k = -1;
					for (i = 0; i < 8; i = i + 1)
						if (rgb({1'b0, hash(pg, pv, {pe[8:1], 1'b0}) + ((`CFT != 0) ? i[2:0] : 3'd0)}) === {r, g, b}) k = i;
					ex = rgb({1'b0, hash(pg, pv, {pe[8:1], 1'b0})});
					if (k < 0 || (`CFT == 0 && k != 0))
						bad("border");
					else if (cell_cf[pg] < 0)
						cell_cf[pg] = k;
					else if (cell_cf[pg] != k)
						bad("border of another frame of the machine");
				end
			end else begin
				py = (848 + y) % 960;
				sl = py / 3;
				sx = x / 3;
				hh = (sx < 21) ? 384 : (sx < 85) ? sx + 363 : (sx >= 405) ? 319 : sx - 85;
				pv = (hh >= 384) ? ((sl == 0) ? 319 : sl - 1) : sl;
				if ((hh >= 320 && hh < 384) || (pv >= 240 && pv < 256))
					ex = 24'd0;
				else if (pv < 192 && hh < 256)
					ex = rgb(paper_pix(`FS, pv, hh));
				else begin
					fsb = hash(`FS, pv, {hh[8:1], 1'b0}) + ((`CFT != 0) ? cf[`FS] : 0);
					ex = rgb({1'b0, fsb});
				end
				// (the cell frame changes at line 315: around it the line buffer has the frame before)
				if ({r, g, b} !== ex && !((`CFT != 0) && pv >= 300))
					bad("full screen");
			end
		end
		x = x + 1;
	end else if (de_d) begin
		if (frames >= 3 && x != 1280) begin
			errors = errors + 1;
			$display("frame %0d row %0d: %0d pixels", frames, y, x);
		end
		x = 0;
		y = y + 1;
	end
end

endmodule
