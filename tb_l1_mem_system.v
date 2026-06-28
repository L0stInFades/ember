`timescale 1ns/1ps
module tb_l1_mem_system;
    localparam I_LINES = 8;
    localparam D_LINES = 8;
    localparam WORDS   = 4;
    localparam LAT     = 5;
    localparam LINE_BYTES = WORDS * 4;
    localparam INDEX_SPAN = D_LINES * LINE_BYTES;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         i_req = 0;
    reg  [31:0] i_addr = 0;
    wire [31:0] i_rdata;
    wire        i_ready;

    reg         d_req = 0, d_we = 0;
    reg  [31:0] d_addr = 0, d_wdata = 0;
    reg  [3:0]  d_be = 4'hF;
    wire [31:0] d_rdata;
    wire        d_ready;

    wire [31:0] ptw_rdata;
    wire        ptw_ready;
    wire [31:0] i_hits, i_misses, d_hits, d_misses;
    wire        backing_req, backing_we, backing_ack;
    wire [31:0] backing_addr;

    l1_mem_system #(
        .I_LINES(I_LINES), .D_LINES(D_LINES), .WORDS(WORDS), .MEMW(1<<14), .LAT(LAT)
    ) dut (
        .clk(clk), .rst(rst),
        .i_req(i_req), .i_addr(i_addr), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .ptw_req(1'b0), .ptw_we(1'b0), .ptw_addr(32'd0), .ptw_wdata(32'd0), .ptw_be(4'h0),
        .ptw_rdata(ptw_rdata), .ptw_ready(ptw_ready),
        .i_hits(i_hits), .i_misses(i_misses), .d_hits(d_hits), .d_misses(d_misses),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    integer fails = 0;
    integer cyc = 0;
    integer backing_reads = 0, backing_writes = 0;
    integer ki, kd, k;
    reg [31:0] cap_i, cap_d;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (backing_ack && backing_we) backing_writes <= backing_writes + 1;
        if (backing_ack && !backing_we) backing_reads <= backing_reads + 1;
    end

    function [31:0] refv(input [31:0] a);
        refv = (a & 32'hFFFF_FFFC) ^ 32'hA5A5_0000;
    endfunction

    task chk(input [31:0] got, input [31:0] exp, input [255:0] name);
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got=%08x exp=%08x", name, got, exp);
                fails = fails + 1;
            end else begin
                $display("ok   %0s = %08x", name, got);
            end
        end
    endtask

    task ifetch(input [31:0] addr, output [31:0] got);
        begin
            @(negedge clk);
            i_addr = addr;
            i_req = 1'b1;
            while (!i_ready) @(negedge clk);
            got = i_rdata;
            @(negedge clk);
            i_req = 1'b0;
            @(negedge clk);
        end
    endtask

    task d_read(input [31:0] addr, output [31:0] got);
        begin
            @(negedge clk);
            d_addr = addr;
            d_wdata = 32'd0;
            d_be = 4'hF;
            d_we = 1'b0;
            d_req = 1'b1;
            while (!d_ready) @(negedge clk);
            got = d_rdata;
            @(negedge clk);
            d_req = 1'b0;
            @(negedge clk);
        end
    endtask

    task d_write(input [31:0] addr, input [31:0] data, input [3:0] be);
        begin
            @(negedge clk);
            d_addr = addr;
            d_wdata = data;
            d_be = be;
            d_we = 1'b1;
            d_req = 1'b1;
            while (!d_ready) @(negedge clk);
            @(negedge clk);
            d_req = 1'b0;
            d_we = 1'b0;
            d_be = 4'hF;
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        ifetch(32'h0000_0000, cap_i);
        chk(cap_i, refv(32'h0000_0000), "icache_cold_fetch");
        ifetch(32'h0000_0000, cap_i);
        chk(cap_i, refv(32'h0000_0000), "icache_hit_fetch");

        d_write(32'h0000_0100, 32'hDEAD_BEEF, 4'hF);
        d_read(32'h0000_0100, cap_d);
        chk(cap_d, 32'hDEAD_BEEF, "dcache_write_read");

        d_write(32'h0000_0104, 32'h1111_2222, 4'hF);
        d_write(32'h0000_0104, 32'hAAAA_CC55, 4'b0011);
        d_read(32'h0000_0104, cap_d);
        chk(cap_d, 32'h1111_CC55, "dcache_byte_enable");

        d_write(32'h0000_0180, 32'hC0DE_1234, 4'hF);
        d_read(32'h0000_0180 + INDEX_SPAN, cap_d);
        chk(cap_d, refv(32'h0000_0180 + INDEX_SPAN), "dcache_conflict_fill");
        ifetch(32'h0000_0180, cap_i);
        chk(cap_i, 32'hC0DE_1234, "d_writeback_visible_to_icache");

        fork
            begin
                for (ki = 0; ki < 16; ki = ki + 1) begin
                    ifetch(32'h0000_0800 + ki*4, cap_i);
                    chk(cap_i, refv(32'h0000_0800 + ki*4), "ifetch_stream");
                end
            end
            begin
                for (kd = 0; kd < 16; kd = kd + 1)
                    d_write(32'h0000_0C00 + kd*4, 32'hD100_0000 + kd, 4'hF);
            end
        join

        for (k = 0; k < 16; k = k + 1) begin
            d_read(32'h0000_0C00 + k*4, cap_d);
            chk(cap_d, 32'hD100_0000 + k, "d_stream_readback");
        end

        $display("l1 stats: i_hits=%0d i_misses=%0d d_hits=%0d d_misses=%0d backing_reads=%0d backing_writes=%0d",
                 i_hits, i_misses, d_hits, d_misses, backing_reads, backing_writes);
        if (i_hits == 0 || i_misses == 0 || d_hits == 0 || d_misses == 0) begin
            $display("FAIL cache stats did not exercise both hit and miss paths");
            fails = fails + 1;
        end
        if (backing_reads == 0 || backing_writes == 0) begin
            $display("FAIL backing memory did not see both reads and writebacks");
            fails = fails + 1;
        end

        if (fails == 0) $display("L1MEM_RESULT: PASS");
        else            $display("L1MEM_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
