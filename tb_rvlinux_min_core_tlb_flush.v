`timescale 1ns/1ps

module tb_rvlinux_min_core_tlb_flush;
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
    integer tlb_flushes = 0;
    integer satp_flushes = 0;
    integer sfence_flushes = 0;
    integer data_ptw_starts = 0;
    integer code_ptw_starts = 0;

    localparam [31:0] ROOT_PTE = 32'h0000_0801; // PPN=2, V
    localparam [31:0] CODE_PTE = 32'h0000_000f; // PA 0x00000000, V/R/W/X
    localparam [31:0] DATA_PTE = 32'h0000_0c07; // PA 0x00003000, V/R/W

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

    always @(posedge clk) begin
        if (!rst && dut.tlb_flush) begin
            tlb_flushes <= tlb_flushes + 1;
            if (dut.ex_is_csr_r && dut.ex_csr_addr_r == 12'h180)
                satp_flushes <= satp_flushes + 1;
            if (dut.ex_is_sfence_r)
                sfence_flushes <= sfence_flushes + 1;
        end
        if (!rst && dut.cluster.mem.ptw_start) begin
            if (dut.cluster.mem.va_r == 32'h0000_3000)
                data_ptw_starts <= data_ptw_starts + 1;
            if (dut.cluster.mem.va_r[31:12] == 20'h00000)
                code_ptw_starts <= code_ptw_starts + 1;
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

        // M-mode setup: write satp, then MRET into S-mode at VA 0x40.
        write_word(0,  32'h0400_0093); // addi x1,x0,0x40
        write_word(1,  32'h3410_9073); // csrw mepc,x1
        write_word(2,  32'h0000_10b7); // lui  x1,0x1
        write_word(3,  32'h8800_8093); // addi x1,x1,-1920 -> MPP=S, MPIE=1
        write_word(4,  32'h3000_9073); // csrw mstatus,x1
        write_word(5,  32'h8000_00b7); // lui  x1,0x80000
        write_word(6,  32'h0010_8093); // addi x1,x1,1 -> satp MODE=Sv32, root PPN=1
        write_word(7,  32'h1800_9073); // csrw satp,x1
        write_word(8,  32'h3020_0073); // mret

        // S-mode code: fill DTLB, execute SFENCE.VMA, then prove the next load
        // refills through the PTW instead of using the stale DTLB entry.
        write_word(16, 32'h0000_3237); // lui  x4,0x3       -> VA 0x00003000
        write_word(17, 32'h0002_2283); // lw   x5,0(x4)
        write_word(18, 32'h1200_0073); // sfence.vma
        write_word(19, 32'h0002_2303); // lw   x6,0(x4)
        write_word(20, 32'h0003_0513); // addi x10,x6,0
        write_word(21, 32'h0010_0073); // ebreak

        // Root page table at PA 0x1000, leaf table at PA 0x2000.
        write_word(32'h0000_1000 >> 2, ROOT_PTE);
        write_word(32'h0000_2000 >> 2, CODE_PTE);
        write_word(32'h0000_200c >> 2, DATA_PTE);
        write_word(32'h0000_3000 >> 2, 32'h1357_2468);

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 8000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("MIN_CORE_TLB_FLUSH_RESULT: FAIL timeout pc=%08h retired=%0d priv=%0d owner=%0d flushes=%0d data_ptw=%0d",
                     pc, retired, dbg_priv, cluster_active_owner, tlb_flushes, data_ptw_starts);
            $finish;
        end
        if (fault) begin
            $display("MIN_CORE_TLB_FLUSH_RESULT: FAIL fault cause=%0d tval=%08h pc=%08h retired=%0d priv=%0d",
                     fault_cause, fault_tval, pc, retired, dbg_priv);
            $finish;
        end
        if (dbg_priv != 2'd1 || dbg_x5 != 32'h1357_2468 ||
            dbg_x6 != 32'h1357_2468 || dbg_x10 != 32'h1357_2468) begin
            $display("MIN_CORE_TLB_FLUSH_RESULT: FAIL regs priv=%0d x5=%08h x6=%08h x10=%08h pc=%08h retired=%0d",
                     dbg_priv, dbg_x5, dbg_x6, dbg_x10, pc, retired);
            $finish;
        end
        if (tlb_flushes != 2 || satp_flushes != 1 || sfence_flushes != 1 ||
            data_ptw_starts != 2 || code_ptw_starts < 2 || ad_writes < 2) begin
            $display("MIN_CORE_TLB_FLUSH_RESULT: FAIL flushes=%0d satp=%0d sfence=%0d data_ptw=%0d code_ptw=%0d ad_writes=%0d pc=%08h retired=%0d",
                     tlb_flushes, satp_flushes, sfence_flushes, data_ptw_starts,
                     code_ptw_starts, ad_writes, pc, retired);
            $finish;
        end

        $display("MIN_CORE_TLB_FLUSH_RESULT: PASS retired=%0d pc=%08h flushes=%0d satp=%0d sfence=%0d data_ptw=%0d code_ptw=%0d ad_writes=%0d",
                 retired, pc, tlb_flushes, satp_flushes, sfence_flushes,
                 data_ptw_starts, code_ptw_starts, ad_writes);
        $finish;
    end
endmodule
