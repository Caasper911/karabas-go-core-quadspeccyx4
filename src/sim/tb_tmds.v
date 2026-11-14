`timescale 1ns / 1ps
`default_nettype none

/*
 tb_tmds.v

 tmds_oserdes.v (PLL x 10, BUFPLL, OSERDES2) with the unisim models: random 10-bit words on the three data lanes, the
 clock word 1111100000 on lane 3; the lanes are read back in the middle of each bit (falling ioclk), cut into words
 where the clock lane shows its word, and each word compared with the words given (one latency for all, found at the
 first word). Prints "tb_tmds: <n> errors".
*/

module tb_tmds;

reg pclk = 1'b0;
always #6.7955 pclk = ~pclk;
reg reset = 1'b1;
initial #200 reset = 1'b0;

reg [9:0] d0 = 10'd0, d1 = 10'd0, d2 = 10'd0;
reg [29:0] hist [0:1023];
integer pix = 0, seed = 7;
always @(posedge pclk) begin
	d0 <= $random(seed);
	d1 <= $random(seed);
	d2 <= $random(seed);
	pix = pix + 1;
end
always @(negedge pclk)
	hist[pix & 1023] = {d2, d1, d0};

wire [3:0] tp, tn;
tmds_oserdes dut (
	.pclk(pclk), .reset(reset), .d0(d0), .d1(d1), .d2(d2), .dc(10'b1111100000), .tmds_p(tp), .tmds_n(tn)
);

reg [9:0] s0 = 0, s1 = 0, s2 = 0, sc = 0;
integer nb = 0, lat = -1, words = 0, errors = 0, k;
reg found;
always @(negedge dut.ioclk) begin
	s0 = {tp[0], s0[9:1]};
	s1 = {tp[1], s1[9:1]};
	s2 = {tp[2], s2[9:1]};
	sc = {tp[3], sc[9:1]};
	nb = nb + 1;
	if (sc === 10'b1111100000 && pix > 100) begin
		if (lat < 0) begin
			found = 1'b0;
			for (k = 1; k < 30; k = k + 1)
				if (!found && hist[(pix - k) & 1023] === {s2, s1, s0}) begin
					lat = k;
					found = 1'b1;
				end
			if (lat < 0) begin
				errors = errors + 1;
				if (errors < 5) $display("word %h %h %h: not among the words given", s2, s1, s0);
			end else
				$display("latency %0d pixels", lat);
		end else begin
			words = words + 1;
			if (hist[(pix - lat) & 1023] !== {s2, s1, s0}) begin
				errors = errors + 1;
				if (errors < 10) $display("word %0d: %h %h %h, given %h", words, s2, s1, s0, hist[(pix - lat) & 1023]);
			end
		end
	end
end

initial begin
	#60000;
	if (words < 1000) begin
		errors = errors + 1;
		$display("only %0d words", words);
	end
	$display("tb_tmds: %0d words, %0d errors", words, errors);
	$finish;
end

endmodule
