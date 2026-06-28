`timescale 1ns/1ps
// ===========================================================================
// 乱序核 (Tomasulo + ROB)  最终版: 2宽超标量乱序
//   寄存器重命名(RAT) + 16项 ROB + 8项发射队列(RS) + 双CDB + 顺序双提交
//   2宽派遣 / 2 FU双发射 / 乱序发射 / 顺序提交
//   分支投机(BHT) + 误预测 ROB 冲刷 + RAT 重建恢复
//   load/store 顺序访存(store提交时写, load到ROB头读)
//   FU1 不解析控制(分支/JALR只在 FU0); 每周期至多1次内存读+1次误预测
// ===========================================================================

// ---------------- 译码模块 ----------------
module odecode(
    input  wire [31:0] ins,
    output wire [4:0]  rd, rs1, rs2,
    output wire [2:0]  f3,
    output reg  [3:0]  aluop,
    output reg  [1:0]  asel,
    output reg         bsel, we, u1, u2,
    output reg  [2:0]  kind,            // 0=alu 1=branch 2=jal 3=jalr 4=load 5=store
    output reg  [31:0] imm
);
    localparam [3:0] A_ADD=0,A_SUB=1,A_AND=2,A_OR=3,A_XOR=4,A_SLL=5,A_SRL=6,A_SRA=7,A_SLT=8,A_SLTU=9;
    localparam [6:0] OP_LUI=7'h37,OP_AUIPC=7'h17,OP_JAL=7'h6f,OP_JALR=7'h67,
                     OP_BR=7'h63,OP_LOAD=7'h03,OP_STORE=7'h23,OP_IMM=7'h13,OP_REG=7'h33;
    assign rd=ins[11:7]; assign rs1=ins[19:15]; assign rs2=ins[24:20]; assign f3=ins[14:12];
    wire f7b=ins[30];
    wire [31:0] i_imm={{20{ins[31]}},ins[31:20]};
    wire [31:0] s_imm={{20{ins[31]}},ins[31:25],ins[11:7]};
    wire [31:0] b_imm={{19{ins[31]}},ins[31],ins[7],ins[30:25],ins[11:8],1'b0};
    wire [31:0] u_imm={ins[31:12],12'b0};
    wire [31:0] j_imm={{11{ins[31]}},ins[31],ins[19:12],ins[20],ins[30:21],1'b0};
    always @(*) begin
        aluop=A_ADD; asel=2'd0; bsel=0; we=0; u1=0; u2=0; kind=3'd0; imm=32'd0;
        case (ins[6:0])
            OP_REG: begin we=1;u1=1;u2=1;
                case (f3)
                    3'b000:aluop=f7b?A_SUB:A_ADD; 3'b001:aluop=A_SLL; 3'b010:aluop=A_SLT;
                    3'b011:aluop=A_SLTU; 3'b100:aluop=A_XOR; 3'b101:aluop=f7b?A_SRA:A_SRL;
                    3'b110:aluop=A_OR; default:aluop=A_AND;
                endcase end
            OP_IMM: begin we=1;bsel=1;u1=1;imm=i_imm;
                case (f3)
                    3'b000:aluop=A_ADD; 3'b010:aluop=A_SLT; 3'b011:aluop=A_SLTU; 3'b100:aluop=A_XOR;
                    3'b110:aluop=A_OR; 3'b111:aluop=A_AND; 3'b001:aluop=A_SLL; default:aluop=f7b?A_SRA:A_SRL;
                endcase end
            OP_LUI:   begin we=1;asel=2'd2;bsel=1;imm=u_imm; end
            OP_AUIPC: begin we=1;asel=2'd1;bsel=1;imm=u_imm; end
            OP_BR:    begin kind=3'd1;u1=1;u2=1;imm=b_imm; end
            OP_JAL:   begin we=1;kind=3'd2;imm=j_imm; end
            OP_JALR:  begin we=1;kind=3'd3;bsel=1;u1=1;imm=i_imm; end
            OP_LOAD:  begin we=1;kind=3'd4;bsel=1;u1=1;imm=i_imm; end
            OP_STORE: begin kind=3'd5;bsel=1;u1=1;u2=1;imm=s_imm; end
            default: ;
        endcase
    end
endmodule

// ---------------- 乱序核 ----------------
module cpu_ooo #(parameter MEMFILE="prog.hex")(
    input  wire        clk, rst,
    input  wire        imem_we,
    input  wire [7:0]  imem_waddr,
    input  wire [31:0] imem_wdata,
    output reg  [31:0] dbg_x10, dbg_pc
);
    integer i;
    reg [31:0] regs[0:31], imem[0:255], dmem[0:255];
    initial begin
        for (i=0;i<32;i=i+1) regs[i]=0;
        for (i=0;i<256;i=i+1) begin imem[i]=0; dmem[i]=0; end
`ifdef SIM_INIT
        $readmemh(MEMFILE, imem);
`endif
    end
    always @(posedge clk) if (imem_we) imem[imem_waddr] <= imem_wdata;

    reg [31:0] pc;
    reg        stall_ctrl;

    // RAT / ROB / RS / BHT
    reg        rat_busy[0:31]; reg [3:0] rat_tag[0:31];
    reg        rob_busy[0:15], rob_done[0:15], rob_we[0:15], rob_isload[0:15], rob_isstore[0:15], rob_addrok[0:15];
    reg [4:0]  rob_rd[0:15];
    reg [31:0] rob_val[0:15], rob_addr[0:15], rob_stdata[0:15];
    reg [3:0]  rob_head, rob_tail; reg [4:0] rob_count;
    reg        rs_busy[0:7]; reg [2:0] rs_kind[0:7]; reg [3:0] rs_op[0:7];
    reg [31:0] rs_vj[0:7], rs_vk[0:7], rs_imm[0:7], rs_pc[0:7];
    reg [3:0]  rs_qj[0:7], rs_qk[0:7]; reg rs_qjv[0:7], rs_qkv[0:7];
    reg [3:0]  rs_dest[0:7]; reg [1:0] rs_asel[0:7]; reg rs_bsel[0:7]; reg [2:0] rs_f3[0:7];
    reg        rs_pred[0:7]; reg [5:0] rs_bidx[0:7];
    reg [1:0]  bht[0:63];

    // ---------------- 函数 ----------------
    function [31:0] alu; input [3:0] o; input [31:0] x,y; begin
        case (o)
            4'd0:alu=x+y; 4'd1:alu=x-y; 4'd2:alu=x&y; 4'd3:alu=x|y; 4'd4:alu=x^y;
            4'd5:alu=x<<y[4:0]; 4'd6:alu=x>>y[4:0]; 4'd7:alu=$signed(x)>>>y[4:0];
            4'd8:alu=($signed(x)<$signed(y))?32'd1:32'd0; 4'd9:alu=(x<y)?32'd1:32'd0; default:alu=0;
        endcase end
    endfunction
    function cond; input [2:0] f; input [31:0] x,y; begin
        case (f)
            3'b000:cond=(x==y); 3'b001:cond=(x!=y); 3'b100:cond=($signed(x)<$signed(y));
            3'b101:cond=($signed(x)>=$signed(y)); 3'b110:cond=(x<y); default:cond=(x>=y);
        endcase end
    endfunction
    function prod; input [2:0] kk; prod=(kk==3'd0)||(kk==3'd2)||(kk==3'd3); endfunction

    // ---------------- 译码 2 路 ----------------
    wire [31:0] ins0 = imem[pc[9:2]];
    wire [31:0] ins1 = imem[pc[9:2]+8'd1];
    wire [4:0]  d0_rd,d0_rs1,d0_rs2,d1_rd,d1_rs1,d1_rs2; wire [2:0] d0_f3,d1_f3;
    wire [3:0]  d0_aluop,d1_aluop; wire [1:0] d0_asel,d1_asel;
    wire        d0_bsel,d0_we,d0_u1,d0_u2,d1_bsel,d1_we,d1_u1,d1_u2; wire [2:0] d0_kind,d1_kind;
    wire [31:0] d0_imm,d1_imm;
    odecode dec0(.ins(ins0),.rd(d0_rd),.rs1(d0_rs1),.rs2(d0_rs2),.f3(d0_f3),.aluop(d0_aluop),
        .asel(d0_asel),.bsel(d0_bsel),.we(d0_we),.u1(d0_u1),.u2(d0_u2),.kind(d0_kind),.imm(d0_imm));
    odecode dec1(.ins(ins1),.rd(d1_rd),.rs1(d1_rs1),.rs2(d1_rs2),.f3(d1_f3),.aluop(d1_aluop),
        .asel(d1_asel),.bsel(d1_bsel),.we(d1_we),.u1(d1_u1),.u2(d1_u2),.kind(d1_kind),.imm(d1_imm));
    wire d0_ctrl = (d0_kind==3'd1)||(d0_kind==3'd2)||(d0_kind==3'd3);
    wire d1_ctrl = (d1_kind==3'd1)||(d1_kind==3'd2)||(d1_kind==3'd3);

    // ---------------- 空闲 RS (2) ----------------
    reg [3:0] frs0,frs1; reg fr0,fr1; integer s;
    always @(*) begin
        frs0=0;fr0=0;frs1=0;fr1=0;
        for (s=0;s<8;s=s+1) if (!rs_busy[s]) begin
            if (!fr0) begin frs0=s[3:0];fr0=1; end
            else if (!fr1) begin frs1=s[3:0];fr1=1; end
        end
    end
    wire can_disp1 = !stall_ctrl && (rob_count<5'd16) && fr0;
    wire can_disp2 = !stall_ctrl && (rob_count<5'd15) && fr1;

    // ---------------- 就绪 RS (2); FU1 不收分支/JALR ----------------
    reg [3:0] iss0,iss1; reg issf0,issf1; integer t;
    always @(*) begin
        iss0=0;issf0=0;iss1=0;issf1=0;
        for (t=0;t<8;t=t+1) if (rs_busy[t]&&!rs_qjv[t]&&!rs_qkv[t]) begin
            if (!issf0) begin iss0=t[3:0];issf0=1; end
            else if (!issf1 && rs_kind[t]!=3'd1 && rs_kind[t]!=3'd3) begin iss1=t[3:0];issf1=1; end
        end
    end

    // ---------------- 执行 (两 FU 组合) ----------------
    wire [31:0] ex0_in1=(rs_asel[iss0]==2'd1)?rs_pc[iss0]:(rs_asel[iss0]==2'd2)?32'd0:rs_vj[iss0];
    wire [31:0] ex0_in2=rs_bsel[iss0]?rs_imm[iss0]:rs_vk[iss0];
    wire [31:0] ex0_res=alu(rs_op[iss0],ex0_in1,ex0_in2);
    wire        ex0_btaken=cond(rs_f3[iss0],rs_vj[iss0],rs_vk[iss0]);
    wire [31:0] ex0_target=(rs_kind[iss0]==3'd3)?((rs_vj[iss0]+rs_imm[iss0])&~32'h1):(rs_pc[iss0]+rs_imm[iss0]);
    wire [31:0] ex0_wbval=(rs_kind[iss0]==3'd2||rs_kind[iss0]==3'd3)?(rs_pc[iss0]+32'd4):ex0_res;
    wire [31:0] ex1_in1=(rs_asel[iss1]==2'd1)?rs_pc[iss1]:(rs_asel[iss1]==2'd2)?32'd0:rs_vj[iss1];
    wire [31:0] ex1_in2=rs_bsel[iss1]?rs_imm[iss1]:rs_vk[iss1];
    wire [31:0] ex1_res=alu(rs_op[iss1],ex1_in1,ex1_in2);
    wire [31:0] ex1_wbval=(rs_kind[iss1]==3'd2)?(rs_pc[iss1]+32'd4):ex1_res;

    // 本周期 CDB (a=FU0, b=FU1, ldhead=load到头)
    wire        cdb_a_v=issf0&&prod(rs_kind[iss0]); wire [3:0] cdb_a_tag=rs_dest[iss0]; wire [31:0] cdb_a_val=ex0_wbval;
    wire        cdb_b_v=issf1&&prod(rs_kind[iss1]); wire [3:0] cdb_b_tag=rs_dest[iss1]; wire [31:0] cdb_b_val=ex1_wbval;
    wire        ldhead_fire=rob_busy[rob_head]&&rob_isload[rob_head]&&rob_addrok[rob_head]&&!rob_done[rob_head];
    wire [31:0] ldhead_val=dmem[rob_addr[rob_head][9:2]];

    // 误预测 (仅 FU0 分支)
    wire        iss_mispred=issf0&&(rs_kind[iss0]==3'd1)&&(ex0_btaken!=rs_pred[iss0]);
    wire [3:0]  nyoung=rob_tail-rs_dest[iss0]-4'd1;
    wire [4:0]  ninflight={1'b0,(rs_dest[iss0]-rob_head)}+5'd1;

    // 提交数 / 派遣数
    wire c0=rob_busy[rob_head]&&rob_done[rob_head];
    wire c1=c0&&rob_busy[rob_head+4'd1]&&rob_done[rob_head+4'd1];
    wire [1:0] ncommit=c0?(c1?2'd2:2'd1):2'd0;
    wire [1:0] ndisp = !can_disp1 ? 2'd0 : d0_ctrl ? 2'd1 : can_disp2 ? 2'd2 : 2'd1;

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            pc<=0; stall_ctrl<=0; rob_head<=0; rob_tail<=0; rob_count<=0;
            for (k=0;k<32;k=k+1) begin rat_busy[k]<=0; rat_tag[k]<=0; end
            for (k=0;k<16;k=k+1) begin rob_busy[k]<=0;rob_done[k]<=0;rob_we[k]<=0;rob_rd[k]<=0;rob_isload[k]<=0;rob_isstore[k]<=0;rob_addrok[k]<=0; end
            for (k=0;k<8;k=k+1)  begin rs_busy[k]<=0;rs_qjv[k]<=0;rs_qkv[k]<=0; end
            for (k=0;k<64;k=k+1) bht[k]<=2'b01;
        end else begin
            // ========== 1) 发射执行 FU0 ==========
            if (issf0) begin
                rs_busy[iss0]<=0;
                if (rs_kind[iss0]==3'd4) begin rob_addr[rs_dest[iss0]]<=ex0_res; rob_addrok[rs_dest[iss0]]<=1; end
                else if (rs_kind[iss0]==3'd5) begin rob_addr[rs_dest[iss0]]<=ex0_res; rob_stdata[rs_dest[iss0]]<=rs_vk[iss0]; rob_addrok[rs_dest[iss0]]<=1; rob_done[rs_dest[iss0]]<=1; end
                else begin
                    rob_val[rs_dest[iss0]]<=ex0_wbval; rob_done[rs_dest[iss0]]<=1;
                    if (rs_kind[iss0]==3'd3) begin pc<=ex0_target; stall_ctrl<=0; end
                    if (rs_kind[iss0]==3'd1) begin
                        if (ex0_btaken) begin if (bht[rs_bidx[iss0]]!=2'b11) bht[rs_bidx[iss0]]<=bht[rs_bidx[iss0]]+2'd1; end
                        else            begin if (bht[rs_bidx[iss0]]!=2'b00) bht[rs_bidx[iss0]]<=bht[rs_bidx[iss0]]-2'd1; end
                    end
                end
            end
            // ========== 1) 发射执行 FU1 (无控制解析) ==========
            if (issf1) begin
                rs_busy[iss1]<=0;
                if (rs_kind[iss1]==3'd4) begin rob_addr[rs_dest[iss1]]<=ex1_res; rob_addrok[rs_dest[iss1]]<=1; end
                else if (rs_kind[iss1]==3'd5) begin rob_addr[rs_dest[iss1]]<=ex1_res; rob_stdata[rs_dest[iss1]]<=rs_vk[iss1]; rob_addrok[rs_dest[iss1]]<=1; rob_done[rs_dest[iss1]]<=1; end
                else begin rob_val[rs_dest[iss1]]<=ex1_wbval; rob_done[rs_dest[iss1]]<=1; end
            end
            // ========== 1b) load 到 ROB 头读内存 ==========
            if (ldhead_fire) begin rob_val[rob_head]<=ldhead_val; rob_done[rob_head]<=1; end
            // ========== 唤醒 RS (检查 cdb_a/cdb_b/ldhead) ==========
            for (k=0;k<8;k=k+1) begin
                if (rs_busy[k]&&rs_qjv[k]) begin
                    if      (cdb_a_v&&rs_qj[k]==cdb_a_tag) begin rs_vj[k]<=cdb_a_val; rs_qjv[k]<=0; end
                    else if (cdb_b_v&&rs_qj[k]==cdb_b_tag) begin rs_vj[k]<=cdb_b_val; rs_qjv[k]<=0; end
                    else if (ldhead_fire&&rs_qj[k]==rob_head) begin rs_vj[k]<=ldhead_val; rs_qjv[k]<=0; end
                end
                if (rs_busy[k]&&rs_qkv[k]) begin
                    if      (cdb_a_v&&rs_qk[k]==cdb_a_tag) begin rs_vk[k]<=cdb_a_val; rs_qkv[k]<=0; end
                    else if (cdb_b_v&&rs_qk[k]==cdb_b_tag) begin rs_vk[k]<=cdb_b_val; rs_qkv[k]<=0; end
                    else if (ldhead_fire&&rs_qk[k]==rob_head) begin rs_vk[k]<=ldhead_val; rs_qkv[k]<=0; end
                end
            end

            // ========== 误预测恢复 (优先, 本周期不提交不派遣) ==========
            if (iss_mispred) begin
                pc<=ex0_btaken?(rs_pc[iss0]+rs_imm[iss0]):(rs_pc[iss0]+32'd4);
                stall_ctrl<=0; rob_tail<=rs_dest[iss0]+4'd1; rob_count<=ninflight;
                for (k=0;k<16;k=k+1)
                    if (((k[3:0]-rs_dest[iss0])>=4'd1)&&((k[3:0]-rs_dest[iss0])<=nyoung)) rob_busy[k]<=0;
                for (k=0;k<8;k=k+1)
                    if (rs_busy[k]&&((rs_dest[k]-rs_dest[iss0])>=4'd1)&&((rs_dest[k]-rs_dest[iss0])<=nyoung)) rs_busy[k]<=0;
                for (k=0;k<32;k=k+1) rat_busy[k]<=0;
                for (k=0;k<16;k=k+1)
                    if (k<ninflight)
                        if (rob_we[(rob_head+k[3:0])&4'hf]&&rob_rd[(rob_head+k[3:0])&4'hf]!=5'd0) begin
                            rat_busy[rob_rd[(rob_head+k[3:0])&4'hf]]<=1; rat_tag[rob_rd[(rob_head+k[3:0])&4'hf]]<=(rob_head+k[3:0])&4'hf;
                        end
            end else begin
                // ========== 2) 顺序提交 (至多2) ==========
                if (c0) begin
                    if (rob_isstore[rob_head]) dmem[rob_addr[rob_head][9:2]]<=rob_stdata[rob_head];
                    else if (rob_we[rob_head]&&rob_rd[rob_head]!=5'd0) regs[rob_rd[rob_head]]<=rob_val[rob_head];
                    if (!rob_isstore[rob_head]&&rat_busy[rob_rd[rob_head]]&&(rat_tag[rob_rd[rob_head]]==rob_head)) rat_busy[rob_rd[rob_head]]<=0;
                    rob_busy[rob_head]<=0;
                end
                if (c1) begin
                    if (rob_isstore[rob_head+4'd1]) dmem[rob_addr[rob_head+4'd1][9:2]]<=rob_stdata[rob_head+4'd1];
                    else if (rob_we[rob_head+4'd1]&&rob_rd[rob_head+4'd1]!=5'd0) regs[rob_rd[rob_head+4'd1]]<=rob_val[rob_head+4'd1];
                    if (!rob_isstore[rob_head+4'd1]&&rat_busy[rob_rd[rob_head+4'd1]]&&(rat_tag[rob_rd[rob_head+4'd1]]==(rob_head+4'd1))) rat_busy[rob_rd[rob_head+4'd1]]<=0;
                    rob_busy[rob_head+4'd1]<=0;
                end
                rob_head  <= rob_head + {2'b0,ncommit};
                rob_count <= rob_count - {3'b0,ncommit} + {3'b0,ndisp};

                // ========== 3) 派遣 (至多2) ==========
                // ---- slot0 ----
                if (ndisp>=2'd1) begin
                    rob_busy[rob_tail]<=1; rob_done[rob_tail]<=0; rob_we[rob_tail]<=d0_we; rob_rd[rob_tail]<=d0_rd;
                    rob_isload[rob_tail]<=(d0_kind==3'd4); rob_isstore[rob_tail]<=(d0_kind==3'd5); rob_addrok[rob_tail]<=0;
                    rs_busy[frs0]<=1; rs_kind[frs0]<=d0_kind; rs_op[frs0]<=d0_aluop; rs_imm[frs0]<=d0_imm;
                    rs_pc[frs0]<=pc; rs_dest[frs0]<=rob_tail; rs_asel[frs0]<=d0_asel; rs_bsel[frs0]<=d0_bsel; rs_f3[frs0]<=d0_f3;
                    rs_pred[frs0]<=(d0_kind==3'd1)?bht[pc[7:2]][1]:1'b0; rs_bidx[frs0]<=pc[7:2];
                    // rs1
                    if (!d0_u1||d0_rs1==5'd0) begin rs_vj[frs0]<=0; rs_qjv[frs0]<=0; end
                    else if (rat_busy[d0_rs1]) begin
                        if      (cdb_a_v&&cdb_a_tag==rat_tag[d0_rs1]) begin rs_vj[frs0]<=cdb_a_val; rs_qjv[frs0]<=0; end
                        else if (cdb_b_v&&cdb_b_tag==rat_tag[d0_rs1]) begin rs_vj[frs0]<=cdb_b_val; rs_qjv[frs0]<=0; end
                        else if (ldhead_fire&&rob_head==rat_tag[d0_rs1]) begin rs_vj[frs0]<=ldhead_val; rs_qjv[frs0]<=0; end
                        else if (rob_done[rat_tag[d0_rs1]]) begin rs_vj[frs0]<=rob_val[rat_tag[d0_rs1]]; rs_qjv[frs0]<=0; end
                        else begin rs_qj[frs0]<=rat_tag[d0_rs1]; rs_qjv[frs0]<=1; end
                    end else begin rs_vj[frs0]<=regs[d0_rs1]; rs_qjv[frs0]<=0; end
                    // rs2
                    if (!d0_u2||d0_rs2==5'd0) begin rs_vk[frs0]<=0; rs_qkv[frs0]<=0; end
                    else if (rat_busy[d0_rs2]) begin
                        if      (cdb_a_v&&cdb_a_tag==rat_tag[d0_rs2]) begin rs_vk[frs0]<=cdb_a_val; rs_qkv[frs0]<=0; end
                        else if (cdb_b_v&&cdb_b_tag==rat_tag[d0_rs2]) begin rs_vk[frs0]<=cdb_b_val; rs_qkv[frs0]<=0; end
                        else if (ldhead_fire&&rob_head==rat_tag[d0_rs2]) begin rs_vk[frs0]<=ldhead_val; rs_qkv[frs0]<=0; end
                        else if (rob_done[rat_tag[d0_rs2]]) begin rs_vk[frs0]<=rob_val[rat_tag[d0_rs2]]; rs_qkv[frs0]<=0; end
                        else begin rs_qk[frs0]<=rat_tag[d0_rs2]; rs_qkv[frs0]<=1; end
                    end else begin rs_vk[frs0]<=regs[d0_rs2]; rs_qkv[frs0]<=0; end
                    if (d0_we&&d0_rd!=5'd0) begin rat_busy[d0_rd]<=1; rat_tag[d0_rd]<=rob_tail; end
                end
                // ---- slot1 (依赖 slot0) ----
                if (ndisp>=2'd2) begin
                    rob_busy[rob_tail+4'd1]<=1; rob_done[rob_tail+4'd1]<=0; rob_we[rob_tail+4'd1]<=d1_we; rob_rd[rob_tail+4'd1]<=d1_rd;
                    rob_isload[rob_tail+4'd1]<=(d1_kind==3'd4); rob_isstore[rob_tail+4'd1]<=(d1_kind==3'd5); rob_addrok[rob_tail+4'd1]<=0;
                    rs_busy[frs1]<=1; rs_kind[frs1]<=d1_kind; rs_op[frs1]<=d1_aluop; rs_imm[frs1]<=d1_imm;
                    rs_pc[frs1]<=pc+32'd4; rs_dest[frs1]<=rob_tail+4'd1; rs_asel[frs1]<=d1_asel; rs_bsel[frs1]<=d1_bsel; rs_f3[frs1]<=d1_f3;
                    rs_pred[frs1]<=(d1_kind==3'd1)?bht[pc[7:2]+6'd1][1]:1'b0; rs_bidx[frs1]<=pc[7:2]+6'd1;
                    // rs1 (先查是否依赖 slot0)
                    if (!d1_u1||d1_rs1==5'd0) begin rs_vj[frs1]<=0; rs_qjv[frs1]<=0; end
                    else if (d0_we&&d0_rd!=5'd0&&d0_rd==d1_rs1) begin rs_qj[frs1]<=rob_tail; rs_qjv[frs1]<=1; end
                    else if (rat_busy[d1_rs1]) begin
                        if      (cdb_a_v&&cdb_a_tag==rat_tag[d1_rs1]) begin rs_vj[frs1]<=cdb_a_val; rs_qjv[frs1]<=0; end
                        else if (cdb_b_v&&cdb_b_tag==rat_tag[d1_rs1]) begin rs_vj[frs1]<=cdb_b_val; rs_qjv[frs1]<=0; end
                        else if (ldhead_fire&&rob_head==rat_tag[d1_rs1]) begin rs_vj[frs1]<=ldhead_val; rs_qjv[frs1]<=0; end
                        else if (rob_done[rat_tag[d1_rs1]]) begin rs_vj[frs1]<=rob_val[rat_tag[d1_rs1]]; rs_qjv[frs1]<=0; end
                        else begin rs_qj[frs1]<=rat_tag[d1_rs1]; rs_qjv[frs1]<=1; end
                    end else begin rs_vj[frs1]<=regs[d1_rs1]; rs_qjv[frs1]<=0; end
                    // rs2
                    if (!d1_u2||d1_rs2==5'd0) begin rs_vk[frs1]<=0; rs_qkv[frs1]<=0; end
                    else if (d0_we&&d0_rd!=5'd0&&d0_rd==d1_rs2) begin rs_qk[frs1]<=rob_tail; rs_qkv[frs1]<=1; end
                    else if (rat_busy[d1_rs2]) begin
                        if      (cdb_a_v&&cdb_a_tag==rat_tag[d1_rs2]) begin rs_vk[frs1]<=cdb_a_val; rs_qkv[frs1]<=0; end
                        else if (cdb_b_v&&cdb_b_tag==rat_tag[d1_rs2]) begin rs_vk[frs1]<=cdb_b_val; rs_qkv[frs1]<=0; end
                        else if (ldhead_fire&&rob_head==rat_tag[d1_rs2]) begin rs_vk[frs1]<=ldhead_val; rs_qkv[frs1]<=0; end
                        else if (rob_done[rat_tag[d1_rs2]]) begin rs_vk[frs1]<=rob_val[rat_tag[d1_rs2]]; rs_qkv[frs1]<=0; end
                        else begin rs_qk[frs1]<=rat_tag[d1_rs2]; rs_qkv[frs1]<=1; end
                    end else begin rs_vk[frs1]<=regs[d1_rs2]; rs_qkv[frs1]<=0; end
                    if (d1_we&&d1_rd!=5'd0) begin rat_busy[d1_rd]<=1; rat_tag[d1_rd]<=rob_tail+4'd1; end
                end
                rob_tail <= rob_tail + {2'b0,ndisp};

                // ========== PC 推进 ==========
                if (ndisp==2'd1 && d0_ctrl) begin
                    if (d0_kind==3'd2)      pc<=pc+d0_imm;                                  // JAL
                    else if (d0_kind==3'd1) pc<=bht[pc[7:2]][1]?(pc+d0_imm):(pc+32'd4);     // 分支预测
                    else                    stall_ctrl<=1;                                  // JALR
                end else if (ndisp==2'd2 && d1_ctrl) begin
                    if (d1_kind==3'd2)      pc<=(pc+32'd4)+d1_imm;
                    else if (d1_kind==3'd1) pc<=bht[pc[7:2]+6'd1][1]?((pc+32'd4)+d1_imm):(pc+32'd8);
                    else                    stall_ctrl<=1;
                end else if (ndisp==2'd2) pc<=pc+32'd8;
                else if (ndisp==2'd1)     pc<=pc+32'd4;
            end
        end
    end

`ifdef SIM_INIT
    reg [31:0] cyc_count, instr_retired, mispredict_count;
    always @(posedge clk) begin
        if (rst) begin cyc_count<=0; instr_retired<=0; mispredict_count<=0; end
        else begin
            cyc_count<=cyc_count+32'd1;
            if (!iss_mispred) instr_retired<=instr_retired+{30'b0,ncommit};
            if (iss_mispred)  mispredict_count<=mispredict_count+32'd1;
        end
    end
`endif

    always @(*) begin dbg_x10=regs[10]; dbg_pc=pc; end
endmodule
