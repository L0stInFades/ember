`timescale 1ns/1ps
// Synthesis/PnR wrapper for the split L1 subsystem. It keeps top-level IO small
// while preventing the I$/D$/arbiter/backing-memory datapaths from being trimmed.
module syn_top_l1_mem_system(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] din,
    input  wire [3:0]  ctrl,
    output reg  [31:0] dout
);
    wire [31:0] i_rdata, d_rdata;
    wire        i_ready, d_ready;
    wire [31:0] ptw_rdata;
    wire        ptw_ready;
    wire [31:0] i_hits, i_misses, d_hits, d_misses;
    wire        backing_req, backing_we, backing_ack;
    wire [31:0] backing_addr;
    reg  [31:0] din_r;
    reg  [3:0]  ctrl_r;

    always @(posedge clk) begin
        if (rst) begin
            din_r <= 32'd0;
            ctrl_r <= 4'd0;
        end else begin
            din_r <= din;
            ctrl_r <= ctrl;
        end
    end

    l1_mem_system #(
        .I_LINES(64),
        .D_LINES(64),
        .WORDS(4),
        .MEMW(1<<14),
        .LAT(8)
    ) u (
        .clk(clk), .rst(rst),
        .i_req(ctrl_r[0]), .i_addr(din_r), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(ctrl_r[1]), .d_we(ctrl_r[2]), .d_addr(din_r ^ 32'h0000_1000),
        .d_wdata({din_r[15:0], din_r[31:16]}), .d_be(ctrl_r),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .ptw_req(ctrl_r[3]), .ptw_we(1'b0), .ptw_addr(din_r ^ 32'h0000_2000),
        .ptw_wdata(32'd0), .ptw_be(4'hF), .ptw_rdata(ptw_rdata), .ptw_ready(ptw_ready),
        .i_hits(i_hits), .i_misses(i_misses), .d_hits(d_hits), .d_misses(d_misses),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    always @(posedge clk) begin
        dout <= i_rdata ^ d_rdata ^ ptw_rdata ^ i_hits ^ i_misses ^ d_hits ^ d_misses ^
                backing_addr ^ {28'd0, backing_ack, backing_we, backing_req,
                                i_ready ^ d_ready ^ ptw_ready};
    end
endmodule
