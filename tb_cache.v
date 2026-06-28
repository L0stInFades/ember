`timescale 1ns/1ps
module tb_cache;
    localparam LINES=64, WORDS=4, LAT=8;   // 1 KB direct-mapped, 8-cycle memory
    reg clk=0, rst=1;
    always #5 clk=~clk;

    reg         c_req=0, c_we=0;
    reg  [31:0] c_addr=0, c_wdata=0;
    reg  [3:0]  c_be=4'hF;
    wire [31:0] c_rdata; wire c_ready;
    wire        m_req, m_we; wire [31:0] m_addr, m_wdata, m_rdata; wire m_ack;
    wire [31:0] hits, misses;

    cache #(.LINES(LINES), .WORDS(WORDS), .RO(0)) dut(
        .clk(clk), .rst(rst), .c_req(c_req), .c_we(c_we), .c_addr(c_addr),
        .c_wdata(c_wdata), .c_be(c_be), .c_rdata(c_rdata), .c_ready(c_ready),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rdata(m_rdata), .m_ack(m_ack), .hits(hits), .misses(misses));
    slowmem #(.MEMW(1<<14), .LAT(LAT)) mem(
        .clk(clk), .rst(rst), .m_req(m_req), .m_we(m_we), .m_addr(m_addr),
        .m_wdata(m_wdata), .m_rdata(m_rdata), .m_ack(m_ack));

    integer fails=0; reg [31:0] cap; integer cyc=0; integer t0;
    integer mxfer=0;                          // backing-memory word transfers
    always @(posedge clk) cyc=cyc+1;
    always @(posedge clk) if (m_ack) mxfer=mxfer+1;

    function [31:0] refv(input [31:0] a); refv=(a & 32'hFFFF_FFFC) ^ 32'hA5A5_0000; endfunction

    task acc(input we, input [31:0] addr, input [31:0] wd);
        begin
            @(negedge clk); c_req=1; c_we=we; c_addr=addr; c_wdata=wd; c_be=4'hF;
            while (!c_ready) @(negedge clk);
            cap = c_rdata;
            @(negedge clk); c_req=0; c_we=0;
            @(negedge clk);
        end
    endtask

    task chk(input [31:0] got, input [31:0] exp, input [127:0] name);
        begin
            if (got!==exp) begin
                $display("FAIL %0s: got=%08x exp=%08x", name, got, exp); fails=fails+1;
            end else $display("ok   %0s = %08x", name, got);
        end
    endtask

    integer i, r, base, A, B;
    initial begin
        repeat(4) @(posedge clk); rst=0; @(negedge clk);

        // ---- correctness: cold reads return the backing pattern ----
        for (i=0;i<16;i=i+1) begin acc(0, i*4, 0); chk(cap, refv(i*4), "coldrd"); end
        // re-read -> hits, same data
        acc(0, 32'h8, 0); chk(cap, refv(32'h8), "rehit");

        // ---- writes then read-back ----
        acc(1, 32'h4,  32'hDEADBEEF); acc(0, 32'h4, 0);
        chk(cap, 32'hDEADBEEF, "wr_rd_4");
        acc(1, 32'h20, 32'hCAFEBABE); acc(0, 32'h20, 0);
        chk(cap, 32'hCAFEBABE, "wr_rd_20");

        // ---- write-back on eviction: dirty line flushed, refilled correctly ----
        A = 32'h4;            // idx0, tag0 (already dirty = 0xDEADBEEF)
        B = 32'h4 + (1<<10);  // idx0, tag1 -> evicts A's dirty line (writeback)
        acc(0, B, 0);                  // miss: writeback A's line, fill B
        acc(0, A, 0);                  // miss: refill A from memory
        chk(cap, 32'hDEADBEEF, "wb_evict");   // value survived via writeback

        // ---- performance: small array reused many times ----
        base = 32'h2000; t0 = cyc; mxfer = 0;
        for (r=0;r<8;r=r+1)
            for (i=0;i<128;i=i+1) acc(0, base + i*4, 0);
        $display("");
        $display("=== cache perf: 128-word array x8 passes (LINES=%0d WORDS=%0d LAT=%0d) ===",
                 LINES, WORDS, LAT);
        $display("accesses=%0d  hits=%0d  misses=%0d  hitrate=%0d.%0d%%",
                 1024, hits, misses, (hits*100)/1024, ((hits*1000)/1024)%10);
        // honest cache metrics: memory traffic and AMAT (handshake-overhead-free)
        $display("backing-mem word transfers: with_cache=%0d  no_cache=%0d  -> %0d.%0dx less traffic",
                 mxfer, 1024, (1024*10)/mxfer/10, ((1024*10)/mxfer)%10);
        // AMAT = hit*1 + miss*(WORDS*(LAT+1));  no-cache = LAT+1 per access (x100 fixed-point)
        $display("AMAT_with_cache=%0d.%02d cyc/acc   no_cache=%0d.00 cyc/acc   -> %0d.%02dx faster",
                 (hits*100 + misses*WORDS*(LAT+1)*100/1)/1024/100,
                 ((hits*100 + misses*WORDS*(LAT+1)*100)/1024)%100,
                 (LAT+1),
                 ((LAT+1)*100*1024)/(hits*100 + misses*WORDS*(LAT+1)*100)/1,
                 (((LAT+1)*100*1024*100)/(hits*100 + misses*WORDS*(LAT+1)*100))%100);

        $display("");
        if (fails==0) $display("CACHE_RESULT: PASS (all correctness checks ok)");
        else          $display("CACHE_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
