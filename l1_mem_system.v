`timescale 1ns/1ps
// Split L1 memory subsystem for the future multi-cycle rvlinux core.
//
// CPU-side protocol matches cache.v: hold req/address/data stable until the
// corresponding ready pulse, then drop req for at least one cycle.
module l1_mem_system #(
    parameter I_LINES = 64,
    parameter D_LINES = 64,
    parameter WORDS   = 4,
    parameter MEMW    = 1<<14,
    parameter LAT     = 8,
    parameter [31:0] RAMBASE = 32'h0000_0000,
    parameter MEMFILE = "",
    parameter MEMFILE_WORDS = 0
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        i_req,
    input  wire [31:0] i_addr,
    output wire [31:0] i_rdata,
    output wire        i_ready,

    input  wire        d_req,
    input  wire        d_we,
    input  wire [31:0] d_addr,
    input  wire [31:0] d_wdata,
    input  wire [3:0]  d_be,
    output wire [31:0] d_rdata,
    output wire        d_ready,

    input  wire        ptw_req,
    input  wire        ptw_we,
    input  wire [31:0] ptw_addr,
    input  wire [31:0] ptw_wdata,
    input  wire [3:0]  ptw_be,
    output wire [31:0] ptw_rdata,
    output wire        ptw_ready,

    output wire [31:0] i_hits,
    output wire [31:0] i_misses,
    output wire [31:0] d_hits,
    output wire [31:0] d_misses,

    output wire        backing_req,
    output wire        backing_we,
    output wire [31:0] backing_addr,
    output wire        backing_ack
);
    wire        ic_m_req, ic_m_we, ic_m_ack;
    wire [31:0] ic_m_addr, ic_m_wdata, ic_m_rdata;
    wire        dc_m_req, dc_m_we, dc_m_ack;
    wire [31:0] dc_m_addr, dc_m_wdata, dc_m_rdata;
    wire        dc_c_req, dc_c_we, dc_c_ready;
    wire [31:0] dc_c_addr, dc_c_wdata, dc_c_rdata;
    wire [3:0]  dc_c_be;
    wire [31:0] backing_wdata, backing_rdata;

    cache #(.LINES(I_LINES), .WORDS(WORDS), .RO(1)) icache (
        .clk(clk), .rst(rst),
        .c_req(i_req), .c_we(1'b0), .c_addr(i_addr), .c_wdata(32'd0), .c_be(4'd0),
        .c_rdata(i_rdata), .c_ready(i_ready),
        .m_req(ic_m_req), .m_we(ic_m_we), .m_addr(ic_m_addr), .m_wdata(ic_m_wdata),
        .m_rdata(ic_m_rdata), .m_ack(ic_m_ack),
        .hits(i_hits), .misses(i_misses)
    );

    cache_client_arbiter2 d_cpu_arb (
        .clk(clk), .rst(rst),
        .a_req(d_req), .a_we(d_we), .a_addr(d_addr), .a_wdata(d_wdata), .a_be(d_be),
        .a_rdata(d_rdata), .a_ready(d_ready),
        .b_req(ptw_req), .b_we(ptw_we), .b_addr(ptw_addr), .b_wdata(ptw_wdata), .b_be(ptw_be),
        .b_rdata(ptw_rdata), .b_ready(ptw_ready),
        .c_req(dc_c_req), .c_we(dc_c_we), .c_addr(dc_c_addr), .c_wdata(dc_c_wdata), .c_be(dc_c_be),
        .c_rdata(dc_c_rdata), .c_ready(dc_c_ready)
    );

    cache #(.LINES(D_LINES), .WORDS(WORDS), .RO(0)) dcache (
        .clk(clk), .rst(rst),
        .c_req(dc_c_req), .c_we(dc_c_we), .c_addr(dc_c_addr), .c_wdata(dc_c_wdata), .c_be(dc_c_be),
        .c_rdata(dc_c_rdata), .c_ready(dc_c_ready),
        .m_req(dc_m_req), .m_we(dc_m_we), .m_addr(dc_m_addr), .m_wdata(dc_m_wdata),
        .m_rdata(dc_m_rdata), .m_ack(dc_m_ack),
        .hits(d_hits), .misses(d_misses)
    );

    mem_arbiter2 arb (
        .clk(clk), .rst(rst),
        .i_req(ic_m_req), .i_we(ic_m_we), .i_addr(ic_m_addr), .i_wdata(ic_m_wdata),
        .i_rdata(ic_m_rdata), .i_ack(ic_m_ack),
        .d_req(dc_m_req), .d_we(dc_m_we), .d_addr(dc_m_addr), .d_wdata(dc_m_wdata),
        .d_rdata(dc_m_rdata), .d_ack(dc_m_ack),
        .m_req(backing_req), .m_we(backing_we), .m_addr(backing_addr), .m_wdata(backing_wdata),
        .m_rdata(backing_rdata), .m_ack(backing_ack)
    );

    slowmem #(
        .MEMW(MEMW),
        .LAT(LAT),
        .RAMBASE(RAMBASE),
        .MEMFILE(MEMFILE),
        .MEMFILE_WORDS(MEMFILE_WORDS)
    ) backing (
        .clk(clk), .rst(rst),
        .m_req(backing_req), .m_we(backing_we), .m_addr(backing_addr),
        .m_wdata(backing_wdata), .m_rdata(backing_rdata), .m_ack(backing_ack)
    );
endmodule
