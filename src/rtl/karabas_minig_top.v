`timescale 1ns / 1ps
`default_nettype none

/*
 karabas_minig_top.v

 QuadSpeccyX4 (rtl/quadspeccyx4.v) on Karabas Mini rev. G (the pins of karabas-go-core-tsconf). As karabas_mini_top.v
 except: the PCM5102 (DAC_BCK / DAC_WS / DAC_DAT) instead of the sigma-delta outputs, MCU_SCK on a global clock pin
 (C9: IBUFG + BUFG, SCK up to 32 MHz; the FT812 gets the SCK before the BUFG, a BUFG drives clock pins only),
 MCU_IO<5:0>, the ESP32 lines; no FT_RESET, MIDI_CLK, MIDI_RESET_N, ESP_RESET_N, ESP_BOOT_N.
*/

module karabas_minig_top (
	input wire CLK_50MHZ,

	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,

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

	// the video of the FT812 into the FPGA (not used)
	input wire [7:0] VGA_R,
	input wire [7:0] VGA_G,
	input wire [7:0] VGA_B,
	input wire VGA_HS,
	input wire VGA_VS,

	output wire [3:0] TMDS_P,
	output wire [3:0] TMDS_N,

	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	input wire FT_DE,
	output wire FT_CLK_OUT,

	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,

	output wire TAPE_OUT,
	input wire TAPE_IN,

	output wire DAC_BCK,
	output wire DAC_WS,
	output wire DAC_DAT,

	output wire ADC_CLK,
	inout wire ADC_BCK,
	inout wire ADC_LRCK,
	input wire ADC_DOUT,

	inout wire ESP32_SPI_CS_N,
	input wire ESP32_PCM_BCK,
	input wire ESP32_PCM_RLCK,
	input wire ESP32_PCM_DAT,

	input wire MCU_CS_N,
	input wire MCU_SCK,
	input wire MCU_MOSI,
	output wire MCU_MISO,
	inout wire [5:0] MCU_IO,

	output wire MIDI_TX,

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
assign ESP32_SPI_CS_N = 1'bZ;


assign SD_DO = 1'bZ;     // MISO of the card (SD_DI is MOSI)
assign SD_DI = 1'b1;
assign SD_CS_N = 1'b1;
assign SD_CLK = 1'b0;

// the SDRAM: the frame buffer of the wall (fb_sdram.v in the core)

assign WA = 3'd0;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign WD = 16'bZZZZZZZZZZZZZZZZ;

assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bZ;
assign ADC_LRCK = 1'bZ;

assign MIDI_TX = 1'b1;

assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;

// ---------------------------------------------------------------------------------------------
// the core

wire clk_bus, clk_8, areset, pclk;   // clk_bus, pclk: the nets of the ucf
wire mcu_int, dvi_only;
wire ft_spi_on, ft_mosi, ft_cs_n;
wire [7:0] video_r, video_g, video_b;
wire video_hs, video_vs, video_de;
wire [15:0] audio_l, audio_r;

// MCU_IO: [0] an input (the burst CS_N of v1), [1] INT of link v2 (the burst READY of v1), [2] SD2 CS_N, [3] FT CS_N
assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bZ;
assign MCU_IO[5:2] = 4'bZZZZ;

// MCU_SCK on a global buffer (C9, a clock pin; as TS-Conf on the Mini G): kg_mcu clocks its SPI receiver from it
wire mcu_sck_ibufg, mcu_sck;
IBUFG ibufg_mcu_sck(.I(MCU_SCK), .O(mcu_sck_ibufg));
BUFG bufg_mcu_sck(.I(mcu_sck_ibufg), .O(mcu_sck));

quadspeccyx4 core(
	.CLK_50MHZ(CLK_50MHZ),
	.clk_bus(clk_bus),
	.clk_8(clk_8),
	.pclk(pclk),
	.areset(areset),
	.MA(MA), .MD(MD), .MRD_N(MRD_N), .MWR_N(MWR_N),
	.SDR_CLK(SDR_CLK), .SDR_BA(SDR_BA), .SDR_A(SDR_A), .SDR_DQM(SDR_DQM), .SDR_RAS_N(SDR_RAS_N),
	.SDR_CAS_N(SDR_CAS_N), .SDR_WE_N(SDR_WE_N), .SDR_DQ(SDR_DQ),
	.mcu_cs_n(MCU_CS_N), .mcu_sck(mcu_sck), .mcu_mosi(MCU_MOSI), .mcu_miso(MCU_MISO),
	.mcu_ft_ss(MCU_IO[3]), .mcu_sd2_ss(MCU_IO[2]),
	.mcu_int(mcu_int),
	.dvi_only(dvi_only),
	.ft_spi_on(ft_spi_on), .ft_vga_on(), .ft_sck(), .ft_mosi(ft_mosi), .ft_cs_n(ft_cs_n),
	.ft_reset(), .ft_miso(FT_SPI_MISO),
	.tape_in(TAPE_IN), .tape_out(TAPE_OUT), .beeper(),
	.video_r(video_r), .video_g(video_g), .video_b(video_b), .video_hs(video_hs), .video_vs(video_vs),
	.video_de(video_de),
	.audio_l(audio_l), .audio_r(audio_r)
);

// FT812: only the MCU uses it (its SPI); it must always have its clock (FT_CLK_OUT, 8 MHz)
assign FT_SPI_CS_N = ft_spi_on ? ft_cs_n : 1'b1;
assign FT_SPI_SCK = ft_spi_on ? mcu_sck_ibufg : 1'b0;
assign FT_SPI_MOSI = ft_spi_on ? ft_mosi : 1'b0;
ODDR2 ft_clk_out(.Q(FT_CLK_OUT), .C0(clk_8), .C1(~clk_8), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

// ---------------------------------------------------------------------------------------------
// HDMI: the picture with the OSD and the sound

hdmi_out hdmi(
	.clk_bus(clk_bus),
	.pclk(pclk),
	.reset(areset),
	.rgb({video_r, video_g, video_b}),
	.hs(video_hs),
	.vs(video_vs),
	.de(video_de),
	.dvi_only(dvi_only),
	.audio_l(audio_l),
	.audio_r(audio_r),
	.tmds_p(TMDS_P),
	.tmds_n(TMDS_N)
);

// sound: the PCM5102 (DIV_BITS 2: BCK 3.5 MHz, 55 kHz, as tsconf; with 1 (109 kHz, as Go) the DAC of Mini G is silent)
kg_pcm5102 #(.DIV_BITS(2)) pcm5102(
	.clk(clk_bus),
	.reset(areset),
	.left(audio_l),
	.right(audio_r),
	.din(DAC_DAT),
	.bck(DAC_BCK),
	.lrck(DAC_WS)
);

endmodule
