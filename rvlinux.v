`timescale 1ns/1ps
// ===========================================================================
// rvlinux: single-cycle RV32IMA + Zicsr + M/S/U privilege + Sv32 MMU.
//   Goal: boot real MMU Linux (buildroot qemu_riscv32_virt) on top of OpenSBI.
//   - RV32I + M (behavioral mul/div for sim speed) + A (LR/SC + AMO*)
//   - Three privilege modes (M=3, S=1, U=0)
//   - Sv32 hardware page-table walk for fetch + load/store/amo (combinational,
//     reads the unified RAM array; HW sets A/D on the leaf PTE)
//   - Full S-mode CSR set + trap delegation (medeleg/mideleg)
//   - qemu-virt physical memory map: CLINT 0x0200_0000, PLIC 0x0C00_0000,
//     16550 UART 0x1000_0000, syscon 0x1110_0000, RAM 0x8000_0000 (64MB)
//   Single-cycle => precise traps trivially hold.
//   (Combinational PTW/div are for functional sim under Verilator; the
//    synthesizable variant lives in the cached/multicycle core.)
// ===========================================================================
module rvlinux #(
    parameter MEMFILE  = "fw_payload.hex",
    parameter MEMWORDS = 16*1024*1024,          // 64 MB / 4
    parameter MEMFILE_WORDS = 0,
    parameter [31:0] RAMBASE = 32'h8000_0000,
    parameter EBREAK_HALTS = 1,
    parameter [31:0] MTIME_TICK_CYCLES = 32'd1
)(
    input  wire        clk,
    input  wire        rst,
    output reg         uart_we,
    output reg  [7:0]  uart_data,
    input  wire        rx_valid,      // sim has a byte for UART RX
    input  wire [7:0]  rx_byte_in,
    output wire        rx_ready,      // UART accepted the RX byte this cycle
    output reg         halt,
    output reg  [31:0] exit_code,
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
    output wire [31:0] dbg_satp,
    output wire [31:0] dbg_mepc,
    output wire [31:0] dbg_sepc,
    output wire [31:0] dbg_mtime,
    output wire [31:0] dbg_mtimecmp,
    output wire        dbg_mmio_valid,
    output wire        dbg_mmio_we,
    output wire [2:0]  dbg_mmio_funct3,
    output wire [31:0] dbg_mmio_pa,
    output wire [31:0] dbg_mmio_wdata,
    output wire [31:0] dbg_mmio_rdata
);
`ifdef RVLINUX_SYNTH_SHELL
    wire        shell_uart_we;
    wire [7:0]  shell_uart_data;
    wire        shell_halt;
    wire [31:0] shell_exit_code;
    wire        shell_fault;
    wire [3:0]  shell_fault_cause;
    wire [31:0] shell_fault_tval;
    wire [31:0] shell_pc;
    wire [31:0] shell_retired;
    wire [31:0] shell_x3;
    wire [31:0] shell_x5;
    wire [31:0] shell_x6;
    wire [31:0] shell_x10;
    wire [31:0] shell_dbg_rval;
    wire [1:0]  shell_priv;
    wire [31:0] shell_dbg_mcause;
    wire [31:0] shell_dbg_scause;
    wire [31:0] shell_dbg_mip;
    wire [31:0] shell_dbg_mie;
    wire [31:0] shell_dbg_stval;
    wire [31:0] shell_dbg_satp;
    wire [31:0] shell_dbg_mepc;
    wire [31:0] shell_dbg_sepc;
    wire [31:0] shell_dbg_mtime;
    wire [31:0] shell_dbg_mtimecmp;
    wire        shell_dbg_mmio_valid;
    wire        shell_dbg_mmio_we;
    wire [2:0]  shell_dbg_mmio_funct3;
    wire [31:0] shell_dbg_mmio_pa;
    wire [31:0] shell_dbg_mmio_wdata;
    wire [31:0] shell_dbg_mmio_rdata;
    wire        shell_cluster_busy;
    wire [2:0]  shell_active_owner;
    wire [31:0] shell_i_hits;
    wire [31:0] shell_i_misses;
    wire [31:0] shell_d_hits;
    wire [31:0] shell_d_misses;
    wire [31:0] shell_ad_writes;
    wire        shell_backing_req;
    wire        shell_backing_we;
    wire [31:0] shell_backing_addr;
    wire        shell_backing_ack;

    assign dbg_pc = shell_pc;
    assign dbg_priv = shell_priv;
    assign dbg_rval = shell_dbg_rval;
    assign dbg_mval = 32'd0;
    assign dbg_scause = shell_dbg_scause;
    assign dbg_mcause = shell_dbg_mcause;
    assign dbg_mip = shell_dbg_mip;
    assign dbg_mie = shell_dbg_mie;
    assign dbg_stval = shell_dbg_stval;
    assign dbg_satp = shell_dbg_satp;
    assign dbg_mepc = shell_dbg_mepc;
    assign dbg_sepc = shell_dbg_sepc;
    assign dbg_mtime = shell_dbg_mtime;
    assign dbg_mtimecmp = shell_dbg_mtimecmp;
    assign dbg_mmio_valid = shell_dbg_mmio_valid;
    assign dbg_mmio_we = shell_dbg_mmio_we;
    assign dbg_mmio_funct3 = shell_dbg_mmio_funct3;
    assign dbg_mmio_pa = shell_dbg_mmio_pa;
    assign dbg_mmio_wdata = shell_dbg_mmio_wdata;
    assign dbg_mmio_rdata = shell_dbg_mmio_rdata;

    always @(*) begin
        uart_we = shell_uart_we;
        uart_data = shell_uart_data;
        halt = shell_halt;
        exit_code = shell_exit_code;
    end

    rvlinux_min_core_fsm #(
        .RESET_PC(RAMBASE),
        .I_LINES(16),
        .D_LINES(16),
        .WORDS(4),
        .MEMWORDS(MEMWORDS),
        .LAT(5),
        .RAMBASE(RAMBASE),
        .MEMFILE(MEMFILE),
        .MEMFILE_WORDS(MEMFILE_WORDS),
        .EBREAK_HALTS(EBREAK_HALTS),
        .MTIME_TICK_CYCLES(MTIME_TICK_CYCLES)
    ) synth_shell (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in), .rx_ready(rx_ready),
        .uart_we(shell_uart_we), .uart_data(shell_uart_data),
        .halt(shell_halt), .exit_code(shell_exit_code),
        .fault(shell_fault), .fault_cause(shell_fault_cause),
        .fault_tval(shell_fault_tval), .pc(shell_pc),
        .retired(shell_retired),
        .dbg_x3(shell_x3), .dbg_x5(shell_x5), .dbg_x6(shell_x6),
        .dbg_x10(shell_x10),
        .dbg_rsel(dbg_rsel), .dbg_rval(shell_dbg_rval),
        .dbg_priv(shell_priv),
        .dbg_mcause(shell_dbg_mcause),
        .dbg_scause(shell_dbg_scause),
        .dbg_mip(shell_dbg_mip),
        .dbg_mie(shell_dbg_mie),
        .dbg_stval(shell_dbg_stval),
        .dbg_satp(shell_dbg_satp),
        .dbg_mepc(shell_dbg_mepc),
        .dbg_sepc(shell_dbg_sepc),
        .dbg_mtime(shell_dbg_mtime),
        .dbg_mtimecmp(shell_dbg_mtimecmp),
        .dbg_mmio_valid(shell_dbg_mmio_valid),
        .dbg_mmio_we(shell_dbg_mmio_we),
        .dbg_mmio_funct3(shell_dbg_mmio_funct3),
        .dbg_mmio_pa(shell_dbg_mmio_pa),
        .dbg_mmio_wdata(shell_dbg_mmio_wdata),
        .dbg_mmio_rdata(shell_dbg_mmio_rdata),
        .cluster_busy(shell_cluster_busy),
        .cluster_active_owner(shell_active_owner),
        .i_hits(shell_i_hits), .i_misses(shell_i_misses),
        .d_hits(shell_d_hits), .d_misses(shell_d_misses),
        .ad_writes(shell_ad_writes),
        .backing_req(shell_backing_req), .backing_we(shell_backing_we),
        .backing_addr(shell_backing_addr), .backing_ack(shell_backing_ack)
    );
`else
    integer i;
    localparam RAMMASK = (MEMWORDS*4) - 1;      // byte mask within RAM
    reg [31:0] mem [0:MEMWORDS-1];
    initial begin
`ifdef SIM_INIT
        if (MEMFILE_WORDS == 0)
            $readmemh(MEMFILE, mem);
        else
            $readmemh(MEMFILE, mem, 0, MEMFILE_WORDS-1);
`endif
    end

    // -------------------- architectural state --------------------
    reg [31:0] pc;
    reg [31:0] regs [0:31];
    reg [1:0]  priv;                            // 0=U 1=S 3=M
    initial begin pc=RAMBASE; priv=2'd3; for(i=0;i<32;i=i+1) regs[i]=0; end
    assign dbg_pc = pc;
    assign dbg_priv = priv;
    assign dbg_rval = regs[dbg_rsel];
    assign dbg_mval = mem[(dbg_maddr & RAMMASK)>>2];

    localparam PRV_U=2'd0, PRV_S=2'd1, PRV_M=2'd3;

    // CSRs
    reg [31:0] mstatus, mtvec, mscratch, mepc, mcause, mtval, mie, mip;
    reg [31:0] medeleg, mideleg, menvcfg, menvcfgh, misa;
    reg [31:0] stvec, sscratch, sepc, scause, stval, satp;
    reg [63:0] mtime, mtimecmp, mcycle, minstret;
    reg [31:0] mtime_tick_count;
    reg [31:0] lr_addr; reg lr_valid;           // A-ext reservation (physical)
    assign dbg_scause = scause;
    assign dbg_mcause = mcause;
    assign dbg_mip = mip;
    assign dbg_mie = mie;
    assign dbg_stval = stval;
    assign dbg_satp = satp;
    assign dbg_mepc = mepc;
    assign dbg_sepc = sepc;
    assign dbg_mtime = mtime[31:0];
    assign dbg_mtimecmp = mtimecmp[31:0];
    assign dbg_mmio_valid = 1'b0;
    assign dbg_mmio_we = 1'b0;
    assign dbg_mmio_funct3 = 3'd0;
    assign dbg_mmio_pa = 32'd0;
    assign dbg_mmio_wdata = 32'd0;
    assign dbg_mmio_rdata = 32'd0;

`ifdef RVTRACE
    integer rvtrace_fd;
    initial begin
        rvtrace_fd = $fopen("rvtrace.log", "w");
        $fwrite(rvtrace_fd, "event,cycle,pc,instr,priv,rd,wdata,next_pc,cause,tval\n");
    end
`endif

    // mstatus bit indices
    localparam SIE=1, MIE=3, SPIE=5, MPIE=7, SPP=8, MPRV=17, SUM_B=18, MXR_B=19;
    // mip/mie bit indices
    localparam SSI=1, MSI=3, STI=5, MTI=7, SEI=9, MEI=11;
    localparam [31:0] SSTATUS_MASK = 32'h800D_E722;
    localparam [31:0] S_INT_MASK   = 32'h0000_0222;   // SSIP|STIP|SEIP

    initial begin
        mstatus=0; mtvec=0; mscratch=0; mepc=0; mcause=0; mtval=0; mie=0; mip=0;
        medeleg=0; mideleg=0; menvcfg=0; menvcfgh=0; misa=32'h4014_1101; // MXL=1, A,I,M,S,U
        stvec=0; sscratch=0; sepc=0; scause=0; stval=0; satp=0;
        mtime=0; mtimecmp=64'hffff_ffff_ffff_ffff; mcycle=0; minstret=0;
        mtime_tick_count=0;
        lr_addr=0; lr_valid=0;
    end

    // -------------------- physical memory helpers --------------------
    function in_ram; input [31:0] a; in_ram = (a>=RAMBASE) && (a < RAMBASE + MEMWORDS*4); endfunction

    // combinational physical word read (RAM only; devices handled separately)
    function [31:0] pread; input [31:0] a; begin
        pread = in_ram(a) ? mem[(a & RAMMASK)>>2] : 32'h0;
    end endfunction

    // ===================================================================
    //  Sv32 page-table walk (combinational).  acc: 0=fetch(X) 1=load(R) 2=store/amo(W)
    //  Returns fault flag, cause, physical address, and leaf PTE info for A/D.
    // ===================================================================
    // ---- fetch translation ----
    wire        f_xen   = (satp[31]) && (priv != PRV_M);
    wire [31:0] f_va    = pc;
    wire [9:0]  f_vpn1  = f_va[31:22];
    wire [9:0]  f_vpn0  = f_va[21:12];
    wire [31:0] f_pte1_pa = {satp[19:0], 12'b0} + {f_vpn1, 2'b0};
    wire [31:0] f_pte1    = pread(f_pte1_pa);
    wire        f_pte1_v  = f_pte1[0];
    wire        f_pte1_leaf = f_pte1[3] | f_pte1[1];        // X or R
    wire [31:0] f_pte0_pa = {f_pte1[29:10], 12'b0} + {f_vpn0, 2'b0};
    wire [31:0] f_pte0    = pread(f_pte0_pa);
    wire [31:0] f_leaf    = f_pte1_leaf ? f_pte1 : f_pte0;
    wire [31:0] f_leaf_pa = f_pte1_leaf ? f_pte1_pa : f_pte0_pa;
    // physical address compose (4MB superpage if leaf at level1)
    wire [31:0] f_pa = !f_xen ? f_va :
                       f_pte1_leaf ? {f_pte1[29:20], f_va[21:0]} :
                                     {f_pte0[29:10], f_va[11:0]};
    // permission: need X; U-page in S/M fetch not allowed
    wire f_perm = f_leaf[3] &&
                  ( (priv==PRV_U) ? f_leaf[4] : !f_leaf[4] );
    wire f_walk_bad = !f_pte1_v || (f_pte1[1]==0 && f_pte1[2]==1) ||
                      (!f_pte1_leaf && (!f_pte0[0] || (f_pte0[1]==0 && f_pte0[2]==1) || !(f_pte0[3]|f_pte0[1])));
    wire f_fault = f_xen && ( !in_ram(f_pte1_pa) || f_walk_bad || !f_perm );

    // ---- second fetch half translation (only used when a 32b instr crosses a page) ----
    wire [31:0] f2_va = pc + 32'd2;
    wire [9:0]  f2_vpn1 = f2_va[31:22];
    wire [9:0]  f2_vpn0 = f2_va[21:12];
    wire [31:0] f2_pte1_pa = {satp[19:0], 12'b0} + {f2_vpn1, 2'b0};
    wire [31:0] f2_pte1    = pread(f2_pte1_pa);
    wire        f2_pte1_leaf = f2_pte1[3] | f2_pte1[1];
    wire [31:0] f2_pte0_pa = {f2_pte1[29:10], 12'b0} + {f2_vpn0, 2'b0};
    wire [31:0] f2_pte0    = pread(f2_pte0_pa);
    wire [31:0] f2_leaf    = f2_pte1_leaf ? f2_pte1 : f2_pte0;
    wire [31:0] f2_pa = !f_xen ? f2_va :
                        f2_pte1_leaf ? {f2_pte1[29:20], f2_va[21:0]} :
                                       {f2_pte0[29:10], f2_va[11:0]};
    wire f2_perm = f2_leaf[3] && ((priv==PRV_U) ? f2_leaf[4] : !f2_leaf[4]);
    wire f2_walk_bad = !f2_pte1[0] || (f2_pte1[1]==0 && f2_pte1[2]==1) ||
                       (!f2_pte1_leaf && (!f2_pte0[0] || (f2_pte0[1]==0 && f2_pte0[2]==1) || !(f2_pte0[3]|f2_pte0[1])));
    wire f2_fault = f_xen && ( !in_ram(f2_pte1_pa) || f2_walk_bad || !f2_perm );

    // ---- data translation (for load/store/amo) ----
    wire [1:0]  d_effpriv = mstatus[MPRV] ? mstatus[12:11] : priv;
    wire        d_xen   = (satp[31]) && (d_effpriv != PRV_M);
    reg  [1:0]  d_acc;                          // set in decode
    wire [31:0] d_va;                           // = mem address (set below)
    wire [9:0]  d_vpn1  = d_va[31:22];
    wire [9:0]  d_vpn0  = d_va[21:12];
    wire [31:0] d_pte1_pa = {satp[19:0], 12'b0} + {d_vpn1, 2'b0};
    wire [31:0] d_pte1    = pread(d_pte1_pa);
    wire        d_pte1_v  = d_pte1[0];
    wire        d_pte1_leaf = d_pte1[3] | d_pte1[1];
    wire [31:0] d_pte0_pa = {d_pte1[29:10], 12'b0} + {d_vpn0, 2'b0};
    wire [31:0] d_pte0    = pread(d_pte0_pa);
    wire [31:0] d_leaf    = d_pte1_leaf ? d_pte1 : d_pte0;
    wire [31:0] d_leaf_pa = d_pte1_leaf ? d_pte1_pa : d_pte0_pa;
    wire [31:0] d_pa = !d_xen ? d_va :
                       d_pte1_leaf ? {d_pte1[29:20], d_va[21:0]} :
                                     {d_pte0[29:10], d_va[11:0]};
    wire d_readable = d_leaf[1] | (mstatus[MXR_B] & d_leaf[3]);
    wire d_perm = ( (d_acc==2'd0) ? d_leaf[3] :
                    (d_acc==2'd1) ? d_readable :
                                    d_leaf[2] ) &&
                  ( (d_effpriv==PRV_U) ? d_leaf[4]
                                       : (!d_leaf[4] | mstatus[SUM_B]) );
    wire d_walk_bad = !d_pte1_v || (d_pte1[1]==0 && d_pte1[2]==1) ||
                      (!d_pte1_leaf && (!d_pte0[0] || (d_pte0[1]==0 && d_pte0[2]==1) || !(d_pte0[3]|d_pte0[1])));
    wire d_fault = d_xen && ( !in_ram(d_pte1_pa) || d_walk_bad || !d_perm );

    // -------------------- fetch (with RVC) --------------------
    wire [31:0] f_w0  = pread(f_pa);                 // word containing pc
    wire [15:0] lo16  = pc[1] ? f_w0[31:16] : f_w0[15:0];
    wire        is_rvc = (lo16[1:0] != 2'b11);
    wire        need_hi = !is_rvc;
    wire        fcross  = need_hi && pc[1] && (pc[11:2]==10'h3FF);  // upper half in next page
    wire [31:0] hi_word = pc[1] ? (fcross ? pread(f2_pa) : pread((f_pa & ~32'h3)+32'd4))
                                : f_w0;
    wire [15:0] hi16  = pc[1] ? hi_word[15:0] : f_w0[31:16];
    wire [31:0] raw32 = {hi16, lo16};
    wire        ifetch_fault = f_fault || (fcross && f2_fault);

    // ---- RVC decompressor: 16b compressed -> 32b equivalent ----
    wire [4:0] c_rdp  = {2'b01, lo16[4:2]};
    wire [4:0] c_rs2p = {2'b01, lo16[4:2]};
    wire [4:0] c_rs1p = {2'b01, lo16[9:7]};
    wire [4:0] c_rd   = lo16[11:7];
    wire [4:0] c_rs2  = lo16[6:2];
    wire [11:0] ciw_imm  = {2'b00, lo16[10:7], lo16[12:11], lo16[5], lo16[6], 2'b00};
    wire [11:0] clw_imm  = {5'b0, lo16[5], lo16[12:10], lo16[6], 2'b00};
    wire [11:0] ci_imm   = {{7{lo16[12]}}, lo16[6:2]};
    wire [11:0] c16sp    = {{3{lo16[12]}}, lo16[4:3], lo16[5], lo16[2], lo16[6], 4'b0000};
    wire [19:0] clui20   = {{15{lo16[12]}}, lo16[6:2]};
    wire [11:0] clwsp    = {4'b0, lo16[3:2], lo16[12], lo16[6:4], 2'b00};
    wire [11:0] cswsp    = {4'b0, lo16[8:7], lo16[12:9], 2'b00};
    wire [4:0] cshamt    = lo16[6:2];
    wire [11:0] cjo      = {lo16[12], lo16[8], lo16[10:9], lo16[6], lo16[7], lo16[2], lo16[11], lo16[5:3], 1'b0};
    wire [20:0] cj_imm   = {{9{cjo[11]}}, cjo};
    wire [8:0] cbo       = {lo16[12], lo16[6:5], lo16[2], lo16[11:10], lo16[4:3], 1'b0};
    wire [12:0] cb_imm   = {{4{cbo[8]}}, cbo};

    reg [31:0] cdec; reg cbad;
    always @(*) begin
        cdec = 32'h0000_0013;  cbad = 1'b0;   // default: NOP (addi x0,x0,0)
        case ({lo16[1:0], lo16[15:13]})
            // ---- Q0 ----
            5'b00_000: begin
                if (lo16[12:5]==8'b0) cbad=1'b1;                                // reserved
                else cdec = {ciw_imm, 5'd2, 3'b000, c_rdp, 7'b0010011};         // C.ADDI4SPN
            end
            5'b00_010: cdec = {clw_imm, c_rs1p, 3'b010, c_rdp, 7'b0000011};     // C.LW
            5'b00_110: cdec = {clw_imm[11:5], c_rs2p, c_rs1p, 3'b010, clw_imm[4:0], 7'b0100011}; // C.SW
            // ---- Q1 ----
            5'b01_000: cdec = {ci_imm, c_rd, 3'b000, c_rd, 7'b0010011};         // C.ADDI / C.NOP
            5'b01_001: cdec = {cj_imm[20], cj_imm[10:1], cj_imm[11], cj_imm[19:12], 5'd1, 7'b1101111}; // C.JAL
            5'b01_010: cdec = {ci_imm, 5'd0, 3'b000, c_rd, 7'b0010011};         // C.LI
            5'b01_011: cdec = (c_rd==5'd2) ? {c16sp, 5'd2, 3'b000, 5'd2, 7'b0010011} // C.ADDI16SP
                                           : {clui20, c_rd, 7'b0110111};        // C.LUI
            5'b01_100: begin
                case (lo16[11:10])
                    2'b00: cdec = {7'b0000000, cshamt, c_rs1p, 3'b101, c_rs1p, 7'b0010011}; // C.SRLI
                    2'b01: cdec = {7'b0100000, cshamt, c_rs1p, 3'b101, c_rs1p, 7'b0010011}; // C.SRAI
                    2'b10: cdec = {ci_imm, c_rs1p, 3'b111, c_rs1p, 7'b0010011};             // C.ANDI
                    default: begin // 11: SUB/XOR/OR/AND  (c[12]=1 => rv64 W ops: illegal)
                        if (lo16[12]) cbad=1'b1;
                        else case (lo16[6:5])
                            2'b00: cdec = {7'b0100000, c_rs2p, c_rs1p, 3'b000, c_rs1p, 7'b0110011}; // SUB
                            2'b01: cdec = {7'b0000000, c_rs2p, c_rs1p, 3'b100, c_rs1p, 7'b0110011}; // XOR
                            2'b10: cdec = {7'b0000000, c_rs2p, c_rs1p, 3'b110, c_rs1p, 7'b0110011}; // OR
                            default:cdec= {7'b0000000, c_rs2p, c_rs1p, 3'b111, c_rs1p, 7'b0110011}; // AND
                        endcase
                    end
                endcase
            end
            5'b01_101: cdec = {cj_imm[20], cj_imm[10:1], cj_imm[11], cj_imm[19:12], 5'd0, 7'b1101111}; // C.J
            5'b01_110: cdec = {cb_imm[12], cb_imm[10:5], 5'd0, c_rs1p, 3'b000, cb_imm[4:1], cb_imm[11], 7'b1100011}; // C.BEQZ
            5'b01_111: cdec = {cb_imm[12], cb_imm[10:5], 5'd0, c_rs1p, 3'b001, cb_imm[4:1], cb_imm[11], 7'b1100011}; // C.BNEZ
            // ---- Q2 ----
            5'b10_000: cdec = {7'b0000000, cshamt, c_rd, 3'b001, c_rd, 7'b0010011};         // C.SLLI
            5'b10_010: cdec = {clwsp, 5'd2, 3'b010, c_rd, 7'b0000011};                      // C.LWSP
            5'b10_100: begin
                if (!lo16[12]) begin
                    if (c_rs2==5'd0) cdec = {12'b0, c_rd, 3'b000, 5'd0, 7'b1100111};        // C.JR
                    else             cdec = {7'b0000000, c_rs2, 5'd0, 3'b000, c_rd, 7'b0110011}; // C.MV
                end else begin
                    if (c_rd==5'd0 && c_rs2==5'd0) cdec = 32'h0010_0073;                    // C.EBREAK
                    else if (c_rs2==5'd0) cdec = {12'b0, c_rd, 3'b000, 5'd1, 7'b1100111};   // C.JALR
                    else cdec = {7'b0000000, c_rs2, c_rd, 3'b000, c_rd, 7'b0110011};        // C.ADD
                end
            end
            5'b10_110: cdec = {cswsp[11:5], c_rs2, 5'd2, 3'b010, cswsp[4:0], 7'b0100011};   // C.SWSP
            default: cbad = 1'b1;   // unsupported (incl. compressed float)
        endcase
    end

    wire [31:0] instr = is_rvc ? cdec : raw32;
    wire        rvc_illegal = is_rvc && cbad;
    wire [31:0] ilen = is_rvc ? 32'd2 : 32'd4;
    // -------------------- decode --------------------
    wire [6:0]  opc = instr[6:0];
    wire [4:0]  rd  = instr[11:7], rs1=instr[19:15], rs2=instr[24:20];
    wire [2:0]  f3  = instr[14:12];
    wire [6:0]  f7  = instr[31:25];
    wire [4:0]  f5  = instr[31:27];
    wire [11:0] csr_addr = instr[31:20];
    wire [31:0] rv1 = regs[rs1];
    wire [31:0] rv2 = regs[rs2];
    wire [31:0] immI = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] immS = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] immB = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] immU = {instr[31:12], 12'b0};
    wire [31:0] immJ = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
    wire [4:0]  zimm = instr[19:15];

    localparam [6:0] LUI=7'h37,AUIPC=7'h17,JAL=7'h6f,JALR=7'h67,BR=7'h63,
                     LOAD=7'h03,STORE=7'h23,OPIMM=7'h13,OP=7'h33,SYSTEM=7'h73,
                     FENCE=7'h0f,AMO=7'h2f;

    // -------------------- ALU --------------------
    wire [31:0] ai = rv1;
    wire [31:0] bi = (opc==OPIMM) ? immI : rv2;
    wire [4:0]  sh = (opc==OPIMM) ? immI[4:0] : rv2[4:0];
    wire signed [31:0] ai_s = ai;
    wire [31:0] sra_res = ai_s >>> sh;          // standalone signed context (arithmetic)
    reg [31:0] aluout;
    always @(*) begin
        case (f3)
            3'b000: aluout = (opc==OP && f7[5]) ? (ai - bi) : (ai + bi);
            3'b001: aluout = ai << sh;
            3'b010: aluout = ($signed(ai) < $signed(bi)) ? 32'd1 : 32'd0;
            3'b011: aluout = (ai < bi) ? 32'd1 : 32'd0;
            3'b100: aluout = ai ^ bi;
            3'b101: aluout = f7[5] ? sra_res : (ai >> sh);
            3'b110: aluout = ai | bi;
            default:aluout = ai & bi;
        endcase
    end

    // -------------------- M extension (behavioral, sim) --------------------
    wire signed [31:0] sa = rv1, sb = rv2;
    wire [63:0] mul_ss = $signed({{32{rv1[31]}},rv1}) * $signed({{32{rv2[31]}},rv2});
    wire [63:0] mul_uu = {32'b0,rv1} * {32'b0,rv2};
    wire [63:0] mul_su = $signed({{32{rv1[31]}},rv1}) * $signed({1'b0,rv2});
    wire divz = (rv2==32'd0);
    wire dov  = (rv1==32'h8000_0000) && (rv2==32'hffff_ffff);
    wire signed [31:0] sdiv = sa / sb;
    wire signed [31:0] srem = sa % sb;
    reg [31:0] mout;
    always @(*) begin
        case (f3)
            3'b000: mout = mul_ss[31:0];
            3'b001: mout = mul_ss[63:32];
            3'b010: mout = mul_su[63:32];
            3'b011: mout = mul_uu[63:32];
            3'b100: mout = divz ? 32'hffff_ffff : dov ? 32'h8000_0000 : sdiv;
            3'b101: mout = divz ? 32'hffff_ffff : (rv1/rv2);
            3'b110: mout = divz ? rv1 : dov ? 32'h0 : srem;
            default:mout = divz ? rv1 : (rv1%rv2);
        endcase
    end
    wire is_muldiv = (opc==OP) && (f7==7'h01);

    // -------------------- branch --------------------
    reg branch_taken;
    always @(*) begin
        case (f3)
            3'b000: branch_taken = (rv1==rv2);
            3'b001: branch_taken = (rv1!=rv2);
            3'b100: branch_taken = ($signed(rv1) <  $signed(rv2));
            3'b101: branch_taken = ($signed(rv1) >= $signed(rv2));
            3'b110: branch_taken = (rv1 <  rv2);
            3'b111: branch_taken = (rv1 >= rv2);
            default:branch_taken = 1'b0;
        endcase
    end

    // -------------------- data address + access classification --------------
    wire is_load  = (opc==LOAD);
    wire is_store = (opc==STORE);
    wire is_amo   = (opc==AMO);
    wire is_lr    = is_amo && (f5==5'b00010);
    wire is_sc    = is_amo && (f5==5'b00011);
    wire amo_store = is_amo && !is_lr;          // SC/AMO* write memory (SC conditional)
    assign d_va = is_store ? (rv1 + immS) :
                  is_load  ? (rv1 + immI) :
                  is_amo   ? rv1 : 32'h0;
    always @(*) begin
        d_acc = 2'd1;
        if (is_store)            d_acc = 2'd2;
        else if (is_load||is_lr) d_acc = 2'd1;
        else if (is_amo)         d_acc = 2'd2;  // SC/AMO need write perm
    end
    wire mem_op = is_load || is_store || is_amo;
    // misaligned access detection (causes 4/6; not delegated -> M-mode emulates)
    wire acc_hw  = (is_load && (f3==3'b001 || f3==3'b101)) || (is_store && f3==3'b001);
    wire acc_w   = (is_load && f3==3'b010) || (is_store && f3==3'b010) || is_amo;
    wire size_mal= (acc_hw && d_va[0]) || (acc_w && (d_va[1:0]!=2'b00));
    wire exc_lmal= size_mal && (is_load || is_lr);
    wire exc_smal= size_mal && (is_store || (is_amo && !is_lr));

    // physical device routing on translated data address
    wire d_is_ram   = in_ram(d_pa);
    wire d_is_clint = (d_pa[31:16]==16'h0200);
    wire d_is_plic  = (d_pa[31:26]==6'b000011);             // 0x0C00_0000..0x0FFF_FFFF
    wire d_is_uart  = (d_pa[31:8]==24'h10_0000);            // 0x1000_00xx
    wire d_is_sys   = (d_pa[31:12]==20'h11100);             // 0x1110_0xxx

    // device + ram read word
    reg [31:0] clint_rd;
    always @(*) begin
        case (d_pa[15:0])
            16'h4000: clint_rd = mtimecmp[31:0];
            16'h4004: clint_rd = mtimecmp[63:32];
            16'hBFF8: clint_rd = mtime[31:0];
            16'hBFFC: clint_rd = mtime[63:32];
            16'h0000: clint_rd = {31'd0, mip[MSI]};
            default:  clint_rd = 32'd0;
        endcase
    end
    // 16550 UART (reg-shift 0, io-width 1)
    reg [7:0] uart_lcr, uart_ier, uart_mcr, uart_fcr, uart_scr, uart_dll, uart_dlm;
    reg [7:0] rx_data_r; reg rx_have;   // 1-byte RX holding register
    initial begin uart_lcr=0; uart_ier=0; uart_mcr=0; uart_fcr=0; uart_scr=0; uart_dll=0; uart_dlm=0; rx_data_r=0; rx_have=0; end
    // TX is instantaneous (THR always empty); RX byte ready in rx_have.
    wire uart_rx_int = rx_have & uart_ier[0];   // received-data-available (IER.RDI)
    wire uart_tx_int = uart_ier[1];             // THR-empty (IER.THRI), THRE always 1
    wire uart_irq    = uart_rx_int | uart_tx_int;
    wire [7:0] uart_iir = uart_rx_int ? 8'hC4 : uart_tx_int ? 8'hC2 : 8'hC1; // FIFO bits + cause
    wire [7:0] uart_lsr = 8'h60 | {7'd0, rx_have};                            // THRE|TEMT|DR
    reg [31:0] uart_rd;
    always @(*) begin
        case (d_pa[2:0])
            3'd0:    uart_rd = uart_lcr[7] ? {24'd0,uart_dll} : {24'd0,rx_data_r}; // DLL / RBR
            3'd1:    uart_rd = uart_lcr[7] ? {24'd0,uart_dlm} : {24'd0,uart_ier};
            3'd2:    uart_rd = {24'd0, uart_iir};
            3'd3:    uart_rd = {24'd0, uart_lcr};
            3'd4:    uart_rd = {24'd0, uart_mcr};
            3'd5:    uart_rd = {24'd0, uart_lsr};
            3'd6:    uart_rd = 32'hB0;            // MSR: DCD|DSR|CTS
            default: uart_rd = {24'd0, uart_scr}; // SCR scratch
        endcase
    end
    // ---- minimal SiFive-style PLIC: single source (1=UART), S-mode context 1 ----
    reg [2:0]  plic_prio1;     // priority of source 1
    reg        plic_senable1;  // source-1 enable bit in S-context
    reg [2:0]  plic_sthresh;   // S-context priority threshold
    reg        plic_claimed;   // source 1 claimed, awaiting completion
    initial begin plic_prio1=0; plic_senable1=0; plic_sthresh=0; plic_claimed=0; end
    wire plic_s_pending = uart_irq & plic_senable1 & (plic_prio1 > plic_sthresh) & ~plic_claimed;
    // effective mip: SEIP is OR of software bit and the PLIC external line
    wire [31:0] mip_eff = mip | (plic_s_pending ? (32'd1<<SEI) : 32'd0);
    reg [31:0] plic_rd;
    always @(*) begin
        case (d_pa[23:0])
            24'h000004: plic_rd = {29'd0, plic_prio1};       // priority[1]
            24'h001000: plic_rd = {30'd0, (uart_irq?1'b1:1'b0), 1'b0}; // pending word0 (src1 bit)
            24'h002080: plic_rd = {30'd0, plic_senable1, 1'b0};        // S enable word0
            24'h201000: plic_rd = {29'd0, plic_sthresh};     // S threshold
            24'h201004: plic_rd = plic_s_pending ? 32'd1 : 32'd0;     // S claim
            default:    plic_rd = 32'd0;
        endcase
    end
    wire [31:0] ramword = pread(d_pa);
    wire [31:0] memword = d_is_clint ? clint_rd :
                          d_is_uart  ? {4{uart_rd[7:0]}} : // byte-wide regs: put on every lane
                          d_is_plic  ? plic_rd  : ramword;
    // RX accepted when UART holding reg is free
    assign rx_ready = rx_valid & ~rx_have;
    wire uart_rbr_rd   = is_load && d_is_uart && (d_pa[2:0]==3'd0) && !uart_lcr[7];
    wire plic_claim_rd = is_load && d_is_plic && (d_pa[23:0]==24'h201004);

    // load formatting
    wire [1:0] boff = d_pa[1:0];
    wire [7:0]  lb = memword[boff*8 +: 8];
    wire [15:0] lh = memword[(boff[1]?16:0) +: 16];
    reg [31:0] loaddata;
    always @(*) begin
        case (f3)
            3'b000: loaddata = {{24{lb[7]}}, lb};
            3'b001: loaddata = {{16{lh[15]}}, lh};
            3'b100: loaddata = {24'd0, lb};
            3'b101: loaddata = {16'd0, lh};
            default:loaddata = memword;
        endcase
    end

    // AMO compute (word)
    wire [31:0] amo_a = memword;                 // old value (mem)
    wire [31:0] amo_b = rv2;
    reg [31:0] amo_res;
    always @(*) begin
        case (f5)
            5'b00001: amo_res = amo_b;                                   // SWAP
            5'b00000: amo_res = amo_a + amo_b;                           // ADD
            5'b00100: amo_res = amo_a ^ amo_b;                           // XOR
            5'b01100: amo_res = amo_a & amo_b;                           // AND
            5'b01000: amo_res = amo_a | amo_b;                           // OR
            5'b10000: amo_res = ($signed(amo_a) < $signed(amo_b)) ? amo_a : amo_b; // MIN
            5'b10100: amo_res = ($signed(amo_a) > $signed(amo_b)) ? amo_a : amo_b; // MAX
            5'b11000: amo_res = (amo_a < amo_b) ? amo_a : amo_b;         // MINU
            5'b11100: amo_res = (amo_a > amo_b) ? amo_a : amo_b;         // MAXU
            default:  amo_res = amo_b;
        endcase
    end
    // SC success: reservation valid and matches this physical word
    wire sc_ok = is_sc && lr_valid && (lr_addr == {d_pa[31:2],2'b00});
    wire do_mem_write = (is_store) || (is_amo && !is_lr && (!is_sc || sc_ok));

    // store/amo word (read-modify-write)
    reg [31:0] storeword;
    always @(*) begin
        storeword = ramword;
        if (is_store) begin
            case (f3)
                3'b000: storeword[boff*8 +: 8] = rv2[7:0];
                3'b001: if (boff[1]) storeword[31:16]=rv2[15:0]; else storeword[15:0]=rv2[15:0];
                default:storeword = rv2;
            endcase
        end else if (is_sc) begin
            storeword = rv2;                     // SC stores full word
        end else begin
            storeword = amo_res;                 // AMO*
        end
    end

    // -------------------- CSR read --------------------
    wire [31:0] sstatus_v = mstatus & SSTATUS_MASK;
    reg [31:0] csr_rdata; reg csr_exists;
    always @(*) begin
        csr_exists = 1'b1;
        case (csr_addr)
            12'h100: csr_rdata = sstatus_v;
            12'h104: csr_rdata = mie & mideleg;          // sie
            12'h105: csr_rdata = stvec;
            12'h106: csr_rdata = 32'd0;                  // scounteren
            12'h140: csr_rdata = sscratch;
            12'h141: csr_rdata = sepc;
            12'h142: csr_rdata = scause;
            12'h143: csr_rdata = stval;
            12'h144: csr_rdata = mip_eff & mideleg;      // sip
            12'h180: csr_rdata = satp;
            12'h300: csr_rdata = mstatus;
            12'h301: csr_rdata = misa;
            12'h302: csr_rdata = medeleg;
            12'h303: csr_rdata = mideleg;
            12'h304: csr_rdata = mie;
            12'h305: csr_rdata = mtvec;
            12'h306: csr_rdata = 32'd0;                  // mcounteren
            12'h30a: csr_rdata = menvcfg;
            12'h31a: csr_rdata = menvcfgh;
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = mepc;
            12'h342: csr_rdata = mcause;
            12'h343: csr_rdata = mtval;
            12'h344: csr_rdata = mip;
            12'hF11: csr_rdata = 32'd0;                  // mvendorid
            12'hF12: csr_rdata = 32'd0;                  // marchid
            12'hF13: csr_rdata = 32'd0;                  // mimpid
            12'hF14: csr_rdata = 32'd0;                  // mhartid
            12'hB00,12'hC00: csr_rdata = mcycle[31:0];
            12'hB80,12'hC80: csr_rdata = mcycle[63:32];
            12'hB02,12'hC02: csr_rdata = minstret[31:0];
            12'hB82,12'hC82: csr_rdata = minstret[63:32];
            12'hC01: csr_rdata = mtime[31:0];            // time
            12'hC81: csr_rdata = mtime[63:32];           // timeh
            default: begin csr_rdata = 32'd0; csr_exists = 1'b0; end
        endcase
    end
    wire [31:0] csr_src = f3[2] ? {27'd0, zimm} : rv1;
    reg [31:0] csr_wval;
    always @(*) begin
        case (f3[1:0])
            2'b01: csr_wval = csr_src;
            2'b10: csr_wval = csr_rdata | csr_src;
            2'b11: csr_wval = csr_rdata & ~csr_src;
            default: csr_wval = csr_rdata;
        endcase
    end
    wire csr_is   = (opc==SYSTEM) && (f3!=3'b000);
    wire csr_we   = csr_is && !((f3[1:0]!=2'b01) && rs1==5'd0); // RS/RC rs1=0 => read-only
    // CSR privilege check: bits [9:8] = lowest priv that can access
    wire csr_priv_ok = (priv >= csr_addr[9:8]);
    // satp access in S with TVM trap, plus reading counters with counteren - omit for boot

    // -------------------- SYSTEM decode --------------------
    wire is_ecall  = (opc==SYSTEM)&&(f3==0)&&(csr_addr==12'h000);
    wire is_ebreak = (opc==SYSTEM)&&(f3==0)&&(csr_addr==12'h001);
    wire is_mret   = (opc==SYSTEM)&&(f3==0)&&(csr_addr==12'h302);
    wire is_sret   = (opc==SYSTEM)&&(f3==0)&&(csr_addr==12'h102);
    wire is_wfi    = (opc==SYSTEM)&&(f3==0)&&(csr_addr==12'h105);
    wire is_sfence = (opc==SYSTEM)&&(f3==0)&&(f7==7'h09);

    // -------------------- legality --------------------
    reg legal;
    always @(*) begin
        case (opc)
            LUI,AUIPC,JAL,JALR,BR,LOAD,STORE,OPIMM,FENCE: legal=1'b1;
            OP:     legal = (f7==7'h00)||(f7==7'h20)||(f7==7'h01);
            AMO:    legal = (f3==3'b010);
            SYSTEM: legal = is_ecall||is_ebreak||is_mret||is_sret||is_wfi||is_sfence||
                            (csr_is && csr_exists && csr_priv_ok);
            default:legal = 1'b0;
        endcase
    end

    // -------------------- writeback select --------------------
    reg [31:0] wbval; reg wb_en;
    always @(*) begin
        wb_en=1'b0; wbval=32'd0;
        case (opc)
            LUI:   begin wb_en=1; wbval=immU; end
            AUIPC: begin wb_en=1; wbval=pc+immU; end
            JAL,JALR: begin wb_en=1; wbval=pc+ilen; end
            LOAD:  begin wb_en=1; wbval=loaddata; end
            OPIMM: begin wb_en=1; wbval=aluout; end
            OP:    begin wb_en=1; wbval= is_muldiv ? mout : aluout; end
            AMO:   begin wb_en=1; wbval= is_sc ? (sc_ok?32'd0:32'd1) : amo_a; end
            SYSTEM:if (csr_is) begin wb_en=1; wbval=csr_rdata; end
            default:;
        endcase
    end

    // -------------------- next PC --------------------
    wire [31:0] pc4 = pc + ilen;
    reg [31:0] pcnext;
    always @(*) begin
        case (opc)
            JAL:  pcnext = pc + immJ;
            JALR: pcnext = (rv1 + immI) & ~32'h1;
            BR:   pcnext = branch_taken ? (pc + immB) : pc4;
            default: pcnext = pc4;
        endcase
    end

    // -------------------- interrupt evaluation --------------------
    wire [31:0] ints = mip_eff & mie;
    wire [31:0] m_ints = ints & ~mideleg;
    wire [31:0] s_ints = ints &  mideleg;
    wire m_ie = (priv < PRV_M) || mstatus[MIE];
    wire s_ie = (priv < PRV_S) || (priv==PRV_S && mstatus[SIE]);
    wire take_m_int = (m_ints!=0) && m_ie;
    wire take_s_int = (s_ints!=0) && s_ie && !take_m_int;
    reg [3:0] int_code; reg int_to_s;
    always @(*) begin
        int_to_s=1'b0; int_code=4'd0;
        if (take_m_int) begin
            if (m_ints[MEI]) int_code=MEI; else if (m_ints[MSI]) int_code=MSI;
            else if (m_ints[MTI]) int_code=MTI; else if (m_ints[SEI]) int_code=SEI;
            else if (m_ints[SSI]) int_code=SSI; else int_code=STI;
        end else if (take_s_int) begin
            int_to_s=1'b1;
            if (s_ints[SEI]) int_code=SEI; else if (s_ints[SSI]) int_code=SSI; else int_code=STI;
        end
    end
    wire take_interrupt = take_m_int || take_s_int;

    // -------------------- exception evaluation --------------------
    wire exc_ifault    = ifetch_fault;                       // 12 instr page fault
    wire exc_illegal   = !exc_ifault && (!legal || rvc_illegal); // 2
    wire exc_ecall     = is_ecall;                           // 8/9/11
    wire exc_ebreak    = is_ebreak;                          // 3
    wire exc_malign    = mem_op && !exc_ifault && !exc_illegal && (exc_lmal || exc_smal); // 4/6
    wire exc_dfault    = mem_op && !exc_ifault && !exc_illegal && !exc_malign && d_fault; // 13/15
    wire any_exc = exc_ifault || exc_illegal || exc_ecall || exc_ebreak || exc_malign || exc_dfault;
    reg [3:0] exc_code; reg [31:0] exc_tval;
    always @(*) begin
        exc_code=4'd0; exc_tval=32'd0;
        if (exc_ifault)      begin exc_code=4'd12; exc_tval=f_va; end
        else if (exc_illegal)begin exc_code=4'd2;  exc_tval=instr; end
        else if (exc_malign) begin exc_code=exc_smal?4'd6:4'd4; exc_tval=d_va; end
        else if (exc_dfault) begin exc_code=(d_acc==2'd2)?4'd15:4'd13; exc_tval=d_va; end
        else if (exc_ebreak) begin exc_code=4'd3;  exc_tval=32'd0; end
        else if (exc_ecall)  begin exc_code=(priv==PRV_U)?4'd8:(priv==PRV_S)?4'd9:4'd11; exc_tval=32'd0; end
    end

    // -------------------- trap target + cause --------------------
    wire trap = take_interrupt || any_exc;
    wire deleg_to_s = take_interrupt ? int_to_s
                                     : (priv<=PRV_S && medeleg[exc_code]);
    wire [31:0] trap_cause = take_interrupt ? {1'b1, 27'd0, int_code}
                                            : {28'd0, exc_code};
    wire [31:0] trap_tval  = take_interrupt ? 32'd0 : exc_tval;
    // vectored mode for interrupts
    wire [31:0] s_base = {stvec[31:2],2'b00};
    wire [31:0] m_base = {mtvec[31:2],2'b00};
    wire [31:0] s_target = (stvec[0] && take_interrupt) ? (s_base + {int_code,2'b00}) : s_base;
    wire [31:0] m_target = (mtvec[0] && take_interrupt) ? (m_base + {int_code,2'b00}) : m_base;

    // -------------------- MMIO control --------------------
    wire do_store_commit = !trap && do_mem_write;
    wire store_uart = do_store_commit && d_is_uart && (d_pa[2:0]==3'd0) && !uart_lcr[7];
    wire store_sys  = do_store_commit && d_is_sys;

    // A/D update for leaf PTEs on successful access
    wire f_set_a = f_xen && !f_fault && (f_leaf[6]==1'b0);
    wire d_need  = mem_op && d_xen && !d_fault;
    wire d_set_a = d_need && (d_leaf[6]==1'b0);
    wire d_set_d = d_need && (d_acc==2'd2) && (d_leaf[7]==1'b0);
    wire mtime_tick_fire = (MTIME_TICK_CYCLES <= 32'd1) ||
                           (mtime_tick_count == (MTIME_TICK_CYCLES - 32'd1));
    wire [63:0] mtime_next_tick = mtime + (mtime_tick_fire ? 64'd1 : 64'd0);

    // -------------------- sequential --------------------
    always @(posedge clk) begin
        uart_we <= 1'b0; halt <= 1'b0;
        if (mtime_tick_fire) begin
            mtime <= mtime + 64'd1;
            mtime_tick_count <= 32'd0;
        end else begin
            mtime_tick_count <= mtime_tick_count + 32'd1;
        end
        mcycle <= mcycle + 64'd1;
        if (mtime_next_tick >= mtimecmp) mip[MTI] <= 1'b1; else mip[MTI] <= 1'b0;
        if (rx_ready) begin rx_have <= 1'b1; rx_data_r <= rx_byte_in; end

        if (rst) begin
            pc<=RAMBASE; priv<=PRV_M;
            mstatus<=0; mie<=0; mip<=0; mepc<=0; mcause<=0; mtval<=0; mtvec<=0;
            medeleg<=0; mideleg<=0; menvcfg<=0; menvcfgh<=0; satp<=0; lr_valid<=0;
            mtime<=0; mtimecmp<=64'hffff_ffff_ffff_ffff; mcycle<=0; minstret<=0;
            mtime_tick_count<=0;
            uart_lcr<=0; uart_ier<=0; uart_mcr<=0; rx_have<=0;
            plic_prio1<=0; plic_senable1<=0; plic_sthresh<=0; plic_claimed<=0;
        end else if (trap) begin
`ifdef RVTRACE
            $fwrite(rvtrace_fd, "TRAP,%0d,%08x,%08x,%0d,%0d,%08x,%08x,%08x,%08x\n",
                    mcycle, pc, instr, priv, 0, 32'd0, deleg_to_s ? s_target : m_target,
                    trap_cause, trap_tval);
`endif
            lr_valid<=1'b0;
            if (deleg_to_s) begin
                sepc<=pc; scause<=trap_cause; stval<=trap_tval;
                mstatus[SPIE]<=mstatus[SIE]; mstatus[SIE]<=1'b0;
                mstatus[SPP]<=(priv==PRV_U)?1'b0:1'b1;
                priv<=PRV_S; pc<=s_target;
            end else begin
                mepc<=pc; mcause<=trap_cause; mtval<=trap_tval;
                mstatus[MPIE]<=mstatus[MIE]; mstatus[MIE]<=1'b0;
                mstatus[12:11]<=priv;
                priv<=PRV_M; pc<=m_target;
            end
        end else if (is_mret) begin
`ifdef RVTRACE
            $fwrite(rvtrace_fd, "RET,%0d,%08x,%08x,%0d,%0d,%08x,%08x,%08x,%08x\n",
                    mcycle, pc, instr, priv, 0, 32'd0, mepc, 32'd0, 32'd0);
`endif
            priv<=mstatus[12:11];
            mstatus[MIE]<=mstatus[MPIE]; mstatus[MPIE]<=1'b1;
            mstatus[12:11]<=PRV_U;
            if (mstatus[12:11]!=PRV_M) mstatus[MPRV]<=1'b0;
            pc<=mepc; minstret<=minstret+64'd1;
        end else if (is_sret) begin
`ifdef RVTRACE
            $fwrite(rvtrace_fd, "RET,%0d,%08x,%08x,%0d,%0d,%08x,%08x,%08x,%08x\n",
                    mcycle, pc, instr, priv, 0, 32'd0, sepc, 32'd0, 32'd0);
`endif
            priv<= mstatus[SPP] ? PRV_S : PRV_U;
            mstatus[SIE]<=mstatus[SPIE]; mstatus[SPIE]<=1'b1;
            mstatus[SPP]<=1'b0;
            mstatus[MPRV]<=1'b0;
            pc<=sepc; minstret<=minstret+64'd1;
        end else begin
`ifdef RVTRACE
            $fwrite(rvtrace_fd, "RET,%0d,%08x,%08x,%0d,%0d,%08x,%08x,%08x,%08x\n",
                    mcycle, pc, instr, priv, (wb_en && rd!=5'd0) ? rd : 5'd0,
                    (wb_en && rd!=5'd0) ? wbval : 32'd0, pcnext, 32'd0, 32'd0);
`endif
            // ---- normal commit ----
            if (wb_en && rd!=5'd0) regs[rd]<=wbval;

            // reservation tracking
            if (is_lr) begin lr_valid<=1'b1; lr_addr<={d_pa[31:2],2'b00}; end
            else if (is_sc) lr_valid<=1'b0;
            else if (do_mem_write && d_is_ram) begin
                if (lr_valid && lr_addr=={d_pa[31:2],2'b00}) lr_valid<=1'b0;
            end

            // memory write
            if (do_mem_write && d_is_ram) mem[(d_pa & RAMMASK)>>2] <= storeword;
            if (do_store_commit && d_is_clint) begin
                case (d_pa[15:0])
                    16'h0000: mip[MSI]      <= storeword[0];
                    16'h4000: mtimecmp[31:0]<= storeword;
                    16'h4004: mtimecmp[63:32]<=storeword;
                    16'hBFF8: mtime[31:0]   <= storeword;
                    16'hBFFC: mtime[63:32]  <= storeword;
                    default: ;
                endcase
            end
            if (do_store_commit && d_is_uart) begin
                case (d_pa[2:0])
                    3'd0: if (uart_lcr[7]) uart_dll<=rv2[7:0]; else begin uart_we<=1'b1; uart_data<=rv2[7:0]; end
                    3'd1: if (uart_lcr[7]) uart_dlm<=rv2[7:0]; else uart_ier<=rv2[7:0];
                    3'd2: uart_fcr<=rv2[7:0];
                    3'd3: uart_lcr<=rv2[7:0];
                    3'd4: uart_mcr<=rv2[7:0];
                    3'd7: uart_scr<=rv2[7:0];
                    default: ;
                endcase
            end
            // PLIC register writes
            if (do_store_commit && d_is_plic) begin
                case (d_pa[23:0])
                    24'h000004: plic_prio1   <= storeword[2:0];
                    24'h002080: plic_senable1<= storeword[1];
                    24'h201000: plic_sthresh <= storeword[2:0];
                    24'h201004: plic_claimed <= 1'b0;          // complete
                    default: ;
                endcase
            end
            // UART RBR read consumes the pending RX byte
            if (uart_rbr_rd && rx_have) rx_have <= 1'b0;
            // PLIC claim read marks source in-service
            if (plic_claim_rd && plic_s_pending) plic_claimed <= 1'b1;
            if (store_sys) begin
                if (storeword==32'h5555) begin halt<=1'b1; exit_code<=32'd0; end
                else if (storeword==32'h7777) begin halt<=1'b1; exit_code<=32'd1; end
            end

            // HW A/D bit updates on leaf PTEs
            if (f_set_a) mem[(f_leaf_pa & RAMMASK)>>2] <= f_leaf | 32'h40;
            if (d_set_a || d_set_d)
                mem[(d_leaf_pa & RAMMASK)>>2] <= d_leaf | (d_set_a?32'h40:0) | (d_set_d?32'h80:0);

            // CSR writes
            if (csr_we) begin
                case (csr_addr)
                    12'h100: mstatus <= (mstatus & ~SSTATUS_MASK) | (csr_wval & SSTATUS_MASK);
                    12'h104: mie     <= (mie & ~mideleg) | (csr_wval & mideleg);
                    12'h105: stvec   <= csr_wval;
                    12'h140: sscratch<= csr_wval;
                    12'h141: sepc    <= csr_wval;
                    12'h142: scause  <= csr_wval;
                    12'h143: stval   <= csr_wval;
                    12'h144: mip[SSI]<= csr_wval[SSI];
                    12'h180: satp    <= csr_wval;
                    12'h300: mstatus <= csr_wval;
                    12'h302: medeleg <= csr_wval;
                    12'h303: mideleg <= csr_wval;
                    12'h304: mie     <= csr_wval;
                    12'h305: mtvec   <= csr_wval;
                    12'h30a: menvcfg <= 32'd0;
                    12'h31a: menvcfgh<= csr_wval & 32'h2000_0000; // ADUE hint; DUT already updates A/D in HW
                    12'h340: mscratch<= csr_wval;
                    12'h341: mepc    <= csr_wval;
                    12'h342: mcause  <= csr_wval;
                    12'h343: mtval   <= csr_wval;
                    12'h344: begin mip[SSI]<=csr_wval[SSI]; mip[STI]<=csr_wval[STI]; mip[SEI]<=csr_wval[SEI]; end
                    default: ;
                endcase
            end
            pc<=pcnext; minstret<=minstret+64'd1;
        end
    end
`endif
endmodule
