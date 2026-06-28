`timescale 1ns/1ps
// 五级流水核功能仿真测试平台
module tb_pipe;
    reg clk=0, rst=1;
    wire [31:0] dbg_x10, dbg_pc;
    integer i;
    reg [31:0] last_pc;
    integer halt_seen;

    cpu_pipe #(.MEMFILE("prog_pipe.hex")) dut (
        .clk(clk), .rst(rst),
        .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .dbg_x10(dbg_x10), .dbg_pc(dbg_pc)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("wave_pipe.vcd");
        $dumpvars(0, tb_pipe);

        rst = 1;
        repeat (3) @(posedge clk);
        rst = 0;

        last_pc = 32'hffffffff; halt_seen = 0;
        for (i = 0; i < 600; i = i + 1) begin
            @(posedge clk);
            if (i < 32)
                $display("cyc=%0d  pc=0x%08h", i, dbg_pc);
            if (dbg_pc == last_pc) halt_seen = halt_seen + 1;
            else begin last_pc = dbg_pc; halt_seen = 0; end
            if (halt_seen == 4)            // 持续不变才算停机(避开 1 拍停顿误报)
                $display(">> 检测到自循环停机 pc=0x%08h (cyc=%0d)", dbg_pc, i);
            if (halt_seen > 8) i = 600;    // 排空流水线后退出
        end

        $display("");
        $display("==== 最终寄存器/内存 ====");
        $display("t0 (x5)  = %0d", dut.regs[5]);
        $display("t1 (x6)  = %0d", dut.regs[6]);
        $display("t2 (x7)  = %0d", dut.regs[7]);
        $display("t3 (x28) = %0d", dut.regs[28]);
        $display("t4 (x29) = %0d   <- load-use", dut.regs[29]);
        $display("s0 (x8)  = %0d   <- 循环求和", dut.regs[8]);
        $display("a1 (x11) = %0d   <- 前向分支", dut.regs[11]);
        $display("a2 (x12) = %0d   <- jal/jalr 函数", dut.regs[12]);
        $display("mem[0]   = %0d", dut.dmem[0]);
        $display("");
        if (dut.regs[8]==55 && dut.regs[29]==14 && dut.regs[11]==1 &&
            dut.regs[12]==42 && dut.dmem[0]==13)
            $display("RESULT: PASS  (前递/停顿/前后向分支/jal-jalr 全部正确)");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
