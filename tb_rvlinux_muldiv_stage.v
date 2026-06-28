`timescale 1ns/1ps

module tb_rvlinux_muldiv_stage;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg start = 1'b0;
    reg [2:0] funct3 = 3'd0;
    reg [31:0] rs1_value = 32'd0;
    reg [31:0] rs2_value = 32'd0;
    wire done;
    wire busy;
    wire [31:0] result;

    integer failures = 0;

    rvlinux_muldiv_stage dut (
        .clk(clk), .rst(rst), .start(start), .funct3(funct3),
        .rs1_value(rs1_value), .rs2_value(rs2_value),
        .done(done), .busy(busy), .result(result)
    );

    always #5 clk = ~clk;

    task run_case;
        input [255:0] name;
        input [2:0] f3;
        input [31:0] a;
        input [31:0] b;
        input [31:0] expected;
        integer cycles;
        begin
            funct3 = f3;
            rs1_value = a;
            rs2_value = b;
            start = 1'b1;
            cycles = 0;
            while (!done && cycles < 80) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!done) begin
                $display("MULDIV_RESULT: FAIL timeout %0s", name);
                failures = failures + 1;
            end else if (result !== expected) begin
                $display("MULDIV_RESULT: FAIL %0s got=%08h expect=%08h",
                         name, result, expected);
                failures = failures + 1;
            end
            start = 1'b0;
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        run_case("mul",    3'b000, 32'd7, 32'd5, 32'd35);
        run_case("mulh",   3'b001, 32'hffff_fffe, 32'd3, 32'hffff_ffff);
        run_case("mulhsu", 3'b010, 32'hffff_fffe, 32'd3, 32'hffff_ffff);
        run_case("mulhu",  3'b011, 32'hffff_ffff, 32'd2, 32'h0000_0001);
        run_case("div",    3'b100, -32'sd8, 32'd3, 32'hffff_fffe);
        run_case("divov",  3'b100, 32'h8000_0000, 32'hffff_ffff, 32'h8000_0000);
        run_case("divu",   3'b101, 32'd10, 32'd3, 32'd3);
        run_case("rem",    3'b110, -32'sd8, 32'd3, 32'hffff_fffe);
        run_case("remz",   3'b110, 32'h1234_5678, 32'd0, 32'h1234_5678);
        run_case("remu",   3'b111, 32'd10, 32'd3, 32'd1);

        if (failures == 0)
            $display("MULDIV_RESULT: PASS");
        else
            $display("MULDIV_RESULT: FAIL failures=%0d", failures);
        $finish;
    end
endmodule
