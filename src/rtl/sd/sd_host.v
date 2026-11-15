`timescale 1ns / 1ps
`default_nettype none

/*
 sd_host.v

 The image of the SD cards of all sixteen machines (sd_oct of the two engines) on slot 0 of the file mounter of
 kg_mcu2 (img_sdc side: sdc_*): one request at a time, the machines in turn (round robin over the pending ones).

 A sector cache of 32 sectors (16 KB of block RAM), direct mapped, write through: the machines boot the same image
 and read the same sectors (the boot sector, the FAT, the directories, ESXDOS's files); a sector of the MCU takes
 5-40 ms, one from the cache 512 clocks (18 us). The line of a sector is lba[4:0] ^ lba[9:5] ^ lba[14:10] (as
 kg_sd_emu: FAT structures sit at sectors 32 * 2^n apart). A read: a hit is copied from the cache into the buffer of
 the machine; a miss goes to the MCU, its bytes into the buffer and the line (valid at the end, not after an
 error). A write: the sector goes from the buffer of the machine to the MCU (sdc_byte_out_data three clocks after
 sdc_byte_addr: OUT_LATENCY 3 of kg_mcu2), its line (if it holds that sector) is invalid. A new image empties the
 cache (a request out then does not fill its line).
*/

module sd_host (
	input wire clk,

	// the engines (sd_oct): engine e machine m = index e * 8 + m
	input wire [15:0] pend,
	input wire [15:0] wr,
	output reg [2:0] h_m = 3'd0,          // the machine of the request in both engines (the engine: h_e)
	input wire [63:0] lba,               // h_lba of each engine
	output wire [1:0] done,
	output wire [1:0] we,
	output wire [8:0] a,
	output wire [7:0] d,
	input wire [15:0] q,                 // h_q of each engine (one clock after a)

	// the file mounter, slot 0
	input wire img_mounted,
	input wire [63:0] img_size,
	output reg sdc_rd = 1'b0,
	output reg sdc_wr = 1'b0,
	output reg [31:0] sdc_sector = 32'd0,
	input wire sdc_busy,
	input wire sdc_done,
	input wire sdc_error,
	input wire sdc_byte_in_strobe,
	input wire [8:0] sdc_byte_addr,
	input wire [7:0] sdc_byte_in_data,
	output reg [7:0] sdc_byte_out_data = 8'd0,

	output wire [21:0] c_size,           // of the CSD
	output wire active                   // a request (debug)
);

localparam H_IDLE = 3'd0, H_LBA = 3'd1, H_LOOK = 3'd2, H_MCU = 3'd3, H_COPY = 3'd4, H_DONE = 3'd5;
reg [2:0] state = H_IDLE;
reg h_e = 1'b0;
reg [3:0] rr = 4'd0;                 // the next machine to look at
reg rwr = 1'b0;
reg [31:0] rlba = 32'd0;
reg [4:0] line = 5'd0;
reg inval = 1'b0;                    // a new image while the request was out
reg [9:0] ci = 10'd0;                // the copy from the cache
assign active = state != H_IDLE;

// the size of the image (more than 4 GB: as 4 GB)
reg [31:0] size = 32'd0;
always @(posedge clk)
	if (img_mounted)
		size <= |img_size[63:32] ? 32'hFFFFFE00 : img_size[31:0];
assign c_size = size[31:19] == 13'd0 ? 22'd0 : {9'd0, size[31:19]} - 22'd1;

// the cache: data, tags (distributed RAM), valid bits
reg [31:0] tag [0:31];
reg [31:0] valid = 32'd0;
integer i;
initial for (i = 0; i < 32; i = i + 1) tag[i] = 32'd0;
wire [31:0] lba_e = h_e ? lba[63:32] : lba[31:0];
wire [4:0] line_of = lba_e[4:0] ^ lba_e[9:5] ^ lba_e[14:10];
reg c_we = 1'b0;
reg [13:0] c_a = 14'd0;
reg [7:0] c_d = 8'd0;
wire [7:0] c_q;
kg_spram #(.DW(8), .AW(14)) cache (
	.clk(clk), .en(1'b1), .we(c_we), .addr(c_a), .din(c_d), .dout(c_q)
);

// the buffer of the machine: the bytes of a read (from the MCU or the cache); for a write sdc_byte_addr reads it
reg b_we = 1'b0;
reg [8:0] b_a = 9'd0;
reg [7:0] b_d = 8'd0;
assign we = {b_we & h_e, b_we & ~h_e};
assign a = b_we ? b_a : sdc_byte_addr;
assign d = b_d;
// (from the state, not a register: the toggle of the card is then seen by H_IDLE, which would take the machine again)
wire done_r = state == H_DONE;
assign done = {done_r & h_e, done_r & ~h_e};

wire [15:0] pend_rot = (pend >> rr) | (pend << (5'd16 - rr));
reg [3:0] first;
integer k;
always @* begin
	first = 4'd0;
	for (k = 15; k >= 0; k = k - 1)
		if (pend_rot[k])
			first = k;
end

always @(posedge clk) begin
	c_we <= 1'b0;
	b_we <= 1'b0;
	sdc_byte_out_data <= h_e ? q[15:8] : q[7:0];
	if (img_mounted) begin
		valid <= 32'd0;
		if (state != H_IDLE)
			inval <= 1'b1;
	end
	case (state)
		H_IDLE:
			if (pend != 16'd0) begin
				{h_e, h_m} <= rr + first;
				rr <= rr + first + 4'd1;
				state <= H_LBA;
			end
		H_LBA: begin
			// h_m is out a clock: its lba
			rlba <= lba_e;
			line <= line_of;
			rwr <= wr[{h_e, h_m}];
			inval <= 1'b0;
			state <= H_LOOK;
		end
		H_LOOK: begin
			sdc_sector <= rlba;
			if (rwr) begin
				if (tag[line] == rlba)
					valid[line] <= 1'b0;
				sdc_wr <= 1'b1;
				state <= H_MCU;
			end else if (valid[line] && tag[line] == rlba) begin
				ci <= 10'd0;
				state <= H_COPY;
			end else begin
				valid[line] <= 1'b0;
				sdc_rd <= 1'b1;
				state <= H_MCU;
			end
		end
		H_MCU: begin
			if (sdc_busy) begin
				sdc_rd <= 1'b0;
				sdc_wr <= 1'b0;
			end
			if (sdc_byte_in_strobe && !rwr) begin
				b_we <= 1'b1;
				b_a <= sdc_byte_addr;
				b_d <= sdc_byte_in_data;
				c_we <= 1'b1;
				c_a <= {line, sdc_byte_addr};
				c_d <= sdc_byte_in_data;
			end
			if (sdc_done && !sdc_rd && !sdc_wr) begin
				if (!rwr && !sdc_error && !inval && !img_mounted) begin
					tag[line] <= rlba;
					valid[line] <= 1'b1;
				end
				state <= H_DONE;
			end
		end
		H_COPY: begin
			// the cache read of byte ci, its byte a clock later into the buffer
			c_a <= {line, ci[8:0]};
			ci <= ci + 10'd1;
			if (ci >= 10'd2) begin
				b_we <= 1'b1;
				b_a <= ci[8:0] - 9'd2;
				b_d <= c_q;
			end
			if (ci == 10'd513)
				state <= H_DONE;
		end
		H_DONE: begin
			// the last byte goes into the buffer now: the request of the machine is done
			state <= H_IDLE;
		end
		default: state <= H_IDLE;
	endcase
end

endmodule
