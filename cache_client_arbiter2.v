`timescale 1ns/1ps
// Two-client arbiter for a cache CPU-side req/ready port.
//
// Both clients hold req/address/data stable until their one-cycle ready pulse,
// then drop req for at least one cycle. The arbiter drives one request into the
// cache and routes c_rdata/c_ready back to the granted client.
module cache_client_arbiter2(
    input  wire        clk,
    input  wire        rst,

    input  wire        a_req,
    input  wire        a_we,
    input  wire [31:0] a_addr,
    input  wire [31:0] a_wdata,
    input  wire [3:0]  a_be,
    output reg  [31:0] a_rdata,
    output reg         a_ready,

    input  wire        b_req,
    input  wire        b_we,
    input  wire [31:0] b_addr,
    input  wire [31:0] b_wdata,
    input  wire [3:0]  b_be,
    output reg  [31:0] b_rdata,
    output reg         b_ready,

    output reg         c_req,
    output reg         c_we,
    output reg  [31:0] c_addr,
    output reg  [31:0] c_wdata,
    output reg  [3:0]  c_be,
    input  wire [31:0] c_rdata,
    input  wire        c_ready
);
    localparam S_IDLE = 2'd0;
    localparam S_BUSY = 2'd1;
    localparam S_WAIT = 2'd2;

    localparam G_A = 1'b0;
    localparam G_B = 1'b1;

    reg [1:0] state;
    reg       grant;
    reg       last_grant;
    reg       lat_we;
    reg [31:0] lat_addr;
    reg [31:0] lat_wdata;
    reg [3:0]  lat_be;

    wire choose_b = b_req && (!a_req || last_grant == G_A);
    wire choose_a = a_req && (!b_req || last_grant == G_B);

    always @(posedge clk) begin
        a_ready <= 1'b0;
        b_ready <= 1'b0;
        c_req <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            grant <= G_A;
            last_grant <= G_B;
            lat_we <= 1'b0;
            lat_addr <= 32'd0;
            lat_wdata <= 32'd0;
            lat_be <= 4'd0;
            a_rdata <= 32'd0;
            b_rdata <= 32'd0;
            c_we <= 1'b0;
            c_addr <= 32'd0;
            c_wdata <= 32'd0;
            c_be <= 4'd0;
        end else begin
            case (state)
            S_IDLE: begin
                if (choose_b) begin
                    grant <= G_B;
                    lat_we <= b_we;
                    lat_addr <= b_addr;
                    lat_wdata <= b_wdata;
                    lat_be <= b_be;
                    state <= S_BUSY;
                end else if (choose_a) begin
                    grant <= G_A;
                    lat_we <= a_we;
                    lat_addr <= a_addr;
                    lat_wdata <= a_wdata;
                    lat_be <= a_be;
                    state <= S_BUSY;
                end
            end

            S_BUSY: begin
                c_req <= 1'b1;
                c_we <= lat_we;
                c_addr <= lat_addr;
                c_wdata <= lat_wdata;
                c_be <= lat_be;
                if (c_ready) begin
                    c_req <= 1'b0;
                    last_grant <= grant;
                    if (grant == G_B) begin
                        b_rdata <= c_rdata;
                        b_ready <= 1'b1;
                    end else begin
                        a_rdata <= c_rdata;
                        a_ready <= 1'b1;
                    end
                    state <= S_WAIT;
                end
            end

            S_WAIT: begin
                if ((grant == G_B && !b_req) || (grant == G_A && !a_req))
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
