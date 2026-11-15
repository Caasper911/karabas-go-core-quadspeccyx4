`timescale 1ns / 1ps
`default_nettype none

/*
 tb_r.v

 The R register of tv80_core against the Z80: R counts the M1 cycles (bits 6..0, bit 7 kept), LD A,R gives R after
 the two M1 of LD A,R itself, its S / Z flags are those of R, LD R,A sets it.
   0000 XOR A / LD R,A / NOP / NOP / LD A,R (4) / LD (8000),A / LD A,R (6+2=8? see below) / LD (8001),A
        LD A,80h / LD R,A / LD A,R (82h) / LD (8002),A / HALT
 Prints "tb_r: <n> errors".
*/

module tb_r;

reg clk = 1'b0;
always #10 clk = ~clk;
reg reset_n = 1'b0;
initial #100 reset_n = 1'b1;

reg [7:0] mem [0:65535];
integer i;
initial begin
	for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
	// XOR A; LD R,A; NOP; NOP; LD A,R; LD (8000),A; LD A,R; LD (8001),A; LD A,80h; LD R,A; LD A,R; LD (8002),A; HALT
	{mem[0], mem[1], mem[2], mem[3], mem[4], mem[5], mem[6]} = {8'hAF, 8'hED, 8'h4F, 8'h00, 8'h00, 8'hED, 8'h5F};
	{mem[7], mem[8], mem[9], mem[10], mem[11]} = {8'h32, 8'h00, 8'h80, 8'hED, 8'h5F};
	{mem[12], mem[13], mem[14]} = {8'h32, 8'h01, 8'h80};
	{mem[15], mem[16], mem[17], mem[18], mem[19], mem[20]} = {8'h3E, 8'h80, 8'hED, 8'h4F, 8'hED, 8'h5F};
	{mem[21], mem[22], mem[23], mem[24]} = {8'h32, 8'h02, 8'h80, 8'h76};
end

wire [15:0] A;
wire [7:0] dout;
wire m1_n, mreq_n, iorq, no_read, write, halt_n;
wire [6:0] mc, ts;
reg [7:0] di_reg = 8'hFF;           // DI is the byte of T2 kept (T80se; as zx_oct c_di)
always @(posedge clk)
	if (ts[2])
		di_reg <= mem[A];
tv80_core #(.Mode(0), .IOWait(1)) cpu (
	.rseed(8'd0), .reset_n(reset_n), .clk(clk), .cen(1'b1), .wait_n(1'b1), .int_n(1'b1), .nmi_n(1'b1), .busrq_n(1'b1),
	.dinst(mem[A]), .di(di_reg), .m1_n(m1_n), .iorq(iorq), .no_read(no_read), .write(write), .rfsh_n(),
	.halt_n(halt_n), .busak_n(), .A(A), .dout(dout), .mc(mc), .ts(ts), .intcycle_n(), .IntE(), .stop()
);

always @(posedge clk)
	if (write && !iorq && ts[2])
		mem[A] <= dout;

integer errors = 0;

initial begin
	#20000;
	// after LD R,A (0): NOP, NOP (2), the two M1 of LD A,R (2): 4
	if (mem['h8000] !== 8'h04) begin errors = errors + 1; $display("LD A,R after LD R,A 0 / NOP / NOP: %h, not 04", mem['h8000]); end
	// then LD (nn),A (1 M1), LD A,R (2): 7
	if (mem['h8001] !== 8'h07) begin errors = errors + 1; $display("LD A,R after LD (nn),A: %h, not 07", mem['h8001]); end
	// LD A,80h; LD R,A (R = 80); LD A,R (2): 82, bit 7 kept
	if (mem['h8002] !== 8'h82) begin errors = errors + 1; $display("LD A,R after LD R,A 80: %h, not 82", mem['h8002]); end
	if (cpu.F[7] !== 1'b1 || cpu.F[6] !== 1'b0) begin errors = errors + 1; $display("flags of LD A,R 82: S %b Z %b", cpu.F[7], cpu.F[6]); end
	$display("tb_r: 8000 %h 8001 %h 8002 %h, %0d errors", mem['h8000], mem['h8001], mem['h8002], errors);
	$finish;
end

endmodule
