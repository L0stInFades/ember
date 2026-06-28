`timescale 1ns/1ps
// Multi-cycle load/store stage for the future rvlinux stall FSM.
//
// This stage keeps the rvlinux.v data-access semantics that belong near the
// core: misaligned load/store traps, load sign/zero extension, and store byte
// enables. Address translation, A/D updates, and the actual D$ access are
// delegated to rvlinux_mem_boundary.v.
module rvlinux_lsu_stage(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire        is_store,
    input  wire [2:0]  funct3,
    input  wire [31:0] va,
    input  wire [31:0] store_data,

    output reg         done,
    output wire        busy,
    output reg         fault,
    output reg  [3:0]  cause,
    output reg  [31:0] fault_va,
    output reg  [31:0] pa,
    output reg  [31:0] load_data,

    output wire        mem_req,
    output wire [1:0]  mem_access,
    output wire [31:0] mem_va,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_be,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,
    input  wire        mem_fault,
    input  wire [3:0]  mem_cause,
    input  wire [31:0] mem_pa
);
    localparam ACC_LOAD  = 2'd1;
    localparam ACC_STORE = 2'd2;

    localparam CAUSE_LOAD_MAL  = 4'd4;
    localparam CAUSE_STORE_MAL = 4'd6;

    localparam S_IDLE      = 2'd0;
    localparam S_REQ       = 2'd1;
    localparam S_WAIT_DROP = 2'd2;

    reg [1:0]  state;
    reg        is_store_r;
    reg [2:0]  funct3_r;
    reg [31:0] va_r;
    reg [31:0] store_data_r;

    wire req_half = (!is_store && (funct3 == 3'b001 || funct3 == 3'b101)) ||
                    ( is_store &&  funct3 == 3'b001);
    wire req_word = (funct3 == 3'b010);
    wire misaligned = (req_half && va[0]) || (req_word && (va[1:0] != 2'b00));

    assign busy = (state != S_IDLE);
    assign mem_req = (state == S_REQ);
    assign mem_access = is_store_r ? ACC_STORE : ACC_LOAD;
    assign mem_va = va_r;
    assign mem_wdata = store_wdata(funct3_r, va_r[1:0], store_data_r);
    assign mem_be = is_store_r ? store_be(funct3_r, va_r[1:0]) : 4'hF;

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            is_store_r <= 1'b0;
            funct3_r <= 3'd0;
            va_r <= 32'd0;
            store_data_r <= 32'd0;
            fault <= 1'b0;
            cause <= 4'd0;
            fault_va <= 32'd0;
            pa <= 32'd0;
            load_data <= 32'd0;
        end else begin
            case (state)
            S_IDLE: begin
                if (start) begin
                    is_store_r <= is_store;
                    funct3_r <= funct3;
                    va_r <= va;
                    store_data_r <= store_data;
                    fault_va <= va;
                    pa <= 32'd0;
                    load_data <= 32'd0;
                    if (misaligned) begin
                        fault <= 1'b1;
                        cause <= is_store ? CAUSE_STORE_MAL : CAUSE_LOAD_MAL;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        state <= S_REQ;
                    end
                end
            end

            S_REQ: begin
                if (mem_ready) begin
                    fault_va <= va_r;
                    pa <= mem_pa;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        load_data <= 32'd0;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        load_data <= is_store_r ? 32'd0 :
                                     format_load(mem_rdata, funct3_r, mem_pa[1:0]);
                    end
                    done <= 1'b1;
                    state <= S_WAIT_DROP;
                end
            end

            S_WAIT_DROP: begin
                if (!start)
                    state <= S_IDLE;
            end

            default: begin
                state <= S_IDLE;
            end
            endcase
        end
    end

    function [3:0] store_be;
        input [2:0] f3;
        input [1:0] off;
        begin
            case (f3)
            3'b000: begin
                case (off)
                2'd0: store_be = 4'b0001;
                2'd1: store_be = 4'b0010;
                2'd2: store_be = 4'b0100;
                default: store_be = 4'b1000;
                endcase
            end
            3'b001: store_be = off[1] ? 4'b1100 : 4'b0011;
            default: store_be = 4'b1111;
            endcase
        end
    endfunction

    function [31:0] store_wdata;
        input [2:0]  f3;
        input [1:0]  off;
        input [31:0] data;
        begin
            case (f3)
            3'b000: begin
                case (off)
                2'd0: store_wdata = {24'd0, data[7:0]};
                2'd1: store_wdata = {16'd0, data[7:0], 8'd0};
                2'd2: store_wdata = {8'd0, data[7:0], 16'd0};
                default: store_wdata = {data[7:0], 24'd0};
                endcase
            end
            3'b001: store_wdata = off[1] ? {data[15:0], 16'd0} :
                                           {16'd0, data[15:0]};
            default: store_wdata = data;
            endcase
        end
    endfunction

    function [31:0] format_load;
        input [31:0] word;
        input [2:0]  f3;
        input [1:0]  off;
        reg [7:0]    b;
        reg [15:0]   h;
        begin
            case (off)
            2'd0: b = word[7:0];
            2'd1: b = word[15:8];
            2'd2: b = word[23:16];
            default: b = word[31:24];
            endcase
            h = off[1] ? word[31:16] : word[15:0];

            case (f3)
            3'b000: format_load = {{24{b[7]}}, b};
            3'b001: format_load = {{16{h[15]}}, h};
            3'b100: format_load = {24'd0, b};
            3'b101: format_load = {16'd0, h};
            default: format_load = word;
            endcase
        end
    endfunction
endmodule
