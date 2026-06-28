`timescale 1ns/1ps
module tb_sv32_ptw;
    localparam [31:0] RAMBASE = 32'h8000_0000;
    localparam MEMWORDS = 1<<14;
    localparam LAT = 4;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         start = 0;
    reg  [31:0] satp = 0, va = 0;
    reg  [1:0]  access = 0, priv = 0;
    reg         sum = 0, mxr = 0;
    wire        busy, done, fault, set_a, set_d;
    wire [3:0]  cause;
    wire [31:0] pa, leaf_pte, leaf_pte_pa;
    wire        m_req, m_we, m_ack;
    wire [31:0] m_addr, m_wdata, m_rdata;

    sv32_ptw #(.MEMWORDS(MEMWORDS), .RAMBASE(RAMBASE)) dut (
        .clk(clk), .rst(rst),
        .start(start), .satp(satp), .va(va), .access(access), .priv(priv), .sum(sum), .mxr(mxr),
        .busy(busy), .done(done), .fault(fault), .cause(cause), .pa(pa),
        .leaf_pte(leaf_pte), .leaf_pte_pa(leaf_pte_pa), .set_a(set_a), .set_d(set_d),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack)
    );

    reg [31:0] mem [0:MEMWORDS-1];
    reg        mem_busy = 0, mem_wait_drop = 0;
    reg [15:0] mem_cnt = 0;
    reg [31:0] lat_addr = 0;
    reg [31:0] m_rdata_r = 0;
    reg        m_ack_r = 0;
    integer k;
    integer reads = 0;
    integer fails = 0;

    assign m_rdata = m_rdata_r;
    assign m_ack = m_ack_r;

    function [31:0] idx(input [31:0] addr);
        idx = (addr - RAMBASE) >> 2;
    endfunction

    function [31:0] pte(input [31:0] ppn, input [7:0] flags);
        pte = (ppn << 10) | flags;
    endfunction

    initial begin
        for (k = 0; k < MEMWORDS; k = k + 1)
            mem[k] = 32'd0;

        mem[idx(32'h8000_1004)] = pte(32'h80002, 8'h01); // VPN1=1 -> L0 table
        mem[idx(32'h8000_200C)] = pte(32'h80003, 8'hCF); // VPN0=3, kernel RWX AD
        mem[idx(32'h8000_2010)] = pte(32'h80004, 8'h07); // VPN0=4, kernel RW, no A/D
        mem[idx(32'h8000_2014)] = pte(32'h80005, 8'h59); // VPN0=5, user X, A set
        mem[idx(32'h8000_2018)] = pte(32'h80006, 8'h47); // VPN0=6, kernel RW, A set
        mem[idx(32'h8000_201C)] = 32'd0;                 // VPN0=7 invalid
    end

    always @(posedge clk) begin
        if (rst) begin
            m_ack_r <= 1'b0;
            mem_busy <= 1'b0;
            mem_wait_drop <= 1'b0;
            mem_cnt <= 16'd0;
            lat_addr <= 32'd0;
            reads <= 0;
        end else begin
            m_ack_r <= 1'b0;
            if (mem_wait_drop) begin
                if (!m_req) mem_wait_drop <= 1'b0;
            end else if (!mem_busy) begin
                if (m_req) begin
                    mem_busy <= 1'b1;
                    mem_cnt <= LAT[15:0] - 16'd1;
                    lat_addr <= m_addr;
                end
            end else if (mem_cnt == 0) begin
                mem_busy <= 1'b0;
                mem_wait_drop <= 1'b1;
                m_ack_r <= 1'b1;
                m_rdata_r <= mem[idx(lat_addr)];
                reads <= reads + 1;
            end else begin
                mem_cnt <= mem_cnt - 16'd1;
            end
        end
    end

    task chk(input cond, input [255:0] name);
        begin
            if (!cond) begin
                $display("FAIL %0s", name);
                fails = fails + 1;
            end else begin
                $display("ok   %0s", name);
            end
        end
    endtask

    task walk(input [31:0] satp_i, input [31:0] va_i, input [1:0] acc_i,
              input [1:0] priv_i, input sum_i, input mxr_i);
        begin
            @(negedge clk);
            satp = satp_i;
            va = va_i;
            access = acc_i;
            priv = priv_i;
            sum = sum_i;
            mxr = mxr_i;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            while (!done) @(negedge clk);
            @(negedge clk);
        end
    endtask

    localparam [31:0] SATP_ROOT = 32'h8000_0000 | 32'h0008_0001;

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        walk(32'd0, 32'h8123_4568, 2'd0, 2'd3, 1'b0, 1'b0);
        chk(!fault && pa == 32'h8123_4568 && reads == 0, "bare_or_m_mode_no_walk");

        walk(SATP_ROOT, 32'h0040_3004, 2'd0, 2'd1, 1'b0, 1'b0);
        chk(!fault && pa == 32'h8000_3004 && leaf_pte_pa == 32'h8000_200C, "s_fetch_two_level");
        chk(!set_a && !set_d && cause == 4'd0, "fetch_ad_clean");

        walk(SATP_ROOT, 32'h0040_4000, 2'd2, 2'd1, 1'b0, 1'b0);
        chk(!fault && pa == 32'h8000_4000, "s_store_two_level");
        chk(set_a && set_d && leaf_pte == pte(32'h80004, 8'h07), "store_ad_request");

        walk(SATP_ROOT, 32'h0040_5000, 2'd1, 2'd1, 1'b1, 1'b1);
        chk(!fault && pa == 32'h8000_5000 && set_a == 1'b0, "s_load_user_x_mxr_sum");

        walk(SATP_ROOT, 32'h0040_5000, 2'd1, 2'd1, 1'b1, 1'b0);
        chk(fault && cause == 4'd13, "mxr_off_load_fault");

        walk(SATP_ROOT, 32'h0040_6000, 2'd1, 2'd0, 1'b0, 1'b0);
        chk(fault && cause == 4'd13, "u_load_supervisor_fault");

        walk(SATP_ROOT, 32'h0040_7000, 2'd0, 2'd1, 1'b0, 1'b0);
        chk(fault && cause == 4'd12, "invalid_fetch_fault");

        $display("ptw reads=%0d", reads);
        chk(reads == 12, "ptw_read_accounting");
        if (fails == 0) $display("PTW_RESULT: PASS");
        else            $display("PTW_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
