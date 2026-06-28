`timescale 1ns/1ps
module tb_rvlinux_decode_stage;
    reg  [15:0] lo16 = 16'd0;
    reg  [31:0] raw32 = 32'd0;
    reg         is_rvc = 1'b0;

    wire [31:0] instr, ilen;
    wire        rvc_illegal;
    wire [6:0]  opc, f7;
    wire [4:0]  rd, rs1, rs2, f5, zimm;
    wire [2:0]  f3;
    wire [11:0] csr_addr;
    wire [31:0] immI, immS, immB, immU, immJ;
    wire        is_lui, is_auipc, is_jal, is_jalr, is_branch;
    wire        is_load, is_store, is_opimm, is_op, is_fence;
    wire        is_amo, is_lr, is_sc, amo_store;
    wire        is_system, is_csr, is_ecall, is_ebreak, is_mret, is_sret;
    wire        is_wfi, is_sfence, is_muldiv, base_legal;

    rvlinux_decode_stage dut (
        .lo16(lo16), .raw32(raw32), .is_rvc(is_rvc),
        .instr(instr), .ilen(ilen), .rvc_illegal(rvc_illegal),
        .opc(opc), .rd(rd), .rs1(rs1), .rs2(rs2), .f3(f3), .f7(f7),
        .f5(f5), .csr_addr(csr_addr), .zimm(zimm),
        .immI(immI), .immS(immS), .immB(immB), .immU(immU), .immJ(immJ),
        .is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal),
        .is_jalr(is_jalr), .is_branch(is_branch), .is_load(is_load),
        .is_store(is_store), .is_opimm(is_opimm), .is_op(is_op),
        .is_fence(is_fence), .is_amo(is_amo), .is_lr(is_lr),
        .is_sc(is_sc), .amo_store(amo_store), .is_system(is_system),
        .is_csr(is_csr), .is_ecall(is_ecall), .is_ebreak(is_ebreak),
        .is_mret(is_mret), .is_sret(is_sret), .is_wfi(is_wfi),
        .is_sfence(is_sfence), .is_muldiv(is_muldiv),
        .base_legal(base_legal)
    );

    integer fails = 0;

    task chk(input cond, input [383:0] name);
        begin
            if (!cond) begin
                $display("FAIL %0s", name);
                fails = fails + 1;
            end else begin
                $display("ok   %0s", name);
            end
        end
    endtask

    task decode_expect(
        input [15:0] lo_i,
        input [31:0] raw_i,
        input        rvc_i,
        input [31:0] instr_i,
        input [31:0] ilen_i,
        input        bad_i,
        input [383:0] name
    );
        begin
            lo16 = lo_i;
            raw32 = raw_i;
            is_rvc = rvc_i;
            #1;
            chk(instr == instr_i, {name, "_instr"});
            chk(ilen == ilen_i, {name, "_ilen"});
            chk(rvc_illegal == bad_i, {name, "_rvc_illegal"});
        end
    endtask

    initial begin
        decode_expect(16'h0093, 32'h00A0_0093, 1'b0, 32'h00A0_0093,
                      32'd4, 1'b0, "rv32_addi_passthrough");
        chk(is_opimm && rd == 5'd1 && rs1 == 5'd0 && immI == 32'd10,
            "rv32_addi_fields");

        decode_expect(16'h0001, 32'hDEAD_BEEF, 1'b1, 32'h0000_0013,
                      32'd2, 1'b0, "c_nop");
        chk(is_opimm && rd == 5'd0 && rs1 == 5'd0, "c_nop_fields");

        decode_expect(16'h0024, 32'hDEAD_BEEF, 1'b1, 32'h0081_0493,
                      32'd2, 1'b0, "c_addi4spn");
        chk(is_opimm && rd == 5'd9 && rs1 == 5'd2 && immI == 32'd8,
            "c_addi4spn_fields");

        decode_expect(16'h4188, 32'hDEAD_BEEF, 1'b1, 32'h0005_A503,
                      32'd2, 1'b0, "c_lw");
        chk(is_load && rd == 5'd10 && rs1 == 5'd11 && f3 == 3'b010,
            "c_lw_fields");

        decode_expect(16'hC188, 32'hDEAD_BEEF, 1'b1, 32'h00A5_A023,
                      32'd2, 1'b0, "c_sw");
        chk(is_store && rs1 == 5'd11 && rs2 == 5'd10 && immS == 32'd0,
            "c_sw_fields");

        decode_expect(16'h2011, 32'hDEAD_BEEF, 1'b1, 32'h0040_00EF,
                      32'd2, 1'b0, "c_jal");
        chk(is_jal && rd == 5'd1 && immJ == 32'd4, "c_jal_fields");

        decode_expect(16'h4085, 32'hDEAD_BEEF, 1'b1, 32'h0010_0093,
                      32'd2, 1'b0, "c_li");
        chk(is_opimm && rd == 5'd1 && rs1 == 5'd0 && immI == 32'd1,
            "c_li_fields");

        decode_expect(16'h6505, 32'hDEAD_BEEF, 1'b1, 32'h0000_1537,
                      32'd2, 1'b0, "c_lui");
        chk(is_lui && rd == 5'd10 && immU == 32'h0000_1000,
            "c_lui_fields");

        decode_expect(16'h8C85, 32'hDEAD_BEEF, 1'b1, 32'h4094_84B3,
                      32'd2, 1'b0, "c_sub");
        chk(is_op && rd == 5'd9 && rs1 == 5'd9 && rs2 == 5'd9 &&
            f7 == 7'h20, "c_sub_fields");

        decode_expect(16'hA011, 32'hDEAD_BEEF, 1'b1, 32'h0040_006F,
                      32'd2, 1'b0, "c_j");
        chk(is_jal && rd == 5'd0 && immJ == 32'd4, "c_j_fields");

        decode_expect(16'hC105, 32'hDEAD_BEEF, 1'b1, 32'h0205_0063,
                      32'd2, 1'b0, "c_beqz");
        chk(is_branch && rs1 == 5'd10 && rs2 == 5'd0 &&
            immB == 32'd32, "c_beqz_fields");

        decode_expect(16'h4102, 32'hDEAD_BEEF, 1'b1, 32'h0001_2103,
                      32'd2, 1'b0, "c_lwsp");
        chk(is_load && rd == 5'd2 && rs1 == 5'd2, "c_lwsp_fields");

        decode_expect(16'h8082, 32'hDEAD_BEEF, 1'b1, 32'h0000_8067,
                      32'd2, 1'b0, "c_jr");
        chk(is_jalr && rd == 5'd0 && rs1 == 5'd1, "c_jr_fields");

        decode_expect(16'h9002, 32'hDEAD_BEEF, 1'b1, 32'h0010_0073,
                      32'd2, 1'b0, "c_ebreak");
        chk(is_system && is_ebreak && base_legal, "c_ebreak_fields");

        decode_expect(16'hC02A, 32'hDEAD_BEEF, 1'b1, 32'h00A1_2023,
                      32'd2, 1'b0, "c_swsp");
        chk(is_store && rs1 == 5'd2 && rs2 == 5'd10, "c_swsp_fields");

        decode_expect(16'h0000, 32'hDEAD_BEEF, 1'b1, 32'h0000_0013,
                      32'd2, 1'b1, "illegal_c_addi4spn_zero");
        decode_expect(16'h9C85, 32'hDEAD_BEEF, 1'b1, 32'h0000_0013,
                      32'd2, 1'b1, "illegal_c_rv64_w_op");

        decode_expect(16'h202F, 32'h1000_202F, 1'b0, 32'h1000_202F,
                      32'd4, 1'b0, "rv32_lr_w");
        chk(is_amo && is_lr && !amo_store && base_legal, "rv32_lr_w_fields");

        decode_expect(16'h2FAF, 32'h18B5_2FAF, 1'b0, 32'h18B5_2FAF,
                      32'd4, 1'b0, "rv32_sc_w");
        chk(is_amo && is_sc && amo_store && base_legal, "rv32_sc_w_fields");

        decode_expect(16'h1073, 32'h3020_0073, 1'b0, 32'h3020_0073,
                      32'd4, 1'b0, "rv32_mret");
        chk(is_system && is_mret && base_legal, "rv32_mret_fields");

        if (fails == 0) $display("DECODE_STAGE_RESULT: PASS");
        else            $display("DECODE_STAGE_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
