`timescale 1ns/1ps
// Sequential memory boundary for the future multi-cycle rvlinux core.
//
// One upstream request performs:
//   1. Sv32 translation through sv32_ptw.v,
//   2. optional hardware A/D PTE writeback through the D$ PTW port,
//   3. the final I$ fetch or D$ load/store.
//
// Upstream protocol: hold core_req and all request inputs stable until the
// one-cycle core_ready pulse, then drop core_req for at least one cycle.
// core_access=3 is translate-only: core_be[0]=1 checks store permission and
// updates A/D, core_be[0]=0 checks load permission and updates A only.
module rvlinux_mem_boundary #(
    parameter I_LINES  = 64,
    parameter D_LINES  = 64,
    parameter WORDS    = 4,
    parameter MEMWORDS = 1<<14,
    parameter LAT      = 8,
    parameter [31:0] RAMBASE = 32'h0000_0000,
    parameter MEMFILE = "",
    parameter MEMFILE_WORDS = 0
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        core_req,
    input  wire [1:0]  core_access,  // 0=fetch, 1=load, 2=store/amo, 3=translate-only
    input  wire [31:0] core_va,
    input  wire [31:0] core_wdata,
    input  wire [3:0]  core_be,
    input  wire [31:0] satp,
    input  wire [1:0]  priv,
    input  wire        sum,
    input  wire        mxr,
    input  wire        tlb_flush,

    output reg  [31:0] core_rdata,
    output reg         core_ready,
    output reg         core_fault,
    output reg  [3:0]  core_cause,
    output reg  [31:0] core_pa,
    output wire        core_busy,

    output wire [31:0] i_hits,
    output wire [31:0] i_misses,
    output wire [31:0] d_hits,
    output wire [31:0] d_misses,
    output reg  [31:0] ad_writes,

    output wire        backing_req,
    output wire        backing_we,
    output wire [31:0] backing_addr,
    output wire        backing_ack
);
    localparam ACC_FETCH = 2'd0;
    localparam ACC_LOAD  = 2'd1;
    localparam ACC_STORE = 2'd2;
    localparam ACC_TRANSLATE_ONLY = 2'd3;

    localparam S_IDLE      = 3'd0;
    localparam S_PTW_START = 3'd1;
    localparam S_PTW_WAIT  = 3'd2;
    localparam S_AD_WAIT   = 3'd3;
    localparam S_MEM_WAIT  = 3'd4;
    localparam S_WAIT_DROP = 3'd5;

    reg [2:0]  state;
    reg [1:0]  access_r;
    reg [31:0] va_r;
    reg [31:0] wdata_r;
    reg [3:0]  be_r;
    reg [31:0] satp_r;
    reg [1:0]  priv_r;
    reg        sum_r;
    reg        mxr_r;
    reg [31:0] pa_r;
    reg [31:0] ad_addr_r;
    reg [31:0] ad_wdata_r;
    reg        ptw_start;

    reg        itlb_valid;
    reg [31:0] itlb_satp;
    reg [19:0] itlb_vpn;
    reg [31:0] itlb_pte;
    reg        itlb_level1;

    reg        dtlb_valid;
    reg [31:0] dtlb_satp;
    reg [19:0] dtlb_vpn;
    reg [31:0] dtlb_pte;
    reg        dtlb_level1;

    wire        ptw_busy;
    wire        ptw_done;
    wire        ptw_fault;
    wire [3:0]  ptw_cause;
    wire [31:0] ptw_pa;
    wire [31:0] ptw_leaf_pte;
    wire [31:0] ptw_leaf_pte_pa;
    wire        ptw_set_a;
    wire        ptw_set_d;

    wire        ptw_walk_req;
    wire        ptw_walk_we;
    wire [31:0] ptw_walk_addr;
    wire [31:0] ptw_walk_wdata;
    wire [31:0] ptw_walk_rdata;
    wire        ptw_walk_ack;

    wire        ptw_port_req;
    wire        ptw_port_we;
    wire [31:0] ptw_port_addr;
    wire [31:0] ptw_port_wdata;
    wire [31:0] ptw_port_rdata;
    wire        ptw_port_ready;

    wire        i_req;
    wire [31:0] i_addr;
    wire [31:0] i_rdata;
    wire        i_ready;

    wire        d_req;
    wire        d_we;
    wire [31:0] d_addr;
    wire [31:0] d_wdata;
    wire [3:0]  d_be;
    wire [31:0] d_rdata;
    wire        d_ready;

    assign core_busy = (state != S_IDLE);

    assign i_req  = (state == S_MEM_WAIT) && (access_r == ACC_FETCH);
    assign i_addr = pa_r;

    assign d_req    = (state == S_MEM_WAIT) &&
                      (access_r != ACC_FETCH) &&
                      (access_r != ACC_TRANSLATE_ONLY);
    assign d_we     = (access_r == ACC_STORE);
    assign d_addr   = pa_r;
    assign d_wdata  = wdata_r;
    assign d_be     = d_we ? be_r : 4'hF;

    assign ptw_port_req   = (state == S_AD_WAIT) ? 1'b1       : ptw_walk_req;
    assign ptw_port_we    = (state == S_AD_WAIT) ? 1'b1       : ptw_walk_we;
    assign ptw_port_addr  = (state == S_AD_WAIT) ? ad_addr_r  : ptw_walk_addr;
    assign ptw_port_wdata = (state == S_AD_WAIT) ? ad_wdata_r : ptw_walk_wdata;
    assign ptw_walk_rdata = ptw_port_rdata;
    assign ptw_walk_ack   = (state == S_AD_WAIT) ? 1'b0 : ptw_port_ready;

    wire [1:0] ptw_access =
        (access_r == ACC_TRANSLATE_ONLY) ? (be_r[0] ? ACC_TRANSLATE_ONLY : ACC_LOAD) :
                                           access_r;
    wire [1:0] core_ptw_access =
        (core_access == ACC_TRANSLATE_ONLY) ? (core_be[0] ? ACC_TRANSLATE_ONLY : ACC_LOAD) :
                                              core_access;
    wire [19:0] core_vpn = core_va[31:12];
    wire        use_itlb = (core_access == ACC_FETCH);
    wire        core_translated = satp[31] && (priv != 2'd3);

    wire itlb_tag_hit = itlb_valid && (itlb_satp == satp) &&
                        (itlb_level1 ? (itlb_vpn[19:10] == core_vpn[19:10]) :
                                       (itlb_vpn == core_vpn));
    wire dtlb_tag_hit = dtlb_valid && (dtlb_satp == satp) &&
                        (dtlb_level1 ? (dtlb_vpn[19:10] == core_vpn[19:10]) :
                                       (dtlb_vpn == core_vpn));
    wire        tlb_tag_hit = use_itlb ? itlb_tag_hit : dtlb_tag_hit;
    wire [31:0] tlb_pte = use_itlb ? itlb_pte : dtlb_pte;
    wire        tlb_level1 = use_itlb ? itlb_level1 : dtlb_level1;
    wire        tlb_store_like = (core_ptw_access == ACC_STORE) ||
                                 (core_ptw_access == ACC_TRANSLATE_ONLY);
    wire        tlb_hit = core_translated && tlb_tag_hit &&
                          tlb_perm_ok(tlb_pte, core_ptw_access, priv, sum, mxr) &&
                          tlb_pte[6] && (!tlb_store_like || tlb_pte[7]);
    wire [31:0] tlb_pa = tlb_pa_from_pte(tlb_pte, core_va, tlb_level1);

    wire [31:0] ptw_fill_pte = ptw_leaf_pte |
                                (ptw_set_a ? 32'h0000_0040 : 32'd0) |
                                (ptw_set_d ? 32'h0000_0080 : 32'd0);
    wire [31:0] ptw_l1_pte_pa = {satp_r[19:0], 12'b0} + {va_r[31:22], 2'b0};
    wire        ptw_leaf_level1 = (ptw_leaf_pte_pa == ptw_l1_pte_pa);
    wire        ptw_can_fill_tlb = satp_r[31] && (priv_r != 2'd3);

    function tlb_perm_ok;
        input [31:0] pte;
        input [1:0]  acc;
        input [1:0]  prv;
        input        sum_i;
        input        mxr_i;
        reg          readable;
        begin
            readable = pte[1] | (mxr_i & pte[3]);
            if (acc == ACC_FETCH)
                tlb_perm_ok = pte[3] && ((prv == 2'd0) ? pte[4] : !pte[4]);
            else
                tlb_perm_ok = ((acc == ACC_LOAD) ? readable : pte[2]) &&
                              ((prv == 2'd0) ? pte[4] : (!pte[4] | sum_i));
        end
    endfunction

    function [31:0] tlb_pa_from_pte;
        input [31:0] pte;
        input [31:0] va;
        input        level1;
        begin
            tlb_pa_from_pte = level1 ? {pte[29:20], va[21:0]} :
                                       {pte[29:10], va[11:0]};
        end
    endfunction

    l1_mem_system #(
        .I_LINES(I_LINES),
        .D_LINES(D_LINES),
        .WORDS(WORDS),
        .MEMW(MEMWORDS),
        .LAT(LAT),
        .RAMBASE(RAMBASE),
        .MEMFILE(MEMFILE),
        .MEMFILE_WORDS(MEMFILE_WORDS)
    ) memsys (
        .clk(clk), .rst(rst),
        .i_req(i_req), .i_addr(i_addr), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .ptw_req(ptw_port_req), .ptw_we(ptw_port_we), .ptw_addr(ptw_port_addr),
        .ptw_wdata(ptw_port_wdata), .ptw_be(4'hF),
        .ptw_rdata(ptw_port_rdata), .ptw_ready(ptw_port_ready),
        .i_hits(i_hits), .i_misses(i_misses), .d_hits(d_hits), .d_misses(d_misses),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    sv32_ptw #(
        .MEMWORDS(MEMWORDS),
        .RAMBASE(RAMBASE)
    ) ptw (
        .clk(clk), .rst(rst),
        .start(ptw_start), .satp(satp_r), .va(va_r), .access(ptw_access),
        .priv(priv_r), .sum(sum_r), .mxr(mxr_r),
        .busy(ptw_busy), .done(ptw_done), .fault(ptw_fault), .cause(ptw_cause),
        .pa(ptw_pa), .leaf_pte(ptw_leaf_pte), .leaf_pte_pa(ptw_leaf_pte_pa),
        .set_a(ptw_set_a), .set_d(ptw_set_d),
        .m_req(ptw_walk_req), .m_we(ptw_walk_we), .m_addr(ptw_walk_addr),
        .m_wdata(ptw_walk_wdata), .m_rdata(ptw_walk_rdata), .m_ack(ptw_walk_ack)
    );

    always @(posedge clk) begin
        core_ready <= 1'b0;
        ptw_start <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            access_r <= ACC_FETCH;
            va_r <= 32'd0;
            wdata_r <= 32'd0;
            be_r <= 4'hF;
            satp_r <= 32'd0;
            priv_r <= 2'd3;
            sum_r <= 1'b0;
            mxr_r <= 1'b0;
            pa_r <= 32'd0;
            ad_addr_r <= 32'd0;
            ad_wdata_r <= 32'd0;
            itlb_valid <= 1'b0;
            itlb_satp <= 32'd0;
            itlb_vpn <= 20'd0;
            itlb_pte <= 32'd0;
            itlb_level1 <= 1'b0;
            dtlb_valid <= 1'b0;
            dtlb_satp <= 32'd0;
            dtlb_vpn <= 20'd0;
            dtlb_pte <= 32'd0;
            dtlb_level1 <= 1'b0;
            core_rdata <= 32'd0;
            core_fault <= 1'b0;
            core_cause <= 4'd0;
            core_pa <= 32'd0;
            ad_writes <= 32'd0;
        end else begin
            if (tlb_flush) begin
                itlb_valid <= 1'b0;
                dtlb_valid <= 1'b0;
            end
            case (state)
            S_IDLE: begin
                if (core_req) begin
                    access_r <= core_access;
                    va_r <= core_va;
                    wdata_r <= core_wdata;
                    be_r <= core_be;
                    satp_r <= satp;
                    priv_r <= priv;
                    sum_r <= sum;
                    mxr_r <= mxr;
                    core_fault <= 1'b0;
                    core_cause <= 4'd0;
                    if (tlb_hit) begin
                        pa_r <= tlb_pa;
                        core_pa <= tlb_pa;
                        if (core_access == ACC_TRANSLATE_ONLY) begin
                            core_rdata <= 32'd0;
                            core_ready <= 1'b1;
                            state <= S_WAIT_DROP;
                        end else begin
                            state <= S_MEM_WAIT;
                        end
                    end else begin
                        state <= S_PTW_START;
                    end
                end
            end

            S_PTW_START: begin
                ptw_start <= 1'b1;
                state <= S_PTW_WAIT;
            end

            S_PTW_WAIT: begin
                if (ptw_done) begin
                    pa_r <= ptw_pa;
                    core_pa <= ptw_pa;
                    if (ptw_fault) begin
                        core_rdata <= 32'd0;
                        core_fault <= 1'b1;
                        core_cause <= ptw_cause;
                        core_ready <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else if (ptw_set_a || ptw_set_d) begin
                        ad_addr_r <= ptw_leaf_pte_pa;
                        ad_wdata_r <= ptw_fill_pte;
                        state <= S_AD_WAIT;
                    end else if (access_r == ACC_TRANSLATE_ONLY) begin
                        if (ptw_can_fill_tlb) begin
                            if (access_r == ACC_FETCH) begin
                                itlb_valid <= 1'b1;
                                itlb_satp <= satp_r;
                                itlb_vpn <= va_r[31:12];
                                itlb_pte <= ptw_leaf_pte;
                                itlb_level1 <= ptw_leaf_level1;
                            end else begin
                                dtlb_valid <= 1'b1;
                                dtlb_satp <= satp_r;
                                dtlb_vpn <= va_r[31:12];
                                dtlb_pte <= ptw_leaf_pte;
                                dtlb_level1 <= ptw_leaf_level1;
                            end
                        end
                        core_rdata <= 32'd0;
                        core_fault <= 1'b0;
                        core_cause <= 4'd0;
                        core_ready <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else begin
                        if (ptw_can_fill_tlb) begin
                            if (access_r == ACC_FETCH) begin
                                itlb_valid <= 1'b1;
                                itlb_satp <= satp_r;
                                itlb_vpn <= va_r[31:12];
                                itlb_pte <= ptw_leaf_pte;
                                itlb_level1 <= ptw_leaf_level1;
                            end else begin
                                dtlb_valid <= 1'b1;
                                dtlb_satp <= satp_r;
                                dtlb_vpn <= va_r[31:12];
                                dtlb_pte <= ptw_leaf_pte;
                                dtlb_level1 <= ptw_leaf_level1;
                            end
                        end
                        state <= S_MEM_WAIT;
                    end
                end
            end

            S_AD_WAIT: begin
                if (ptw_port_ready) begin
                    ad_writes <= ad_writes + 32'd1;
                    if (ptw_can_fill_tlb) begin
                        if (access_r == ACC_FETCH) begin
                            itlb_valid <= 1'b1;
                            itlb_satp <= satp_r;
                            itlb_vpn <= va_r[31:12];
                            itlb_pte <= ad_wdata_r;
                            itlb_level1 <= ptw_leaf_level1;
                        end else begin
                            dtlb_valid <= 1'b1;
                            dtlb_satp <= satp_r;
                            dtlb_vpn <= va_r[31:12];
                            dtlb_pte <= ad_wdata_r;
                            dtlb_level1 <= ptw_leaf_level1;
                        end
                    end
                    if (access_r == ACC_TRANSLATE_ONLY) begin
                        core_rdata <= 32'd0;
                        core_pa <= pa_r;
                        core_fault <= 1'b0;
                        core_cause <= 4'd0;
                        core_ready <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else begin
                        state <= S_MEM_WAIT;
                    end
                end
            end

            S_MEM_WAIT: begin
                if ((access_r == ACC_FETCH && i_ready) ||
                    (access_r != ACC_FETCH && d_ready)) begin
                    core_rdata <= (access_r == ACC_FETCH) ? i_rdata : d_rdata;
                    core_pa <= pa_r;
                    core_fault <= 1'b0;
                    core_cause <= 4'd0;
                    core_ready <= 1'b1;
                    state <= S_WAIT_DROP;
                end
            end

            S_WAIT_DROP: begin
                if (!core_req)
                    state <= S_IDLE;
            end

            default: begin
                state <= S_IDLE;
            end
            endcase
        end
    end
endmodule
