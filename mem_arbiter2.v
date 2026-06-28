`timescale 1ns/1ps
// Two-client arbiter for the cache/slowmem word-wide memory interface.
//
// Each client holds req/address/write data stable until it sees a one-cycle ack.
// The arbiter latches one request, drives the shared memory until m_ack, returns
// rdata/ack to that client, then waits for that client to drop req before taking
// another request. Simultaneous requests are served round-robin.
module mem_arbiter2(
    input  wire        clk,
    input  wire        rst,

    input  wire        i_req,
    input  wire        i_we,
    input  wire [31:0] i_addr,
    input  wire [31:0] i_wdata,
    output reg  [31:0] i_rdata,
    output reg         i_ack,

    input  wire        d_req,
    input  wire        d_we,
    input  wire [31:0] d_addr,
    input  wire [31:0] d_wdata,
    output reg  [31:0] d_rdata,
    output reg         d_ack,

    output reg         m_req,
    output reg         m_we,
    output reg  [31:0] m_addr,
    output reg  [31:0] m_wdata,
    input  wire [31:0] m_rdata,
    input  wire        m_ack
);
    localparam S_IDLE = 2'd0;
    localparam S_BUSY = 2'd1;
    localparam S_WAIT = 2'd2;

    localparam G_I = 1'b0;
    localparam G_D = 1'b1;

    reg [1:0]  state;
    reg        grant;
    reg        last_grant;
    reg        lat_we;
    reg [31:0] lat_addr;
    reg [31:0] lat_wdata;

    wire choose_d = d_req && (!i_req || last_grant == G_I);
    wire choose_i = i_req && (!d_req || last_grant == G_D);

    always @(posedge clk) begin
        i_ack <= 1'b0;
        d_ack <= 1'b0;
        m_req <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            grant <= G_I;
            last_grant <= G_D;
            lat_we <= 1'b0;
            lat_addr <= 32'd0;
            lat_wdata <= 32'd0;
            i_rdata <= 32'd0;
            d_rdata <= 32'd0;
            m_we <= 1'b0;
            m_addr <= 32'd0;
            m_wdata <= 32'd0;
        end else begin
            case (state)
            S_IDLE: begin
                if (choose_d) begin
                    grant <= G_D;
                    lat_we <= d_we;
                    lat_addr <= d_addr;
                    lat_wdata <= d_wdata;
                    state <= S_BUSY;
                end else if (choose_i) begin
                    grant <= G_I;
                    lat_we <= i_we;
                    lat_addr <= i_addr;
                    lat_wdata <= i_wdata;
                    state <= S_BUSY;
                end
            end

            S_BUSY: begin
                m_req <= 1'b1;
                m_we <= lat_we;
                m_addr <= lat_addr;
                m_wdata <= lat_wdata;
                if (m_ack) begin
                    m_req <= 1'b0;
                    last_grant <= grant;
                    if (grant == G_D) begin
                        d_rdata <= m_rdata;
                        d_ack <= 1'b1;
                    end else begin
                        i_rdata <= m_rdata;
                        i_ack <= 1'b1;
                    end
                    state <= S_WAIT;
                end
            end

            S_WAIT: begin
                if ((grant == G_D && !d_req) || (grant == G_I && !i_req))
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
