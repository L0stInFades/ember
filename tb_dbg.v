`timescale 1ns/1ps
module tb_dbg;
    reg clk=0, rst=1; wire [31:0] dx10, dpc; integer i;
    cpu_super #(.MEMFILE("prog_ilp.hex")) dut (
        .clk(clk), .rst(rst), .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .dbg_x10(dx10), .dbg_pc(dpc));
    always #5 clk=~clk;
    initial begin
        rst=1; repeat(3) @(posedge clk); rst=0;
        for (i=0;i<24;i=i+1) begin
            @(posedge clk); #1;
            $display("c%0d pc=%0d issA=%b issB=%b | xaV=%b xaRd=%0d aluA=%0d | xbV=%b xbRd=%0d aluB=%0d | maV=%b maRd=%0d maAlu=%0d | t0=%0d t1=%0d",
                i, dut.pc, dut.iss_a, dut.iss_b, dut.xa_v, dut.xa_rd, dut.aluA,
                dut.xb_v, dut.xb_rd, dut.aluB, dut.ma_v, dut.ma_rd, dut.ma_alu,
                dut.regs[5], dut.regs[6]);
        end
        $finish;
    end
endmodule
