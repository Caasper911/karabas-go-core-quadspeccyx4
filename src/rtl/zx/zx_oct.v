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

 Memory. One request a clock at most (only machine slot - 1 asks): m_req for one clock, a read at the start of T1 (bus
 slot), a write at the start of T2; the CPU takes the data of a read at the end of T2, 15 clocks after the request,
 so no WAIT. All memory is in the SRAM (byte address, 22 bits), ROM and RAM alike; the data of a read comes back
 whenever the SRAM arbiter (sram_arb.v, a queue for two engines) has it: m_rv with the machine m_rm and the byte m_rd
 (the context ramd of the machine; late if it was not there in time):
   {0, BASE[0], m, page, offset 14}       the 128 KB of RAM of machine m
   {1, BASE[0], m, bank 4, offset 13}     the 128 KB of the DivMMC of machine m (machine 7 of engine 1, the 16th: 64 KB,
                                          banks 0..7: its banks 8..15 are the ROMs)
   {1, 1, 111, 1, rom 16}                 the ROMs, shared: 0000 128 editor, 4000 48 BASIC, 8000 ESXDOS (8 KB); written
                                          by the loader of the core (not through here)

 Ports as Pentagon 128: #FE (A0 = 0: border, MIC, beeper; read: the keyboard of the selected machine sel, or of all with
 keys_all, and the tape input of the machine, tape_in[b]), #7FFD
 (A15 = 0, A1 = 0: page, screen, ROM, lock), AY #FFFD / #BFFD (A15 = 1, A1 = 0: a copy of the 16 registers per
 machine; the writes of the selected machine go out to the one AY, ay_*), Kempston #1F (the selected machine). INT:
 int_n is that of the CPU of this slot (zx_vid.v: the raster of each machine is staggered). The data of an I/O read is taken in each bus slot of the cycle (the last one before the CPU takes it
 counts), FF in the acknowledge M1 of an interrupt (IM 2 vectors from the bus: FF, Pentagon).

 DivMMC (divmmc_en; as pentagon.v of QuadSpeccy, after divmmc.vhd of divgmx): #E3 (7 CONMEM, 6 MAPRAM, 5..0 the bank
 at 2000; 3..0 used, 128 KB), #E7 (bit 0 the card select), #EB (SPI: a write sends the byte, a read gives the byte of
 the exchange before and sends FF; the card: sd_oct.v, sd_en; an I/O read of #EB waits (WAIT) while the card
 waits for the image). Mapped (CONMEM or automap): 0000-1FFF
 the ESXDOS ROM (with MAPRAM: bank 3, read only), 2000-3FFF the bank (read only with MAPRAM and bank 3). Automap: an
 opcode fetch of 0000, 0008, 0038, 0066, 04C6, 0562 sets detect, of 1FF8-1FFF clears it, of 3D00-3DFF maps at once
 (the fetch itself, any ROM); out of the M1 read automap follows detect. A reset of the machine keeps the DivMMC (a
 reset with NMI held clears #E3 and the card select); dv_clear (power on) and DivMMC off clear all.

 src/sim/tb_wall.v compares the eight machines with eight tv80_core on a behavioural bus, clock for clock.
*/

module zx_oct #(
	parameter [1:0] BASE = 2'd0,         // the MB of SRAM of this engine (byte address bits 21..20)
	parameter [15:0] LFSR_INIT = BASE[0] ? 16'hACE1 : 16'h1D2B   // the start of the R seed LFSR (not 0)
) (
	input wire clk,
	input wire [2:0] slot,               // this clock: cen of CPU slot, bus logic of machine slot - 1

	input wire int_n,                    // the INT of the CPU of this slot (zx_vid)
	input wire [7:0] reset,              // machine m: bit m
	input wire [7:0] nmi,                // NMI while high

	// the selected machine (sel_en: it is in this engine): keyboard, tape, Kempston joystick, the AY
	input wire sel_en,
	input wire [2:0] sel,
	input wire [39:0] keys,              // pressed keys: bit row * 5 + column, row n = A(8+n) low
	input wire keys_all,                 // the keys and Kempston go to every machine (else only to the selected one)
	input wire [7:0] tape_in,            // the tape input of machine m: bit m (EAR, bit 6 of #FE)
	input wire [7:0] kempston,

	// SRAM (sram_arb): a request is high for one clock; the byte of a read comes later (m_rv one clock: machine m_rm)
	output reg m_req = 1'b0,
	output reg m_we = 1'b0,
	output reg [21:0] m_addr = 22'd0,    // byte
	output reg [7:0] m_din = 8'd0,
	output reg [2:0] m_m = 3'd0,         // the machine of the request (its read comes back to it)
	input wire m_rv,
	input wire [2:0] m_rm,
	input wire [7:0] m_rd,

	// DivMMC
	input wire divmmc_en,
	input wire dv_clear,                 // the state of the DivMMC of every machine cleared (power on; hold 1 T or more)
	// the SD cards (sd_oct): sd_en 0 none (#EB gives FF); h_* sd_host
	input wire sd_en,
	input wire [21:0] sd_csize,
	output wire [7:0] h_pend,
	output wire [7:0] h_wr,
	input wire [2:0] h_m,
	output wire [31:0] h_lba,
	input wire h_done,
	input wire h_we,
	input wire [8:0] h_a,
	input wire [7:0] h_d,
	output wire [7:0] h_q,

	// per machine
	output reg [7:0] beeper = 8'd0,
	output reg [7:0] mic = 8'd0,
	// the video (zx_vid) of machine slot - 4: its border and screen
	output wire [2:0] v_border,
	output wire v_scr7,

	// the AY: the register writes of the selected machine; ay_rd its register ay_ra (to load the AY when sel changes)
	output reg ay_we = 1'b0,
	output reg [3:0] ay_wa = 4'd0,
	output reg [7:0] ay_wd = 8'd0,
	input wire [3:0] ay_ra,
	output wire [7:0] ay_rd,

	// debug, sticky until a reset of the machine: the data of a read was not there when the CPU took it
	output reg [7:0] late = 8'd0,
	// debug of machine sel (bring-up): the address of its last opcode fetch, its #7FFD, sticky (cleared by its reset):
	// bit 0 a write of #FE, 1 a write of #7FFD (with the lock off), 2 a memory write, 3 an I/O write, 4 an opcode
	// fetch from RAM, 5 an interrupt acknowledge
	output reg [15:0] dbg_pc = 16'd0,
	output wire [5:0] dbg_7ffd,
	output reg [5:0] dbg_ev = 6'd0
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
reg c_src [0:7];                  // its data: 1 c_pdat (port, FF), 0 the memory (c_ramd)
reg [7:0] c_pdat [0:7];
reg c_iss [0:7];                  // toggles: a read of the SRAM made (bus logic) / its data written: pending = differ
reg c_ret [0:7];
reg [7:0] c_ramd [0:7];           // the byte of the last read of the memory
reg c_conmem [0:7];               // DivMMC: #E3 bit 7
reg c_mapram [0:7];               // #E3 bit 6 (sticky)
reg [3:0] c_dvbank [0:7];         // #E3 bits 3..0
reg c_automap [0:7];
reg c_detect [0:7];
reg c_cs_n [0:7];                 // the card select (#E7 bit 0), 1 deselected
reg c_ebw [0:7];                  // an I/O read of #EB waits for the card (WAIT of the CPU)
reg [7:0] c_di [0:7];             // DI of the CPU (T80se: the data of T2 kept)
reg [3:0] c_ayreg [0:7];
reg c_ayrv [0:7];                 // the register select had 0 in bits 7..4 (else the AY is not addressed)
reg [3:0] c_ayclr [0:7];          // a reset clears the 16 registers, one per T-state (a reset lasts 16 T or more)
reg [7:0] c_seed [0:7];           // R of the CPU after its reset (rseed): the LFSR below while the machine is in reset
reg [7:0] ay_ram [0:127];         // {machine, register}
initial begin
	for (i = 0; i < 8; i = i + 1) begin
		c_7ffd[i] = 6'd0; c_border[i] = 3'd0; c_wrdone[i] = 1'b0; c_rd[i] = 1'b0; c_t2[i] = 1'b0; c_src[i] = 1'b0;
		c_pdat[i] = 8'hFF; c_iss[i] = 1'b0; c_ret[i] = 1'b0; c_ramd[i] = 8'hFF; c_di[i] = 8'hFF; c_ayreg[i] = 4'd0;
		c_ayrv[i] = 1'b1; c_ayclr[i] = 4'd0; c_seed[i] = 8'd0;
		c_conmem[i] = 1'b0; c_mapram[i] = 1'b0; c_dvbank[i] = 4'd0; c_automap[i] = 1'b0; c_detect[i] = 1'b0;
		c_cs_n[i] = 1'b1; c_ebw[i] = 1'b0;
	end
	for (i = 0; i < 128; i = i + 1) ay_ram[i] = 8'd0;
end

wire [2:0] v_m = slot - 3'd4;
assign v_border = c_border[v_m];
assign v_scr7 = c_7ffd[v_m][3];
assign ay_rd = ay_ram[{sel, ay_ra}];
assign dbg_7ffd = c_7ffd[sel];

// ---------------------------------------------------------------------------------------------
// CPU

// R after a reset: not 0 as the Z80, a different pseudo-random value for each machine (the user asked for it,
// programs take random numbers from R). A 16-bit LFSR runs every clock (another start in each engine); a machine in
// reset takes it in its bus slot (c_seed), the CPU loads R from it in its reset slots: R is the value of the last
// clock of the reset, which depends on when the reset ends (the ROM loading of the MCU, a key press)
reg [15:0] lfsr = LFSR_INIT;
always @(posedge clk)
	lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

// INT of the CPU of this slot
wire c_int_n = int_n;

wire [7:0] c_dinst = c_src[th] ? c_pdat[th] : c_ramd[th];

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
	.wait_n(~c_ebw[th]),
	.int_n(c_int_n),
	.nmi_n(~nmi[th]),
	.busrq_n(1'b1),
	.dinst(c_dinst),
	.rseed(c_seed[th]),
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
wire [2:0] page = (p_A[15:14] == 2'b01) ? 3'd5 : (p_A[15:14] == 2'b10) ? 3'd2 : b7ffd[2:0];

// the DivMMC of machine b: mapped by CONMEM, automap or this opcode fetch of 3Dxx
wire dv_instant = m1 & p_intcycle_n & (p_A[15:8] == 8'h3D);
wire dv_mapped = divmmc_en & (c_conmem[b] | c_automap[b] | dv_instant);
wire last_m = BASE[0] && b == 3'd7;              // the 16th machine: 64 KB of DivMMC (banks 0..7)
wire [3:0] dv_bank = last_m ? {1'b0, c_dvbank[b][2:0]} : c_dvbank[b];

// the memory map: the byte of the SRAM, read only
reg [21:0] mem_addr;
reg mem_ro;
always @* begin
	mem_ro = 1'b0;
	if (dv_mapped && p_A[15:13] == 3'b000) begin
		mem_ro = 1'b1;
		mem_addr = c_mapram[b] ? {1'b1, BASE[0], b, 4'd3, p_A[12:0]} : {6'b111111, 3'b100, p_A[12:0]};
	end else if (dv_mapped && p_A[15:13] == 3'b001) begin
		mem_ro = c_mapram[b] && c_dvbank[b] == 4'd3;
		mem_addr = {1'b1, BASE[0], b, dv_bank, p_A[12:0]};
	end else if (p_A[15:14] == 2'b00) begin
		mem_ro = 1'b1;
		mem_addr = {6'b111111, 1'b0, b7ffd[4], p_A[13:0]};        // ROM 128 / 48
	end else
		mem_addr = {1'b0, BASE[0], b, page, p_A[13:0]};
end
wire dv_entry = p_A == 16'h0000 || p_A == 16'h0008 || p_A == 16'h0038 || p_A == 16'h0066 ||
	p_A == 16'h04C6 || p_A == 16'h0562;
wire dv_exit = p_A[15:3] == 13'b0001111111111;   // 1FF8-1FFF
wire dv_port = divmmc_en && p_A[7:0] == 8'hEB;
// the card of machine b: the exchange of this clock (xfer, tx), the byte of the last one (sd_q), busy: it waits
reg sd_xfer;
reg [7:0] sd_tx;
wire [7:0] sd_q;
wire sd_busy;
sd_oct sd (
	.clk(clk), .b(b), .rst(reset[b]), .clr(dv_clear | ~divmmc_en | ~sd_en), .xfer(sd_xfer), .tx(sd_tx),
	.cs_n(c_cs_n[b]), .q(sd_q), .busy(sd_busy), .c_size(sd_csize),
	.h_pend(h_pend), .h_wr(h_wr), .h_m(h_m), .h_lba(h_lba), .h_done(h_done), .h_we(h_we), .h_a(h_a), .h_d(h_d),
	.h_q(h_q)
);
wire is_sel = sel_en && (b == sel);
wire has_keys = is_sel || keys_all;    // the keyboard and Kempston

// ports
wire ay_port = p_A[15] & ~p_A[1];
reg [4:0] kb_col;
integer r;
always @* begin
	kb_col = 5'b11111;
	if (has_keys)
		for (r = 0; r < 8; r = r + 1)
			if (!p_A[8 + r])
				kb_col = kb_col & ~keys[r*5 +: 5];
end
wire [7:0] ay_q = ay_ram[{b, c_ayreg[b]}];
reg [7:0] port_q;
always @* begin
	if (!p_A[0])
		port_q = {1'b1, tape_in[b], 1'b1, kb_col};
	else if (ay_port && p_A[14])
		port_q = c_ayrv[b] ? ay_q : 8'hFF;
	else if (p_A[7:0] == 8'h1F)
		port_q = has_keys ? kempston : 8'h00;
	else if (dv_port)
		port_q = sd_q;
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

// the next contexts of machine b (written in its bus slot, one write of each a clock)
reg [5:0] n_7ffd;
reg n_wrdone, n_rd, n_t2, n_src, n_iss, n_ayrv, n_ay_we;
reg n_conmem, n_mapram, n_automap, n_detect, n_cs_n;
reg [3:0] n_dvbank;
reg n_ebw;
reg [7:0] n_pdat, n_ay_d;
reg [2:0] n_border;
reg [3:0] n_ayreg, n_ayclr;
reg [7:0] n_seed;
reg [6:0] n_ay_a;
always @* begin
	n_7ffd = c_7ffd[b];
	n_wrdone = c_wrdone[b];
	n_rd = c_rd[b];
	n_t2 = t2;
	n_src = 1'b0;
	n_pdat = c_pdat[b];
	n_iss = c_iss[b];
	n_conmem = c_conmem[b];
	n_mapram = c_mapram[b];
	n_dvbank = c_dvbank[b];
	n_automap = c_automap[b];
	n_detect = c_detect[b];
	n_cs_n = c_cs_n[b];
	n_ebw = 1'b0;
	sd_xfer = 1'b0;
	sd_tx = 8'hFF;
	n_border = c_border[b];
	n_ayreg = c_ayreg[b];
	n_ayrv = c_ayrv[b];
	n_ayclr = c_ayclr[b];
	n_seed = reset[b] ? lfsr[7:0] ^ lfsr[15:8] : c_seed[b];
	n_ay_we = 1'b0;
	n_ay_a = {b, c_ayreg[b]};
	n_ay_d = p_dout & ay_mask(c_ayreg[b]);
	if (reset[b]) begin
		n_7ffd = 6'd0;
		n_wrdone = 1'b0;
		n_rd = 1'b0;
		n_t2 = 1'b0;
		n_src = c_src[b];
		n_ayreg = 4'd0;
		n_ayrv = 1'b1;
		// the AY registers: one per T-state while the reset lasts (the reset of the core and of the OSD are
		// milliseconds; src/sim/tb_wall.v holds a reset 20 T-states). #FE is kept over a reset, as the ULA: the
		// border stays until the ROM sets it
		n_ayclr = c_ayclr[b] + 1'd1;
		n_ay_we = 1'b1;
		n_ay_a = {b, c_ayclr[b]};
		n_ay_d = 8'd0;
		// the DivMMC is kept over a reset, but with NMI held (ESXDOS without its state) #E3 and the card select
		if (nmi[b]) begin
			n_conmem = 1'b0;
			n_mapram = 1'b0;
			n_dvbank = 4'd0;
			n_cs_n = 1'b1;
		end
	end else begin
		// DivMMC automap: in the M1 read (T1, T2) by the address, out of it automap follows detect
		if (m1 && p_intcycle_n && (t1 || t2)) begin
			if (dv_entry)
				n_detect = 1'b1;
			else if (dv_exit)
				n_detect = 1'b0;
			else if (p_A[15:8] == 8'h3D) begin
				n_automap = 1'b1;
				n_detect = 1'b1;
			end
		end else
			n_automap = c_detect[b];
		// the data the CPU will take: a port, FF in the acknowledge M1, else the memory
		if (io_rd) begin
			n_src = 1'b1;
			// (#EB: not after its exchange in this cycle, that gave c_spi the byte of the next one)
			if (!(dv_port && c_wrdone[b]))
				n_pdat = port_q;
		end else if (m1 && !p_intcycle_n) begin
			n_src = 1'b1;
			n_pdat = 8'hFF;
		end
		// T1: the read
		if (t1) begin
			n_wrdone = 1'b0;
			n_rd = mem_rd;
			if (mem_rd)
				n_iss = ~c_iss[b];
		end
		if (t3)
			n_rd = 1'b0;
		// T2: the write, the port writes
		if (t2 && !c_wrdone[b]) begin
			if (mem_wr)
				n_wrdone = 1'b1;
			if (io_wr) begin
				n_wrdone = 1'b1;
				if (!p_A[0])
					n_border = p_dout[2:0];
				if (!p_A[15] && !p_A[1] && !b7ffd[5])
					n_7ffd = p_dout[5:0];
				if (ay_port && p_A[14]) begin
					n_ayreg = p_dout[3:0];
					n_ayrv = (p_dout[7:4] == 4'd0);
				end
				// AY: a write of #BFFD
				if (ay_port && !p_A[14] && c_ayrv[b])
					n_ay_we = 1'b1;
				// DivMMC
				if (divmmc_en && p_A[7:0] == 8'hE3) begin
					n_conmem = p_dout[7];
					n_mapram = c_mapram[b] | p_dout[6];
					n_dvbank = p_dout[3:0];
				end
				if (divmmc_en && p_A[7:0] == 8'hE7)
					n_cs_n = p_dout[0];
				if (dv_port) begin
					sd_xfer = 1'b1;                      // the exchange of a write
					sd_tx = p_dout;
				end
			end
			// the exchange of a read of #EB (the CPU has taken sd_q, the byte of the exchange before); while
			// the card waits for the image the CPU waits (T2 again)
			if (io_rd && dv_port) begin
				if (sd_busy)
					n_ebw = 1'b1;
				else begin
					n_wrdone = 1'b1;
					sd_xfer = 1'b1;
				end
			end
		end
	end
	// power on, DivMMC off
	if (dv_clear || !divmmc_en) begin
		n_conmem = 1'b0;
		n_mapram = 1'b0;
		n_dvbank = 4'd0;
		n_automap = 1'b0;
		n_detect = 1'b0;
		n_cs_n = 1'b1;
		n_ebw = 1'b0;
	end
end

always @(posedge clk) begin
	m_req <= 1'b0;
	m_we <= 1'b0;
	ay_we <= 1'b0;

	// the contexts of machine b: one write of each a clock (n_*, below). XST 14.7 got a context written in both
	// branches of "if (reset) ... else ..." wrong: c_t2 became a RAM written only when its data was 0 (found by the
	// simulation of the netlist, src/sim/run_ps.sh: on the board no machine ran)
	c_7ffd[b] <= n_7ffd;
	c_wrdone[b] <= n_wrdone;
	c_rd[b] <= n_rd;
	c_t2[b] <= n_t2;
	c_src[b] <= n_src;
	c_pdat[b] <= n_pdat;
	c_iss[b] <= n_iss;
	c_conmem[b] <= n_conmem;
	c_mapram[b] <= n_mapram;
	c_dvbank[b] <= n_dvbank;
	c_automap[b] <= n_automap;
	c_detect[b] <= n_detect;
	c_cs_n[b] <= n_cs_n;
	c_ebw[b] <= n_ebw;
	c_border[b] <= n_border;
	c_ayreg[b] <= n_ayreg;
	c_ayrv[b] <= n_ayrv;
	c_ayclr[b] <= n_ayclr;
	c_seed[b] <= n_seed;
	if (n_ay_we)
		ay_ram[n_ay_a] <= n_ay_d;
	if (n_ay_we && is_sel) begin
		ay_we <= 1'b1;
		ay_wa <= n_ay_a[3:0];
		ay_wd <= n_ay_d;
	end

	if (reset[b]) begin
		if (is_sel)
			dbg_ev <= 6'd0;
	end else begin
		if (is_sel) begin
			if (m1 && t1 && p_intcycle_n) begin
				dbg_pc <= p_A;
				if (p_A[15:14] != 2'b00) dbg_ev[4] <= 1'b1;
			end
			if (m1 && t1 && !p_intcycle_n) dbg_ev[5] <= 1'b1;
			if (t2 && !c_wrdone[b]) begin
				if (mem_wr) dbg_ev[2] <= 1'b1;
				if (io_wr) dbg_ev[3] <= 1'b1;
				if (io_wr && !p_A[0]) dbg_ev[0] <= 1'b1;
				if (io_wr && !p_A[15] && !p_A[1] && !b7ffd[5]) dbg_ev[1] <= 1'b1;
			end
		end

		// T1: the read
		if (t1 && mem_rd) begin
			m_req <= 1'b1;
			m_addr <= mem_addr;
			m_m <= b;
		end

		// T2: the write, #FE
		if (t2 && !c_wrdone[b]) begin
			if (mem_wr && !mem_ro) begin
				m_req <= 1'b1;
				m_we <= 1'b1;
				m_addr <= mem_addr;
				m_din <= p_dout;
			end
			if (io_wr && !p_A[0]) begin
				mic[b] <= p_dout[3];
				beeper[b] <= p_dout[4];
			end
		end
	end

	// the return of a read
	if (m_rv) begin
		c_ret[m_rm] <= ~c_ret[m_rm];
		c_ramd[m_rm] <= m_rd;
	end
end

endmodule
