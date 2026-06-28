`timescale 1ns/1ps
module tb_rvlinux_fetch_stage;
    localparam I_LINES  = 16;
    localparam D_LINES  = 16;
    localparam WORDS    = 4;
    localparam LAT      = 5;
    localparam MEMWORDS = 1<<14;
    localparam PRV_M    = 2'd3;
    localparam PRV_S    = 2'd1;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         start = 0;
    reg  [31:0] pc = 0;
    reg  [31:0] satp = 0;
    reg  [1:0]  priv = PRV_M;
    reg         sum = 0, mxr = 0;

    wire        done, busy, fault, is_rvc, used_second_fetch;
    wire [3:0]  cause;
    wire [31:0] fault_va, raw32;
    wire [15:0] lo16;

    wire        mem_req;
    wire [1:0]  mem_access;
    wire [31:0] mem_va, mem_wdata;
    wire [3:0]  mem_be;
    wire [31:0] mem_rdata;
    wire        mem_ready, mem_fault;
    wire [3:0]  mem_cause;

    wire [31:0] i_hits, i_misses, d_hits, d_misses, ad_writes;
    wire        backing_req, backing_we, backing_ack;
    wire [31:0] backing_addr;

    rvlinux_fetch_stage fetch (
        .clk(clk), .rst(rst),
        .start(start), .pc(pc),
        .done(done), .busy(busy), .fault(fault), .cause(cause),
        .fault_va(fault_va), .lo16(lo16), .raw32(raw32),
        .is_rvc(is_rvc), .used_second_fetch(used_second_fetch),
        .mem_req(mem_req), .mem_access(mem_access), .mem_va(mem_va),
        .mem_wdata(mem_wdata), .mem_be(mem_be), .mem_rdata(mem_rdata),
        .mem_ready(mem_ready), .mem_fault(mem_fault), .mem_cause(mem_cause)
    );

    rvlinux_mem_boundary #(
        .I_LINES(I_LINES), .D_LINES(D_LINES), .WORDS(WORDS),
        .MEMWORDS(MEMWORDS), .LAT(LAT), .RAMBASE(32'h0000_0000)
    ) mem (
        .clk(clk), .rst(rst),
        .core_req(mem_req), .core_access(mem_access), .core_va(mem_va),
        .core_wdata(mem_wdata), .core_be(mem_be), .satp(satp), .priv(priv),
        .sum(sum), .mxr(mxr), .tlb_flush(1'b0),
        .core_rdata(mem_rdata), .core_ready(mem_ready), .core_fault(mem_fault),
        .core_cause(mem_cause), .core_pa(), .core_busy(),
        .i_hits(i_hits), .i_misses(i_misses),
        .d_hits(d_hits), .d_misses(d_misses), .ad_writes(ad_writes),
        .backing_req(backing_req), .backing_we(backing_we),
        .backing_addr(backing_addr), .backing_ack(backing_ack)
    );

    integer fails = 0;
    integer cyc = 0;
    reg [31:0] got_raw, got_fault_va;
    reg [15:0] got_lo16;
    reg        got_fault, got_is_rvc, got_second;
    reg [3:0]  got_cause;

    localparam [31:0] SATP_ROOT = 32'h8000_0001;
    localparam [31:0] ROOT_PTE  = (32'h0000_0002 << 10) | 32'h001;
    localparam [31:0] LEAF0_PTE = (32'h0000_0003 << 10) | 32'h00B;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc > 20000) begin
            $display("FAIL watchdog timeout");
            $display("FETCH_STAGE_RESULT: FAIL (timeout)");
            $finish;
        end
    end

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

    task fetch_once(input [31:0] pc_i);
        begin
            @(negedge clk);
            pc = pc_i;
            start = 1'b1;
            while (!done) @(negedge clk);
            got_raw = raw32;
            got_lo16 = lo16;
            got_fault = fault;
            got_cause = cause;
            got_fault_va = fault_va;
            got_is_rvc = is_rvc;
            got_second = used_second_fetch;
            @(negedge clk);
            start = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        #1;
        mem.memsys.backing.mem[32'h0000_0100 >> 2] = 32'h00A0_0093;
        mem.memsys.backing.mem[32'h0000_0104 >> 2] = 32'h00B7_0000;
        mem.memsys.backing.mem[32'h0000_0108 >> 2] = 32'hA5A5_1234;
        mem.memsys.backing.mem[32'h0000_010C >> 2] = 32'h6141_0000;

        mem.memsys.backing.mem[32'h0000_1000 >> 2] = ROOT_PTE;
        mem.memsys.backing.mem[32'h0000_2000 >> 2] = LEAF0_PTE;
        mem.memsys.backing.mem[32'h0000_2004 >> 2] = 32'h0000_0000;
        mem.memsys.backing.mem[32'h0000_3FFC >> 2] = 32'h00B7_0000;

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        satp = 32'd0;
        priv = PRV_M;
        fetch_once(32'h0000_0100);
        chk(!got_fault && !got_is_rvc && !got_second, "aligned_rv32_fetch");
        chk(got_raw == 32'h00A0_0093 && got_lo16 == 16'h0093, "aligned_rv32_bits");

        fetch_once(32'h0000_0106);
        chk(!got_fault && !got_is_rvc && got_second, "halfword_rv32_uses_second_fetch");
        chk(got_raw == 32'h1234_00B7 && got_lo16 == 16'h00B7, "halfword_rv32_reassembled");

        fetch_once(32'h0000_010E);
        chk(!got_fault && got_is_rvc && !got_second, "high_half_rvc_no_second_fetch");
        chk(got_lo16 == 16'h6141, "high_half_rvc_lo16");

        satp = SATP_ROOT;
        priv = PRV_S;
        fetch_once(32'h0000_0FFE);
        chk(got_fault && got_cause == 4'd12, "cross_page_second_fetch_fault");
        chk(got_fault_va == 32'h0000_0FFE, "fetch_fault_tval_matches_rvlinux_pc");
        chk(got_second, "cross_page_attempted_second_fetch");

        chk(i_misses != 0 && i_hits != 0, "boundary_icache_exercised");
        chk(ad_writes != 0, "translated_fetch_updates_accessed");

        $display("fetch_stage stats: i_hits=%0d i_misses=%0d d_hits=%0d d_misses=%0d ad_writes=%0d",
                 i_hits, i_misses, d_hits, d_misses, ad_writes);
        if (fails == 0) $display("FETCH_STAGE_RESULT: PASS");
        else            $display("FETCH_STAGE_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
