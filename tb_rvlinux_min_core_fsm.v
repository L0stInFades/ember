`timescale 1ns/1ps

module tb_rvlinux_min_core_fsm;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg rx_valid = 1'b0;
    reg [7:0] rx_byte_in = 8'd0;

    wire rx_ready;
    wire uart_we;
    wire [7:0] uart_data;
    wire halt;
    wire [31:0] exit_code;
    wire fault;
    wire [3:0] fault_cause;
    wire [31:0] fault_tval;
    wire [31:0] pc;
    wire [31:0] retired;
    wire [31:0] dbg_x3;
    wire [31:0] dbg_x5;
    wire [31:0] dbg_x6;
    wire [31:0] dbg_x10;
    wire cluster_busy;
    wire [2:0] cluster_active_owner;
    wire [31:0] i_hits;
    wire [31:0] i_misses;
    wire [31:0] d_hits;
    wire [31:0] d_misses;
    wire [31:0] ad_writes;
    wire backing_req;
    wire backing_we;
    wire [31:0] backing_addr;
    wire backing_ack;

    integer cycle;

    rvlinux_min_core_fsm #(
        .RESET_PC(32'h0000_0000),
        .I_LINES(16),
        .D_LINES(16),
        .WORDS(4),
        .MEMWORDS(1024),
        .LAT(4),
        .RAMBASE(32'h0000_0000)
    ) dut (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in),
        .rx_ready(rx_ready), .uart_we(uart_we), .uart_data(uart_data),
        .exit_code(exit_code),
        .halt(halt), .fault(fault), .fault_cause(fault_cause),
        .fault_tval(fault_tval), .pc(pc), .retired(retired),
        .dbg_x3(dbg_x3), .dbg_x5(dbg_x5), .dbg_x6(dbg_x6),
        .dbg_x10(dbg_x10), .cluster_busy(cluster_busy),
        .cluster_active_owner(cluster_active_owner),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    always #5 clk = ~clk;

    task write_word;
        input integer index;
        input [31:0] value;
        begin
            dut.cluster.mem.memsys.backing.mem[index] = value;
        end
    endtask

    initial begin
        #1;
        // 0x00: x1=5; x2=7; x3=12
        write_word(0, 32'h0050_0093); // addi x1,x0,5
        write_word(1, 32'h0070_0113); // addi x2,x0,7
        write_word(2, 32'h0020_81b3); // add  x3,x1,x2
        write_word(3, 32'h1000_0213); // addi x4,x0,0x100
        // 0x10: store/load through D$, then branch over the bad write.
        write_word(4, 32'h0032_2023); // sw   x3,0(x4)
        write_word(5, 32'h0002_2283); // lw   x5,0(x4)
        write_word(6, 32'h0032_8463); // beq  x5,x3,+8
        write_word(7, 32'h0010_0313); // addi x6,x0,1 (must be skipped)
        // 0x20: two compressed nops prove 16-bit PC stepping before EBREAK.
        write_word(8, 32'h0001_0001); // c.nop; c.nop
        write_word(9, 32'h0002_8513); // addi x10,x5,0
        // 0x28: M-extension and AMO/LR/SC through the shared cluster.
        write_word(10, 32'h0220_85b3); // mul  x11,x1,x2 = 35
        write_word(11, 32'h0215_c633); // div  x12,x11,x1 = 7
        write_word(12, 32'h0225_e6b3); // rem  x13,x11,x2 = 0
        write_word(13, 32'h0012_272f); // amoadd.w x14,x1,(x4): old=12, mem=17
        write_word(14, 32'h1002_27af); // lr.w x15,(x4): old=17
        write_word(15, 32'h0090_0813); // addi x16,x0,9
        write_word(16, 32'h1902_28af); // sc.w x17,x16,(x4): success, mem=9
        write_word(17, 32'h0002_2903); // lw x18,0(x4): 9
        write_word(18, 32'h0039_0513); // addi x10,x18,3: 12
        write_word(19, 32'h0612_2c2f); // amoadd.w.aqrl x24,x1,(x4): old=9, mem=14
        write_word(20, 32'h0002_2c83); // lw x25,0(x4): 14
        // Signed right shifts must sign-extend. Linux printk width parsing relies
        // on srai of packed signed fields before the first S-mode console write.
        write_word(21, 32'hfff0_0993); // addi x19,x0,-1
        write_word(22, 32'h4089_da13); // srai x20,x19,8: 0xffffffff
        write_word(23, 32'h0080_0a93); // addi x21,x0,8
        write_word(24, 32'h4159_db33); // sra  x22,x19,x21: 0xffffffff
        write_word(25, 32'h0089_db93); // srli x23,x19,8: 0x00ffffff
        write_word(26, 32'h0010_0073); // ebreak

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 3000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("MIN_CORE_RESULT: FAIL timeout pc=%08h retired=%0d owner=%0d",
                     pc, retired, cluster_active_owner);
            $finish;
        end
        if (fault) begin
            $display("MIN_CORE_RESULT: FAIL fault cause=%0d tval=%08h pc=%08h retired=%0d",
                     fault_cause, fault_tval, pc, retired);
            $finish;
        end
        if (dbg_x3 != 32'd12 || dbg_x5 != 32'd12 ||
            dbg_x6 != 32'd0 || dbg_x10 != 32'd12 ||
            dut.regs[11] != 32'd35 || dut.regs[12] != 32'd7 ||
            dut.regs[13] != 32'd0 || dut.regs[14] != 32'd12 ||
            dut.regs[15] != 32'd17 || dut.regs[17] != 32'd0 ||
            dut.regs[18] != 32'd9 || dut.regs[20] != 32'hffff_ffff ||
            dut.regs[22] != 32'hffff_ffff || dut.regs[23] != 32'h00ff_ffff ||
            dut.regs[24] != 32'd9 || dut.regs[25] != 32'd14) begin
            $display("MIN_CORE_RESULT: FAIL regs x3=%0d x5=%0d x6=%0d x10=%0d x11=%0d x12=%0d x13=%0d x14=%0d x15=%0d x17=%0d x18=%0d x20=%08h x22=%08h x23=%08h x24=%0d x25=%0d pc=%08h retired=%0d",
                     dbg_x3, dbg_x5, dbg_x6, dbg_x10, dut.regs[11],
                     dut.regs[12], dut.regs[13], dut.regs[14],
                     dut.regs[15], dut.regs[17], dut.regs[18],
                     dut.regs[20], dut.regs[22], dut.regs[23],
                     dut.regs[24], dut.regs[25], pc, retired);
            $finish;
        end
        if (pc != 32'h0000_0068 || retired != 32'd26) begin
            $display("MIN_CORE_RESULT: FAIL final pc=%08h retired=%0d",
                     pc, retired);
            $finish;
        end

        $display("MIN_CORE_RESULT: PASS retired=%0d pc=%08h ihit=%0d imiss=%0d dhit=%0d dmiss=%0d",
                 retired, pc, i_hits, i_misses, d_hits, d_misses);
        $finish;
    end
endmodule
