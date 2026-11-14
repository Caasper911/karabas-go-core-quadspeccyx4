`timescale 1ns / 1ps
`default_nettype none

/*
 hdmi_out.v

 HDMI of the Mini / Mini G (from QuadSpeccy): the picture of the core on the pixel clock pclk (73.6 MHz: 1568 x 960,
 visible 1280 x 800, or the 720 x 576 raster; de the visible part, the syncs with the polarity of the raster) with the
 sound.

 hdmi_enc.vhd (the encoders of zhdmi_tx of the modules, INPUT_REG = 1: the picture registered first) gives the 10-bit
 words, tmds_oserdes.v serializes them (PLL x 10, BUFPLL, OSERDES2: 736 Mbit/s a lane). The fabric serializer of the
 modules with a DCM at 5x did not do: 368 MHz is above the 333 MHz of the CLKFX of a -2 part, and its shift
 registers missed 2.7 ns by 2.3 ns (the first build of the Mini).

 Audio: 48 kHz made on clk_bus (an accumulator: + 48 a clock modulo 28030), the samples held in registers of clk_bus
 and a toggle; on pclk the toggle through two registers gives the strobe of hdmi_tx (the samples are stable for
 20 us around it). dvi_only (kg_mcu2) is a register of clk_bus, static: DVI, no data islands.
*/

module hdmi_out (
	input wire clk_bus,
	input wire pclk,
	input wire reset,

	input wire [23:0] rgb,
	input wire hs,
	input wire vs,
	input wire de,

	input wire dvi_only,
	input wire [15:0] audio_l,   // signed, clk_bus
	input wire [15:0] audio_r,

	output wire [3:0] tmds_p,
	output wire [3:0] tmds_n
);

// the samples on clk_bus
reg [14:0] aud_acc = 15'd0;
reg aud_t = 1'b0;
reg [23:0] hdmi_l = 24'd0, hdmi_r = 24'd0;
always @(posedge clk_bus)
	if (aud_acc >= 15'd27982) begin
		aud_acc <= aud_acc + 15'd48 - 15'd28030;
		aud_t <= ~aud_t;
		hdmi_l <= {audio_l, 8'd0};
		hdmi_r <= {audio_r, 8'd0};
	end else
		aud_acc <= aud_acc + 15'd48;

// the strobe on pclk
reg [2:0] aud_s = 3'd0;
reg [1:0] dvi_s = 2'b00;
always @(posedge pclk) begin
	aud_s <= {aud_s[1:0], aud_t};
	dvi_s <= {dvi_s[0], dvi_only};
end

wire [9:0] t0, t1, t2, tc;
hdmi_enc #(.SAMPLE_FREQ(48000), .INPUT_REG(1)) enc(
	.clk(pclk),
	.reset(reset),
	.rgb(rgb),
	.vsync(vs),
	.hsync(hs),
	.de(de),
	.audio_en(~dvi_s[1]),
	.audio_l(hdmi_l),
	.audio_r(hdmi_r),
	.audio_clk(aud_s[2] ^ aud_s[1]),
	.tmds_0(t0),
	.tmds_1(t1),
	.tmds_2(t2),
	.tmds_c(tc)
);

tmds_oserdes ser(
	.pclk(pclk),
	.reset(reset),
	.d0(t0),
	.d1(t1),
	.d2(t2),
	.dc(tc),
	.tmds_p(tmds_p),
	.tmds_n(tmds_n)
);

endmodule
