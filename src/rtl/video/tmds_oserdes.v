`timescale 1ns / 1ps
`default_nettype none

/*
 tmds_oserdes.v

 The TMDS serializers of HDMI for a pixel clock of 73.6 MHz (736 Mbit/s a lane), the way of Xilinx XAPP495: a PLL on
 the pixel clock (x 10, VCO 736 MHz) gives the bit clock (CLKOUT0 / 1 into a BUFPLL: ioclk and the serdes strobe) and
 the clock of two pixels a word (CLKOUT1 / 5: pclkx2, 147 MHz, BUFG); per lane two OSERDES2 (master and slave,
 cascaded: 5 bits a pclkx2 clock, SDR) and an OBUFDS. The fabric serializer of the modules (zhdmi_tmds_serializer,
 5x the pixel clock in LUTs) does not meet 368 MHz.

 The 10-bit words (hdmi_enc.vhd, on pclk, bit 0 first) go into pclkx2 as two halves: a toggle of pclk is seen changed
 in the pclkx2 clock in the middle of a pixel (the edge at the start of the pixel still sees the old value): then the
 low half (bits 4..0) is taken, at the next edge (the start of the next pixel, the word still the old one) the high
 half. Both clocks come from the PLL (the pclkx2 edges are those of pclk and the middles), so the paths are timed.

 Lane 3 is the clock (the word 1111100000).
*/

module tmds_oserdes (
	input wire pclk,
	input wire reset,

	input wire [9:0] d0,
	input wire [9:0] d1,
	input wire [9:0] d2,
	input wire [9:0] dc,

	output wire [3:0] tmds_p,
	output wire [3:0] tmds_n
);

// the clocks
wire [5:0] pll_o;
wire pll_locked, bufpll_lock, ioclk, strobe, pclkx2;
kg_pll #(
	.CLKIN_PERIOD(13.591),
	.DIVCLK_DIVIDE(1), .CLKFBOUT_MULT(10),
	.CLKOUT0_DIVIDE(1), .CLKOUT1_DIVIDE(5), .CLKOUT2_DIVIDE(10),
	.CLKOUT3_DIVIDE(10), .CLKOUT4_DIVIDE(10), .CLKOUT5_DIVIDE(10),
	.IBUFG(0),
	.BUFG_MASK(6'b000010)
) pll (
	.clk_in(pclk),
	.rst(reset),
	.clk_out(pll_o),
	.locked(pll_locked)
);
assign pclkx2 = pll_o[1];

BUFPLL #(.DIVIDE(5)) bufpll (
	.PLLIN(pll_o[0]),
	.GCLK(pclkx2),
	.LOCKED(pll_locked),
	.IOCLK(ioclk),
	.SERDESSTROBE(strobe),
	.LOCK(bufpll_lock)
);

// the words into pclkx2: 5 bits a clock, the low half in the middle of the pixel
reg tog = 1'b0;
always @(posedge pclk)
	tog <= ~tog;

reg tog_d = 1'b0;
reg [4:0] h0 = 5'd0, h1 = 5'd0, h2 = 5'd0, hc = 5'd0;
reg [2:0] rst_s = 3'b111;
always @(posedge pclkx2) begin
	tog_d <= tog;
	if (tog != tog_d) begin
		h0 <= d0[4:0]; h1 <= d1[4:0]; h2 <= d2[4:0]; hc <= dc[4:0];
	end else begin
		h0 <= d0[9:5]; h1 <= d1[9:5]; h2 <= d2[9:5]; hc <= dc[9:5];
	end
	rst_s <= {rst_s[1:0], reset | ~bufpll_lock};
end
wire srst = rst_s[2];

// the lanes
wire [19:0] hw = {hc, h2, h1, h0};
genvar i;
generate
	for (i = 0; i < 4; i = i + 1) begin : g_lane
		wire [4:0] w = hw[i*5 +: 5];
		wire oq, c_d, c_t, c_d2, c_t2;
		// the slave takes bits 0..3 (sent first), the master bit 4 (XAPP495 serdes_n_to_1 with SF 5)
		OSERDES2 #(
			.DATA_WIDTH(5), .DATA_RATE_OQ("SDR"), .DATA_RATE_OT("SDR"), .SERDES_MODE("MASTER"),
			.OUTPUT_MODE("DIFFERENTIAL")
		) os_m (
			.OQ(oq), .OCE(1'b1), .CLK0(ioclk), .CLK1(1'b0), .IOCE(strobe), .RST(srst), .CLKDIV(pclkx2),
			.D4(1'b0), .D3(1'b0), .D2(1'b0), .D1(w[4]),
			.TQ(), .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TRAIN(1'b0), .TCE(1'b1),
			.SHIFTIN1(1'b1), .SHIFTIN2(1'b1), .SHIFTIN3(c_d2), .SHIFTIN4(c_t2),
			.SHIFTOUT1(c_d), .SHIFTOUT2(c_t), .SHIFTOUT3(), .SHIFTOUT4()
		);
		OSERDES2 #(
			.DATA_WIDTH(5), .DATA_RATE_OQ("SDR"), .DATA_RATE_OT("SDR"), .SERDES_MODE("SLAVE"),
			.OUTPUT_MODE("DIFFERENTIAL")
		) os_s (
			.OQ(), .OCE(1'b1), .CLK0(ioclk), .CLK1(1'b0), .IOCE(strobe), .RST(srst), .CLKDIV(pclkx2),
			.D4(w[3]), .D3(w[2]), .D2(w[1]), .D1(w[0]),
			.TQ(), .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TRAIN(1'b0), .TCE(1'b1),
			.SHIFTIN1(c_d), .SHIFTIN2(c_t), .SHIFTIN3(1'b1), .SHIFTIN4(1'b1),
			.SHIFTOUT1(), .SHIFTOUT2(), .SHIFTOUT3(c_d2), .SHIFTOUT4(c_t2)
		);
		OBUFDS ob (.I(oq), .O(tmds_p[i]), .OB(tmds_n[i]));
	end
endgenerate

endmodule
