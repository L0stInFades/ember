`timescale 1ns/1ps
module syn_top_ooo(
    input  wire clk, rst, imem_we,
    input  wire [7:0]  imem_waddr,
    input  wire [31:0] imem_wdata,
    output reg  [31:0] dbg
);
    wire [31:0] x10, pcv;
    cpu_ooo core(.clk(clk), .rst(rst), .imem_we(imem_we), .imem_waddr(imem_waddr),
                 .imem_wdata(imem_wdata), .dbg_x10(x10), .dbg_pc(pcv));
    always @(posedge clk) dbg <= x10 ^ pcv;
endmodule
