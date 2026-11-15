`timescale 1ns / 1ps
`default_nettype none

/*
 tb_sd.v

 The DivMMC with the SD cards: the sixteen machines (two zx_oct with sd_oct) on sram_arb, sram_ctrl, the SRAM model
 (ROM 128 / 48 and ESXDOS in it as the loader puts them), sd_host on a model of the file mounter (slot 0 of img_sdc:
 sdc_busy, bytes of a read every second clock, a write copied from sdc_byte_out_data three clocks after
 sdc_byte_addr, then sdc_done; LAT clocks before the bytes, as the MCU takes milliseconds) with the image
 work_d/img.hex (tools/mkimg.py: ESXDOS's SYS and BIN). Machine k out of reset at 40000 + STAGGER * k clocks.
 Per frame: the requests of each machine (reads, writes, cache hits). At the end the screens (work_d/screens.hex,
 png), the sectors written and checks: every request done, no late read, no SRAM model error, the bytes each card
 gave for each read sector equal to the image (a sector is compared when a machine reads it: reads checks).
*/

`ifndef FRAMES
`define FRAMES 8
`endif
`ifndef LAT
`define LAT 20000
`endif
`ifndef STAGGER
`define STAGGER 20000
`endif
`ifndef IMGSEC
`define IMGSEC 8192
`endif

module tb_sd;

reg clk_sys = 1'b0;
always #5.946 clk_sys = ~clk_sys;
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

integer n = 0, k;
reg [15:0] reset = 16'hFFFF;
always @(posedge clk_bus) begin
	n = n + 1;
	for (k = 0; k < 16; k = k + 1)
		if (n == 40000 + `STAGGER * k) reset[k] <= 1'b0;
end

// two engines on the arbiter and the SRAM, their cards on sd_host
wire [1:0] e_req, e_we;
wire [43:0] e_addr;
wire [15:0] e_din;
wire [5:0] e_m;
wire a_rv, a_re;
wire [2:0] a_rm;
wire [7:0] a_rd;
wire [15:0] q;
wire [15:0] late, h_pend, h_wr;
wire [63:0] h_lba;
wire [2:0] h_m;
wire [1:0] h_done, h_we;
wire [8:0] h_a;
wire [7:0] h_d;
wire [15:0] h_q;
wire [21:0] c_size;
wire [5:0] e_vb;
wire [11:0] e_7ffd;

genvar ge;
generate
	for (ge = 0; ge < 2; ge = ge + 1) begin : g_eng
		zx_oct #(.BASE(ge)) eng (
			.clk(clk_bus), .slot(slot), .int_n(int_n), .reset(reset[ge*8 +: 8]), .nmi(8'd0),
			.sel_en(ge == 0), .sel(3'd0), .keys(40'd0), .keys_all(1'b0), .tape_in(8'd0), .kempston(8'd0),
			.m_req(e_req[ge]), .m_we(e_we[ge]), .m_addr(e_addr[ge*22 +: 22]), .m_din(e_din[ge*8 +: 8]),
			.m_m(e_m[ge*3 +: 3]), .m_rv(a_rv && a_re == ge), .m_rm(a_rm), .m_rd(a_rd),
			.divmmc_en(1'b1), .dv_clear(n < 100),
			.sd_en(1'b1), .sd_csize(c_size), .h_pend(h_pend[ge*8 +: 8]), .h_wr(h_wr[ge*8 +: 8]), .h_m(h_m),
			.h_lba(h_lba[ge*32 +: 32]), .h_done(h_done[ge]), .h_we(h_we[ge]), .h_a(h_a), .h_d(h_d), .h_q(h_q[ge*8 +: 8]),
			.beeper(), .mic(), .v_m(3'd0), .v_border(), .v_scr7(),
			.ay_we(), .ay_wa(), .ay_wd(), .ay_ra(4'd0), .ay_rd(), .late(late[ge*8 +: 8]),
			.dbg_pc(), .dbg_7ffd(), .dbg_ev()
		);
	end
endgenerate

wire c_req, c_we;
wire [21:0] c_addr;
wire [7:0] c_din;
sram_arb arb (
	.clk(clk_bus), .e_req(e_req), .e_we(e_we), .e_addr(e_addr), .e_din(e_din), .e_m(e_m),
	.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_din(c_din), .q(q),
	.rv(a_rv), .re(a_re), .rm(a_rm), .rd(a_rd)
);
wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MRD_N, MWR_N;
sram_ctrl sram (
	.clk_bus(clk_bus), .clk_sys(clk_sys),
	.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_din(c_din),
	.v_req(1'b0), .v_addr(21'd0), .v_ack(), .q(q),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
);
sram_model model (.A(MA), .DQ(MD), .RD_N(MRD_N), .WR_N(MWR_N), .drv(sram.md_oe[0]));

// ---------------------------------------------------------------------------------------------
// sd_host on the model of the file mounter

reg img_mounted = 1'b0;
reg sdc_busy = 1'b0, sdc_done = 1'b0, sdc_strobe = 1'b0;
reg [8:0] sdc_addr = 9'd0;
reg [7:0] sdc_data = 8'd0;
wire sdc_rd, sdc_wr;
wire [31:0] sdc_sector;
wire [7:0] sdc_out;
sd_host host (
	.clk(clk_bus), .pend(h_pend), .wr(h_wr), .h_m(h_m), .lba(h_lba), .done(h_done), .we(h_we), .a(h_a), .d(h_d),
	.q(h_q), .img_mounted(img_mounted), .img_size(64'd`IMGSEC * 64'd512), .sdc_rd(sdc_rd), .sdc_wr(sdc_wr),
	.sdc_sector(sdc_sector), .sdc_busy(sdc_busy), .sdc_done(sdc_done), .sdc_error(1'b0),
	.sdc_byte_in_strobe(sdc_strobe), .sdc_byte_addr(sdc_addr), .sdc_byte_in_data(sdc_data),
	.sdc_byte_out_data(sdc_out), .c_size(c_size), .active()
);

reg [7:0] img [0:`IMGSEC*512-1];
reg [7:0] img0 [0:`IMGSEC*512-1];   // as it was
integer i, mcu_rd = 0, mcu_wr = 0, hits = 0, errors = 0;
initial begin
	$readmemh("img.hex", img);
	for (i = 0; i < `IMGSEC * 512; i = i + 1) img0[i] = img[i];
end

// the file mounter: one request at a time
integer t, j;
reg [31:0] lba_r;
always @(posedge clk_bus) begin
	if (n == 50) img_mounted <= 1'b1;
	if (n == 51) img_mounted <= 1'b0;
end
initial begin
	@(posedge clk_bus);
	forever begin
		@(posedge clk_bus);
		if (sdc_rd || sdc_wr) begin
			lba_r = sdc_sector;
			if (lba_r >= `IMGSEC) begin
				$display("%0d: a request of sector %0d out of the image", n, lba_r);
				errors = errors + 1;
			end
			sdc_busy <= 1'b1;
			if (sdc_rd) begin
				mcu_rd = mcu_rd + 1;
				repeat (`LAT) @(posedge clk_bus);
				for (j = 0; j < 512; j = j + 1) begin
					sdc_strobe <= 1'b1;
					sdc_addr <= j;
					sdc_data <= img[lba_r * 512 + j];
					@(posedge clk_bus);
					sdc_strobe <= 1'b0;
					@(posedge clk_bus);
				end
			end else begin
				mcu_wr = mcu_wr + 1;
				for (j = 0; j < 512; j = j + 1) begin
					sdc_addr <= j;
					repeat (4) @(posedge clk_bus);   // the address out, three clocks later its byte
					img[lba_r * 512 + j] = sdc_out;
				end
				$display("%0d: sector %0d written", n, lba_r);
				repeat (`LAT) @(posedge clk_bus);
			end
			sdc_busy <= 1'b0;
			sdc_done <= 1'b1;
			@(posedge clk_bus);
			sdc_done <= 1'b0;
			repeat (5) @(posedge clk_bus);
		end
	end
end

always @(posedge clk_bus)
	if (host.state == 3'd4 && host.ci == 10'd0)
		hits = hits + 1;
`ifdef SDTRACE
// `define SDTRACE: the exchanges of machine TRM (engine 0) from clock TRFROM, the requests of sd_host
always @(posedge clk_bus)
	if (n >= `TRFROM && n < `TRFROM + 1200000) begin
		if (g_eng[0].eng.sd_xfer && g_eng[0].eng.sd.b == `TRM && g_eng[0].eng.sd.st != 4'd4)
			$display("%0d: card %0d cs_n %b tx %h out %h st %0d cmd %0d ba %0d busy %b want %b rq %b dn %b live %b q %h pc %h",
				n, `TRM, g_eng[0].eng.sd.cs_n, g_eng[0].eng.sd.tx, g_eng[0].eng.sd.out, g_eng[0].eng.sd.st,
				g_eng[0].eng.sd.cmd, g_eng[0].eng.sd.c_ba[`TRM], g_eng[0].eng.sd.busy, g_eng[0].eng.sd.c_want[`TRM],
				g_eng[0].eng.sd.rq_t[`TRM], g_eng[0].eng.sd.dn_t[`TRM], g_eng[0].eng.sd.live[`TRM],
				g_eng[0].eng.sd.c_q[`TRM], g_eng[0].eng.dbg_pc);
		if (host.state != host_st_d)
			$display("%0d: host state %0d e %b m %0d lba %0d line %0d wr %b pend %b", n, host.state, host.h_e, host.h_m,
				host.rlba, host.line, host.rwr, h_pend);
		if (h_we[0] && h_m == `TRM && h_a < 4)
			$display("%0d: buffer %0d byte %0d <= %h (live %b)", n, `TRM, h_a, h_d, g_eng[0].eng.sd.live[`TRM]);
	end
reg [2:0] host_st_d = 3'd0;
always @(posedge clk_bus) host_st_d <= host.state;
`endif
integer xfers = 0;
always @(posedge clk_bus)
	if (g_eng[0].eng.sd_xfer || g_eng[1].eng.sd_xfer)
		xfers = xfers + 1;

// ---------------------------------------------------------------------------------------------
// the cards: each read sector the CPU gets, byte for byte, against the image (the 512 data bytes after the token)

integer rd_m [0:15];
integer rd_cnt [0:15];
integer rd_pos [0:15];
reg [31:0] rd_lba [0:15];
integer reads = 0;
initial for (k = 0; k < 16; k = k + 1) begin rd_cnt[k] = 0; rd_pos[k] = -1; end

// the exchange of machine b of engine e (bus slot): the byte the card gives is c_q a clock later
genvar gc;
generate
	for (gc = 0; gc < 2; gc = gc + 1) begin : g_chk
		// sampled at the falling edge (sd_xfer is combinational on slot); c_q is written two falling edges later
		reg xf = 1'b0, wasdata = 1'b0, xf2 = 1'b0;
		reg [2:0] xb = 3'd0, xb2 = 3'd0;
		reg [8:0] xba = 9'd0, xba2 = 9'd0;
		reg [31:0] xlba = 32'd0, xlba2 = 32'd0;
		always @(negedge clk_bus) begin
			if (xf2) begin
				if (g_eng[gc].eng.sd.c_q[xb2] !== img[xlba2 * 512 + xba2]) begin
					errors = errors + 1;
					if (errors < 20)
						$display("%0d: machine %0d sector %0d byte %0d: %h, image %h", n, gc * 8 + xb2, xlba2, xba2,
							g_eng[gc].eng.sd.c_q[xb2], img[xlba2 * 512 + xba2]);
				end
				if (xba2 == 9'd511) begin
					rd_cnt[gc * 8 + xb2] = rd_cnt[gc * 8 + xb2] + 1;
					reads = reads + 1;
				end
			end
			{xf2, xb2, xba2, xlba2} <= {xf && wasdata, xb, xba, xlba};
			xf <= g_eng[gc].eng.sd_xfer;
			xb <= g_eng[gc].eng.sd.b;
			wasdata <= g_eng[gc].eng.sd.st == 4'd4;
			xba <= g_eng[gc].eng.sd.c_ba[g_eng[gc].eng.sd.b];
			xlba <= g_eng[gc].eng.sd.c_lba[g_eng[gc].eng.sd.b];
		end
	end
endgenerate

// ---------------------------------------------------------------------------------------------
// ROMs in the SRAM, the DivMMC RAM zero; per frame the counts; at the end the screens

reg [15:0] romw [0:16383];
reg [15:0] esxw [0:4095];
initial begin
	$readmemh("roms.hex", romw);
	$readmemh("esx.hex", esxw);
	#1;
	for (i = 0; i < (1 << 21); i = i + 1)
		model.mem[i] = 16'h0000;
	for (i = 0; i < 16384; i = i + 1)
		model.mem[21'h1F8000 + i] = romw[i];
	for (i = 0; i < 4096; i = i + 1)
		model.mem[21'h1FC000 + i] = esxw[i];
end

integer frames = 0, fd, m, p, a0;
reg int_d = 1'b1;
always @(posedge clk_bus) begin
	int_d <= int_n;
	if (!int_n && int_d && n > 40000) begin
		frames = frames + 1;
		$display("frame %0d: sector reads %0d (MCU %0d, cache %0d), MCU writes %0d, late %b, pending %b, exchanges %0d, PC of machine 0 %h, automap %b", frames, reads,
			mcu_rd, hits, mcu_wr, late, h_pend, xfers, g_eng[0].eng.dbg_pc, g_eng[0].eng.c_automap[0]);
		if (frames == `FRAMES) begin
			fd = $fopen("screens.hex", "w");
			for (m = 0; m < 16; m = m + 1) begin
				p = (m < 8 ? g_eng[0].eng.c_7ffd[m] : g_eng[1].eng.c_7ffd[m - 8]) & 8 ? 7 : 5;
				$fdisplay(fd, "@ %0d %0d", p, m < 8 ? g_eng[0].eng.c_border[m] : g_eng[1].eng.c_border[m - 8]);
				for (i = 0; i < 6912; i = i + 1) begin
					a0 = {1'b0, m[3], m[2:0], p[2:0], 14'd0} + i;
					$fdisplay(fd, "%h", a0[0] ? model.mem[a0 >> 1][15:8] : model.mem[a0 >> 1][7:0]);
				end
			end
			$fclose(fd);
			for (m = 0; m < 16; m = m + 1)
				$display("machine %0d: %0d sectors read", m, rd_cnt[m]);
			if (late != 16'd0) begin
				$display("late reads %b", late);
				errors = errors + 1;
			end
			errors = errors + model.errors;
			$display("tb_sd: SRAM model errors %0d", model.errors);
			$display("tb_sd: %0d errors", errors);
			$finish;
		end
	end
end

endmodule
