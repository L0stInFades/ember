`timescale 1ns/1ps
// Sequential RV32M multiply/divide stage for the future rvlinux stall FSM.
//
// The booting rvlinux.v still uses behavioral * / / / % for simulation speed.
// This stage gives the synthesizable multicycle core path a bounded 32-cycle
// implementation for all RV32M operations without inferring a large combinational
// divider.
module rvlinux_muldiv_stage(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [2:0]  funct3,
    input  wire [31:0] rs1_value,
    input  wire [31:0] rs2_value,

    output reg         done,
    output wire        busy,
    output reg  [31:0] result
);
    localparam S_IDLE      = 2'd0;
    localparam S_MUL       = 2'd1;
    localparam S_DIV       = 2'd2;
    localparam S_WAIT_DROP = 2'd3;

    reg [1:0]  state;
    reg [2:0]  funct3_r;
    reg [5:0]  count;

    reg [63:0] mul_acc;
    reg [63:0] mul_multiplicand;
    reg [31:0] mul_multiplier;
    reg        mul_neg;

    reg [31:0] div_dividend;
    reg [31:0] div_divisor;
    reg [31:0] div_quotient;
    reg [32:0] div_remainder;
    reg        div_quot_neg;
    reg        div_rem_neg;
    reg        div_is_rem;

    wire is_mul_op = (funct3[2] == 1'b0);
    wire mul_a_signed = (funct3 == 3'b000) || (funct3 == 3'b001) ||
                        (funct3 == 3'b010);
    wire mul_b_signed = (funct3 == 3'b000) || (funct3 == 3'b001);
    wire mul_a_neg = mul_a_signed && rs1_value[31];
    wire mul_b_neg = mul_b_signed && rs2_value[31];
    wire [31:0] mul_a_abs = mul_a_neg ? (~rs1_value + 32'd1) : rs1_value;
    wire [31:0] mul_b_abs = mul_b_neg ? (~rs2_value + 32'd1) : rs2_value;

    wire div_signed = (funct3 == 3'b100) || (funct3 == 3'b110);
    wire div_start_is_rem = (funct3 == 3'b110) || (funct3 == 3'b111);
    wire div_a_neg = div_signed && rs1_value[31];
    wire div_b_neg = div_signed && rs2_value[31];
    wire [31:0] div_a_abs = div_a_neg ? (~rs1_value + 32'd1) : rs1_value;
    wire [31:0] div_b_abs = div_b_neg ? (~rs2_value + 32'd1) : rs2_value;
    wire div_by_zero = (rs2_value == 32'd0);
    wire div_overflow = div_signed && (rs1_value == 32'h8000_0000) &&
                        (rs2_value == 32'hffff_ffff);

    wire [63:0] mul_acc_step = mul_multiplier[0] ?
                               (mul_acc + mul_multiplicand) : mul_acc;
    wire [63:0] mul_product = mul_neg ? (~mul_acc_step + 64'd1) : mul_acc_step;

    wire [32:0] div_rem_shift = {div_remainder[31:0], div_dividend[31]};
    wire        div_ge = div_rem_shift >= {1'b0, div_divisor};
    wire [32:0] div_rem_sub = div_rem_shift - {1'b0, div_divisor};
    wire [32:0] div_rem_step = div_ge ? div_rem_sub : div_rem_shift;
    wire [31:0] div_quot_step = {div_quotient[30:0], div_ge};
    wire [31:0] div_quot_signed = div_quot_neg ?
                                  (~div_quot_step + 32'd1) : div_quot_step;
    wire [31:0] div_rem_signed = div_rem_neg ?
                                 (~div_rem_step[31:0] + 32'd1) :
                                 div_rem_step[31:0];

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            funct3_r <= 3'd0;
            count <= 6'd0;
            mul_acc <= 64'd0;
            mul_multiplicand <= 64'd0;
            mul_multiplier <= 32'd0;
            mul_neg <= 1'b0;
            div_dividend <= 32'd0;
            div_divisor <= 32'd0;
            div_quotient <= 32'd0;
            div_remainder <= 33'd0;
            div_quot_neg <= 1'b0;
            div_rem_neg <= 1'b0;
            div_is_rem <= 1'b0;
            result <= 32'd0;
        end else begin
            case (state)
            S_IDLE: begin
                if (start) begin
                    funct3_r <= funct3;
                    count <= 6'd0;
                    if (is_mul_op) begin
                        mul_acc <= 64'd0;
                        mul_multiplicand <= {32'd0, mul_a_abs};
                        mul_multiplier <= mul_b_abs;
                        mul_neg <= mul_a_neg ^ mul_b_neg;
                        result <= 32'd0;
                        state <= S_MUL;
                    end else if (div_by_zero) begin
                        result <= div_start_is_rem ? rs1_value : 32'hffff_ffff;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else if (div_overflow) begin
                        result <= div_start_is_rem ? 32'd0 : 32'h8000_0000;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else begin
                        div_dividend <= div_a_abs;
                        div_divisor <= div_b_abs;
                        div_quotient <= 32'd0;
                        div_remainder <= 33'd0;
                        div_quot_neg <= div_signed && (rs1_value[31] ^ rs2_value[31]);
                        div_rem_neg <= div_signed && rs1_value[31];
                        div_is_rem <= div_start_is_rem;
                        result <= 32'd0;
                        state <= S_DIV;
                    end
                end
            end

            S_MUL: begin
                if (count == 6'd31) begin
                    case (funct3_r)
                    3'b000: result <= mul_product[31:0];
                    default: result <= mul_product[63:32];
                    endcase
                    done <= 1'b1;
                    state <= S_WAIT_DROP;
                end else begin
                    mul_acc <= mul_acc_step;
                    mul_multiplicand <= mul_multiplicand << 1;
                    mul_multiplier <= mul_multiplier >> 1;
                    count <= count + 6'd1;
                end
            end

            S_DIV: begin
                if (count == 6'd31) begin
                    result <= div_is_rem ? div_rem_signed : div_quot_signed;
                    done <= 1'b1;
                    state <= S_WAIT_DROP;
                end else begin
                    div_dividend <= {div_dividend[30:0], 1'b0};
                    div_remainder <= div_rem_step;
                    div_quotient <= div_quot_step;
                    count <= count + 6'd1;
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
endmodule
