`timescale 1ns/1ps

module tb_rvlinux_synth_shell;
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

    localparam [31:0] ROOT_PTE   = 32'h0000_0801;
    localparam [31:0] CODE_PTE   = 32'h0000_000f;
    localparam [31:0] UART_PTE   = 32'h0400_0007;
    localparam [31:0] SYSCON_PTE = 32'h0444_0007;

    rvlinux #(
        .MEMWORDS(4096),
        .RAMBASE(32'h0000_0000)
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

    task write_word;
        input integer index;
        input [31:0] value;
        begin
            dut.synth_shell.cluster.mem.memsys.backing.mem[index] = value;
        end
    endtask

    initial begin
        #1;

        write_word(0,  32'h0400_0093); // addi x1,x0,0x40
        write_word(1,  32'h3410_9073); // csrw mepc,x1
        write_word(2,  32'h0000_10b7); // lui  x1,0x1
        write_word(3,  32'h8800_8093); // addi x1,x1,-1920 -> MPP=S, MPIE=1
        write_word(4,  32'h3000_9073); // csrw mstatus,x1
        write_word(5,  32'h8000_00b7); // lui  x1,0x80000
        write_word(6,  32'h0010_8093); // addi x1,x1,1 -> satp MODE=Sv32, root PPN=1
        write_word(7,  32'h1800_9073); // csrw satp,x1
        write_word(8,  32'h3020_0073); // mret

        write_word(16, 32'h0000_1237); // lui  x4,0x1
        write_word(17, 32'h0430_0293); // addi x5,x0,0x43
        write_word(18, 32'h0052_0023); // sb   x5,0(x4)
        write_word(19, 32'h0052_4303); // lbu  x6,5(x4)
        write_word(20, 32'h0003_0513); // addi x10,x6,0
        write_word(21, 32'h0000_23b7); // lui  x7,0x2
        write_word(22, 32'h0000_5437); // lui  x8,0x5
        write_word(23, 32'h5554_0413); // addi x8,x8,0x555 -> 0x5555
        write_word(24, 32'h0083_a023); // sw   x8,0(x7)
        write_word(25, 32'h0010_0073); // ebreak, must not be reached

        write_word(32'h0000_1000 >> 2, ROOT_PTE);
        write_word(32'h0000_2000 >> 2, CODE_PTE);
        write_word(32'h0000_2004 >> 2, UART_PTE);
        write_word(32'h0000_2008 >> 2, SYSCON_PTE);

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 9000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("RVLINUX_SYNTH_SHELL_RESULT: FAIL timeout pc=%08h priv=%0d mtime=%0d",
                     dbg_pc, dbg_priv, dbg_mtime);
            $finish;
        end
        if (!uart_seen || uart_byte != 8'h43 || exit_code != 32'd0) begin
            $display("RVLINUX_SYNTH_SHELL_RESULT: FAIL uart_seen=%0d uart=%02h exit=%0d",
                     uart_seen, uart_byte, exit_code);
            $finish;
        end
        dbg_rsel = 5'd6;
        #1 cap_x6 = dbg_rval;
        dbg_rsel = 5'd10;
        #1 cap_x10 = dbg_rval;
        if (dbg_priv != 2'd1 || dbg_pc != 32'h0000_0064 ||
            cap_x6 != 32'h0000_0060 ||
            cap_x10 != 32'h0000_0060) begin
            $display("RVLINUX_SYNTH_SHELL_RESULT: FAIL pc=%08h priv=%0d x6=%08h x10=%08h",
                     dbg_pc, dbg_priv, cap_x6, cap_x10);
            $finish;
        end

        $display("RVLINUX_SYNTH_SHELL_RESULT: PASS pc=%08h priv=%0d uart=%02h mtime=%0d",
                 dbg_pc, dbg_priv, uart_byte, dbg_mtime);
        $finish;
    end
endmodule
