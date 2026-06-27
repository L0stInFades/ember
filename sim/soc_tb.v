`timescale 1ns/1ps
`ifndef PROG
 `define PROG "prog.hex"
`endif
`ifndef MAXCYC
 `define MAXCYC 2000000
`endif
module soc_tb;
    reg clk=0, rst=1;
    wire uart_we, halt; wire [7:0] uart_data; wire [31:0] exit_code, dpc;
    integer cyc;

    rvcore #(.MEMFILE(`PROG)) dut(
        .clk(clk), .rst(rst), .uart_we(uart_we), .uart_data(uart_data),
        .halt(halt), .exit_code(exit_code), .dbg_pc(dpc));

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst && uart_we) $write("%c", uart_data);
        if (!rst && halt) begin
            $display("\n[SOC] 退出码 = %0d (周期 %0d)", exit_code, cyc);
            $finish;
        end
    end

    initial begin
        rst=1; repeat(4) @(posedge clk); rst=0;
        for (cyc=0; cyc<`MAXCYC; cyc=cyc+1) @(posedge clk);
        $display("\n[SOC] 超时停止 (%0d 周期), pc=%08x", `MAXCYC, dpc);
        $finish;
    end
endmodule
