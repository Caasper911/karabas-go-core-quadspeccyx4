`timescale 1ns / 1ps
`default_nettype none

/*
 sd_oct.v

 The SD cards of the eight machines of an engine (zx_oct): the state machine of kg_sd_emu.v of QuadSpeccy (after
 nextor_sd.v of karabas-go-core-msx, Andy Karpov, GPL-3.0) for each machine, its state in contexts (distributed RAM
 indexed by the machine) as the machines of zx_oct, on the image of the file mounter through sd_host.v (one image
 for all sixteen machines).

 An SDHC card (block addresses, OCR with CCS) of the size of the image: CMD0/1/8/9/10/12/16/17/18/24/25/55/58 and
 ACMD41, the response after one FF byte (Ncr = 2, as kg_sd_emu), FF until the data token FE of a read, 05 then busy
 (00) after a write.

 An exchange is a byte of #EB in the bus slot of machine b (zx_oct): xfer with the byte of the CPU (tx; FF for a
 read) and the card select; the card gives the byte of its state before the byte (out), then takes tx. The byte it
 gave is the next read of #EB (q: c_q of machine b, written a clock after the exchange, when a byte of the sector
 buffer is there). The exchanges of a machine are 4 T-states (32 clocks) apart at least.

 The sector buffer: 512 bytes per machine (4 KB, a RAMB16 pair per engine): port A the card (its byte in the bus
 slot), port B sd_host (h_*: machine h_m, the bytes of a read sector in, of a written one out). A read or a write
 of the image is a request: the card wants it (want), then makes it when the one before is done (rq_t / dn_t
 toggles: pending while they differ); sd_host toggles dn_t at the end. A request nobody waits for any more (CMD12,
 a deselect, a reset) is not live: its bytes do not go into the buffer (h_we), a new request waits for its end.
 busy: the card of machine b waits for its request (RD_WAIT, WR_BUSY): zx_oct holds the CPU in an I/O read of #EB
 meanwhile (WAIT), the driver would give up after a few thousand tries, a sector of the MCU takes 5-40 ms.
*/

module sd_oct (
	input wire clk,
	input wire [2:0] b,                 // the machine of the bus logic of this clock
	input wire rst,                     // a reset of machine b: the card is idle
	input wire clr,                     // all cleared (power on, DivMMC off): machine b in this clock
	input wire xfer,                    // an exchange of machine b
	input wire [7:0] tx,
	input wire cs_n,                    // its card select (#E7 bit 0)
	output wire [7:0] q,                // the byte of the last exchange of machine b
	output wire busy,                   // the card of machine b waits for the image
	input wire [21:0] c_size,           // C_SIZE of the CSD: (the size of the image / 512 KB) - 1

	// sd_host
	output wire [7:0] h_pend,           // machine m: a request is out
	output wire [7:0] h_wr,             // its kind: 1 write
	input wire [2:0] h_m,
	output wire [31:0] h_lba,           // the sector of the request of h_m
	input wire h_done,                  // the request of h_m is done
	input wire h_we,                    // its buffer (written only while its request is live)
	input wire [8:0] h_a,
	input wire [7:0] h_d,
	output wire [7:0] h_q               // one clock after h_a
);

localparam S_IDLE = 4'd0, S_CMD = 4'd1, S_RESP = 4'd2, S_RD_WAIT = 4'd3, S_RD_DATA = 4'd4,
	S_RD_CRC = 4'd5, S_WR_TOKEN = 4'd6, S_WR_DATA = 4'd7, S_WR_CRC = 4'd8, S_WR_RESP = 4'd9,
	S_WR_BUSY = 4'd10, S_NCR = 4'd11;

// ---------------------------------------------------------------------------------------------
// contexts (index = machine), written in the bus slot of the machine, one write of each a clock

integer i;
reg [3:0] c_st [0:7];
reg [5:0] c_cmd [0:7];
reg [31:0] c_arg [0:7];
reg [2:0] c_cnt [0:7];               // the bytes of a command
reg [4:0] c_ridx [0:7];              // the byte of a response
reg c_idle [0:7];                    // the idle bit of R1 (until ACMD41 / CMD1)
reg c_app [0:7];                     // CMD55 before: an ACMD
reg c_acmd [0:7];                    // the command is an ACMD
reg c_multi [0:7];                   // CMD18 / CMD25
reg c_crc1 [0:7];                    // the first CRC byte of a block was there
reg c_want [0:7];                    // a request to make when the one before is done
reg c_wwr [0:7];                     // its kind: 1 write
reg [8:0] c_ba [0:7];                // the byte of the buffer (read: the next one out, write: the next one in)
reg [31:0] c_lba [0:7];
reg [7:0] c_q [0:7];                 // the byte of the last exchange (written a clock after it)
initial begin
	for (i = 0; i < 8; i = i + 1) begin
		c_st[i] = S_IDLE; c_cmd[i] = 6'd0; c_arg[i] = 32'd0; c_cnt[i] = 3'd0; c_ridx[i] = 5'd0; c_idle[i] = 1'b1;
		c_app[i] = 1'b0; c_acmd[i] = 1'b0; c_multi[i] = 1'b0; c_crc1[i] = 1'b0; c_want[i] = 1'b0; c_wwr[i] = 1'b0;
		c_ba[i] = 9'd0; c_lba[i] = 32'd0; c_q[i] = 8'hFF;
	end
end

// the requests (flip-flops: written by the card in the bus slot and by sd_host)
reg [7:0] rq_t = 8'd0, dn_t = 8'd0, wr_v = 8'd0, live = 8'd0;
assign h_pend = rq_t ^ dn_t;
assign h_wr = wr_v;
assign h_lba = c_lba[h_m];

wire [3:0] st = c_st[b];
wire [5:0] cmd = c_cmd[b];
wire [31:0] arg = c_arg[b];
wire [4:0] ridx = c_ridx[b];
wire acmd = c_acmd[b];
wire ready = !c_want[b] && rq_t[b] == dn_t[b];     // the request is done (the sector is in the buffer / written)
assign busy = (st == S_RD_WAIT || st == S_WR_BUSY) && !ready;
assign q = c_q[b];

// ---------------------------------------------------------------------------------------------
// the byte the card gives (kg_sd_emu)

wire cmd_bad = !(cmd == 6'd0 || cmd == 6'd1 || cmd == 6'd8 || cmd == 6'd9 || cmd == 6'd10 || cmd == 6'd12 ||
	cmd == 6'd16 || cmd == 6'd17 || cmd == 6'd18 || cmd == 6'd24 || cmd == 6'd25 || cmd == 6'd55 || cmd == 6'd58);
wire [7:0] r1 = {5'd0, (acmd ? 1'b0 : cmd_bad), 1'b0, c_idle[b]};

reg [7:0] resp;
reg [4:0] resp_len;                  // the bytes of the response, R1 included
always @* begin
	resp = 8'hFF;
	resp_len = 5'd1;
	if (!acmd) case (cmd)
		6'd8: begin
			resp_len = 5'd5;
			case (ridx)
				5'd3: resp = {4'd0, arg[11:8]};
				5'd4: resp = arg[7:0];
				default: resp = 8'h00;
			endcase
		end
		6'd58: begin
			resp_len = 5'd5;
			case (ridx)
				5'd1: resp = 8'hC0;       // powered up, CCS (SDHC)
				5'd2: resp = 8'hFF;
				5'd3: resp = 8'h80;
				default: resp = 8'h00;
			endcase
		end
		6'd9: begin
			resp_len = 5'd20;
			case (ridx)
				5'd1: resp = 8'hFE;
				5'd2: resp = 8'h40;       // CSD version 2
				5'd3: resp = 8'h0E;
				5'd4: resp = 8'h00;
				5'd5: resp = 8'h32;
				5'd6: resp = 8'h5B;
				5'd7: resp = 8'h59;       // READ_BL_LEN 9
				5'd8: resp = 8'h00;
				5'd9: resp = {2'd0, c_size[21:16]};
				5'd10: resp = c_size[15:8];
				5'd11: resp = c_size[7:0];
				5'd12: resp = 8'h7F;
				5'd13: resp = 8'h80;
				5'd14: resp = 8'h0A;
				5'd15: resp = 8'h40;      // WRITE_BL_LEN 9
				5'd16: resp = 8'h00;
				5'd17: resp = 8'h01;
				default: resp = 8'hFF;
			endcase
		end
		6'd10: begin
			resp_len = 5'd20;
			case (ridx)
				5'd1: resp = 8'hFE;
				5'd2: resp = 8'h00;       // MID
				5'd3: resp = "K";         // OID
				5'd4: resp = "G";
				5'd5: resp = "S";         // PNM
				5'd6: resp = "W";
				5'd7: resp = "A";
				5'd8: resp = "L";
				5'd9: resp = "L";
				5'd10: resp = 8'h10;      // PRV 1.0
				5'd15: resp = 8'h01;      // MDT
				5'd16: resp = 8'h6A;
				5'd17: resp = 8'h01;
				5'd18, 5'd19: resp = 8'hFF;
				default: resp = 8'h00;
			endcase
		end
		default: ;
	endcase
end

reg [7:0] out;
always @* begin
	case (st)
		S_RESP: out = ridx == 5'd0 ? r1 : resp;
		S_RD_WAIT: out = ready ? 8'hFE : 8'hFF;
		S_WR_RESP: out = 8'h05;
		S_WR_BUSY: out = ready ? 8'hFF : 8'h00;
		default: out = 8'hFF;
	endcase
end
wire from_buf = st == S_RD_DATA;     // the byte of the buffer (port A, a clock later)

// ---------------------------------------------------------------------------------------------
// the next state of the card of machine b

wire is_cmd = tx[7:6] == 2'b01;
reg [3:0] n_st;
reg [5:0] n_cmd;
reg [31:0] n_arg, n_lba;
reg [2:0] n_cnt;
reg [4:0] n_ridx;
reg n_idle, n_app, n_acmd, n_multi, n_crc1, n_want, n_wwr, n_issue, n_drop, n_bwe;
reg [8:0] n_ba;
always @* begin
	n_st = st;
	n_cmd = cmd;
	n_arg = arg;
	n_lba = c_lba[b];
	n_cnt = c_cnt[b];
	n_ridx = ridx;
	n_idle = c_idle[b];
	n_app = c_app[b];
	n_acmd = acmd;
	n_multi = c_multi[b];
	n_crc1 = c_crc1[b];
	n_want = c_want[b];
	n_wwr = c_wwr[b];
	n_ba = c_ba[b];
	n_issue = 1'b0;                  // the request goes out now
	n_drop = 1'b0;                   // nobody waits for the request out any more
	n_bwe = 1'b0;                    // tx into the buffer
	// the request: when the one before is done
	if (c_want[b] && rq_t[b] == dn_t[b]) begin
		n_issue = 1'b1;
		n_want = 1'b0;
	end
	if (rst || clr) begin
		n_st = S_IDLE;
		n_idle = 1'b1;
		n_app = 1'b0;
		n_want = 1'b0;
		n_drop = 1'b1;
		n_issue = 1'b0;
	end else if (xfer) begin
		if (cs_n) begin
			// deselected: the card drops what it was doing
			n_st = S_IDLE;
			n_want = 1'b0;
			n_drop = 1'b1;
			n_issue = 1'b0;
		end else case (st)
			S_IDLE, S_RD_WAIT: begin
				if (st == S_RD_WAIT && ready && !is_cmd) begin
					// the token went out in this exchange: the data from byte 0
					n_st = S_RD_DATA;
				end else if (is_cmd) begin
					if (st == S_RD_WAIT) begin
						// CMD12 in a multiple block read: the block on its way is not wanted
						n_want = 1'b0;
						n_drop = 1'b1;
						n_issue = 1'b0;
					end
					n_cmd = tx[5:0];
					n_acmd = c_app[b];
					n_app = 1'b0;
					n_cnt = 3'd1;
					n_st = S_CMD;
				end
			end
			S_CMD: begin
				if (c_cnt[b] <= 3'd4)
					n_arg = {arg[23:0], tx};
				if (c_cnt[b] == 3'd5) begin
					// the CRC: the command is complete; the response after one FF byte (Ncr = 2)
					n_ridx = 5'd0;
					n_st = S_NCR;
					if (!acmd) case (cmd)
						6'd0: n_idle = 1'b1;
						6'd1: n_idle = 1'b0;
						6'd55: n_app = 1'b1;
						default: ;
					endcase
					else if (cmd == 6'd41)
						n_idle = 1'b0;
				end
				n_cnt = c_cnt[b] + 3'd1;
			end
			S_NCR: n_st = S_RESP;
			S_RESP: begin
				if (ridx == resp_len - 5'd1) begin
					n_st = S_IDLE;
					if (!acmd && (cmd == 6'd17 || cmd == 6'd18)) begin
						n_lba = arg;
						n_multi = cmd == 6'd18;
						n_want = 1'b1;
						n_wwr = 1'b0;
						n_ba = 9'd0;
						n_st = S_RD_WAIT;
					end
					if (!acmd && (cmd == 6'd24 || cmd == 6'd25)) begin
						n_lba = arg;
						n_multi = cmd == 6'd25;
						n_st = S_WR_TOKEN;
					end
				end
				n_ridx = ridx + 5'd1;
			end
			S_RD_DATA: begin
				n_ba = c_ba[b] + 9'd1;
				if (c_ba[b] == 9'd511) begin
					n_crc1 = 1'b0;
					n_st = S_RD_CRC;
				end
			end
			S_RD_CRC: begin
				n_crc1 = 1'b1;
				if (c_crc1[b]) begin
					if (c_multi[b]) begin
						n_lba = c_lba[b] + 32'd1;
						n_want = 1'b1;
						n_wwr = 1'b0;
						n_ba = 9'd0;
						n_st = S_RD_WAIT;
					end else
						n_st = S_IDLE;
				end
			end
			S_WR_TOKEN: begin
				if (tx == 8'hFE || (c_multi[b] && tx == 8'hFC)) begin
					n_ba = 9'd0;
					n_st = S_WR_DATA;
				end else if (c_multi[b] && tx == 8'hFD)
					n_st = S_IDLE;
				else if (is_cmd) begin
					n_cmd = tx[5:0];
					n_acmd = c_app[b];
					n_app = 1'b0;
					n_cnt = 3'd1;
					n_st = S_CMD;
				end
			end
			S_WR_DATA: begin
				n_bwe = 1'b1;
				n_ba = c_ba[b] + 9'd1;
				if (c_ba[b] == 9'd511) begin
					n_crc1 = 1'b0;
					n_st = S_WR_CRC;
				end
			end
			S_WR_CRC: begin
				n_crc1 = 1'b1;
				if (c_crc1[b]) begin
					n_want = 1'b1;
					n_wwr = 1'b1;
					n_st = S_WR_RESP;
				end
			end
			S_WR_RESP: n_st = S_WR_BUSY;
			S_WR_BUSY: begin
				if (ready) begin
					n_lba = c_lba[b] + 32'd1;
					n_st = c_multi[b] ? S_WR_TOKEN : S_IDLE;
				end
			end
			default: n_st = S_IDLE;
		endcase
	end
end

// the sector buffers: port A {b, c_ba} the card, port B {h_m, h_a} sd_host
wire [7:0] buf_qa;
kg_tdpram #(.DW(8), .AW(12)) sbuf (
	.clka(clk), .ena(1'b1), .wea(n_bwe), .addra({b, c_ba[b]}), .dina(tx), .douta(buf_qa),
	.clkb(clk), .enb(1'b1), .web(h_we & live[h_m]), .addrb({h_m, h_a}), .dinb(h_d), .doutb(h_q)
);

// the byte of the exchange into c_q a clock later (from the buffer: its port A then)
reg q_we = 1'b0, q_buf = 1'b0;
reg [2:0] q_m = 3'd0;
reg [7:0] q_v = 8'hFF;

always @(posedge clk) begin
	c_st[b] <= n_st;
	c_cmd[b] <= n_cmd;
	c_arg[b] <= n_arg;
	c_lba[b] <= n_lba;
	c_cnt[b] <= n_cnt;
	c_ridx[b] <= n_ridx;
	c_idle[b] <= n_idle;
	c_app[b] <= n_app;
	c_acmd[b] <= n_acmd;
	c_multi[b] <= n_multi;
	c_crc1[b] <= n_crc1;
	c_want[b] <= n_want;
	c_wwr[b] <= n_wwr;
	c_ba[b] <= n_ba;

	q_we <= (xfer && !rst) || clr;
	q_buf <= from_buf && !clr;
	q_m <= b;
	q_v <= clr ? 8'hFF : out;
	if (q_we)
		c_q[q_m] <= q_buf ? buf_qa : q_v;

	// the requests
	if (n_issue) begin
		rq_t[b] <= ~rq_t[b];
		wr_v[b] <= c_wwr[b];
	end
	if (n_issue || n_drop)
		live[b] <= n_issue;
	if (h_done)
		dn_t[h_m] <= ~dn_t[h_m];
end

endmodule
