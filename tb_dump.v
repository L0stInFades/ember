`timescale 1ns/1ps
// 架构状态转储 + 性能, 用于"标量 vs 超标量"等价比对 (-DSUPER 选超标量核)
// 用法: iverilog -g2012 -DSIM_INIT [-DSUPER] -DPROG='"xxx.hex"' tb_dump.v cpu_*.v
`ifndef PROG
 `define PROG "prog_ilp.hex"
`endif
module tb_dump;
    reg clk=0, rst=1;
    wire [31:0] dx10, dpc;
    integer i, j;
    reg [31:0] p1, p2; integer hc;
    reg [31:0] scyc, sret; reg snapped;

`ifdef OOO
    cpu_ooo   #(.MEMFILE(`PROG)) dut (
        .clk(clk), .rst(rst), .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .dbg_x10(dx10), .dbg_pc(dpc));
`elsif SUPER
    cpu_super #(.MEMFILE(`PROG)) dut (
        .clk(clk), .rst(rst), .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .dbg_x10(dx10), .dbg_pc(dpc));
`else
    cpu_pipe  #(.MEMFILE(`PROG)) dut (
        .clk(clk), .rst(rst), .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .dbg_x10(dx10), .dbg_pc(dpc));
`endif

    always #5 clk = ~clk;

    initial begin
        rst=1; repeat(3) @(posedge clk); rst=0;
        p1=32'hffffffff; p2=32'hfffffffe; hc=0; snapped=0;
        for (i=0; i<8000; i=i+1) begin
            @(posedge clk);
            if (dpc==p2) hc=hc+1; else hc=0;   // 周期<=2 的 PC 振荡 = 停机自循环
            p2=p1; p1=dpc;
            if (hc>=4 && !snapped) begin
                scyc=dut.cyc_count; sret=dut.instr_retired; snapped=1;
            end
            if (hc>=12) i=8000;
        end
        $display("=ARCH=");
        for (j=0;j<32;j=j+1) $display("R[%0d]=%08x", j, dut.regs[j]);
        for (j=0;j<8;j=j+1)  $display("M[%0d]=%08x", j, dut.dmem[j]);
        $display("=PERF=");
        $display("cycles=%0d",  scyc);
        $display("retired=%0d", sret);
        if (scyc>0) $display("IPC100=%0d", (sret*100)/scyc);
        $finish;
    end
endmodule
