`timescale 1ns/1ps

module tb_rvlinux_synth_shell_memfile;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg rx_valid = 1'b0;
    reg [7:0] rx_byte_in = 8'd0;
    reg [4:0] dbg_rsel = 5'd0;
    reg [31:0] dbg_maddr = 32'd0;

    wire uart_we;
    wire [7:0] uart_data;
    wire rx_ready;
    wire halt;
    wire [31:0] exit_code;
    wire [31:0] dbg_pc;
    wire [1:0] dbg_priv;
    wire [31:0] dbg_rval;
    wire [31:0] dbg_mval;
    wire [31:0] dbg_scause;
    wire [31:0] dbg_mcause;
    wire [31:0] dbg_mip;
    wire [31:0] dbg_mie;
    wire [31:0] dbg_stval;
    wire [31:0] dbg_mtime;
    wire [31:0] dbg_mtimecmp;

    reg uart_seen = 1'b0;
    reg [7:0] uart_byte = 8'd0;
    reg [31:0] cap_x6 = 32'd0;
    reg [31:0] cap_x10 = 32'd0;
    integer cycle;

    rvlinux #(
        .MEMFILE("tb_rvlinux_synth_shell_memfile.hex"),
        .MEMWORDS(4096),
        .MEMFILE_WORDS(10),
        .RAMBASE(32'h8000_0000)
    ) dut (
        .clk(clk), .rst(rst),
        .uart_we(uart_we), .uart_data(uart_data),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in), .rx_ready(rx_ready),
        .halt(halt), .exit_code(exit_code),
        .dbg_pc(dbg_pc), .dbg_priv(dbg_priv),
        .dbg_rsel(dbg_rsel), .dbg_rval(dbg_rval),
        .dbg_maddr(dbg_maddr), .dbg_mval(dbg_mval),
        .dbg_scause(dbg_scause), .dbg_mcause(dbg_mcause),
        .dbg_mip(dbg_mip), .dbg_mie(dbg_mie),
        .dbg_stval(dbg_stval), .dbg_mtime(dbg_mtime),
        .dbg_mtimecmp(dbg_mtimecmp)
    );

    always #5 clk = ~clk;

    always @(negedge clk) begin
        if (uart_we) begin
            uart_seen <= 1'b1;
            uart_byte <= uart_data;
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 4000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("RVLINUX_SYNTH_SHELL_MEMFILE_RESULT: FAIL timeout pc=%08h priv=%0d mtime=%0d",
                     dbg_pc, dbg_priv, dbg_mtime);
            $finish;
        end
        if (!uart_seen || uart_byte != 8'h44 || exit_code != 32'd0) begin
            $display("RVLINUX_SYNTH_SHELL_MEMFILE_RESULT: FAIL uart_seen=%0d uart=%02h exit=%0d",
                     uart_seen, uart_byte, exit_code);
            $finish;
        end

        dbg_rsel = 5'd6;
        #1 cap_x6 = dbg_rval;
        dbg_rsel = 5'd10;
        #1 cap_x10 = dbg_rval;
        if (dbg_pc != 32'h8000_0024 || dbg_priv != 2'd3 ||
            dbg_mtime == 32'd0 || dbg_mtimecmp != 32'hffff_ffff ||
            cap_x6 != 32'h0000_0060 || cap_x10 != 32'h0000_0060) begin
            $display("RVLINUX_SYNTH_SHELL_MEMFILE_RESULT: FAIL pc=%08h priv=%0d mtime=%0d mtimecmp=%08h x6=%08h x10=%08h",
                     dbg_pc, dbg_priv, dbg_mtime, dbg_mtimecmp, cap_x6, cap_x10);
            $finish;
        end

        $display("RVLINUX_SYNTH_SHELL_MEMFILE_RESULT: PASS pc=%08h uart=%02h mtime=%0d",
                 dbg_pc, uart_byte, dbg_mtime);
        $finish;
    end
endmodule
