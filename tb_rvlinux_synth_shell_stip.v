`timescale 1ns/1ps

module tb_rvlinux_synth_shell_stip;
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

    reg [31:0] cap_x3 = 32'd0;
    reg [31:0] cap_x10 = 32'd0;
    integer cycle;

    rvlinux #(
        .MEMFILE(""),
        .MEMWORDS(1024),
        .MEMFILE_WORDS(0),
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

    function [31:0] rv_i;
        input [11:0] imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            rv_i = {imm, rs1, funct3, rd, opcode};
        end
    endfunction

    function [31:0] rv_lui;
        input [4:0] rd;
        input [19:0] imm20;
        begin
            rv_lui = {imm20, rd, 7'b0110111};
        end
    endfunction

    function [31:0] rv_addi;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            rv_addi = rv_i(imm, rs1, 3'b000, rd, 7'b0010011);
        end
    endfunction

    function [31:0] rv_csrw;
        input [11:0] csr;
        input [4:0] rs1;
        begin
            rv_csrw = rv_i(csr, rs1, 3'b001, 5'd0, 7'b1110011);
        end
    endfunction

    function [31:0] rv_csrs;
        input [11:0] csr;
        input [4:0] rs1;
        begin
            rv_csrs = rv_i(csr, rs1, 3'b010, 5'd0, 7'b1110011);
        end
    endfunction

    function [31:0] rv_csrr;
        input [4:0] rd;
        input [11:0] csr;
        begin
            rv_csrr = rv_i(csr, 5'd0, 3'b010, rd, 7'b1110011);
        end
    endfunction

    task write_word;
        input integer index;
        input [31:0] value;
        begin
            dut.synth_shell.cluster.mem.memsys.backing.mem[index] = value;
        end
    endtask

    task capture_reg;
        input [4:0] regnum;
        output [31:0] value;
        begin
            dbg_rsel = regnum;
            #1 value = dbg_rval;
        end
    endtask

    initial begin
        #1;

        // M-mode setup: set mip.STIP, delegate STIE, and enter S-mode.
        write_word(0,  rv_addi(5'd1, 5'd0, 12'h080)); // addi x1,x0,0x80
        write_word(1,  rv_csrw(12'h105, 5'd1));       // csrw stvec,x1
        write_word(2,  rv_addi(5'd1, 5'd0, 12'h020)); // addi x1,x0,STIE
        write_word(3,  rv_csrw(12'h303, 5'd1));       // csrw mideleg,x1
        write_word(4,  rv_csrw(12'h304, 5'd1));       // csrw mie,x1
        write_word(5,  rv_csrw(12'h344, 5'd1));       // csrw mip,x1, set STIP
        write_word(6,  rv_addi(5'd1, 5'd0, 12'h040)); // addi x1,x0,0x40
        write_word(7,  rv_csrw(12'h341, 5'd1));       // csrw mepc,x1
        write_word(8,  rv_lui(5'd1, 20'h00001));      // lui  x1,0x1
        write_word(9,  rv_addi(5'd1, 5'd1, 12'h800)); // addi x1,x1,-2048 -> MPP=S
        write_word(10, rv_csrw(12'h300, 5'd1));       // csrw mstatus,x1
        write_word(11, 32'h3020_0073);                // mret

        write_word(12, 32'h0000_0013);
        write_word(13, 32'h0000_0013);
        write_word(14, 32'h0000_0013);
        write_word(15, 32'h0000_0013);

        // S-mode at 0x40: enable SIE, then the pending STIP must trap.
        write_word(16, rv_addi(5'd4, 5'd0, 12'h002)); // addi x4,x0,SIE
        write_word(17, rv_csrs(12'h100, 5'd4));       // csrs sstatus,x4
        write_word(18, rv_addi(5'd8, 5'd0, 12'h011)); // addi x8,x0,0x11

        // S-mode handler at 0x80: x10=scause, x3=sepc, then halt.
        write_word(32, rv_csrr(5'd10, 12'h142));      // csrr x10,scause
        write_word(33, rv_csrr(5'd3, 12'h141));       // csrr x3,sepc
        write_word(34, 32'h0010_0073);                // ebreak

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 5000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        capture_reg(5'd3, cap_x3);
        capture_reg(5'd10, cap_x10);

        if (!halt) begin
            $display("RVLINUX_SYNTH_SHELL_STIP_RESULT: FAIL timeout pc=%08h priv=%0d mtime=%0d mip=%08h mie=%08h",
                     dbg_pc, dbg_priv, dbg_mtime, dbg_mip, dbg_mie);
            $finish;
        end
        if (dut.synth_shell.fault) begin
            $display("RVLINUX_SYNTH_SHELL_STIP_RESULT: FAIL fatal fault cause=%0d tval=%08h pc=%08h",
                     dut.synth_shell.fault_cause, dut.synth_shell.fault_tval,
                     dbg_pc);
            $finish;
        end
        if (exit_code != 32'd0 ||
            dbg_priv != 2'd1 || dbg_pc != 32'h0000_0088 ||
            cap_x3 != 32'h0000_0048 ||
            cap_x10 != 32'h8000_0005 ||
            dbg_scause != 32'h8000_0005 ||
            dbg_mcause != 32'd0 ||
            dbg_mip != 32'h0000_0020 ||
            dbg_mie != 32'h0000_0020 ||
            dbg_stval != 32'd0 ||
            dbg_mtime == 32'd0 ||
            dbg_mtimecmp != 32'hffff_ffff) begin
            $display("RVLINUX_SYNTH_SHELL_STIP_RESULT: FAIL pc=%08h priv=%0d x3=%08h x10=%08h scause=%08h mcause=%08h mip=%08h mie=%08h exit=%0d mtime=%0d mtimecmp=%08h retired=%0d",
                     dbg_pc, dbg_priv, cap_x3, cap_x10, dbg_scause,
                     dbg_mcause, dbg_mip, dbg_mie, exit_code, dbg_mtime,
                     dbg_mtimecmp, dut.synth_shell.retired);
            $finish;
        end

        $display("RVLINUX_SYNTH_SHELL_STIP_RESULT: PASS pc=%08h priv=%0d scause=%08h sepc=%08h mip=%08h retired=%0d",
                 dbg_pc, dbg_priv, dbg_scause, cap_x3, dbg_mip,
                 dut.synth_shell.retired);
        $finish;
    end
endmodule
