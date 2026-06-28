`timescale 1ns/1ps
// ===========================================================================
// 2 宽顺序超标量 RV32I (非对称双发射)
//   Lane A (槽0): 全功能 - ALU / LOAD / STORE / BRANCH / JAL / JALR
//   Lane B (槽1): 仅 ALU 类 (OP/OP-IMM/LUI/AUIPC)
//   发射规则: 同时发 2 条需满足: B 是简单 ALU 且 A 非控制转移 且 B 不依赖 A 且不与 A 同写
//   阶段: ID(组合取指+译码+发射) -> EX -> MEM -> WB
//   前递: 跨束全前递 (EX/MEM, MEM/WB -> EX; MEM/WB -> ID 读). load-use 停 1 拍.
//   分支/跳转: 预测不跳, EX 解析, 误判冲刷 (1 气泡)
//   注: 取指为组合读(为简化对齐), Fmax 会比标量低; 本阶段重点是 IPC
// ===========================================================================

// ---------------- 译码器 (与标量核逻辑一致, 实例化两次) ----------------
module sdec(
    input  wire [31:0] instr,
    output wire [4:0]  rd, rs1, rs2,
    output wire [2:0]  funct3,
    output reg         reg_write, mem_read, mem_write, is_branch, is_jal, is_jalr,
    output reg  [1:0]  alu_a_sel, result_src,
    output reg         alu_b_sel,
    output reg  [3:0]  alu_op,
    output reg  [31:0] imm,
    output reg         uses_rs1, uses_rs2
);
    localparam [6:0] OP_LUI=7'b0110111, OP_AUIPC=7'b0010111, OP_JAL=7'b1101111,
                     OP_JALR=7'b1100111, OP_BR=7'b1100011, OP_LOAD=7'b0000011,
                     OP_STORE=7'b0100011, OP_IMM=7'b0010011, OP_REG=7'b0110011;
    localparam [3:0] A_ADD=0,A_SUB=1,A_AND=2,A_OR=3,A_XOR=4,
                     A_SLL=5,A_SRL=6,A_SRA=7,A_SLT=8,A_SLTU=9;
    wire [6:0] opcode = instr[6:0];
    assign rd     = instr[11:7];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];
    assign funct3 = instr[14:12];
    wire f7b = instr[30];
    wire [31:0] i_imm = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] s_imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] b_imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] u_imm = {instr[31:12], 12'b0};
    wire [31:0] j_imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
    always @(*) begin
        reg_write=0; mem_read=0; mem_write=0; is_branch=0; is_jal=0; is_jalr=0;
        alu_a_sel=2'd0; alu_b_sel=1'b0; result_src=2'd0; alu_op=A_ADD;
        imm=32'd0; uses_rs1=0; uses_rs2=0;
        case (opcode)
            OP_REG: begin
                reg_write=1; uses_rs1=1; uses_rs2=1;
                case (funct3)
                    3'b000: alu_op = f7b ? A_SUB : A_ADD;
                    3'b001: alu_op = A_SLL;
                    3'b010: alu_op = A_SLT;
                    3'b011: alu_op = A_SLTU;
                    3'b100: alu_op = A_XOR;
                    3'b101: alu_op = f7b ? A_SRA : A_SRL;
                    3'b110: alu_op = A_OR;
                    default:alu_op = A_AND;
                endcase
            end
            OP_IMM: begin
                reg_write=1; alu_b_sel=1; uses_rs1=1; imm=i_imm;
                case (funct3)
                    3'b000: alu_op = A_ADD;
                    3'b010: alu_op = A_SLT;
                    3'b011: alu_op = A_SLTU;
                    3'b100: alu_op = A_XOR;
                    3'b110: alu_op = A_OR;
                    3'b111: alu_op = A_AND;
                    3'b001: alu_op = A_SLL;
                    default:alu_op = f7b ? A_SRA : A_SRL; // 101
                endcase
            end
            OP_LOAD:  begin reg_write=1; mem_read=1;  result_src=2'd1; alu_b_sel=1; uses_rs1=1; imm=i_imm; end
            OP_STORE: begin mem_write=1; alu_b_sel=1; uses_rs1=1; uses_rs2=1; imm=s_imm; end
            OP_BR:    begin is_branch=1; uses_rs1=1; uses_rs2=1; imm=b_imm; end
            OP_LUI:   begin reg_write=1; alu_a_sel=2'd2; alu_b_sel=1; imm=u_imm; end
            OP_AUIPC: begin reg_write=1; alu_a_sel=2'd1; alu_b_sel=1; imm=u_imm; end
            OP_JAL:   begin reg_write=1; is_jal=1;  result_src=2'd2; imm=j_imm; end
            OP_JALR:  begin reg_write=1; is_jalr=1; result_src=2'd2; alu_b_sel=1; uses_rs1=1; imm=i_imm; end
            default: ;
        endcase
    end
endmodule

// ------------------------------- 顶层核 -------------------------------
module cpu_super #(
    parameter MEMFILE = "prog.hex"
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        imem_we,
    input  wire [7:0]  imem_waddr,
    input  wire [31:0] imem_wdata,
    output reg  [31:0] dbg_x10,
    output reg  [31:0] dbg_pc
);
    localparam [3:0] A_ADD=0,A_SUB=1,A_AND=2,A_OR=3,A_XOR=4,
                     A_SLL=5,A_SRL=6,A_SRA=7,A_SLT=8,A_SLTU=9;

    integer kk;
    reg [31:0] pc;
    reg [31:0] regs [0:31];
    reg [31:0] imem [0:255];
    reg [31:0] dmem [0:255];
    initial begin
        for (kk=0; kk<32;  kk=kk+1) regs[kk]=0;
        for (kk=0; kk<256; kk=kk+1) begin imem[kk]=0; dmem[kk]=0; end
`ifdef SIM_INIT
        $readmemh(MEMFILE, imem);
`endif
    end

    // ===================== ID/EX 流水寄存器 =====================
    // Lane A (全功能)
    reg        xa_v, xa_we, xa_isload, xa_isstore, xa_isbr, xa_isjal, xa_isjalr;
    reg [31:0] xa_pc, xa_imm, xa_rs1v, xa_rs2v;
    reg [4:0]  xa_rd, xa_rs1, xa_rs2;
    reg [2:0]  xa_f3;
    reg [3:0]  xa_aluop;
    reg [1:0]  xa_asel, xa_rsrc;
    reg        xa_bsel;
    // Lane B (仅 ALU)
    reg        xb_v, xb_we;
    reg [31:0] xb_pc, xb_imm, xb_rs1v, xb_rs2v;
    reg [4:0]  xb_rd, xb_rs1, xb_rs2;
    reg [3:0]  xb_aluop;
    reg [1:0]  xb_asel;
    reg        xb_bsel;
`ifdef DYN_BP
    reg [1:0]  bht [0:63];
    reg        xa_pred_taken;
    reg [5:0]  xa_bht_idx;
    integer    bi; initial for (bi=0; bi<64; bi=bi+1) bht[bi]=2'b01;
`endif

    // ===================== EX/MEM 流水寄存器 =====================
    reg        ma_v, ma_we, ma_isload, ma_isstore;
    reg [1:0]  ma_rsrc;
    reg [31:0] ma_alu, ma_pc4, ma_storeval;
    reg [4:0]  ma_rd;
    reg        mb_v, mb_we;
    reg [31:0] mb_alu;
    reg [4:0]  mb_rd;

    // ===================== MEM/WB 流水寄存器 =====================
    reg        wa_v, wa_we;
    reg [31:0] wa_res;
    reg [4:0]  wa_rd;
    reg        wb_v, wb_we;
    reg [31:0] wb_res;
    reg [4:0]  wb_rd;

    // ===================== 函数: ALU / 分支条件 / 前递 =====================
    function [31:0] alu;
        input [3:0] op; input [31:0] x, y;
        begin
            case (op)
                A_ADD:   alu = x + y;
                A_SUB:   alu = x - y;
                A_AND:   alu = x & y;
                A_OR:    alu = x | y;
                A_XOR:   alu = x ^ y;
                A_SLL:   alu = x << y[4:0];
                A_SRL:   alu = x >> y[4:0];
                A_SRA:   alu = $signed(x) >>> y[4:0];
                A_SLT:   alu = ($signed(x) < $signed(y)) ? 32'd1 : 32'd0;
                A_SLTU:  alu = (x < y) ? 32'd1 : 32'd0;
                default: alu = 32'd0;
            endcase
        end
    endfunction

    function cond;
        input [2:0] f3; input [31:0] x, y;
        begin
            case (f3)
                3'b000:  cond = (x == y);
                3'b001:  cond = (x != y);
                3'b100:  cond = ($signed(x) <  $signed(y));
                3'b101:  cond = ($signed(x) >= $signed(y));
                3'b110:  cond = (x <  y);
                default: cond = (x >= y); // 111
            endcase
        end
    endfunction

    wire [31:0] exmem_a_fwd = (ma_rsrc==2'd2) ? ma_pc4 : ma_alu; // 非 load 的可前递值

    // 前递用宏(内联展开, 保证连续赋值对 ma_*/mb_*/wa_*/wb_* 敏感)
    // EX 级: 新->旧, 同级 LaneB(程序序在后) 优先于 LaneA; LaneA 的 load 不从 EX/MEM 前递
    `define FWDEX(R,FB) (((R)==5'd0) ? 32'd0 : \
        (mb_v && mb_we && mb_rd==(R)) ? mb_alu : \
        (ma_v && ma_we && ma_rd==(R) && !ma_isload) ? exmem_a_fwd : \
        (wb_v && wb_we && wb_rd==(R)) ? wb_res : \
        (wa_v && wa_we && wa_rd==(R)) ? wa_res : (FB))
    // ID 读: 仅 WB 级 (距离3 冒险), 其余靠 EX 级前递
    `define FWDID(R,FB) (((R)==5'd0) ? 32'd0 : \
        (wb_v && wb_we && wb_rd==(R)) ? wb_res : \
        (wa_v && wa_we && wa_rd==(R)) ? wa_res : (FB))

    // ===================== ID: 取指(组合) + 译码 =====================
    wire [31:0] ia = imem[pc[9:2]];
    wire [31:0] ib = imem[pc[9:2] + 1];

    wire        da_rw, da_mr, da_mw, da_br, da_jal, da_jalr, da_u1, da_u2, da_bsel;
    wire [1:0]  da_asel, da_rsrc;
    wire [3:0]  da_aluop;
    wire [31:0] da_imm;
    wire [4:0]  da_rd, da_rs1, da_rs2;
    wire [2:0]  da_f3;
    sdec dca(.instr(ia), .rd(da_rd), .rs1(da_rs1), .rs2(da_rs2), .funct3(da_f3),
        .reg_write(da_rw), .mem_read(da_mr), .mem_write(da_mw), .is_branch(da_br),
        .is_jal(da_jal), .is_jalr(da_jalr), .alu_a_sel(da_asel), .result_src(da_rsrc),
        .alu_b_sel(da_bsel), .alu_op(da_aluop), .imm(da_imm), .uses_rs1(da_u1), .uses_rs2(da_u2));

    wire        db_rw, db_mr, db_mw, db_br, db_jal, db_jalr, db_u1, db_u2, db_bsel;
    wire [1:0]  db_asel, db_rsrc;
    wire [3:0]  db_aluop;
    wire [31:0] db_imm;
    wire [4:0]  db_rd, db_rs1, db_rs2;
    wire [2:0]  db_f3;
    sdec dcb(.instr(ib), .rd(db_rd), .rs1(db_rs1), .rs2(db_rs2), .funct3(db_f3),
        .reg_write(db_rw), .mem_read(db_mr), .mem_write(db_mw), .is_branch(db_br),
        .is_jal(db_jal), .is_jalr(db_jalr), .alu_a_sel(db_asel), .result_src(db_rsrc),
        .alu_b_sel(db_bsel), .alu_op(db_aluop), .imm(db_imm), .uses_rs1(db_u1), .uses_rs2(db_u2));

    // ID 读寄存器 (带 WB 前递)
    wire [31:0] a_rs1_id = `FWDID(da_rs1, regs[da_rs1]);
    wire [31:0] a_rs2_id = `FWDID(da_rs2, regs[da_rs2]);
    wire [31:0] b_rs1_id = `FWDID(db_rs1, regs[db_rs1]);
    wire [31:0] b_rs2_id = `FWDID(db_rs2, regs[db_rs2]);

    // ===================== EX 组合逻辑 =====================
    wire [31:0] a_op1 = `FWDEX(xa_rs1, xa_rs1v);
    wire [31:0] a_op2 = `FWDEX(xa_rs2, xa_rs2v);
    wire [31:0] a_in1 = (xa_asel==2'd1) ? xa_pc : (xa_asel==2'd2) ? 32'd0 : a_op1;
    wire [31:0] a_in2 = xa_bsel ? xa_imm : a_op2;
    wire [31:0] aluA  = alu(xa_aluop, a_in1, a_in2);
    wire        a_taken = xa_v && xa_isbr && cond(xa_f3, a_op1, a_op2);
    wire [31:0] a_jrtgt = (a_op1 + xa_imm) & ~32'h1;
`ifdef DYN_BP
    // 误预测 = 实际方向 != ID 预测; jal 已在 ID 重定向, 不在 EX 重定向
    wire        mispred     = xa_isbr && (a_taken != xa_pred_taken);
    wire        redirect    = xa_v && (xa_isjalr || mispred);
    wire [31:0] redirect_pc = xa_isjalr ? a_jrtgt :
                              (a_taken ? (xa_pc + xa_imm) : (xa_pc + 32'd4));
`else
    wire        redirect    = xa_v && (xa_isjal || xa_isjalr || a_taken);
    wire [31:0] redirect_pc = xa_isjalr ? a_jrtgt : (xa_pc + xa_imm);
`endif

    wire [31:0] b_op1 = `FWDEX(xb_rs1, xb_rs1v);
    wire [31:0] b_op2 = `FWDEX(xb_rs2, xb_rs2v);
    wire [31:0] b_in1 = (xb_asel==2'd1) ? xb_pc : (xb_asel==2'd2) ? 32'd0 : b_op1;
    wire [31:0] b_in2 = xb_bsel ? xb_imm : b_op2;
    wire [31:0] aluB  = alu(xb_aluop, b_in1, b_in2);

    // ===================== 冒险 / 发射决策 =====================
    wire need_a = (da_u1 && da_rs1!=5'd0) || (da_u2 && da_rs2!=5'd0);
    // load-use: LaneA load 在 EX, ID 束(A 或 B)用到它 -> 停 1 拍
    wire ld_hit = xa_v && xa_isload && (xa_rd!=5'd0) &&
                  ( (da_u1 && da_rs1==xa_rd) || (da_u2 && da_rs2==xa_rd) ||
                    (db_u1 && db_rs1==xa_rd) || (db_u2 && db_rs2==xa_rd) );
    wire stall = ld_hit;

    wire a_is_ctrl = da_br || da_jal || da_jalr;
    wire b_simple  = db_rw && !db_mr && !db_mw && !db_br && !db_jal && !db_jalr;
    wire dep_b_a   = da_rw && (da_rd!=5'd0) &&
                     ( (db_u1 && db_rs1==da_rd) || (db_u2 && db_rs2==da_rd) );
    wire waw_b_a   = da_rw && db_rw && (da_rd!=5'd0) && (da_rd==db_rd);

    wire iss_a = !stall && !redirect;
    wire iss_b = iss_a && b_simple && !a_is_ctrl && !dep_b_a && !waw_b_a;

    // ===================== 动态分支预测 (ID 级重定向) =====================
`ifdef DYN_BP
    wire [5:0]  id_bht_idx    = pc[7:2];
    wire        id_pred_taken = da_br && bht[id_bht_idx][1];
    wire        id_take       = iss_a && (da_jal || (da_br && id_pred_taken));
    wire [31:0] id_take_pc    = pc + da_imm;   // jal: pc+j_imm; 分支: pc+b_imm
`else
    wire        id_take    = 1'b0;
    wire [31:0] id_take_pc = 32'd0;
`endif

    // ===================== 时序: PC =====================
    always @(posedge clk) begin
        if (rst)             pc <= 32'd0;
        else if (redirect)   pc <= redirect_pc;
        else if (stall)      pc <= pc;
        else if (id_take)    pc <= id_take_pc;
        else if (iss_b)      pc <= pc + 32'd8;
        else                 pc <= pc + 32'd4;
    end

    always @(posedge clk) if (imem_we) imem[imem_waddr] <= imem_wdata;

    // ===================== 时序: ID/EX =====================
    always @(posedge clk) begin
        if (rst || redirect || stall) begin
            xa_v<=0; xa_we<=0; xa_isload<=0; xa_isstore<=0; xa_isbr<=0; xa_isjal<=0; xa_isjalr<=0; xa_rd<=0;
            xb_v<=0; xb_we<=0; xb_rd<=0;
`ifdef DYN_BP
            xa_pred_taken<=1'b0;
`endif
        end else begin
            // Lane A
            xa_v<=1'b1; xa_pc<=pc; xa_rd<=da_rd; xa_rs1<=da_rs1; xa_rs2<=da_rs2;
            xa_rs1v<=a_rs1_id; xa_rs2v<=a_rs2_id; xa_imm<=da_imm; xa_aluop<=da_aluop;
            xa_asel<=da_asel; xa_bsel<=da_bsel; xa_rsrc<=da_rsrc; xa_f3<=da_f3;
            xa_we<=da_rw; xa_isload<=da_mr; xa_isstore<=da_mw;
            xa_isbr<=da_br; xa_isjal<=da_jal; xa_isjalr<=da_jalr;
            // Lane B
            xb_v<=iss_b; xb_pc<=pc+32'd4; xb_rd<=db_rd; xb_rs1<=db_rs1; xb_rs2<=db_rs2;
            xb_rs1v<=b_rs1_id; xb_rs2v<=b_rs2_id; xb_imm<=db_imm; xb_aluop<=db_aluop;
            xb_asel<=db_asel; xb_bsel<=db_bsel; xb_we<=(iss_b ? db_rw : 1'b0);
`ifdef DYN_BP
            xa_pred_taken <= id_pred_taken; xa_bht_idx <= id_bht_idx;
`endif
        end
    end

    // ===================== 时序: EX/MEM =====================
    always @(posedge clk) begin
        if (rst) begin
            ma_v<=0; ma_we<=0; ma_isload<=0; ma_isstore<=0; ma_rd<=0;
            mb_v<=0; mb_we<=0; mb_rd<=0;
        end else begin
            ma_v<=xa_v; ma_we<=xa_we; ma_isload<=xa_isload; ma_isstore<=xa_isstore;
            ma_rsrc<=xa_rsrc; ma_alu<=aluA; ma_pc4<=xa_pc+32'd4; ma_storeval<=a_op2; ma_rd<=xa_rd;
            mb_v<=xb_v; mb_we<=xb_we; mb_alu<=aluB; mb_rd<=xb_rd;
        end
    end

    // ===================== 时序: MEM/WB (含数据存储) =====================
    always @(posedge clk) begin
        if (rst) begin
            wa_v<=0; wa_we<=0; wa_rd<=0;
            wb_v<=0; wb_we<=0; wb_rd<=0;
        end else begin
            if (ma_isstore) dmem[ma_alu[9:2]] <= ma_storeval;
            wa_v<=ma_v; wa_we<=ma_we; wa_rd<=ma_rd;
            wa_res <= (ma_rsrc==2'd1) ? dmem[ma_alu[9:2]] :
                      (ma_rsrc==2'd2) ? ma_pc4 : ma_alu;
            wb_v<=mb_v; wb_we<=mb_we; wb_rd<=mb_rd; wb_res<=mb_alu;
        end
    end

    // ===================== 时序: 寄存器写回 (双写口) =====================
    always @(posedge clk) begin
        if (!rst) begin
            if (wa_we && wa_rd!=5'd0) regs[wa_rd] <= wa_res;
            if (wb_we && wb_rd!=5'd0) regs[wb_rd] <= wb_res;
        end
    end

`ifdef DYN_BP
    // BHT 更新 (分支在 EX 解析时)
    always @(posedge clk) if (!rst && xa_v && xa_isbr) begin
        if (a_taken) begin if (bht[xa_bht_idx]!=2'b11) bht[xa_bht_idx] <= bht[xa_bht_idx]+2'd1; end
        else         begin if (bht[xa_bht_idx]!=2'b00) bht[xa_bht_idx] <= bht[xa_bht_idx]-2'd1; end
    end
`endif

`ifdef SIM_INIT
    // ---- 性能计数器 (仅仿真) ----
    reg [31:0] cyc_count, instr_retired, branch_count, mispredict_count;
    always @(posedge clk) begin
        if (rst) begin
            cyc_count<=0; instr_retired<=0; branch_count<=0; mispredict_count<=0;
        end else begin
            cyc_count     <= cyc_count + 32'd1;
            instr_retired <= instr_retired + (wa_v?32'd1:32'd0) + (wb_v?32'd1:32'd0);
            if (xa_v && xa_isbr)            branch_count     <= branch_count + 32'd1;
`ifdef DYN_BP
            if (xa_v && mispred)            mispredict_count <= mispredict_count + 32'd1;
`else
            if (xa_v && xa_isbr && a_taken) mispredict_count <= mispredict_count + 32'd1;
`endif
        end
    end
`endif

    always @(*) begin dbg_x10 = regs[10]; dbg_pc = pc; end
endmodule
