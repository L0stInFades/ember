`timescale 1ns/1ps
// 性能基准测试平台: 跑分支预测微基准, 在停机处快照性能计数器, 打印 IPC/误预测率
module tb_bench;
    reg clk=0, rst=1;
    wire [31:0] dbg_x10, dbg_pc;
    integer i; reg [31:0] last_pc; integer halt_seen;
    reg [31:0] s_cyc, s_ret, s_br, s_mis; reg snapped;

    cpu_pipe #(.MEMFILE("prog_bench.hex")) dut (
        .clk(clk), .rst(rst),
        .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .dbg_x10(dbg_x10), .dbg_pc(dbg_pc)
    );
    always #5 clk = ~clk;

    initial begin
        rst=1; repeat(3) @(posedge clk); rst=0;
        last_pc=32'hffffffff; halt_seen=0; snapped=0;
        // done 标签在字节地址 44; 程序中真实 PC 最大为 40, 故 PC>=44 持续即停机
        for (i=0; i<5000; i=i+1) begin
            @(posedge clk);
            if (dbg_pc>=32'd44) halt_seen=halt_seen+1;
            else halt_seen=0;
            if (halt_seen==3 && !snapped) begin
                s_cyc=dut.cyc_count; s_ret=dut.instr_retired;
                s_br=dut.branch_count; s_mis=dut.mispredict_count; snapped=1;
            end
            if (halt_seen>10) i=5000;
        end
        $display("==== 结果校验 ====");
        $display("t6 = %0d (期望 1600)   t2 = %0d (期望 64)", dut.regs[31], dut.regs[7]);
        $display("==== 性能 ====");
        $display("cycles       = %0d", s_cyc);
        $display("instr退休    = %0d", s_ret);
        $display("IPC*100      = %0d", (s_ret*100)/s_cyc);
        $display("分支数       = %0d", s_br);
        $display("误预测数     = %0d", s_mis);
        $display("误预测率%%    = %0d", (s_mis*100)/s_br);
        if (dut.regs[31]==1600 && dut.regs[7]==64)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
