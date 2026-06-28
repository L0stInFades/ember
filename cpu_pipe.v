`timescale 1ns/1ps
// ===========================================================================
// 5 级流水线 RV32I 处理器核 (面向高 Fmax)
//   stages: IF -> ID -> EX -> MEM -> WB
//   冒险处理:
//     - 数据前递 (forwarding): EX/MEM, MEM/WB -> EX 操作数 (含分支比较/store 数据)
//     - load-use 停顿: 1 个气泡
//     - 静态分支预测 (BTFN): 后向分支预测跳转(ID 重定向, 1 气泡);
//                            前向分支预测不跳; 误判在 EX 修正(2 气泡)
//     - JAL 在 ID 解析并重定向(1 气泡); JALR 在 EX 解析(2 气泡)
//   存储: 同步读 BRAM 风格(imem/dmem), 利于 FPGA 时序收敛
// ===========================================================================
module cpu_pipe #(
    parameter MEMFILE = "prog_pipe.hex"
)(
    input  wire        clk,
    input  wire        rst,
    // 外部指令加载口 (综合时使指令内容"未知", 避免常量折叠; 仿真中置 0 不用)
    input  wire        imem_we,
    input  wire [7:0]  imem_waddr,
    input  wire [31:0] imem_wdata,
    output reg  [31:0] dbg_x10,
    output reg  [31:0] dbg_pc
);
    // ---- opcodes ----
    localparam [6:0] OP_LUI=7'b0110111, OP_AUIPC=7'b0010111, OP_JAL=7'b1101111,
                     OP_JALR=7'b1100111, OP_BR=7'b1100011, OP_LOAD=7'b0000011,
                     OP_STORE=7'b0100011, OP_IMM=7'b0010011, OP_REG=7'b0110011;
    // ---- ALU ops ----
    localparam [3:0] A_ADD=0,A_SUB=1,A_AND=2,A_OR=3,A_XOR=4,
                     A_SLL=5,A_SRL=6,A_SRA=7,A_SLT=8,A_SLTU=9;

    // ===================== 体系结构状态 =====================
    reg [31:0] pc;
    reg [31:0] regs [0:31];
    reg [31:0] imem [0:255];
    reg [31:0] dmem [0:255];

    integer kk;
    initial begin
        for (kk=0; kk<32;  kk=kk+1) regs[kk]=0;
        for (kk=0; kk<256; kk=kk+1) begin imem[kk]=0; dmem[kk]=0; end
`ifdef SIM_INIT
        $readmemh(MEMFILE, imem);
`endif
    end

    // ===================== 流水线寄存器 =====================
    reg [31:0] if_id_instr, if_id_pc;

    reg [31:0] id_ex_pc, id_ex_imm, id_ex_rs1_v, id_ex_rs2_v;
    reg [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
    reg [2:0]  id_ex_funct3;
    reg [3:0]  id_ex_alu_op;
    reg [1:0]  id_ex_alu_a_sel, id_ex_result_src;
    reg        id_ex_alu_b_sel;
    reg        id_ex_reg_write, id_ex_mem_read, id_ex_mem_write;
    reg        id_ex_is_branch, id_ex_is_jal, id_ex_is_jalr, id_ex_predicted_taken;

    reg [31:0] ex_mem_alu_result, ex_mem_store_data, ex_mem_pc4;
    reg [4:0]  ex_mem_rd;
    reg [1:0]  ex_mem_result_src;
    reg        ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write;

    reg [31:0] mem_wb_alu_result, mem_wb_mem_data, mem_wb_pc4;
    reg [4:0]  mem_wb_rd;
    reg [1:0]  mem_wb_result_src;
    reg        mem_wb_reg_write;

    // ===================== WB 阶段 =====================
    wire [31:0] wb_result = (mem_wb_result_src==2'd0) ? mem_wb_alu_result :
                            (mem_wb_result_src==2'd1) ? mem_wb_mem_data   :
                                                        mem_wb_pc4;
    wire memwb_fwd_ok = mem_wb_reg_write && (mem_wb_rd != 5'd0);

    // ===================== ID 阶段: 译码 =====================
    wire [6:0] id_opcode = if_id_instr[6:0];
    wire [4:0] id_rd     = if_id_instr[11:7];
    wire [2:0] id_funct3 = if_id_instr[14:12];
    wire [4:0] id_rs1    = if_id_instr[19:15];
    wire [4:0] id_rs2    = if_id_instr[24:20];
    wire       id_f7b    = if_id_instr[30];

    wire [31:0] id_i_imm = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
    wire [31:0] id_s_imm = {{20{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
    wire [31:0] id_b_imm = {{19{if_id_instr[31]}}, if_id_instr[31], if_id_instr[7], if_id_instr[30:25], if_id_instr[11:8], 1'b0};
    wire [31:0] id_u_imm = {if_id_instr[31:12], 12'b0};
    wire [31:0] id_j_imm = {{11{if_id_instr[31]}}, if_id_instr[31], if_id_instr[19:12], if_id_instr[20], if_id_instr[30:21], 1'b0};

    reg        c_reg_write, c_mem_read, c_mem_write, c_is_branch, c_is_jal, c_is_jalr;
    reg [1:0]  c_alu_a_sel, c_result_src;
    reg        c_alu_b_sel;
    reg [3:0]  c_alu_op;
    reg [31:0] id_imm;
    reg        uses_rs1, uses_rs2;

    always @(*) begin
        // defaults (= bubble / no side effect)
        c_reg_write=0; c_mem_read=0; c_mem_write=0; c_is_branch=0; c_is_jal=0; c_is_jalr=0;
        c_alu_a_sel=2'd0; c_alu_b_sel=1'b0; c_result_src=2'd0; c_alu_op=A_ADD;
        id_imm=32'd0; uses_rs1=1'b0; uses_rs2=1'b0;
        case (id_opcode)
            OP_REG: begin
                c_reg_write=1; uses_rs1=1; uses_rs2=1;
                case (id_funct3)
                    3'b000: c_alu_op = id_f7b ? A_SUB : A_ADD;
                    3'b001: c_alu_op = A_SLL;
                    3'b010: c_alu_op = A_SLT;
                    3'b011: c_alu_op = A_SLTU;
                    3'b100: c_alu_op = A_XOR;
                    3'b101: c_alu_op = id_f7b ? A_SRA : A_SRL;
                    3'b110: c_alu_op = A_OR;
                    default:c_alu_op = A_AND;
                endcase
            end
            OP_IMM: begin
                c_reg_write=1; c_alu_b_sel=1; uses_rs1=1; id_imm=id_i_imm;
                case (id_funct3)
                    3'b000: c_alu_op = A_ADD;
                    3'b010: c_alu_op = A_SLT;
                    3'b011: c_alu_op = A_SLTU;
                    3'b100: c_alu_op = A_XOR;
                    3'b110: c_alu_op = A_OR;
                    3'b111: c_alu_op = A_AND;
                    3'b001: c_alu_op = A_SLL;
                    default:c_alu_op = id_f7b ? A_SRA : A_SRL; // 101
                endcase
            end
            OP_LOAD:  begin c_reg_write=1; c_mem_read=1; c_result_src=2'd1; c_alu_b_sel=1; uses_rs1=1; id_imm=id_i_imm; end
            OP_STORE: begin c_mem_write=1; c_alu_b_sel=1; uses_rs1=1; uses_rs2=1; id_imm=id_s_imm; end
            OP_BR:    begin c_is_branch=1; uses_rs1=1; uses_rs2=1; id_imm=id_b_imm; end
            OP_LUI:   begin c_reg_write=1; c_alu_a_sel=2'd2; c_alu_b_sel=1; id_imm=id_u_imm; end
            OP_AUIPC: begin c_reg_write=1; c_alu_a_sel=2'd1; c_alu_b_sel=1; id_imm=id_u_imm; end
            OP_JAL:   begin c_reg_write=1; c_is_jal=1; c_result_src=2'd2; id_imm=id_j_imm; end
            OP_JALR:  begin c_reg_write=1; c_is_jalr=1; c_result_src=2'd2; c_alu_b_sel=1; uses_rs1=1; id_imm=id_i_imm; end
            default: ; // bubble
        endcase
    end

    // 寄存器读 + WB 写直通 (read-during-write forwarding)
    wire [31:0] rf_rs1 = (id_rs1==5'd0) ? 32'd0 : regs[id_rs1];
    wire [31:0] rf_rs2 = (id_rs2==5'd0) ? 32'd0 : regs[id_rs2];
    wire [31:0] rs1_v_id = (memwb_fwd_ok && mem_wb_rd==id_rs1) ? wb_result : rf_rs1;
    wire [31:0] rs2_v_id = (memwb_fwd_ok && mem_wb_rd==id_rs2) ? wb_result : rf_rs2;

    // ===================== EX 阶段: 前递 =====================
    wire        exmem_fwd_ok  = ex_mem_reg_write && (ex_mem_rd!=5'd0) && (ex_mem_result_src!=2'd1);
    wire [31:0] exmem_fwd_val = (ex_mem_result_src==2'd2) ? ex_mem_pc4 : ex_mem_alu_result;
    // EX 级前递排除 load 结果(它走 BRAM 慢输出); load 值改由停顿+寄存器堆/ID 直通获得
    wire        memwb_ex_fwd_ok = mem_wb_reg_write && (mem_wb_rd!=5'd0) && (mem_wb_result_src!=2'd1);

    wire [31:0] fwdA = (exmem_fwd_ok    && ex_mem_rd==id_ex_rs1) ? exmem_fwd_val :
                       (memwb_ex_fwd_ok && mem_wb_rd==id_ex_rs1) ? wb_result     :
                                                                   id_ex_rs1_v;
    wire [31:0] fwdB = (exmem_fwd_ok    && ex_mem_rd==id_ex_rs2) ? exmem_fwd_val :
                       (memwb_ex_fwd_ok && mem_wb_rd==id_ex_rs2) ? wb_result     :
                                                                   id_ex_rs2_v;

    wire [31:0] alu_in1 = (id_ex_alu_a_sel==2'd1) ? id_ex_pc :
                          (id_ex_alu_a_sel==2'd2) ? 32'd0     : fwdA;
    wire [31:0] alu_in2 = id_ex_alu_b_sel ? id_ex_imm : fwdB;

    reg [31:0] alu_y;
    always @(*) begin
        case (id_ex_alu_op)
            A_ADD:   alu_y = alu_in1 + alu_in2;
            A_SUB:   alu_y = alu_in1 - alu_in2;
            A_AND:   alu_y = alu_in1 & alu_in2;
            A_OR:    alu_y = alu_in1 | alu_in2;
            A_XOR:   alu_y = alu_in1 ^ alu_in2;
            A_SLL:   alu_y = alu_in1 << alu_in2[4:0];
            A_SRL:   alu_y = alu_in1 >> alu_in2[4:0];
            A_SRA:   alu_y = $signed(alu_in1) >>> alu_in2[4:0];
            A_SLT:   alu_y = ($signed(alu_in1) < $signed(alu_in2)) ? 32'd1 : 32'd0;
            A_SLTU:  alu_y = (alu_in1 < alu_in2) ? 32'd1 : 32'd0;
            default: alu_y = 32'd0;
        endcase
    end

    // 分支条件 (用前递后的操作数)
    reg actual_taken;
    always @(*) begin
        case (id_ex_funct3)
            3'b000:  actual_taken = (fwdA == fwdB);
            3'b001:  actual_taken = (fwdA != fwdB);
            3'b100:  actual_taken = ($signed(fwdA) <  $signed(fwdB));
            3'b101:  actual_taken = ($signed(fwdA) >= $signed(fwdB));
            3'b110:  actual_taken = (fwdA <  fwdB);
            default: actual_taken = (fwdA >= fwdB); // 111
        endcase
    end

    wire [31:0] branch_target = id_ex_pc + id_ex_imm;
    wire [31:0] jalr_target   = (fwdA + id_ex_imm) & ~32'h1;
    wire        mispredict    = id_ex_is_branch && (actual_taken != id_ex_predicted_taken);
    wire        ex_redirect   = mispredict || id_ex_is_jalr;
    wire [31:0] ex_redirect_pc= id_ex_is_jalr ? jalr_target :
                                (actual_taken ? branch_target : (id_ex_pc + 32'd4));

    // ===================== 冒险检测 =====================
    // load 结果不再组合前递进 EX, 故 load-use 需停顿到其写回寄存器堆:
    //   距离1(load 在 EX) 停 2 拍, 距离2(load 在 MEM) 停 1 拍
    wire dep_ex  = (uses_rs1 && (id_ex_rd ==id_rs1)) || (uses_rs2 && (id_ex_rd ==id_rs2));
    wire dep_mem = (uses_rs1 && (ex_mem_rd==id_rs1)) || (uses_rs2 && (ex_mem_rd==id_rs2));
    wire load_use_stall = (id_ex_mem_read  && (id_ex_rd !=5'd0) && dep_ex) ||
                          (ex_mem_mem_read && (ex_mem_rd!=5'd0) && dep_mem);

`ifdef DYN_BP
    // 动态分支预测: 64 项 2 位饱和计数器 BHT, 按 PC 低位索引; MSB 即方向预测
    reg  [1:0] bht [0:63];
    integer bhi; initial for (bhi=0; bhi<64; bhi=bhi+1) bht[bhi]=2'b01;
    wire [5:0] id_bht_idx = if_id_pc[7:2];
    wire id_predicted_taken = c_is_branch && bht[id_bht_idx][1];
    reg  [5:0] id_ex_bht_idx;
    always @(posedge clk) id_ex_bht_idx <= id_bht_idx;
    always @(posedge clk) if (!rst && id_ex_is_branch) begin
        if (actual_taken) begin if (bht[id_ex_bht_idx]!=2'b11) bht[id_ex_bht_idx] <= bht[id_ex_bht_idx]+2'd1; end
        else              begin if (bht[id_ex_bht_idx]!=2'b00) bht[id_ex_bht_idx] <= bht[id_ex_bht_idx]-2'd1; end
    end
`else
    wire id_predicted_taken = c_is_branch && id_b_imm[31];   // 静态 BTFN: 后向预测跳转
`endif
    wire id_redirect    = (!ex_redirect) && (!load_use_stall) &&
                          (c_is_jal || (c_is_branch && id_predicted_taken));
    wire [31:0] id_redirect_pc = if_id_pc + id_imm;

    // ===================== 时序: PC =====================
    always @(posedge clk) begin
        if (rst)                 pc <= 32'd0;
        else if (ex_redirect)    pc <= ex_redirect_pc;
        else if (load_use_stall) pc <= pc;
        else if (id_redirect)    pc <= id_redirect_pc;
        else                     pc <= pc + 32'd4;
    end

    // ===================== 时序: IF/ID =====================
    always @(posedge clk) begin
        if (rst || ex_redirect || id_redirect) begin
            if_id_instr <= 32'd0; if_id_pc <= 32'd0;     // flush -> bubble
        end else if (load_use_stall) begin
            if_id_instr <= if_id_instr; if_id_pc <= if_id_pc; // freeze
        end else begin
            if_id_instr <= imem[pc[9:2]]; if_id_pc <= pc;     // sync fetch
        end
    end

    // 指令存储写端口 (外部加载)
    always @(posedge clk) if (imem_we) imem[imem_waddr] <= imem_wdata;

    // ===================== 时序: ID/EX =====================
    always @(posedge clk) begin
        if (rst || ex_redirect || load_use_stall) begin
            id_ex_reg_write<=0; id_ex_mem_read<=0; id_ex_mem_write<=0;
            id_ex_is_branch<=0; id_ex_is_jal<=0; id_ex_is_jalr<=0; id_ex_predicted_taken<=0;
            id_ex_rd<=0; id_ex_rs1<=0; id_ex_rs2<=0; id_ex_result_src<=0;
        end else begin
            id_ex_pc<=if_id_pc; id_ex_imm<=id_imm;
            id_ex_rs1_v<=rs1_v_id; id_ex_rs2_v<=rs2_v_id;
            id_ex_rs1<=id_rs1; id_ex_rs2<=id_rs2; id_ex_rd<=id_rd;
            id_ex_funct3<=id_funct3; id_ex_alu_op<=c_alu_op;
            id_ex_alu_a_sel<=c_alu_a_sel; id_ex_alu_b_sel<=c_alu_b_sel;
            id_ex_result_src<=c_result_src;
            id_ex_reg_write<=c_reg_write; id_ex_mem_read<=c_mem_read; id_ex_mem_write<=c_mem_write;
            id_ex_is_branch<=c_is_branch; id_ex_is_jal<=c_is_jal; id_ex_is_jalr<=c_is_jalr;
            id_ex_predicted_taken<=id_predicted_taken;
        end
    end

    // ===================== 时序: EX/MEM =====================
    always @(posedge clk) begin
        if (rst) begin
            ex_mem_reg_write<=0; ex_mem_mem_read<=0; ex_mem_mem_write<=0;
            ex_mem_rd<=0; ex_mem_result_src<=0;
        end else begin
            ex_mem_reg_write<=id_ex_reg_write; ex_mem_mem_read<=id_ex_mem_read;
            ex_mem_mem_write<=id_ex_mem_write; ex_mem_result_src<=id_ex_result_src;
            ex_mem_alu_result<=alu_y; ex_mem_store_data<=fwdB;
            ex_mem_rd<=id_ex_rd; ex_mem_pc4<=id_ex_pc + 32'd4;
        end
    end

    // ===================== 时序: MEM/WB (含数据存储) =====================
    always @(posedge clk) begin
        if (rst) begin
            mem_wb_reg_write<=0; mem_wb_rd<=0; mem_wb_result_src<=0;
        end else begin
            if (ex_mem_mem_write) dmem[ex_mem_alu_result[9:2]] <= ex_mem_store_data;
            mem_wb_mem_data   <= dmem[ex_mem_alu_result[9:2]];
            mem_wb_reg_write  <= ex_mem_reg_write;
            mem_wb_result_src <= ex_mem_result_src;
            mem_wb_alu_result <= ex_mem_alu_result;
            mem_wb_pc4        <= ex_mem_pc4;
            mem_wb_rd         <= ex_mem_rd;
        end
    end

    // ===================== 时序: 寄存器写回 =====================
    always @(posedge clk) begin
        if (!rst && mem_wb_reg_write && mem_wb_rd!=5'd0)
            regs[mem_wb_rd] <= wb_result;
    end

`ifdef SIM_INIT
    // ---- 性能计数器 (仅仿真): cycles / 退休指令 / 分支 / 误预测 ----
    reg if_id_valid, id_ex_valid, ex_mem_valid, mem_wb_valid;
    reg [31:0] cyc_count, instr_retired, branch_count, mispredict_count;
    always @(posedge clk) begin
        if (rst) begin
            if_id_valid<=0; id_ex_valid<=0; ex_mem_valid<=0; mem_wb_valid<=0;
            cyc_count<=0; instr_retired<=0; branch_count<=0; mispredict_count<=0;
        end else begin
            if (ex_redirect || id_redirect) if_id_valid <= 1'b0;
            else if (load_use_stall)        if_id_valid <= if_id_valid;
            else                            if_id_valid <= 1'b1;
            if (ex_redirect || load_use_stall) id_ex_valid <= 1'b0;
            else                               id_ex_valid <= if_id_valid;
            ex_mem_valid <= id_ex_valid;
            mem_wb_valid <= ex_mem_valid;
            cyc_count <= cyc_count + 32'd1;
            if (mem_wb_valid)    instr_retired    <= instr_retired + 32'd1;
            if (id_ex_is_branch) branch_count     <= branch_count + 32'd1;
            if (mispredict)      mispredict_count <= mispredict_count + 32'd1;
        end
    end
`endif

    // ---- 调试输出 (防止综合时被裁剪) ----
    always @(*) begin dbg_x10 = regs[10]; dbg_pc = pc; end
endmodule
