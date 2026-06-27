`timescale 1ns/1ps
// Word-wide backing memory with a fixed access latency. Request is held until
// a one-cycle ack. Initialized with a deterministic pattern for verification.
module slowmem #(
    parameter MEMW = 1<<14,        // words
    parameter LAT  = 8             // cycles per word access
)(
    input  wire        clk, rst,
    input  wire        m_req,
    input  wire        m_we,
    input  wire [31:0] m_addr,     // byte address (word aligned)
    input  wire [31:0] m_wdata,
    output reg  [31:0] m_rdata,
    output reg         m_ack
);
    reg [31:0] mem [0:MEMW-1];
    reg        busy;
    reg [15:0] cnt;
    integer k;
    initial begin
        for (k=0;k<MEMW;k=k+1) mem[k] = (k<<2) ^ 32'hA5A5_0000;  // ref pattern
        busy=0; cnt=0; m_ack=0; m_rdata=0;
    end
    always @(posedge clk) begin
        if (rst) begin m_ack<=0; busy<=0; cnt<=0; end
        else begin
            m_ack <= 1'b0;
            if (!busy) begin
                if (m_req) begin busy<=1'b1; cnt<=LAT[15:0]-16'd1; end
            end else if (cnt==0) begin
                m_ack <= 1'b1; busy <= 1'b0;
                if (m_we) mem[m_addr>>2] <= m_wdata;
                m_rdata <= mem[m_addr>>2];
            end else cnt <= cnt - 16'd1;
        end
    end
endmodule
