`timescale 1ns / 1ps

/*
 tb_tv80o.v

 The equivalence of tv80_oct (one tv80 logic for eight CPUs, one clock each, tools/mkctx.py) with eight tv80_core,
 clock for clock (after tb_tv80q.v of karabas-go-core-quadspeccy).

 Eight reference tv80_core and one tv80_oct on the same clock; CPU k gets its cen in slot k (of 8) in both. Each CPU
 has its own 64 KB memory of random bytes (the program: random code goes through every prefix, undocumented opcodes,
 block instructions, HALT, jumps, IM 0 / 1 / 2, EI / DI), and its own random WAIT, INT, NMI, skipped cens (a pause) and
 resets; the reference and the oct CPU k get the same (the same seed), each from its own outputs. Every clock every
 output of every CPU is compared (A, dout, mc, ts, m1_n, iorq, no_read, write, intcycle_n, halt_n); the first
 difference stops the test. Prints "tb_tv80o: <n> errors".

 `define CLOCKS: the length (default 2 000 000 clocks = 250 000 T-states per CPU); SEED: the random seed (1).
 The state of every CPU (ACC, F, PC, SP, I, the register file) is compared once per T-state too.
 TRACE_CPU / TRACE_FROM: print CPU k every clock from that clock on.
*/

module tb_tv80o;

`ifndef CLOCKS
`define CLOCKS 2000000
`endif

reg clk = 1'b0;
always #17.838 clk = ~clk;

reg [2:0] slot = 3'd0;
always @(posedge clk)
	slot <= slot + 1'd1;

// ---------------------------------------------------------------------------------------------
// stimulus per CPU (the same for the reference and the oct one)

reg [7:0] rst_n = 8'h00;
reg [7:0] run = 8'hFF;        // its cen in its slot
reg [7:0] wait_n = 8'hFF;
reg [7:0] int_n = 8'hFF;
reg [7:0] nmi_n = 8'hFF;
wire [7:0] cen;
genvar g;
generate
	for (g = 0; g < 8; g = g + 1) begin : g_cen
		assign cen[g] = (slot == g) && run[g];
	end
endgenerate

`ifndef SEED
`define SEED 1
`endif
integer seed = `SEED;
integer cycles = 0;
integer k;
integer rst_cnt [0:7];
integer int_cnt [0:7];
integer nmi_cnt [0:7];
initial for (k = 0; k < 8; k = k + 1) begin rst_cnt[k] = 20; int_cnt[k] = 0; nmi_cnt[k] = 0; end

// the stimulus changes at slot 7 (non-blocking: CPU 7 takes the old values in that clock, as its reference does)
always @(posedge clk) begin
	cycles = cycles + 1;
	if (slot == 3'd7) begin
		for (k = 0; k < 8; k = k + 1) begin
			// reset: 20 T-states at the start, then now and then
			if (rst_cnt[k] > 0) begin
				rst_cnt[k] = rst_cnt[k] - 1;
				rst_n[k] <= 1'b0;
			end else begin
				rst_n[k] <= 1'b1;
				if (($random(seed) & 32'hFFFF) == 0)
					rst_cnt[k] = 3;
			end
			run[k] <= ($random(seed) & 15) != 0;          // 1 of 16 T-states without cen
			wait_n[k] <= ($random(seed) & 7) != 0;        // WAIT 1 of 8
			// INT: 32 T-states every ~256; NMI: 1..40 T-states every ~1000 (its edge is what counts: Oldnmi_n)
			if (int_cnt[k] > 0) begin
				int_cnt[k] = int_cnt[k] - 1;
				int_n[k] <= 1'b0;
			end else begin
				int_n[k] <= 1'b1;
				// CPU 0 rarely (its IFF2 stays set after EI), the others often: their states differ, a CPU reading
				// the state of another shows
				if (($random(seed) & (k == 0 ? 4095 : 255)) == 0)
					int_cnt[k] = 32;
			end
			if (nmi_cnt[k] > 0) begin
				nmi_cnt[k] = nmi_cnt[k] - 1;
				nmi_n[k] <= 1'b0;
			end else begin
				nmi_n[k] <= 1'b1;
				if (($random(seed) & 1023) == 0)
					nmi_cnt[k] = 1 + (($random(seed) & 32'h7FFFFFFF) % 40);
			end
		end
	end
end

// ---------------------------------------------------------------------------------------------
// memories: mem_r of the reference CPUs, mem_q of the oct one, the same random bytes at the start

reg [7:0] mem_r [0:8*65536-1];
reg [7:0] mem_q [0:8*65536-1];
integer i, rnd;
initial begin
	for (i = 0; i < 8 * 65536; i = i + 1) begin
		rnd = $random(seed);
		// one byte of 8 is ED: the ED instructions (LD A,I / LD A,R, RETN, IM, block ones) come often
		if (rnd[10:8] == 3'd0) rnd[7:0] = 8'hED;
		// no HALT (with interrupts off it sleeps until a reset): EI instead, so interrupts are taken often
		if (rnd[7:0] == 8'h76) rnd[7:0] = 8'hFB;
		mem_r[i] = rnd[7:0];
		mem_q[i] = rnd[7:0];
	end
end

// ---------------------------------------------------------------------------------------------
// the reference: eight tv80_core

wire [8*16-1:0] r_A, q_A;
wire [8*8-1:0] r_dout, q_dout, r_di, q_di;
wire [8*7-1:0] r_mc, q_mc, r_ts, q_ts;
wire [7:0] r_m1_n, r_iorq, r_no_read, r_write, r_intcycle_n, r_halt_n;
wire [7:0] q_m1_n, q_iorq, q_no_read, q_write, q_intcycle_n, q_halt_n;

// the data of a CPU: its memory at A, an I/O read gives A[7:0] ^ A[15:8]
generate
	for (g = 0; g < 8; g = g + 1) begin : g_ref
		assign r_di[g*8 +: 8] = r_iorq[g] ? (r_A[g*16 +: 8] ^ r_A[g*16 + 8 +: 8]) : mem_r[g * 65536 + r_A[g*16 +: 16]];
		assign q_di[g*8 +: 8] = q_iorq[g] ? (q_A[g*16 +: 8] ^ q_A[g*16 + 8 +: 8]) : mem_q[g * 65536 + q_A[g*16 +: 16]];

		tv80_core #(.Mode(0), .IOWait(1)) ref (
			.rseed(8'd0), .reset_n(rst_n[g]), .clk(clk), .cen(cen[g]), .wait_n(wait_n[g]), .int_n(int_n[g]), .nmi_n(nmi_n[g]),
			.busrq_n(1'b1), .dinst(r_di[g*8 +: 8]), .di(r_di[g*8 +: 8]),
			.m1_n(r_m1_n[g]), .iorq(r_iorq[g]), .no_read(r_no_read[g]), .write(r_write[g]), .rfsh_n(),
			.halt_n(r_halt_n[g]), .busak_n(), .A(r_A[g*16 +: 16]), .dout(r_dout[g*8 +: 8]), .mc(r_mc[g*7 +: 7]),
			.ts(r_ts[g*7 +: 7]), .intcycle_n(r_intcycle_n[g]), .IntE(), .stop()
		);

		// memory writes: in T2 of a write cycle, at the cen of the CPU (each from its own outputs)
		always @(posedge clk) begin
			if (cen[g] && r_write[g] && !r_iorq[g] && r_ts[g*7 + 2])
				mem_r[g * 65536 + r_A[g*16 +: 16]] <= r_dout[g*8 +: 8];
			if (cen[g] && q_write[g] && !q_iorq[g] && q_ts[g*7 + 2])
				mem_q[g * 65536 + q_A[g*16 +: 16]] <= q_dout[g*8 +: 8];
		end
	end
endgenerate

// ---------------------------------------------------------------------------------------------
// the oct CPU

tv80_oct #(.Mode(0), .IOWait(1)) oct (
	.clk(clk), .slot(slot),
	.reset_n(rst_n), .cen(cen), .wait_n(wait_n), .int_n(int_n), .nmi_n(nmi_n), .dinst(q_di), .di(q_di),
	.A(q_A), .dout(q_dout), .mc(q_mc), .ts(q_ts), .m1_n(q_m1_n), .iorq(q_iorq), .no_read(q_no_read),
	.write(q_write), .intcycle_n(q_intcycle_n), .halt_n(q_halt_n)
);

// ---------------------------------------------------------------------------------------------
// compare: every clock, every CPU (not in its reset and the T-state after: the reference resets at once, the oct
// CPU in its slot)

integer errors = 0;
integer st_errors = 0;

// the state of every CPU (ACC, F, PC, SP, I, the register file) once per T-state, in the clock after its slot: an
// error inside shows here before it reaches an output
generate
	for (g = 0; g < 8; g = g + 1) begin : g_st
		integer r;
		reg bad;
		always @(negedge clk)
			if (rst_n[g] && settle[g] == 0 && slot == ((g + 1) & 7)) begin
				bad = g_ref[g].ref.ACC !== oct.core.ACC_m[g] || g_ref[g].ref.F !== oct.core.F_m[g] ||
					g_ref[g].ref.PC !== oct.core.PC_m[g] || g_ref[g].ref.SP !== oct.core.SP_m[g] ||
					g_ref[g].ref.I !== oct.core.I_m[g] || g_ref[g].ref.R !== oct.core.R_m[g];
				for (r = 0; r < 8; r = r + 1)
					if (g_ref[g].ref.i_reg.RegsH[r] !== oct.core.i_reg.RegsH[g*8 + r] ||
						g_ref[g].ref.i_reg.RegsL[r] !== oct.core.i_reg.RegsL[g*8 + r])
						bad = 1'b1;
				if (bad) begin
					st_errors = st_errors + 1;
					$display("%t clock %0d CPU %0d state differs: ref ACC %h F %h PC %h SP %h, oct ACC %h F %h PC %h SP %h",
						$time, cycles, g, g_ref[g].ref.ACC, g_ref[g].ref.F, g_ref[g].ref.PC, g_ref[g].ref.SP,
						oct.core.ACC_m[g], oct.core.F_m[g], oct.core.PC_m[g], oct.core.SP_m[g]);
					for (r = 0; r < 8; r = r + 1)
						$display("  reg %0d ref %h%h oct %h%h", r, g_ref[g].ref.i_reg.RegsH[r], g_ref[g].ref.i_reg.RegsL[r],
							oct.core.i_reg.RegsH[g*8 + r], oct.core.i_reg.RegsL[g*8 + r]);
					$display("tb_tv80o: %0d errors", errors + st_errors);
					$finish;
				end
			end
	end
endgenerate
integer settle [0:7];
integer m1s [0:7];
integer ints [0:7];
initial for (k = 0; k < 8; k = k + 1) begin settle[k] = 0; m1s[k] = 0; ints[k] = 0; end
reg [7:0] diff;

always @(negedge clk) begin
	for (k = 0; k < 8; k = k + 1) begin
		if (!rst_n[k])
			settle[k] = 16;
		else if (settle[k] > 0)
			settle[k] = settle[k] - 1;
		else begin
			if (cen[k] && !r_m1_n[k]) m1s[k] = m1s[k] + 1;
			if (cen[k] && !r_intcycle_n[k] && r_ts[k*7 + 1]) ints[k] = ints[k] + 1;
			if (r_A[k*16 +: 16] !== q_A[k*16 +: 16] || r_dout[k*8 +: 8] !== q_dout[k*8 +: 8] ||
				r_mc[k*7 +: 7] !== q_mc[k*7 +: 7] || r_ts[k*7 +: 7] !== q_ts[k*7 +: 7] ||
				r_m1_n[k] !== q_m1_n[k] || r_iorq[k] !== q_iorq[k] || r_no_read[k] !== q_no_read[k] ||
				r_write[k] !== q_write[k] || r_intcycle_n[k] !== q_intcycle_n[k] || r_halt_n[k] !== q_halt_n[k]) begin
				errors = errors + 1;
				$display("%t clock %0d CPU %0d differs: ref A %h do %h mc %b ts %b m1 %b io %b nr %b wr %b ic %b h %b",
					$time, cycles, k, r_A[k*16 +: 16], r_dout[k*8 +: 8], r_mc[k*7 +: 7], r_ts[k*7 +: 7], r_m1_n[k],
					r_iorq[k], r_no_read[k], r_write[k], r_intcycle_n[k], r_halt_n[k]);
				$display("%t                           oct A %h do %h mc %b ts %b m1 %b io %b nr %b wr %b ic %b h %b",
					$time, q_A[k*16 +: 16], q_dout[k*8 +: 8], q_mc[k*7 +: 7], q_ts[k*7 +: 7], q_m1_n[k],
					q_iorq[k], q_no_read[k], q_write[k], q_intcycle_n[k], q_halt_n[k]);
`ifdef TRACE_CPU
				$display("ref ACC %h F %h BusA %h BusB %h | oct ACC %h F %h BusA %h BusB %h",
					g_ref[`TRACE_CPU].ref.ACC, g_ref[`TRACE_CPU].ref.F, g_ref[`TRACE_CPU].ref.BusA, g_ref[`TRACE_CPU].ref.BusB,
					oct.core.ACC_m[`TRACE_CPU], oct.core.F_m[`TRACE_CPU], oct.core.BusA_m[`TRACE_CPU], oct.core.BusB_m[`TRACE_CPU]);
				for (i = 0; i < 8; i = i + 1)
					$display("reg %0d ref %h%h oct %h%h", i, g_ref[`TRACE_CPU].ref.i_reg.RegsH[i], g_ref[`TRACE_CPU].ref.i_reg.RegsL[i],
						oct.core.i_reg.RegsH[`TRACE_CPU*8 + i], oct.core.i_reg.RegsL[`TRACE_CPU*8 + i]);
`endif
				$display("tb_tv80o: %0d errors", errors);
				$finish;
			end
		end
	end
`ifdef TRACE_CPU
	// `define TRACE_CPU <k> TRACE_FROM <clock>: both CPUs k every clock from that clock on
	if (cycles >= `TRACE_FROM)
		$display("%0d s%0d rst %b run %b w %b i %b n %b | ref A %h do %h mc %b ts %b IR %h di %h | oct A %h do %h mc %b ts %b IR %h",
			cycles, slot, rst_n[`TRACE_CPU], run[`TRACE_CPU], wait_n[`TRACE_CPU], int_n[`TRACE_CPU], nmi_n[`TRACE_CPU],
			r_A[`TRACE_CPU*16 +: 16], r_dout[`TRACE_CPU*8 +: 8], r_mc[`TRACE_CPU*7 +: 7], r_ts[`TRACE_CPU*7 +: 7],
			g_ref[`TRACE_CPU].ref.IR, r_di[`TRACE_CPU*8 +: 8],
			q_A[`TRACE_CPU*16 +: 16], q_dout[`TRACE_CPU*8 +: 8], q_mc[`TRACE_CPU*7 +: 7], q_ts[`TRACE_CPU*7 +: 7],
			oct.core.IR_m[`TRACE_CPU]);
`endif
	if (cycles == `CLOCKS) begin
		$display("tb_tv80o: %0d clocks, M1 cycles per CPU %0d %0d %0d %0d %0d %0d %0d %0d, interrupts %0d %0d %0d %0d %0d %0d %0d %0d",
			cycles, m1s[0], m1s[1], m1s[2], m1s[3], m1s[4], m1s[5], m1s[6], m1s[7],
			ints[0], ints[1], ints[2], ints[3], ints[4], ints[5], ints[6], ints[7]);
		$display("tb_tv80o: %0d errors", errors + st_errors);
		$finish;
	end
end

endmodule
