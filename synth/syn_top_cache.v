`timescale 1ns/1ps
// Synthesis wrapper: funnels the cache's wide buses through one 32-bit in/out
// so it fits the device IO budget, to measure cache logic area/Fmax.
module syn_top_cache(
    input  wire clk, rst,
    input  wire c_req, c_we, m_ack,
    input  wire [31:0] din,
    output reg  [31:0] dout
);
    wire [31:0] c_rdata, m_addr, m_wdata, hits, misses;
    wire c_ready, m_req, m_we;
    cache #(.LINES(64), .WORDS(4)) u(
        .clk(clk), .rst(rst),
        .c_req(c_req), .c_we(c_we), .c_addr(din), .c_wdata(din), .c_be(din[3:0]),
        .c_rdata(c_rdata), .c_ready(c_ready),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(din), .m_ack(m_ack), .hits(hits), .misses(misses));
    always @(posedge clk)
        dout <= c_rdata ^ m_addr ^ m_wdata ^ hits ^ misses ^ {29'b0, c_ready, m_req, m_we};
endmodule
