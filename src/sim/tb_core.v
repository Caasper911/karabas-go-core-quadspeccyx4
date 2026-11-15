`timescale 1ns / 1ps
`default_nettype none

/*
 tb_core.v

 The whole core (quadspeccyx4.v with its PLLs, the MCU link idle) on the SRAM model; the ROM written into zx_oct
 directly (the loader of the MCU is not simulated), the BUSY of the MCU forced to 0 after 2 us. Prints the diagnostics of the core (the diagnostics squares) every
 100 000 clocks of clk_bus and the border of the selected machine: the machines must run (bring-up of the board).
*/

`ifndef CLOCKS
`define CLOCKS 1500000
`endif

module tb_core;

reg clk50 = 1'b0;
always #10 clk50 = ~clk50;

wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MRD_N, MWR_N;
wire clk_bus;

quadspeccyx4 #(.MEMTEST_AW(10)) dut (
	.CLK_50MHZ(clk50),
	.clk_bus(clk_bus), .clk_8(), .pclk(), .areset(),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N),
	.SDR_CLK(SDR_CLK), .SDR_BA(SDR_BA), .SDR_A(SDR_A), .SDR_DQM(SDR_DQM), .SDR_RAS_N(SDR_RAS_N),
	.SDR_CAS_N(SDR_CAS_N), .SDR_WE_N(SDR_WE_N), .SDR_DQ(SDR_DQ),
	.mcu_cs_n(1'b1), .mcu_sck(1'b0), .mcu_mosi(1'b0), .mcu_miso(), .mcu_ft_ss(1'b1), .mcu_sd2_ss(1'b1),
	.mcu_int(), .dvi_only(),
	.ft_spi_on(), .ft_vga_on(), .ft_sck(), .ft_mosi(), .ft_cs_n(), .ft_reset(), .ft_miso(1'b1),
	.tape_in(1'b0), .tape_out(), .beeper(),
	.video_r(), .video_g(), .video_b(), .video_hs(), .video_vs(), .video_de(),
	.audio_l(), .audio_r()
);

wire SDR_CLK, SDR_RAS_N, SDR_CAS_N, SDR_WE_N;
wire [1:0] SDR_BA, SDR_DQM;
wire [12:0] SDR_A;
wire [15:0] SDR_DQ;
sdram_model #(.ROWS(1024), .RB(10)) sdram (
	.clk(SDR_CLK), .ba(SDR_BA), .a(SDR_A), .dqm(SDR_DQM), .ras_n(SDR_RAS_N), .cas_n(SDR_CAS_N), .we_n(SDR_WE_N),
	.dq(SDR_DQ)
);
sram_model model (.A(MA), .DQ(MD), .RD_N(MRD_N), .WR_N(MWR_N), .drv(dut.sram.md_oe[0]));

reg [15:0] romw [0:16383];
integer i, n = 0;
initial begin
	$readmemh("roms.hex", romw);
	for (i = 0; i < (1 << 21); i = i + 1)
		model.mem[i] = 16'h0000;
	// the ROMs in the SRAM, as the loader puts them there ({111111, byte}: words 1F8000)
	for (i = 0; i < 16384; i = i + 1)
		model.mem[21'h1F8000 + i] = romw[i];
	// the MCU would end its INIT (busy 0) after loading the ROMs
	#2000 force dut.mcu_busy = 1'b0;
end

always @(posedge clk_bus) begin
	n = n + 1;
	if (n % 100000 == 0)
		$display("%0d: reset %b border %0d diag %b %b %h %h %h %h", n, dut.m_reset, dut.v_border, dut.diag[15:0], dut.diag[31:16],
			dut.diag[47:32], dut.diag[63:48], dut.diag[79:64], dut.diag[95:80]);
	if (n == `CLOCKS) $finish;
end

endmodule
