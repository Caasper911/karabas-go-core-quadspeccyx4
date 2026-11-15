`timescale 1ns / 1ps
`default_nettype none

/*
 karabas_go_top.v

 QuadSpeccyX4 (rtl/quadspeccyx4.v) on Karabas Go: the VGA DAC clocked by V_CLK (pclk through an ODDR2, its rising edge in
 the middle of a pixel), the PCM5102, the beeper and tape outputs, the FT812 kept off the VGA bus but for the MCU.
 SDRAM, SD card, floppy drive, ESP, MIDI and the CF card are not used: idle.
*/

module karabas_go_top (
	input wire CLK_50MHZ,

	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,
	inout wire ESP_RESET_N,
	inout wire ESP_BOOT_N,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N,

	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

	output wire SD_CS_N,
	output wire SD_CLK,
	inout wire SD_DI,
	inout wire SD_DO,
	input wire SD_DET_N,

	output wire [7:0] VGA_R,
	output wire [7:0] VGA_G,
	output wire [7:0] VGA_B,
	output wire VGA_HS,
	output wire VGA_VS,
	output wire V_CLK,

	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	output wire FT_OE_N,

	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,

	input wire FDC_INDEX,
	output wire [1:0] FDC_DRIVE,
	output wire FDC_MOTOR,
	output wire FDC_DIR,
	output wire FDC_STEP,
	output wire FDC_WDATA,
	output wire FDC_WGATE,
	input wire FDC_TR00,
	input wire FDC_WPRT,
	input wire FDC_RDATA,
	output wire FDC_SIDE_N,

	output wire TAPE_OUT,
	input wire TAPE_IN,
	output wire BEEPER,

	output wire DAC_LRCK,
	output wire DAC_DAT,
	output wire DAC_BCK,
	output wire DAC_MUTE,

	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,
	input wire MCU_SPI_FT_CS_N,
	input wire MCU_SPI_SD2_CS_N,
	inout wire [1:0] MCU_SPI_IO,

	output wire MIDI_TX,
	output wire MIDI_CLK,
	output wire MIDI_RESET_N,

	output wire FLASH_CS_N,
	input wire FLASH_DO,
	output wire FLASH_DI,
	output wire FLASH_SCK,
	output wire FLASH_WP_N,
	output wire FLASH_HOLD_N
);

// ---------------------------------------------------------------------------------------------
// unused parts of the board: idle

assign UART_RX = 1'bZ;
assign UART_TX = 1'bZ;
assign UART_CTS = 1'bZ;
assign ESP_RESET_N = 1'bZ;
assign ESP_BOOT_N = 1'bZ;


assign SD_DO = 1'bZ;     // MISO of the card (SD_DI is MOSI)
assign SD_DI = 1'b1;
assign SD_CS_N = 1'b1;
assign SD_CLK = 1'b0;

// the SDRAM: the frame buffer of the wall (fb_sdram.v in the core)

assign FDC_DRIVE = 2'b00;
assign FDC_MOTOR = 1'b0;
assign FDC_DIR = 1'b0;
assign FDC_STEP = 1'b0;
assign FDC_WDATA = 1'b0;
assign FDC_WGATE = 1'b0;
assign FDC_SIDE_N = 1'b1;

assign WA = 3'd0;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign WD = 16'bZZZZZZZZZZZZZZZZ;

assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b0;
assign MIDI_RESET_N = 1'b0;

assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;

// ---------------------------------------------------------------------------------------------
// the core

wire clk_bus, areset, pclk;   // clk_bus: the net of the ucf
wire mcu_int;
wire ft_spi_on, ft_vga_on, ft_sck, ft_mosi, ft_cs_n;
wire [7:0] video_r, video_g, video_b;
wire video_hs, video_vs;
wire [15:0] audio_l, audio_r;

// MCU link v2: INT on the IO1 line of the firmware = MCU_SPI_IO[0] (N9, the burst READY of v1; the index is swapped on
// the Go), IO0 = MCU_SPI_IO[1] (M11, the burst CS_N of v1) an input
assign MCU_SPI_IO[0] = mcu_int;
assign MCU_SPI_IO[1] = 1'bZ;

quadspeccyx4 core(
	.CLK_50MHZ(CLK_50MHZ),
	.clk_bus(clk_bus),
	.clk_8(),
	.pclk(pclk),
	.areset(areset),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N),
	.SDR_CLK(SDR_CLK), .SDR_BA(SDR_BA), .SDR_A(SDR_A), .SDR_DQM(SDR_DQM), .SDR_RAS_N(SDR_RAS_N),
	.SDR_CAS_N(SDR_CAS_N), .SDR_WE_N(SDR_WE_N), .SDR_DQ(SDR_DQ),
	.mcu_cs_n(MCU_CS_N), .mcu_sck(MCU_SCK), .mcu_mosi(MCU_MOSI), .mcu_miso(MCU_MISO),
	.mcu_ft_ss(MCU_SPI_FT_CS_N), .mcu_sd2_ss(MCU_SPI_SD2_CS_N),
	.mcu_int(mcu_int),
	.dvi_only(),
	.ft_spi_on(ft_spi_on), .ft_vga_on(ft_vga_on), .ft_sck(ft_sck), .ft_mosi(ft_mosi), .ft_cs_n(ft_cs_n),
	.ft_reset(), .ft_miso(FT_SPI_MISO),
	.tape_in(TAPE_IN), .tape_out(TAPE_OUT), .beeper(BEEPER),
	.video_r(video_r), .video_g(video_g), .video_b(video_b), .video_hs(video_hs), .video_vs(video_vs), .video_de(),
	.audio_l(audio_l), .audio_r(audio_r)
);

// FT812: only the MCU uses it
assign FT_SPI_CS_N = ft_spi_on ? ft_cs_n : 1'b1;
assign FT_SPI_SCK = ft_spi_on ? ft_sck : 1'b0;
assign FT_SPI_MOSI = ft_spi_on ? ft_mosi : 1'b0;
assign FT_OE_N = ft_vga_on ? 1'b0 : 1'b1;

// VGA: the DAC takes the picture with the rising V_CLK, half a pclk after the picture changed (pclk inverted)
assign VGA_R = video_r;
assign VGA_G = video_g;
assign VGA_B = video_b;
assign VGA_HS = video_hs;
assign VGA_VS = video_vs;
ODDR2 #(.DDR_ALIGNMENT("NONE"), .INIT(1'b0), .SRTYPE("SYNC")) oddr_vclk(
	.Q(V_CLK), .C0(pclk), .C1(~pclk), .CE(1'b1), .D0(1'b0), .D1(1'b1), .R(1'b0), .S(1'b0)
);

// sound: the PCM5102
kg_pcm5102 #(.DIV_BITS(1)) pcm5102(
	.clk(clk_bus),
	.reset(areset),
	.left(audio_l),
	.right(audio_r),
	.din(DAC_DAT),
	.bck(DAC_BCK),
	.lrck(DAC_LRCK)
);
assign DAC_MUTE = 1'b1;   // 1 = unmuted

endmodule
