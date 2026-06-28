`timescale 1ns/1ps

module tb_rvlinux_timebase_param;
    reg clk = 1'b0;
    reg rst = 1'b1;
    wire [31:0] dbg_mtime;

    always #5 clk = ~clk;

    rvlinux #(
        .MEMWORDS(16),
        .RAMBASE(32'h0000_0000),
        .MTIME_TICK_CYCLES(32'd4)
    ) dut (
        .clk(clk),
        .rst(rst),
        .uart_we(),
        .uart_data(),
        .rx_valid(1'b0),
        .rx_byte_in(8'd0),
        .rx_ready(),
        .halt(),
        .exit_code(),
        .dbg_pc(),
        .dbg_priv(),
        .dbg_rsel(5'd0),
        .dbg_rval(),
        .dbg_maddr(32'd0),
        .dbg_mval(),
        .dbg_scause(),
        .dbg_mcause(),
        .dbg_mip(),
        .dbg_mie(),
        .dbg_stval(),
        .dbg_satp(),
        .dbg_mepc(),
        .dbg_sepc(),
        .dbg_mtime(dbg_mtime),
        .dbg_mtimecmp(),
        .dbg_mmio_valid(),
        .dbg_mmio_we(),
        .dbg_mmio_funct3(),
        .dbg_mmio_pa(),
        .dbg_mmio_wdata(),
        .dbg_mmio_rdata()
    );

    integer fails = 0;

    task chk;
        input cond;
        input [255:0] name;
        begin
            if (!cond) begin
                fails = fails + 1;
                $display("not ok %0s", name);
            end else begin
                $display("ok %0s", name);
            end
        end
    endtask

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        dut.mem[0] = 32'h0000_0013; // nop
        dut.mem[1] = 32'h0000_0013;
        dut.mem[2] = 32'h0000_0013;
        dut.mem[3] = 32'h0000_0013;

        tick();
        tick();
        rst = 1'b0;
        #1;
        chk(dbg_mtime == 32'd0, "reset_mtime_zero");

        tick();
        chk(dbg_mtime == 32'd0, "mtime_holds_cycle_1");
        tick();
        chk(dbg_mtime == 32'd0, "mtime_holds_cycle_2");
        tick();
        chk(dbg_mtime == 32'd0, "mtime_holds_cycle_3");
        tick();
        chk(dbg_mtime == 32'd1, "mtime_ticks_cycle_4");
        tick();
        chk(dbg_mtime == 32'd1, "mtime_holds_after_tick");

        if (fails == 0) $display("RVLINUX_TIMEBASE_PARAM_RESULT: PASS");
        else            $display("RVLINUX_TIMEBASE_PARAM_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
