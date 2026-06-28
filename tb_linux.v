`timescale 1ns/1ps
`ifndef PROG
 `define PROG "sanity.hex"
`endif
`ifndef MAXCYC
 `define MAXCYC 2000000
`endif
`ifndef MEMW
 `define MEMW 16384
`endif
module tb_linux;
    reg clk=0, rst=1;
    wire uart_we, halt; wire [7:0] uart_data; wire [31:0] exit_code, dpc; wire [1:0] dpriv;
    integer cyc;

    rvlinux #(.MEMFILE(`PROG), .MEMWORDS(`MEMW)) dut(
        .clk(clk), .rst(rst), .uart_we(uart_we), .uart_data(uart_data),
        .rx_valid(1'b0), .rx_byte_in(8'd0),
        .halt(halt), .exit_code(exit_code), .dbg_pc(dpc), .dbg_priv(dpriv));

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst && uart_we) $write("%c", uart_data);
        if (!rst && halt) begin
            $display("\n[SOC] halt exit=%0d (cyc %0d)", exit_code, cyc);
            $finish;
        end
    end

    initial begin
        rst=1; repeat(4) @(posedge clk); rst=0;
        for (cyc=0; cyc<`MAXCYC; cyc=cyc+1) @(posedge clk);
        $display("\n[SOC] timeout (%0d cyc) pc=%08x priv=%0d", `MAXCYC, dpc, dpriv);
        $finish;
    end
endmodule
