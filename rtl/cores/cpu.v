`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// 最小 RV32I 单周期处理器核 (teaching soft-core)
// 哈佛结构: 指令存储 imem 与数据存储 dmem 分离, 每条指令一个时钟周期完成.
// 支持: LUI AUIPC JAL JALR BRANCH(6) LOAD(lw) STORE(sw) OP-IMM OP
// ---------------------------------------------------------------------------
module cpu #(
    parameter MEMFILE = "prog.hex"
)(
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] pc_out,
    output wire [31:0] instr_out
);
    // ---- opcodes ----
    localparam [6:0] OP_LUI   = 7'b0110111;
    localparam [6:0] OP_AUIPC = 7'b0010111;
    localparam [6:0] OP_JAL   = 7'b1101111;
    localparam [6:0] OP_JALR  = 7'b1100111;
    localparam [6:0] OP_BR    = 7'b1100011;
    localparam [6:0] OP_LOAD  = 7'b0000011;
    localparam [6:0] OP_STORE = 7'b0100011;
    localparam [6:0] OP_IMM   = 7'b0010011;
    localparam [6:0] OP_REG   = 7'b0110011;

    // ---- ALU 操作编码 ----
    localparam [3:0] A_ADD=0, A_SUB=1, A_AND=2, A_OR=3, A_XOR=4,
                     A_SLL=5, A_SRL=6, A_SRA=7, A_SLT=8, A_SLTU=9;

    // ---- 体系结构状态 ----
    reg [31:0] pc;
    reg [31:0] regs [0:31];   // 32 个通用寄存器, x0 恒为 0
    reg [31:0] imem [0:255];  // 指令存储 (1KB)
    reg [31:0] dmem [0:255];  // 数据存储 (1KB)

    integer k;
    initial begin
        pc = 0;
        for (k=0; k<32;  k=k+1) regs[k] = 0;
        for (k=0; k<256; k=k+1) begin imem[k]=0; dmem[k]=0; end
        $readmemh(MEMFILE, imem);
    end

    // ---- 取指 ----
    wire [31:0] instr    = imem[pc[9:2]];
    wire [31:0] pc_plus4 = pc + 32'd4;
    assign pc_out    = pc;
    assign instr_out = instr;

    // ---- 译码 ----
    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd     = instr[11:7];
    wire [2:0] f3     = instr[14:12];
    wire [4:0] rs1    = instr[19:15];
    wire [4:0] rs2    = instr[24:20];

    wire [31:0] i_imm = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] s_imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] b_imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] u_imm = {instr[31:12], 12'b0};
    wire [31:0] j_imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    // ---- 读寄存器 (x0 永远读 0) ----
    wire [31:0] rs1_v = (rs1==5'b0) ? 32'b0 : regs[rs1];
    wire [31:0] rs2_v = (rs2==5'b0) ? 32'b0 : regs[rs2];

    // ---- ALU 操作数选择 ----
    wire        use_imm = (opcode==OP_IMM)||(opcode==OP_LOAD)||(opcode==OP_STORE)||(opcode==OP_JALR);
    wire [31:0] imm_alu = (opcode==OP_STORE) ? s_imm : i_imm;
    wire [31:0] alu_a   = rs1_v;
    wire [31:0] alu_b   = use_imm ? imm_alu : rs2_v;

    // ---- ALU 操作译码 ----
    reg [3:0] alu_op;
    always @(*) begin
        if (opcode==OP_REG) begin
            case (f3)
                3'b000:  alu_op = instr[30] ? A_SUB : A_ADD;
                3'b001:  alu_op = A_SLL;
                3'b010:  alu_op = A_SLT;
                3'b011:  alu_op = A_SLTU;
                3'b100:  alu_op = A_XOR;
                3'b101:  alu_op = instr[30] ? A_SRA : A_SRL;
                3'b110:  alu_op = A_OR;
                default: alu_op = A_AND;
            endcase
        end else if (opcode==OP_IMM) begin
            case (f3)
                3'b000:  alu_op = A_ADD;
                3'b010:  alu_op = A_SLT;
                3'b011:  alu_op = A_SLTU;
                3'b100:  alu_op = A_XOR;
                3'b110:  alu_op = A_OR;
                3'b111:  alu_op = A_AND;
                3'b001:  alu_op = A_SLL;
                default: alu_op = instr[30] ? A_SRA : A_SRL; // f3==101
            endcase
        end else begin
            alu_op = A_ADD; // load/store 地址计算, jalr 基址相加等
        end
    end

    // ---- ALU ----
    reg [31:0] alu_y;
    always @(*) begin
        case (alu_op)
            A_ADD:   alu_y = alu_a + alu_b;
            A_SUB:   alu_y = alu_a - alu_b;
            A_AND:   alu_y = alu_a & alu_b;
            A_OR:    alu_y = alu_a | alu_b;
            A_XOR:   alu_y = alu_a ^ alu_b;
            A_SLL:   alu_y = alu_a << alu_b[4:0];
            A_SRL:   alu_y = alu_a >> alu_b[4:0];
            A_SRA:   alu_y = $signed(alu_a) >>> alu_b[4:0];
            A_SLT:   alu_y = ($signed(alu_a) < $signed(alu_b)) ? 32'd1 : 32'd0;
            A_SLTU:  alu_y = (alu_a < alu_b) ? 32'd1 : 32'd0;
            default: alu_y = 32'b0;
        endcase
    end

    // ---- 数据存储 (组合读, 时钟沿写) ----
    wire [7:0]  dmem_idx = alu_y[9:2];
    wire [31:0] dmem_rd  = dmem[dmem_idx];

    // ---- 写回结果选择 ----
    wire [31:0] result =
        (opcode==OP_LUI)                     ? u_imm        :
        (opcode==OP_AUIPC)                   ? (pc + u_imm) :
        (opcode==OP_JAL || opcode==OP_JALR)  ? pc_plus4     :
        (opcode==OP_LOAD)                    ? dmem_rd      :
        alu_y;

    wire reg_write = (opcode==OP_LUI)||(opcode==OP_AUIPC)||(opcode==OP_JAL)||
                     (opcode==OP_JALR)||(opcode==OP_LOAD)||(opcode==OP_REG)||(opcode==OP_IMM);
    wire mem_write = (opcode==OP_STORE);

    // ---- 分支判断 ----
    reg branch_taken;
    always @(*) begin
        branch_taken = 1'b0;
        if (opcode==OP_BR) begin
            case (f3)
                3'b000:  branch_taken = (rs1_v == rs2_v);                 // beq
                3'b001:  branch_taken = (rs1_v != rs2_v);                 // bne
                3'b100:  branch_taken = ($signed(rs1_v) <  $signed(rs2_v)); // blt
                3'b101:  branch_taken = ($signed(rs1_v) >= $signed(rs2_v)); // bge
                3'b110:  branch_taken = (rs1_v <  rs2_v);                 // bltu
                default: branch_taken = (rs1_v >= rs2_v);                 // bgeu (f3==111)
            endcase
        end
    end

    // ---- 下一条 PC ----
    wire [31:0] pc_next =
        (opcode==OP_JAL)  ? (pc + j_imm)                  :
        (opcode==OP_JALR) ? ((rs1_v + i_imm) & ~32'h1)    :
        (branch_taken)    ? (pc + b_imm)                  :
        pc_plus4;

    // ---- 时序更新 ----
    always @(posedge clk) begin
        if (rst) begin
            pc <= 32'b0;
        end else begin
            pc <= pc_next;
            if (reg_write && rd != 5'b0) regs[rd] <= result;
            if (mem_write)               dmem[dmem_idx] <= rs2_v;
        end
    end
endmodule
