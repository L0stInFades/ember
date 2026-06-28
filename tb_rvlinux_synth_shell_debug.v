`timescale 1ns/1ps

module tb_rvlinux_synth_shell_debug;
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

    reg [31:0] cap_x4 = 32'd0;
    reg [31:0] cap_x10 = 32'd0;
    integer cycle;

    rvlinux #(
        .MEMWORDS(1024),
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

    task write_word;
        input integer index;
        input [31:0] value;
        begin
            dut.synth_shell.cluster.mem.memsys.backing.mem[index] = value;
        end
    endtask

    initial begin
        #1;

        // M-mode setup: delegate U ECALL, set S trap/entry state, then MRET.
        write_word(0,  32'h1000_0093); // addi x1,x0,0x100
        write_word(1,  32'h3050_9073); // csrw mtvec,x1
        write_word(2,  32'h3020_9073); // csrw medeleg,x1 (delegate cause 8)
        write_word(3,  32'h0800_0093); // addi x1,x0,0x80
        write_word(4,  32'h1050_9073); // csrw stvec,x1
        write_word(5,  32'h0400_0093); // addi x1,x0,0x40
        write_word(6,  32'h3410_9073); // csrw mepc,x1
        write_word(7,  32'h0000_10b7); // lui x1,0x1
        write_word(8,  32'h8800_8093); // addi x1,x1,-1920 -> MPP=S, MPIE=1
        write_word(9,  32'h3000_9073); // csrw mstatus,x1
        write_word(10, 32'h3020_0073); // mret

        write_word(11, 32'h0000_0013);
        write_word(12, 32'h0000_0013);
        write_word(13, 32'h0000_0013);
        write_word(14, 32'h0000_0013);
        write_word(15, 32'h0000_0013);

        // S-mode entry at 0x40: set U entry and SRET into U-mode.
        write_word(16, 32'h0600_0093); // addi x1,x0,0x60
        write_word(17, 32'h1410_9073); // csrw sepc,x1
        write_word(18, 32'h0200_0093); // addi x1,x0,0x20
        write_word(19, 32'h1000_9073); // csrw sstatus,x1 (SPIE=1, SPP=0)
        write_word(20, 32'h1020_0073); // sret

        write_word(21, 32'h0000_0013);
        write_word(22, 32'h0000_0013);
        write_word(23, 32'h0000_0013);

        // U-mode at 0x60: execute a delegated ECALL.
        write_word(24, 32'h0070_0213); // addi x4,x0,7
        write_word(25, 32'h0000_0073); // ecall
        write_word(26, 32'h0000_0013);
        write_word(27, 32'h0000_0013);
        write_word(28, 32'h0000_0013);
        write_word(29, 32'h0000_0013);
        write_word(30, 32'h0000_0013);
        write_word(31, 32'h0000_0013);

        // S-mode handler at 0x80: read scause/sepc, set x10, then halt.
        write_word(32, 32'h1420_2173); // csrr x2,scause
        write_word(33, 32'h1410_21f3); // csrr x3,sepc
        write_word(34, 32'h0041_0513); // addi x10,x2,4
        write_word(35, 32'h0010_0073); // ebreak

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 6000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        if (!halt) begin
            $display("RVLINUX_SYNTH_SHELL_DEBUG_RESULT: FAIL timeout pc=%08h priv=%0d mtime=%0d",
                     dbg_pc, dbg_priv, dbg_mtime);
            $finish;
        end

        dbg_rsel = 5'd4;
        #1 cap_x4 = dbg_rval;
        dbg_rsel = 5'd10;
        #1 cap_x10 = dbg_rval;

        if (dbg_priv != 2'd1 || dbg_pc != 32'h0000_008c ||
            cap_x4 != 32'd7 || cap_x10 != 32'd12 ||
            dbg_scause != 32'd8 ||
            dbg_mcause != 32'd0 || dbg_stval != 32'd0 ||
            dbg_mip != 32'd0 || dbg_mie != 32'd0 ||
            dbg_mtime == 32'd0 || dbg_mtimecmp != 32'hffff_ffff) begin
            $display("RVLINUX_SYNTH_SHELL_DEBUG_RESULT: FAIL pc=%08h priv=%0d x4=%08h x10=%08h scause=%08h mcause=%08h stval=%08h mip=%08h mie=%08h mtime=%0d mtimecmp=%08h",
                     dbg_pc, dbg_priv, cap_x4, cap_x10, dbg_scause, dbg_mcause,
                     dbg_stval, dbg_mip, dbg_mie, dbg_mtime, dbg_mtimecmp);
            $finish;
        end

        $display("RVLINUX_SYNTH_SHELL_DEBUG_RESULT: PASS pc=%08h priv=%0d x4=%08h x10=%08h scause=%08h mtime=%0d",
                 dbg_pc, dbg_priv, cap_x4, cap_x10, dbg_scause, dbg_mtime);
        $finish;
    end
endmodule
