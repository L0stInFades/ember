`timescale 1ns/1ps
// Multi-cycle LR/SC/AMO stage for the future rvlinux stall FSM.
//
// Word atomics are split into explicit boundary transactions. Store-check
// transactions validate store permission and perform Sv32 A/D updates without
// issuing a final data write, which is needed for failed SC.W and AMO faults.
module rvlinux_amo_stage(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [4:0]  funct5,
    input  wire [31:0] va,
    input  wire [31:0] rs2_value,
    input  wire        clear_reservation,

    output reg         done,
    output wire        busy,
    output reg         fault,
    output reg  [3:0]  cause,
    output reg  [31:0] fault_va,
    output reg  [31:0] pa,
    output reg  [31:0] rd_value,
    output reg         reservation_valid,
    output reg  [31:0] reservation_addr,

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
    localparam ACC_LOAD        = 2'd1;
    localparam ACC_STORE       = 2'd2;
    localparam ACC_STORE_CHECK = 2'd3;

    localparam F5_AMOADD  = 5'b00000;
    localparam F5_AMOSWAP = 5'b00001;
    localparam F5_LR      = 5'b00010;
    localparam F5_SC      = 5'b00011;
    localparam F5_AMOXOR  = 5'b00100;
    localparam F5_AMOOR   = 5'b01000;
    localparam F5_AMOAND  = 5'b01100;
    localparam F5_AMOMIN  = 5'b10000;
    localparam F5_AMOMAX  = 5'b10100;
    localparam F5_AMOMINU = 5'b11000;
    localparam F5_AMOMAXU = 5'b11100;

    localparam CAUSE_LOAD_MAL  = 4'd4;
    localparam CAUSE_STORE_MAL = 4'd6;

    localparam S_IDLE          = 4'd0;
    localparam S_LR_REQ        = 4'd1;
    localparam S_SC_CHECK      = 4'd2;
    localparam S_SC_STORE_GAP  = 4'd3;
    localparam S_SC_STORE      = 4'd4;
    localparam S_AMO_CHECK     = 4'd5;
    localparam S_AMO_LOAD_GAP  = 4'd6;
    localparam S_AMO_LOAD      = 4'd7;
    localparam S_AMO_STORE_GAP = 4'd8;
    localparam S_AMO_STORE     = 4'd9;
    localparam S_WAIT_DROP     = 4'd10;

    reg [3:0]  state;
    reg [4:0]  funct5_r;
    reg [31:0] va_r;
    reg [31:0] rs2_r;
    reg [31:0] old_r;

    wire is_lr_start = (funct5 == F5_LR);
    wire is_sc_start = (funct5 == F5_SC);
    wire misaligned = (va[1:0] != 2'b00);
    wire [31:0] mem_pa_word = {mem_pa[31:2], 2'b00};
    wire sc_match = reservation_valid && !clear_reservation &&
                    (reservation_addr == mem_pa_word);

    assign busy = (state != S_IDLE);
    assign mem_req = (state == S_LR_REQ) ||
                     (state == S_SC_CHECK) ||
                     (state == S_SC_STORE) ||
                     (state == S_AMO_CHECK) ||
                     (state == S_AMO_LOAD) ||
                     (state == S_AMO_STORE);
    assign mem_access = ((state == S_LR_REQ) || (state == S_AMO_LOAD)) ? ACC_LOAD :
                        ((state == S_SC_CHECK) || (state == S_AMO_CHECK)) ?
                            ACC_STORE_CHECK : ACC_STORE;
    assign mem_va = va_r;
    assign mem_wdata = (state == S_AMO_STORE) ?
                       amo_result(funct5_r, old_r, rs2_r) : rs2_r;
    assign mem_be = 4'hF;

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            funct5_r <= 5'd0;
            va_r <= 32'd0;
            rs2_r <= 32'd0;
            old_r <= 32'd0;
            fault <= 1'b0;
            cause <= 4'd0;
            fault_va <= 32'd0;
            pa <= 32'd0;
            rd_value <= 32'd0;
            reservation_valid <= 1'b0;
            reservation_addr <= 32'd0;
        end else begin
            case (state)
            S_IDLE: begin
                if (start) begin
                    funct5_r <= funct5;
                    va_r <= va;
                    rs2_r <= rs2_value;
                    old_r <= 32'd0;
                    fault_va <= va;
                    pa <= 32'd0;
                    rd_value <= 32'd0;
                    if (misaligned) begin
                        fault <= 1'b1;
                        cause <= is_lr_start ? CAUSE_LOAD_MAL : CAUSE_STORE_MAL;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        if (is_lr_start)
                            state <= S_LR_REQ;
                        else if (is_sc_start)
                            state <= S_SC_CHECK;
                        else
                            state <= S_AMO_CHECK;
                    end
                end
            end

            S_LR_REQ: begin
                if (mem_ready) begin
                    fault_va <= va_r;
                    pa <= mem_pa;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        rd_value <= 32'd0;
                        reservation_valid <= 1'b0;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        rd_value <= mem_rdata;
                        reservation_valid <= 1'b1;
                        reservation_addr <= mem_pa_word;
                    end
                    done <= 1'b1;
                    state <= S_WAIT_DROP;
                end
            end

            S_SC_CHECK: begin
                if (mem_ready) begin
                    fault_va <= va_r;
                    pa <= mem_pa;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        rd_value <= 32'd1;
                        reservation_valid <= 1'b0;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else if (sc_match) begin
                        state <= S_SC_STORE_GAP;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        rd_value <= 32'd1;
                        reservation_valid <= 1'b0;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end
                end
            end

            S_SC_STORE_GAP: begin
                state <= S_SC_STORE;
            end

            S_SC_STORE: begin
                if (mem_ready) begin
                    fault_va <= va_r;
                    pa <= mem_pa;
                    reservation_valid <= 1'b0;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        rd_value <= 32'd1;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        rd_value <= 32'd0;
                    end
                    done <= 1'b1;
                    state <= S_WAIT_DROP;
                end
            end

            S_AMO_CHECK: begin
                if (mem_ready) begin
                    fault_va <= va_r;
                    pa <= mem_pa;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        rd_value <= 32'd0;
                        reservation_valid <= 1'b0;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else begin
                        state <= S_AMO_LOAD_GAP;
                    end
                end
            end

            S_AMO_LOAD_GAP: begin
                state <= S_AMO_LOAD;
            end

            S_AMO_LOAD: begin
                if (mem_ready) begin
                    fault_va <= va_r;
                    pa <= mem_pa;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        rd_value <= 32'd0;
                        reservation_valid <= 1'b0;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        old_r <= mem_rdata;
                        state <= S_AMO_STORE_GAP;
                    end
                end
            end

            S_AMO_STORE_GAP: begin
                state <= S_AMO_STORE;
            end

            S_AMO_STORE: begin
                if (mem_ready) begin
                    fault_va <= va_r;
                    pa <= mem_pa;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        rd_value <= 32'd0;
                        reservation_valid <= 1'b0;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        rd_value <= old_r;
                        if (reservation_valid && (reservation_addr == mem_pa_word))
                            reservation_valid <= 1'b0;
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

            if (clear_reservation) begin
                reservation_valid <= 1'b0;
                reservation_addr <= 32'd0;
            end
        end
    end

    function [31:0] amo_result;
        input [4:0]  op;
        input [31:0] a;
        input [31:0] b;
        reg signed [31:0] sa;
        reg signed [31:0] sb;
        begin
            sa = a;
            sb = b;
            case (op)
            F5_AMOSWAP: amo_result = b;
            F5_AMOADD:  amo_result = a + b;
            F5_AMOXOR:  amo_result = a ^ b;
            F5_AMOAND:  amo_result = a & b;
            F5_AMOOR:   amo_result = a | b;
            F5_AMOMIN:  amo_result = (sa < sb) ? a : b;
            F5_AMOMAX:  amo_result = (sa > sb) ? a : b;
            F5_AMOMINU: amo_result = (a < b) ? a : b;
            F5_AMOMAXU: amo_result = (a > b) ? a : b;
            default:    amo_result = b;
            endcase
        end
    endfunction
endmodule
