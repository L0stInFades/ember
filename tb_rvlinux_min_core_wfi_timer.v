`timescale 1ns/1ps

module tb_rvlinux_min_core_wfi_timer;
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
    wire [31:0] dbg_satp;
    wire [31:0] dbg_mepc;
    wire [31:0] dbg_sepc;
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

    localparam [31:0] WFI_PC = 32'h0000_0038;
    localparam [31:0] WFI_NEXT_PC = 32'h0000_003c;

    integer cycle;
    integer stalled_cycles;
    reg seen_wfi;
    reg [31:0] wfi_retired;

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
        .dbg_stval(dbg_stval), .dbg_satp(dbg_satp),
        .dbg_mepc(dbg_mepc), .dbg_sepc(dbg_sepc),
        .dbg_mtime(dbg_mtime), .dbg_mtimecmp(dbg_mtimecmp),
        .cluster_busy(cluster_busy),
        .cluster_active_owner(cluster_active_owner),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
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

        write_word(0,  rv_addi(5'd1, 5'd0, 12'h080)); // mtvec = 0x80
        write_word(1,  rv_csrw(12'h305, 5'd1));
        write_word(2,  rv_addi(5'd1, 5'd0, 12'h080)); // mie.MTIE
        write_word(3,  rv_csrw(12'h304, 5'd1));
        write_word(4,  rv_addi(5'd1, 5'd0, 12'h008)); // mstatus.MIE
        write_word(5,  rv_csrs(12'h300, 5'd1));
        write_word(6,  rv_lui(5'd2, 20'h02004));      // CLINT mtimecmp
        write_word(7,  rv_addi(5'd3, 5'd0, 12'h000));
        write_word(8,  rv_sw(5'd3, 5'd2, 12'h004));   // mtimecmp high = 0
        write_word(9,  rv_addi(5'd3, 5'd0, 12'h3e8)); // mtimecmp low = 1000
        write_word(10, rv_sw(5'd3, 5'd2, 12'h000));
        write_word(11, rv_lui(5'd2, 20'h0200c));
        write_word(12, rv_addi(5'd2, 5'd2, 12'hff8)); // CLINT mtime low
        write_word(13, rv_sw(5'd0, 5'd2, 12'h000));   // mtime low = 0
        write_word(14, 32'h1050_0073);                // wfi
        write_word(15, rv_addi(5'd8, 5'd0, 12'h066)); // must not execute
        write_word(16, 32'h0010_0073);                // fall-through ebreak

        write_word(32, rv_csrr(5'd10, 12'h342));      // mcause
        write_word(33, rv_csrr(5'd3, 12'h341));       // mepc
        write_word(34, 32'h0010_0073);                // handler ebreak

        repeat (5) @(posedge clk);
        rst = 1'b0;

        seen_wfi = 1'b0;
        stalled_cycles = 0;
        wfi_retired = 32'd0;
        for (cycle = 0; cycle < 10000 && !halt; cycle = cycle + 1) begin
            @(posedge clk);
            if (!seen_wfi && pc == WFI_PC) begin
                seen_wfi = 1'b1;
                wfi_retired = retired;
            end else if (seen_wfi && pc == WFI_PC && retired == wfi_retired) begin
                stalled_cycles = stalled_cycles + 1;
            end
        end

        if (!halt) begin
            $display("MIN_CORE_WFI_TIMER_RESULT: FAIL timeout pc=%08h retired=%0d owner=%0d mtime=%0d mip=%08h mie=%08h",
                     pc, retired, cluster_active_owner, dbg_mtime, dbg_mip,
                     dbg_mie);
            $finish;
        end
        if (fault) begin
            $display("MIN_CORE_WFI_TIMER_RESULT: FAIL fatal fault cause=%0d tval=%08h pc=%08h",
                     fault_cause, fault_tval, pc);
            $finish;
        end
        if (!seen_wfi || stalled_cycles < 100 ||
            exit_code != 32'd0 || dbg_priv != 2'd3 ||
            pc != 32'h0000_0088 ||
            dbg_x10 != 32'h8000_0007 ||
            dbg_mcause != 32'h8000_0007 ||
            dbg_mepc != WFI_NEXT_PC ||
            dbg_x3 != WFI_NEXT_PC ||
            dut.regs[8] != 32'd0 ||
            dbg_mie != 32'h0000_0080 ||
            dbg_mtimecmp != 32'd1000 ||
            dbg_stval != 32'd0) begin
            $display("MIN_CORE_WFI_TIMER_RESULT: FAIL seen=%0d stalled=%0d pc=%08h priv=%0d x3=%08h x8=%08h x10=%08h mcause=%08h mepc=%08h mip=%08h mie=%08h mtime=%0d mtimecmp=%0d retired=%0d",
                     seen_wfi, stalled_cycles, pc, dbg_priv, dbg_x3,
                     dut.regs[8], dbg_x10, dbg_mcause, dbg_mepc, dbg_mip,
                     dbg_mie, dbg_mtime, dbg_mtimecmp, retired);
            $finish;
        end

        $display("MIN_CORE_WFI_TIMER_RESULT: PASS stalled=%0d pc=%08h mcause=%08h mepc=%08h mtime=%0d retired=%0d",
                 stalled_cycles, pc, dbg_mcause, dbg_mepc, dbg_mtime,
                 retired);
        $finish;
    end
endmodule
