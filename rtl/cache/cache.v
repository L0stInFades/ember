`timescale 1ns/1ps
// Direct-mapped, write-back, write-allocate cache.
// Single-cycle hit; a miss stalls the CPU while the victim line is (optionally)
// written back and the requested line is refilled from a multi-cycle word-wide
// backing memory. Set RO=1 for an instruction cache (writes unused).
//
// Handshake: the CPU holds c_req and the address/data stable until it observes
// a one-cycle c_ready pulse, then drops c_req for at least one cycle.
module cache #(
    parameter LINES = 64,          // cache lines (power of 2)
    parameter WORDS = 4,           // words per line (power of 2)
    parameter RO    = 0            // 1 = read-only (I-cache)
)(
    input  wire        clk, rst,
    // CPU side
    input  wire        c_req,
    input  wire        c_we,
    input  wire [31:0] c_addr,     // byte address
    input  wire [31:0] c_wdata,
    input  wire [3:0]  c_be,       // byte enables (writes)
    output reg  [31:0] c_rdata,
    output reg         c_ready,    // 1-cycle pulse when access completes
    // memory side (word interface, multi-cycle, req held until ack)
    output reg         m_req,
    output reg         m_we,
    output reg  [31:0] m_addr,
    output reg  [31:0] m_wdata,
    input  wire [31:0] m_rdata,
    input  wire        m_ack,
    // stats
    output reg  [31:0] hits,
    output reg  [31:0] misses
);
    localparam OFFW = $clog2(WORDS);
    localparam IDXW = $clog2(LINES);
    localparam TAGW = 32 - 2 - OFFW - IDXW;

    wire [OFFW-1:0] woff = c_addr[2+OFFW-1      : 2];
    wire [IDXW-1:0] idx  = c_addr[2+OFFW+IDXW-1 : 2+OFFW];
    wire [TAGW-1:0] tag  = c_addr[31            : 2+OFFW+IDXW];

    reg [TAGW-1:0] tag_arr  [0:LINES-1];
    reg            valid    [0:LINES-1];
    reg            dirty    [0:LINES-1];
    reg [31:0]     data_arr [0:LINES*WORDS-1];

    wire hit = valid[idx] && (tag_arr[idx] == tag);
    wire [31:0] hit_word = data_arr[idx*WORDS + woff];

    localparam S_IDLE=3'd0, S_WB=3'd1, S_FILL=3'd2, S_SVC=3'd3, S_WAIT=3'd4;
    reg [2:0] state;
    reg [OFFW:0]   wcnt;           // word counter for line transfers
    reg [TAGW-1:0] vtag;           // victim tag for writeback

    integer i;
    always @(posedge clk) begin
        c_ready <= 1'b0;
        m_req   <= 1'b0;
        if (rst) begin
            state<=S_IDLE; c_ready<=0; hits<=0; misses<=0; wcnt<=0;
            for (i=0;i<LINES;i=i+1) begin valid[i]<=1'b0; dirty[i]<=1'b0; end
        end else begin
            case (state)
            S_IDLE: if (c_req) begin
                if (hit) begin
                    hits <= hits + 1;
                    if (c_we && !RO) begin
                        data_arr[idx*WORDS+woff] <= apply_be(hit_word, c_wdata, c_be);
                        dirty[idx] <= 1'b1;
                    end
                    c_rdata <= hit_word;
                    c_ready <= 1'b1;
                    state   <= S_WAIT;
                end else begin
                    misses <= misses + 1;
                    wcnt   <= 0;
                    if (valid[idx] && dirty[idx] && !RO) begin
                        vtag  <= tag_arr[idx];
                        state <= S_WB;
                    end else state <= S_FILL;
                end
            end
            S_WB: begin                       // flush dirty victim, word by word
                m_req   <= 1'b1;
                m_we    <= 1'b1;
                m_addr  <= {vtag, idx, wcnt[OFFW-1:0], 2'b00};
                m_wdata <= data_arr[idx*WORDS + wcnt[OFFW-1:0]];
                if (m_ack) begin
                    m_req <= 1'b0;
                    if (wcnt == WORDS-1) begin wcnt<=0; state<=S_FILL; end
                    else wcnt <= wcnt + 1;
                end
            end
            S_FILL: begin                     // refill requested line, word by word
                m_req  <= 1'b1;
                m_we   <= 1'b0;
                m_addr <= {tag, idx, wcnt[OFFW-1:0], 2'b00};
                if (m_ack) begin
                    m_req <= 1'b0;
                    data_arr[idx*WORDS + wcnt[OFFW-1:0]] <= m_rdata;
                    if (wcnt == WORDS-1) begin
                        wcnt <= 0;
                        tag_arr[idx] <= tag;
                        valid[idx]   <= 1'b1;
                        dirty[idx]   <= 1'b0;
                        state <= S_SVC;
                    end else wcnt <= wcnt + 1;
                end
            end
            S_SVC: begin                      // line present: service original request
                if (c_we && !RO) begin
                    data_arr[idx*WORDS+woff] <= apply_be(data_arr[idx*WORDS+woff], c_wdata, c_be);
                    dirty[idx] <= 1'b1;
                end
                c_rdata <= data_arr[idx*WORDS+woff];
                c_ready <= 1'b1;
                state   <= S_WAIT;
            end
            S_WAIT: if (!c_req) state <= S_IDLE;   // wait for CPU to drop req
            endcase
        end
    end

    function [31:0] apply_be(input [31:0] old, input [31:0] nw, input [3:0] be);
        apply_be = { be[3]?nw[31:24]:old[31:24], be[2]?nw[23:16]:old[23:16],
                     be[1]?nw[15:8] :old[15:8],  be[0]?nw[7:0]  :old[7:0] };
    endfunction
endmodule
