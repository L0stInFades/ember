`timescale 1ns/1ps
// Sequential MMIO/device stage for the multicycle rvlinux core.
//
// This module lifts the qemu-virt device subset out of rvlinux.v: CLINT,
// single-source UART PLIC, 16550-compatible UART registers, and syscon
// poweroff. One request completes with a one-cycle done pulse; callers hold
// start stable until done, then drop start for at least one cycle.
module rvlinux_mmio_stage #(
    parameter [31:0] MTIME_TICK_CYCLES = 32'd1
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire        is_store,
    input  wire [2:0]  funct3,
    input  wire [31:0] pa,
    input  wire [31:0] store_data,

    input  wire        rx_valid,
    input  wire [7:0]  rx_byte_in,
    output wire        rx_ready,

    output reg         done,
    output wire        busy,
    output reg         fault,
    output reg  [3:0]  cause,
    output reg  [31:0] fault_pa,
    output reg  [31:0] load_data,

    output reg         uart_we,
    output reg  [7:0]  uart_data,
    output reg         halt,
    output reg  [31:0] exit_code,
    output wire [31:0] irq_pending,
    output wire [31:0] mtime_out,
    output wire [31:0] mtimecmp_out,
    output wire [63:0] mtime_full_out,
    output wire [63:0] mtimecmp_full_out
);
    localparam CAUSE_LOAD_MAL  = 4'd4;
    localparam CAUSE_STORE_MAL = 4'd6;

    localparam S_IDLE      = 1'd0;
    localparam S_WAIT_DROP = 1'd1;

    localparam MSI = 3;
    localparam MTI = 7;
    localparam SEI = 9;

    reg state;

    reg        msip;
    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    reg [31:0] mtime_tick_count;

    reg [7:0] uart_lcr;
    reg [7:0] uart_ier;
    reg [7:0] uart_mcr;
    reg [7:0] uart_fcr;
    reg [7:0] uart_scr;
    reg [7:0] uart_dll;
    reg [7:0] uart_dlm;
    reg [7:0] rx_data_r;
    reg       rx_have;

    reg [2:0] plic_prio1;
    reg       plic_senable1;
    reg [2:0] plic_sthresh;
    reg       plic_claimed;

    wire is_clint = (pa[31:16] == 16'h0200);
    wire is_plic  = (pa[31:26] == 6'b000011);
    wire is_uart  = (pa[31:8]  == 24'h10_0000);
    wire is_sys   = (pa[31:12] == 20'h11100);

    wire req_half = (!is_store && (funct3 == 3'b001 || funct3 == 3'b101)) ||
                    ( is_store &&  funct3 == 3'b001);
    wire req_word = (funct3 == 3'b010);
    wire misaligned = (req_half && pa[0]) || (req_word && (pa[1:0] != 2'b00));

    wire uart_rx_int = rx_have & uart_ier[0];
    wire uart_tx_int = uart_ier[1];
    wire uart_irq    = uart_rx_int | uart_tx_int;
    wire plic_s_pending = uart_irq & plic_senable1 &
                           (plic_prio1 > plic_sthresh) & ~plic_claimed;

    assign busy = (state != S_IDLE);
    assign rx_ready = rx_valid & ~rx_have;
    assign irq_pending =
        (msip ? (32'd1 << MSI) : 32'd0) |
        ((mtime >= mtimecmp) ? (32'd1 << MTI) : 32'd0) |
        (plic_s_pending ? (32'd1 << SEI) : 32'd0);
    assign mtime_out = mtime[31:0];
    assign mtimecmp_out = mtimecmp[31:0];
    assign mtime_full_out = mtime;
    assign mtimecmp_full_out = mtimecmp;

    wire [7:0] uart_iir = uart_rx_int ? 8'hC4 :
                          uart_tx_int ? 8'hC2 : 8'hC1;
    wire [7:0] uart_lsr = 8'h60 | {7'd0, rx_have};

    reg [31:0] clint_rd;
    reg [31:0] uart_rd;
    reg [31:0] plic_rd;
    reg [31:0] memword;
    reg [31:0] storeword;

    always @(*) begin
        case (pa[15:0])
        16'h0000: clint_rd = {31'd0, msip};
        16'h4000: clint_rd = mtimecmp[31:0];
        16'h4004: clint_rd = mtimecmp[63:32];
        16'hBFF8: clint_rd = mtime[31:0];
        16'hBFFC: clint_rd = mtime[63:32];
        default:  clint_rd = 32'd0;
        endcase
    end

    always @(*) begin
        case (pa[2:0])
        3'd0:    uart_rd = {24'd0, uart_lcr[7] ? uart_dll : rx_data_r};
        3'd1:    uart_rd = {24'd0, uart_lcr[7] ? uart_dlm : uart_ier};
        3'd2:    uart_rd = {24'd0, uart_iir};
        3'd3:    uart_rd = {24'd0, uart_lcr};
        3'd4:    uart_rd = {24'd0, uart_mcr};
        3'd5:    uart_rd = {24'd0, uart_lsr};
        3'd6:    uart_rd = 32'h0000_00B0;
        default: uart_rd = {24'd0, uart_scr};
        endcase
    end

    always @(*) begin
        case (pa[23:0])
        24'h000004: plic_rd = {29'd0, plic_prio1};
        24'h001000: plic_rd = {30'd0, uart_irq, 1'b0};
        24'h002080: plic_rd = {30'd0, plic_senable1, 1'b0};
        24'h201000: plic_rd = {29'd0, plic_sthresh};
        24'h201004: plic_rd = plic_s_pending ? 32'd1 : 32'd0;
        default:    plic_rd = 32'd0;
        endcase
    end

    always @(*) begin
        memword = 32'd0;
        if (is_clint)
            memword = clint_rd;
        else if (is_uart)
            memword = {4{uart_rd[7:0]}};
        else if (is_plic)
            memword = plic_rd;
    end

    always @(*) begin
        storeword = store_merge(memword, funct3, pa[1:0], store_data);
    end

    always @(posedge clk) begin
        done <= 1'b0;
        uart_we <= 1'b0;
        halt <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            fault <= 1'b0;
            cause <= 4'd0;
            fault_pa <= 32'd0;
            load_data <= 32'd0;
            uart_data <= 8'd0;
            exit_code <= 32'd0;
            msip <= 1'b0;
            mtime <= 64'd0;
            mtimecmp <= 64'hffff_ffff_ffff_ffff;
            mtime_tick_count <= 32'd0;
            uart_lcr <= 8'd0;
            uart_ier <= 8'd0;
            uart_mcr <= 8'd0;
            uart_fcr <= 8'd0;
            uart_scr <= 8'd0;
            uart_dll <= 8'd0;
            uart_dlm <= 8'd0;
            rx_data_r <= 8'd0;
            rx_have <= 1'b0;
            plic_prio1 <= 3'd0;
            plic_senable1 <= 1'b0;
            plic_sthresh <= 3'd0;
            plic_claimed <= 1'b0;
        end else begin
            if (MTIME_TICK_CYCLES <= 32'd1) begin
                mtime <= mtime + 64'd1;
                mtime_tick_count <= 32'd0;
            end else if (mtime_tick_count == (MTIME_TICK_CYCLES - 32'd1)) begin
                mtime <= mtime + 64'd1;
                mtime_tick_count <= 32'd0;
            end else begin
                mtime_tick_count <= mtime_tick_count + 32'd1;
            end
            if (rx_ready) begin
                rx_have <= 1'b1;
                rx_data_r <= rx_byte_in;
            end

            case (state)
            S_IDLE: begin
                if (start) begin
                    fault <= 1'b0;
                    cause <= 4'd0;
                    fault_pa <= pa;
                    load_data <= 32'd0;

                    if (misaligned) begin
                        fault <= 1'b1;
                        cause <= is_store ? CAUSE_STORE_MAL : CAUSE_LOAD_MAL;
                    end else if (is_store) begin
                        if (is_clint) begin
                            case (pa[15:0])
                            16'h0000: msip <= storeword[0];
                            16'h4000: mtimecmp[31:0] <= storeword;
                            16'h4004: mtimecmp[63:32] <= storeword;
                            16'hBFF8: mtime[31:0] <= storeword;
                            16'hBFFC: mtime[63:32] <= storeword;
                            default: ;
                            endcase
                        end

                        if (is_uart) begin
                            case (pa[2:0])
                            3'd0: begin
                                if (uart_lcr[7])
                                    uart_dll <= store_data[7:0];
                                else begin
                                    uart_we <= 1'b1;
                                    uart_data <= store_data[7:0];
                                end
                            end
                            3'd1: begin
                                if (uart_lcr[7])
                                    uart_dlm <= store_data[7:0];
                                else
                                    uart_ier <= store_data[7:0];
                            end
                            3'd2: uart_fcr <= store_data[7:0];
                            3'd3: uart_lcr <= store_data[7:0];
                            3'd4: uart_mcr <= store_data[7:0];
                            3'd7: uart_scr <= store_data[7:0];
                            default: ;
                            endcase
                        end

                        if (is_plic) begin
                            case (pa[23:0])
                            24'h000004: plic_prio1 <= storeword[2:0];
                            24'h002080: plic_senable1 <= storeword[1];
                            24'h201000: plic_sthresh <= storeword[2:0];
                            24'h201004: plic_claimed <= 1'b0;
                            default: ;
                            endcase
                        end

                        if (is_sys) begin
                            if (storeword == 32'h0000_5555) begin
                                halt <= 1'b1;
                                exit_code <= 32'd0;
                            end else if (storeword == 32'h0000_7777) begin
                                halt <= 1'b1;
                                exit_code <= 32'd1;
                            end
                        end
                    end else begin
                        load_data <= format_load(memword, funct3, pa[1:0]);
                        if (is_uart && (pa[2:0] == 3'd0) && !uart_lcr[7] && rx_have)
                            rx_have <= 1'b0;
                        if (is_plic && (pa[23:0] == 24'h201004) && plic_s_pending)
                            plic_claimed <= 1'b1;
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

    function [31:0] store_merge;
        input [31:0] old_word;
        input [2:0]  f3;
        input [1:0]  off;
        input [31:0] data;
        begin
            store_merge = old_word;
            case (f3)
            3'b000: begin
                case (off)
                2'd0: store_merge[7:0] = data[7:0];
                2'd1: store_merge[15:8] = data[7:0];
                2'd2: store_merge[23:16] = data[7:0];
                default: store_merge[31:24] = data[7:0];
                endcase
            end
            3'b001: begin
                if (off[1])
                    store_merge[31:16] = data[15:0];
                else
                    store_merge[15:0] = data[15:0];
            end
            default: store_merge = data;
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
