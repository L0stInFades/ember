`timescale 1ns/1ps
module tb_rvlinux_stage_cluster;
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
    localparam F5_AMOOR   = 5'b01000;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg [31:0] satp = 0;
    reg [1:0]  priv = PRV_M;
    reg [1:0]  data_priv = PRV_M;
    reg        sum = 0, mxr = 0;

    reg        fetch_start = 0;
    reg [31:0] fetch_pc = 0;
    wire       fetch_done, fetch_busy, fetch_fault, fetch_is_rvc, fetch_second;
    wire [3:0] fetch_cause;
    wire [31:0] fetch_fault_va, fetch_raw32;
    wire [15:0] fetch_lo16;

    reg        lsu_start = 0;
    reg        lsu_is_store = 0;
    reg [2:0]  lsu_funct3 = 0;
    reg [31:0] lsu_va = 0;
    reg [31:0] lsu_store_data = 0;
    wire       lsu_done, lsu_busy, lsu_fault;
    wire [3:0] lsu_cause;
    wire [31:0] lsu_fault_va, lsu_pa, lsu_load_data;

    reg        amo_start = 0;
    reg [4:0]  amo_funct5 = 0;
    reg [31:0] amo_va = 0;
    reg [31:0] amo_rs2_value = 0;
    reg        amo_clear_reservation = 0;
    wire       amo_done, amo_busy, amo_fault, amo_reservation_valid;
    wire [3:0] amo_cause;
    wire [31:0] amo_fault_va, amo_pa, amo_rd_value, amo_reservation_addr;

    reg        xlate_start = 0;
    reg        xlate_is_store = 0;
    reg [31:0] xlate_va = 0;
    wire       xlate_done, xlate_busy, xlate_fault;
    wire [3:0] xlate_cause;
    wire [31:0] xlate_fault_va, xlate_pa;

    wire       cluster_busy;
    wire [2:0] active_owner;
    wire [31:0] i_hits, i_misses, d_hits, d_misses, ad_writes;
    wire backing_req, backing_we, backing_ack;
    wire [31:0] backing_addr;

    rvlinux_stage_cluster #(
        .I_LINES(I_LINES), .D_LINES(D_LINES), .WORDS(WORDS),
        .MEMWORDS(MEMWORDS), .LAT(LAT), .RAMBASE(32'h0000_0000)
    ) dut (
        .clk(clk), .rst(rst),
        .satp(satp), .priv(priv), .data_priv(data_priv),
        .sum(sum), .mxr(mxr), .tlb_flush(1'b0),
        .fetch_start(fetch_start), .fetch_pc(fetch_pc),
        .fetch_done(fetch_done), .fetch_busy(fetch_busy),
        .fetch_fault(fetch_fault), .fetch_cause(fetch_cause),
        .fetch_fault_va(fetch_fault_va), .fetch_lo16(fetch_lo16),
        .fetch_raw32(fetch_raw32), .fetch_is_rvc(fetch_is_rvc),
        .fetch_used_second(fetch_second),
        .lsu_start(lsu_start), .lsu_is_store(lsu_is_store),
        .lsu_funct3(lsu_funct3), .lsu_va(lsu_va),
        .lsu_store_data(lsu_store_data),
        .lsu_done(lsu_done), .lsu_busy(lsu_busy),
        .lsu_fault(lsu_fault), .lsu_cause(lsu_cause),
        .lsu_fault_va(lsu_fault_va), .lsu_pa(lsu_pa),
        .lsu_load_data(lsu_load_data),
        .amo_start(amo_start), .amo_funct5(amo_funct5),
        .amo_va(amo_va), .amo_rs2_value(amo_rs2_value),
        .amo_clear_reservation(amo_clear_reservation),
        .amo_done(amo_done), .amo_busy(amo_busy),
        .amo_fault(amo_fault), .amo_cause(amo_cause),
        .amo_fault_va(amo_fault_va), .amo_pa(amo_pa),
        .amo_rd_value(amo_rd_value),
        .amo_reservation_valid(amo_reservation_valid),
        .amo_reservation_addr(amo_reservation_addr),
        .xlate_start(xlate_start), .xlate_is_store(xlate_is_store),
        .xlate_va(xlate_va),
        .xlate_done(xlate_done), .xlate_busy(xlate_busy),
        .xlate_fault(xlate_fault), .xlate_cause(xlate_cause),
        .xlate_fault_va(xlate_fault_va), .xlate_pa(xlate_pa),
        .cluster_busy(cluster_busy), .active_owner(active_owner),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    integer fails = 0;
    integer cyc = 0;
    integer backing_reads = 0, backing_writes = 0;

    reg [31:0] got_fetch_raw, got_lsu_load, got_lsu_pa, got_amo_rd, got_amo_pa;
    reg [31:0] got_xlate_pa;
    reg        got_fetch_fault, got_lsu_fault, got_amo_fault, got_xlate_fault;
    reg [3:0]  got_fetch_cause, got_lsu_cause, got_amo_cause, got_xlate_cause;

    localparam [31:0] SATP_ROOT = 32'h8000_0001;
    localparam [31:0] ROOT_PTE  = (32'h0000_0002 << 10) | 32'h001;
    localparam [31:0] LEAF0_PTE = (32'h0000_0003 << 10) | 32'h00F;
    localparam [31:0] LEAF1_PTE = (32'h0000_0004 << 10) | 32'h007;
    localparam [31:0] LEAF2_U_PTE = (32'h0000_0005 << 10) | 32'h017;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (backing_ack && backing_we) backing_writes <= backing_writes + 1;
        if (backing_ack && !backing_we) backing_reads <= backing_reads + 1;
        if (cyc > 70000) begin
            $display("FAIL watchdog timeout");
            $display("STAGE_CLUSTER_RESULT: FAIL (timeout)");
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

    task fetch_once(input [31:0] pc_i, input [31:0] satp_i, input [1:0] priv_i);
        begin
            @(negedge clk);
            satp = satp_i;
            priv = priv_i;
            data_priv = priv_i;
            fetch_pc = pc_i;
            fetch_start = 1'b1;
            while (!fetch_done) @(negedge clk);
            got_fetch_raw = fetch_raw32;
            got_fetch_fault = fetch_fault;
            got_fetch_cause = fetch_cause;
            @(negedge clk);
            fetch_start = 1'b0;
            while (cluster_busy) @(negedge clk);
            @(negedge clk);
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
            satp = satp_i;
            priv = priv_i;
            data_priv = priv_i;
            lsu_is_store = store_i;
            lsu_funct3 = funct3_i;
            lsu_va = va_i;
            lsu_store_data = store_data_i;
            lsu_start = 1'b1;
            while (!lsu_done) @(negedge clk);
            got_lsu_load = lsu_load_data;
            got_lsu_fault = lsu_fault;
            got_lsu_cause = lsu_cause;
            got_lsu_pa = lsu_pa;
            @(negedge clk);
            lsu_start = 1'b0;
            while (cluster_busy) @(negedge clk);
            @(negedge clk);
        end
    endtask

    task lsu_once_data_priv(
        input        store_i,
        input [2:0]  funct3_i,
        input [31:0] va_i,
        input [31:0] store_data_i,
        input [31:0] satp_i,
        input [1:0]  priv_i,
        input [1:0]  data_priv_i,
        input        sum_i
    );
        begin
            @(negedge clk);
            satp = satp_i;
            priv = priv_i;
            data_priv = data_priv_i;
            sum = sum_i;
            lsu_is_store = store_i;
            lsu_funct3 = funct3_i;
            lsu_va = va_i;
            lsu_store_data = store_data_i;
            lsu_start = 1'b1;
            while (!lsu_done) @(negedge clk);
            got_lsu_load = lsu_load_data;
            got_lsu_fault = lsu_fault;
            got_lsu_cause = lsu_cause;
            got_lsu_pa = lsu_pa;
            @(negedge clk);
            lsu_start = 1'b0;
            while (cluster_busy) @(negedge clk);
            @(negedge clk);
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
            satp = satp_i;
            priv = priv_i;
            data_priv = priv_i;
            amo_funct5 = funct5_i;
            amo_va = va_i;
            amo_rs2_value = rs2_i;
            amo_start = 1'b1;
            while (!amo_done) @(negedge clk);
            got_amo_rd = amo_rd_value;
            got_amo_fault = amo_fault;
            got_amo_cause = amo_cause;
            got_amo_pa = amo_pa;
            @(negedge clk);
            amo_start = 1'b0;
            while (cluster_busy) @(negedge clk);
            @(negedge clk);
        end
    endtask

    task xlate_once(
        input        store_i,
        input [31:0] va_i,
        input [31:0] satp_i,
        input [1:0]  priv_i
    );
        begin
            @(negedge clk);
            satp = satp_i;
            priv = priv_i;
            data_priv = priv_i;
            xlate_is_store = store_i;
            xlate_va = va_i;
            xlate_start = 1'b1;
            while (!xlate_done) @(negedge clk);
            got_xlate_pa = xlate_pa;
            got_xlate_fault = xlate_fault;
            got_xlate_cause = xlate_cause;
            @(negedge clk);
            xlate_start = 1'b0;
            while (cluster_busy) @(negedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        #1;
        dut.mem.memsys.backing.mem[32'h0000_0100 >> 2] = 32'h00A0_0093;
        dut.mem.memsys.backing.mem[32'h0000_0104 >> 2] = 32'h0000_0000;
        dut.mem.memsys.backing.mem[32'h0000_0110 >> 2] = 32'h1122_3344;
        dut.mem.memsys.backing.mem[32'h0000_0120 >> 2] = 32'h0000_0064;
        dut.mem.memsys.backing.mem[32'h0000_1000 >> 2] = ROOT_PTE;
        dut.mem.memsys.backing.mem[32'h0000_2000 >> 2] = LEAF0_PTE;
        dut.mem.memsys.backing.mem[32'h0000_2004 >> 2] = LEAF1_PTE;
        dut.mem.memsys.backing.mem[32'h0000_2008 >> 2] = LEAF2_U_PTE;
        dut.mem.memsys.backing.mem[32'h0000_3020 >> 2] = 32'h00B0_0113;
        dut.mem.memsys.backing.mem[32'h0000_3024 >> 2] = 32'hCAFE_BABE;
        dut.mem.memsys.backing.mem[32'h0000_3028 >> 2] = 32'h1357_2468;
        dut.mem.memsys.backing.mem[32'h0000_4000 >> 2] = 32'h2468_ACE0;
        dut.mem.memsys.backing.mem[32'h0000_5000 >> 2] = 32'hFACE_CAFE;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        fetch_once(32'h0000_0100, 32'd0, PRV_M);
        chk(!got_fetch_fault && got_fetch_raw == 32'h00A0_0093,
            "bare_fetch_through_shared_boundary");
        fetch_once(32'h0000_0100, 32'd0, PRV_M);
        chk(!got_fetch_fault && got_fetch_raw == 32'h00A0_0093,
            "bare_fetch_hit_reuses_shared_icache");
        chk(active_owner == 3'd0 && !cluster_busy, "fetch_owner_released");

        lsu_once(1'b1, 3'b010, 32'h0000_0110, 32'h5566_7788, 32'd0, PRV_M);
        chk(!got_lsu_fault && got_lsu_pa == 32'h0000_0110, "bare_lsu_store");
        lsu_once(1'b0, 3'b010, 32'h0000_0110, 32'd0, 32'd0, PRV_M);
        chk(!got_lsu_fault && got_lsu_load == 32'h5566_7788,
            "bare_lsu_load_sees_store");
        chk(active_owner == 3'd0 && !cluster_busy, "lsu_owner_released");

        amo_once(F5_AMOOR, 32'h0000_0120, 32'h0000_000F, 32'd0, PRV_M);
        chk(!got_amo_fault && got_amo_rd == 32'h0000_0064,
            "bare_amo_returns_old_word");
        amo_once(F5_LR, 32'h0000_0120, 32'd0, 32'd0, PRV_M);
        chk(!got_amo_fault && got_amo_rd == 32'h0000_006F &&
            amo_reservation_valid, "bare_lr_reads_amo_and_reserves");
        amo_once(F5_SC, 32'h0000_0120, 32'h0000_2222, 32'd0, PRV_M);
        chk(!got_amo_fault && got_amo_rd == 32'd0 && !amo_reservation_valid,
            "bare_sc_success");
        lsu_once(1'b0, 3'b010, 32'h0000_0120, 32'd0, 32'd0, PRV_M);
        chk(!got_lsu_fault && got_lsu_load == 32'h0000_2222,
            "shared_boundary_sees_sc_store");

        fetch_once(32'h0000_0020, SATP_ROOT, PRV_S);
        chk(!got_fetch_fault && got_fetch_raw == 32'h00B0_0113,
            "translated_fetch_through_cluster");
        lsu_once(1'b1, 3'b010, 32'h0000_0024, 32'hA5A5_1234, SATP_ROOT, PRV_S);
        chk(!got_lsu_fault && got_lsu_pa == 32'h0000_3024,
            "translated_lsu_store_through_cluster");
        lsu_once(1'b0, 3'b010, 32'h0000_0024, 32'd0, SATP_ROOT, PRV_S);
        chk(!got_lsu_fault && got_lsu_load == 32'hA5A5_1234,
            "translated_lsu_loadback_through_cluster");
        amo_once(F5_AMOSWAP, 32'h0000_0028, 32'hDEAD_BEEF, SATP_ROOT, PRV_S);
        chk(!got_amo_fault && got_amo_pa == 32'h0000_3028 &&
            got_amo_rd == 32'h1357_2468, "translated_amo_through_cluster");
        lsu_once(1'b0, 3'b010, 32'h0000_0028, 32'd0, SATP_ROOT, PRV_S);
        chk(!got_lsu_fault && got_lsu_load == 32'hDEAD_BEEF,
            "translated_amo_visible_to_lsu");

        xlate_once(1'b0, 32'h0000_1000, SATP_ROOT, PRV_S);
        chk(!got_xlate_fault && got_xlate_pa == 32'h0000_4000,
            "translated_load_xlate_returns_pa");
        lsu_once(1'b0, 3'b010, 32'h0000_2004, 32'd0, 32'd0, PRV_M);
        chk(!got_lsu_fault && got_lsu_load == (LEAF1_PTE | 32'h0000_0040),
            "translated_load_xlate_sets_accessed_only");
        xlate_once(1'b1, 32'h0000_1000, SATP_ROOT, PRV_S);
        chk(!got_xlate_fault && got_xlate_pa == 32'h0000_4000,
            "translated_store_xlate_returns_pa");
        lsu_once(1'b0, 3'b010, 32'h0000_2004, 32'd0, 32'd0, PRV_M);
        chk(!got_lsu_fault && got_lsu_load == (LEAF1_PTE | 32'h0000_00C0),
            "translated_store_xlate_sets_dirty");
        lsu_once(1'b0, 3'b010, 32'h0000_4000, 32'd0, 32'd0, PRV_M);
        chk(!got_lsu_fault && got_lsu_load == 32'h2468_ACE0,
            "translated_xlate_does_not_touch_data");

        fetch_once(32'h0040_0000, SATP_ROOT, PRV_S);
        chk(got_fetch_fault && got_fetch_cause == 4'd12,
            "translated_fetch_fault_propagates");
        lsu_once(1'b0, 3'b010, 32'h0040_0000, 32'd0, SATP_ROOT, PRV_S);
        chk(got_lsu_fault && got_lsu_cause == 4'd13,
            "translated_lsu_fault_propagates");
        amo_once(F5_AMOADD, 32'h0040_0000, 32'h1, SATP_ROOT, PRV_S);
        chk(got_amo_fault && got_amo_cause == 4'd15,
            "translated_amo_fault_propagates");

        lsu_once_data_priv(1'b0, 3'b010, 32'h0000_2000, 32'd0,
                           SATP_ROOT, PRV_M, PRV_S, 1'b0);
        chk(got_lsu_fault && got_lsu_cause == 4'd13,
            "mprv_data_priv_s_blocks_user_page_without_sum");
        lsu_once_data_priv(1'b0, 3'b010, 32'h0000_2000, 32'd0,
                           SATP_ROOT, PRV_M, PRV_S, 1'b1);
        chk(!got_lsu_fault && got_lsu_pa == 32'h0000_5000 &&
            got_lsu_load == 32'hFACE_CAFE,
            "mprv_data_priv_s_sum_loads_user_page");
        sum = 1'b0;
        data_priv = priv;

        chk(i_hits != 0 && i_misses != 0, "shared_icache_exercised");
        chk(d_hits != 0 && d_misses != 0, "shared_dcache_exercised");
        chk(ad_writes >= 2, "shared_ptw_ad_updates");

        $display("stage_cluster stats: i_hits=%0d i_misses=%0d d_hits=%0d d_misses=%0d ad_writes=%0d backing_reads=%0d backing_writes=%0d",
                 i_hits, i_misses, d_hits, d_misses, ad_writes, backing_reads, backing_writes);
        if (fails == 0) $display("STAGE_CLUSTER_RESULT: PASS");
        else            $display("STAGE_CLUSTER_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
