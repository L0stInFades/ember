`timescale 1ns/1ps
// 测试平台: 复位 -> 跑核 -> 检测自循环停机 -> 打印状态并自检 PASS/FAIL
module tb;
    reg clk = 0, rst = 1;
    wire [31:0] pc, instr;
    integer i;
    reg [31:0] last_pc;

    cpu #(.MEMFILE("prog.hex")) dut (
        .clk(clk), .rst(rst), .pc_out(pc), .instr_out(instr)
    );

    always #5 clk = ~clk;   // 100MHz 时钟

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb);

        rst = 1;
        repeat (3) @(posedge clk);
        rst = 0;

        last_pc = 32'hffffffff;
        for (i = 0; i < 2000; i = i + 1) begin
            $display("cyc=%0d  pc=0x%08h  instr=0x%08h", i, pc, instr);
            if (pc == last_pc) begin
                $display(">> 检测到自循环(j .) 停机于 pc=0x%08h", pc);
                i = 2000;
            end else begin
                last_pc = pc;
                @(posedge clk);
            end
        end

        $display("");
        $display("==== 最终状态 ====");
        $display("x1  ra = %0d", dut.regs[1]);
        $display("x5  t0 = %0d", dut.regs[5]);
        $display("x6  t1 = %0d", dut.regs[6]);
        $display("x10 a0 = %0d", dut.regs[10]);
        $display("x11 a1 = %0d", dut.regs[11]);
        $display("mem[0] = %0d", dut.dmem[0]);
        $display("");
        if (dut.regs[10]==55 && dut.regs[11]==55 && dut.dmem[0]==55)
            $display("RESULT: PASS  (sum 1..10 == 55; jal/jalr/branch/sw/lw 均正确)");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
