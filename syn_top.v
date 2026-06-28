`timescale 1ns/1ps
// 综合顶层: 暴露少量输出, 防止综合工具裁掉数据通路, 便于测 Fmax
module syn_top(
    input  wire        clk,
    input  wire        rst,
    input  wire        imem_we,
    input  wire [7:0]  imem_waddr,
    input  wire [31:0] imem_wdata,
    output reg  [31:0] dbg
);
    wire [31:0] x10, pcv;
    cpu_pipe core(
        .clk(clk), .rst(rst),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .dbg_x10(x10), .dbg_pc(pcv)
    );
    always @(posedge clk) dbg <= x10 ^ pcv;
endmodule
