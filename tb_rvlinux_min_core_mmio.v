`timescale 1ns/1ps

module tb_rvlinux_min_core_mmio;
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

    reg uart_seen = 1'b0;
    reg [7:0] uart_byte = 8'd0;
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

    always @(negedge clk) begin
        if (uart_we) begin
            uart_seen <= 1'b1;
            uart_byte <= uart_data;
        end
    end

    task write_word;
        input integer index;
        input [31:0] value;
        begin
            dut.cluster.mem.memsys.backing.mem[index] = value;
        end
    endtask

    initial begin
        #1;
        write_word(0, 32'h1000_0237); // lui  x4,0x10000
        write_word(1, 32'h0410_0293); // addi x5,x0,65
        write_word(2, 32'h0052_0023); // sb   x5,0(x4)
        write_word(3, 32'h0052_4303); // lbu  x6,5(x4)
        write_word(4, 32'h0003_0513); // addi x10,x6,0
        write_word(5, 32'h1110_03b7); // lui  x7,0x11100
        write_word(6, 32'h0000_5437); // lui  x8,0x5
        write_word(7, 32'h5554_0413); // addi x8,x8,0x555 -> 0x5555
        write_word(8, 32'h0083_a023); // sw   x8,0(x7)
        write_word(9, 32'h0010_0073); // ebreak, must not be reached

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 3000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("MIN_CORE_MMIO_RESULT: FAIL timeout pc=%08h retired=%0d owner=%0d",
                     pc, retired, cluster_active_owner);
            $finish;
        end
        if (fault) begin
            $display("MIN_CORE_MMIO_RESULT: FAIL fault cause=%0d tval=%08h pc=%08h retired=%0d",
                     fault_cause, fault_tval, pc, retired);
            $finish;
        end
        if (!uart_seen || uart_byte != 8'h41) begin
            $display("MIN_CORE_MMIO_RESULT: FAIL uart_seen=%0d uart_byte=%02h",
                     uart_seen, uart_byte);
            $finish;
        end
        if (dbg_x6 != 32'h0000_0060 || dbg_x10 != 32'h0000_0060) begin
            $display("MIN_CORE_MMIO_RESULT: FAIL x6=%08h x10=%08h",
                     dbg_x6, dbg_x10);
            $finish;
        end
        if (exit_code != 32'd0 || pc != 32'h0000_0024 || retired != 32'd9) begin
            $display("MIN_CORE_MMIO_RESULT: FAIL exit=%0d pc=%08h retired=%0d",
                     exit_code, pc, retired);
            $finish;
        end

        $display("MIN_CORE_MMIO_RESULT: PASS retired=%0d pc=%08h uart=%02h exit=%0d",
                 retired, pc, uart_byte, exit_code);
        $finish;
    end
endmodule
