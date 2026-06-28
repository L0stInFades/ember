`timescale 1ns/1ps

module tb_rvlinux_min_core_ebreak_trap;
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
    wire [31:0] dbg_mcause;
    wire [31:0] dbg_scause;
    wire [31:0] dbg_mip;
    wire [31:0] dbg_mie;
    wire [31:0] dbg_stval;
    wire [31:0] dbg_mtime;
    wire [31:0] dbg_mtimecmp;
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
        .RAMBASE(32'h0000_0000),
        .EBREAK_HALTS(0)
    ) dut (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in),
        .rx_ready(rx_ready), .uart_we(uart_we), .uart_data(uart_data),
        .halt(halt), .exit_code(exit_code),
        .fault(fault), .fault_cause(fault_cause),
        .fault_tval(fault_tval), .pc(pc), .retired(retired),
        .dbg_x3(dbg_x3), .dbg_x5(dbg_x5), .dbg_x6(dbg_x6),
        .dbg_x10(dbg_x10), .dbg_priv(dbg_priv),
        .dbg_mcause(dbg_mcause), .dbg_scause(dbg_scause),
        .dbg_mip(dbg_mip), .dbg_mie(dbg_mie),
        .dbg_stval(dbg_stval), .dbg_mtime(dbg_mtime),
        .dbg_mtimecmp(dbg_mtimecmp),
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

        write_word(0,  32'h0800_0093); // addi x1,x0,0x80
        write_word(1,  32'h3050_9073); // csrw mtvec,x1
        write_word(2,  32'h0010_0073); // ebreak, must trap when EBREAK_HALTS=0
        write_word(3,  32'h0550_0513); // addi x10,x0,0x55, must not execute

        // M-mode handler at 0x80: expose mcause/mepc, then halt through syscon.
        write_word(32, 32'h3420_2573); // csrr x10,mcause
        write_word(33, 32'h3410_21f3); // csrr x3,mepc
        write_word(34, 32'h1110_03b7); // lui  x7,0x11100
        write_word(35, 32'h0000_5437); // lui  x8,0x5
        write_word(36, 32'h5554_0413); // addi x8,x8,0x555 -> 0x5555
        write_word(37, 32'h0083_a023); // sw   x8,0(x7)

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 5000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("MIN_CORE_EBREAK_TRAP_RESULT: FAIL timeout pc=%08h priv=%0d retired=%0d owner=%0d",
                     pc, dbg_priv, retired, cluster_active_owner);
            $finish;
        end
        if (fault) begin
            $display("MIN_CORE_EBREAK_TRAP_RESULT: FAIL fatal fault cause=%0d tval=%08h pc=%08h",
                     fault_cause, fault_tval, pc);
            $finish;
        end
        if (exit_code != 32'd0 || pc != 32'h0000_0098 ||
            dbg_priv != 2'd3 || dbg_x10 != 32'd3 ||
            dbg_x3 != 32'h0000_0008 ||
            dbg_mcause != 32'd3 || dut.csr.mepc_out != 32'h0000_0008 ||
            dbg_scause != 32'd0 || dbg_stval != 32'd0) begin
            $display("MIN_CORE_EBREAK_TRAP_RESULT: FAIL pc=%08h priv=%0d x3=%08h x10=%08h mcause=%08h mepc=%08h scause=%08h stval=%08h exit=%0d retired=%0d",
                     pc, dbg_priv, dbg_x3, dbg_x10, dbg_mcause,
                     dut.csr.mepc_out, dbg_scause, dbg_stval, exit_code,
                     retired);
            $finish;
        end

        $display("MIN_CORE_EBREAK_TRAP_RESULT: PASS pc=%08h priv=%0d mcause=%08h mepc=%08h retired=%0d",
                 pc, dbg_priv, dbg_mcause, dut.csr.mepc_out, retired);
        $finish;
    end
endmodule
