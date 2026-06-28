`timescale 1ns/1ps
module tb_rvlinux_lsu_stage;
    localparam I_LINES  = 16;
    localparam D_LINES  = 16;
    localparam WORDS    = 4;
    localparam LAT      = 5;
    localparam MEMWORDS = 1<<14;
    localparam PRV_M    = 2'd3;
    localparam PRV_S    = 2'd1;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         start = 0;
    reg         is_store = 0;
    reg  [2:0]  funct3 = 0;
    reg  [31:0] va = 0;
    reg  [31:0] store_data = 0;
    reg  [31:0] satp = 0;
    reg  [1:0]  priv = PRV_M;
    reg         sum = 0, mxr = 0;

    wire        done, busy, fault;
    wire [3:0]  cause;
    wire [31:0] fault_va, pa, load_data;

    wire        mem_req;
    wire [1:0]  mem_access;
    wire [31:0] mem_va, mem_wdata;
    wire [3:0]  mem_be;
    wire [31:0] mem_rdata, mem_pa;
    wire        mem_ready, mem_fault;
    wire [3:0]  mem_cause;

    wire [31:0] i_hits, i_misses, d_hits, d_misses, ad_writes;
    wire        backing_req, backing_we, backing_ack;
    wire [31:0] backing_addr;

    rvlinux_lsu_stage lsu (
        .clk(clk), .rst(rst),
        .start(start), .is_store(is_store), .funct3(funct3),
        .va(va), .store_data(store_data),
        .done(done), .busy(busy), .fault(fault), .cause(cause),
        .fault_va(fault_va), .pa(pa), .load_data(load_data),
        .mem_req(mem_req), .mem_access(mem_access), .mem_va(mem_va),
        .mem_wdata(mem_wdata), .mem_be(mem_be), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready), .mem_fault(mem_fault), .mem_cause(mem_cause),
        .mem_pa(mem_pa)
    );

    rvlinux_mem_boundary #(
        .I_LINES(I_LINES), .D_LINES(D_LINES), .WORDS(WORDS),
        .MEMWORDS(MEMWORDS), .LAT(LAT), .RAMBASE(32'h0000_0000)
    ) mem (
        .clk(clk), .rst(rst),
        .core_req(mem_req), .core_access(mem_access), .core_va(mem_va),
        .core_wdata(mem_wdata), .core_be(mem_be), .satp(satp), .priv(priv),
        .sum(sum), .mxr(mxr), .tlb_flush(1'b0),
        .core_rdata(mem_rdata), .core_ready(mem_ready), .core_fault(mem_fault),
        .core_cause(mem_cause), .core_pa(mem_pa), .core_busy(),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    integer fails = 0;
    integer cyc = 0;
    integer backing_reads = 0, backing_writes = 0;
    integer reads_before = 0, writes_before = 0;

    reg [31:0] got_load, got_pa, got_fault_va;
    reg        got_fault;
    reg [3:0]  got_cause;

    localparam [31:0] SATP_ROOT = 32'h8000_0001;
    localparam [31:0] ROOT_PTE  = (32'h0000_0002 << 10) | 32'h001;
    localparam [31:0] LEAF0_PTE = (32'h0000_0003 << 10) | 32'h007;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (backing_ack && backing_we) backing_writes <= backing_writes + 1;
        if (backing_ack && !backing_we) backing_reads <= backing_reads + 1;
        if (cyc > 30000) begin
            $display("FAIL watchdog timeout");
            $display("LSU_STAGE_RESULT: FAIL (timeout)");
            $finish;
        end
    end

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

    task lsu_once(
        input        store_i,
        input [2:0]  funct3_i,
        input [31:0] va_i,
        input [31:0] store_data_i,
        input [31:0] satp_i,
        input [1:0]  priv_i
    );
        begin
            @(negedge clk);
            is_store = store_i;
            funct3 = funct3_i;
            va = va_i;
            store_data = store_data_i;
            satp = satp_i;
            priv = priv_i;
            sum = 1'b0;
            mxr = 1'b0;
            start = 1'b1;
            while (!done) @(negedge clk);
            got_load = load_data;
            got_fault = fault;
            got_cause = cause;
            got_fault_va = fault_va;
            got_pa = pa;
            @(negedge clk);
            start = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        #1;
        mem.memsys.backing.mem[32'h0000_0100 >> 2] = 32'h80FF_7F01;
        mem.memsys.backing.mem[32'h0000_0104 >> 2] = 32'h1122_3344;
        mem.memsys.backing.mem[32'h0000_0108 >> 2] = 32'h0000_0000;
        mem.memsys.backing.mem[32'h0000_1000 >> 2] = ROOT_PTE;
        mem.memsys.backing.mem[32'h0000_2000 >> 2] = LEAF0_PTE;
        mem.memsys.backing.mem[32'h0000_2004 >> 2] = 32'h0000_0000;
        mem.memsys.backing.mem[32'h0000_3020 >> 2] = 32'hCAFE_BABE;
        mem.memsys.backing.mem[32'h0000_3024 >> 2] = 32'h0000_0000;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        lsu_once(1'b0, 3'b000, 32'h0000_0102, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_load == 32'hFFFF_FFFF, "lb_sign_extend");
        lsu_once(1'b0, 3'b100, 32'h0000_0103, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_load == 32'h0000_0080, "lbu_zero_extend");
        lsu_once(1'b0, 3'b001, 32'h0000_0102, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_load == 32'hFFFF_80FF, "lh_sign_extend");
        lsu_once(1'b0, 3'b101, 32'h0000_0100, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_load == 32'h0000_7F01, "lhu_zero_extend");

        lsu_once(1'b1, 3'b000, 32'h0000_0105, 32'h0000_00AA, 32'd0, PRV_M);
        chk(!got_fault && got_pa == 32'h0000_0105, "sb_success");
        lsu_once(1'b0, 3'b010, 32'h0000_0104, 32'd0, 32'd0, PRV_M);
        chk(got_load == 32'h1122_AA44, "sb_byte_enable_visible");
        lsu_once(1'b1, 3'b001, 32'h0000_0106, 32'h0000_BEEF, 32'd0, PRV_M);
        chk(!got_fault, "sh_success");
        lsu_once(1'b0, 3'b010, 32'h0000_0104, 32'd0, 32'd0, PRV_M);
        chk(got_load == 32'hBEEF_AA44, "sh_byte_enable_visible");
        lsu_once(1'b1, 3'b010, 32'h0000_0108, 32'h1234_5678, 32'd0, PRV_M);
        chk(!got_fault, "sw_success");
        lsu_once(1'b0, 3'b010, 32'h0000_0108, 32'd0, 32'd0, PRV_M);
        chk(got_load == 32'h1234_5678, "sw_visible");

        reads_before = backing_reads;
        writes_before = backing_writes;
        lsu_once(1'b0, 3'b001, 32'h0000_0101, 32'd0, 32'd0, PRV_M);
        chk(got_fault && got_cause == 4'd4 && got_fault_va == 32'h0000_0101,
            "lh_misaligned_fault");
        chk(backing_reads == reads_before && backing_writes == writes_before,
            "load_misaligned_no_memory_request");
        lsu_once(1'b1, 3'b010, 32'h0000_010A, 32'hFFFF_0000, 32'd0, PRV_M);
        chk(got_fault && got_cause == 4'd6 && got_fault_va == 32'h0000_010A,
            "sw_misaligned_fault");

        lsu_once(1'b0, 3'b010, 32'h0000_0020, 32'd0, SATP_ROOT, PRV_S);
        chk(!got_fault && got_pa == 32'h0000_3020 && got_load == 32'hCAFE_BABE,
            "translated_lw_success");
        chk(ad_writes == 1, "translated_load_sets_accessed");
        lsu_once(1'b1, 3'b010, 32'h0000_0024, 32'h55AA_1234, SATP_ROOT, PRV_S);
        chk(!got_fault && got_pa == 32'h0000_3024, "translated_sw_success");
        chk(ad_writes == 2, "translated_store_sets_dirty");
        lsu_once(1'b0, 3'b010, 32'h0000_0024, 32'd0, SATP_ROOT, PRV_S);
        chk(!got_fault && got_load == 32'h55AA_1234, "translated_store_visible");
        lsu_once(1'b0, 3'b010, 32'h0000_1000, 32'd0, SATP_ROOT, PRV_S);
        chk(got_fault && got_cause == 4'd13 && got_fault_va == 32'h0000_1000,
            "translated_load_page_fault");

        chk(d_hits != 0 && d_misses != 0, "dcache_exercised");

        $display("lsu_stage stats: d_hits=%0d d_misses=%0d ad_writes=%0d backing_reads=%0d backing_writes=%0d",
                 d_hits, d_misses, ad_writes, backing_reads, backing_writes);
        if (fails == 0) $display("LSU_STAGE_RESULT: PASS");
        else            $display("LSU_STAGE_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
