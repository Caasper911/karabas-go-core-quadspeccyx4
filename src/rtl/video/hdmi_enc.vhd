-- zhdmi_tx.vhd - HDMI transmitter
--
-- Copyright (c) 2021-2025 Francois Galea <fgalea at free.fr>
-- Modification for Spartan 6 (c) 2025 Andy Karpov <andy dot karpov at gmail dot com>
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.

--
-- SpeccyWall (src/rtl/video/hdmi_enc.vhd): a copy of zhdmi_tx.vhd of karabas-go-modules (entity hdmi_tx) without its
-- serializers (in the fabric at 5x the pixel clock: 368 MHz at the 73.6 MHz of SpeccyWall does not meet the timing);
-- the 10-bit words go out (tmds_0..2, tmds_c) to the OSERDES2 serializers of tmds_oserdes.v. Same licence.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hdmi_enc is
	generic (
		SAMPLE_FREQ : integer := 32000;
		-- Invert flags for the different TMDS channels.
		-- Set a channel bit to 1 if the p and n outputs for that channel are swapped.
		INVERTED_TX : std_logic_vector(3 downto 0) := "0000";
		-- karabas: register rgb, vsync, hsync and de on clk before the encoders (one clock of latency
		-- for all four, so the alignment in the core does not change). The OSD overlay output
		-- (kg_osd_overlay rgb_o) is combinational: with it the overlay mux and the TMDS encoder share one
		-- pixel clock, which fails near 99 % slices (core-sega on Mini at 65 MHz: -2.7 ns).
		INPUT_REG : integer range 0 to 1 := 0   -- 1: registered (an integer, so that Verilog can set it)
	);
	port (
		clk      : in std_logic;	-- pixel clock
		reset    : in std_logic;
		rgb      : in std_logic_vector(23 downto 0);	-- pixel data
		vsync    : in std_logic;
		hsync    : in std_logic;
		de       : in std_logic;

		audio_en     : in std_logic;		-- audio enable
		audio_l      : in std_logic_vector(23 downto 0);	-- left channel
		audio_r      : in std_logic_vector(23 downto 0);	-- right channel
		audio_clk    : in std_logic;		-- audio sample clock (coherent with clk)

		-- the 10-bit words of the channels on clk (0 blue, 1 green, 2 red, c the clock), bit 0 sent first
		tmds_0   : out std_logic_vector(9 downto 0);
		tmds_1   : out std_logic_vector(9 downto 0);
		tmds_2   : out std_logic_vector(9 downto 0);
		tmds_c   : out std_logic_vector(9 downto 0)
	);
end hdmi_enc;


architecture rtl of hdmi_enc is
	type tmds_d_t is array(0 to 2) of std_logic_vector(9 downto 0);
	signal tmds_d : tmds_d_t;
	signal dvi_d : tmds_d_t;
	signal enc_d  : tmds_d_t;
	signal tmds_div_mux_d : tmds_d_t;
	signal clk_d  : std_logic_vector(9 downto 0);

	signal data : std_logic_vector(23 downto 0);
	
	signal sde  : std_logic;
	signal sae  : std_logic;
	signal vgb  : std_logic;
	signal dgb  : std_logic;

	-- the inputs, registered or not (INPUT_REG)
	signal rgb_i   : std_logic_vector(23 downto 0);
	signal vsync_i : std_logic;
	signal hsync_i : std_logic;
	signal de_i    : std_logic;

begin
	in_reg: if INPUT_REG = 1 generate
		process(clk)
		begin
			if rising_edge(clk) then
				rgb_i <= rgb;
				vsync_i <= vsync;
				hsync_i <= hsync;
				de_i <= de;
			end if;
		end process;
	end generate;
	in_direct: if INPUT_REG = 0 generate
		rgb_i <= rgb;
		vsync_i <= vsync;
		hsync_i <= hsync;
		de_i <= de;
	end generate;

	tmds_d(0) <= enc_d(0) when INVERTED_TX(0) = '0' else not enc_d(0);
	tmds_d(1) <= enc_d(1) when INVERTED_TX(1) = '0' else not enc_d(1);
	tmds_d(2) <= enc_d(2) when INVERTED_TX(2) = '0' else not enc_d(2);
	clk_d <= "1111100000" when INVERTED_TX(3) = '0' else "0000011111";
	
	tmds_div_mux_d(0) <= tmds_d(0) when audio_en = '1' else dvi_d(0);
	tmds_div_mux_d(1) <= tmds_d(1) when audio_en = '1' else dvi_d(1);
	tmds_div_mux_d(2) <= tmds_d(2) when audio_en = '1' else dvi_d(2);

	dvi: entity work.dvi port map(
		CLK	=> clk,
		RESET	=> reset,
		RGB	=> rgb_i,
		HSYNC	=> hsync_i,
		VSYNC	=> vsync_i,
		DE		=> de_i,
		ENC_RED	=> dvi_d(2),
		ENC_GREEN => dvi_d(1),
		ENC_BLUE	=> dvi_d(0)
	);

	signaler: entity work.signaling generic map (
			SAMPLE_FREQ => SAMPLE_FREQ
		)
		port map (
			clk => clk,
			reset => reset,
			rgb => rgb_i,
			vsync => vsync_i,
			hsync => hsync_i,
			ide => de_i,
			audio_en => audio_en,
			audio_l => audio_l,
			audio_r => audio_r,
			audio_clk => audio_clk,
			data => data,
			de => sde,
			ae => sae,
			vgb => vgb,
			dgb => dgb
		);

	tmds_c <= clk_d;
	tmds_0 <= tmds_div_mux_d(0);
	tmds_1 <= tmds_div_mux_d(1);
	tmds_2 <= tmds_div_mux_d(2);

	chn: for i in 0 to 2 generate
		encoder: entity work.tmds_encoder generic map (
			CHN => i
		) port map (
			clk => clk,
			reset => reset,
			data => data(i*8+7 downto i*8),
			de => sde,
			ae => sae,
			vgb => vgb,
			dgb => dgb,
			tmds_d => enc_d(i)
		);

	end generate chn;

end architecture;
