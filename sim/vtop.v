`timescale 1ns/1ps
// Sim top wrapping rvlinux with full 64MB RAM, loads MEMFILE via readmemh.
module vtop #(parameter MEMFILE="linux-build/fw_payload.hex")(
    input  wire        clk,
    input  wire        rst,
    output wire        uart_we,
    output wire [7:0]  uart_data,
    input  wire        rx_valid,
    input  wire [7:0]  rx_byte_in,
    output wire        rx_ready,
    output wire        halt,
    output wire [31:0] exit_code,
    output wire [31:0] dbg_pc,
    output wire [1:0]  dbg_priv,
    input  wire [4:0]  dbg_rsel,
    output wire [31:0] dbg_rval,
    input  wire [31:0] dbg_maddr,
    output wire [31:0] dbg_mval,
    output wire [31:0] dbg_scause,
    output wire [31:0] dbg_mcause,
    output wire [31:0] dbg_mip,
    output wire [31:0] dbg_mie,
    output wire [31:0] dbg_stval,
    output wire [31:0] dbg_mtime,
    output wire [31:0] dbg_mtimecmp
);
    rvlinux #(.MEMFILE(MEMFILE), .MEMWORDS(32*1024*1024)) dut(
        .clk(clk), .rst(rst),
        .uart_we(uart_we), .uart_data(uart_data),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in), .rx_ready(rx_ready),
        .halt(halt), .exit_code(exit_code),
        .dbg_pc(dbg_pc), .dbg_priv(dbg_priv),
        .dbg_rsel(dbg_rsel), .dbg_rval(dbg_rval),
        .dbg_maddr(dbg_maddr), .dbg_mval(dbg_mval),
        .dbg_scause(dbg_scause), .dbg_mcause(dbg_mcause),
        .dbg_mip(dbg_mip), .dbg_mie(dbg_mie), .dbg_stval(dbg_stval),
        .dbg_mtime(dbg_mtime), .dbg_mtimecmp(dbg_mtimecmp));
endmodule
