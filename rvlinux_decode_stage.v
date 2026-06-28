`timescale 1ns/1ps
// RVC decompression and basic decode packet for the future rvlinux stall FSM.
//
// The multi-cycle core will fetch through rvlinux_fetch_stage.v, latch lo16/raw32,
// then decode from this stable packet. CSR existence/privilege legality still
// belongs with the CSR/trap stage because it depends on current privilege state.
module rvlinux_decode_stage(
    input  wire [15:0] lo16,
    input  wire [31:0] raw32,
    input  wire        is_rvc,

    output wire [31:0] instr,
    output wire [31:0] ilen,
    output wire        rvc_illegal,

    output wire [6:0]  opc,
    output wire [4:0]  rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [2:0]  f3,
    output wire [6:0]  f7,
    output wire [4:0]  f5,
    output wire [11:0] csr_addr,
    output wire [4:0]  zimm,
    output wire [31:0] immI,
    output wire [31:0] immS,
    output wire [31:0] immB,
    output wire [31:0] immU,
    output wire [31:0] immJ,

    output wire        is_lui,
    output wire        is_auipc,
    output wire        is_jal,
    output wire        is_jalr,
    output wire        is_branch,
    output wire        is_load,
    output wire        is_store,
    output wire        is_opimm,
    output wire        is_op,
    output wire        is_fence,
    output wire        is_amo,
    output wire        is_lr,
    output wire        is_sc,
    output wire        amo_store,
    output wire        is_system,
    output wire        is_csr,
    output wire        is_ecall,
    output wire        is_ebreak,
    output wire        is_mret,
    output wire        is_sret,
    output wire        is_wfi,
    output wire        is_sfence,
    output wire        is_muldiv,
    output wire        base_legal
);
    localparam [6:0] LUI    = 7'h37;
    localparam [6:0] AUIPC  = 7'h17;
    localparam [6:0] JAL    = 7'h6f;
    localparam [6:0] JALR   = 7'h67;
    localparam [6:0] BR     = 7'h63;
    localparam [6:0] LOAD   = 7'h03;
    localparam [6:0] STORE  = 7'h23;
    localparam [6:0] OPIMM  = 7'h13;
    localparam [6:0] OP     = 7'h33;
    localparam [6:0] SYSTEM = 7'h73;
    localparam [6:0] FENCE  = 7'h0f;
    localparam [6:0] AMO    = 7'h2f;

    wire [4:0] c_rdp  = {2'b01, lo16[4:2]};
    wire [4:0] c_rs2p = {2'b01, lo16[4:2]};
    wire [4:0] c_rs1p = {2'b01, lo16[9:7]};
    wire [4:0] c_rd   = lo16[11:7];
    wire [4:0] c_rs2  = lo16[6:2];
    wire [11:0] ciw_imm = {2'b00, lo16[10:7], lo16[12:11],
                           lo16[5], lo16[6], 2'b00};
    wire [11:0] clw_imm = {5'b0, lo16[5], lo16[12:10], lo16[6], 2'b00};
    wire [11:0] ci_imm  = {{7{lo16[12]}}, lo16[6:2]};
    wire [11:0] c16sp   = {{3{lo16[12]}}, lo16[4:3], lo16[5],
                           lo16[2], lo16[6], 4'b0000};
    wire [19:0] clui20  = {{15{lo16[12]}}, lo16[6:2]};
    wire [11:0] clwsp   = {4'b0, lo16[3:2], lo16[12], lo16[6:4], 2'b00};
    wire [11:0] cswsp   = {4'b0, lo16[8:7], lo16[12:9], 2'b00};
    wire [4:0]  cshamt  = lo16[6:2];
    wire [11:0] cjo     = {lo16[12], lo16[8], lo16[10:9], lo16[6],
                           lo16[7], lo16[2], lo16[11], lo16[5:3], 1'b0};
    wire [20:0] cj_imm  = {{9{cjo[11]}}, cjo};
    wire [8:0]  cbo     = {lo16[12], lo16[6:5], lo16[2],
                           lo16[11:10], lo16[4:3], 1'b0};
    wire [12:0] cb_imm  = {{4{cbo[8]}}, cbo};

    reg [31:0] cdec;
    reg        cbad;

    always @(*) begin
        cdec = 32'h0000_0013;
        cbad = 1'b0;
        case ({lo16[1:0], lo16[15:13]})
        5'b00_000: begin
            if (lo16[12:5] == 8'b0)
                cbad = 1'b1;
            else
                cdec = {ciw_imm, 5'd2, 3'b000, c_rdp, OPIMM};
        end
        5'b00_010: cdec = {clw_imm, c_rs1p, 3'b010, c_rdp, LOAD};
        5'b00_110: cdec = {clw_imm[11:5], c_rs2p, c_rs1p, 3'b010,
                           clw_imm[4:0], STORE};
        5'b01_000: cdec = {ci_imm, c_rd, 3'b000, c_rd, OPIMM};
        5'b01_001: cdec = {cj_imm[20], cj_imm[10:1], cj_imm[11],
                           cj_imm[19:12], 5'd1, JAL};
        5'b01_010: cdec = {ci_imm, 5'd0, 3'b000, c_rd, OPIMM};
        5'b01_011: cdec = (c_rd == 5'd2) ?
                           {c16sp, 5'd2, 3'b000, 5'd2, OPIMM} :
                           {clui20, c_rd, LUI};
        5'b01_100: begin
            case (lo16[11:10])
            2'b00: cdec = {7'b0000000, cshamt, c_rs1p, 3'b101, c_rs1p, OPIMM};
            2'b01: cdec = {7'b0100000, cshamt, c_rs1p, 3'b101, c_rs1p, OPIMM};
            2'b10: cdec = {ci_imm, c_rs1p, 3'b111, c_rs1p, OPIMM};
            default: begin
                if (lo16[12]) begin
                    cbad = 1'b1;
                end else begin
                    case (lo16[6:5])
                    2'b00: cdec = {7'b0100000, c_rs2p, c_rs1p, 3'b000, c_rs1p, OP};
                    2'b01: cdec = {7'b0000000, c_rs2p, c_rs1p, 3'b100, c_rs1p, OP};
                    2'b10: cdec = {7'b0000000, c_rs2p, c_rs1p, 3'b110, c_rs1p, OP};
                    default: cdec = {7'b0000000, c_rs2p, c_rs1p, 3'b111, c_rs1p, OP};
                    endcase
                end
            end
            endcase
        end
        5'b01_101: cdec = {cj_imm[20], cj_imm[10:1], cj_imm[11],
                           cj_imm[19:12], 5'd0, JAL};
        5'b01_110: cdec = {cb_imm[12], cb_imm[10:5], 5'd0, c_rs1p,
                           3'b000, cb_imm[4:1], cb_imm[11], BR};
        5'b01_111: cdec = {cb_imm[12], cb_imm[10:5], 5'd0, c_rs1p,
                           3'b001, cb_imm[4:1], cb_imm[11], BR};
        5'b10_000: cdec = {7'b0000000, cshamt, c_rd, 3'b001, c_rd, OPIMM};
        5'b10_010: cdec = {clwsp, 5'd2, 3'b010, c_rd, LOAD};
        5'b10_100: begin
            if (!lo16[12]) begin
                if (c_rs2 == 5'd0)
                    cdec = {12'b0, c_rd, 3'b000, 5'd0, JALR};
                else
                    cdec = {7'b0000000, c_rs2, 5'd0, 3'b000, c_rd, OP};
            end else begin
                if (c_rd == 5'd0 && c_rs2 == 5'd0)
                    cdec = 32'h0010_0073;
                else if (c_rs2 == 5'd0)
                    cdec = {12'b0, c_rd, 3'b000, 5'd1, JALR};
                else
                    cdec = {7'b0000000, c_rs2, c_rd, 3'b000, c_rd, OP};
            end
        end
        5'b10_110: cdec = {cswsp[11:5], c_rs2, 5'd2, 3'b010,
                           cswsp[4:0], STORE};
        default: cbad = 1'b1;
        endcase
    end

    assign instr = is_rvc ? cdec : raw32;
    assign rvc_illegal = is_rvc && cbad;
    assign ilen = is_rvc ? 32'd2 : 32'd4;

    assign opc = instr[6:0];
    assign rd = instr[11:7];
    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign f3 = instr[14:12];
    assign f7 = instr[31:25];
    assign f5 = instr[31:27];
    assign csr_addr = instr[31:20];
    assign zimm = instr[19:15];
    assign immI = {{20{instr[31]}}, instr[31:20]};
    assign immS = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign immB = {{19{instr[31]}}, instr[31], instr[7],
                   instr[30:25], instr[11:8], 1'b0};
    assign immU = {instr[31:12], 12'b0};
    assign immJ = {{11{instr[31]}}, instr[31], instr[19:12],
                   instr[20], instr[30:21], 1'b0};

    assign is_lui = (opc == LUI);
    assign is_auipc = (opc == AUIPC);
    assign is_jal = (opc == JAL);
    assign is_jalr = (opc == JALR);
    assign is_branch = (opc == BR);
    assign is_load = (opc == LOAD);
    assign is_store = (opc == STORE);
    assign is_opimm = (opc == OPIMM);
    assign is_op = (opc == OP);
    assign is_fence = (opc == FENCE);
    assign is_amo = (opc == AMO);
    assign is_lr = is_amo && (f5 == 5'b00010);
    assign is_sc = is_amo && (f5 == 5'b00011);
    assign amo_store = is_amo && !is_lr;
    assign is_system = (opc == SYSTEM);
    assign is_csr = is_system && (f3 != 3'b000);
    assign is_ecall = is_system && (f3 == 3'b000) && (csr_addr == 12'h000);
    assign is_ebreak = is_system && (f3 == 3'b000) && (csr_addr == 12'h001);
    assign is_mret = is_system && (f3 == 3'b000) && (csr_addr == 12'h302);
    assign is_sret = is_system && (f3 == 3'b000) && (csr_addr == 12'h102);
    assign is_wfi = is_system && (f3 == 3'b000) && (csr_addr == 12'h105);
    assign is_sfence = is_system && (f3 == 3'b000) && (f7 == 7'h09);
    assign is_muldiv = is_op && (f7 == 7'h01);

    assign base_legal =
        is_lui || is_auipc || is_jal || is_jalr || is_branch ||
        is_load || is_store || is_opimm || is_fence ||
        (is_op && ((f7 == 7'h00) || (f7 == 7'h20) || (f7 == 7'h01))) ||
        (is_amo && (f3 == 3'b010)) ||
        (is_system && (is_ecall || is_ebreak || is_mret || is_sret ||
                       is_wfi || is_sfence || is_csr));
endmodule
