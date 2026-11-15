`timescale 1ns / 1ps
`default_nettype none

/*
 fb_sdram.v

 The frame buffer of the wall in the SDRAM (32 MB, 4 banks x 8192 rows x 512 words): the cells of the sixteen machines
 (320 x 200, 4 bits a pixel, 80 words a line) as their rasters draw them (zx_vid.v), read a row of the wall at a time
 for vga_out. clk = clk_sys (84 MHz), the SDRAM on the negative clock, CAS latency 2, burst length 1, the timing of
 sdram_ctrl of QuadSpeccy (the read data taken on the falling clock 2.5 clocks after READ), but a command every
 clock: a line is ACTIVE, 80 READ / WRITE in a row (the last with auto precharge), 5 clocks idle.

 Where: bank = the frame (three per machine), row = {machine, line[7:2]}, column = {line[1:0], word}.

 Writes. zx_vid writes the words of a line of machine k into the line buffer of its engine (block RAM, clk_bus;
 {k, line parity, word}) and gives l_done with the last one; the line goes into the queue (clk_bus, 16 entries) and
 is written from the buffer to the SDRAM (it has a line of the machine, 64 us, before the buffer is used again).

 Reads. vga_out asks for the row it shows next (rq_t toggles with rq_cr / rq_lc / rq_half, pclk): the line rq_lc of
 the four machines 4 rq_cr .. 4 rq_cr + 3 into the row buffer (rb_*: block RAM {half, column of cells, word}, read on
 pclk). A row has 1568 pclk (1790 clk_sys); it takes 4 x 87 clocks, before the writes (a write waits at most a row).

 The frames of machine g (no tearing): w[g] the one being written, c[g] the last complete one, d[g] the one shown
 (taken from c[g] when the first line of its cell row is read). When line 199 of w is written, c = w and w the third
 one (not c, not d).

 Refresh: every 512 clocks one more is owed (8192 in 64 ms needs one in 7.8 us = 656 clocks); between the lines.
*/

module fb_sdram #(
	parameter INIT_WAIT = 16'd20000      // clocks before the init sequence (238 us > 100 us)
) (
	input wire clk,                      // clk_sys
	input wire clk_bus,                  // clk_sys / 3, the same PLL
	input wire pclk,

	// clk_bus: the cells of the engines (zx_vid)
	input wire [1:0] w_we,
	input wire [21:0] w_addr,            // engine e: w_addr[e*11 +: 11]
	input wire [31:0] w_data,
	input wire [1:0] l_done,
	input wire [5:0] l_m,
	input wire [15:0] l_lc,

	// pclk: the rows of the wall (vga_out)
	input wire rq_t,
	input wire [1:0] rq_cr,
	input wire [7:0] rq_lc,
	input wire rq_half,
	input wire [9:0] rb_addr,
	output wire [15:0] rb_q,

	output reg ready = 1'b0,
	output reg over = 1'b0,              // the line queue overflowed (sticky, debug)

	output wire SDR_CLK,
	output reg [1:0] SDR_BA = 2'b00,
	output reg [12:0] SDR_A = 13'd0,
	output reg [1:0] SDR_DQM = 2'b11,
	output wire SDR_RAS_N,
	output wire SDR_CAS_N,
	output wire SDR_WE_N,
	inout wire [15:0] SDR_DQ
);

// ---------------------------------------------------------------------------------------------
// clk_bus: the line buffers and the queue of written lines

reg lb_en = 1'b0;
reg [10:0] lb_a = 11'd0;
wire [15:0] lb_q0, lb_q1;
kg_sdpram #(.DW(16), .AW(11)) lbuf0 (
	.clka(clk_bus), .wea(w_we[0]), .addra(w_addr[10:0]), .dina(w_data[15:0]),
	.clkb(clk), .enb(1'b1), .addrb(lb_a), .doutb(lb_q0)
);
kg_sdpram #(.DW(16), .AW(11)) lbuf1 (
	.clka(clk_bus), .wea(w_we[1]), .addra(w_addr[21:11]), .dina(w_data[31:16]),
	.clkb(clk), .enb(1'b1), .addrb(lb_a), .doutb(lb_q1)
);

// {engine, machine, line}; the two engines never end a line in the same clock (their rasters are 104 T apart)
reg [11:0] lq [0:15];
reg [3:0] lq_wp = 4'd0, lq_rp = 4'd0;
always @(posedge clk_bus)
	if (l_done != 2'b00) begin
		lq[lq_wp] <= l_done[1] ? {1'b1, l_m[5:3], l_lc[15:8]} : {1'b0, l_m[2:0], l_lc[7:0]};
		lq_wp <= lq_wp + 1'd1;
		if (lq_wp + 1'd1 == lq_rp)
			over <= 1'b1;
	end
wire lq_ne = lq_wp != lq_rp;
wire [11:0] lq_head = lq[lq_rp];

// ---------------------------------------------------------------------------------------------
// pclk: the row requests (a toggle; the row registers are stable when it is seen)

reg [2:0] rq_s = 3'd0;
always @(posedge clk)
	rq_s <= {rq_s[1:0], rq_t};
wire rq_ev = rq_s[2] ^ rq_s[1];
reg rq_pend = 1'b0;
reg [1:0] rp_cr = 2'd0;
reg [7:0] rp_lc = 8'd0;
reg rp_half = 1'b0;

// ---------------------------------------------------------------------------------------------
// the row buffer: written on clk, read on pclk

reg rb_we = 1'b0;
reg [9:0] rb_wa = 10'd0;
reg [15:0] rb_wd = 16'd0;
kg_sdpram #(.DW(16), .AW(10)) rbuf (
	.clka(clk), .wea(rb_we), .addra(rb_wa), .dina(rb_wd),
	.clkb(pclk), .enb(1'b1), .addrb(rb_addr), .doutb(rb_q)
);

// ---------------------------------------------------------------------------------------------
// the SDRAM pins

localparam CMD_NOP     = 3'b111;
localparam CMD_ACTIVE  = 3'b011;
localparam CMD_READ    = 3'b101;
localparam CMD_WRITE   = 3'b100;
localparam CMD_PRECHG  = 3'b010;
localparam CMD_REFRESH = 3'b001;
localparam CMD_MODE    = 3'b000;

// mode register: single write, CAS latency 2, sequential, burst length 1
localparam [12:0] MODE = 13'b000_1_00_010_0_000;

reg [2:0] cmd = CMD_NOP;
assign {SDR_RAS_N, SDR_CAS_N, SDR_WE_N} = cmd;

// the write data and its enable in the IOBs (sdram_ctrl of QuadSpeccy: one register per pin)
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [15:0] dq_out = 16'd0;
(* IOB = "TRUE", equivalent_register_removal = "no" *) reg [15:0] dq_t = 16'hFFFF;   // 1: Z
genvar gd;
generate
	for (gd = 0; gd < 16; gd = gd + 1) begin : g_dq
		assign SDR_DQ[gd] = dq_t[gd] ? 1'bZ : dq_out[gd];
	end
endgenerate

// the negative clock of the SDRAM: it rises in the middle of a clk period
ODDR2 #(.DDR_ALIGNMENT("NONE"), .INIT(1'b0), .SRTYPE("SYNC")) u_sdr_clk (
	.Q(SDR_CLK), .C0(clk), .C1(~clk), .CE(1'b1), .D0(1'b0), .D1(1'b1), .R(1'b0), .S(1'b0)
);

// the read data: taken on the falling clock 2.5 clocks after READ, then a register, then the row buffer
reg [15:0] dq_in = 16'd0, dq_r = 16'd0;
reg [4:0] rd_sr = 5'd0;              // a READ left its register 0..4 clocks ago
reg [9:0] ra0 = 10'd0, ra1 = 10'd0, ra2 = 10'd0, ra3 = 10'd0;
always @(negedge clk)
	if (rd_sr[2])
		dq_in <= SDR_DQ;

// ---------------------------------------------------------------------------------------------
// the frames of the machines

reg [31:0] fw = 32'h00000000;        // machine g: bits 2g + 1..2g, the frame being written
reg [31:0] fc = 32'h55555555;        // the last complete
reg [31:0] fd = 32'hAAAAAAAA;        // shown

// ---------------------------------------------------------------------------------------------
// the sequencer

reg [15:0] init_cnt = 16'd0;
reg [4:0] init_step = 5'd0;

reg [8:0] rf_cnt = 9'd0;
reg [3:0] rf_owed = 4'd0;
reg rf_take = 1'b0;

localparam S_IDLE = 2'd0, S_LINE = 2'd1, S_WAIT = 2'd2;
reg [1:0] st = S_IDLE;
reg [3:0] wt = 4'd0;                 // S_WAIT: clocks left
reg job_rd = 1'b0;                   // the job: a row (4 lines read) or a line written
reg [1:0] seg = 2'd0;                // the line of a row
reg [6:0] cc = 7'd0;                 // the clock in a line: 0 ACTIVE, 2..81 the words
reg [3:0] g = 4'd0;                  // the machine of the line
reg [7:0] ln = 8'd0;                 // its line in the cell
reg jh = 1'b0;                       // a row: the half of the row buffer
reg je = 1'b0;                       // a write: the engine (line buffer)
reg [2:0] jk = 3'd0;

wire [6:0] wd = cc - 7'd2;           // the word of this clock
wire [1:0] g_w = fw[{g, 1'b0} +: 2];
wire [1:0] g_c = fc[{g, 1'b0} +: 2];
wire [1:0] g_d = fd[{g, 1'b0} +: 2];

always @(posedge clk) begin
	cmd <= CMD_NOP;
	dq_t <= 16'hFFFF;
	rd_sr <= {rd_sr[3:0], 1'b0};
	ra1 <= ra0;
	ra2 <= ra1;
	ra3 <= ra2;
	if (rd_sr[2])
		dq_r <= dq_in;                  // (taken on the falling clock in the middle of this one)
	rb_we <= rd_sr[3];
	rb_wa <= ra3;
	rb_wd <= dq_r;

	// refresh owed
	rf_cnt <= rf_cnt + 1'd1;
	if (rf_cnt == 9'd511 && !rf_take && rf_owed != 4'd15)
		rf_owed <= rf_owed + 1'd1;
	else if (rf_take && rf_cnt != 9'd511)
		rf_owed <= rf_owed - 1'd1;
	rf_take <= 1'b0;

	if (rq_ev) begin
		rq_pend <= 1'b1;
		rp_cr <= rq_cr;
		rp_lc <= rq_lc;
		rp_half <= rq_half;
	end

	if (!ready) begin
		SDR_DQM <= 2'b11;
		if (init_cnt != INIT_WAIT)
			init_cnt <= init_cnt + 1'd1;
		else begin
			init_step <= init_step + 1'd1;
			case (init_step)
				5'd0: begin cmd <= CMD_PRECHG; SDR_A[10] <= 1'b1; end
				5'd4: cmd <= CMD_REFRESH;
				5'd12: cmd <= CMD_REFRESH;
				5'd20: begin cmd <= CMD_MODE; SDR_A <= MODE; SDR_BA <= 2'b00; end
				5'd24: ready <= 1'b1;
				default: ;
			endcase
		end
	end else begin
		SDR_DQM <= 2'b00;
		case (st)
			S_IDLE: begin
				cc <= 7'd0;
				seg <= 2'd0;
				if (rf_owed != 4'd0 && (rf_owed >= 4'd4 || !rq_pend)) begin
					cmd <= CMD_REFRESH;
					rf_take <= 1'b1;
					wt <= 4'd7;                     // tRFC 66 ns
					st <= S_WAIT;
				end else if (rq_pend) begin
					rq_pend <= rq_ev;               // (a new request in this clock stays)
					job_rd <= 1'b1;
					g <= {rp_cr, 2'd0};
					ln <= rp_lc;
					jh <= rp_half;
					st <= S_LINE;
					// the first line of a cell row: its machines show their last complete frame from now on
					if (rp_lc == 8'd0)
						fd[{rp_cr, 3'b000} +: 8] <= fc[{rp_cr, 3'b000} +: 8];
				end else if (lq_ne) begin
					lq_rp <= lq_rp + 1'd1;
					job_rd <= 1'b0;
					je <= lq_head[11];
					jk <= lq_head[10:8];
					g <= lq_head[11:8];
					ln <= lq_head[7:0];
					st <= S_LINE;
				end
			end

			S_LINE: begin
				cc <= cc + 1'd1;
				if (cc == 7'd0) begin
					cmd <= CMD_ACTIVE;
					SDR_BA <= job_rd ? g_d : g_w;
					SDR_A <= {3'b000, g, ln[7:2]};
				end
				// a write: the word of the line buffer two clocks ahead
				lb_a <= {jk, ln[0], cc};
				if (cc >= 7'd2) begin
					SDR_A <= {2'b00, cc == 7'd81, 1'b0, ln[1:0], wd};
					if (job_rd) begin
						cmd <= CMD_READ;
						rd_sr[0] <= 1'b1;
						ra0 <= {jh, seg, wd};
					end else begin
						cmd <= CMD_WRITE;
						dq_out <= je ? lb_q1 : lb_q0;
						dq_t <= 16'h0000;
					end
				end
				if (cc == 7'd81) begin
					wt <= 4'd4;
					st <= S_WAIT;
					if (!job_rd && ln == 8'd199) begin
						// the frame is complete
						fc[{g, 1'b0} +: 2] <= g_w;
						fw[{g, 1'b0} +: 2] <= 2'd3 - g_w - g_d;
					end
				end
			end

			default: begin   // S_WAIT
				cc <= 7'd0;
				if (wt != 4'd0)
					wt <= wt - 1'd1;
				else if (job_rd && seg != 2'd3) begin
					seg <= seg + 1'd1;
					g <= g + 1'd1;
					st <= S_LINE;
				end else begin
					job_rd <= 1'b0;
					st <= S_IDLE;
				end
			end
		endcase
	end

end

endmodule
