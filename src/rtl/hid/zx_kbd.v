`timescale 1ns / 1ps
`default_nettype none

/*
 zx_kbd.v

 The USB HID keyboard report of the MCU (kg_mcu KB_STATUS, KB_DAT0..5) and the two joysticks as
 the ZX keyboard matrix and the Kempston joystick, for the machine that has the keyboard, and the
 hotkeys of the wall (from QuadSpeccy, with sel of 4 bits):

   Win + 1..8   the keyboard goes to machine 0..7 (sel), with Shift to machine 8..15 (from ROWS 3 on)
   Win + arrows the machine next to the selected one in the grid of 4 columns (sel[1:0]) and ROWS rows (sel[3:2]),
                no wrap
   Win + `/~    full screen of the selected machine on / off (full_tgl, one clock)

 While Win is held no key goes to the machine. The mapping is that of the profi / tsconf
 hid_parser in the Spectrum mode, without its macros:

   Shift CS, Ctrl SS, Alt CS+SS, Backspace CS+0, Esc CS+Space, arrows CS+5..8, Tab CS+I,
   CapsLock CS+2, PgUp CS+3, PgDn CS+4, ' " , < . > ; : / ? = + - _ and the keypad * - + /
   as SS combinations (their Shift does not give CS).

 keys: bit row * 5 + column, row n read with A(8+n) low, column 0 = data bit 0.
 The six key codes are taken one per clock; the matrix is updated after the sixth.
*/

module zx_kbd #(
	parameter ROWS = 2              // rows of 4 machines
) (
	input wire clk,
	input wire reset,

	input wire [7:0] kb_status,
	input wire [7:0] kb_dat0,
	input wire [7:0] kb_dat1,
	input wire [7:0] kb_dat2,
	input wire [7:0] kb_dat3,
	input wire [7:0] kb_dat4,
	input wire [7:0] kb_dat5,

	input wire [2:0] joy_type_l,  // 0 Kempston, 1 Sinclair 1, 2 Sinclair 2, 3 Cursor, 4 QAOPM, 5 QAOPS
	input wire [2:0] joy_type_r,
	input wire [12:0] joy_l,      // Mode Z Y X C B A Start R L D U On
	input wire [12:0] joy_r,

	output reg [39:0] keys = 40'd0,
	output reg [7:0] kempston = 8'd0,
	output reg [3:0] sel = 4'd0,
	output reg full_tgl = 1'b0
);

localparam K_CS = 0,  K_Z = 1,  K_X = 2,  K_C = 3,  K_V = 4;
localparam K_A = 5,   K_S = 6,  K_D = 7,  K_F = 8,  K_G = 9;
localparam K_Q = 10,  K_W = 11, K_E = 12, K_R = 13, K_T = 14;
localparam K_1 = 15,  K_2 = 16, K_3 = 17, K_4 = 18, K_5 = 19;
localparam K_0 = 20,  K_9 = 21, K_8 = 22, K_7 = 23, K_6 = 24;
localparam K_P = 25,  K_O = 26, K_I = 27, K_U = 28, K_Y = 29;
localparam K_ENT = 30, K_L = 31, K_K = 32, K_J = 33, K_H = 34;
localparam K_SP = 35, K_SS = 36, K_M = 37, K_N = 38, K_B = 39;

localparam J_UP = 1, J_DOWN = 2, J_LEFT = 3, J_RIGHT = 4, J_A = 6, J_B = 7, J_C = 8;

function [39:0] k;
	input integer n;
	begin
		k = 40'd0;
		k[n] = 1'b1;
	end
endfunction

// one key code: {no CS from Shift, keys}
function [40:0] decode;
	input [7:0] code;
	input shift;
	begin
		decode = 41'd0;
		case (code)
			8'h04: decode[39:0] = k(K_A);
			8'h05: decode[39:0] = k(K_B);
			8'h06: decode[39:0] = k(K_C);
			8'h07: decode[39:0] = k(K_D);
			8'h08: decode[39:0] = k(K_E);
			8'h09: decode[39:0] = k(K_F);
			8'h0A: decode[39:0] = k(K_G);
			8'h0B: decode[39:0] = k(K_H);
			8'h0C: decode[39:0] = k(K_I);
			8'h0D: decode[39:0] = k(K_J);
			8'h0E: decode[39:0] = k(K_K);
			8'h0F: decode[39:0] = k(K_L);
			8'h10: decode[39:0] = k(K_M);
			8'h11: decode[39:0] = k(K_N);
			8'h12: decode[39:0] = k(K_O);
			8'h13: decode[39:0] = k(K_P);
			8'h14: decode[39:0] = k(K_Q);
			8'h15: decode[39:0] = k(K_R);
			8'h16: decode[39:0] = k(K_S);
			8'h17: decode[39:0] = k(K_T);
			8'h18: decode[39:0] = k(K_U);
			8'h19: decode[39:0] = k(K_V);
			8'h1A: decode[39:0] = k(K_W);
			8'h1B: decode[39:0] = k(K_X);
			8'h1C: decode[39:0] = k(K_Y);
			8'h1D: decode[39:0] = k(K_Z);
			8'h1E, 8'h59: decode[39:0] = k(K_1);
			8'h1F, 8'h5A: decode[39:0] = k(K_2);
			8'h20, 8'h5B: decode[39:0] = k(K_3);
			8'h21, 8'h5C: decode[39:0] = k(K_4);
			8'h22, 8'h5D: decode[39:0] = k(K_5);
			8'h23, 8'h5E: decode[39:0] = k(K_6);
			8'h24, 8'h5F: decode[39:0] = k(K_7);
			8'h25, 8'h60: decode[39:0] = k(K_8);
			8'h26, 8'h61: decode[39:0] = k(K_9);
			8'h27, 8'h62: decode[39:0] = k(K_0);
			8'h28, 8'h58: decode[39:0] = k(K_ENT);
			8'h2C: decode[39:0] = k(K_SP);
			8'h2A: decode[39:0] = k(K_CS) | k(K_0);           // Backspace
			8'h29: decode[39:0] = k(K_CS) | k(K_SP);          // Esc: Break
			8'h50: decode[39:0] = k(K_CS) | k(K_5);           // left
			8'h51: decode[39:0] = k(K_CS) | k(K_6);           // down
			8'h52: decode[39:0] = k(K_CS) | k(K_7);           // up
			8'h4F: decode[39:0] = k(K_CS) | k(K_8);           // right
			8'h2B: decode[39:0] = k(K_CS) | k(K_I);           // Tab
			8'h39: decode[39:0] = k(K_CS) | k(K_2);           // CapsLock
			8'h4B: decode[39:0] = k(K_CS) | k(K_3);           // PgUp: true video
			8'h4E: decode[39:0] = k(K_CS) | k(K_4);           // PgDn: inverse video
			8'h34: decode = {1'b1, k(K_SS) | (shift ? k(K_P) : k(K_7))};   // ' "
			8'h36: decode = {1'b1, k(K_SS) | (shift ? k(K_R) : k(K_N))};   // , <
			8'h37: decode = {1'b1, k(K_SS) | (shift ? k(K_T) : k(K_M))};   // . >
			8'h33: decode = {1'b1, k(K_SS) | (shift ? k(K_Z) : k(K_O))};   // ; :
			8'h38: decode = {1'b1, k(K_SS) | (shift ? k(K_C) : k(K_V))};   // / ?
			8'h2E: decode = {1'b1, k(K_SS) | (shift ? k(K_K) : k(K_L))};   // = +
			8'h2D: decode = {1'b1, k(K_SS) | (shift ? k(K_0) : k(K_J))};   // - _
			8'h55: decode = {1'b1, k(K_SS) | k(K_B)};                      // keypad *
			8'h56: decode = {1'b1, k(K_SS) | k(K_J)};                      // keypad -
			8'h57: decode = {1'b1, k(K_SS) | k(K_K)};                      // keypad +
			8'h54: decode = {1'b1, k(K_SS) | k(K_V)};                      // keypad /
			default: ;
		endcase
	end
endfunction

function [39:0] joy_keys;
	input [2:0] t;
	input [12:0] j;
	begin
		joy_keys = 40'd0;
		case (t)
			3'd1: begin   // Sinclair 1 (Interface 2 left): 1 left, 2 right, 3 down, 4 up, 5 fire
				if (j[J_LEFT])  joy_keys = joy_keys | k(K_1);
				if (j[J_RIGHT]) joy_keys = joy_keys | k(K_2);
				if (j[J_DOWN])  joy_keys = joy_keys | k(K_3);
				if (j[J_UP])    joy_keys = joy_keys | k(K_4);
				if (j[J_B])     joy_keys = joy_keys | k(K_5);
			end
			3'd2: begin   // Sinclair 2: 6 left, 7 right, 8 down, 9 up, 0 fire
				if (j[J_LEFT])  joy_keys = joy_keys | k(K_6);
				if (j[J_RIGHT]) joy_keys = joy_keys | k(K_7);
				if (j[J_DOWN])  joy_keys = joy_keys | k(K_8);
				if (j[J_UP])    joy_keys = joy_keys | k(K_9);
				if (j[J_B])     joy_keys = joy_keys | k(K_0);
			end
			3'd3: begin   // Cursor: 5 left, 6 down, 7 up, 8 right, 0 fire
				if (j[J_LEFT])  joy_keys = joy_keys | k(K_5);
				if (j[J_DOWN])  joy_keys = joy_keys | k(K_6);
				if (j[J_UP])    joy_keys = joy_keys | k(K_7);
				if (j[J_RIGHT]) joy_keys = joy_keys | k(K_8);
				if (j[J_B])     joy_keys = joy_keys | k(K_0);
			end
			3'd4, 3'd5: begin   // QAOP + M / Space
				if (j[J_UP])    joy_keys = joy_keys | k(K_Q);
				if (j[J_DOWN])  joy_keys = joy_keys | k(K_A);
				if (j[J_LEFT])  joy_keys = joy_keys | k(K_O);
				if (j[J_RIGHT]) joy_keys = joy_keys | k(K_P);
				if (j[J_B])     joy_keys = joy_keys | (t == 3'd4 ? k(K_M) : k(K_SP));
			end
			default: ;
		endcase
	end
endfunction

function [7:0] kemp;
	input [2:0] t;
	input [12:0] j;
	begin
		if (t == 3'd0)
			kemp = {1'b0, j[J_A], j[J_C], j[J_B], j[J_UP], j[J_DOWN], j[J_LEFT], j[J_RIGHT]};
		else
			kemp = 8'd0;
	end
endfunction

wire shift = kb_status[1] | kb_status[5];
wire ctrl = kb_status[0] | kb_status[4];
wire alt = kb_status[2] | kb_status[6];
wire win = kb_status[3] | kb_status[7];

reg [2:0] idx = 3'd0;
reg [7:0] code;
always @* begin
	case (idx)
		3'd0: code = kb_dat0;
		3'd1: code = kb_dat1;
		3'd2: code = kb_dat2;
		3'd3: code = kb_dat3;
		3'd4: code = kb_dat4;
		default: code = kb_dat5;
	endcase
end

wire [40:0] dec = decode(code, shift);

reg [39:0] acc = 40'd0;
reg acc_nocs = 1'b0;
reg [3:0] hk_num = 4'd0, hk_num_prev = 4'd0;
reg hk_tilde = 1'b0, hk_tilde_prev = 1'b0;
reg [2:0] hk_arr = 3'd0, hk_arr_prev = 3'd0;   // arrow: 0 none, 4 right (4F), 5 left (50), 6 down (51), 7 up (52)

wire [39:0] acc_n = acc | dec[39:0];
wire nocs_n = acc_nocs | dec[40];
wire [3:0] hk_num_n = (code >= 8'h1E && code <= 8'h25) ? code[3:0] - 4'hD : hk_num;   // 1E..25 -> 1..8
wire hk_tilde_n = hk_tilde | (code == 8'h35);
wire [2:0] hk_arr_n = (code >= 8'h4F && code <= 8'h52) ? {1'b1, code[1:0] - 2'd3} : hk_arr;

wire [39:0] mods = (ctrl | alt ? k(K_SS) : 40'd0) | (alt | (shift & ~nocs_n) ? k(K_CS) : 40'd0);
wire [39:0] joys = joy_keys(joy_type_l, joy_l) | joy_keys(joy_type_r, joy_r);

always @(posedge clk) begin
	full_tgl <= 1'b0;
	if (reset) begin
		idx <= 3'd0;
		acc <= 40'd0;
		acc_nocs <= 1'b0;
		hk_num <= 4'd0;
		hk_tilde <= 1'b0;
		hk_arr <= 3'd0;
		keys <= 40'd0;
		sel <= 4'd0;
	end else if (idx == 3'd5) begin
		idx <= 3'd0;
		acc <= 40'd0;
		acc_nocs <= 1'b0;
		hk_num <= 4'd0;
		hk_tilde <= 1'b0;
		hk_arr <= 3'd0;
		keys <= (win ? 40'd0 : (acc_n | mods)) | joys;
		kempston <= kemp(joy_type_l, joy_l) | kemp(joy_type_r, joy_r);
		// hotkeys on the change of the key with Win held
		hk_num_prev <= hk_num_n;
		hk_tilde_prev <= hk_tilde_n;
		if (win && hk_num_n != 4'd0 && hk_num_n != hk_num_prev && hk_num_n <= ROWS * 4)
			sel <= hk_num_n - 4'd1 + ((shift && ROWS > 2) ? 4'd8 : 4'd0);
		if (win && hk_tilde_n && !hk_tilde_prev)
			full_tgl <= 1'b1;
		hk_arr_prev <= hk_arr_n;
		if (win && hk_arr_n != 3'd0 && hk_arr_n != hk_arr_prev)
			case (hk_arr_n[1:0])
				2'd0: if (sel[1:0] != 2'd3) sel[1:0] <= sel[1:0] + 2'd1;             // right
				2'd1: if (sel[1:0] != 2'd0) sel[1:0] <= sel[1:0] - 2'd1;             // left
				2'd2: if (sel[3:2] != ROWS - 1) sel[3:2] <= sel[3:2] + 2'd1;        // down
				default: if (sel[3:2] != 2'd0) sel[3:2] <= sel[3:2] - 2'd1;         // up
			endcase
	end else begin
		idx <= idx + 1'd1;
		acc <= acc_n;
		acc_nocs <= nocs_n;
		hk_num <= hk_num_n;
		hk_tilde <= hk_tilde_n;
		hk_arr <= hk_arr_n;
	end
end

endmodule
