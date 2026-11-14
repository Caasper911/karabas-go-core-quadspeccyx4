`timescale 1ns / 1ps
`default_nettype none

/*
 zx_oct.v

 Eight Pentagon 128 on one logic: one tv80 (tv80o_core, tools/mkctx.py) and one bus logic, the state of each machine
 in distributed RAM indexed by the machine (a context). clk = clk_bus, 28 MHz; a T-state of the 3.5 MHz CPUs is 8
 clocks, slot 0 the clock of ce_cpu (zx_timing).

   slot k      CPU k: its cen; its inputs (dinst, di, INT, NMI, reset) from the context of machine k
   slot k + 1  the bus logic of machine k: the new outputs of CPU k (second read port of tv80o_core, pth), the
               decode, the memory request, the port writes, the data the CPU will take (ports, FF)

 Memory. One request a clock at most (only machine slot - 1 asks), so the requests of the eight machines never meet:
 no queue, no WAIT. A read made at the start of T1 (bus slot) has its data 3 clocks later, the CPU takes it at the end
 of T2, 15 clocks after; a write is made at the start of T2. The ROM (128 editor and 48 BASIC, 32 KB) is a block RAM
 shared by the machines (rom_we: the loader), the RAM of machine m is 128 KB of SRAM at byte {BASE, m, page, offset}
 (sram_ctrl.v, latency 3 as the ROM pipeline here, so one return a clock: the context mdat of the machine).

 Ports as Pentagon 128: #FE (A0 = 0: border, MIC, beeper; read: keyboard and tape of the selected machine sel), #7FFD
 (A15 = 0, A1 = 0: page, screen, ROM, lock), AY #FFFD / #BFFD (A15 = 1, A1 = 0: a copy of the 16 registers per
 machine; the writes of the selected machine go out to the one AY, ay_*), Kempston #1F (the selected machine). INT
 of the raster as the CPU of slot 0 sees it (every machine in the same relation to its INT, as raster_delay of
 QuadSpeccy). The data of an I/O read is taken in each bus slot of the cycle (the last one before the CPU takes it
 counts), FF in the acknowledge M1 of an interrupt (IM 2 vectors from the bus: FF, Pentagon).

 src/sim/tb_wall.v compares the eight machines with eight tv80_core on a behavioural bus, clock for clock.
*/

module zx_oct #(
	parameter [1:0] BASE = 2'd0          // the MB of SRAM of this engine (byte address bits 21..20)
) (
	input wire clk,
	input wire [2:0] slot,               // this clock: cen of CPU slot, bus logic of machine slot - 1

	input wire int_n,                    // the raster INT (zx_timing)
	input wire [7:0] reset,              // machine m: bit m
	input wire [7:0] nmi,                // NMI while high

	// the selected machine: keyboard, tape, Kempston joystick
	input wire [2:0] sel,
	input wire [39:0] keys,              // pressed keys: bit row * 5 + column, row n = A(8+n) low
	input wire tape_in,
	input wire [7:0] kempston,

	// SRAM (sram_ctrl): a request is high for one clock, its read data m_q 3 clocks after that clock
	output reg m_req = 1'b0,
	output reg m_we = 1'b0,
	output reg [21:0] m_addr = 22'd0,    // byte
	output reg [7:0] m_din = 8'd0,
	input wire [15:0] m_q,               // the word of m_addr[21:1]

	// ROM loader (32 KB: 0..3FFF 128 editor, 4000..7FFF 48 BASIC)
	input wire rom_we,
	input wire [14:0] rom_wa,
	input wire [7:0] rom_wd,

	// per machine
	output reg [7:0] beeper = 8'd0,
	output reg [7:0] mic = 8'd0,
	input wire [2:0] v_m,                // the video reads the border and the screen of machine v_m
	output wire [2:0] v_border,
	output wire v_scr7,

	// the AY: the register writes of the selected machine; ay_rd its register ay_ra (to load the AY when sel changes)
	output reg ay_we = 1'b0,
	output reg [3:0] ay_wa = 4'd0,
	output reg [7:0] ay_wd = 8'd0,
	input wire [3:0] ay_ra,
	output wire [7:0] ay_rd,

	// debug, sticky until a reset of the machine: the data of a read was not there when the CPU took it
	output reg [7:0] late = 8'd0
);

wire [2:0] th = slot;             // the CPU of this clock
wire [2:0] b = slot - 3'd1;       // the machine of the bus logic

// ---------------------------------------------------------------------------------------------
// contexts (distributed RAM, index = machine)

integer i;
reg [5:0] c_7ffd [0:7];           // 2..0 page at C000, 3 screen, 4 ROM, 5 lock
reg [2:0] c_border [0:7];
reg c_wrdone [0:7];               // the write / port write of this M-cycle is made
reg c_rd [0:7];                   // this M-cycle reads memory
reg c_t2 [0:7];                   // the CPU is in T2: it takes its data at its next cen
reg c_src [0:7];                  // its data: 1 c_pdat (port, FF), 0 c_mdat (memory)
reg [7:0] c_pdat [0:7];
reg c_iss [0:7];                  // toggles: a read made (bus logic) / its data written (return): pending = differ
reg c_ret [0:7];
reg [7:0] c_mdat [0:7];
reg [7:0] c_di [0:7];             // DI of the CPU (T80se: the data of T2 kept)
reg [3:0] c_ayreg [0:7];
reg c_ayrv [0:7];                 // the register select had 0 in bits 7..4 (else the AY is not addressed)
reg [3:0] c_ayclr [0:7];          // a reset clears the 16 registers, one per T-state (a reset lasts 16 T or more)
reg [7:0] ay_ram [0:127];         // {machine, register}
initial begin
	for (i = 0; i < 8; i = i + 1) begin
		c_7ffd[i] = 6'd0; c_border[i] = 3'd0; c_wrdone[i] = 1'b0; c_rd[i] = 1'b0; c_t2[i] = 1'b0; c_src[i] = 1'b0;
		c_pdat[i] = 8'hFF; c_iss[i] = 1'b0; c_ret[i] = 1'b0; c_mdat[i] = 8'hFF; c_di[i] = 8'hFF; c_ayreg[i] = 4'd0;
		c_ayrv[i] = 1'b1; c_ayclr[i] = 4'd0;
	end
	for (i = 0; i < 128; i = i + 1) ay_ram[i] = 8'd0;
end

assign v_border = c_border[v_m];
assign v_scr7 = c_7ffd[v_m][3];
assign ay_rd = ay_ram[{sel, ay_ra}];

// ---------------------------------------------------------------------------------------------
// CPU

// INT: the value at slot 0 for every CPU
reg int_t = 1'b1;
always @(posedge clk)
	if (slot == 3'd0)
		int_t <= int_n;
wire c_int_n = (slot == 3'd0) ? int_n : int_t;

wire [7:0] c_dinst = c_src[th] ? c_pdat[th] : c_mdat[th];

wire [15:0] p_A;
wire [7:0] p_dout;
wire [6:0] p_mc, p_ts;
wire p_m1_n, p_iorq, p_no_read, p_write, p_intcycle_n, p_halt_n;

tv80o_core #(.Mode(0), .IOWait(1)) core (
	.th(th),
	.pth(b),
	.reset_n(~reset[th]),
	.clk(clk),
	.cen(1'b1),
	.wait_n(1'b1),
	.int_n(c_int_n),
	.nmi_n(~nmi[th]),
	.busrq_n(1'b1),
	.dinst(c_dinst),
	.di(c_di[th]),
	.m1_n(), .iorq(), .no_read(), .write(), .rfsh_n(), .halt_n(), .busak_n(), .A(), .dout(), .mc(), .ts(),
	.intcycle_n(), .IntE(), .stop(),
	.p_A(p_A), .p_dout(p_dout), .p_m1_n(p_m1_n), .p_mc(p_mc), .p_ts(p_ts), .p_halt_n(p_halt_n),
	.p_intcycle_n(p_intcycle_n), .p_iorq(p_iorq), .p_no_read(p_no_read), .p_write(p_write)
);

// at its cen the CPU takes DI of T2 (T80se); the data was not there: late
always @(posedge clk) begin
	if (c_t2[th])
		c_di[th] <= c_dinst;
	if (reset[th])
		late[th] <= 1'b0;
	else if (c_t2[th] && c_rd[th] && !c_src[th] && (c_iss[th] != c_ret[th]))
		late[th] <= 1'b1;
end

// ---------------------------------------------------------------------------------------------
// bus logic of machine b

wire m1 = p_mc[0];
wire t1 = p_ts[1], t2 = p_ts[2], t3 = p_ts[3];
wire mem_rd = m1 ? p_intcycle_n : (~p_no_read & ~p_write & ~p_iorq);
wire mem_wr = ~m1 & p_write & ~p_iorq;
wire io_rd = ~m1 & p_iorq & ~p_write;
wire io_wr = ~m1 & p_iorq & p_write;

wire [5:0] b7ffd = c_7ffd[b];
wire is_rom = (p_A[15:14] == 2'b00);
wire [2:0] page = (p_A[15:14] == 2'b01) ? 3'd5 : (p_A[15:14] == 2'b10) ? 3'd2 : b7ffd[2:0];
wire [21:0] ram_addr = {BASE, b, page, p_A[13:0]};
wire is_sel = (b == sel);

// ports
wire ay_port = p_A[15] & ~p_A[1];
reg [4:0] kb_col;
integer r;
always @* begin
	kb_col = 5'b11111;
	if (is_sel)
		for (r = 0; r < 8; r = r + 1)
			if (!p_A[8 + r])
				kb_col = kb_col & ~keys[r*5 +: 5];
end
wire [7:0] ay_q = ay_ram[{b, c_ayreg[b]}];
reg [7:0] port_q;
always @* begin
	if (!p_A[0])
		port_q = {1'b1, is_sel & tape_in, 1'b1, kb_col};
	else if (ay_port && p_A[14])
		port_q = c_ayrv[b] ? ay_q : 8'hFF;
	else if (p_A[7:0] == 8'h1F)
		port_q = is_sel ? kempston : 8'h00;
	else
		port_q = 8'hFF;
end

// the bits of AY register n (the rest read as 0)
function [7:0] ay_mask;
	input [3:0] n;
	case (n)
		4'd1, 4'd3, 4'd5, 4'd13: ay_mask = 8'h0F;
		4'd6, 4'd8, 4'd9, 4'd10: ay_mask = 8'h1F;
		default: ay_mask = 8'hFF;
	endcase
endfunction

// the ROM: block RAM, read in the clock after the bus slot, its data delayed to the latency of the SRAM
(* ram_style = "block" *) reg [7:0] rom [0:32767];
reg [14:0] rom_ra = 15'd0;
reg [7:0] rom_q1 = 8'hFF, rom_q2 = 8'hFF;
always @(posedge clk) begin
	if (rom_we)
		rom[rom_wa] <= rom_wd;
	rom_q1 <= rom[rom_ra];
end

// the returns: the machine, ROM or SRAM, the byte of the word, three clocks after the bus slot
reg [2:0] r_m1 = 3'd0, r_m2 = 3'd0, r_m3 = 3'd0;
reg r_v1 = 1'b0, r_v2 = 1'b0, r_v3 = 1'b0;
reg r_rom1 = 1'b0, r_rom2 = 1'b0, r_rom3 = 1'b0;
reg r_hi1 = 1'b0, r_hi2 = 1'b0, r_hi3 = 1'b0;

always @(posedge clk) begin
	m_req <= 1'b0;
	m_we <= 1'b0;
	ay_we <= 1'b0;

	r_v1 <= 1'b0;
	r_m1 <= b;
	r_rom1 <= 1'b0;
	r_hi1 <= p_A[0];
	{r_v2, r_m2, r_rom2, r_hi2} <= {r_v1, r_m1, r_rom1, r_hi1};
	{r_v3, r_m3, r_rom3, r_hi3} <= {r_v2, r_m2, r_rom2, r_hi2};
	rom_q2 <= rom_q1;

	if (reset[b]) begin
		c_7ffd[b] <= 6'd0;
		c_wrdone[b] <= 1'b0;
		c_rd[b] <= 1'b0;
		c_t2[b] <= 1'b0;
		c_ayreg[b] <= 4'd0;
		c_ayrv[b] <= 1'b1;
		// the AY registers: one per T-state while the reset lasts (the reset of the core and of the OSD are
		// milliseconds; src/sim/tb_wall.v holds a reset 20 T-states)
		c_ayclr[b] <= c_ayclr[b] + 1'd1;
		ay_ram[{b, c_ayclr[b]}] <= 8'd0;
		if (is_sel) begin
			ay_we <= 1'b1;
			ay_wa <= c_ayclr[b];
			ay_wd <= 8'd0;
		end
		// #FE is kept over a reset, as the ULA: the border stays until the ROM sets it
	end else begin
		c_t2[b] <= t2;

		// the data the CPU will take: a port, FF in the acknowledge M1, else the memory
		if (io_rd) begin
			c_src[b] <= 1'b1;
			c_pdat[b] <= port_q;
		end else if (m1 && !p_intcycle_n) begin
			c_src[b] <= 1'b1;
			c_pdat[b] <= 8'hFF;
		end else
			c_src[b] <= 1'b0;

		// T1: the read
		if (t1) begin
			c_wrdone[b] <= 1'b0;
			c_rd[b] <= mem_rd;
			if (mem_rd) begin
				c_iss[b] <= ~c_iss[b];
				r_v1 <= 1'b1;
				r_rom1 <= is_rom;
				rom_ra <= {b7ffd[4], p_A[13:0]};
				if (!is_rom) begin
					m_req <= 1'b1;
					m_addr <= ram_addr;
				end
			end
		end
		if (t3)
			c_rd[b] <= 1'b0;

		// T2: the write, the port writes
		if (t2 && !c_wrdone[b]) begin
			if (mem_wr) begin
				c_wrdone[b] <= 1'b1;
				if (!is_rom) begin
					m_req <= 1'b1;
					m_we <= 1'b1;
					m_addr <= ram_addr;
					m_din <= p_dout;
				end
			end
			if (io_wr) begin
				c_wrdone[b] <= 1'b1;
				if (!p_A[0]) begin
					c_border[b] <= p_dout[2:0];
					mic[b] <= p_dout[3];
					beeper[b] <= p_dout[4];
				end
				if (!p_A[15] && !p_A[1] && !b7ffd[5])
					c_7ffd[b] <= p_dout[5:0];
				if (ay_port && p_A[14]) begin
					c_ayreg[b] <= p_dout[3:0];
					c_ayrv[b] <= (p_dout[7:4] == 4'd0);
				end
			end
		end

		// AY: a write of #BFFD
		if (t2 && !c_wrdone[b] && io_wr && ay_port && !p_A[14] && c_ayrv[b]) begin
			ay_ram[{b, c_ayreg[b]}] <= p_dout & ay_mask(c_ayreg[b]);
			if (is_sel) begin
				ay_we <= 1'b1;
				ay_wa <= c_ayreg[b];
				ay_wd <= p_dout & ay_mask(c_ayreg[b]);
			end
		end
	end

	// the return of the read of 3 clocks before
	if (r_v3) begin
		c_ret[r_m3] <= ~c_ret[r_m3];
		c_mdat[r_m3] <= r_rom3 ? rom_q2 : r_hi3 ? m_q[15:8] : m_q[7:0];
	end
end

endmodule
