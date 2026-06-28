`timescale 1ns/1ps
module tb_ptw_dcache;
    localparam I_LINES = 16;
    localparam D_LINES = 16;
    localparam WORDS   = 4;
    localparam LAT     = 5;
    localparam MEMWORDS = 1<<14;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         i_req = 0;
    reg  [31:0] i_addr = 0;
    wire [31:0] i_rdata;
    wire        i_ready;

    reg         d_req = 0, d_we = 0;
    reg  [31:0] d_addr = 0, d_wdata = 0;
    reg  [3:0]  d_be = 4'hF;
    wire [31:0] d_rdata;
    wire        d_ready;

    reg         ptw_start = 0;
    reg  [31:0] ptw_satp = 0;
    reg  [31:0] ptw_va = 0;
    reg  [1:0]  ptw_access = 0, ptw_priv = 0;
    reg         ptw_sum = 0, ptw_mxr = 0;
    wire        ptw_busy, ptw_done, ptw_fault, ptw_set_a, ptw_set_d;
    wire [3:0]  ptw_cause;
    wire [31:0] ptw_pa, ptw_leaf_pte, ptw_leaf_pte_pa;
    wire        ptw_m_req, ptw_m_we, ptw_m_ack;
    wire [31:0] ptw_m_addr, ptw_m_wdata, ptw_m_rdata;

    wire [31:0] i_hits, i_misses, d_hits, d_misses;
    wire        backing_req, backing_we, backing_ack;
    wire [31:0] backing_addr;

    l1_mem_system #(
        .I_LINES(I_LINES), .D_LINES(D_LINES), .WORDS(WORDS), .MEMW(MEMWORDS), .LAT(LAT)
    ) memsys (
        .clk(clk), .rst(rst),
        .i_req(i_req), .i_addr(i_addr), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .ptw_req(ptw_m_req), .ptw_we(ptw_m_we), .ptw_addr(ptw_m_addr),
        .ptw_wdata(ptw_m_wdata), .ptw_be(4'hF), .ptw_rdata(ptw_m_rdata), .ptw_ready(ptw_m_ack),
        .i_hits(i_hits), .i_misses(i_misses), .d_hits(d_hits), .d_misses(d_misses),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    sv32_ptw #(.MEMWORDS(MEMWORDS), .RAMBASE(32'h0000_0000)) ptw (
        .clk(clk), .rst(rst),
        .start(ptw_start), .satp(ptw_satp), .va(ptw_va), .access(ptw_access),
        .priv(ptw_priv), .sum(ptw_sum), .mxr(ptw_mxr),
        .busy(ptw_busy), .done(ptw_done), .fault(ptw_fault), .cause(ptw_cause),
        .pa(ptw_pa), .leaf_pte(ptw_leaf_pte), .leaf_pte_pa(ptw_leaf_pte_pa),
        .set_a(ptw_set_a), .set_d(ptw_set_d),
        .m_req(ptw_m_req), .m_we(ptw_m_we), .m_addr(ptw_m_addr), .m_wdata(ptw_m_wdata),
        .m_rdata(ptw_m_rdata), .m_ack(ptw_m_ack)
    );

    integer fails = 0;
    integer backing_reads = 0, backing_writes = 0;
    integer reads_before = 0, writes_before = 0, hits_before = 0;
    reg [31:0] cap_d;

    always @(posedge clk) begin
        if (backing_ack && backing_we) backing_writes <= backing_writes + 1;
        if (backing_ack && !backing_we) backing_reads <= backing_reads + 1;
    end

    function [31:0] pte(input [31:0] ppn, input [7:0] flags);
        pte = (ppn << 10) | flags;
    endfunction

    task chk(input cond, input [319:0] name);
        begin
            if (!cond) begin
                $display("FAIL %0s", name);
                fails = fails + 1;
            end else begin
                $display("ok   %0s", name);
            end
        end
    endtask

    task d_write(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            d_addr = addr;
            d_wdata = data;
            d_be = 4'hF;
            d_we = 1'b1;
            d_req = 1'b1;
            while (!d_ready) @(negedge clk);
            @(negedge clk);
            d_req = 1'b0;
            d_we = 1'b0;
            @(negedge clk);
        end
    endtask

    task d_read(input [31:0] addr, output [31:0] got);
        begin
            @(negedge clk);
            d_addr = addr;
            d_wdata = 32'd0;
            d_be = 4'hF;
            d_we = 1'b0;
            d_req = 1'b1;
            while (!d_ready) @(negedge clk);
            got = d_rdata;
            @(negedge clk);
            d_req = 1'b0;
            @(negedge clk);
        end
    endtask

    task walk(input [31:0] satp_i, input [31:0] va_i);
        begin
            @(negedge clk);
            ptw_satp = satp_i;
            ptw_va = va_i;
            ptw_access = 2'd0;
            ptw_priv = 2'd1;
            ptw_sum = 1'b0;
            ptw_mxr = 1'b0;
            ptw_start = 1'b1;
            @(negedge clk);
            ptw_start = 1'b0;
            while (!ptw_done) @(negedge clk);
            @(negedge clk);
        end
    endtask

    localparam [31:0] ROOT_PTE_PA = 32'h0000_1004; // SATP PPN=1, VPN1=1
    localparam [31:0] LEAF_PTE_PA = 32'h0000_203C; // L0 PPN=2, VPN0=15
    localparam [31:0] VA          = 32'h0040_F234;
    localparam [31:0] SATP_ROOT   = 32'h8000_0001;
    localparam [31:0] ROOT_PTE    = (32'h0000_0002 << 10) | 32'h001;
    localparam [31:0] LEAF_PTE    = (32'h0000_0030 << 10) | 32'h0CF;

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        d_write(ROOT_PTE_PA, ROOT_PTE);
        d_write(LEAF_PTE_PA, LEAF_PTE);
        d_read(ROOT_PTE_PA, cap_d);
        chk(cap_d == ROOT_PTE, "d_side_dirty_root_pte");
        d_read(LEAF_PTE_PA, cap_d);
        chk(cap_d == LEAF_PTE, "d_side_dirty_leaf_pte");

        reads_before = backing_reads;
        writes_before = backing_writes;
        hits_before = d_hits;

        walk(SATP_ROOT, VA);
        chk(!ptw_fault && ptw_pa == 32'h0003_0234, "ptw_walks_dirty_dcache_ptes");
        chk(ptw_leaf_pte == LEAF_PTE && ptw_leaf_pte_pa == LEAF_PTE_PA, "ptw_returns_dirty_leaf");
        chk(backing_reads == reads_before, "ptw_no_backing_read_on_dirty_hits");
        chk(backing_writes == writes_before, "ptw_no_dirty_writeback_needed");
        chk(d_hits >= hits_before + 2, "ptw_reads_hit_dcache");

        $display("ptw_dcache stats: d_hits=%0d d_misses=%0d backing_reads=%0d backing_writes=%0d",
                 d_hits, d_misses, backing_reads, backing_writes);
        if (fails == 0) $display("PTW_DCACHE_RESULT: PASS");
        else            $display("PTW_DCACHE_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
