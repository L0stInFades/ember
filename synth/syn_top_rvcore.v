`timescale 1ns/1ps
// 综合顶层: 用小存储(256字)只测核心逻辑面积/Fmax
module syn_top_rvcore(
    input  wire clk, rst,
    output wire uart_we,
    output wire [7:0] uart_data,
    output wire halt,
    output reg  [31:0] dbg
);
    wire [31:0] ec, pc;
    rvcore #(.MEMWORDS(256)) core(
        .clk(clk), .rst(rst), .uart_we(uart_we), .uart_data(uart_data),
        .halt(halt), .exit_code(ec), .dbg_pc(pc));
    always @(posedge clk) dbg <= ec ^ pc;
endmodule
