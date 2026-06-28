`timescale 1ns/1ps
// Multi-cycle instruction fetch stage for the future rvlinux stall FSM.
//
// It drives the core-facing side of rvlinux_mem_boundary for instruction fetches
// and reconstructs the same lo16/raw32 values that rvlinux.v currently builds
// with combinational pread() calls. A 32-bit instruction at pc[1]=1 needs a
// second fetch at pc+2, which also covers the Sv32 cross-page case.
module rvlinux_fetch_stage(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [31:0] pc,

    output reg         done,
    output wire        busy,
    output reg         fault,
    output reg  [3:0]  cause,
    output reg  [31:0] fault_va,
    output reg  [15:0] lo16,
    output reg  [31:0] raw32,
    output reg         is_rvc,
    output reg         used_second_fetch,

    output wire        mem_req,
    output wire [1:0]  mem_access,
    output wire [31:0] mem_va,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_be,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,
    input  wire        mem_fault,
    input  wire [3:0]  mem_cause
);
    localparam ACC_FETCH = 2'd0;

    localparam S_IDLE      = 3'd0;
    localparam S_REQ0      = 3'd1;
    localparam S_GAP0      = 3'd2;
    localparam S_REQ1      = 3'd3;
    localparam S_WAIT_DROP = 3'd4;

    reg [2:0]  state;
    reg [31:0] pc_r;
    reg [31:0] word0_r;

    wire [15:0] first_lo16 = pc_r[1] ? mem_rdata[31:16] : mem_rdata[15:0];
    wire        first_is_rvc = (first_lo16[1:0] != 2'b11);
    wire        need_second = pc_r[1] && !first_is_rvc;

    assign busy = (state != S_IDLE);
    assign mem_req = (state == S_REQ0) || (state == S_REQ1);
    assign mem_access = ACC_FETCH;
    assign mem_va = (state == S_REQ1) ? (pc_r + 32'd2) : pc_r;
    assign mem_wdata = 32'd0;
    assign mem_be = 4'h0;

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            pc_r <= 32'd0;
            word0_r <= 32'd0;
            fault <= 1'b0;
            cause <= 4'd0;
            fault_va <= 32'd0;
            lo16 <= 16'd0;
            raw32 <= 32'd0;
            is_rvc <= 1'b0;
            used_second_fetch <= 1'b0;
        end else begin
            case (state)
            S_IDLE: begin
                if (start) begin
                    pc_r <= pc;
                    fault <= 1'b0;
                    cause <= 4'd0;
                    fault_va <= pc;
                    used_second_fetch <= 1'b0;
                    state <= S_REQ0;
                end
            end

            S_REQ0: begin
                if (mem_ready) begin
                    word0_r <= mem_rdata;
                    lo16 <= first_lo16;
                    is_rvc <= first_is_rvc;
                    fault_va <= pc_r;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        raw32 <= 32'd0;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end else if (need_second) begin
                        state <= S_GAP0;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        raw32 <= pc_r[1] ? {16'd0, mem_rdata[31:16]} : mem_rdata;
                        done <= 1'b1;
                        state <= S_WAIT_DROP;
                    end
                end
            end

            S_GAP0: begin
                state <= S_REQ1;
            end

            S_REQ1: begin
                if (mem_ready) begin
                    fault_va <= pc_r;
                    used_second_fetch <= 1'b1;
                    if (mem_fault) begin
                        fault <= 1'b1;
                        cause <= mem_cause;
                        raw32 <= 32'd0;
                    end else begin
                        fault <= 1'b0;
                        cause <= 4'd0;
                        raw32 <= {mem_rdata[15:0], word0_r[31:16]};
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
endmodule
