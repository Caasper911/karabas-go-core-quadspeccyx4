`timescale 1ns / 1ps

/*
 tb_wall.v

 Eight Pentagon 128 of zx_oct (one tv80o_core and one bus logic) on sram_arb, sram_ctrl and the SRAM model, against
 eight golden machines: tv80_core each with a behavioural bus (its own memory, no latency, ports and #7FFD written here
 again), the cen of golden CPU k in slot k as in the engine. Every T-state every output of CPU k of the engine (in
 slot k + 1, the second read port) is compared with golden CPU k; at the end the 128 KB of each machine in the SRAM
 model with the memory of the golden one, the border, beeper, MIC and the AY registers. Also: zx_oct late (a read not
 there in time) never set, the SRAM model counts no timing / fight errors, a video reader (v_req) on the SRAM above
 the machines reads the words it should. A second engine (eng1, BASE 1: the second MB) runs the same code on a copy of
 the memory with the same inputs, in lock step: its requests meet those of eng every time, the queues of sram_arb
 are as full as they can be; it must never be late either.

 `define MODE_ROM: the ROM 128 / 48 (work_w/roms.hex) loaded through the loader port, the RAM zero, INT of
 zx_timing, the machines out of reset 1000 T-states one after the other (SAME_START: all at once, one code in lock
 step), no NMI; the screens in screens.hex at the end. Else random code (as tb_tv80o.v): the ROM and the RAM random
 (each 8th byte ED, EI 1 of 64, no HALT), random INT, NMI, resets (every ~8000 T), keys, the selected machine.
 `define CLOCKS (default 2 000 000), SEED (1), WATCH (a byte address: its writes printed). Prints
 "tb_wall: <n> errors".

 The ROMs are in the SRAM ({111111, rom 16}: 128 at 0000, 48 at 4000, ESXDOS at 8000), put into the model at the start
 (the loader of the core is not here); the video reader reads that region (the rest of the SRAM is used now).
 `define DIVMMC: the DivMMC on (zx_oct divmmc_en), the golden bus has it as pentagon.v of QuadSpeccy: #E3 / #E7 / #EB
 (no card: #EB gives FF), the mapping of ESXDOS (random 8 KB, or esxdos089.bin with MODE_ROM) and the 128 KB of each
 machine, automap / detect; its memory compared at the end. A read of the golden machine uses the mapping of its T1
 (the engine asks there; automap may change at T2).
*/

module tb_wall;

`ifndef CLOCKS
`define CLOCKS 2000000
`endif
`ifndef SEED
`define SEED 1
`endif

// ---------------------------------------------------------------------------------------------
// clocks: clk_sys 84.09 MHz, clk_bus = clk_sys / 3 (its edges after those of clk_sys, as from the PLL)

reg clk_sys = 1'b0;
always #5.946 clk_sys = ~clk_sys;
reg clk_bus = 1'b0;
reg [1:0] div = 2'd0;
always @(posedge clk_sys) begin
	div <= (div == 2'd2) ? 2'd0 : div + 1'd1;
	if (div == 2'd2) clk_bus <= 1'b1;
	if (div == 2'd0) clk_bus <= 1'b0;   // high 1 clk_sys of 3: the edges are what counts
end

// ---------------------------------------------------------------------------------------------
// raster, slots

wire ce7, ce_cpu, ce14, vga_half;
wire [8:0] hc, vc, vga_x;
wire zx_int_n;
wire [4:0] frame;
wire [9:0] vga_p, vga_l;
zx_timing timing (
	.clk(clk_bus), .reset(1'b0), .ce7(ce7), .ce_cpu(ce_cpu), .ce14(ce14), .hc(hc), .vc(vc), .int_n(zx_int_n),
	.frame(frame), .vga_x(vga_x), .vga_half(vga_half), .vga_p(vga_p), .vga_l(vga_l)
);

reg [2:0] slot = 3'd0;
always @(posedge clk_bus)
	slot <= ce_cpu ? 3'd1 : slot + 1'd1;

integer cycles = 0;
always @(posedge clk_bus)
	cycles = cycles + 1;

// ---------------------------------------------------------------------------------------------
// stimulus (changed at slot 7: CPU 7 takes the old values in that clock, as its golden one)

integer seed = `SEED;
integer k, i, j, rnd;
reg [7:0] reset = 8'hFF;
reg [7:0] nmi = 8'h00;
reg rnd_int_n = 1'b1;
reg [2:0] sel = 3'd0;
reg [39:0] keys = 40'd0;
reg [7:0] tape_in = 8'd0;        // the tape input of each machine
reg keys_all = 1'b0;             // the keys and Kempston to every machine
reg [7:0] kempston = 8'd0;
reg loading = 1'b1;
reg frozen = 1'b0;               // the end: no golden writes any more
integer settle [0:7];
integer rst_cnt [0:7];
integer nmi_cnt [0:7];
integer int_cnt = 0;

`ifdef MODE_ROM
wire int_n = zx_int_n;
`else
wire int_n = rnd_int_n;
`endif

always @(posedge clk_bus)
	if (slot == 3'd7 && !loading) begin
		for (k = 0; k < 8; k = k + 1) begin
`ifdef MODE_ROM
			// out of reset one after the other: machine k 1000 * k T-states after the load
			if (rst_cnt[k] > 0) begin
				rst_cnt[k] = rst_cnt[k] - 1;
				reset[k] <= 1'b1;
			end else
				reset[k] <= 1'b0;
`else
			if (rst_cnt[k] > 0) begin
				rst_cnt[k] = rst_cnt[k] - 1;
				reset[k] <= 1'b1;
			end else begin
				reset[k] <= 1'b0;
				// a reset every ~8000 T-states: random code sits for long in LDIR / LDDR (BC up to 65535)
				if (($random(seed) & 8191) == 0)
					rst_cnt[k] = 20;
			end
			if (nmi_cnt[k] > 0) begin
				nmi_cnt[k] = nmi_cnt[k] - 1;
				nmi[k] <= 1'b1;
			end else begin
				nmi[k] <= 1'b0;
				if (($random(seed) & 2047) == 0)
					nmi_cnt[k] = 1 + (($random(seed) & 32'h7FFFFFFF) % 40);
			end
`endif
		end
`ifndef MODE_ROM
		// INT: 32 T-states every ~100 (taken whenever a CPU has them enabled)
		if (int_cnt > 0) begin
			int_cnt = int_cnt - 1;
			rnd_int_n <= 1'b0;
		end else begin
			rnd_int_n <= 1'b1;
			if (($random(seed) & 63) == 0)
				int_cnt = 32;
		end
		// the selected machine and its inputs: now and then
		if (($random(seed) & 4095) == 0) begin
			sel <= $random(seed);
			keys <= {$random(seed), $random(seed)} & {$random(seed), $random(seed)} & {$random(seed), $random(seed)};
			tape_in <= $random(seed);
			kempston <= $random(seed);
			keys_all <= $random(seed);
		end
`endif
	end

// ---------------------------------------------------------------------------------------------
// the engine, the SRAM controller, the SRAM

wire m_req, m_we;
wire [21:0] m_addr;
wire [7:0] m_din;
wire [15:0] m_q;
wire m_rv, m_re;
wire [2:0] m_rm;
wire [7:0] m_rd;
wire e1_req, e1_we;
wire [21:0] e1_addr;
wire [7:0] e1_din;
wire [7:0] late1;
`ifdef DIVMMC
wire divmmc_en = 1'b1;
`else
wire divmmc_en = 1'b0;
`endif
wire [7:0] beeper, mic;
wire [2:0] v_border;
wire v_scr7;
wire ay_we;
wire [3:0] ay_wa;
wire [7:0] ay_wd;
wire [7:0] late;

// INT: the value at slot 0 for every CPU (the engines take the INT of the CPU of each slot; zx_vid staggers it in the
// core, not here), the golden CPUs the same
reg g_int_t = 1'b1;
always @(posedge clk_bus)
	if (slot == 3'd0)
		g_int_t <= int_n;
wire g_int_n = (slot == 3'd0) ? int_n : g_int_t;

wire [5:0] e_m;
zx_oct #(.BASE(2'd0)) eng (
	.clk(clk_bus), .slot(slot), .int_n(g_int_n), .reset(reset), .nmi(nmi),
	.sel_en(1'b1), .sel(sel), .keys(keys), .keys_all(keys_all), .tape_in(tape_in), .kempston(kempston),
	.m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_din(m_din), .m_m(e_m[2:0]), .m_rv(m_rv & ~m_re), .m_rm(m_rm), .m_rd(m_rd),
	.divmmc_en(divmmc_en), .dv_clear(1'b0),
	.sd_en(1'b0), .sd_csize(22'd0), .h_pend(), .h_wr(), .h_m(3'd0), .h_lba(), .h_done(1'b0), .h_we(1'b0), .h_a(9'd0),
	.h_d(8'd0), .h_q(),
	.beeper(beeper), .mic(mic), .v_border(v_border), .v_scr7(v_scr7),
	.ay_we(ay_we), .ay_wa(ay_wa), .ay_wd(ay_wd), .ay_ra(4'd0), .ay_rd(), .late(late)
);

zx_oct #(.BASE(2'd1), .LFSR_INIT(16'h1D2B)) eng1 (     // (the LFSR of eng: R the same, in lock step)
	.clk(clk_bus), .slot(slot), .int_n(g_int_n), .reset(reset), .nmi(nmi),
	.sel_en(1'b1), .sel(sel), .keys(keys), .keys_all(keys_all), .tape_in(tape_in), .kempston(kempston),
	.m_req(e1_req), .m_we(e1_we), .m_addr(e1_addr), .m_din(e1_din), .m_m(e_m[5:3]), .m_rv(m_rv & m_re), .m_rm(m_rm), .m_rd(m_rd),
	.divmmc_en(divmmc_en), .dv_clear(1'b0),
	.sd_en(1'b0), .sd_csize(22'd0), .h_pend(), .h_wr(), .h_m(3'd0), .h_lba(), .h_done(1'b0), .h_we(1'b0), .h_a(9'd0),
	.h_d(8'd0), .h_q(),
	.beeper(), .mic(), .v_border(), .v_scr7(),
	.ay_we(), .ay_wa(), .ay_wd(), .ay_ra(4'd0), .ay_rd(), .late(late1)
);

wire c_req, c_we;
wire [21:0] c_addr;
wire [7:0] c_din;
sram_arb arb (
	.clk(clk_bus),
	.e_req({e1_req, m_req}), .e_we({e1_we, m_we}), .e_addr({e1_addr, m_addr}), .e_din({e1_din, m_din}), .e_m(e_m),
	.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_din(c_din), .q(m_q),
	.rv(m_rv), .re(m_re), .rm(m_rm), .rd(m_rd)
);

`ifdef QTRACE
reg [3:0] qmax0 = 0, qmax1 = 0;
always @(negedge clk_bus) begin
	if (arb.wp0 - arb.rp0 > qmax0) begin qmax0 = arb.wp0 - arb.rp0; $display("clock %0d queue0 %0d", cycles, qmax0); end
	if (arb.wp1 - arb.rp1 > qmax1) begin qmax1 = arb.wp1 - arb.rp1; $display("clock %0d queue1 %0d", cycles, qmax1); end
	if (cycles > 92755 && cycles < 92782) $display("%0d req %b%b we %b%b m %h a0 %h | take %b%b head %h | t3 %b %b %0d | late %b slot %0d mm %0d %0d wp %0d rp %0d q %h", cycles, e1_req, m_req, e1_we, m_we, e_m, m_addr, arb.take1, arb.take0, arb.head, m_rv, m_re, m_rm, late, slot, eng.m_m, eng1.m_m, arb.wp0, arb.rp0, arb.fq0[arb.rp0]);
end
`endif
reg v_req = 1'b0;
reg [20:0] v_addr = 21'd0;
wire v_ack;
wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MRD_N, MWR_N;

sram_ctrl sram (
	.clk_bus(clk_bus), .clk_sys(clk_sys),
	.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_din(c_din),
	.v_req(v_req), .v_addr(v_addr), .v_ack(v_ack), .q(m_q),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N)
);

sram_model model (.A(MA), .DQ(MD), .RD_N(MRD_N), .WR_N(MWR_N), .drv(sram.md_oe[0]));

// the read words are valid when they are taken (the clk_bus edge at the end of the access)
always @(posedge clk_bus)
	if (MRD_N != 2'b11)
		model.check_read(~MRD_N);

// ---------------------------------------------------------------------------------------------
// memory contents at the start (the same in the SRAM model and the golden machines), the ROM load

reg [7:0] g_ram [0:8*131072-1];   // golden: machine k at k * 128 KB, page p at p * 16 KB
reg [7:0] g_rom [0:32767];
reg [7:0] g_esx [0:8191];         // the ESXDOS ROM
reg [7:0] g_dv [0:8*131072-1];    // the DivMMC RAM: machine k at k * 128 KB, bank b at b * 8 KB
reg [15:0] rom_exp [0:20479];     // the words of the ROM region of the SRAM (the video reader)
reg [15:0] romw [0:16383];
integer errors = 0;

function [7:0] rnd_byte;
	input integer r;
	begin
		rnd_byte = r[7:0];
		if (r[10:8] == 3'd0) rnd_byte = 8'hED;
		// no HALT (with interrupts off it sleeps until a reset); EI 1 of 64 bytes (interrupts taken often)
		if (rnd_byte == 8'h76 || r[16:11] == 6'd0) rnd_byte = 8'hFB;
	end
endfunction

`ifdef IDPORT
// the machine number port in both engines (eng1 is not compared with golden machines)
integer id_rd0 = 0, id_rd1 = 0;
always @(posedge clk_bus) begin
	if (eng.io_rd && eng.p_A == 16'h5A73) begin
		id_rd0 = id_rd0 + 1;
		if (eng.port_q !== {5'd0, eng.b}) begin
			errors = errors + 1;
			$display("%t engine 0 machine %0d: #5A73 %h", $time, eng.b, eng.port_q);
		end
	end
	if (eng1.io_rd && eng1.p_A == 16'h5A73) begin
		id_rd1 = id_rd1 + 1;
		if (eng1.port_q !== {5'd1, eng1.b}) begin
			errors = errors + 1;
			$display("%t engine 1 machine %0d: #5A73 %h", $time, eng1.b, eng1.port_q);
		end
	end
end

task id_seq;
	input integer a;
	input integer rom;
	reg [7:0] s [0:6];
	integer j;
	begin
		if (a[5]) begin s[0] = 8'h01; s[1] = 8'h73; s[2] = 8'h5A; s[3] = 8'hED; s[4] = 8'h78; end
		else begin s[0] = 8'h00; s[1] = 8'h3E; s[2] = 8'h5A; s[3] = 8'hDB; s[4] = 8'h73; end
		s[5] = 8'hD3; s[6] = 8'hFE;
		for (j = 0; j < 7; j = j + 1)
			if (rom) g_rom[a + j] = s[j]; else g_ram[a + j] = s[j];
	end
endtask
`endif

initial begin
	for (k = 0; k < 8; k = k + 1) begin rst_cnt[k] = 20; nmi_cnt[k] = 0; end
`ifdef MODE_ROM
	$readmemh("roms.hex", romw);
	for (i = 0; i < 16384; i = i + 1) begin
		g_rom[2*i] = romw[i][7:0];
		g_rom[2*i+1] = romw[i][15:8];
	end
	for (i = 0; i < 8 * 131072; i = i + 1)
		g_ram[i] = 8'd0;
	// SAME_START: all at once (one code in lock step), else one after the other
	for (k = 0; k < 8; k = k + 1)
`ifdef SAME_START
		rst_cnt[k] = 20;
`else
		rst_cnt[k] = 20 + 1000 * k;
`endif
`else
	for (i = 0; i < 32768; i = i + 1)
		g_rom[i] = rnd_byte($random(seed));
	for (i = 0; i < 8 * 131072; i = i + 1)
		g_ram[i] = rnd_byte($random(seed));
`ifdef IDPORT
	// the machine number port: every 32 bytes LD BC,#5A73 : IN A,(C) : OUT (#FE),A or LD A,#5A : IN A,(#73) : OUT (#FE),A
	for (i = 0; i < 32768; i = i + 32) id_seq(i, 1);
	for (i = 0; i < 8 * 131072; i = i + 32) id_seq(i, 0);
`endif
`endif
	for (i = 0; i < 8192; i = i + 1)
		g_esx[i] = rnd_byte($random(seed));
`ifdef MODE_ROM
	$readmemh("esx.hex", g_esx);
`endif
	for (i = 0; i < 8 * 131072; i = i + 1)
		g_dv[i] = rnd_byte($random(seed));
	for (i = 0; i < 8 * 65536; i = i + 1) begin
		model.mem[i] = {g_ram[2*i+1], g_ram[2*i]};
		model.mem[8 * 65536 + i] = {g_ram[2*i+1], g_ram[2*i]};
	end

	// the ROMs into the SRAM (the loader of the core writes them there), the DivMMC RAM of both engines the same
	for (i = 0; i < 16384; i = i + 1) begin
		model.mem[21'h1F8000 + i] = {g_rom[2*i+1], g_rom[2*i]};
		rom_exp[i] = {g_rom[2*i+1], g_rom[2*i]};
	end
	for (i = 0; i < 4096; i = i + 1) begin
		model.mem[21'h1FC000 + i] = {g_esx[2*i+1], g_esx[2*i]};
		rom_exp[16384 + i] = {g_esx[2*i+1], g_esx[2*i]};
	end
	for (i = 0; i < 8 * 65536; i = i + 1) begin
		model.mem[21'h100000 + i] = {g_dv[2*i+1], g_dv[2*i]};
		if (i < 7 * 65536 + 32768)                                // engine 1: its last machine has 64 KB (the ROMs above)
			model.mem[21'h180000 + i] = {g_dv[2*i+1], g_dv[2*i]};
	end
	repeat (100) @(posedge clk_bus);
	loading <= 1'b0;
end

// ---------------------------------------------------------------------------------------------
// the golden machines

reg [7:0] g_rst_n = 8'h00;
always @* g_rst_n = ~reset;


wire [8*16-1:0] gA;
wire [8*8-1:0] gdo;
wire [8*7-1:0] gmc, gts;
wire [7:0] gm1_n, giorq, gnoread, gwrite, gintc_n, ghalt_n, gie;
reg [7:0] g_dinst [0:7];
reg [7:0] g_di [0:7];
reg [5:0] g_7ffd [0:7];
reg [2:0] g_border [0:7];
reg [7:0] g_beeper = 8'd0, g_mic = 8'd0;
reg g_wrdone [0:7];
reg [7:0] g_pdat [0:7];
reg [3:0] g_ayreg [0:7];
reg g_ayrv [0:7];
reg [7:0] g_ay [0:127];
reg g_conmem [0:7], g_mapram [0:7], g_automap [0:7], g_detect [0:7], g_cs_n [0:7];
reg [3:0] g_dvbank [0:7];
reg g_map_t1 [0:7];               // the DivMMC was mapped at T1 of this M-cycle (the read of the golden one uses it)
initial for (k = 0; k < 8; k = k + 1) begin
	g_conmem[k] = 1'b0; g_mapram[k] = 1'b0; g_automap[k] = 1'b0; g_detect[k] = 1'b0; g_cs_n[k] = 1'b1; g_dvbank[k] = 4'd0;
	g_map_t1[k] = 1'b0;
end
initial for (k = 0; k < 8; k = k + 1) begin
	g_di[k] = 8'hFF; g_7ffd[k] = 6'd0; g_border[k] = 3'd0; g_wrdone[k] = 1'b0; g_pdat[k] = 8'hFF; g_ayreg[k] = 4'd0;
	g_ayrv[k] = 1'b1;
end
initial for (i = 0; i < 128; i = i + 1) g_ay[i] = 8'd0;

// the byte at A of golden machine k (mapped: the DivMMC was mapped when the read started)
function [7:0] g_rd;
	input [2:0] m;
	input [15:0] a;
	input mapped;
	reg [2:0] pg;
	begin
		pg = (a[15:14] == 2'b01) ? 3'd5 : (a[15:14] == 2'b10) ? 3'd2 : g_7ffd[m][2:0];
		if (mapped && a[15:13] == 3'b000)
			g_rd = g_mapram[m] ? g_dv[{m, 4'd3, a[12:0]}] : g_esx[a[12:0]];
		else if (mapped && a[15:13] == 3'b001)
			g_rd = g_dv[{m, g_dvbank[m], a[12:0]}];
		else if (a[15:14] == 2'b00)
			g_rd = g_rom[{g_7ffd[m][4], a[13:0]}];
		else
			g_rd = g_ram[{m, pg, a[13:0]}];
	end
endfunction

// the ports of golden machine k (A, its inputs)
reg [4:0] g_kb;
integer rr;
function [7:0] g_port;
	input [2:0] m;
	input [15:0] a;
	begin
		g_kb = 5'b11111;
		if (m == sel || keys_all)
			for (rr = 0; rr < 8; rr = rr + 1)
				if (!a[8 + rr])
					g_kb = g_kb & ~keys[rr*5 +: 5];
		if (!a[0])
			g_port = {1'b1, tape_in[m], 1'b1, g_kb};
		else if (a[15] && !a[1] && a[14])
			g_port = g_ayrv[m] ? g_ay[{m, g_ayreg[m]}] : 8'hFF;
		else if (a[7:0] == 8'h1F)
			g_port = (m == sel || keys_all) ? kempston : 8'h00;
		else if (a == 16'h5A73)
			g_port = {5'd0, m};            // the machine number (eng, BASE 0)
		else
			g_port = 8'hFF;                // also #EB of the DivMMC: no card
	end
endfunction

function [7:0] ay_mask;
	input [3:0] n;
	case (n)
		4'd1, 4'd3, 4'd5, 4'd13: ay_mask = 8'h0F;
		4'd6, 4'd8, 4'd9, 4'd10: ay_mask = 8'h1F;
		default: ay_mask = 8'hFF;
	endcase
endfunction

genvar g;
generate
	for (g = 0; g < 8; g = g + 1) begin : g_m
		localparam [2:0] GM = g;
		integer gj;
		wire cen = (slot == g);
		wire [15:0] a = gA[g*16 +: 16];
		wire [7:0] dout = gdo[g*8 +: 8];
		wire m1 = gmc[g*7];
		wire [6:0] ts = gts[g*7 +: 7];
		wire mem_wr = ~m1 & gwrite[g] & ~giorq[g];
		wire io_rd = ~m1 & giorq[g] & ~gwrite[g];
		wire io_wr = ~m1 & giorq[g] & gwrite[g];
		// the byte golden CPU k takes: made again at every falling edge (the memories and the ports change at the
		// rising ones; a continuous assignment through g_rd would not follow g_ram / g_7ffd, only its arguments)
		reg [7:0] dinst = 8'hFF;
		// a cycle without a read (internal, write) gives the CPU the byte of the last memory read of this machine (DI of
		// T80se takes it at every T2; JR takes its offset from DI in its internal M3): as zx_oct and pentagon of
		// QuadSpeccy, whose data register keeps the last read
		reg [7:0] g_last = 8'hFF;
		wire g_memrd = m1 ? gintc_n[g] : (~gnoread[g] & ~gwrite[g] & ~giorq[g]);

		// R after a reset (rseed): what the engine loads in slot g (c_seed of machine g then), held between
		reg [7:0] g_seed_h = 8'd0;
		always @(posedge clk_bus)
			if (slot == g)
				g_seed_h <= eng.c_seed[g];
		wire [7:0] g_rseed = (slot == g) ? eng.c_seed[g] : g_seed_h;

		tv80_core #(.Mode(0), .IOWait(1)) cpu (
			.rseed(g_rseed), .reset_n(g_rst_n[g]), .clk(clk_bus), .cen(cen), .wait_n(1'b1), .int_n(g_int_n), .nmi_n(~nmi[g]),
			.busrq_n(1'b1), .dinst(dinst), .di(g_di[g]),
			.m1_n(gm1_n[g]), .iorq(giorq[g]), .no_read(gnoread[g]), .write(gwrite[g]), .rfsh_n(), .halt_n(ghalt_n[g]),
			.busak_n(), .A(gA[g*16 +: 16]), .dout(gdo[g*8 +: 8]), .mc(gmc[g*7 +: 7]), .ts(gts[g*7 +: 7]),
			.intcycle_n(gintc_n[g]), .IntE(gie[g]), .stop()
		);
		// the register files start known (0) here and in both engines: a read at an unknown address gave the two
		// engines different mixes of X through the byte select of sram_arb
		integer ri;
		initial
			for (ri = 0; ri < 8; ri = ri + 1) begin
				cpu.i_reg.RegsH[ri] = 8'd0;
				cpu.i_reg.RegsL[ri] = 8'd0;
				eng.core.i_reg.RegsH[g*8 + ri] = 8'd0;
				eng.core.i_reg.RegsL[g*8 + ri] = 8'd0;
				eng1.core.i_reg.RegsH[g*8 + ri] = 8'd0;
				eng1.core.i_reg.RegsL[g*8 + ri] = 8'd0;
			end

		// the byte the CPU takes at its cen in T2 (opcode, memory, port, FF of an acknowledge): the engine one the same
		always @(negedge clk_bus) begin
			dinst = io_rd ? g_pdat[g] : (m1 && !gintc_n[g]) ? 8'hFF : g_memrd ? g_rd(g, a, g_map_t1[g]) : g_last;
			if (cen && ts[2] && !loading && !frozen && !reset[g] && settle[g] == 0 &&
				(m1 || (~gnoread[g] & ~gwrite[g])) && (^dinst !== 1'bx) && eng.c_dinst !== dinst) begin
				errors = errors + 1;
				$display("%t clock %0d machine %0d takes %h, golden %h: A %h mc %b io %b ic %b src %b pdat %h mdat %h 7ffd %h / %h",
					$time, cycles, g, eng.c_dinst, dinst, a, gmc[g*7 +: 7], giorq[g], gintc_n[g], eng.c_src[g],
					eng.c_pdat[g], eng.c_ramd[g], eng.c_7ffd[g], g_7ffd[g]);
				finish;
			end
		end

		// the state of CPU k once per T-state (slot k + 1, after its cen): ACC, F, PC, SP, I, IFF1 / IFF2, IR, INT_s,
		// the register file; an error inside shows before it reaches an output
		integer gr;
		reg st_bad;
		always @(negedge clk_bus)
			if (slot == ((g + 1) & 7) && !loading && !frozen && !reset[g] && settle[g] == 0) begin
				st_bad = eng.core.ACC_m[g] !== cpu.ACC || eng.core.F_m[g] !== cpu.F || eng.core.PC_m[g] !== cpu.PC ||
					eng.core.SP_m[g] !== cpu.SP || eng.core.I_m[g] !== cpu.I || eng.core.R_m[g] !== cpu.R || eng.core.IntE_FF1_m[g] !== cpu.IntE_FF1 ||
					eng.core.IntE_FF2_m[g] !== cpu.IntE_FF2 || eng.core.IR_m[g] !== cpu.IR || eng.core.INT_s_m[g] !== cpu.INT_s ||
					(^g_di[g] !== 1'bx && eng.c_di[g] !== g_di[g]);
				for (gr = 0; gr < 8; gr = gr + 1)
					// (a register the golden CPU has unknown, from a read at an unknown address, is not compared: the SRAM model
					// gives the two engines a mix of X there)
					if ((^cpu.i_reg.RegsH[gr] !== 1'bx && eng.core.i_reg.RegsH[g*8 + gr] !== cpu.i_reg.RegsH[gr]) ||
						(^cpu.i_reg.RegsL[gr] !== 1'bx && eng.core.i_reg.RegsL[g*8 + gr] !== cpu.i_reg.RegsL[gr]))
						st_bad = 1'b1;
				if (st_bad) begin
					errors = errors + 1;
					$display("  diffs: %b%b%b%b%b%b%b%b%b%b g_di %b c_di %b", eng.core.ACC_m[g] !== cpu.ACC, eng.core.F_m[g] !== cpu.F,
						eng.core.PC_m[g] !== cpu.PC, eng.core.SP_m[g] !== cpu.SP, eng.core.I_m[g] !== cpu.I,
						eng.core.IntE_FF1_m[g] !== cpu.IntE_FF1, eng.core.IntE_FF2_m[g] !== cpu.IntE_FF2,
						eng.core.IR_m[g] !== cpu.IR, eng.core.INT_s_m[g] !== cpu.INT_s, (^g_di[g] !== 1'bx && eng.c_di[g] !== g_di[g]),
						g_di[g], eng.c_di[g]);
					$display("%t clock %0d machine %0d state differs: engine ACC %h F %h PC %h SP %h I %h IFF %b%b IR %h INT_s %b DI %h",
						$time, cycles, g, eng.core.ACC_m[g], eng.core.F_m[g], eng.core.PC_m[g], eng.core.SP_m[g], eng.core.I_m[g],
						eng.core.IntE_FF1_m[g], eng.core.IntE_FF2_m[g], eng.core.IR_m[g], eng.core.INT_s_m[g], eng.c_di[g]);
					$display("%t                                    golden ACC %h F %h PC %h SP %h I %h IFF %b%b IR %h INT_s %b DI %h",
						$time, cpu.ACC, cpu.F, cpu.PC, cpu.SP, cpu.I, cpu.IntE_FF1, cpu.IntE_FF2, cpu.IR, cpu.INT_s, g_di[g]);
					for (gr = 0; gr < 8; gr = gr + 1)
						$display("  reg %0d engine %h%h golden %h%h", gr, eng.core.i_reg.RegsH[g*8 + gr], eng.core.i_reg.RegsL[g*8 + gr],
							cpu.i_reg.RegsH[gr], cpu.i_reg.RegsL[gr]);
					finish;
				end
			end

`ifdef TRACE_M
		// `define TRACE_M <k> TRACE_FROM <clock>: machine k every T-state from that clock on
		always @(negedge clk_bus)
			if (g == `TRACE_M && cycles >= `TRACE_FROM && slot == ((g + 1) & 7))
				$display("%0d A %h mc %b ts %b io %b wr %b ic %b int %b | eng dinst %h di %h ACC %h PC %h | gold dinst %h di %h ACC %h PC %h",
					cycles, a, gmc[g*7 +: 7], ts, giorq[g], gwrite[g], gintc_n[g], g_int_n, eng.c_src[g] ? eng.c_pdat[g] : eng.c_ramd[g],
					eng.c_di[g], eng.core.ACC_m[g], eng.core.PC_m[g], dinst, g_di[g], cpu.ACC, cpu.PC);
`endif

		// the DivMMC of this machine now (CONMEM, automap, this opcode fetch of 3Dxx)
		wire g_instant = m1 && gintc_n[g] && a[15:8] == 8'h3D;
		wire g_mapped = divmmc_en && (g_conmem[g] || g_automap[g] || g_instant);
		wire g_entry = a == 16'h0000 || a == 16'h0008 || a == 16'h0038 || a == 16'h0066 || a == 16'h04C6 || a == 16'h0562;

		always @(posedge clk_bus) if (!frozen) begin
			if (slot == ((g + 1) & 7) && ts[1])
				g_map_t1[g] <= g_mapped;
			if (reset[g]) begin
				g_7ffd[g] <= 6'd0;
				g_wrdone[g] <= 1'b0;
				g_ayreg[g] <= 4'd0;
				g_ayrv[g] <= 1'b1;
				for (gj = 0; gj < 16; gj = gj + 1) g_ay[g*16 + gj] <= 8'd0;
				if (nmi[g]) begin
					g_conmem[g] <= 1'b0;
					g_mapram[g] <= 1'b0;
					g_dvbank[g] <= 4'd0;
					g_cs_n[g] <= 1'b1;
				end
			end else begin
				// DivMMC automap (in the bus slot, as the engine): in the M1 read by the address, out of it follows detect
				if (slot == ((g + 1) & 7) && divmmc_en) begin
					if (m1 && gintc_n[g] && (ts[1] || ts[2])) begin
						if (g_entry)
							g_detect[g] <= 1'b1;
						else if (a[15:3] == 13'b0001111111111)
							g_detect[g] <= 1'b0;
						else if (a[15:8] == 8'h3D) begin
							g_automap[g] <= 1'b1;
							g_detect[g] <= 1'b1;
						end
					end else
						g_automap[g] <= g_detect[g];
				end
				// the data of a port: taken in every clock after a cen (as the bus slots of the engine)
				if (slot == ((g + 1) & 7) && io_rd)
					g_pdat[g] <= g_port(g, a);
				if (cen && ts[2]) begin
					g_di[g] <= dinst;
					if (g_memrd)
						g_last <= dinst;
				end
				// the writes at the start of T2, the clock after the cen (the bus timing: zx_oct does them there)
				if (slot == ((g + 1) & 7)) begin
					if (ts[1])
						g_wrdone[g] <= 1'b0;
					if (ts[2] && !g_wrdone[g]) begin
						if (mem_wr || io_wr)
							g_wrdone[g] <= 1'b1;
						if (mem_wr && g_mapped && a[15:13] == 3'b001) begin
							if (!(g_mapram[g] && g_dvbank[g] == 4'd3))
								g_dv[{GM, g_dvbank[g], a[12:0]}] <= dout;
						end else if (mem_wr && a[15:14] != 2'b00)
							g_ram[{GM, (a[15:14] == 2'b01) ? 3'd5 : (a[15:14] == 2'b10) ? 3'd2 : g_7ffd[g][2:0],
								a[13:0]}] <= dout;
`ifdef WATCH
						if (mem_wr && a[15:14] != 2'b00 && {GM, (a[15:14] == 2'b01) ? 3'd5 : (a[15:14] == 2'b10) ? 3'd2 :
							g_7ffd[g][2:0], a[13:0]} == `WATCH)
							$display("%t clock %0d golden %0d write %h <= %h (A %h, 7ffd %h)", $time, cycles, g, `WATCH, dout, a,
								g_7ffd[g]);
`endif
						if (io_wr) begin
							if (!a[0]) begin
								g_border[g] <= dout[2:0];
								g_mic[g] <= dout[3];
								g_beeper[g] <= dout[4];
							end
							if (!a[15] && !a[1] && !g_7ffd[g][5])
								g_7ffd[g] <= dout[5:0];
							if (divmmc_en && a[7:0] == 8'hE3) begin
								g_conmem[g] <= dout[7];
								g_mapram[g] <= g_mapram[g] | dout[6];
								g_dvbank[g] <= dout[3:0];
							end
							if (divmmc_en && a[7:0] == 8'hE7)
								g_cs_n[g] <= dout[0];
							if (a[15] && !a[1]) begin
								if (a[14]) begin
									g_ayreg[g] <= dout[3:0];
									g_ayrv[g] <= (dout[7:4] == 4'd0);
								end else if (g_ayrv[g])
									g_ay[{GM, g_ayreg[g]}] <= dout & ay_mask(g_ayreg[g]);
							end
						end
					end
				end
			end
		end
	end
endgenerate

// ---------------------------------------------------------------------------------------------
// compare: CPU k of the engine in slot k + 1 (its second read port) with golden CPU k (not in a reset and two
// T-states after it: the golden CPU resets at once, the engine one in its slot)

integer ie_t [0:7];
integer m1s [0:7];
integer ints [0:7];
initial for (k = 0; k < 8; k = k + 1) begin settle[k] = 0; m1s[k] = 0; ints[k] = 0; ie_t[k] = 0; end
wire [2:0] pm = slot - 3'd1;
reg [7:0] late_seen = 8'd0, late1_seen = 8'd0;

always @(negedge clk_bus) begin
	if (!loading) begin
		k = pm;
		if (reset[k])
			settle[k] = 2;
		else if (settle[k] > 0) begin
			settle[k] = settle[k] - 1;
		end else begin
			if (!gm1_n[k] && gts[k*7 + 1]) m1s[k] = m1s[k] + 1;
			if (gie[k]) ie_t[k] = ie_t[k] + 1;
			if (!gintc_n[k] && gts[k*7 + 1] && gmc[k*7]) ints[k] = ints[k] + 1;
			if (eng.p_A !== gA[k*16 +: 16] || eng.p_dout !== gdo[k*8 +: 8] || eng.p_mc !== gmc[k*7 +: 7] ||
				eng.p_ts !== gts[k*7 +: 7] || eng.p_m1_n !== gm1_n[k] || eng.p_iorq !== giorq[k] ||
				eng.p_no_read !== gnoread[k] || eng.p_write !== gwrite[k] || eng.p_intcycle_n !== gintc_n[k] ||
				eng.p_halt_n !== ghalt_n[k]) begin
				errors = errors + 1;
				$display("%t clock %0d machine %0d differs: engine A %h do %h mc %b ts %b m1 %b io %b nr %b wr %b ic %b h %b",
					$time, cycles, k, eng.p_A, eng.p_dout, eng.p_mc, eng.p_ts, eng.p_m1_n, eng.p_iorq, eng.p_no_read,
					eng.p_write, eng.p_intcycle_n, eng.p_halt_n);
				$display("%t                               golden A %h do %h mc %b ts %b m1 %b io %b nr %b wr %b ic %b h %b",
					$time, gA[k*16 +: 16], gdo[k*8 +: 8], gmc[k*7 +: 7], gts[k*7 +: 7], gm1_n[k], giorq[k], gnoread[k],
					gwrite[k], gintc_n[k], ghalt_n[k]);
				finish;
			end
		end
	end
	if (late != late_seen) begin
		late_seen = late_seen | late;
		if (late & ~reset) begin
			errors = errors + 1;
			$display("%t clock %0d late %b", $time, cycles, late);
		end
	end
	if (late1 != late1_seen) begin
		late1_seen = late1_seen | late1;
		if (late1 & ~reset) begin
			errors = errors + 1;
			$display("%t clock %0d engine 1 late %b", $time, cycles, late1);
		end
	end
	if (cycles == `CLOCKS)
		finish;
end

`ifdef WATCH
// `define WATCH <byte address>: the writes to it in the engine and the golden machines
always @(posedge clk_bus) begin
	if (m_req && m_we && m_addr == `WATCH)
		$display("%t clock %0d engine write %h <= %h (slot %0d, reset %b)", $time, cycles, m_addr, m_din, slot, reset);
end
`endif

// ---------------------------------------------------------------------------------------------
// the video reader: random words above the machines, each compared two clocks after its v_ack

reg [20:0] v_a1 = 0, v_a2 = 0;
reg v_v1 = 1'b0, v_v2 = 1'b0;
integer vreads = 0;
always @(posedge clk_bus) begin
	if (v_ack || !v_req) begin
		v_req <= ($random(seed) & 3) == 0;
		v_addr <= 21'h1F8000 + (($random(seed) & 32'h7FFFFFFF) % 20480);    // the ROMs
	end
	v_v1 <= v_ack;
	v_a1 <= v_addr;
	v_v2 <= v_v1;
	v_a2 <= v_a1;
	if (v_v2) begin
		vreads = vreads + 1;
		if (m_q !== rom_exp[v_a2 - 21'h1F8000]) begin
			errors = errors + 1;
			if (errors < 10) $display("%t video read %h: %h, not %h", $time, v_a2, m_q, rom_exp[v_a2 - 21'h1F8000]);
		end
	end
end

// ---------------------------------------------------------------------------------------------
// the end: the memories, the ports, the counts

integer mem_err;
integer fd;
reg [5:0] s_7ffd [0:7];
reg [2:0] s_border [0:7];
reg [7:0] s_beeper, s_mic;
reg [7:0] s_ay [0:127];
task finish;
	begin
		// now: the ports of the engine (written at the end of a bus slot, as the golden ones) and no more golden
		// writes; the SRAM 2 clocks later, when the writes of the bus slots before now are in (the write of a bus
		// slot reaches the SRAM in the middle of the second clock after it)
		for (k = 0; k < 8; k = k + 1) begin
			s_7ffd[k] = eng.c_7ffd[k];
			s_border[k] = eng.c_border[k];
		end
		for (k = 0; k < 128; k = k + 1)
			s_ay[k] = eng.ay_ram[k];
		s_beeper = beeper;
		s_mic = mic;
		loading = 1'b1;
		frozen = 1'b1;
		// the machines held (no new requests), the writes in the queues of sram_arb reach the SRAM
		reset <= 8'hFF;
		nmi <= 8'h00;
		repeat (40) @(posedge clk_bus);
		#1;
		mem_err = 0;
		for (i = 0; i < 8 * 65536; i = i + 1) begin
			if (model.mem[i] !== {g_ram[2*i+1], g_ram[2*i]}) begin
				mem_err = mem_err + 1;
				if (mem_err < 5) $display("memory word %h: SRAM %h, golden %h%h", i, model.mem[i], g_ram[2*i+1], g_ram[2*i]);
			end
			if (model.mem[21'h100000 + i] !== {g_dv[2*i+1], g_dv[2*i]}) begin
				mem_err = mem_err + 1;
				if (mem_err < 5) $display("DivMMC word %h: SRAM %h, golden %h%h", i, model.mem[21'h100000 + i], g_dv[2*i+1], g_dv[2*i]);
			end
		end
		for (k = 0; k < 8; k = k + 1) begin
			if (s_border[k] !== g_border[k] || s_beeper[k] !== g_beeper[k] || s_mic[k] !== g_mic[k] ||
				s_7ffd[k] !== g_7ffd[k]) begin
				mem_err = mem_err + 1;
				$display("machine %0d: border %h beeper %b mic %b 7ffd %h, golden %h %b %b %h", k, s_border[k],
					s_beeper[k], s_mic[k], s_7ffd[k], g_border[k], g_beeper[k], g_mic[k], g_7ffd[k]);
			end
			for (j = 0; j < 16; j = j + 1)
				if (s_ay[k*16 + j] !== g_ay[k*16 + j]) begin
					mem_err = mem_err + 1;
					$display("machine %0d AY register %0d: %h, golden %h", k, j, s_ay[k*16 + j], g_ay[k*16 + j]);
				end
		end
`ifdef MODE_ROM
		// the screens: the page of each machine (5 or 7, #7FFD bit 3) from the SRAM, its border
		fd = $fopen("screens.hex", "w");
		for (k = 0; k < 8; k = k + 1) begin
			$fdisplay(fd, "@ %0d %0d", s_7ffd[k][3] ? 7 : 5, s_border[k]);
			for (i = 0; i < 6912; i = i + 1) begin
				j = {k[2:0], s_7ffd[k][3] ? 3'd7 : 3'd5, 14'd0} + i;
				$fdisplay(fd, "%h", j[0] ? model.mem[j >> 1][15:8] : model.mem[j >> 1][7:0]);
			end
		end
		$fclose(fd);
`endif
		errors = errors + mem_err + model.errors;
		$display("tb_wall: %0d clocks, M1 cycles per machine %0d %0d %0d %0d %0d %0d %0d %0d", cycles,
			m1s[0], m1s[1], m1s[2], m1s[3], m1s[4], m1s[5], m1s[6], m1s[7]);
		$display("tb_wall: T-states with interrupts on %0d %0d %0d %0d %0d %0d %0d %0d", ie_t[0], ie_t[1], ie_t[2], ie_t[3],
			ie_t[4], ie_t[5], ie_t[6], ie_t[7]);
		$display("tb_wall: interrupts %0d %0d %0d %0d %0d %0d %0d %0d, video reads %0d, SRAM model errors %0d (X accesses %0d), memory / port errors %0d",
			ints[0], ints[1], ints[2], ints[3], ints[4], ints[5], ints[6], ints[7], vreads, model.errors, model.xs, mem_err);
`ifdef IDPORT
		$display("tb_wall: machine number port: %0d bus slots read it (engine 0), %0d (engine 1)", id_rd0, id_rd1);
`endif
		$display("tb_wall: %0d errors", errors);
		$finish;
	end
endtask

endmodule
