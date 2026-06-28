`timescale 1ns/1ps
// Synthesizable single-port backing memory (BRAM-inferable): registered read,
// one access per request, a one-cycle ack. Addressed by byte address relative to
// BASE. File-loadable for simulation. This is the real-memory replacement for the
// behavioral arrays in the single-cycle cores; sits behind the L1 cache.
module mainmem #(
    parameter MEMWORDS = 1<<18,                 // words (power of 2) ; 1<<18 = 1 MB
    parameter [31:0] BASE = 32'h8000_0000,
    parameter MEMFILE = "prog.hex"
)(
    input  wire        clk, rst,
    input  wire        m_req,
    input  wire        m_we,
    input  wire [31:0] m_addr,                  // byte address (word aligned)
    input  wire [31:0] m_wdata,
    output reg  [31:0] m_rdata,
    output reg         m_ack
);
    reg [31:0] mem [0:MEMWORDS-1];
    wire [31:0] idx = ((m_addr - BASE) >> 2) & (MEMWORDS-1);
    integer k;
    initial begin
        for (k=0;k<MEMWORDS;k=k+1) mem[k]=32'd0;
`ifdef SIM_INIT
        $readmemh(MEMFILE, mem);
`endif
        m_ack=1'b0; m_rdata=32'd0;
    end
    always @(posedge clk) begin
        if (rst) begin
            m_ack <= 1'b0;
        end else begin
            m_ack <= 1'b0;
            if (m_req && !m_ack) begin          // 1-cycle latency, single ack pulse
                if (m_we) mem[idx] <= m_wdata;
                m_rdata <= mem[idx];
                m_ack   <= 1'b1;
            end
        end
    end
endmodule
