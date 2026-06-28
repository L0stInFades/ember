`timescale 1ns/1ps
// ===========================================================================
// rvmc: multi-cycle, *synthesizable* RV32IMA + Zicsr + M/S/U privilege.
//   The synthesizable successor to single-cycle rvlinux.v. Instead of unlimited
//   combinational reads into a behavioral RAM, it serializes fetch and
//   load/store across cycles over a simple req/ready memory port (the L1 cache).
//   MMIO (CLINT / 16550 UART TX / syscon) is handled directly (uncached).
//   NOTE: this increment uses *physical* addressing (no Sv32 MMU yet) and no
//   compressed (RVC) decode - the directed tests are built -march=rv32ima.
//   The sequential Sv32 PTW and RVC decode are layered on next (see goal.md P0).
//
//   Memory port protocol (matches rtl/cache/cache.v CPU side):
//     assert mem_req (+ addr/we/wdata/be), hold until a 1-cycle mem_ready pulse,
//     then drop mem_req for >=1 cycle before the next access. The FSM inserts an
//     explicit gap state after every cache access to honor this.
// ===========================================================================
module rvmc #(
    parameter [31:0] RAMBASE = 32'h8000_0000
)(
    input  wire        clk, rst,
    // cached memory port (-> L1 cache CPU side)
    output reg         mem_req,
    output reg         mem_we,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_be,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,
    // uart tx + halt
    output reg         uart_we,
    output reg  [7:0]  uart_data,
    output reg         halt,
    output reg  [31:0] exit_code,
    // debug
    output wire [31:0] dbg_pc,
    output wire [1:0]  dbg_priv,
    output wire [31:0] dbg_instret
);
    integer i;
    localparam PRV_U=2'd0, PRV_S=2'd1, PRV_M=2'd3;

    // -------------------- architectural state --------------------
    reg [31:0] pc;
    reg [31:0] regs [0:31];
    reg [1:0]  priv;
    initial begin pc=RAMBASE; priv=PRV_M; for(i=0;i<32;i=i+1) regs[i]=0; end
    assign dbg_pc = pc;
    assign dbg_priv = priv;

    // CSRs
    reg [31:0] mstatus, mtvec, mscratch, mepc, mcause, mtval, mie, mip;
    reg [31:0] medeleg, mideleg, misa;
    reg [31:0] stvec, sscratch, sepc, scause, stval, satp;
    reg [63:0] mtime, mtimecmp, mcycle, minstret;
    reg [31:0] lr_addr; reg lr_valid;
    assign dbg_instret = minstret[31:0];

    localparam SIE=1, MIE=3, SPIE=5, MPIE=7, SPP=8, MPRV=17, SUM_B=18, MXR_B=19;
    localparam SSI=1, MSI=3, STI=5, MTI=7, SEI=9, MEI=11;
    localparam [31:0] SSTATUS_MASK = 32'h800D_E722;

    initial begin
        mstatus=0; mtvec=0; mscratch=0; mepc=0; mcause=0; mtval=0; mie=0; mip=0;
        medeleg=0; mideleg=0; misa=32'h4014_1101;
        stvec=0; sscratch=0; sepc=0; scause=0; stval=0; satp=0;
        mtime=0; mtimecmp=64'hffff_ffff_ffff_ffff; mcycle=0; minstret=0;
        lr_addr=0; lr_valid=0;
    end

    // -------------------- FSM --------------------
    localparam S_FETCH=3'd0, S_EXEC=3'd1, S_LOAD=3'd2, S_AMOGAP=3'd3,
               S_STORE=3'd4, S_GAP=3'd5;
    reg [2:0]  state;
    reg [31:0] instr_r;          // latched instruction
    reg [31:0] amo_wdata_r;      // latched AMO result to store
    initial begin state=S_FETCH; instr_r=32'h13; amo_wdata_r=0; end

    // -------------------- decode (from latched instr) --------------------
    wire [31:0] instr = instr_r;
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
    wire [31:0] ilen = 32'd4;

    localparam [6:0] LUI=7'h37,AUIPC=7'h17,JAL=7'h6f,JALR=7'h67,BR=7'h63,
                     LOAD=7'h03,STORE=7'h23,OPIMM=7'h13,OP=7'h33,SYSTEM=7'h73,
                     FENCE=7'h0f,AMO=7'h2f;

    // -------------------- ALU --------------------
    wire [31:0] ai = rv1;
    wire [31:0] bi = (opc==OPIMM) ? immI : rv2;
    wire [4:0]  sh = (opc==OPIMM) ? immI[4:0] : rv2[4:0];
    wire signed [31:0] ai_s = ai;
    wire [31:0] sra_res = ai_s >>> sh;
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

    // -------------------- M extension --------------------
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

    // -------------------- data address + classification (physical) ----------
    wire is_load  = (opc==LOAD);
    wire is_store = (opc==STORE);
    wire is_amo   = (opc==AMO);
    wire is_lr    = is_amo && (f5==5'b00010);
    wire is_sc    = is_amo && (f5==5'b00011);
    wire [31:0] d_va = is_store ? (rv1 + immS) :
                       is_load  ? (rv1 + immI) :
                       is_amo   ? rv1 : 32'h0;
    wire [31:0] d_pa = d_va;                          // no MMU yet
    wire mem_op = is_load || is_store || is_amo;
    // misaligned detection
    wire acc_hw  = (is_load && (f3==3'b001 || f3==3'b101)) || (is_store && f3==3'b001);
    wire acc_w   = (is_load && f3==3'b010) || (is_store && f3==3'b010) || is_amo;
    wire size_mal= (acc_hw && d_va[0]) || (acc_w && (d_va[1:0]!=2'b00));
    wire exc_lmal= size_mal && (is_load || is_lr);
    wire exc_smal= size_mal && (is_store || (is_amo && !is_lr));

    function in_ram; input [31:0] a; in_ram = (a>=RAMBASE) && (a < RAMBASE + (1<<28)); endfunction
    wire d_is_ram   = in_ram(d_pa);
    wire d_is_clint = (d_pa[31:16]==16'h0200);
    wire d_is_uart  = (d_pa[31:8]==24'h10_0000);
    wire d_is_sys   = (d_pa[31:12]==20'h11100);
    wire d_is_mmio  = d_is_clint || d_is_uart || d_is_sys;

    // -------------------- MMIO read --------------------
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
    reg [7:0] uart_lcr, uart_ier, uart_mcr, uart_fcr, uart_scr, uart_dll, uart_dlm;
    initial begin uart_lcr=0; uart_ier=0; uart_mcr=0; uart_fcr=0; uart_scr=0; uart_dll=0; uart_dlm=0; end
    wire [7:0] uart_lsr = 8'h60;                       // THRE|TEMT, no RX
    reg [31:0] uart_rd;
    always @(*) begin
        case (d_pa[2:0])
            3'd0:    uart_rd = uart_lcr[7] ? {24'd0,uart_dll} : 32'd0;   // DLL / RBR(no rx)
            3'd1:    uart_rd = uart_lcr[7] ? {24'd0,uart_dlm} : {24'd0,uart_ier};
            3'd2:    uart_rd = 8'hC1;                                     // IIR: no int
            3'd3:    uart_rd = {24'd0, uart_lcr};
            3'd4:    uart_rd = {24'd0, uart_mcr};
            3'd5:    uart_rd = {24'd0, uart_lsr};
            3'd6:    uart_rd = 32'hB0;
            default: uart_rd = {24'd0, uart_scr};
        endcase
    end
    // word the current data access sees (RAM via cache result, or MMIO)
    wire [31:0] memword = (state==S_LOAD) ? mem_rdata :
                          d_is_clint ? clint_rd :
                          d_is_uart  ? {4{uart_rd[7:0]}} : 32'd0;

    // -------------------- load formatting --------------------
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

    // -------------------- AMO compute --------------------
    wire [31:0] amo_a = memword;
    wire [31:0] amo_b = rv2;
    reg [31:0] amo_res;
    always @(*) begin
        case (f5)
            5'b00001: amo_res = amo_b;
            5'b00000: amo_res = amo_a + amo_b;
            5'b00100: amo_res = amo_a ^ amo_b;
            5'b01100: amo_res = amo_a & amo_b;
            5'b01000: amo_res = amo_a | amo_b;
            5'b10000: amo_res = ($signed(amo_a) < $signed(amo_b)) ? amo_a : amo_b;
            5'b10100: amo_res = ($signed(amo_a) > $signed(amo_b)) ? amo_a : amo_b;
            5'b11000: amo_res = (amo_a < amo_b) ? amo_a : amo_b;
            5'b11100: amo_res = (amo_a > amo_b) ? amo_a : amo_b;
            default:  amo_res = amo_b;
        endcase
    end
    wire sc_ok = is_sc && lr_valid && (lr_addr == {d_pa[31:2],2'b00});

    // -------------------- store data + byte enables (cache merges via be) ----
    reg [31:0] st_wdata; reg [3:0] st_be;
    always @(*) begin
        st_wdata = rv2; st_be = 4'hf;
        case (f3)
            3'b000: begin st_wdata = {4{rv2[7:0]}};  st_be = (4'b0001 << d_pa[1:0]); end
            3'b001: begin st_wdata = {2{rv2[15:0]}}; st_be = d_pa[1] ? 4'b1100 : 4'b0011; end
            default:begin st_wdata = rv2;            st_be = 4'hf; end
        endcase
    end

    // -------------------- CSR read --------------------
    wire [31:0] sstatus_v = mstatus & SSTATUS_MASK;
    reg [31:0] csr_rdata; reg csr_exists;
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
            12'h144: csr_rdata = mip & mideleg;
            12'h180: csr_rdata = satp;
            12'h300: csr_rdata = mstatus;
            12'h301: csr_rdata = misa;
            12'h302: csr_rdata = medeleg;
            12'h303: csr_rdata = mideleg;
            12'h304: csr_rdata = mie;
            12'h305: csr_rdata = mtvec;
            12'h306: csr_rdata = 32'd0;
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = mepc;
            12'h342: csr_rdata = mcause;
            12'h343: csr_rdata = mtval;
            12'h344: csr_rdata = mip;
            12'hF11,12'hF12,12'hF13,12'hF14: csr_rdata = 32'd0;
            12'hB00,12'hC00: csr_rdata = mcycle[31:0];
            12'hB80,12'hC80: csr_rdata = mcycle[63:32];
            12'hB02,12'hC02: csr_rdata = minstret[31:0];
            12'hB82,12'hC82: csr_rdata = minstret[63:32];
            12'hC01: csr_rdata = mtime[31:0];
            12'hC81: csr_rdata = mtime[63:32];
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
    wire csr_we_i = csr_is && !((f3[1:0]!=2'b01) && rs1==5'd0);
    wire csr_priv_ok = (priv >= csr_addr[9:8]);

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

    // -------------------- writeback select + next pc --------------------
    reg [31:0] wbval; reg wb_en;
    always @(*) begin
        wb_en=1'b0; wbval=32'd0;
        case (opc)
            LUI:   begin wb_en=1; wbval=immU; end
            AUIPC: begin wb_en=1; wbval=pc+immU; end
            JAL,JALR: begin wb_en=1; wbval=pc+ilen; end
            OPIMM: begin wb_en=1; wbval=aluout; end
            OP:    begin wb_en=1; wbval= is_muldiv ? mout : aluout; end
            SYSTEM:if (csr_is) begin wb_en=1; wbval=csr_rdata; end
            default:;
        endcase
    end
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

    // -------------------- interrupt / exception evaluation --------------------
    wire [31:0] ints = mip & mie;
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

    wire exc_illegal = (!legal);
    wire exc_ecall   = is_ecall;
    wire exc_ebreak  = is_ebreak;
    wire exc_malign  = mem_op && !exc_illegal && (exc_lmal || exc_smal);
    wire any_exc = exc_illegal || exc_ecall || exc_ebreak || exc_malign;
    reg [3:0] exc_code; reg [31:0] exc_tval;
    always @(*) begin
        exc_code=4'd0; exc_tval=32'd0;
        if (exc_illegal)     begin exc_code=4'd2;  exc_tval=instr; end
        else if (exc_malign) begin exc_code=exc_smal?4'd6:4'd4; exc_tval=d_va; end
        else if (exc_ebreak) begin exc_code=4'd3;  exc_tval=32'd0; end
        else if (exc_ecall)  begin exc_code=(priv==PRV_U)?4'd8:(priv==PRV_S)?4'd9:4'd11; exc_tval=32'd0; end
    end

    wire trap = take_interrupt || any_exc;
    wire deleg_to_s = take_interrupt ? int_to_s : (priv<=PRV_S && medeleg[exc_code]);
    wire [31:0] trap_cause = take_interrupt ? {1'b1, 27'd0, int_code} : {28'd0, exc_code};
    wire [31:0] trap_tval  = take_interrupt ? 32'd0 : exc_tval;
    wire [31:0] s_base = {stvec[31:2],2'b00};
    wire [31:0] m_base = {mtvec[31:2],2'b00};
    wire [31:0] s_target = (stvec[0] && take_interrupt) ? (s_base + {int_code,2'b00}) : s_base;
    wire [31:0] m_target = (mtvec[0] && take_interrupt) ? (m_base + {int_code,2'b00}) : m_base;

    // which RAM accesses go through the cache
    wire ram_load = (is_load || is_lr) && d_is_ram;
    wire ram_amo  = is_amo && !is_lr && !is_sc && d_is_ram;
    wire ram_store= is_store && d_is_ram;

    // -------------------- combinational memory control --------------------
    always @(*) begin
        mem_req=1'b0; mem_we=1'b0; mem_addr=32'h0; mem_wdata=32'h0; mem_be=4'hf;
        case (state)
            S_FETCH: begin mem_req=1'b1; mem_addr={pc[31:2],2'b00}; end
            S_LOAD:  begin mem_req=1'b1; mem_addr={d_pa[31:2],2'b00}; end
            S_STORE: begin
                mem_req=1'b1; mem_we=1'b1; mem_addr={d_pa[31:2],2'b00};
                mem_wdata = (is_amo && !is_sc) ? amo_wdata_r : is_sc ? rv2 : st_wdata;
                mem_be    = (is_amo || is_sc) ? 4'hf : st_be;
            end
            default: ;
        endcase
    end

    // helper task-like inline: apply a CSR write (used at commit)
    // (kept inline in the sequential block below)

    // -------------------- sequential --------------------
    always @(posedge clk) begin
        uart_we <= 1'b0; halt <= 1'b0;
        mtime  <= mtime + 64'd1;
        mcycle <= mcycle + 64'd1;
        if ((mtime+64'd1) >= mtimecmp) mip[MTI] <= 1'b1; else mip[MTI] <= 1'b0;

        if (rst) begin
            state<=S_FETCH; pc<=RAMBASE; priv<=PRV_M;
            mstatus<=0; mie<=0; mip<=0; mepc<=0; mcause<=0; mtval<=0; mtvec<=0;
            medeleg<=0; mideleg<=0; satp<=0; lr_valid<=0;
            mtime<=0; mtimecmp<=64'hffff_ffff_ffff_ffff; mcycle<=0; minstret<=0;
            uart_lcr<=0; uart_ier<=0; uart_mcr<=0;
        end else case (state)

        // ---- fetch instruction word through the cache ----
        S_FETCH: if (mem_ready) begin instr_r <= mem_rdata; state <= S_EXEC; end

        // ---- decode/execute the latched instruction ----
        S_EXEC: begin
            if (trap) begin
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
                state<=S_FETCH;
            end else if (is_mret) begin
                priv<=mstatus[12:11];
                mstatus[MIE]<=mstatus[MPIE]; mstatus[MPIE]<=1'b1; mstatus[12:11]<=PRV_U;
                if (mstatus[12:11]!=PRV_M) mstatus[MPRV]<=1'b0;
                pc<=mepc; minstret<=minstret+64'd1; state<=S_FETCH;
            end else if (is_sret) begin
                priv<= mstatus[SPP] ? PRV_S : PRV_U;
                mstatus[SIE]<=mstatus[SPIE]; mstatus[SPIE]<=1'b1; mstatus[SPP]<=1'b0;
                mstatus[MPRV]<=1'b0;
                pc<=sepc; minstret<=minstret+64'd1; state<=S_FETCH;
            end else if (ram_load || ram_amo) begin
                state <= S_LOAD;                      // need a memory read first
            end else if (ram_store) begin
                state <= S_STORE;
            end else if (is_sc && d_is_ram) begin
                if (sc_ok) state <= S_STORE;          // conditional store
                else begin
                    if (rd!=5'd0) regs[rd]<=32'd1;     // SC failed
                    lr_valid<=1'b0;
                    pc<=pcnext; minstret<=minstret+64'd1; state<=S_FETCH;
                end
            end else begin
                // non-memory (or MMIO) instruction: commit now
                if (wb_en && rd!=5'd0) regs[rd]<=wbval;
                if (is_load && d_is_mmio && rd!=5'd0) regs[rd]<=loaddata;   // MMIO load
                // MMIO writes
                if (is_store && d_is_uart) begin
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
                if (is_store && d_is_clint) begin
                    case (d_pa[15:0])
                        16'h0000: mip[MSI]      <= rv2[0];
                        16'h4000: mtimecmp[31:0]<= rv2;
                        16'h4004: mtimecmp[63:32]<=rv2;
                        16'hBFF8: mtime[31:0]   <= rv2;
                        16'hBFFC: mtime[63:32]  <= rv2;
                        default: ;
                    endcase
                end
                if (is_store && d_is_sys) begin
                    if (rv2==32'h5555) begin halt<=1'b1; exit_code<=32'd0; end
                    else if (rv2==32'h7777) begin halt<=1'b1; exit_code<=32'd1; end
                end
                // CSR writes
                if (csr_we_i) begin
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
                        12'h340: mscratch<= csr_wval;
                        12'h341: mepc    <= csr_wval;
                        12'h342: mcause  <= csr_wval;
                        12'h343: mtval   <= csr_wval;
                        12'h344: begin mip[SSI]<=csr_wval[SSI]; mip[STI]<=csr_wval[STI]; mip[SEI]<=csr_wval[SEI]; end
                        default: ;
                    endcase
                end
                pc<=pcnext; minstret<=minstret+64'd1; state<=S_FETCH;
            end
        end

        // ---- RAM read complete (load / LR / AMO old value) ----
        S_LOAD: if (mem_ready) begin
            if (is_load) begin
                if (rd!=5'd0) regs[rd]<=loaddata;
                pc<=pcnext; minstret<=minstret+64'd1; state<=S_GAP;
            end else if (is_lr) begin
                if (rd!=5'd0) regs[rd]<=mem_rdata;
                lr_valid<=1'b1; lr_addr<={d_pa[31:2],2'b00};
                pc<=pcnext; minstret<=minstret+64'd1; state<=S_GAP;
            end else begin                            // AMO: capture old + result, go store
                amo_wdata_r <= amo_res;
                if (rd!=5'd0) regs[rd]<=mem_rdata;
                state<=S_AMOGAP;
            end
        end

        // ---- 1-cycle gap so the cache sees req deasserted ----
        S_AMOGAP: state <= S_STORE;

        // ---- RAM write complete ----
        S_STORE: if (mem_ready) begin
            if (is_sc) begin
                if (rd!=5'd0) regs[rd]<=32'd0;        // SC success
                lr_valid<=1'b0;
            end else if (!is_amo) begin
                // plain store: a store to a reserved word breaks the reservation
                if (lr_valid && lr_addr=={d_pa[31:2],2'b00}) lr_valid<=1'b0;
            end
            pc<=pcnext; minstret<=minstret+64'd1; state<=S_GAP;
        end

        S_GAP: state <= S_FETCH;
        endcase
    end
endmodule
