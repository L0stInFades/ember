`timescale 1ns/1ps
module tb_rvlinux_mem_boundary;
    localparam I_LINES  = 16;
    localparam D_LINES  = 16;
    localparam WORDS    = 4;
    localparam LAT      = 5;
    localparam MEMWORDS = 1<<14;

    localparam ACC_FETCH = 2'd0;
    localparam ACC_LOAD  = 2'd1;
    localparam ACC_STORE = 2'd2;
    localparam ACC_TRANSLATE_ONLY = 2'd3;
    localparam PRV_S     = 2'd1;
    localparam PRV_M     = 2'd3;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         req = 0;
    reg  [1:0]  access = 0;
    reg  [31:0] va = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  be = 4'hF;
    reg  [31:0] satp = 0;
    reg  [1:0]  priv = PRV_M;
    reg         sum = 0, mxr = 0;
    reg         tlb_flush = 0;

    wire [31:0] rdata;
    wire        ready;
    wire        fault;
    wire [3:0]  cause;
    wire [31:0] pa;
    wire        busy;
    wire [31:0] i_hits, i_misses, d_hits, d_misses, ad_writes;
    wire        backing_req, backing_we, backing_ack;
    wire [31:0] backing_addr;

    rvlinux_mem_boundary #(
        .I_LINES(I_LINES), .D_LINES(D_LINES), .WORDS(WORDS),
        .MEMWORDS(MEMWORDS), .LAT(LAT), .RAMBASE(32'h0000_0000)
    ) dut (
        .clk(clk), .rst(rst),
        .core_req(req), .core_access(access), .core_va(va),
        .core_wdata(wdata), .core_be(be), .satp(satp), .priv(priv),
        .sum(sum), .mxr(mxr), .tlb_flush(tlb_flush),
        .core_rdata(rdata), .core_ready(ready), .core_fault(fault),
        .core_cause(cause), .core_pa(pa), .core_busy(busy),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    integer fails = 0;
    integer cyc = 0;
    integer backing_reads = 0, backing_writes = 0;
    integer reads_before = 0;
    integer ptw_starts = 0;
    integer ptw_starts_before = 0;
    reg [31:0] cap_rdata, cap_pa;
    reg        cap_fault;
    reg [3:0]  cap_cause;

    localparam [31:0] SATP_ROOT   = 32'h8000_0001;
    localparam [31:0] ROOT_PTE_PA = 32'h0000_1004; // SATP PPN=1, VPN1=1
    localparam [31:0] LEAF_PTE_PA = 32'h0000_203C; // L0 PPN=2, VPN0=15
    localparam [31:0] VA_OK       = 32'h0040_F254;
    localparam [31:0] VA_BAD      = 32'h0080_0000;
    localparam [31:0] DATA_PA     = 32'h0003_0254;
    localparam [31:0] DATA_PA2    = 32'h0003_1254;
    localparam [31:0] ROOT_PTE    = (32'h0000_0002 << 10) | 32'h001;
    localparam [31:0] LEAF_PTE    = (32'h0000_0030 << 10) | 32'h00F; // V/R/W/X, A/D clear
    localparam [31:0] LEAF_PTE2   = (32'h0000_0031 << 10) | 32'h00F; // same VA remapped

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (backing_ack && backing_we) backing_writes <= backing_writes + 1;
        if (backing_ack && !backing_we) backing_reads <= backing_reads + 1;
        if (dut.ptw_start) ptw_starts <= ptw_starts + 1;
        if (cyc > 20000) begin
            $display("FAIL watchdog timeout");
            $display("MEM_BOUNDARY_RESULT: FAIL (timeout)");
            $finish;
        end
    end

    function [31:0] refv(input [31:0] a);
        refv = (a & 32'hFFFF_FFFC) ^ 32'hA5A5_0000;
    endfunction

    task chk(input cond, input [383:0] name);
        begin
            if (!cond) begin
                $display("FAIL %0s", name);
                fails = fails + 1;
            end else begin
                $display("ok   %0s", name);
            end
        end
    endtask

    task memop(
        input [1:0]  acc_i,
        input [31:0] satp_i,
        input [1:0]  priv_i,
        input [31:0] va_i,
        input [31:0] wdata_i,
        input [3:0]  be_i,
        output [31:0] got_rdata,
        output        got_fault,
        output [3:0]  got_cause,
        output [31:0] got_pa
    );
        begin
            @(negedge clk);
            access = acc_i;
            satp = satp_i;
            priv = priv_i;
            va = va_i;
            wdata = wdata_i;
            be = be_i;
            sum = 1'b0;
            mxr = 1'b0;
            req = 1'b1;
            while (!ready) @(negedge clk);
            got_rdata = rdata;
            got_fault = fault;
            got_cause = cause;
            got_pa = pa;
            @(negedge clk);
            req = 1'b0;
            @(negedge clk);
        end
    endtask

    task flush_tlb;
        begin
            @(negedge clk);
            tlb_flush = 1'b1;
            @(negedge clk);
            tlb_flush = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        memop(ACC_STORE, 32'd0, PRV_M, ROOT_PTE_PA, ROOT_PTE, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == ROOT_PTE_PA, "bare_store_root_pte");
        memop(ACC_STORE, 32'd0, PRV_M, LEAF_PTE_PA, LEAF_PTE, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == LEAF_PTE_PA, "bare_store_leaf_pte");

        reads_before = backing_reads;
        memop(ACC_FETCH, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'h0,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "translated_fetch_pa");
        chk(cap_rdata == refv(DATA_PA), "translated_fetch_reads_icache");
        chk(ad_writes == 1, "fetch_sets_accessed_bit");
        chk(backing_reads == reads_before + WORDS, "fetch_ptw_hits_dirty_pte_cache");

        memop(ACC_LOAD, 32'd0, PRV_M, LEAF_PTE_PA, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(cap_rdata == (LEAF_PTE | 32'h0000_0040), "leaf_pte_accessed_visible");

        reads_before = backing_reads;
        ptw_starts_before = ptw_starts;
        memop(ACC_FETCH, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'h0,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_rdata == refv(DATA_PA), "translated_fetch_hits_icache");
        chk(backing_reads == reads_before, "fetch_hit_no_backing_read");
        chk(ptw_starts == ptw_starts_before, "fetch_tlb_hit_skips_ptw");

        memop(ACC_STORE, 32'd0, PRV_M, DATA_PA, 32'hCAFE_BABE, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "bare_store_data_word");

        reads_before = backing_reads;
        memop(ACC_LOAD, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_rdata == 32'hCAFE_BABE, "translated_load_sees_dirty_dcache");
        chk(ad_writes == 1, "load_does_not_rewrite_clean_a_bit");
        chk(backing_reads == reads_before, "load_ptw_and_data_hit_cache");

        memop(ACC_STORE, SATP_ROOT, PRV_S, VA_OK, 32'h1234_5678, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "translated_store_pa");
        chk(ad_writes == 2, "store_sets_dirty_bit");

        memop(ACC_LOAD, 32'd0, PRV_M, LEAF_PTE_PA, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(cap_rdata == (LEAF_PTE | 32'h0000_00C0), "leaf_pte_ad_visible");
        memop(ACC_LOAD, 32'd0, PRV_M, DATA_PA, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(cap_rdata == 32'h1234_5678, "translated_store_visible");

        memop(ACC_STORE, 32'd0, PRV_M, LEAF_PTE_PA, LEAF_PTE, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault, "reset_leaf_pte_ad_for_store_check");
        flush_tlb();
        memop(ACC_TRANSLATE_ONLY, SATP_ROOT, PRV_S, VA_OK, 32'hDEAD_BEEF, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "store_check_translates_store_permission");
        chk(ad_writes == 3, "store_check_sets_accessed_and_dirty");
        memop(ACC_LOAD, 32'd0, PRV_M, DATA_PA, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(cap_rdata == 32'h1234_5678, "store_check_does_not_write_data");

        memop(ACC_STORE, 32'd0, PRV_M, LEAF_PTE_PA, LEAF_PTE, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault, "reset_leaf_pte_ad_for_load_translate");
        flush_tlb();
        memop(ACC_TRANSLATE_ONLY, SATP_ROOT, PRV_S, VA_OK, 32'hDEAD_BEEF, 4'h0,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "load_translate_translates_load_permission");
        chk(ad_writes == 4, "load_translate_sets_accessed_only");
        ptw_starts_before = ptw_starts;
        memop(ACC_LOAD, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_rdata == 32'h1234_5678, "load_translate_tlb_load_data");
        chk(ptw_starts == ptw_starts_before, "load_translate_tlb_hit_skips_ptw");
        memop(ACC_LOAD, 32'd0, PRV_M, LEAF_PTE_PA, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(cap_rdata == (LEAF_PTE | 32'h0000_0040), "load_translate_leaf_pte_a_visible");
        memop(ACC_LOAD, 32'd0, PRV_M, DATA_PA, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(cap_rdata == 32'h1234_5678, "load_translate_does_not_read_or_write_data");
        memop(ACC_FETCH, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'h0,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "remap_refill_old_itlb");
        chk(cap_rdata == refv(DATA_PA), "remap_refill_old_itlb_fetch_data");

        memop(ACC_STORE, 32'd0, PRV_M, DATA_PA, 32'h0BAD_F00D, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "remap_old_pa_seed");
        memop(ACC_STORE, 32'd0, PRV_M, DATA_PA2, 32'h600D_CAFE, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA2, "remap_new_pa_seed");
        memop(ACC_STORE, 32'd0, PRV_M, LEAF_PTE_PA, LEAF_PTE2, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault, "remap_leaf_without_flush");

        ptw_starts_before = ptw_starts;
        memop(ACC_LOAD, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "stale_dtlb_uses_old_pa_without_flush");
        chk(cap_rdata == 32'h0BAD_F00D, "stale_dtlb_load_reads_old_pa");
        memop(ACC_FETCH, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'h0,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA, "stale_itlb_uses_old_pa_without_flush");
        chk(cap_rdata == refv(DATA_PA), "stale_itlb_fetch_reads_old_pa");
        chk(ptw_starts == ptw_starts_before, "stale_tlb_no_ptw_before_flush");

        flush_tlb();
        memop(ACC_LOAD, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA2, "flush_dtlb_sees_remapped_pa");
        chk(cap_rdata == 32'h600D_CAFE, "flush_dtlb_load_reads_new_pa");
        chk(ad_writes == 5, "flush_remap_load_sets_accessed");
        memop(ACC_FETCH, SATP_ROOT, PRV_S, VA_OK, 32'd0, 4'h0,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(!cap_fault && cap_pa == DATA_PA2, "flush_itlb_sees_remapped_pa");
        chk(cap_rdata == refv(DATA_PA2), "flush_itlb_fetch_reads_new_pa");
        memop(ACC_LOAD, 32'd0, PRV_M, LEAF_PTE_PA, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(cap_rdata == (LEAF_PTE2 | 32'h0000_0040), "remap_leaf_pte_a_visible");

        memop(ACC_LOAD, SATP_ROOT, PRV_S, VA_BAD, 32'd0, 4'hF,
              cap_rdata, cap_fault, cap_cause, cap_pa);
        chk(cap_fault && cap_cause == 4'd13, "bad_mapping_load_fault");

        chk(i_hits != 0 && i_misses != 0, "icache_exercised");
        chk(d_hits != 0 && d_misses != 0, "dcache_exercised");

        $display("mem_boundary stats: i_hits=%0d i_misses=%0d d_hits=%0d d_misses=%0d ad_writes=%0d backing_reads=%0d backing_writes=%0d",
                 i_hits, i_misses, d_hits, d_misses, ad_writes, backing_reads, backing_writes);
        if (fails == 0) $display("MEM_BOUNDARY_RESULT: PASS");
        else            $display("MEM_BOUNDARY_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
