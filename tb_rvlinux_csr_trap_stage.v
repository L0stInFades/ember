`timescale 1ns/1ps

module tb_rvlinux_csr_trap_stage;
    reg clk = 1'b0;
    reg rst = 1'b1;

    reg step_valid = 1'b0;
    reg fast_retire = 1'b0;
    reg [31:0] pc = 32'd0;
    reg [31:0] instr = 32'd0;
    reg [31:0] normal_next_pc = 32'd0;
    reg system_valid = 1'b0;
    reg is_csr = 1'b0;
    reg is_ecall = 1'b0;
    reg is_ebreak = 1'b0;
    reg is_mret = 1'b0;
    reg is_sret = 1'b0;
    reg is_wfi = 1'b0;
    reg is_sfence = 1'b0;
    reg [2:0] f3 = 3'd0;
    reg [4:0] rs1 = 5'd0;
    reg [4:0] zimm = 5'd0;
    reg [11:0] csr_addr = 12'd0;
    reg [31:0] rs1_value = 32'd0;
    reg exception_valid = 1'b0;
    reg [3:0] exception_cause = 4'd0;
    reg [31:0] exception_tval = 32'd0;
    reg [31:0] irq_pending = 32'd0;
    reg [63:0] time_value = 64'd0;
    reg check_interrupts = 1'b1;

    wire done;
    wire trap_taken;
    wire return_taken;
    wire illegal;
    wire wb_en;
    wire [31:0] wb_value;
    wire [31:0] next_pc;
    wire [31:0] trap_cause;
    wire [31:0] trap_tval;
    wire [1:0] priv;
    wire [31:0] satp;
    wire [31:0] mstatus_out;
    wire [31:0] mie_out;
    wire [31:0] mip_out;
    wire [31:0] medeleg_out;
    wire [31:0] mideleg_out;
    wire [31:0] mepc_out;
    wire [31:0] sepc_out;
    wire [31:0] mcause_out;
    wire [31:0] scause_out;
    wire [31:0] mtval_out;
    wire [31:0] stval_out;
    wire [63:0] mcycle_out;
    wire [63:0] minstret_out;
    wire sum;
    wire mxr;
    wire mprv;
    wire [1:0] data_priv;

    integer failures = 0;
    reg [63:0] ret_before;

    rvlinux_csr_trap_stage dut (
        .clk(clk), .rst(rst),
        .step_valid(step_valid), .fast_retire(fast_retire),
        .pc(pc), .instr(instr),
        .normal_next_pc(normal_next_pc),
        .system_valid(system_valid), .is_csr(is_csr),
        .is_ecall(is_ecall), .is_ebreak(is_ebreak),
        .is_mret(is_mret), .is_sret(is_sret), .is_wfi(is_wfi),
        .is_sfence(is_sfence), .f3(f3), .rs1(rs1), .zimm(zimm),
        .csr_addr(csr_addr), .rs1_value(rs1_value),
        .exception_valid(exception_valid),
        .exception_cause(exception_cause), .exception_tval(exception_tval),
        .irq_pending(irq_pending),
        .time_value(time_value),
        .check_interrupts(check_interrupts),
        .done(done), .trap_taken(trap_taken),
        .return_taken(return_taken), .illegal(illegal),
        .wb_en(wb_en), .wb_value(wb_value), .next_pc(next_pc),
        .trap_cause(trap_cause), .trap_tval(trap_tval),
        .priv(priv), .satp(satp), .mstatus_out(mstatus_out),
        .mie_out(mie_out), .mip_out(mip_out),
        .medeleg_out(medeleg_out), .mideleg_out(mideleg_out),
        .mepc_out(mepc_out), .sepc_out(sepc_out),
        .mcause_out(mcause_out), .scause_out(scause_out),
        .mtval_out(mtval_out), .stval_out(stval_out),
        .mcycle_out(mcycle_out), .minstret_out(minstret_out),
        .sum(sum), .mxr(mxr), .mprv(mprv), .data_priv(data_priv)
    );

    always #5 clk = ~clk;

    task clear_inputs;
        begin
            step_valid = 1'b0;
            fast_retire = 1'b0;
            pc = 32'd0;
            instr = 32'd0;
            normal_next_pc = 32'd0;
            system_valid = 1'b0;
            is_csr = 1'b0;
            is_ecall = 1'b0;
            is_ebreak = 1'b0;
            is_mret = 1'b0;
            is_sret = 1'b0;
            is_wfi = 1'b0;
            is_sfence = 1'b0;
            f3 = 3'd0;
            rs1 = 5'd0;
            zimm = 5'd0;
            csr_addr = 12'd0;
            rs1_value = 32'd0;
            exception_valid = 1'b0;
            exception_cause = 4'd0;
            exception_tval = 32'd0;
            irq_pending = 32'd0;
            check_interrupts = 1'b1;
        end
    endtask

    task step_csrw;
        input [11:0] addr;
        input [31:0] value;
        input [31:0] step_pc;
        begin
            clear_inputs();
            pc = step_pc;
            normal_next_pc = step_pc + 32'd4;
            instr = {addr, 5'd1, 3'b001, 5'd2, 7'h73};
            system_valid = 1'b1;
            is_csr = 1'b1;
            f3 = 3'b001;
            rs1 = 5'd1;
            csr_addr = addr;
            rs1_value = value;
            step_valid = 1'b1;
            @(posedge clk); #1;
            step_valid = 1'b0;
        end
    endtask

    task step_system0;
        input [31:0] step_pc;
        input [31:0] step_instr;
        input integer kind;
        begin
            clear_inputs();
            pc = step_pc;
            instr = step_instr;
            normal_next_pc = step_pc + 32'd4;
            system_valid = 1'b1;
            case (kind)
            0: is_ecall = 1'b1;
            1: is_ebreak = 1'b1;
            2: is_mret = 1'b1;
            3: is_sret = 1'b1;
            4: is_wfi = 1'b1;
            default: is_sfence = 1'b1;
            endcase
            step_valid = 1'b1;
            @(posedge clk); #1;
            step_valid = 1'b0;
        end
    endtask

    task expect32;
        input [255:0] name;
        input [31:0] got;
        input [31:0] expected;
        begin
            if (got !== expected) begin
                $display("CSR_STAGE_RESULT: FAIL %0s got=%08h expect=%08h",
                         name, got, expected);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        clear_inputs();
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        expect32("reset priv", {30'd0, priv}, 32'd3);

        ret_before = minstret_out;
        clear_inputs();
        fast_retire = 1'b1;
        @(posedge clk); #1;
        fast_retire = 1'b0;
        if (done || trap_taken || return_taken || minstret_out != ret_before + 64'd1) begin
            $display("CSR_STAGE_RESULT: FAIL fast_retire done=%0d trap=%0d ret=%0d before=%0d",
                     done, trap_taken, minstret_out, ret_before);
            failures = failures + 1;
        end

        step_csrw(12'h305, 32'h0000_0100, 32'h0000_0000); // mtvec
        expect32("mtvec old", wb_value, 32'd0);
        expect32("mtvec", dut.mtvec, 32'h0000_0100);
        expect32("mtvec next", next_pc, 32'h0000_0004);

        step_csrw(12'h302, 32'h0000_0200, 32'h0000_0004); // delegate S ECALL
        step_csrw(12'h105, 32'h0000_0200, 32'h0000_0008); // stvec
        step_csrw(12'h341, 32'h0000_0123, 32'h0000_000c); // mepc
        expect32("mepc masked", mepc_out, 32'h0000_0122);
        step_csrw(12'h300, 32'h0000_0880, 32'h0000_0010); // MPIE=1, MPP=S

        step_system0(32'h0000_0014, 32'h3020_0073, 2); // mret
        expect32("mret next", next_pc, 32'h0000_0122);
        expect32("mret priv S", {30'd0, priv}, 32'd1);
        expect32("mret mstatus", mstatus_out & 32'h0000_1888, 32'h0000_0088);

        step_csrw(12'h180, 32'h8000_0001, 32'h0000_0122); // satp
        expect32("satp", satp, 32'h8000_0001);
        step_csrw(12'h100, 32'h000c_0120, 32'h0000_0126); // sstatus SUM/MXR/SPIE
        expect32("sum", {31'd0, sum}, 32'd1);
        expect32("mxr", {31'd0, mxr}, 32'd1);

        step_system0(32'h0000_0130, 32'h0000_0073, 0); // S-mode ecall
        expect32("ecall trap", {31'd0, trap_taken}, 32'd1);
        expect32("ecall target", next_pc, 32'h0000_0200);
        expect32("ecall scause", scause_out, 32'd9);
        expect32("ecall sepc", sepc_out, 32'h0000_0130);
        expect32("ecall priv", {30'd0, priv}, 32'd1);

        step_csrw(12'h141, 32'h0000_0303, 32'h0000_0200); // sepc
        expect32("sepc masked", sepc_out, 32'h0000_0302);
        step_csrw(12'h100, 32'h0000_0020, 32'h0000_0204); // SPIE=1, SPP=0
        step_system0(32'h0000_0208, 32'h1020_0073, 3); // sret to U
        expect32("sret next", next_pc, 32'h0000_0302);
        expect32("sret priv U", {30'd0, priv}, 32'd0);

        // U-mode attempt to access an M-mode CSR traps as illegal to M.
        step_csrw(12'h305, 32'h0000_0444, 32'h0000_0302);
        expect32("illegal csr trap", {31'd0, trap_taken}, 32'd1);
        expect32("illegal flag", {31'd0, illegal}, 32'd1);
        expect32("illegal target", next_pc, 32'h0000_0100);
        expect32("illegal cause", mcause_out, 32'd2);
        expect32("illegal mepc", mepc_out, 32'h0000_0302);
        expect32("illegal priv M", {30'd0, priv}, 32'd3);

        if (minstret_out < 64'd8) begin
            $display("CSR_STAGE_RESULT: FAIL minstret too small %0d", minstret_out);
            failures = failures + 1;
        end

        if (failures == 0)
            $display("CSR_STAGE_RESULT: PASS");
        else
            $display("CSR_STAGE_RESULT: FAIL failures=%0d", failures);
        $finish;
    end
endmodule
