`timescale 1ns/1ps

module tb_rvlinux_min_core_time_csr;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg rx_valid = 1'b0;
    reg [7:0] rx_byte_in = 8'd0;
    reg [4:0] dbg_rsel = 5'd0;

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
    wire [31:0] dbg_rval;
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
    wire dbg_mmio_valid;
    wire dbg_mmio_we;
    wire [2:0] dbg_mmio_funct3;
    wire [31:0] dbg_mmio_pa;
    wire [31:0] dbg_mmio_wdata;
    wire [31:0] dbg_mmio_rdata;
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

    localparam [31:0] TIME_BASE = 32'h0010_0000;

    integer cycle;
    reg [31:0] csr_time;
    reg [31:0] clint_time;
    reg [31:0] delta;

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
        .dbg_x10(dbg_x10), .dbg_rsel(dbg_rsel), .dbg_rval(dbg_rval),
        .dbg_priv(dbg_priv), .dbg_mcause(dbg_mcause),
        .dbg_scause(dbg_scause), .dbg_mip(dbg_mip), .dbg_mie(dbg_mie),
        .dbg_stval(dbg_stval), .dbg_satp(dbg_satp),
        .dbg_mepc(dbg_mepc), .dbg_sepc(dbg_sepc),
        .dbg_mtime(dbg_mtime), .dbg_mtimecmp(dbg_mtimecmp),
        .dbg_mmio_valid(dbg_mmio_valid), .dbg_mmio_we(dbg_mmio_we),
        .dbg_mmio_funct3(dbg_mmio_funct3), .dbg_mmio_pa(dbg_mmio_pa),
        .dbg_mmio_wdata(dbg_mmio_wdata), .dbg_mmio_rdata(dbg_mmio_rdata),
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

    function [31:0] rv_lw;
        input [4:0] rd;
        input [4:0] rs1;
        input [11:0] imm;
        begin
            rv_lw = rv_i(imm, rs1, 3'b010, rd, 7'b0000011);
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

        write_word(0, rv_lui(5'd1, 20'h0200c));
        write_word(1, rv_addi(5'd1, 5'd1, 12'hff8)); // CLINT mtime low
        write_word(2, rv_lui(5'd2, 20'h00100));      // TIME_BASE
        write_word(3, rv_sw(5'd2, 5'd1, 12'h000));   // mtime low = TIME_BASE
        write_word(4, rv_csrr(5'd10, 12'hc01));      // CSR time low
        write_word(5, rv_lw(5'd11, 5'd1, 12'h000));  // CLINT mtime low
        write_word(6, 32'h0010_0073);                // ebreak

        repeat (5) @(posedge clk);
        rst = 1'b0;

        for (cycle = 0; cycle < 2000 && !halt; cycle = cycle + 1)
            @(posedge clk);

        dbg_rsel = 5'd11;
        #1;
        csr_time = dbg_x10;
        clint_time = dbg_rval;
        delta = clint_time - csr_time;

        if (!halt) begin
            $display("MIN_CORE_TIME_CSR_RESULT: FAIL timeout pc=%08h retired=%0d owner=%0d mtime=%0d",
                     pc, retired, cluster_active_owner, dbg_mtime);
            $finish;
        end
        if (fault) begin
            $display("MIN_CORE_TIME_CSR_RESULT: FAIL fatal fault cause=%0d tval=%08h pc=%08h",
                     fault_cause, fault_tval, pc);
            $finish;
        end
        if (exit_code != 32'd0 || csr_time < TIME_BASE ||
            clint_time < TIME_BASE || clint_time < csr_time ||
            delta > 32'd2000) begin
            $display("MIN_CORE_TIME_CSR_RESULT: FAIL pc=%08h x10_time=%08h x11_clint=%08h delta=%0d dbg_mtime=%08h retired=%0d",
                     pc, csr_time, clint_time, delta, dbg_mtime, retired);
            $finish;
        end

        $display("MIN_CORE_TIME_CSR_RESULT: PASS x10_time=%08h x11_clint=%08h delta=%0d retired=%0d",
                 csr_time, clint_time, delta, retired);
        $finish;
    end
endmodule
