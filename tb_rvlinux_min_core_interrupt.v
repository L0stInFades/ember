`timescale 1ns/1ps

module tb_rvlinux_min_core_interrupt;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg rx_valid = 1'b0;
    reg [7:0] rx_byte_in = 8'd0;

    wire rx_ready;
    wire uart_we;
    wire [7:0] uart_data;
    wire halt;
    wire [31:0] exit_code;
    wire fault;
    wire [3:0] fault_cause;
    wire [31:0] fault_tval;
    wire [31:0] pc;
    wire [31:0] retired;
    wire [31:0] dbg_x3;
    wire [31:0] dbg_x5;
    wire [31:0] dbg_x6;
    wire [31:0] dbg_x10;
    wire [1:0] dbg_priv;
    wire [31:0] dbg_mcause;
    wire [31:0] dbg_scause;
    wire [31:0] dbg_mip;
    wire [31:0] dbg_mie;
    wire [31:0] dbg_stval;
    wire [31:0] dbg_mtime;
    wire [31:0] dbg_mtimecmp;
    wire cluster_busy;
    wire [2:0] cluster_active_owner;
    wire [31:0] i_hits;
    wire [31:0] i_misses;
    wire [31:0] d_hits;
    wire [31:0] d_misses;
    wire [31:0] ad_writes;
    wire backing_req;
    wire backing_we;
    wire [31:0] backing_addr;
    wire backing_ack;

    reg rx_sent = 1'b0;
    reg rx_accepted = 1'b0;
    integer cycle;

    rvlinux_min_core_fsm #(
        .RESET_PC(32'h0000_0000),
        .I_LINES(16),
        .D_LINES(16),
        .WORDS(4),
        .MEMWORDS(4096),
        .LAT(4),
        .RAMBASE(32'h0000_0000)
    ) dut (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in),
        .rx_ready(rx_ready), .uart_we(uart_we), .uart_data(uart_data),
        .halt(halt), .exit_code(exit_code),
        .fault(fault), .fault_cause(fault_cause),
        .fault_tval(fault_tval), .pc(pc), .retired(retired),
        .dbg_x3(dbg_x3), .dbg_x5(dbg_x5), .dbg_x6(dbg_x6),
        .dbg_x10(dbg_x10), .dbg_priv(dbg_priv),
        .dbg_mcause(dbg_mcause), .dbg_scause(dbg_scause),
        .dbg_mip(dbg_mip), .dbg_mie(dbg_mie),
        .dbg_stval(dbg_stval), .dbg_mtime(dbg_mtime),
        .dbg_mtimecmp(dbg_mtimecmp),
        .cluster_busy(cluster_busy),
        .cluster_active_owner(cluster_active_owner),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    always #5 clk = ~clk;

    always @(negedge clk) begin
        if (rst)
            rx_accepted <= 1'b0;
        else if (rx_valid && rx_ready)
            rx_accepted <= 1'b1;
    end

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

    function [31:0] rv_s;
        input [11:0] imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        begin
            rv_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'b0100011};
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

    function [31:0] rv_lw;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            rv_lw = rv_i(imm, rs1, 3'b010, rd, 7'b0000011);
        end
    endfunction

    function [31:0] rv_lbu;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            rv_lbu = rv_i(imm, rs1, 3'b100, rd, 7'b0000011);
        end
    endfunction

    function [31:0] rv_sb;
        input [4:0] rs2;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            rv_sb = rv_s(imm, rs2, rs1, 3'b000);
        end
    endfunction

    function [31:0] rv_sw;
        input [4:0] rs2;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            rv_sw = rv_s(imm, rs2, rs1, 3'b010);
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
            dut.cluster.mem.memsys.backing.mem[index] = value;
        end
    endtask

    initial begin
        #1;

        // M-mode setup: delegate supervisor external interrupts and enter S-mode.
        write_word(0,  rv_addi(5'd1, 5'd0, 12'h080)); // addi x1,x0,0x80
        write_word(1,  rv_csrw(12'h105, 5'd1));       // csrw stvec,x1
        write_word(2,  rv_addi(5'd1, 5'd0, 12'h200)); // addi x1,x0,SEIE
        write_word(3,  rv_csrw(12'h303, 5'd1));       // csrw mideleg,x1
        write_word(4,  rv_csrw(12'h304, 5'd1));       // csrw mie,x1
        write_word(5,  rv_addi(5'd1, 5'd0, 12'h040)); // addi x1,x0,0x40
        write_word(6,  rv_csrw(12'h341, 5'd1));       // csrw mepc,x1
        write_word(7,  rv_lui(5'd1, 20'h00001));      // lui  x1,0x1
        write_word(8,  rv_addi(5'd1, 5'd1, 12'h800)); // addi x1,x1,-2048 -> MPP=S
        write_word(9,  rv_csrw(12'h300, 5'd1));       // csrw mstatus,x1
        write_word(10, 32'h3020_0073);                // mret

        write_word(11, 32'h0000_0013);
        write_word(12, 32'h0000_0013);
        write_word(13, 32'h0000_0013);
        write_word(14, 32'h0000_0013);
        write_word(15, 32'h0000_0013);

        // S-mode at 0x40: configure UART source 1 in the PLIC, then enable SIE.
        write_word(16, rv_addi(5'd2, 5'd0, 12'h001)); // addi x2,x0,1
        write_word(17, rv_addi(5'd3, 5'd0, 12'h002)); // addi x3,x0,2
        write_word(18, rv_lui(5'd1, 20'h0c000));      // lui  x1,0x0c000
        write_word(19, rv_addi(5'd1, 5'd1, 12'h004)); // addi x1,x1,4
        write_word(20, rv_sw(5'd2, 5'd1, 12'h000));   // sw   x2,0(x1)
        write_word(21, rv_lui(5'd1, 20'h0c002));      // lui  x1,0x0c002
        write_word(22, rv_addi(5'd1, 5'd1, 12'h080)); // addi x1,x1,0x80
        write_word(23, rv_sw(5'd3, 5'd1, 12'h000));   // sw   x3,0(x1)
        write_word(24, rv_lui(5'd1, 20'h0c201));      // lui  x1,0x0c201
        write_word(25, rv_sw(5'd0, 5'd1, 12'h000));   // sw   x0,0(x1)
        write_word(26, rv_lui(5'd1, 20'h10000));      // lui  x1,0x10000
        write_word(27, rv_addi(5'd1, 5'd1, 12'h001)); // addi x1,x1,1
        write_word(28, rv_sb(5'd2, 5'd1, 12'h000));   // sb   x2,0(x1)
        write_word(29, rv_addi(5'd4, 5'd0, 12'h002)); // addi x4,x0,SIE
        write_word(30, rv_csrs(12'h100, 5'd4));       // csrs sstatus,x4
        write_word(31, rv_addi(5'd8, 5'd0, 12'h011)); // addi x8,x0,0x11

        // S-mode handler at 0x80: claim UART IRQ, consume RX byte, complete, halt.
        write_word(32, rv_csrr(5'd10, 12'h142));      // csrr x10,scause
        write_word(33, rv_lui(5'd1, 20'h0c201));      // lui  x1,0x0c201
        write_word(34, rv_addi(5'd1, 5'd1, 12'h004)); // addi x1,x1,4
        write_word(35, rv_lw(5'd11, 5'd1, 12'h000));  // lw   x11,0(x1)
        write_word(36, rv_lui(5'd1, 20'h10000));      // lui  x1,0x10000
        write_word(37, rv_lbu(5'd12, 5'd1, 12'h000)); // lbu  x12,0(x1)
        write_word(38, rv_lui(5'd1, 20'h0c201));      // lui  x1,0x0c201
        write_word(39, rv_addi(5'd1, 5'd1, 12'h004)); // addi x1,x1,4
        write_word(40, rv_sw(5'd11, 5'd1, 12'h000));  // sw   x11,0(x1)
        write_word(41, 32'h0010_0073);                // ebreak

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 8000 && !halt; cycle = cycle + 1) begin
            if (!rx_sent && dbg_priv == 2'd1 && pc == 32'h0000_007c) begin
                rx_byte_in = 8'h5a;
                rx_valid = 1'b1;
                rx_sent = 1'b1;
            end else begin
                rx_valid = 1'b0;
            end
            @(posedge clk);
        end
        rx_valid = 1'b0;

        if (!halt) begin
            $display("MIN_CORE_INTERRUPT_RESULT: FAIL timeout pc=%08h priv=%0d retired=%0d owner=%0d sent=%0d accepted=%0d mip=%08h mie=%08h",
                     pc, dbg_priv, retired, cluster_active_owner, rx_sent,
                     rx_accepted, dbg_mip, dbg_mie);
            $finish;
        end
        if (fault) begin
            $display("MIN_CORE_INTERRUPT_RESULT: FAIL fatal fault cause=%0d tval=%08h pc=%08h",
                     fault_cause, fault_tval, pc);
            $finish;
        end
        if (!rx_sent || !rx_accepted || exit_code != 32'd0 ||
            dbg_priv != 2'd1 || pc != 32'h0000_00a4 ||
            dbg_x10 != 32'h8000_0009 ||
            dut.regs[8] != 32'd0 ||
            dut.regs[11] != 32'd1 ||
            dut.regs[12] != 32'h0000_005a ||
            dbg_scause != 32'h8000_0009 ||
            dbg_mcause != 32'd0 ||
            dut.csr.sepc_out != 32'h0000_007c ||
            dbg_mip != 32'd0 ||
            dbg_mie != 32'h0000_0200 ||
            dbg_stval != 32'd0 ||
            dbg_mtime == 32'd0 ||
            dbg_mtimecmp != 32'hffff_ffff) begin
            $display("MIN_CORE_INTERRUPT_RESULT: FAIL pc=%08h priv=%0d x8=%08h x10=%08h x11=%08h x12=%08h scause=%08h sepc=%08h mcause=%08h mip=%08h mie=%08h sent=%0d accepted=%0d exit=%0d mtime=%0d mtimecmp=%08h",
                     pc, dbg_priv, dut.regs[8], dbg_x10, dut.regs[11],
                     dut.regs[12], dbg_scause, dut.csr.sepc_out, dbg_mcause,
                     dbg_mip, dbg_mie, rx_sent, rx_accepted, exit_code,
                     dbg_mtime, dbg_mtimecmp);
            $finish;
        end

        $display("MIN_CORE_INTERRUPT_RESULT: PASS pc=%08h priv=%0d scause=%08h sepc=%08h claim=%0d rx=%02h retired=%0d",
                 pc, dbg_priv, dbg_scause, dut.csr.sepc_out, dut.regs[11],
                 dut.regs[12][7:0], retired);
        $finish;
    end
endmodule
