`timescale 1ns/1ps

module tb_rvlinux_min_core_mprv;
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
        .MEMWORDS(4096),
        .LAT(4),
        .RAMBASE(32'h0000_0000)
    ) dut (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in),
        .rx_ready(rx_ready), .uart_we(uart_we), .uart_data(uart_data),
        .halt(halt), .exit_code(exit_code),
        .fault(fault), .fault_cause(fault_cause),
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

        // M-mode setup: enable Sv32 and then make data accesses use S-mode
        // permissions via MPRV=1, MPP=S. The following LW must fault on a U page
        // because SUM remains clear.
        write_word(0,  32'h0800_0093); // addi x1,x0,0x80
        write_word(1,  32'h3050_9073); // csrw mtvec,x1
        write_word(2,  32'h8000_00b7); // lui  x1,0x80000
        write_word(3,  32'h0010_8093); // addi x1,x1,1 -> satp MODE=Sv32, root PPN=1
        write_word(4,  32'h1800_9073); // csrw satp,x1
        write_word(5,  32'h0002_10b7); // lui  x1,0x21
        write_word(6,  32'h8000_8093); // addi x1,x1,-2048 -> MPRV=1, MPP=S
        write_word(7,  32'h3000_9073); // csrw mstatus,x1
        write_word(8,  32'h0000_1237); // lui  x4,0x1 -> VA 0x1000
        write_word(9,  32'h0002_2283); // lw   x5,0(x4), should fault with cause 13
        write_word(10, 32'h0550_0513); // addi x10,x0,0x55, must not execute
        write_word(11, 32'h0010_0073); // ebreak, must not be reached

        // M-mode trap handler at 0x80: expose mcause/mtval in x10/x3, then halt.
        write_word(32, 32'h3420_2173); // csrr x2,mcause
        write_word(33, 32'h3430_21f3); // csrr x3,mtval
        write_word(34, 32'h0001_0513); // addi x10,x2,0
        write_word(35, 32'h0010_0073); // ebreak

        // Root page table at PA 0x1000, leaf table at PA 0x2000.
        write_word(32'h0000_1000 >> 2, 32'h0000_0801); // PPN=2, V
        write_word(32'h0000_2004 >> 2, 32'h0000_0c17); // VA 0x1000 -> U R/W PA 0x3000
        write_word(32'h0000_3000 >> 2, 32'h1357_2468);

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 5000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("MIN_CORE_MPRV_RESULT: FAIL timeout pc=%08h retired=%0d priv=%0d owner=%0d",
                     pc, retired, dbg_priv, cluster_active_owner);
            $finish;
        end
        if (fault) begin
            $display("MIN_CORE_MPRV_RESULT: FAIL fatal fault cause=%0d tval=%08h pc=%08h",
                     fault_cause, fault_tval, pc);
            $finish;
        end
        if (dbg_priv != 2'd3 || pc != 32'h0000_008c ||
            dut.regs[2] != 32'd13 || dut.regs[3] != 32'h0000_1000 ||
            dbg_x5 != 32'd0 || dbg_x10 != 32'd13 ||
            dut.csr.mcause_out != 32'd13 ||
            dut.csr.mtval_out != 32'h0000_1000) begin
            $display("MIN_CORE_MPRV_RESULT: FAIL pc=%08h priv=%0d x2=%08h x3=%08h x5=%08h x10=%08h mcause=%08h mtval=%08h retired=%0d",
                     pc, dbg_priv, dut.regs[2], dut.regs[3], dbg_x5,
                     dbg_x10, dut.csr.mcause_out, dut.csr.mtval_out, retired);
            $finish;
        end

        $display("MIN_CORE_MPRV_RESULT: PASS pc=%08h priv=%0d mcause=%08h mtval=%08h retired=%0d",
                 pc, dbg_priv, dut.csr.mcause_out, dut.csr.mtval_out, retired);
        $finish;
    end
endmodule
