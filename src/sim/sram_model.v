`timescale 1ns / 1ps

/*
 sram_model.v

 A behavioural asynchronous SRAM 2M x 16 (10 ns), /RD and /WR per byte, the chip select tied low, as on the Karabas
 Go / Mini / Mini G. Read: the byte drives DQ while its /RD is low and its /WR high, the data tAA after the address
 (X before), tOE after /RD. Write: the byte is written at the rising edge of its /WR. Checks (errors counted, the
 first ones printed):
   - /WR low at least tWP; the address stable from tAS before /WR goes low to tWR after it goes high (and tAW before
     its end); the data stable tDW before the end of /WR and tDH after it
   - no fight on DQ: the FPGA drives (drv) while a byte of the SRAM drives
   - a read sampled (the testbench calls check_read) while the data is not valid yet (X; not when the word itself is
     X or the address is: xs counts those, random code writes CPU registers that were never set)
 The FPGA side has no delays in the simulation, so these are the margins of the schedule, not of the board.
*/

module sram_model #(
	parameter AW = 21,
	parameter tAA = 10.0, parameter tOE = 4.5, parameter tOH = 2.5, parameter tHZ = 4.0,
	parameter tWP = 8.0, parameter tAS = 0.0, parameter tAW = 8.0, parameter tWR = 0.0,
	parameter tDW = 5.0, parameter tDH = 0.0
) (
	input wire [AW-1:0] A,
	inout wire [15:0] DQ,
	input wire [1:0] RD_N,
	input wire [1:0] WR_N,
	input wire drv                      // the FPGA drives DQ (for the fight check)
);

reg [15:0] mem [0:(1 << AW) - 1];
integer errors = 0;
integer xs = 0;                     // writes of X data / reads at an X address (uninitialized CPU registers): not errors

// the read path: the word of A, X from the change of A until tAA (tOH: the old data stays a little)
reg [15:0] rdata = 16'hxxxx;
always @(A) begin
	#(tOH) rdata = 16'hxxxx;
	#(tAA - tOH) rdata = mem[A];
end
// a write into the word being read shows (as the SRAM: the data follows)
reg [1:0] oe = 2'b00;
genvar l;
generate
	for (l = 0; l < 2; l = l + 1) begin : g_lane
		always @(RD_N[l] or WR_N[l]) begin
			if (!RD_N[l] && WR_N[l])
				#(tOE) oe[l] = !RD_N[l] && WR_N[l];
			else
				#(tHZ) oe[l] = !RD_N[l] && WR_N[l];
		end
		assign DQ[l*8 +: 8] = oe[l] ? rdata[l*8 +: 8] : 8'hzz;
	end
endgenerate

// the times of the last changes
realtime t_a = 0, t_d = 0, t_wf = 0, t_wr = -100;
reg [AW-1:0] a_at_wf;
always @(A) begin
	t_a = $realtime;
	if (WR_N != 2'b11) begin
		errors = errors + 1;
		if (errors < 10) $display("%t sram_model: address changed while /WR low", $time);
	end
	if ($realtime - t_wr < tWR) begin
		errors = errors + 1;
		if (errors < 10) $display("%t sram_model: address changed %0.1f ns after /WR (tWR %0.1f)", $time, $realtime - t_wr, tWR);
	end
end
always @(DQ) begin
	t_d = $realtime;
	if (WR_N == 2'b11 && $realtime - t_wr < tDH) begin
		errors = errors + 1;
		if (errors < 10) $display("%t sram_model: data changed %0.1f ns after /WR (tDH)", $time, $realtime - t_wr);
	end
end

generate
	for (l = 0; l < 2; l = l + 1) begin : g_wr
		always @(negedge WR_N[l]) if ($realtime > 0) begin
			t_wf = $realtime;
			a_at_wf = A;
			if ($realtime - t_a < tAS) begin
				errors = errors + 1;
				if (errors < 10) $display("%t sram_model: /WR %0d low %0.1f ns after the address (tAS)", $time, l, $realtime - t_a);
			end
		end
		always @(posedge WR_N[l]) if ($realtime > 0) begin
			if ($realtime - t_wf < tWP) begin
				errors = errors + 1;
				if (errors < 10) $display("%t sram_model: /WR %0d low %0.1f ns (tWP %0.1f)", $time, l, $realtime - t_wf, tWP);
			end
			if ($realtime - t_a < tAW || A !== a_at_wf) begin
				errors = errors + 1;
				if (errors < 10) $display("%t sram_model: address of /WR %0d not stable (tAW)", $time, l);
			end
			if ($realtime - t_d < tDW) begin
				errors = errors + 1;
				if (errors < 10) $display("%t sram_model: data %0.1f ns before the end of /WR %0d (tDW %0.1f)", $time, $realtime - t_d, l, tDW);
			end
			if (^DQ[l*8 +: 8] === 1'bx)
				xs = xs + 1;
			mem[A][l*8 +: 8] = DQ[l*8 +: 8];
			t_wr = $realtime;
			rdata = mem[A];
		end
	end
endgenerate

// no fight
always @(drv or oe)
	if (drv && oe != 2'b00) begin
		errors = errors + 1;
		if (errors < 10) $display("%t sram_model: the FPGA and the SRAM drive DQ", $time);
	end

// the testbench: the read word sampled now must be valid
task check_read;
	input [1:0] lanes;
	begin
		if (^A === 1'bx)
			xs = xs + 1;
		else if ((lanes[0] && ^DQ[7:0] === 1'bx && ^mem[A][7:0] !== 1'bx) ||
			(lanes[1] && ^DQ[15:8] === 1'bx && ^mem[A][15:8] !== 1'bx)) begin
			errors = errors + 1;
			if (errors < 10) $display("%t sram_model: read sampled while the data is not valid", $time);
		end
	end
endtask

endmodule
