`timescale 1ns/1ps
// Privileged CSR/trap/return control stage for the future rvlinux stall FSM.
//
// The current booting rvlinux.v performs CSR reads/writes, exception delegation,
// trap entry, MRET/SRET, and counter updates inside one large single-cycle
// always block. This module factors that control plane into a synthesizable
// single-step stage so the multicycle core can retire normal instructions and
// route SYSTEM/trap events without depending on behavioral memory.
module rvlinux_csr_trap_stage(
    input  wire        clk,
    input  wire        rst,

    input  wire        step_valid,
    input  wire        fast_retire,
    input  wire [31:0] pc,
    input  wire [31:0] instr,
    input  wire [31:0] normal_next_pc,

    input  wire        system_valid,
    input  wire        is_csr,
    input  wire        is_ecall,
    input  wire        is_ebreak,
    input  wire        is_mret,
    input  wire        is_sret,
    input  wire        is_wfi,
    input  wire        is_sfence,
    input  wire [2:0]  f3,
    input  wire [4:0]  rs1,
    input  wire [4:0]  zimm,
    input  wire [11:0] csr_addr,
    input  wire [31:0] rs1_value,

    input  wire        exception_valid,
    input  wire [3:0]  exception_cause,
    input  wire [31:0] exception_tval,
    input  wire [31:0] irq_pending,
    input  wire [63:0] time_value,
    input  wire        check_interrupts,

    output wire        wfi_wake,
    output reg         done,
    output reg         trap_taken,
    output reg         return_taken,
    output reg         illegal,
    output reg         wb_en,
    output reg  [31:0] wb_value,
    output reg  [31:0] next_pc,
    output reg  [31:0] trap_cause,
    output reg  [31:0] trap_tval,

    output reg  [1:0]  priv,
    output wire [31:0] satp,
    output wire [31:0] mstatus_out,
    output wire [31:0] mie_out,
    output wire [31:0] mip_out,
    output wire [31:0] medeleg_out,
    output wire [31:0] mideleg_out,
    output wire [31:0] mepc_out,
    output wire [31:0] sepc_out,
    output wire [31:0] mcause_out,
    output wire [31:0] scause_out,
    output wire [31:0] mtval_out,
    output wire [31:0] stval_out,
    output wire [63:0] mcycle_out,
    output wire [63:0] minstret_out,
    output wire        sum,
    output wire        mxr,
    output wire        mprv,
    output wire [1:0]  data_priv
);
    localparam [1:0] PRV_U = 2'd0;
    localparam [1:0] PRV_S = 2'd1;
    localparam [1:0] PRV_M = 2'd3;

    localparam SIE  = 1;
    localparam MIE  = 3;
    localparam SPIE = 5;
    localparam MPIE = 7;
    localparam SPP  = 8;
    localparam MPRV = 17;
    localparam SUM_B = 18;
    localparam MXR_B = 19;

    localparam SSI = 1;
    localparam MSI = 3;
    localparam STI = 5;
    localparam MTI = 7;
    localparam SEI = 9;
    localparam MEI = 11;

    localparam [31:0] SSTATUS_MASK = 32'h800d_e722;
    localparam [31:0] MISA_VALUE   = 32'h4014_1105;

    reg [31:0] mstatus;
    reg [31:0] mtvec;
    reg [31:0] mscratch;
    reg [31:0] mepc;
    reg [31:0] mcause;
    reg [31:0] mtval;
    reg [31:0] mie;
    reg [31:0] mip;
    reg [31:0] medeleg;
    reg [31:0] mideleg;
    reg [31:0] menvcfg;
    reg [31:0] menvcfgh;
    reg [31:0] stvec;
    reg [31:0] sscratch;
    reg [31:0] sepc;
    reg [31:0] scause;
    reg [31:0] stval;
    reg [31:0] satp_r;
    reg [63:0] mcycle;
    reg [63:0] minstret;

    assign satp = satp_r;
    assign mstatus_out = mstatus;
    assign mie_out = mie;
    assign mip_out = mip | irq_pending;
    assign medeleg_out = medeleg;
    assign mideleg_out = mideleg;
    assign mepc_out = mepc;
    assign sepc_out = sepc;
    assign mcause_out = mcause;
    assign scause_out = scause;
    assign mtval_out = mtval;
    assign stval_out = stval;
    assign mcycle_out = mcycle;
    assign minstret_out = minstret;
    assign sum = mstatus[SUM_B];
    assign mxr = mstatus[MXR_B];
    assign mprv = mstatus[MPRV];
    assign data_priv = mstatus[MPRV] ? mstatus[12:11] : priv;

    wire [31:0] sstatus_v = mstatus & SSTATUS_MASK;
    wire [31:0] mip_eff = mip | irq_pending;
    wire [31:0] csr_src = f3[2] ? {27'd0, zimm} : rs1_value;
    wire csr_we = is_csr && !((f3[1:0] != 2'b01) && rs1 == 5'd0);
    wire csr_priv_ok = (priv >= csr_addr[9:8]);
    wire known_system = is_csr || is_ecall || is_ebreak || is_mret ||
                        is_sret || is_wfi || is_sfence;

    reg [31:0] csr_rdata;
    reg        csr_exists;
    reg [31:0] csr_wval;

    always @(*) begin
        csr_exists = 1'b1;
        case (csr_addr)
        12'h100: csr_rdata = sstatus_v;
        12'h104: csr_rdata = mie & mideleg;
        12'h105: csr_rdata = stvec;
        12'h106: csr_rdata = 32'd0;
        12'h140: csr_rdata = sscratch;
        12'h141: csr_rdata = sepc;
        12'h142: csr_rdata = scause;
        12'h143: csr_rdata = stval;
        12'h144: csr_rdata = mip_eff & mideleg;
        12'h180: csr_rdata = satp_r;
        12'h300: csr_rdata = mstatus;
        12'h301: csr_rdata = MISA_VALUE;
        12'h302: csr_rdata = medeleg;
        12'h303: csr_rdata = mideleg;
        12'h304: csr_rdata = mie;
        12'h305: csr_rdata = mtvec;
        12'h306: csr_rdata = 32'd0;
        12'h30a: csr_rdata = menvcfg;
        12'h31a: csr_rdata = menvcfgh;
        12'h340: csr_rdata = mscratch;
        12'h341: csr_rdata = mepc;
        12'h342: csr_rdata = mcause;
        12'h343: csr_rdata = mtval;
        12'h344: csr_rdata = mip;
        12'hf11: csr_rdata = 32'd0;
        12'hf12: csr_rdata = 32'd0;
        12'hf13: csr_rdata = 32'd0;
        12'hf14: csr_rdata = 32'd0;
        12'hb00, 12'hc00: csr_rdata = mcycle[31:0];
        12'hb80, 12'hc80: csr_rdata = mcycle[63:32];
        12'hb02, 12'hc02: csr_rdata = minstret[31:0];
        12'hb82, 12'hc82: csr_rdata = minstret[63:32];
        12'hc01: csr_rdata = time_value[31:0];
        12'hc81: csr_rdata = time_value[63:32];
        default: begin
            csr_rdata = 32'd0;
            csr_exists = 1'b0;
        end
        endcase
    end

    always @(*) begin
        case (f3[1:0])
        2'b01: csr_wval = csr_src;
        2'b10: csr_wval = csr_rdata | csr_src;
        2'b11: csr_wval = csr_rdata & ~csr_src;
        default: csr_wval = csr_rdata;
        endcase
    end

    wire csr_illegal = is_csr && (!csr_exists || !csr_priv_ok || f3[1:0] == 2'b00);
    wire system_illegal = system_valid && (!known_system || csr_illegal);

    wire [31:0] ints = mip_eff & mie;
    wire [31:0] trap_ints = check_interrupts ? ints : 32'd0;
    wire [31:0] m_ints = trap_ints & ~mideleg;
    wire [31:0] s_ints = trap_ints &  mideleg;
    wire m_ie = (priv < PRV_M) || mstatus[MIE];
    wire s_ie = (priv < PRV_S) || (priv == PRV_S && mstatus[SIE]);
    wire take_m_int = (m_ints != 32'd0) && m_ie;
    wire take_s_int = (s_ints != 32'd0) && s_ie && !take_m_int;
    wire take_interrupt = take_m_int || take_s_int;
    assign wfi_wake = (ints != 32'd0);

    reg [3:0] int_code;
    reg       int_to_s;
    always @(*) begin
        int_code = 4'd0;
        int_to_s = 1'b0;
        if (take_m_int) begin
            if (m_ints[MEI])
                int_code = MEI[3:0];
            else if (m_ints[MSI])
                int_code = MSI[3:0];
            else if (m_ints[MTI])
                int_code = MTI[3:0];
            else if (m_ints[SEI])
                int_code = SEI[3:0];
            else if (m_ints[SSI])
                int_code = SSI[3:0];
            else
                int_code = STI[3:0];
        end else if (take_s_int) begin
            int_to_s = 1'b1;
            if (s_ints[SEI])
                int_code = SEI[3:0];
            else if (s_ints[SSI])
                int_code = SSI[3:0];
            else
                int_code = STI[3:0];
        end
    end

    reg        exc_valid;
    reg [3:0]  exc_code;
    reg [31:0] exc_tval;
    always @(*) begin
        exc_valid = exception_valid || system_illegal ||
                    is_ecall || is_ebreak;
        exc_code = exception_cause;
        exc_tval = exception_tval;
        if (system_illegal) begin
            exc_code = 4'd2;
            exc_tval = instr;
        end else if (is_ebreak) begin
            exc_code = 4'd3;
            exc_tval = 32'd0;
        end else if (is_ecall) begin
            exc_code = (priv == PRV_U) ? 4'd8 :
                       (priv == PRV_S) ? 4'd9 : 4'd11;
            exc_tval = 32'd0;
        end
    end

    wire trap_now = take_interrupt || exc_valid;
    wire deleg_to_s = take_interrupt ? int_to_s :
                      ((priv <= PRV_S) && medeleg[exc_code]);
    wire [31:0] next_trap_cause = take_interrupt ?
                                  {1'b1, 27'd0, int_code} :
                                  {28'd0, exc_code};
    wire [31:0] next_trap_tval = take_interrupt ? 32'd0 : exc_tval;
    wire [31:0] s_base = {stvec[31:2], 2'b00};
    wire [31:0] m_base = {mtvec[31:2], 2'b00};
    wire [31:0] s_target = (stvec[0] && take_interrupt) ?
                           (s_base + {int_code, 2'b00}) : s_base;
    wire [31:0] m_target = (mtvec[0] && take_interrupt) ?
                           (m_base + {int_code, 2'b00}) : m_base;

    always @(posedge clk) begin
        done <= 1'b0;
        trap_taken <= 1'b0;
        return_taken <= 1'b0;
        illegal <= 1'b0;
        wb_en <= 1'b0;
        wb_value <= 32'd0;
        trap_cause <= 32'd0;
        trap_tval <= 32'd0;
        next_pc <= normal_next_pc;
        mcycle <= mcycle + 64'd1;

        if (rst) begin
            priv <= PRV_M;
            mstatus <= 32'd0;
            mtvec <= 32'd0;
            mscratch <= 32'd0;
            mepc <= 32'd0;
            mcause <= 32'd0;
            mtval <= 32'd0;
            mie <= 32'd0;
            mip <= 32'd0;
            medeleg <= 32'd0;
            mideleg <= 32'd0;
            menvcfg <= 32'd0;
            menvcfgh <= 32'd0;
            stvec <= 32'd0;
            sscratch <= 32'd0;
            sepc <= 32'd0;
            scause <= 32'd0;
            stval <= 32'd0;
            satp_r <= 32'd0;
            mcycle <= 64'd0;
            minstret <= 64'd0;
        end else if (step_valid) begin
            done <= 1'b1;
            illegal <= system_illegal;

            if (trap_now) begin
                trap_taken <= 1'b1;
                trap_cause <= next_trap_cause;
                trap_tval <= next_trap_tval;
                if (deleg_to_s) begin
                    sepc <= pc;
                    scause <= next_trap_cause;
                    stval <= next_trap_tval;
                    mstatus[SPIE] <= mstatus[SIE];
                    mstatus[SIE] <= 1'b0;
                    mstatus[SPP] <= (priv == PRV_U) ? 1'b0 : 1'b1;
                    priv <= PRV_S;
                    next_pc <= s_target;
                end else begin
                    mepc <= pc;
                    mcause <= next_trap_cause;
                    mtval <= next_trap_tval;
                    mstatus[MPIE] <= mstatus[MIE];
                    mstatus[MIE] <= 1'b0;
                    mstatus[12:11] <= priv;
                    priv <= PRV_M;
                    next_pc <= m_target;
                end
            end else if (is_mret) begin
                return_taken <= 1'b1;
                priv <= mstatus[12:11];
                mstatus[MIE] <= mstatus[MPIE];
                mstatus[MPIE] <= 1'b1;
                mstatus[12:11] <= PRV_U;
                if (mstatus[12:11] != PRV_M)
                    mstatus[MPRV] <= 1'b0;
                next_pc <= mepc;
                minstret <= minstret + 64'd1;
            end else if (is_sret) begin
                return_taken <= 1'b1;
                priv <= mstatus[SPP] ? PRV_S : PRV_U;
                mstatus[SIE] <= mstatus[SPIE];
                mstatus[SPIE] <= 1'b1;
                mstatus[SPP] <= 1'b0;
                mstatus[MPRV] <= 1'b0;
                next_pc <= sepc;
                minstret <= minstret + 64'd1;
            end else begin
                if (is_csr) begin
                    wb_en <= 1'b1;
                    wb_value <= csr_rdata;
                    if (csr_we) begin
                        case (csr_addr)
                        12'h100: mstatus <= (mstatus & ~SSTATUS_MASK) |
                                            (csr_wval & SSTATUS_MASK);
                        12'h104: mie <= (mie & ~mideleg) |
                                        (csr_wval & mideleg);
                        12'h105: stvec <= csr_wval;
                        12'h140: sscratch <= csr_wval;
                        12'h141: sepc <= csr_wval & 32'hffff_fffe;
                        12'h142: scause <= csr_wval;
                        12'h143: stval <= csr_wval;
                        12'h144: mip[SSI] <= csr_wval[SSI];
                        12'h180: satp_r <= csr_wval;
                        12'h300: mstatus <= csr_wval;
                        12'h302: medeleg <= csr_wval;
                        12'h303: mideleg <= csr_wval;
                        12'h304: mie <= csr_wval;
                        12'h305: mtvec <= csr_wval;
                        12'h30a: menvcfg <= 32'd0;
                        12'h31a: menvcfgh <= csr_wval & 32'h2000_0000;
                        12'h340: mscratch <= csr_wval;
                        12'h341: mepc <= csr_wval & 32'hffff_fffe;
                        12'h342: mcause <= csr_wval;
                        12'h343: mtval <= csr_wval;
                        12'h344: begin
                            mip[SSI] <= csr_wval[SSI];
                            mip[STI] <= csr_wval[STI];
                            mip[SEI] <= csr_wval[SEI];
                        end
                        default: ;
                        endcase
                    end
                end
                next_pc <= normal_next_pc;
                minstret <= minstret + 64'd1;
            end
        end else if (fast_retire) begin
            minstret <= minstret + 64'd1;
        end
    end
endmodule
