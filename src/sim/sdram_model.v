`timescale 1ns / 1ps

/*
 sdram_model.v

 A behavioural SDR SDRAM (4 banks x 8192 rows x 512 columns x 16 bits) for the simulation of sdram_ctrl:
 burst length 1, CAS latency from the mode register (2 or 3), READ / WRITE with or without auto precharge.
 It checks the commands against the timing of a -7 part at the clock it gets (errors counted in `errors`):
 tRCD, tRC / tRAS, tRP, tRRD, tRFC, ACTIVE to an open bank, READ / WRITE to a closed bank, REFRESH with an open
 bank, the mode register before use.

 Only rows 0..ROWS-1 are stored (the simulation uses the low rows of a bank); the word index is
 {bank, row, column}. Read data is driven tAC after the clock edge before the CAS latency edge and held tOH after it.
*/

module sdram_model #(
	parameter ROWS = 256,
	parameter RB = 8,              // log2(ROWS)
	parameter real T_AC = 5.4,
	parameter real T_OH = 2.7,
	parameter real T_RCD = 20.0,
	parameter real T_RP = 20.0,
	parameter real T_RC = 66.0,
	parameter real T_RAS = 44.0,
	parameter real T_RRD = 15.0,
	parameter real T_RFC = 66.0,
	parameter real T_WR = 15.0
) (
	input wire clk,
	input wire [1:0] ba,
	input wire [12:0] a,
	input wire [1:0] dqm,
	input wire ras_n,
	input wire cas_n,
	input wire we_n,
	inout wire [15:0] dq
);


reg [15:0] mem [0:4*ROWS*512-1];

integer errors = 0;
integer reads = 0, writes = 0, refreshes = 0;

reg [2:0] cl = 3'd0;
reg mode_set = 1'b0;

reg open_ [0:3];
reg [12:0] row_ [0:3];
real t_act [0:3];
real t_pre [0:3];       // the end of the precharge (ready for ACTIVE)
real t_last_act;
real t_rfsh_end;

reg [15:0] dq_out;
reg dq_oe = 1'b0;
assign dq = dq_oe ? dq_out : 16'bz;

integer i;
initial begin
	for (i = 0; i < 4; i = i + 1) begin
		open_[i] = 1'b0;
		row_[i] = 13'd0;
		t_act[i] = -1000.0;
		t_pre[i] = -1000.0;
	end
	t_last_act = -1000.0;
	t_rfsh_end = -1000.0;
	for (i = 0; i < 4*ROWS*512; i = i + 1)
		mem[i] = 16'h0000;
end

task err;
	input [8*64-1:0] msg;
	begin
		errors = errors + 1;
		if (errors < 20)
			$display("%t sdram_model: %0s", $time, msg);
	end
endtask

function integer idx;
	input [1:0] b;
	input [12:0] r;
	input [8:0] c;
	begin
		if (r >= ROWS) begin
			$display("%t sdram_model: row %0d beyond the model", $time, r);
			idx = 0;
		end else
			idx = {b, r[RB-1:0], c};
	end
endfunction

// read pipeline: the word of a READ goes out after the edge CL-1 edges later
reg [15:0] rd_word [0:3];
reg rd_valid [0:3];
integer p;
initial for (p = 0; p < 4; p = p + 1) rd_valid[p] = 1'b0;

real now;
reg [2:0] cmd;
integer w;

always @(posedge clk) begin
	now = $realtime;
	cmd = {ras_n, cas_n, we_n};

	// data out: the pipeline moves one step, a word at its end goes out tAC after this edge (the edge CL - 1
	// after its READ, so it is valid at the CL edge); without one the word before stays tOH
	for (p = 0; p < 3; p = p + 1) begin
		rd_valid[p] = rd_valid[p + 1];
		rd_word[p] = rd_word[p + 1];
	end
	rd_valid[3] = 1'b0;
	if (rd_valid[0]) begin
		dq_out <= #(T_AC) rd_word[0];
		dq_oe <= #(T_AC) 1'b1;
	end else if (dq_oe)
		dq_oe <= #(T_OH) 1'b0;

	case (cmd)
		3'b011: begin   // ACTIVE
			if (!mode_set) err("ACTIVE before the mode register");
			if (open_[ba]) err("ACTIVE to an open bank");
			if (now < t_pre[ba] - 0.01) err("ACTIVE before the end of tRP / tWR");
			if (now - t_act[ba] < T_RC - 0.01) err("tRC");
			if (now - t_last_act < T_RRD - 0.01) err("tRRD");
			if (now < t_rfsh_end - 0.01) err("ACTIVE in tRFC");
			open_[ba] = 1'b1;
			row_[ba] = a;
			t_act[ba] = now;
			t_last_act = now;
		end
		3'b101, 3'b100: begin   // READ, WRITE
			if (!open_[ba]) err("READ / WRITE to a closed bank");
			if (now - t_act[ba] < T_RCD - 0.01) err("tRCD");
			w = idx(ba, row_[ba], a[8:0]);
			if (cmd == 3'b101) begin
				reads = reads + 1;
				rd_word[cl - 1] = mem[w];
				rd_valid[cl - 1] = 1'b1;
			end else begin
				writes = writes + 1;
				if (!dqm[0]) mem[w][7:0] = dq[7:0];
				if (!dqm[1]) mem[w][15:8] = dq[15:8];
			end
			if (a[10]) begin   // auto precharge: after tRAS (and tWR for a write), then tRP
				open_[ba] = 1'b0;
				t_pre[ba] = ((t_act[ba] + T_RAS > now + (cmd == 3'b100 ? T_WR : 0.0)) ?
					t_act[ba] + T_RAS : now + (cmd == 3'b100 ? T_WR : 0.0)) + T_RP;
			end
		end
		3'b010: begin   // PRECHARGE
			if (a[10]) begin
				for (p = 0; p < 4; p = p + 1) begin
					open_[p] = 1'b0;
					t_pre[p] = now + T_RP;
				end
			end else begin
				open_[ba] = 1'b0;
				t_pre[ba] = now + T_RP;
			end
		end
		3'b001: begin   // AUTO REFRESH
			refreshes = refreshes + 1;
			for (p = 0; p < 4; p = p + 1) begin
				if (open_[p]) err("REFRESH with an open bank");
				if (now < t_pre[p] - 0.01) err("REFRESH before the end of a precharge");
			end
			if (now < t_rfsh_end - 0.01) err("REFRESH in tRFC");
			t_rfsh_end = now + T_RFC;
		end
		3'b000: begin   // LOAD MODE
			cl = a[6:4];
			mode_set = 1'b1;
			if (a[2:0] != 3'b000) err("burst length is not 1");
		end
		default: ;
	endcase
end

endmodule
