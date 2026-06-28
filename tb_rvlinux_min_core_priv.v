`timescale 1ns/1ps

module tb_rvlinux_min_core_priv;
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
    wire [1:0] dbg_priv;
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
        .dbg_x10(dbg_x10), .dbg_priv(dbg_priv),
        .cluster_busy(cluster_busy),
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
        // M-mode setup: delegate U ECALL, set S trap/entry state, then MRET.
        write_word(0,  32'h1000_0093); // addi x1,x0,0x100
        write_word(1,  32'h3050_9073); // csrw mtvec,x1
        write_word(2,  32'h3020_9073); // csrw medeleg,x1 (delegate cause 8)
        write_word(3,  32'h0800_0093); // addi x1,x0,0x80
        write_word(4,  32'h1050_9073); // csrw stvec,x1
        write_word(5,  32'h0400_0093); // addi x1,x0,0x40
        write_word(6,  32'h3410_9073); // csrw mepc,x1
        write_word(7,  32'h0000_10b7); // lui x1,0x1
        write_word(8,  32'h8800_8093); // addi x1,x1,-1920 -> 0x880
        write_word(9,  32'h3000_9073); // csrw mstatus,x1 (MPP=S, MPIE=1)
        write_word(10, 32'h3020_0073); // mret

        write_word(11, 32'h0000_0013);
        write_word(12, 32'h0000_0013);
        write_word(13, 32'h0000_0013);
        write_word(14, 32'h0000_0013);
        write_word(15, 32'h0000_0013);

        // S-mode entry at 0x40: set U entry and SRET into U-mode.
        write_word(16, 32'h0600_0093); // addi x1,x0,0x60
        write_word(17, 32'h1410_9073); // csrw sepc,x1
        write_word(18, 32'h0200_0093); // addi x1,x0,0x20
        write_word(19, 32'h1000_9073); // csrw sstatus,x1 (SPIE=1, SPP=0)
        write_word(20, 32'h1020_0073); // sret

        write_word(21, 32'h0000_0013);
        write_word(22, 32'h0000_0013);
        write_word(23, 32'h0000_0013);

        // U-mode at 0x60: execute a delegated ECALL.
        write_word(24, 32'h0070_0213); // addi x4,x0,7
        write_word(25, 32'h0000_0073); // ecall
        write_word(26, 32'h0000_0013);
        write_word(27, 32'h0000_0013);
        write_word(28, 32'h0000_0013);
        write_word(29, 32'h0000_0013);
        write_word(30, 32'h0000_0013);
        write_word(31, 32'h0000_0013);

        // S-mode handler at 0x80: read scause/sepc, set x10, then halt.
        write_word(32, 32'h1420_2173); // csrr x2,scause
        write_word(33, 32'h1410_21f3); // csrr x3,sepc
        write_word(34, 32'h0041_0513); // addi x10,x2,4
        write_word(35, 32'h0010_0073); // ebreak

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 5000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("PRIV_CORE_RESULT: FAIL timeout pc=%08h retired=%0d priv=%0d owner=%0d",
                     pc, retired, dbg_priv, cluster_active_owner);
            $finish;
        end
        if (fault) begin
            $display("PRIV_CORE_RESULT: FAIL fault cause=%0d tval=%08h pc=%08h retired=%0d priv=%0d",
                     fault_cause, fault_tval, pc, retired, dbg_priv);
            $finish;
        end
        if (dbg_priv != 2'd1 || pc != 32'h0000_008c || retired != 32'd20 ||
            dut.regs[2] != 32'd8 || dut.regs[3] != 32'h0000_0064 ||
            dut.regs[4] != 32'd7 || dbg_x10 != 32'd12) begin
            $display("PRIV_CORE_RESULT: FAIL pc=%08h retired=%0d priv=%0d x2=%08h x3=%08h x4=%08h x10=%08h scause=%08h sepc=%08h",
                     pc, retired, dbg_priv, dut.regs[2], dut.regs[3],
                     dut.regs[4], dbg_x10, dut.csr.scause_out, dut.csr.sepc_out);
            $finish;
        end

        $display("PRIV_CORE_RESULT: PASS retired=%0d pc=%08h priv=%0d ihit=%0d imiss=%0d",
                 retired, pc, dbg_priv, i_hits, i_misses);
        $finish;
    end
endmodule
