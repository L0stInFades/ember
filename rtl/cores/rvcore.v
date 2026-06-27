`timescale 1ns/1ps
// ===========================================================================
// rvcore: 单周期 RV32IM + Zicsr + M态陷阱 的"能用"处理器核
//   - 完整 RV32I + M(乘除) + Zicsr(CSR) + ECALL/EBREAK/MRET + 非法指令陷阱
//   - 机器态定时器中断 (内置 CLINT: mtime/mtimecmp)
//   - 片上统一 RAM(128KB, 取指/数据共享), 子字访存(lb/lh/lw/sb/sh/...)
//   - MMIO 通过输出端口外露: UART 发送 / 退出
//   单周期 => 精确异常天然成立(每条指令要么完成要么整体陷阱)
// ===========================================================================
module rvcore #(parameter MEMFILE="prog.hex", parameter MEMWORDS=32768)(
    input  wire        clk,
    input  wire        rst,
    output reg         uart_we,      // 写 UART(一个字符)
    output reg  [7:0]  uart_data,
    output reg         halt,         // 写退出寄存器 => 停机
    output reg  [31:0] exit_code,
    output wire [31:0] dbg_pc
);
    // -------------------- 存储 --------------------
    integer i;
    localparam AW = $clog2(MEMWORDS);   // 字地址位宽(令综合推断出正确大小的存储)
    reg [31:0] mem [0:MEMWORDS-1];
    initial begin
`ifdef SIM_INIT
        for (i=0;i<MEMWORDS;i=i+1) mem[i]=32'd0;
        $readmemh(MEMFILE, mem);
`endif
    end

    // -------------------- 体系结构状态 --------------------
    reg [31:0] pc;
    reg [31:0] regs [0:31];
    initial begin pc=0; for (i=0;i<32;i=i+1) regs[i]=0; end
    assign dbg_pc = pc;

    // CSR (机器态最小集)
    reg [31:0] mstatus, mtvec, mscratch, mepc, mcause, mtval, mie, mip;
    reg [63:0] mtime, mtimecmp, mcycle, minstret;
    localparam MIE_BIT=3, MPIE_BIT=7;        // mstatus
    localparam MTIE_BIT=7, MTIP_BIT=7;       // mie/mip 定时器
    initial begin mstatus=0;mtvec=0;mscratch=0;mepc=0;mcause=0;mtval=0;mie=0;mip=0;
                  mtime=0;mtimecmp=64'hffffffffffffffff;mcycle=0;minstret=0; end

    // -------------------- 取指 + 译码 --------------------
    wire [31:0] instr = mem[pc[AW+1:2]];
    wire [6:0]  opc = instr[6:0];
    wire [4:0]  rd  = instr[11:7], rs1=instr[19:15], rs2=instr[24:20];
    wire [2:0]  f3  = instr[14:12];
    wire [6:0]  f7  = instr[31:25];
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
                     LOAD=7'h03,STORE=7'h23,OPIMM=7'h13,OP=7'h33,SYSTEM=7'h73,FENCE=7'h0f;

    // -------------------- ALU --------------------
    reg [31:0] aluout;
    wire [31:0] ai = rv1;
    wire [31:0] bi = (opc==OPIMM) ? immI : rv2;
    wire [4:0]  sh = (opc==OPIMM) ? immI[4:0] : rv2[4:0];
    wire signed [31:0] ai_s = ai;
    wire [31:0] sra_res = ai_s >>> sh;   // 自决有符号上下文 => 真算术右移
    wire [31:0] srl_res = ai   >>  sh;
    wire [31:0] slt_res = ($signed(ai) < $signed(bi)) ? 32'd1 : 32'd0;
    always @(*) begin
        case (f3)
            3'b000: aluout = (opc==OP && f7[5]) ? (ai - bi) : (ai + bi);
            3'b001: aluout = ai << sh;
            3'b010: aluout = slt_res;
            3'b011: aluout = (ai < bi) ? 32'd1 : 32'd0;
            3'b100: aluout = ai ^ bi;
            3'b101: aluout = f7[5] ? sra_res : srl_res;
            3'b110: aluout = ai | bi;
            default:aluout = ai & bi;
        endcase
    end

    // -------------------- M 扩展: 乘法组合, 除法多周期 --------------------
    wire signed [31:0] sa = rv1, sb = rv2;
    wire [63:0] mul_ss = sa * sb;
    wire [63:0] mul_uu = rv1 * rv2;
    wire [63:0] mul_su = $signed({{32{rv1[31]}},rv1}) * $signed({1'b0,rv2});
    wire ov   = ((f3==3'b100)||(f3==3'b110)) && (rv1==32'h80000000 && rv2==32'hffffffff);  // 仅有符号 DIV/REM 溢出特例
    wire divz = (rv2==32'd0);
    // 多周期无符号除法器(32 步), 有符号在外层取绝对值+修正
    wire dsign = (opc==OP) && f7[0] && ((f3==3'b100)||(f3==3'b110)); // DIV/REM
    wire [31:0] a_abs = rv1[31] ? (~rv1+32'd1) : rv1;
    wire [31:0] b_abs = rv2[31] ? (~rv2+32'd1) : rv2;
    wire [31:0] u_a = dsign ? a_abs : rv1;
    wire [31:0] u_b = dsign ? b_abs : rv2;
    wire div_req = (opc==OP) && f7[0] && f3[2] && !divz && !ov;  // 需要迭代单元
    wire div_busy, div_done;  wire [31:0] uq, ur;
    wire div_start = div_req && !div_busy && !div_done;
    divunit du(.clk(clk), .start(div_start), .a_in(u_a), .b_in(u_b),
               .quo(uq), .rem(ur), .busy(div_busy), .done(div_done));
    wire qneg = dsign & (rv1[31]^rv2[31]);
    wire rneg = dsign & rv1[31];
    wire [31:0] q_fixed = qneg ? (~uq+32'd1) : uq;
    wire [31:0] r_fixed = rneg ? (~ur+32'd1) : ur;
    wire stall = div_req && !div_done;     // 除法进行中冻结流水
    reg [31:0] mout;
    always @(*) begin
        case (f3)
            3'b000: mout = mul_ss[31:0];                 // MUL
            3'b001: mout = mul_ss[63:32];                // MULH
            3'b010: mout = mul_su[63:32];                // MULHSU
            3'b011: mout = mul_uu[63:32];                // MULHU
            3'b100: mout = divz ? 32'hffffffff : ov ? 32'h80000000 : q_fixed;     // DIV
            3'b101: mout = divz ? 32'hffffffff : q_fixed;                          // DIVU
            3'b110: mout = divz ? rv1 : ov ? 32'h0 : r_fixed;                      // REM
            default:mout = divz ? rv1 : r_fixed;                                   // REMU
        endcase
    end
    wire is_muldiv = (opc==OP) && f7[0];   // funct7=0000001

    // -------------------- 分支判断 --------------------
    reg branch_taken;
    always @(*) begin
        case (f3)
            3'b000: branch_taken = (rv1==rv2);
            3'b001: branch_taken = (rv1!=rv2);
            3'b100: branch_taken = ($signed(rv1) < $signed(rv2));
            3'b101: branch_taken = ($signed(rv1) >= $signed(rv2));
            3'b110: branch_taken = (rv1 < rv2);
            3'b111: branch_taken = (rv1 >= rv2);
            default:branch_taken = 1'b0;
        endcase
    end

    // -------------------- 访存地址 + 子字 --------------------
    wire [31:0] addr = rv1 + (opc==STORE ? immS : immI);
    wire is_ram   = (addr[31:17]==15'd0);                  // 0x0..0x1FFFF
    wire is_clint = (addr[31:24]==8'h02);                  // 0x0200_0000
    wire is_uart  = (addr==32'h1000_0000);
    wire is_exit  = (addr==32'h1000_0004);
    wire [AW-1:0] widx = addr[AW+1:2];
    wire [31:0] ramword = mem[widx];
    // CLINT 读
    reg [31:0] clint_rd;
    always @(*) begin
        case (addr)
            32'h0200_4000: clint_rd = mtimecmp[31:0];
            32'h0200_4004: clint_rd = mtimecmp[63:32];
            32'h0200_BFF8: clint_rd = mtime[31:0];
            32'h0200_BFFC: clint_rd = mtime[63:32];
            default:       clint_rd = 32'd0;
        endcase
    end
    wire [31:0] memword = is_clint ? clint_rd : ramword;
    // 载入数据(按 funct3 + 偏移)
    reg [31:0] loaddata;
    wire [1:0] boff = addr[1:0];
    wire [7:0] lb = memword[boff*8 +: 8];
    wire [15:0] lh = memword[ (boff[1]?16:0) +: 16 ];
    always @(*) begin
        case (f3)
            3'b000: loaddata = {{24{lb[7]}}, lb};          // LB
            3'b001: loaddata = {{16{lh[15]}}, lh};         // LH
            3'b010: loaddata = memword;                    // LW
            3'b100: loaddata = {24'd0, lb};                // LBU
            3'b101: loaddata = {16'd0, lh};                // LHU
            default:loaddata = memword;
        endcase
    end
    // 存储字(读改写)
    reg [31:0] storeword;
    always @(*) begin
        storeword = ramword;
        case (f3)
            3'b000: storeword[boff*8 +: 8] = rv2[7:0];                 // SB
            3'b001: if (boff[1]) storeword[31:16]=rv2[15:0]; else storeword[15:0]=rv2[15:0]; // SH
            default:storeword = rv2;                                   // SW
        endcase
    end

    // -------------------- CSR 读 --------------------
    reg [31:0] csr_rdata;
    always @(*) begin
        case (csr_addr)
            12'h300: csr_rdata = mstatus;
            12'h301: csr_rdata = 32'h4000_0100;          // misa: RV32IM (MXL=1, I+M)
            12'h304: csr_rdata = mie;
            12'h305: csr_rdata = mtvec;
            12'h340: csr_rdata = mscratch;
            12'h341: csr_rdata = mepc;
            12'h342: csr_rdata = mcause;
            12'h343: csr_rdata = mtval;
            12'h344: csr_rdata = mip;
            12'hF14: csr_rdata = 32'd0;                   // mhartid=0
            12'hB00,12'hC00: csr_rdata = mcycle[31:0];
            12'hB80,12'hC80: csr_rdata = mcycle[63:32];
            12'hB02,12'hC02: csr_rdata = minstret[31:0];
            12'hB82,12'hC82: csr_rdata = minstret[63:32];
            default: csr_rdata = 32'd0;
        endcase
    end
    reg [31:0] csr_wval;
    wire [31:0] csr_src = f3[2] ? {27'd0, zimm} : rv1;   // CSRxxI 用立即数
    always @(*) begin
        case (f3[1:0])
            2'b01: csr_wval = csr_src;                    // CSRRW
            2'b10: csr_wval = csr_rdata | csr_src;        // CSRRS
            2'b11: csr_wval = csr_rdata & ~csr_src;       // CSRRC
            default: csr_wval = csr_rdata;
        endcase
    end
    wire csr_we = (opc==SYSTEM) && (f3!=3'b000) &&
                  !((f3[1:0]==2'b10||f3[1:0]==2'b11) && rs1==5'd0); // CSRRS/C rs1=0 => 只读

    // -------------------- 指令分类 + 合法性 --------------------
    wire is_ecall  = (opc==SYSTEM)&&(f3==0)&&(instr[31:20]==12'h000);
    wire is_ebreak = (opc==SYSTEM)&&(f3==0)&&(instr[31:20]==12'h001);
    wire is_mret   = (opc==SYSTEM)&&(f3==0)&&(instr[31:20]==12'h302);
    wire is_csr    = (opc==SYSTEM)&&(f3!=0);
    reg legal;
    always @(*) begin
        case (opc)
            LUI,AUIPC,JAL,JALR,BR,LOAD,STORE,OPIMM,FENCE: legal=1'b1;
            OP:     legal = (f7==7'h00)||(f7==7'h20)||(f7==7'h01);   // base/sub-sra/muldiv
            SYSTEM: legal = is_ecall||is_ebreak||is_mret||is_csr;
            default: legal = 1'b0;
        endcase
    end
    wire exc_illegal = !legal;

    // -------------------- 写回值选择 --------------------
    reg [31:0] wbval; reg wb_en;
    always @(*) begin
        wb_en = 1'b0; wbval = 32'd0;
        case (opc)
            LUI:   begin wb_en=1; wbval=immU; end
            AUIPC: begin wb_en=1; wbval=pc+immU; end
            JAL:   begin wb_en=1; wbval=pc+4; end
            JALR:  begin wb_en=1; wbval=pc+4; end
            LOAD:  begin wb_en=1; wbval=loaddata; end
            OPIMM: begin wb_en=1; wbval=aluout; end
            OP:    begin wb_en=1; wbval= is_muldiv ? mout : aluout; end
            SYSTEM:if (is_csr) begin wb_en=1; wbval=csr_rdata; end
            default:;
        endcase
    end

    // -------------------- 下一PC --------------------
    wire [31:0] pc4 = pc + 32'd4;
    reg [31:0] pcnext;
    always @(*) begin
        case (opc)
            JAL:  pcnext = pc + immJ;
            JALR: pcnext = (rv1 + immI) & ~32'h1;
            BR:   pcnext = branch_taken ? (pc + immB) : pc4;
            default: pcnext = pc4;
        endcase
    end

    // -------------------- 陷阱判定 --------------------
    wire timer_pending = mip[MTIP_BIT] & mie[MTIE_BIT] & mstatus[MIE_BIT];
    wire take_interrupt = timer_pending;
    wire take_exception = exc_illegal || is_ecall || is_ebreak;
    wire trap = take_interrupt || take_exception;
    reg [31:0] trap_cause, trap_tval;
    always @(*) begin
        if (take_interrupt)      begin trap_cause=32'h8000_0007; trap_tval=32'd0; end           // M定时器中断
        else if (exc_illegal)    begin trap_cause=32'd2;         trap_tval=instr; end            // 非法指令
        else if (is_ecall)       begin trap_cause=32'd11;        trap_tval=32'd0; end            // M态 ECALL
        else                     begin trap_cause=32'd3;         trap_tval=32'd0; end            // EBREAK
    end

    // -------------------- MMIO 输出(组合 valid, 时序见下) --------------------
    wire do_store = (opc==STORE) && !trap;
    wire store_uart = do_store && is_uart;
    wire store_exit = do_store && is_exit;

    // -------------------- 时序更新 --------------------
    always @(posedge clk) begin
        // 默认
        uart_we <= 1'b0; halt <= 1'b0;
        // 计时器
        mtime  <= mtime + 64'd1;
        mcycle <= mcycle + 64'd1;
        mip[MTIP_BIT] <= (mtime + 64'd1) >= mtimecmp;

        if (rst) begin
            pc <= 32'd0; mstatus<=0; mie<=0; mip<=0; mepc<=0; mcause<=0; mtval<=0; mtvec<=0;
            mtime<=0; mtimecmp<=64'hffffffffffffffff; mcycle<=0; minstret<=0; halt<=0; uart_we<=0;
        end else if (stall) begin
            // 除法进行中: 冻结 pc/寄存器/CSR(定时器仍递增, 中断推迟到除法完成)
        end else if (trap) begin
            // 进入陷阱
            mepc   <= pc;
            mcause <= trap_cause;
            mtval  <= trap_tval;
            mstatus[MPIE_BIT] <= mstatus[MIE_BIT];
            mstatus[MIE_BIT]  <= 1'b0;
            mstatus[12:11]    <= 2'b11;             // MPP=M
            pc <= {mtvec[31:2], 2'b00};             // direct 模式
        end else if (is_mret) begin
            mstatus[MIE_BIT]  <= mstatus[MPIE_BIT];
            mstatus[MPIE_BIT] <= 1'b1;
            pc <= mepc;
            minstret <= minstret + 64'd1;
        end else begin
            // 正常执行
            if (wb_en && rd!=5'd0) regs[rd] <= wbval;
            // 存储
            if (do_store && is_ram) mem[widx] <= storeword;
            if (do_store && is_clint) begin
                case (addr)
                    32'h0200_4000: mtimecmp[31:0]  <= rv2;
                    32'h0200_4004: mtimecmp[63:32] <= rv2;
                    32'h0200_BFF8: mtime[31:0]     <= rv2;
                    32'h0200_BFFC: mtime[63:32]    <= rv2;
                    default: ;
                endcase
            end
            if (store_uart) begin uart_we <= 1'b1; uart_data <= rv2[7:0]; end
            if (store_exit) begin halt <= 1'b1; exit_code <= rv2; end
            // CSR 写
            if (csr_we) begin
                case (csr_addr)
                    12'h300: mstatus  <= csr_wval;
                    12'h304: mie      <= csr_wval;
                    12'h305: mtvec    <= csr_wval;
                    12'h340: mscratch <= csr_wval;
                    12'h341: mepc     <= csr_wval;
                    12'h342: mcause   <= csr_wval;
                    12'h343: mtval    <= csr_wval;
                    12'h344: mip[MTIP_BIT] <= csr_wval[MTIP_BIT];
                    default: ;
                endcase
            end
            pc <= pcnext;
            minstret <= minstret + 64'd1;
        end
    end
endmodule

// ===========================================================================
// divunit: 多周期无符号 32/32 除法(恢复法, 32 步)
//   start 脉冲启动; busy 期间运算; done 拉高一拍且此时 quo/rem 有效
// ===========================================================================
module divunit(
    input  wire        clk,
    input  wire        start,
    input  wire [31:0] a_in,    // 被除数(无符号)
    input  wire [31:0] b_in,    // 除数(无符号, 非0)
    output wire [31:0] quo,
    output wire [31:0] rem,
    output reg         busy,
    output reg         done
);
    reg [31:0] a, b, q;
    reg [32:0] r;
    reg [5:0]  cnt;
    wire [32:0] rsh = {r[31:0], a[31]};       // 余数左移并移入被除数次高位
    wire        ge  = (rsh >= {1'b0, b});
    assign quo = q;
    assign rem = r[31:0];
    initial begin busy=1'b0; done=1'b0; a=0; b=0; q=0; r=0; cnt=0; end
    always @(posedge clk) begin
        done <= 1'b0;
        if (start && !busy) begin
            a <= a_in; b <= b_in; q <= 32'd0; r <= 33'd0; cnt <= 6'd0; busy <= 1'b1;
        end else if (busy) begin
            r <= ge ? (rsh - {1'b0, b}) : rsh;
            q <= {q[30:0], ge};
            a <= {a[30:0], 1'b0};
            cnt <= cnt + 6'd1;
            if (cnt == 6'd31) begin busy <= 1'b0; done <= 1'b1; end
        end
    end
endmodule
