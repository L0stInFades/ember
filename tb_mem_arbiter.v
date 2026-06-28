`timescale 1ns/1ps
module tb_mem_arbiter;
    localparam LAT = 5;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         i_req = 0, i_we = 0;
    reg  [31:0] i_addr = 0, i_wdata = 0;
    wire [31:0] i_rdata;
    wire        i_ack;

    reg         d_req = 0, d_we = 0;
    reg  [31:0] d_addr = 0, d_wdata = 0;
    wire [31:0] d_rdata;
    wire        d_ack;

    wire        m_req, m_we, m_ack;
    wire [31:0] m_addr, m_wdata, m_rdata;

    mem_arbiter2 dut(
        .clk(clk), .rst(rst),
        .i_req(i_req), .i_we(i_we), .i_addr(i_addr), .i_wdata(i_wdata),
        .i_rdata(i_rdata), .i_ack(i_ack),
        .d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_wdata(d_wdata),
        .d_rdata(d_rdata), .d_ack(d_ack),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack));

    slowmem #(.MEMW(1<<14), .LAT(LAT)) mem(
        .clk(clk), .rst(rst), .m_req(m_req), .m_we(m_we), .m_addr(m_addr),
        .m_wdata(m_wdata), .m_rdata(m_rdata), .m_ack(m_ack));

    integer fails = 0;
    integer i_count = 0, d_count = 0, m_count = 0;
    reg [31:0] cap_i, cap_d;
    integer k, ki, kd;

    always @(posedge clk) begin
        if (i_ack) i_count <= i_count + 1;
        if (d_ack) d_count <= d_count + 1;
        if (m_ack) m_count <= m_count + 1;
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

    task i_read(input [31:0] addr, output [31:0] got);
        begin
            @(negedge clk);
            i_addr = addr;
            i_wdata = 32'd0;
            i_we = 1'b0;
            i_req = 1'b1;
            while (!i_ack) @(negedge clk);
            got = i_rdata;
            @(negedge clk);
            i_req = 1'b0;
        end
    endtask

    task d_read(input [31:0] addr, output [31:0] got);
        begin
            @(negedge clk);
            d_addr = addr;
            d_wdata = 32'd0;
            d_we = 1'b0;
            d_req = 1'b1;
            while (!d_ack) @(negedge clk);
            got = d_rdata;
            @(negedge clk);
            d_req = 1'b0;
        end
    endtask

    task d_write(input [31:0] addr, input [31:0] data);
        reg [31:0] unused;
        begin
            @(negedge clk);
            d_addr = addr;
            d_wdata = data;
            d_we = 1'b1;
            d_req = 1'b1;
            while (!d_ack) @(negedge clk);
            unused = d_rdata;
            @(negedge clk);
            d_req = 1'b0;
            d_we = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        @(negedge clk);

        fork
            i_read(32'h0000_0000, cap_i);
            d_read(32'h0000_0040, cap_d);
        join
        chk(cap_i, refv(32'h0000_0000), "simul_i_read");
        chk(cap_d, refv(32'h0000_0040), "simul_d_read");

        d_write(32'h0000_0080, 32'h1234_5678);
        i_read(32'h0000_0080, cap_i);
        chk(cap_i, 32'h1234_5678, "write_visible_to_i");

        fork
            begin
                for (ki = 0; ki < 16; ki = ki + 1) begin
                    i_read(32'h0000_0100 + ki*4, cap_i);
                    chk(cap_i, refv(32'h0000_0100 + ki*4), "i_stream");
                end
            end
            begin
                for (kd = 0; kd < 16; kd = kd + 1)
                    d_write(32'h0000_0200 + kd*4, 32'hD000_0000 + kd);
            end
        join

        for (k = 0; k < 16; k = k + 1) begin
            d_read(32'h0000_0200 + k*4, cap_d);
            chk(cap_d, 32'hD000_0000 + k, "d_stream_writeback");
        end

        $display("arbiter counts: i_ack=%0d d_ack=%0d mem_ack=%0d", i_count, d_count, m_count);
        if (i_count == 0 || d_count == 0 || m_count != i_count + d_count) begin
            $display("FAIL ack accounting");
            fails = fails + 1;
        end

        if (fails == 0) $display("ARB_RESULT: PASS");
        else            $display("ARB_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
