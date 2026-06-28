`timescale 1ns/1ps
// Minimal multicycle execution shell around the new rvlinux memory stages.
//
// This is intentionally smaller than rvlinux.v: no Linux boot path yet. It now
// proves the fetch/decode/execute/commit control loop together with the
// privileged CSR/trap stage, shared memory-stage cluster, and a sequential
// qemu-virt MMIO device subset before that loop is migrated into rvlinux.v.
module rvlinux_min_core_fsm #(
    parameter [31:0] RESET_PC = 32'h0000_0000,
    parameter I_LINES  = 16,
    parameter D_LINES  = 16,
    parameter WORDS    = 4,
    parameter MEMWORDS = 1<<14,
    parameter LAT      = 5,
    parameter [31:0] RAMBASE = 32'h0000_0000,
    parameter MEMFILE = "",
    parameter MEMFILE_WORDS = 0,
    parameter EBREAK_HALTS = 1,
    parameter [31:0] MTIME_TICK_CYCLES = 32'd1
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_valid,
    input  wire [7:0]  rx_byte_in,

    output wire        rx_ready,
    output wire        uart_we,
    output wire [7:0]  uart_data,
    output reg         halt,
    output reg  [31:0] exit_code,
    output reg         fault,
    output reg  [3:0]  fault_cause,
    output reg  [31:0] fault_tval,
    output reg  [31:0] pc,
    output reg  [31:0] retired,

    output wire [31:0] dbg_x3,
    output wire [31:0] dbg_x5,
    output wire [31:0] dbg_x6,
    output wire [31:0] dbg_x10,
    input  wire [4:0]  dbg_rsel,
    output wire [31:0] dbg_rval,
    output wire [1:0]  dbg_priv,
    output wire [31:0] dbg_mcause,
    output wire [31:0] dbg_scause,
    output wire [31:0] dbg_mip,
    output wire [31:0] dbg_mie,
    output wire [31:0] dbg_stval,
    output wire [31:0] dbg_satp,
    output wire [31:0] dbg_mepc,
    output wire [31:0] dbg_sepc,
    output wire [31:0] dbg_mtime,
    output wire [31:0] dbg_mtimecmp,
    output reg         dbg_mmio_valid,
    output reg         dbg_mmio_we,
    output reg  [2:0]  dbg_mmio_funct3,
    output reg  [31:0] dbg_mmio_pa,
    output reg  [31:0] dbg_mmio_wdata,
    output reg  [31:0] dbg_mmio_rdata,

    output wire        cluster_busy,
    output wire [2:0]  cluster_active_owner,
    output wire [31:0] i_hits,
    output wire [31:0] i_misses,
    output wire [31:0] d_hits,
    output wire [31:0] d_misses,
    output wire [31:0] ad_writes,
    output wire        backing_req,
    output wire        backing_we,
    output wire [31:0] backing_addr,
    output wire        backing_ack
);
    localparam [3:0] CAUSE_ILLEGAL   = 4'd2;
    localparam [3:0] CAUSE_LOAD_MAL  = 4'd4;
    localparam [3:0] CAUSE_STORE_MAL = 4'd6;

    localparam S_FETCH_START = 4'd0;
    localparam S_FETCH_WAIT  = 4'd1;
    localparam S_DECODE      = 4'd3;
    localparam S_LSU_WAIT    = 4'd4;
    localparam S_LSU_DROP    = 4'd5;
    localparam S_MULDIV_WAIT = 4'd6;
    localparam S_AMO_WAIT    = 4'd7;
    localparam S_AMO_DROP    = 4'd8;
    localparam S_CSR_WAIT    = 4'd9;
    localparam S_MMIO_WAIT   = 4'd10;
    localparam S_XLATE_WAIT  = 4'd11;
    localparam S_HALT        = 4'd12;
    localparam S_EXECUTE     = 4'd13;
    localparam S_WFI_WAIT    = 4'd14;

    reg [3:0] state;

    reg [31:0] regs [0:31];
    integer r;

    assign dbg_x3  = regs[3];
    assign dbg_x5  = regs[5];
    assign dbg_x6  = regs[6];
    assign dbg_x10 = regs[10];
    assign dbg_rval = regs[dbg_rsel];

    reg        fetch_start_r;
    reg [31:0] fetch_pc_r;
    wire       fetch_done;
    wire       fetch_busy;
    wire       fetch_fault;
    wire [3:0] fetch_cause;
    wire [31:0] fetch_fault_va;
    wire [15:0] fetch_lo16;
    wire [31:0] fetch_raw32;
    wire        fetch_is_rvc;
    wire        fetch_used_second;

    reg        lsu_start_r;
    reg        lsu_is_store_r;
    reg [2:0]  lsu_funct3_r;
    reg [31:0] lsu_va_r;
    reg [31:0] lsu_store_data_r;
    wire       lsu_done;
    wire       lsu_busy;
    wire       lsu_fault;
    wire [3:0] lsu_cause;
    wire [31:0] lsu_fault_va;
    wire [31:0] lsu_pa;
    wire [31:0] lsu_load_data;

    reg        xlate_start_r;
    reg        xlate_is_store_r;
    reg [31:0] xlate_va_r;
    wire       xlate_done;
    wire       xlate_busy;
    wire       xlate_fault;
    wire [3:0] xlate_cause;
    wire [31:0] xlate_fault_va;
    wire [31:0] xlate_pa;

    reg        mmio_start_r;
    reg        mmio_is_store_r;
    reg [2:0]  mmio_funct3_r;
    reg [31:0] mmio_pa_r;
    reg [31:0] mmio_store_data_r;
    wire       mmio_done;
    wire       mmio_busy;
    wire       mmio_fault;
    wire [3:0] mmio_cause;
    wire [31:0] mmio_fault_pa;
    wire [31:0] mmio_load_data;
    wire        mmio_halt;
    wire [31:0] mmio_exit_code;
    wire [31:0] mmio_irq_pending;
    wire [31:0] mmio_mtime;
    wire [31:0] mmio_mtimecmp;
    wire [63:0] mmio_mtime_full;
    wire [63:0] mmio_mtimecmp_full;

    reg        muldiv_start_r;
    reg [2:0]  muldiv_funct3_r;
    reg [31:0] muldiv_rs1_value_r;
    reg [31:0] muldiv_rs2_value_r;
    wire       muldiv_done;
    wire       muldiv_busy;
    wire [31:0] muldiv_result;

    reg        amo_start_r;
    reg [4:0]  amo_funct5_r;
    reg [31:0] amo_va_r;
    reg [31:0] amo_rs2_value_r;
    reg        amo_clear_reservation_r;
    wire       amo_done;
    wire       amo_busy;
    wire       amo_fault;
    wire [3:0] amo_cause;
    wire [31:0] amo_fault_va;
    wire [31:0] amo_pa;
    wire [31:0] amo_rd_value;
    wire        amo_reservation_valid;
    wire [31:0] amo_reservation_addr;

    reg        csr_step_valid_r;
    reg        csr_fast_retire_r;
    reg [31:0] csr_pc_r;
    reg [31:0] csr_instr_r;
    reg [31:0] csr_normal_next_pc_r;
    reg        csr_system_valid_r;
    reg        csr_is_csr_r;
    reg        csr_is_ecall_r;
    reg        csr_is_ebreak_r;
    reg        csr_is_mret_r;
    reg        csr_is_sret_r;
    reg        csr_is_wfi_r;
    reg        csr_is_sfence_r;
    reg [2:0]  csr_f3_r;
    reg [4:0]  csr_rs1_r;
    reg [4:0]  csr_zimm_r;
    reg [11:0] csr_addr_r;
    reg [31:0] csr_rs1_value_r;
    reg        csr_exception_valid_r;
    reg [3:0]  csr_exception_cause_r;
    reg [31:0] csr_exception_tval_r;
    reg        csr_check_interrupts_r;

    wire       csr_done;
    wire       csr_wfi_wake;
    wire       csr_trap_taken;
    wire       csr_return_taken;
    wire       csr_illegal;
    wire       csr_wb_en;
    wire [31:0] csr_wb_value;
    wire [31:0] csr_next_pc;
    wire [31:0] csr_trap_cause;
    wire [31:0] csr_trap_tval;
    wire [1:0]  csr_priv;
    wire [31:0] csr_satp;
    wire [31:0] csr_mstatus;
    wire [31:0] csr_mie;
    wire [31:0] csr_mip;
    wire [31:0] csr_medeleg;
    wire [31:0] csr_mideleg;
    wire [31:0] csr_mepc;
    wire [31:0] csr_sepc;
    wire [31:0] csr_mcause;
    wire [31:0] csr_scause;
    wire [31:0] csr_mtval;
    wire [31:0] csr_stval;
    wire [63:0] csr_mcycle;
    wire [63:0] csr_minstret;
    wire        csr_sum;
    wire        csr_mxr;
    wire        csr_mprv;
    wire [1:0]  csr_data_priv;
    wire        fast_retire_allowed = ((csr_mip & csr_mie) == 32'd0);

    assign dbg_satp = csr_satp;
    assign dbg_mepc = csr_mepc;
    assign dbg_sepc = csr_sepc;

    reg [15:0] dec_lo16_r;
    reg [31:0] dec_raw32_r;
    reg        dec_is_rvc_r;
    reg        fetch_fault_r;
    reg [3:0]  fetch_cause_r;
    reg [31:0] fetch_fault_va_r;

    wire [31:0] dec_instr;
    wire [31:0] dec_ilen;
    wire        dec_rvc_illegal;
    wire [6:0]  dec_opc;
    wire [4:0]  dec_rd;
    wire [4:0]  dec_rs1;
    wire [4:0]  dec_rs2;
    wire [2:0]  dec_f3;
    wire [6:0]  dec_f7;
    wire [4:0]  dec_f5;
    wire [11:0] dec_csr_addr;
    wire [4:0]  dec_zimm;
    wire [31:0] dec_immI;
    wire [31:0] dec_immS;
    wire [31:0] dec_immB;
    wire [31:0] dec_immU;
    wire [31:0] dec_immJ;
    wire        dec_is_lui;
    wire        dec_is_auipc;
    wire        dec_is_jal;
    wire        dec_is_jalr;
    wire        dec_is_branch;
    wire        dec_is_load;
    wire        dec_is_store;
    wire        dec_is_opimm;
    wire        dec_is_op;
    wire        dec_is_fence;
    wire        dec_is_amo;
    wire        dec_is_lr;
    wire        dec_is_sc;
    wire        dec_amo_store;
    wire        dec_is_system;
    wire        dec_is_csr;
    wire        dec_is_ecall;
    wire        dec_is_ebreak;
    wire        dec_is_mret;
    wire        dec_is_sret;
    wire        dec_is_wfi;
    wire        dec_is_sfence;
    wire        dec_is_muldiv;
    wire        dec_base_legal;

    wire [31:0] dec_rs1_value = (dec_rs1 == 5'd0) ? 32'd0 : regs[dec_rs1];
    wire [31:0] dec_rs2_value = (dec_rs2 == 5'd0) ? 32'd0 : regs[dec_rs2];

    reg [31:0] ex_instr_r;
    reg [31:0] ex_ilen_r;
    reg        ex_rvc_illegal_r;
    reg [4:0]  ex_rd_r;
    reg [4:0]  ex_rs1_r;
    reg [4:0]  ex_rs2_r;
    reg [2:0]  ex_f3_r;
    reg [6:0]  ex_f7_r;
    reg [4:0]  ex_f5_r;
    reg [11:0] ex_csr_addr_r;
    reg [4:0]  ex_zimm_r;
    reg [31:0] ex_immI_r;
    reg [31:0] ex_immS_r;
    reg [31:0] ex_immB_r;
    reg [31:0] ex_immU_r;
    reg [31:0] ex_immJ_r;
    reg        ex_is_lui_r;
    reg        ex_is_auipc_r;
    reg        ex_is_jal_r;
    reg        ex_is_jalr_r;
    reg        ex_is_branch_r;
    reg        ex_is_load_r;
    reg        ex_is_store_r;
    reg        ex_is_opimm_r;
    reg        ex_is_op_r;
    reg        ex_is_amo_r;
    reg        ex_is_system_r;
    reg        ex_is_csr_r;
    reg        ex_is_ecall_r;
    reg        ex_is_ebreak_r;
    reg        ex_is_mret_r;
    reg        ex_is_sret_r;
    reg        ex_is_wfi_r;
    reg        ex_is_sfence_r;
    reg        ex_is_muldiv_r;
    reg        ex_base_legal_r;
    reg [31:0] ex_rs1_value_r;
    reg [31:0] ex_rs2_value_r;

    wire        csr_writes_satp = ex_is_csr_r && (ex_csr_addr_r == 12'h180) &&
                                  !((ex_f3_r[1:0] != 2'b01) && (ex_rs1_r == 5'd0));
    wire        tlb_flush = (state == S_CSR_WAIT) && csr_done && !csr_trap_taken &&
                            (ex_is_sfence_r || csr_writes_satp);

    wire [31:0] rs1_value = ex_rs1_value_r;
    wire [31:0] rs2_value = ex_rs2_value_r;
    wire signed [31:0] rs1_value_s = rs1_value;
    wire signed [31:0] rs2_value_s = rs2_value;
    wire signed [31:0] ex_immI_s = ex_immI_r;
    wire [31:0] pc_plus_ilen = pc + ex_ilen_r;
    wire [31:0] dec_mem_addr = rs1_value + (ex_is_store_r ? ex_immS_r : ex_immI_r);

    function [31:0] sra32;
        input [31:0] value;
        input [4:0] shamt;
        begin
            if (shamt == 5'd0)
                sra32 = value;
            else
                sra32 = (value >> shamt) |
                        ({32{value[31]}} << (6'd32 - {1'b0, shamt}));
        end
    endfunction

    function is_mmio_addr;
        input [31:0] a;
        begin
            is_mmio_addr = (a[31:16] == 16'h0200) ||
                           (a[31:26] == 6'b000011) ||
                           (a[31:8]  == 24'h10_0000) ||
                           (a[31:12] == 20'h11100);
        end
    endfunction

    wire valid_load_f3 = (ex_f3_r == 3'b000) || (ex_f3_r == 3'b001) ||
                         (ex_f3_r == 3'b010) || (ex_f3_r == 3'b100) ||
                         (ex_f3_r == 3'b101);
    wire valid_store_f3 = (ex_f3_r == 3'b000) || (ex_f3_r == 3'b001) ||
                          (ex_f3_r == 3'b010);
    wire bad_branch_f3 = ex_is_branch_r && ((ex_f3_r == 3'b010) ||
                                            (ex_f3_r == 3'b011));
    wire bad_jalr_f3 = ex_is_jalr_r && (ex_f3_r != 3'b000);
    wire bad_opimm_shift = ex_is_opimm_r &&
        ((ex_f3_r == 3'b001 && ex_f7_r != 7'h00) ||
         (ex_f3_r == 3'b101 && ex_f7_r != 7'h00 && ex_f7_r != 7'h20));
    wire bad_op_f7 = ex_is_op_r &&
        ((ex_f7_r == 7'h20 && ex_f3_r != 3'b000 && ex_f3_r != 3'b101) ||
         (ex_f7_r != 7'h00 && ex_f7_r != 7'h20 && ex_f7_r != 7'h01));
    wire bad_load_store_f3 = (ex_is_load_r && !valid_load_f3) ||
                             (ex_is_store_r && !valid_store_f3);
    wire dec_mem_req_half = (!ex_is_store_r && (ex_f3_r == 3'b001 || ex_f3_r == 3'b101)) ||
                            ( ex_is_store_r &&  ex_f3_r == 3'b001);
    wire dec_mem_req_word = (ex_f3_r == 3'b010);
    wire dec_mem_misaligned = (dec_mem_req_half && dec_mem_addr[0]) ||
                              (dec_mem_req_word && (dec_mem_addr[1:0] != 2'b00));
    wire valid_amo_f5 = (ex_f5_r == 5'b00000) || (ex_f5_r == 5'b00001) ||
                        (ex_f5_r == 5'b00010) || (ex_f5_r == 5'b00011) ||
                        (ex_f5_r == 5'b00100) || (ex_f5_r == 5'b01000) ||
                        (ex_f5_r == 5'b01100) || (ex_f5_r == 5'b10000) ||
                        (ex_f5_r == 5'b10100) || (ex_f5_r == 5'b11000) ||
                        (ex_f5_r == 5'b11100);
    wire bad_amo_f5 = ex_is_amo_r && !valid_amo_f5;

    wire unsupported = ex_rvc_illegal_r || !ex_base_legal_r ||
                       bad_branch_f3 || bad_jalr_f3 || bad_opimm_shift ||
                       bad_op_f7 || bad_load_store_f3 || bad_amo_f5;

    reg        branch_taken;
    reg [31:0] alu_value;
    reg [31:0] normal_pc_next;
    reg        normal_wb_en;
    reg [31:0] normal_wb_value;

    reg        pending_wb_r;
    reg [4:0]  pending_rd_r;
    reg [31:0] pending_wb_value_r;
    reg [31:0] pending_pc_next_r;
    reg        pending_mem_is_store_r;
    reg [2:0]  pending_mem_funct3_r;
    reg [31:0] pending_mem_va_r;
    reg [31:0] pending_mem_store_data_r;

    assign dbg_priv = csr_priv;
    assign dbg_mcause = csr_mcause;
    assign dbg_scause = csr_scause;
    assign dbg_mip = csr_mip;
    assign dbg_mie = csr_mie;
    assign dbg_stval = csr_stval;
    assign dbg_mtime = mmio_mtime;
    assign dbg_mtimecmp = mmio_mtimecmp;

    rvlinux_stage_cluster #(
        .I_LINES(I_LINES),
        .D_LINES(D_LINES),
        .WORDS(WORDS),
        .MEMWORDS(MEMWORDS),
        .LAT(LAT),
        .RAMBASE(RAMBASE),
        .MEMFILE(MEMFILE),
        .MEMFILE_WORDS(MEMFILE_WORDS)
    ) cluster (
        .clk(clk), .rst(rst),
        .satp(csr_satp), .priv(csr_priv), .data_priv(csr_data_priv),
        .sum(csr_sum), .mxr(csr_mxr), .tlb_flush(tlb_flush),

        .fetch_start(fetch_start_r), .fetch_pc(fetch_pc_r),
        .fetch_done(fetch_done), .fetch_busy(fetch_busy),
        .fetch_fault(fetch_fault), .fetch_cause(fetch_cause),
        .fetch_fault_va(fetch_fault_va), .fetch_lo16(fetch_lo16),
        .fetch_raw32(fetch_raw32), .fetch_is_rvc(fetch_is_rvc),
        .fetch_used_second(fetch_used_second),

        .lsu_start(lsu_start_r), .lsu_is_store(lsu_is_store_r),
        .lsu_funct3(lsu_funct3_r), .lsu_va(lsu_va_r),
        .lsu_store_data(lsu_store_data_r), .lsu_done(lsu_done),
        .lsu_busy(lsu_busy), .lsu_fault(lsu_fault),
        .lsu_cause(lsu_cause), .lsu_fault_va(lsu_fault_va),
        .lsu_pa(lsu_pa), .lsu_load_data(lsu_load_data),

        .amo_start(amo_start_r), .amo_funct5(amo_funct5_r),
        .amo_va(amo_va_r), .amo_rs2_value(amo_rs2_value_r),
        .amo_clear_reservation(amo_clear_reservation_r),
        .amo_done(amo_done), .amo_busy(amo_busy), .amo_fault(amo_fault),
        .amo_cause(amo_cause), .amo_fault_va(amo_fault_va),
        .amo_pa(amo_pa), .amo_rd_value(amo_rd_value),
        .amo_reservation_valid(amo_reservation_valid),
        .amo_reservation_addr(amo_reservation_addr),

        .xlate_start(xlate_start_r), .xlate_is_store(xlate_is_store_r),
        .xlate_va(xlate_va_r),
        .xlate_done(xlate_done), .xlate_busy(xlate_busy),
        .xlate_fault(xlate_fault), .xlate_cause(xlate_cause),
        .xlate_fault_va(xlate_fault_va), .xlate_pa(xlate_pa),

        .cluster_busy(cluster_busy), .active_owner(cluster_active_owner),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    rvlinux_muldiv_stage muldiv (
        .clk(clk), .rst(rst),
        .start(muldiv_start_r), .funct3(muldiv_funct3_r),
        .rs1_value(muldiv_rs1_value_r), .rs2_value(muldiv_rs2_value_r),
        .done(muldiv_done), .busy(muldiv_busy), .result(muldiv_result)
    );

    rvlinux_mmio_stage #(
        .MTIME_TICK_CYCLES(MTIME_TICK_CYCLES)
    ) mmio (
        .clk(clk), .rst(rst),
        .start(mmio_start_r), .is_store(mmio_is_store_r),
        .funct3(mmio_funct3_r), .pa(mmio_pa_r),
        .store_data(mmio_store_data_r),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in), .rx_ready(rx_ready),
        .done(mmio_done), .busy(mmio_busy), .fault(mmio_fault),
        .cause(mmio_cause), .fault_pa(mmio_fault_pa),
        .load_data(mmio_load_data),
        .uart_we(uart_we), .uart_data(uart_data),
        .halt(mmio_halt), .exit_code(mmio_exit_code),
        .irq_pending(mmio_irq_pending),
        .mtime_out(mmio_mtime),
        .mtimecmp_out(mmio_mtimecmp),
        .mtime_full_out(mmio_mtime_full),
        .mtimecmp_full_out(mmio_mtimecmp_full)
    );

    rvlinux_csr_trap_stage csr (
        .clk(clk), .rst(rst),
        .step_valid(csr_step_valid_r), .fast_retire(csr_fast_retire_r),
        .pc(csr_pc_r),
        .instr(csr_instr_r), .normal_next_pc(csr_normal_next_pc_r),
        .system_valid(csr_system_valid_r), .is_csr(csr_is_csr_r),
        .is_ecall(csr_is_ecall_r), .is_ebreak(csr_is_ebreak_r),
        .is_mret(csr_is_mret_r), .is_sret(csr_is_sret_r),
        .is_wfi(csr_is_wfi_r), .is_sfence(csr_is_sfence_r),
        .f3(csr_f3_r), .rs1(csr_rs1_r), .zimm(csr_zimm_r),
        .csr_addr(csr_addr_r), .rs1_value(csr_rs1_value_r),
        .exception_valid(csr_exception_valid_r),
        .exception_cause(csr_exception_cause_r),
        .exception_tval(csr_exception_tval_r),
        .irq_pending(mmio_irq_pending),
        .time_value(mmio_mtime_full),
        .check_interrupts(csr_check_interrupts_r),
        .wfi_wake(csr_wfi_wake),
        .done(csr_done), .trap_taken(csr_trap_taken),
        .return_taken(csr_return_taken), .illegal(csr_illegal),
        .wb_en(csr_wb_en), .wb_value(csr_wb_value),
        .next_pc(csr_next_pc), .trap_cause(csr_trap_cause),
        .trap_tval(csr_trap_tval), .priv(csr_priv),
        .satp(csr_satp), .mstatus_out(csr_mstatus),
        .mie_out(csr_mie), .mip_out(csr_mip),
        .medeleg_out(csr_medeleg), .mideleg_out(csr_mideleg),
        .mepc_out(csr_mepc), .sepc_out(csr_sepc),
        .mcause_out(csr_mcause), .scause_out(csr_scause),
        .mtval_out(csr_mtval), .stval_out(csr_stval),
        .mcycle_out(csr_mcycle), .minstret_out(csr_minstret),
        .sum(csr_sum), .mxr(csr_mxr), .mprv(csr_mprv),
        .data_priv(csr_data_priv)
    );

    rvlinux_decode_stage decode (
        .lo16(dec_lo16_r), .raw32(dec_raw32_r), .is_rvc(dec_is_rvc_r),
        .instr(dec_instr), .ilen(dec_ilen), .rvc_illegal(dec_rvc_illegal),
        .opc(dec_opc), .rd(dec_rd), .rs1(dec_rs1), .rs2(dec_rs2),
        .f3(dec_f3), .f7(dec_f7), .f5(dec_f5),
        .csr_addr(dec_csr_addr), .zimm(dec_zimm),
        .immI(dec_immI), .immS(dec_immS), .immB(dec_immB),
        .immU(dec_immU), .immJ(dec_immJ),
        .is_lui(dec_is_lui), .is_auipc(dec_is_auipc),
        .is_jal(dec_is_jal), .is_jalr(dec_is_jalr),
        .is_branch(dec_is_branch), .is_load(dec_is_load),
        .is_store(dec_is_store), .is_opimm(dec_is_opimm),
        .is_op(dec_is_op), .is_fence(dec_is_fence),
        .is_amo(dec_is_amo), .is_lr(dec_is_lr), .is_sc(dec_is_sc),
        .amo_store(dec_amo_store), .is_system(dec_is_system),
        .is_csr(dec_is_csr), .is_ecall(dec_is_ecall),
        .is_ebreak(dec_is_ebreak), .is_mret(dec_is_mret),
        .is_sret(dec_is_sret), .is_wfi(dec_is_wfi),
        .is_sfence(dec_is_sfence), .is_muldiv(dec_is_muldiv),
        .base_legal(dec_base_legal)
    );

    always @(*) begin
        case (ex_f3_r)
        3'b000: branch_taken = (rs1_value == rs2_value);
        3'b001: branch_taken = (rs1_value != rs2_value);
        3'b100: branch_taken = (rs1_value_s < rs2_value_s);
        3'b101: branch_taken = (rs1_value_s >= rs2_value_s);
        3'b110: branch_taken = (rs1_value < rs2_value);
        default: branch_taken = (rs1_value >= rs2_value);
        endcase
    end

    always @(*) begin
        alu_value = 32'd0;
        if (ex_is_opimm_r) begin
            case (ex_f3_r)
            3'b000: alu_value = rs1_value + ex_immI_r;
            3'b010: alu_value = (rs1_value_s < ex_immI_s) ? 32'd1 : 32'd0;
            3'b011: alu_value = (rs1_value < ex_immI_r) ? 32'd1 : 32'd0;
            3'b100: alu_value = rs1_value ^ ex_immI_r;
            3'b110: alu_value = rs1_value | ex_immI_r;
            3'b111: alu_value = rs1_value & ex_immI_r;
            3'b001: alu_value = rs1_value << ex_immI_r[4:0];
            default: alu_value = ex_f7_r[5] ? sra32(rs1_value, ex_immI_r[4:0]) :
                                              (rs1_value >> ex_immI_r[4:0]);
            endcase
        end else begin
            case (ex_f3_r)
            3'b000: alu_value = ex_f7_r[5] ? (rs1_value - rs2_value) :
                                              (rs1_value + rs2_value);
            3'b001: alu_value = rs1_value << rs2_value[4:0];
            3'b010: alu_value = (rs1_value_s < rs2_value_s) ? 32'd1 : 32'd0;
            3'b011: alu_value = (rs1_value < rs2_value) ? 32'd1 : 32'd0;
            3'b100: alu_value = rs1_value ^ rs2_value;
            3'b101: alu_value = ex_f7_r[5] ? sra32(rs1_value, rs2_value[4:0]) :
                                              (rs1_value >> rs2_value[4:0]);
            3'b110: alu_value = rs1_value | rs2_value;
            default: alu_value = rs1_value & rs2_value;
            endcase
        end
    end

    always @(*) begin
        normal_pc_next = pc_plus_ilen;
        if (ex_is_jal_r)
            normal_pc_next = pc + ex_immJ_r;
        else if (ex_is_jalr_r)
            normal_pc_next = (rs1_value + ex_immI_r) & ~32'h1;
        else if (ex_is_branch_r && branch_taken)
            normal_pc_next = pc + ex_immB_r;
    end

    always @(*) begin
        normal_wb_en = 1'b0;
        normal_wb_value = 32'd0;
        if (ex_is_lui_r) begin
            normal_wb_en = 1'b1;
            normal_wb_value = ex_immU_r;
        end else if (ex_is_auipc_r) begin
            normal_wb_en = 1'b1;
            normal_wb_value = pc + ex_immU_r;
        end else if (ex_is_jal_r || ex_is_jalr_r) begin
            normal_wb_en = 1'b1;
            normal_wb_value = pc_plus_ilen;
        end else if (ex_is_opimm_r || ex_is_op_r) begin
            normal_wb_en = 1'b1;
            normal_wb_value = alu_value;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH_START;
            fetch_start_r <= 1'b0;
            fetch_pc_r <= RESET_PC;
            lsu_start_r <= 1'b0;
            lsu_is_store_r <= 1'b0;
            lsu_funct3_r <= 3'd0;
            lsu_va_r <= 32'd0;
            lsu_store_data_r <= 32'd0;
            xlate_start_r <= 1'b0;
            xlate_is_store_r <= 1'b0;
            xlate_va_r <= 32'd0;
            mmio_start_r <= 1'b0;
            mmio_is_store_r <= 1'b0;
            mmio_funct3_r <= 3'd0;
            mmio_pa_r <= 32'd0;
            mmio_store_data_r <= 32'd0;
            muldiv_start_r <= 1'b0;
            muldiv_funct3_r <= 3'd0;
            muldiv_rs1_value_r <= 32'd0;
            muldiv_rs2_value_r <= 32'd0;
            amo_start_r <= 1'b0;
            amo_funct5_r <= 5'd0;
            amo_va_r <= 32'd0;
            amo_rs2_value_r <= 32'd0;
            amo_clear_reservation_r <= 1'b0;
            csr_step_valid_r <= 1'b0;
            csr_fast_retire_r <= 1'b0;
            csr_pc_r <= RESET_PC;
            csr_instr_r <= 32'd0;
            csr_normal_next_pc_r <= RESET_PC;
            csr_system_valid_r <= 1'b0;
            csr_is_csr_r <= 1'b0;
            csr_is_ecall_r <= 1'b0;
            csr_is_ebreak_r <= 1'b0;
            csr_is_mret_r <= 1'b0;
            csr_is_sret_r <= 1'b0;
            csr_is_wfi_r <= 1'b0;
            csr_is_sfence_r <= 1'b0;
            csr_f3_r <= 3'd0;
            csr_rs1_r <= 5'd0;
            csr_zimm_r <= 5'd0;
            csr_addr_r <= 12'd0;
            csr_rs1_value_r <= 32'd0;
            csr_exception_valid_r <= 1'b0;
            csr_exception_cause_r <= 4'd0;
            csr_exception_tval_r <= 32'd0;
            csr_check_interrupts_r <= 1'b1;
            dec_lo16_r <= 16'd0;
            dec_raw32_r <= 32'd0;
            dec_is_rvc_r <= 1'b0;
            fetch_fault_r <= 1'b0;
            fetch_cause_r <= 4'd0;
            fetch_fault_va_r <= RESET_PC;
            ex_instr_r <= 32'd0;
            ex_ilen_r <= 32'd0;
            ex_rvc_illegal_r <= 1'b0;
            ex_rd_r <= 5'd0;
            ex_rs1_r <= 5'd0;
            ex_rs2_r <= 5'd0;
            ex_f3_r <= 3'd0;
            ex_f7_r <= 7'd0;
            ex_f5_r <= 5'd0;
            ex_csr_addr_r <= 12'd0;
            ex_zimm_r <= 5'd0;
            ex_immI_r <= 32'd0;
            ex_immS_r <= 32'd0;
            ex_immB_r <= 32'd0;
            ex_immU_r <= 32'd0;
            ex_immJ_r <= 32'd0;
            ex_is_lui_r <= 1'b0;
            ex_is_auipc_r <= 1'b0;
            ex_is_jal_r <= 1'b0;
            ex_is_jalr_r <= 1'b0;
            ex_is_branch_r <= 1'b0;
            ex_is_load_r <= 1'b0;
            ex_is_store_r <= 1'b0;
            ex_is_opimm_r <= 1'b0;
            ex_is_op_r <= 1'b0;
            ex_is_amo_r <= 1'b0;
            ex_is_system_r <= 1'b0;
            ex_is_csr_r <= 1'b0;
            ex_is_ecall_r <= 1'b0;
            ex_is_ebreak_r <= 1'b0;
            ex_is_mret_r <= 1'b0;
            ex_is_sret_r <= 1'b0;
            ex_is_wfi_r <= 1'b0;
            ex_is_sfence_r <= 1'b0;
            ex_is_muldiv_r <= 1'b0;
            ex_base_legal_r <= 1'b0;
            ex_rs1_value_r <= 32'd0;
            ex_rs2_value_r <= 32'd0;
            pending_wb_r <= 1'b0;
            pending_rd_r <= 5'd0;
            pending_wb_value_r <= 32'd0;
            pending_pc_next_r <= RESET_PC;
            pending_mem_is_store_r <= 1'b0;
            pending_mem_funct3_r <= 3'd0;
            pending_mem_va_r <= 32'd0;
            pending_mem_store_data_r <= 32'd0;
            halt <= 1'b0;
            exit_code <= 32'd0;
            fault <= 1'b0;
            fault_cause <= 4'd0;
            fault_tval <= 32'd0;
            dbg_mmio_valid <= 1'b0;
            dbg_mmio_we <= 1'b0;
            dbg_mmio_funct3 <= 3'd0;
            dbg_mmio_pa <= 32'd0;
            dbg_mmio_wdata <= 32'd0;
            dbg_mmio_rdata <= 32'd0;
            pc <= RESET_PC;
            retired <= 32'd0;
            for (r = 0; r < 32; r = r + 1)
                regs[r] <= 32'd0;
        end else begin
            amo_clear_reservation_r <= 1'b0;
            dbg_mmio_valid <= 1'b0;
            csr_fast_retire_r <= 1'b0;
            case (state)
            S_FETCH_START: begin
                fetch_pc_r <= pc;
                fetch_start_r <= 1'b1;
                lsu_start_r <= 1'b0;
                xlate_start_r <= 1'b0;
                mmio_start_r <= 1'b0;
                muldiv_start_r <= 1'b0;
                amo_start_r <= 1'b0;
                state <= S_FETCH_WAIT;
            end

            S_FETCH_WAIT: begin
                if (fetch_done) begin
                    dec_lo16_r <= fetch_lo16;
                    dec_raw32_r <= fetch_raw32;
                    dec_is_rvc_r <= fetch_is_rvc;
                    fetch_fault_r <= fetch_fault;
                    fetch_cause_r <= fetch_cause;
                    fetch_fault_va_r <= fetch_fault_va;
                    fetch_start_r <= 1'b0;
                    state <= S_DECODE;
                end
            end

            S_DECODE: begin
                ex_instr_r <= dec_instr;
                ex_ilen_r <= dec_ilen;
                ex_rvc_illegal_r <= dec_rvc_illegal;
                ex_rd_r <= dec_rd;
                ex_rs1_r <= dec_rs1;
                ex_rs2_r <= dec_rs2;
                ex_f3_r <= dec_f3;
                ex_f7_r <= dec_f7;
                ex_f5_r <= dec_f5;
                ex_csr_addr_r <= dec_csr_addr;
                ex_zimm_r <= dec_zimm;
                ex_immI_r <= dec_immI;
                ex_immS_r <= dec_immS;
                ex_immB_r <= dec_immB;
                ex_immU_r <= dec_immU;
                ex_immJ_r <= dec_immJ;
                ex_is_lui_r <= dec_is_lui;
                ex_is_auipc_r <= dec_is_auipc;
                ex_is_jal_r <= dec_is_jal;
                ex_is_jalr_r <= dec_is_jalr;
                ex_is_branch_r <= dec_is_branch;
                ex_is_load_r <= dec_is_load;
                ex_is_store_r <= dec_is_store;
                ex_is_opimm_r <= dec_is_opimm;
                ex_is_op_r <= dec_is_op;
                ex_is_amo_r <= dec_is_amo;
                ex_is_system_r <= dec_is_system;
                ex_is_csr_r <= dec_is_csr;
                ex_is_ecall_r <= dec_is_ecall;
                ex_is_ebreak_r <= dec_is_ebreak;
                ex_is_mret_r <= dec_is_mret;
                ex_is_sret_r <= dec_is_sret;
                ex_is_wfi_r <= dec_is_wfi;
                ex_is_sfence_r <= dec_is_sfence;
                ex_is_muldiv_r <= dec_is_muldiv;
                ex_base_legal_r <= dec_base_legal;
                ex_rs1_value_r <= dec_rs1_value;
                ex_rs2_value_r <= dec_rs2_value;
                state <= S_EXECUTE;
            end

            S_EXECUTE: begin
                if (fetch_fault_r) begin
                    pending_wb_r <= 1'b0;
                    pending_rd_r <= 5'd0;
                    pending_wb_value_r <= 32'd0;
                    csr_pc_r <= pc;
                    csr_instr_r <= ex_instr_r;
                    csr_normal_next_pc_r <= pc_plus_ilen;
                    csr_system_valid_r <= 1'b0;
                    csr_is_csr_r <= 1'b0;
                    csr_is_ecall_r <= 1'b0;
                    csr_is_ebreak_r <= 1'b0;
                    csr_is_mret_r <= 1'b0;
                    csr_is_sret_r <= 1'b0;
                    csr_is_wfi_r <= 1'b0;
                    csr_is_sfence_r <= 1'b0;
                    csr_f3_r <= ex_f3_r;
                    csr_rs1_r <= ex_rs1_r;
                    csr_zimm_r <= ex_zimm_r;
                    csr_addr_r <= ex_csr_addr_r;
                    csr_rs1_value_r <= rs1_value;
                    csr_exception_valid_r <= 1'b1;
                    csr_exception_cause_r <= fetch_cause_r;
                    csr_exception_tval_r <= fetch_fault_va_r;
                    csr_step_valid_r <= 1'b1;
                    state <= S_CSR_WAIT;
                end else if (unsupported) begin
                    pending_wb_r <= 1'b0;
                    pending_rd_r <= 5'd0;
                    pending_wb_value_r <= 32'd0;
                    csr_pc_r <= pc;
                    csr_instr_r <= ex_instr_r;
                    csr_normal_next_pc_r <= pc_plus_ilen;
                    csr_system_valid_r <= 1'b0;
                    csr_is_csr_r <= 1'b0;
                    csr_is_ecall_r <= 1'b0;
                    csr_is_ebreak_r <= 1'b0;
                    csr_is_mret_r <= 1'b0;
                    csr_is_sret_r <= 1'b0;
                    csr_is_wfi_r <= 1'b0;
                    csr_is_sfence_r <= 1'b0;
                    csr_f3_r <= ex_f3_r;
                    csr_rs1_r <= ex_rs1_r;
                    csr_zimm_r <= ex_zimm_r;
                    csr_addr_r <= ex_csr_addr_r;
                    csr_rs1_value_r <= rs1_value;
                    csr_exception_valid_r <= 1'b1;
                    csr_exception_cause_r <= CAUSE_ILLEGAL;
                    csr_exception_tval_r <= ex_instr_r;
                    csr_step_valid_r <= 1'b1;
                    state <= S_CSR_WAIT;
                end else if (ex_is_ebreak_r && EBREAK_HALTS) begin
                    halt <= 1'b1;
                    state <= S_HALT;
                end else if (ex_is_muldiv_r) begin
                    muldiv_funct3_r <= ex_f3_r;
                    muldiv_rs1_value_r <= rs1_value;
                    muldiv_rs2_value_r <= rs2_value;
                    pending_wb_r <= (ex_rd_r != 5'd0);
                    pending_rd_r <= ex_rd_r;
                    pending_wb_value_r <= 32'd0;
                    pending_pc_next_r <= pc_plus_ilen;
                    muldiv_start_r <= 1'b1;
                    state <= S_MULDIV_WAIT;
                end else if (ex_is_amo_r) begin
                    amo_funct5_r <= ex_f5_r;
                    amo_va_r <= rs1_value;
                    amo_rs2_value_r <= rs2_value;
                    pending_wb_r <= (ex_rd_r != 5'd0);
                    pending_rd_r <= ex_rd_r;
                    pending_wb_value_r <= 32'd0;
                    pending_pc_next_r <= pc_plus_ilen;
                    amo_start_r <= 1'b1;
                    state <= S_AMO_WAIT;
                end else if (ex_is_load_r || ex_is_store_r) begin
                    pending_wb_r <= ex_is_load_r && (ex_rd_r != 5'd0);
                    pending_rd_r <= ex_rd_r;
                    pending_wb_value_r <= 32'd0;
                    pending_pc_next_r <= pc_plus_ilen;
                    pending_mem_is_store_r <= ex_is_store_r;
                    pending_mem_funct3_r <= ex_f3_r;
                    pending_mem_va_r <= dec_mem_addr;
                    pending_mem_store_data_r <= rs2_value;
                    if (dec_mem_misaligned) begin
                        pending_wb_r <= 1'b0;
                        pending_rd_r <= 5'd0;
                        csr_pc_r <= pc;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= pc_plus_ilen;
                        csr_system_valid_r <= 1'b0;
                        csr_is_csr_r <= 1'b0;
                        csr_is_ecall_r <= 1'b0;
                        csr_is_ebreak_r <= 1'b0;
                        csr_is_mret_r <= 1'b0;
                        csr_is_sret_r <= 1'b0;
                        csr_is_wfi_r <= 1'b0;
                        csr_is_sfence_r <= 1'b0;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b1;
                        csr_exception_cause_r <= ex_is_store_r ? CAUSE_STORE_MAL : CAUSE_LOAD_MAL;
                        csr_exception_tval_r <= dec_mem_addr;
                        csr_step_valid_r <= 1'b1;
                        lsu_start_r <= 1'b0;
                        xlate_start_r <= 1'b0;
                        mmio_start_r <= 1'b0;
                        state <= S_CSR_WAIT;
                    end else begin
                        xlate_is_store_r <= ex_is_store_r;
                        xlate_va_r <= dec_mem_addr;
                        xlate_start_r <= 1'b1;
                        lsu_start_r <= 1'b0;
                        mmio_start_r <= 1'b0;
                        state <= S_XLATE_WAIT;
                    end
                end else if (ex_is_wfi_r) begin
                    pending_wb_r <= 1'b0;
                    pending_rd_r <= 5'd0;
                    pending_wb_value_r <= 32'd0;
                    pending_pc_next_r <= pc_plus_ilen;
                    if (csr_wfi_wake) begin
                        csr_pc_r <= pc_plus_ilen;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= pc_plus_ilen;
                        csr_system_valid_r <= 1'b1;
                        csr_is_csr_r <= 1'b0;
                        csr_is_ecall_r <= 1'b0;
                        csr_is_ebreak_r <= 1'b0;
                        csr_is_mret_r <= 1'b0;
                        csr_is_sret_r <= 1'b0;
                        csr_is_wfi_r <= 1'b1;
                        csr_is_sfence_r <= 1'b0;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b0;
                        csr_exception_cause_r <= 4'd0;
                        csr_exception_tval_r <= 32'd0;
                        csr_check_interrupts_r <= 1'b1;
                        csr_step_valid_r <= 1'b1;
                        state <= S_CSR_WAIT;
                    end else begin
                        csr_step_valid_r <= 1'b0;
                        state <= S_WFI_WAIT;
                    end
                end else begin
                    pending_wb_r <= normal_wb_en && (ex_rd_r != 5'd0);
                    pending_rd_r <= ex_rd_r;
                    pending_wb_value_r <= normal_wb_value;
                    pending_pc_next_r <= normal_pc_next;
                    if (!ex_is_system_r && fast_retire_allowed) begin
                        if (normal_wb_en && ex_rd_r != 5'd0)
                            regs[ex_rd_r] <= normal_wb_value;
                        pc <= normal_pc_next;
                        fetch_pc_r <= normal_pc_next;
                        fetch_start_r <= 1'b1;
                        retired <= retired + 32'd1;
                        pending_wb_r <= 1'b0;
                        csr_fast_retire_r <= 1'b1;
                        state <= S_FETCH_WAIT;
                    end else begin
                        csr_pc_r <= pc;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= normal_pc_next;
                        csr_system_valid_r <= ex_is_system_r;
                        csr_is_csr_r <= ex_is_csr_r;
                        csr_is_ecall_r <= ex_is_ecall_r;
                        csr_is_ebreak_r <= ex_is_ebreak_r;
                        csr_is_mret_r <= ex_is_mret_r;
                        csr_is_sret_r <= ex_is_sret_r;
                        csr_is_wfi_r <= ex_is_wfi_r;
                        csr_is_sfence_r <= ex_is_sfence_r;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b0;
                        csr_exception_cause_r <= 4'd0;
                        csr_exception_tval_r <= 32'd0;
                        csr_step_valid_r <= 1'b1;
                        state <= S_CSR_WAIT;
                    end
                end
            end

            S_LSU_WAIT: begin
                if (lsu_done) begin
                    lsu_start_r <= 1'b0;
                    if (lsu_fault) begin
                        pending_wb_r <= 1'b0;
                        pending_rd_r <= 5'd0;
                        pending_wb_value_r <= 32'd0;
                        csr_pc_r <= pc;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= pending_pc_next_r;
                        csr_system_valid_r <= 1'b0;
                        csr_is_csr_r <= 1'b0;
                        csr_is_ecall_r <= 1'b0;
                        csr_is_ebreak_r <= 1'b0;
                        csr_is_mret_r <= 1'b0;
                        csr_is_sret_r <= 1'b0;
                        csr_is_wfi_r <= 1'b0;
                        csr_is_sfence_r <= 1'b0;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b1;
                        csr_exception_cause_r <= lsu_cause;
                        csr_exception_tval_r <= lsu_fault_va;
                        csr_step_valid_r <= 1'b1;
                        state <= S_CSR_WAIT;
                    end else begin
                        if (lsu_is_store_r && amo_reservation_valid &&
                            (amo_reservation_addr == {lsu_pa[31:2], 2'b00}))
                            amo_clear_reservation_r <= 1'b1;
                        if (lsu_is_store_r || fast_retire_allowed) begin
                            if (!lsu_is_store_r && pending_wb_r)
                                regs[pending_rd_r] <= lsu_load_data;
                            pc <= pending_pc_next_r;
                            fetch_pc_r <= pending_pc_next_r;
                            fetch_start_r <= 1'b1;
                            retired <= retired + 32'd1;
                            pending_wb_r <= 1'b0;
                            csr_fast_retire_r <= 1'b1;
                            state <= S_FETCH_WAIT;
                        end else begin
                            pending_wb_value_r <= lsu_load_data;
                            csr_pc_r <= pc;
                            csr_instr_r <= ex_instr_r;
                            csr_normal_next_pc_r <= pending_pc_next_r;
                            csr_system_valid_r <= 1'b0;
                            csr_is_csr_r <= 1'b0;
                            csr_is_ecall_r <= 1'b0;
                            csr_is_ebreak_r <= 1'b0;
                            csr_is_mret_r <= 1'b0;
                            csr_is_sret_r <= 1'b0;
                            csr_is_wfi_r <= 1'b0;
                            csr_is_sfence_r <= 1'b0;
                            csr_f3_r <= ex_f3_r;
                            csr_rs1_r <= ex_rs1_r;
                            csr_zimm_r <= ex_zimm_r;
                            csr_addr_r <= ex_csr_addr_r;
                            csr_rs1_value_r <= rs1_value;
                            csr_exception_valid_r <= 1'b0;
                            csr_exception_cause_r <= 4'd0;
                            csr_exception_tval_r <= 32'd0;
                            csr_check_interrupts_r <= !lsu_is_store_r;
                            csr_step_valid_r <= 1'b1;
                            state <= S_CSR_WAIT;
                        end
                    end
                end
            end

            S_WFI_WAIT: begin
                fetch_start_r <= 1'b0;
                lsu_start_r <= 1'b0;
                xlate_start_r <= 1'b0;
                mmio_start_r <= 1'b0;
                muldiv_start_r <= 1'b0;
                amo_start_r <= 1'b0;
                csr_step_valid_r <= 1'b0;
                if (csr_wfi_wake) begin
                    pending_wb_r <= 1'b0;
                    pending_rd_r <= 5'd0;
                    pending_wb_value_r <= 32'd0;
                    csr_pc_r <= pc_plus_ilen;
                    csr_instr_r <= ex_instr_r;
                    csr_normal_next_pc_r <= pc_plus_ilen;
                    csr_system_valid_r <= 1'b1;
                    csr_is_csr_r <= 1'b0;
                    csr_is_ecall_r <= 1'b0;
                    csr_is_ebreak_r <= 1'b0;
                    csr_is_mret_r <= 1'b0;
                    csr_is_sret_r <= 1'b0;
                    csr_is_wfi_r <= 1'b1;
                    csr_is_sfence_r <= 1'b0;
                    csr_f3_r <= ex_f3_r;
                    csr_rs1_r <= ex_rs1_r;
                    csr_zimm_r <= ex_zimm_r;
                    csr_addr_r <= ex_csr_addr_r;
                    csr_rs1_value_r <= rs1_value;
                    csr_exception_valid_r <= 1'b0;
                    csr_exception_cause_r <= 4'd0;
                    csr_exception_tval_r <= 32'd0;
                    csr_step_valid_r <= 1'b1;
                    state <= S_CSR_WAIT;
                end
            end

            S_LSU_DROP: begin
                lsu_start_r <= 1'b0;
                if (!cluster_busy)
                    state <= S_FETCH_START;
            end

            S_XLATE_WAIT: begin
                if (xlate_done) begin
                    xlate_start_r <= 1'b0;
                    if (xlate_fault) begin
                        pending_wb_r <= 1'b0;
                        pending_rd_r <= 5'd0;
                        pending_wb_value_r <= 32'd0;
                        csr_pc_r <= pc;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= pending_pc_next_r;
                        csr_system_valid_r <= 1'b0;
                        csr_is_csr_r <= 1'b0;
                        csr_is_ecall_r <= 1'b0;
                        csr_is_ebreak_r <= 1'b0;
                        csr_is_mret_r <= 1'b0;
                        csr_is_sret_r <= 1'b0;
                        csr_is_wfi_r <= 1'b0;
                        csr_is_sfence_r <= 1'b0;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b1;
                        csr_exception_cause_r <= xlate_cause;
                        csr_exception_tval_r <= xlate_fault_va;
                        csr_step_valid_r <= 1'b1;
                        state <= S_CSR_WAIT;
                    end else if (is_mmio_addr(xlate_pa)) begin
                        mmio_is_store_r <= pending_mem_is_store_r;
                        mmio_funct3_r <= pending_mem_funct3_r;
                        mmio_pa_r <= xlate_pa;
                        mmio_store_data_r <= pending_mem_store_data_r;
                        mmio_start_r <= 1'b1;
                        lsu_start_r <= 1'b0;
                        state <= S_MMIO_WAIT;
                    end else begin
                        lsu_is_store_r <= pending_mem_is_store_r;
                        lsu_funct3_r <= pending_mem_funct3_r;
                        lsu_va_r <= pending_mem_va_r;
                        lsu_store_data_r <= pending_mem_store_data_r;
                        lsu_start_r <= 1'b1;
                        mmio_start_r <= 1'b0;
                        state <= S_LSU_WAIT;
                    end
                end
            end

            S_MULDIV_WAIT: begin
                if (muldiv_done) begin
                    muldiv_start_r <= 1'b0;
                    pending_wb_value_r <= muldiv_result;
                    if (fast_retire_allowed) begin
                        if (pending_wb_r)
                            regs[pending_rd_r] <= muldiv_result;
                        pc <= pending_pc_next_r;
                        fetch_pc_r <= pending_pc_next_r;
                        fetch_start_r <= 1'b1;
                        retired <= retired + 32'd1;
                        pending_wb_r <= 1'b0;
                        csr_fast_retire_r <= 1'b1;
                        state <= S_FETCH_WAIT;
                    end else begin
                        csr_pc_r <= pc;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= pending_pc_next_r;
                        csr_system_valid_r <= 1'b0;
                        csr_is_csr_r <= 1'b0;
                        csr_is_ecall_r <= 1'b0;
                        csr_is_ebreak_r <= 1'b0;
                        csr_is_mret_r <= 1'b0;
                        csr_is_sret_r <= 1'b0;
                        csr_is_wfi_r <= 1'b0;
                        csr_is_sfence_r <= 1'b0;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b0;
                        csr_exception_cause_r <= 4'd0;
                        csr_exception_tval_r <= 32'd0;
                        csr_step_valid_r <= 1'b1;
                        state <= S_CSR_WAIT;
                    end
                end
            end

            S_AMO_WAIT: begin
                if (amo_done) begin
                    amo_start_r <= 1'b0;
                    if (amo_fault) begin
                        pending_wb_r <= 1'b0;
                        pending_rd_r <= 5'd0;
                        pending_wb_value_r <= 32'd0;
                        csr_pc_r <= pc;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= pending_pc_next_r;
                        csr_system_valid_r <= 1'b0;
                        csr_is_csr_r <= 1'b0;
                        csr_is_ecall_r <= 1'b0;
                        csr_is_ebreak_r <= 1'b0;
                        csr_is_mret_r <= 1'b0;
                        csr_is_sret_r <= 1'b0;
                        csr_is_wfi_r <= 1'b0;
                        csr_is_sfence_r <= 1'b0;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b1;
                        csr_exception_cause_r <= amo_cause;
                        csr_exception_tval_r <= amo_fault_va;
                        csr_step_valid_r <= 1'b1;
                        state <= S_CSR_WAIT;
                    end else begin
                        pending_wb_value_r <= amo_rd_value;
                        if (fast_retire_allowed) begin
                            if (pending_wb_r)
                                regs[pending_rd_r] <= amo_rd_value;
                            pc <= pending_pc_next_r;
                            fetch_pc_r <= pending_pc_next_r;
                            fetch_start_r <= 1'b1;
                            retired <= retired + 32'd1;
                            pending_wb_r <= 1'b0;
                            csr_fast_retire_r <= 1'b1;
                            state <= S_FETCH_WAIT;
                        end else begin
                            csr_pc_r <= pc;
                            csr_instr_r <= ex_instr_r;
                            csr_normal_next_pc_r <= pending_pc_next_r;
                            csr_system_valid_r <= 1'b0;
                            csr_is_csr_r <= 1'b0;
                            csr_is_ecall_r <= 1'b0;
                            csr_is_ebreak_r <= 1'b0;
                            csr_is_mret_r <= 1'b0;
                            csr_is_sret_r <= 1'b0;
                            csr_is_wfi_r <= 1'b0;
                            csr_is_sfence_r <= 1'b0;
                            csr_f3_r <= ex_f3_r;
                            csr_rs1_r <= ex_rs1_r;
                            csr_zimm_r <= ex_zimm_r;
                            csr_addr_r <= ex_csr_addr_r;
                            csr_rs1_value_r <= rs1_value;
                            csr_exception_valid_r <= 1'b0;
                            csr_exception_cause_r <= 4'd0;
                            csr_exception_tval_r <= 32'd0;
                            csr_check_interrupts_r <= 1'b0;
                            csr_step_valid_r <= 1'b1;
                            state <= S_CSR_WAIT;
                        end
                    end
                end
            end

            S_AMO_DROP: begin
                amo_start_r <= 1'b0;
                if (!cluster_busy)
                    state <= S_FETCH_START;
            end

            S_MMIO_WAIT: begin
                if (mmio_done) begin
                    mmio_start_r <= 1'b0;
                    dbg_mmio_valid <= 1'b1;
                    dbg_mmio_we <= mmio_is_store_r;
                    dbg_mmio_funct3 <= mmio_funct3_r;
                    dbg_mmio_pa <= mmio_pa_r;
                    dbg_mmio_wdata <= mmio_store_data_r;
                    dbg_mmio_rdata <= mmio_load_data;
                    if (mmio_fault) begin
                        pending_wb_r <= 1'b0;
                        pending_rd_r <= 5'd0;
                        pending_wb_value_r <= 32'd0;
                        csr_pc_r <= pc;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= pending_pc_next_r;
                        csr_system_valid_r <= 1'b0;
                        csr_is_csr_r <= 1'b0;
                        csr_is_ecall_r <= 1'b0;
                        csr_is_ebreak_r <= 1'b0;
                        csr_is_mret_r <= 1'b0;
                        csr_is_sret_r <= 1'b0;
                        csr_is_wfi_r <= 1'b0;
                        csr_is_sfence_r <= 1'b0;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b1;
                        csr_exception_cause_r <= mmio_cause;
                        csr_exception_tval_r <= mmio_fault_pa;
                        csr_step_valid_r <= 1'b1;
                        state <= S_CSR_WAIT;
                    end else if (mmio_halt) begin
                        pc <= pending_pc_next_r;
                        retired <= retired + 32'd1;
                        pending_wb_r <= 1'b0;
                        exit_code <= mmio_exit_code;
                        halt <= 1'b1;
                        state <= S_HALT;
                    end else begin
                        pending_wb_value_r <= mmio_load_data;
                        csr_pc_r <= pc;
                        csr_instr_r <= ex_instr_r;
                        csr_normal_next_pc_r <= pending_pc_next_r;
                        csr_system_valid_r <= 1'b0;
                        csr_is_csr_r <= 1'b0;
                        csr_is_ecall_r <= 1'b0;
                        csr_is_ebreak_r <= 1'b0;
                        csr_is_mret_r <= 1'b0;
                        csr_is_sret_r <= 1'b0;
                        csr_is_wfi_r <= 1'b0;
                        csr_is_sfence_r <= 1'b0;
                        csr_f3_r <= ex_f3_r;
                        csr_rs1_r <= ex_rs1_r;
                        csr_zimm_r <= ex_zimm_r;
                        csr_addr_r <= ex_csr_addr_r;
                        csr_rs1_value_r <= rs1_value;
                        csr_exception_valid_r <= 1'b0;
                        csr_exception_cause_r <= 4'd0;
                        csr_exception_tval_r <= 32'd0;
                        csr_check_interrupts_r <= 1'b0;
                        csr_step_valid_r <= 1'b1;
                        state <= S_CSR_WAIT;
                    end
                end
            end

            S_CSR_WAIT: begin
                csr_step_valid_r <= 1'b0;
                if (csr_done) begin
                    csr_check_interrupts_r <= 1'b1;
                    pc <= csr_next_pc;
                    if (csr_trap_taken) begin
                        pending_wb_r <= 1'b0;
                    end else if (csr_return_taken) begin
                        retired <= retired + 32'd1;
                        pending_wb_r <= 1'b0;
                    end else begin
                        if (csr_wb_en && pending_rd_r != 5'd0)
                            regs[pending_rd_r] <= csr_wb_value;
                        else if (pending_wb_r)
                            regs[pending_rd_r] <= pending_wb_value_r;
                        retired <= retired + 32'd1;
                        pending_wb_r <= 1'b0;
                    end
                    fetch_pc_r <= csr_next_pc;
                    fetch_start_r <= 1'b1;
                    state <= S_FETCH_WAIT;
                end
            end

            S_HALT: begin
                fetch_start_r <= 1'b0;
                lsu_start_r <= 1'b0;
                xlate_start_r <= 1'b0;
                mmio_start_r <= 1'b0;
                muldiv_start_r <= 1'b0;
                amo_start_r <= 1'b0;
                csr_step_valid_r <= 1'b0;
                halt <= 1'b1;
            end

            default: begin
                state <= S_HALT;
                halt <= 1'b1;
                fault <= 1'b1;
                fault_cause <= CAUSE_ILLEGAL;
                fault_tval <= 32'hffff_ffff;
            end
            endcase
        end
    end
endmodule
