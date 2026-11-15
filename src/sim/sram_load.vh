// sram_load.vh: the load of the SRAM by the CPUs (c_req of sram_arb), included in a testbench with clk_bus, c_req, hc,
// vc, int_n: per frame (the falling int_n) the accesses per clock in all, in the paper window (vc < 192, hc < 256) and
// the most in any 64 clocks (a ring of the last 64 c_req)
integer ld_all = 0, ld_cl = 0, ld_pap = 0, ld_pcl = 0, ld_max = 0, ld_win = 0;
reg [63:0] ld_ring = 64'd0;
reg ld_int = 1'b1;
always @(posedge clk_bus) begin
	ld_ring <= {ld_ring[62:0], c_req};
	ld_win = ld_win + c_req - ld_ring[63];
	if (ld_win > ld_max) ld_max = ld_win;
	ld_all = ld_all + c_req;
	ld_cl = ld_cl + 1;
	if (vc < 9'd192 && hc < 9'd256) begin
		ld_pap = ld_pap + c_req;
		ld_pcl = ld_pcl + 1;
	end
	ld_int <= int_n;
	if (!int_n && ld_int) begin
		$display("SRAM load: %0d.%0d %% of clocks, paper window %0d.%0d %%, most in 64 clocks %0d",
			ld_all * 100 / ld_cl, (ld_all * 1000 / ld_cl) % 10, ld_pap * 100 / (ld_pcl + 1), (ld_pap * 1000 / (ld_pcl + 1)) % 10, ld_max);
		ld_all = 0; ld_cl = 0; ld_pap = 0; ld_pcl = 0; ld_max = 0;
	end
end
