`timescale 1ns/1ps
module tb_rvlinux_amo_stage;
    localparam I_LINES  = 16;
    localparam D_LINES  = 16;
    localparam WORDS    = 4;
    localparam LAT      = 5;
    localparam MEMWORDS = 1<<14;
    localparam PRV_M    = 2'd3;
    localparam PRV_S    = 2'd1;

    localparam F5_AMOADD  = 5'b00000;
    localparam F5_AMOSWAP = 5'b00001;
    localparam F5_LR      = 5'b00010;
    localparam F5_SC      = 5'b00011;
    localparam F5_AMOXOR  = 5'b00100;
    localparam F5_AMOOR   = 5'b01000;
    localparam F5_AMOAND  = 5'b01100;
    localparam F5_AMOMIN  = 5'b10000;
    localparam F5_AMOMAX  = 5'b10100;
    localparam F5_AMOMINU = 5'b11000;
    localparam F5_AMOMAXU = 5'b11100;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         start = 0;
    reg  [4:0]  funct5 = 0;
    reg  [31:0] va = 0;
    reg  [31:0] rs2_value = 0;
    reg         clear_reservation = 0;
    reg  [31:0] satp = 0;
    reg  [1:0]  priv = PRV_M;
    reg         sum = 0, mxr = 0;

    wire        done, busy, fault, reservation_valid;
    wire [3:0]  cause;
    wire [31:0] fault_va, pa, rd_value, reservation_addr;

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

    rvlinux_amo_stage amo (
        .clk(clk), .rst(rst),
        .start(start), .funct5(funct5), .va(va), .rs2_value(rs2_value),
        .clear_reservation(clear_reservation),
        .done(done), .busy(busy), .fault(fault), .cause(cause),
        .fault_va(fault_va), .pa(pa), .rd_value(rd_value),
        .reservation_valid(reservation_valid), .reservation_addr(reservation_addr),
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
    reg [31:0] got_rd, got_pa, got_fault_va, got_res_addr;
    reg        got_fault, got_res_valid;
    reg [3:0]  got_cause;

    localparam [31:0] SATP_ROOT = 32'h8000_0001;
    localparam [31:0] ROOT_PTE  = (32'h0000_0002 << 10) | 32'h001;
    localparam [31:0] LEAF0_PTE = (32'h0000_0003 << 10) | 32'h007;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (backing_ack && backing_we) backing_writes <= backing_writes + 1;
        if (backing_ack && !backing_we) backing_reads <= backing_reads + 1;
        if (cyc > 50000) begin
            $display("FAIL watchdog timeout");
            $display("AMO_STAGE_RESULT: FAIL (timeout)");
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

    task amo_once(
        input [4:0]  funct5_i,
        input [31:0] va_i,
        input [31:0] rs2_i,
        input [31:0] satp_i,
        input [1:0]  priv_i
    );
        begin
            @(negedge clk);
            funct5 = funct5_i;
            va = va_i;
            rs2_value = rs2_i;
            satp = satp_i;
            priv = priv_i;
            sum = 1'b0;
            mxr = 1'b0;
            start = 1'b1;
            while (!done) @(negedge clk);
            got_rd = rd_value;
            got_fault = fault;
            got_cause = cause;
            got_fault_va = fault_va;
            got_pa = pa;
            got_res_valid = reservation_valid;
            got_res_addr = reservation_addr;
            @(negedge clk);
            start = 1'b0;
            @(negedge clk);
        end
    endtask

    task pulse_clear_reservation;
        begin
            @(negedge clk);
            clear_reservation = 1'b1;
            @(negedge clk);
            clear_reservation = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        #1;
        mem.memsys.backing.mem[32'h0000_0100 >> 2] = 32'h0000_0064;
        mem.memsys.backing.mem[32'h0000_0104 >> 2] = 32'h0000_5555;
        mem.memsys.backing.mem[32'h0000_0108 >> 2] = 32'hFFFF_FFF0;
        mem.memsys.backing.mem[32'h0000_010C >> 2] = 32'h0000_0004;
        mem.memsys.backing.mem[32'h0000_1000 >> 2] = ROOT_PTE;
        mem.memsys.backing.mem[32'h0000_2000 >> 2] = LEAF0_PTE;
        mem.memsys.backing.mem[32'h0000_2004 >> 2] = 32'h0000_0000;
        mem.memsys.backing.mem[32'h0000_3020 >> 2] = 32'h1357_2468;
        mem.memsys.backing.mem[32'h0000_3024 >> 2] = 32'hCAFE_BABE;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        amo_once(F5_AMOOR, 32'h0000_0100, 32'h0000_000F, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'h0000_0064 && got_pa == 32'h0000_0100,
            "amoor_returns_old_word");
        amo_once(F5_LR, 32'h0000_0100, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'h0000_006F && got_res_valid &&
            got_res_addr == 32'h0000_0100, "lr_reads_amoor_result_and_sets_reservation");

        amo_once(F5_SC, 32'h0000_0100, 32'h0000_2222, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'd0 && !got_res_valid, "sc_success_returns_zero");
        amo_once(F5_LR, 32'h0000_0100, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'h0000_2222, "sc_success_store_visible");

        pulse_clear_reservation();
        amo_once(F5_SC, 32'h0000_0100, 32'h0000_DEAD, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'd1 && !got_res_valid, "sc_failure_returns_one");
        amo_once(F5_LR, 32'h0000_0100, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'h0000_2222, "sc_failure_no_store");

        amo_once(F5_AMOADD, 32'h0000_0104, 32'h0000_0005, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'h0000_5555, "amoadd_returns_old_word");
        amo_once(F5_LR, 32'h0000_0104, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'h0000_555A, "amoadd_store_visible");

        amo_once(F5_AMOMIN, 32'h0000_0108, 32'h0000_0003, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'hFFFF_FFF0, "amomin_signed_returns_old_word");
        amo_once(F5_LR, 32'h0000_0108, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'hFFFF_FFF0, "amomin_signed_keeps_negative_min");
        amo_once(F5_AMOMAXU, 32'h0000_010C, 32'hFFFF_FFFF, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'h0000_0004, "amomaxu_returns_old_word");
        amo_once(F5_LR, 32'h0000_010C, 32'd0, 32'd0, PRV_M);
        chk(!got_fault && got_rd == 32'hFFFF_FFFF, "amomaxu_store_visible");

        reads_before = backing_reads;
        writes_before = backing_writes;
        amo_once(F5_LR, 32'h0000_0102, 32'd0, 32'd0, PRV_M);
        chk(got_fault && got_cause == 4'd4 && got_fault_va == 32'h0000_0102,
            "misaligned_lr_load_fault");
        chk(backing_reads == reads_before && backing_writes == writes_before,
            "misaligned_lr_no_memory_request");
        amo_once(F5_AMOOR, 32'h0000_0102, 32'hFFFF_0000, 32'd0, PRV_M);
        chk(got_fault && got_cause == 4'd6 && got_fault_va == 32'h0000_0102,
            "misaligned_amo_store_fault");

        amo_once(F5_AMOSWAP, 32'h0000_0020, 32'hABCD_9876, SATP_ROOT, PRV_S);
        chk(!got_fault && got_pa == 32'h0000_3020 &&
            got_rd == 32'h1357_2468, "translated_amoswap_returns_old_word");
        chk(ad_writes == 1, "translated_amo_sets_accessed_and_dirty");
        amo_once(F5_LR, 32'h0000_0020, 32'd0, SATP_ROOT, PRV_S);
        chk(!got_fault && got_rd == 32'hABCD_9876, "translated_amoswap_store_visible");

        amo_once(F5_AMOSWAP, 32'h0000_1000, 32'h1234_0000, SATP_ROOT, PRV_S);
        chk(got_fault && got_cause == 4'd15 && got_fault_va == 32'h0000_1000,
            "translated_amo_store_page_fault");
        amo_once(F5_LR, 32'h0000_1000, 32'd0, SATP_ROOT, PRV_S);
        chk(got_fault && got_cause == 4'd13 && got_fault_va == 32'h0000_1000,
            "translated_lr_load_page_fault");

        chk(d_hits != 0 && d_misses != 0, "dcache_exercised");

        $display("amo_stage stats: d_hits=%0d d_misses=%0d ad_writes=%0d backing_reads=%0d backing_writes=%0d",
                 d_hits, d_misses, ad_writes, backing_reads, backing_writes);
        if (fails == 0) $display("AMO_STAGE_RESULT: PASS");
        else            $display("AMO_STAGE_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
