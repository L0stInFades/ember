`timescale 1ns/1ps
// Synthesis/PnR wrapper for rvlinux.v under RVLINUX_SYNTH_SHELL. It keeps
// package IO small while preserving the multicycle core, cache, PTW, MMIO, and
// debug-output paths through the rvlinux top-level port contract.
module syn_top_rvlinux_synth_shell(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] din,
    input  wire [7:0]  ctrl,
    output reg  [31:0] dout
);
    reg [31:0] din_r;
    reg [7:0]  ctrl_r;

    wire        uart_we;
    wire [7:0]  uart_data;
    wire        rx_ready;
    wire        halt;
    wire [31:0] exit_code;
    wire [31:0] dbg_pc;
    wire [1:0]  dbg_priv;
    wire [31:0] dbg_rval;
    wire [31:0] dbg_mval;
    wire [31:0] dbg_scause;
    wire [31:0] dbg_mcause;
    wire [31:0] dbg_mip;
    wire [31:0] dbg_mie;
    wire [31:0] dbg_stval;
    wire [31:0] dbg_mtime;
    wire [31:0] dbg_mtimecmp;

    always @(posedge clk) begin
        if (rst) begin
            din_r <= 32'd0;
            ctrl_r <= 8'd0;
        end else begin
            din_r <= din;
            ctrl_r <= ctrl;
        end
    end

    rvlinux #(
        .MEMWORDS(16384),
        .RAMBASE(32'h8000_0000)
    ) u (
        .clk(clk),
        .rst(rst),
        .uart_we(uart_we),
        .uart_data(uart_data),
        .rx_valid(ctrl_r[0]),
        .rx_byte_in(din_r[7:0]),
        .rx_ready(rx_ready),
        .halt(halt),
        .exit_code(exit_code),
        .dbg_pc(dbg_pc),
        .dbg_priv(dbg_priv),
        .dbg_rsel(ctrl_r[5:1]),
        .dbg_rval(dbg_rval),
        .dbg_maddr(din_r),
        .dbg_mval(dbg_mval),
        .dbg_scause(dbg_scause),
        .dbg_mcause(dbg_mcause),
        .dbg_mip(dbg_mip),
        .dbg_mie(dbg_mie),
        .dbg_stval(dbg_stval),
        .dbg_mtime(dbg_mtime),
        .dbg_mtimecmp(dbg_mtimecmp)
    );

    always @(posedge clk) begin
        dout <= dbg_pc ^ dbg_rval ^ dbg_mval ^ dbg_scause ^ dbg_mcause ^
                dbg_mip ^ dbg_mie ^ dbg_stval ^ dbg_mtime ^ dbg_mtimecmp ^
                exit_code ^ {20'd0, dbg_priv, rx_ready, halt, uart_we, uart_data};
    end
endmodule
