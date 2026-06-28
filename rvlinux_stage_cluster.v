`timescale 1ns/1ps
// Shared fetch/translate/LSU/AMO memory-stage cluster for the future rvlinux stall FSM.
//
// The booting rvlinux.v still owns decode, trap/CSR side effects, and writeback.
// This module groups the already-verified multi-cycle stages behind one real
// rvlinux_mem_boundary so the next integration step has a single core-side
// command surface instead of several separate test-only boundary instances.
module rvlinux_stage_cluster #(
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

    input  wire [31:0] satp,
    input  wire [1:0]  priv,
    input  wire [1:0]  data_priv,
    input  wire        sum,
    input  wire        mxr,
    input  wire        tlb_flush,

    input  wire        fetch_start,
    input  wire [31:0] fetch_pc,
    output wire        fetch_done,
    output wire        fetch_busy,
    output wire        fetch_fault,
    output wire [3:0]  fetch_cause,
    output wire [31:0] fetch_fault_va,
    output wire [15:0] fetch_lo16,
    output wire [31:0] fetch_raw32,
    output wire        fetch_is_rvc,
    output wire        fetch_used_second,

    input  wire        lsu_start,
    input  wire        lsu_is_store,
    input  wire [2:0]  lsu_funct3,
    input  wire [31:0] lsu_va,
    input  wire [31:0] lsu_store_data,
    output wire        lsu_done,
    output wire        lsu_busy,
    output wire        lsu_fault,
    output wire [3:0]  lsu_cause,
    output wire [31:0] lsu_fault_va,
    output wire [31:0] lsu_pa,
    output wire [31:0] lsu_load_data,

    input  wire        amo_start,
    input  wire [4:0]  amo_funct5,
    input  wire [31:0] amo_va,
    input  wire [31:0] amo_rs2_value,
    input  wire        amo_clear_reservation,
    output wire        amo_done,
    output wire        amo_busy,
    output wire        amo_fault,
    output wire [3:0]  amo_cause,
    output wire [31:0] amo_fault_va,
    output wire [31:0] amo_pa,
    output wire [31:0] amo_rd_value,
    output wire        amo_reservation_valid,
    output wire [31:0] amo_reservation_addr,

    input  wire        xlate_start,
    input  wire        xlate_is_store,
    input  wire [31:0] xlate_va,
    output wire        xlate_done,
    output wire        xlate_busy,
    output wire        xlate_fault,
    output wire [3:0]  xlate_cause,
    output wire [31:0] xlate_fault_va,
    output wire [31:0] xlate_pa,

    output wire        cluster_busy,
    output wire [2:0]  active_owner,
    output wire [31:0] i_hits,
    output wire [31:0] i_misses,
    output wire [31:0] d_hits,
    output wire [31:0] d_misses,
    output wire [31:0] ad_writes,

    output wire        backing_req,
    output wire        backing_we,
    output wire [31:0] backing_addr,
    output wire        backing_ack
);
    localparam OWNER_NONE  = 3'd0;
    localparam OWNER_FETCH = 3'd1;
    localparam OWNER_LSU   = 3'd2;
    localparam OWNER_AMO   = 3'd3;
    localparam OWNER_XLATE = 3'd4;

    reg [2:0] owner;

    wire grant_amo   = (owner == OWNER_AMO) ||
                       (owner == OWNER_NONE && amo_start);
    wire grant_xlate = (owner == OWNER_XLATE) ||
                       (owner == OWNER_NONE && !amo_start && xlate_start);
    wire grant_lsu   = (owner == OWNER_LSU) ||
                       (owner == OWNER_NONE && !amo_start && !xlate_start && lsu_start);
    wire grant_fetch = (owner == OWNER_FETCH) ||
                       (owner == OWNER_NONE && !amo_start && !xlate_start &&
                        !lsu_start && fetch_start);

    wire fetch_start_i = fetch_start && grant_fetch;
    wire lsu_start_i   = lsu_start && grant_lsu;
    wire amo_start_i   = amo_start && grant_amo;

    wire        fetch_mem_req;
    wire [1:0]  fetch_mem_access;
    wire [31:0] fetch_mem_va;
    wire [31:0] fetch_mem_wdata;
    wire [3:0]  fetch_mem_be;
    wire [31:0] fetch_mem_rdata;
    wire        fetch_mem_ready;
    wire        fetch_mem_fault;
    wire [3:0]  fetch_mem_cause;

    wire        lsu_mem_req;
    wire [1:0]  lsu_mem_access;
    wire [31:0] lsu_mem_va;
    wire [31:0] lsu_mem_wdata;
    wire [3:0]  lsu_mem_be;
    wire [31:0] lsu_mem_rdata;
    wire        lsu_mem_ready;
    wire        lsu_mem_fault;
    wire [3:0]  lsu_mem_cause;
    wire [31:0] lsu_mem_pa;

    wire        amo_mem_req;
    wire [1:0]  amo_mem_access;
    wire [31:0] amo_mem_va;
    wire [31:0] amo_mem_wdata;
    wire [3:0]  amo_mem_be;
    wire [31:0] amo_mem_rdata;
    wire        amo_mem_ready;
    wire        amo_mem_fault;
    wire [3:0]  amo_mem_cause;
    wire [31:0] amo_mem_pa;

    wire        core_req;
    wire [1:0]  core_access;
    wire [31:0] core_va;
    wire [31:0] core_wdata;
    wire [3:0]  core_be;
    wire [31:0] core_rdata;
    wire        core_ready;
    wire        core_fault;
    wire [3:0]  core_cause;
    wire [31:0] core_pa;
    wire [1:0]  core_priv;

    assign active_owner = owner;
    assign cluster_busy = (owner != OWNER_NONE);
    assign core_priv = grant_fetch ? priv : data_priv;

    assign core_req = grant_amo   ? amo_mem_req :
                      grant_xlate ? xlate_start :
                      grant_lsu   ? lsu_mem_req :
                      grant_fetch ? fetch_mem_req : 1'b0;
    assign core_access = grant_amo   ? amo_mem_access :
                         grant_xlate ? 2'd3 :
                         grant_lsu   ? lsu_mem_access :
                         grant_fetch ? fetch_mem_access : 2'd0;
    assign core_va = grant_amo   ? amo_mem_va :
                     grant_xlate ? xlate_va :
                     grant_lsu   ? lsu_mem_va :
                     grant_fetch ? fetch_mem_va : 32'd0;
    assign core_wdata = grant_amo   ? amo_mem_wdata :
                        grant_xlate ? 32'd0 :
                        grant_lsu   ? lsu_mem_wdata :
                        grant_fetch ? fetch_mem_wdata : 32'd0;
    assign core_be = grant_amo   ? amo_mem_be :
                     grant_xlate ? (xlate_is_store ? 4'h1 : 4'h0) :
                     grant_lsu   ? lsu_mem_be :
                     grant_fetch ? fetch_mem_be : 4'h0;

    assign fetch_mem_rdata = core_rdata;
    assign fetch_mem_ready = grant_fetch && core_ready;
    assign fetch_mem_fault = core_fault;
    assign fetch_mem_cause = core_cause;

    assign lsu_mem_rdata = core_rdata;
    assign lsu_mem_ready = grant_lsu && core_ready;
    assign lsu_mem_fault = core_fault;
    assign lsu_mem_cause = core_cause;
    assign lsu_mem_pa = core_pa;

    assign amo_mem_rdata = core_rdata;
    assign amo_mem_ready = grant_amo && core_ready;
    assign amo_mem_fault = core_fault;
    assign amo_mem_cause = core_cause;
    assign amo_mem_pa = core_pa;

    assign xlate_done = grant_xlate && core_ready;
    assign xlate_busy = (owner == OWNER_XLATE);
    assign xlate_fault = core_fault;
    assign xlate_cause = core_cause;
    assign xlate_fault_va = xlate_va;
    assign xlate_pa = core_pa;

    rvlinux_fetch_stage fetch (
        .clk(clk), .rst(rst),
        .start(fetch_start_i), .pc(fetch_pc),
        .done(fetch_done), .busy(fetch_busy), .fault(fetch_fault),
        .cause(fetch_cause), .fault_va(fetch_fault_va),
        .lo16(fetch_lo16), .raw32(fetch_raw32), .is_rvc(fetch_is_rvc),
        .used_second_fetch(fetch_used_second),
        .mem_req(fetch_mem_req), .mem_access(fetch_mem_access),
        .mem_va(fetch_mem_va), .mem_wdata(fetch_mem_wdata),
        .mem_be(fetch_mem_be), .mem_rdata(fetch_mem_rdata),
        .mem_ready(fetch_mem_ready), .mem_fault(fetch_mem_fault),
        .mem_cause(fetch_mem_cause)
    );

    rvlinux_lsu_stage lsu (
        .clk(clk), .rst(rst),
        .start(lsu_start_i), .is_store(lsu_is_store),
        .funct3(lsu_funct3), .va(lsu_va), .store_data(lsu_store_data),
        .done(lsu_done), .busy(lsu_busy), .fault(lsu_fault),
        .cause(lsu_cause), .fault_va(lsu_fault_va),
        .pa(lsu_pa), .load_data(lsu_load_data),
        .mem_req(lsu_mem_req), .mem_access(lsu_mem_access),
        .mem_va(lsu_mem_va), .mem_wdata(lsu_mem_wdata),
        .mem_be(lsu_mem_be), .mem_rdata(lsu_mem_rdata),
        .mem_ready(lsu_mem_ready), .mem_fault(lsu_mem_fault),
        .mem_cause(lsu_mem_cause), .mem_pa(lsu_mem_pa)
    );

    rvlinux_amo_stage amo (
        .clk(clk), .rst(rst),
        .start(amo_start_i), .funct5(amo_funct5), .va(amo_va),
        .rs2_value(amo_rs2_value), .clear_reservation(amo_clear_reservation),
        .done(amo_done), .busy(amo_busy), .fault(amo_fault),
        .cause(amo_cause), .fault_va(amo_fault_va), .pa(amo_pa),
        .rd_value(amo_rd_value),
        .reservation_valid(amo_reservation_valid),
        .reservation_addr(amo_reservation_addr),
        .mem_req(amo_mem_req), .mem_access(amo_mem_access),
        .mem_va(amo_mem_va), .mem_wdata(amo_mem_wdata),
        .mem_be(amo_mem_be), .mem_rdata(amo_mem_rdata),
        .mem_ready(amo_mem_ready), .mem_fault(amo_mem_fault),
        .mem_cause(amo_mem_cause), .mem_pa(amo_mem_pa)
    );

    rvlinux_mem_boundary #(
        .I_LINES(I_LINES),
        .D_LINES(D_LINES),
        .WORDS(WORDS),
        .MEMWORDS(MEMWORDS),
        .LAT(LAT),
        .RAMBASE(RAMBASE),
        .MEMFILE(MEMFILE),
        .MEMFILE_WORDS(MEMFILE_WORDS)
    ) mem (
        .clk(clk), .rst(rst),
        .core_req(core_req), .core_access(core_access), .core_va(core_va),
        .core_wdata(core_wdata), .core_be(core_be),
        .satp(satp), .priv(core_priv), .sum(sum), .mxr(mxr),
        .tlb_flush(tlb_flush),
        .core_rdata(core_rdata), .core_ready(core_ready),
        .core_fault(core_fault), .core_cause(core_cause), .core_pa(core_pa),
        .core_busy(),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    always @(posedge clk) begin
        if (rst) begin
            owner <= OWNER_NONE;
        end else begin
            case (owner)
            OWNER_NONE: begin
                if (amo_start)
                    owner <= OWNER_AMO;
                else if (xlate_start)
                    owner <= OWNER_XLATE;
                else if (lsu_start)
                    owner <= OWNER_LSU;
                else if (fetch_start)
                    owner <= OWNER_FETCH;
            end
            OWNER_FETCH: begin
                if (!fetch_start && !fetch_busy)
                    owner <= OWNER_NONE;
            end
            OWNER_LSU: begin
                if (!lsu_start && !lsu_busy)
                    owner <= OWNER_NONE;
            end
            OWNER_AMO: begin
                if (!amo_start && !amo_busy)
                    owner <= OWNER_NONE;
            end
            OWNER_XLATE: begin
                if (!xlate_start)
                    owner <= OWNER_NONE;
            end
            default: begin
                owner <= OWNER_NONE;
            end
            endcase
        end
    end
endmodule
