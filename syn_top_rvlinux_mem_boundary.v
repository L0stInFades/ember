`timescale 1ns/1ps
// Synthesis/PnR wrapper for rvlinux_mem_boundary. It keeps package IO small
// while preserving the translation, A/D update, I$, D$, and backing-memory paths.
module syn_top_rvlinux_mem_boundary(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] din,
    input  wire [7:0]  ctrl,
    output reg  [31:0] dout
);
    reg [31:0] din_r;
    reg [7:0]  ctrl_r;

    wire [31:0] rdata;
    wire        ready;
    wire        fault;
    wire [3:0]  cause;
    wire [31:0] pa;
    wire        busy;
    wire [31:0] i_hits, i_misses, d_hits, d_misses, ad_writes;
    wire        backing_req, backing_we, backing_ack;
    wire [31:0] backing_addr;

    wire [31:0] satp = {ctrl_r[7], 11'd0, din_r[19:0]};
    wire [1:0]  priv = ctrl_r[5:4];

    always @(posedge clk) begin
        if (rst) begin
            din_r <= 32'd0;
            ctrl_r <= 8'd0;
        end else begin
            din_r <= din;
            ctrl_r <= ctrl;
        end
    end

    rvlinux_mem_boundary #(
        .I_LINES(64),
        .D_LINES(64),
        .WORDS(4),
        .MEMWORDS(1<<14),
        .LAT(8),
        .RAMBASE(32'h0000_0000)
    ) u (
        .clk(clk), .rst(rst),
        .core_req(ctrl_r[0]),
        .core_access(ctrl_r[2:1]),
        .core_va(din_r),
        .core_wdata({din_r[7:0], din_r[15:8], din_r[23:16], din_r[31:24]}),
        .core_be(ctrl_r[7:4]),
        .satp(satp),
        .priv(priv),
        .sum(ctrl_r[6]),
        .mxr(ctrl_r[3]),
        .tlb_flush(1'b0),
        .core_rdata(rdata),
        .core_ready(ready),
        .core_fault(fault),
        .core_cause(cause),
        .core_pa(pa),
        .core_busy(busy),
        .i_hits(i_hits),
        .i_misses(i_misses),
        .d_hits(d_hits),
        .d_misses(d_misses),
        .ad_writes(ad_writes),
        .backing_req(backing_req),
        .backing_we(backing_we),
        .backing_addr(backing_addr),
        .backing_ack(backing_ack)
    );

    always @(posedge clk) begin
        dout <= rdata ^ pa ^ i_hits ^ i_misses ^ d_hits ^ d_misses ^ ad_writes ^
                backing_addr ^ {24'd0, cause, busy, fault, ready, backing_ack,
                                backing_we, backing_req};
    end
endmodule
