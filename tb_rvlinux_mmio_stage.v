`timescale 1ns/1ps

module tb_rvlinux_mmio_stage;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg        start = 1'b0;
    reg        is_store = 1'b0;
    reg [2:0]  funct3 = 3'b010;
    reg [31:0] pa = 32'd0;
    reg [31:0] store_data = 32'd0;
    reg        rx_valid = 1'b0;
    reg [7:0]  rx_byte_in = 8'd0;

    wire       rx_ready;
    wire       done;
    wire       busy;
    wire       fault;
    wire [3:0] cause;
    wire [31:0] fault_pa;
    wire [31:0] load_data;
    wire       uart_we;
    wire [7:0] uart_data;
    wire       halt;
    wire [31:0] exit_code;
    wire [31:0] irq_pending;
    wire [31:0] div_mtime;
    wire [31:0] div_mtimecmp;
    wire [63:0] div_mtime_full;
    wire [63:0] div_mtimecmp_full;
    wire        div_rx_ready;
    wire        div_done;
    wire        div_busy;
    wire        div_fault;
    wire [3:0]  div_cause;
    wire [31:0] div_fault_pa;
    wire [31:0] div_load_data;
    wire        div_uart_we;
    wire [7:0]  div_uart_data;
    wire        div_halt;
    wire [31:0] div_exit_code;
    wire [31:0] div_irq_pending;

    integer fails = 0;
    integer cyc = 0;
    reg [31:0] cap_load;
    reg        cap_fault;
    reg [3:0]  cap_cause;
    reg        cap_uart_we;
    reg [7:0]  cap_uart_data;
    reg        cap_halt;
    reg [31:0] cap_exit_code;

    rvlinux_mmio_stage dut (
        .clk(clk), .rst(rst),
        .start(start), .is_store(is_store), .funct3(funct3),
        .pa(pa), .store_data(store_data),
        .rx_valid(rx_valid), .rx_byte_in(rx_byte_in), .rx_ready(rx_ready),
        .done(done), .busy(busy), .fault(fault), .cause(cause),
        .fault_pa(fault_pa), .load_data(load_data),
        .uart_we(uart_we), .uart_data(uart_data),
        .halt(halt), .exit_code(exit_code), .irq_pending(irq_pending)
    );

    rvlinux_mmio_stage #(
        .MTIME_TICK_CYCLES(32'd4)
    ) div_dut (
        .clk(clk), .rst(rst),
        .start(1'b0), .is_store(1'b0), .funct3(3'b010),
        .pa(32'd0), .store_data(32'd0),
        .rx_valid(1'b0), .rx_byte_in(8'd0), .rx_ready(div_rx_ready),
        .done(div_done), .busy(div_busy), .fault(div_fault),
        .cause(div_cause), .fault_pa(div_fault_pa),
        .load_data(div_load_data),
        .uart_we(div_uart_we), .uart_data(div_uart_data),
        .halt(div_halt), .exit_code(div_exit_code),
        .irq_pending(div_irq_pending),
        .mtime_out(div_mtime), .mtimecmp_out(div_mtimecmp),
        .mtime_full_out(div_mtime_full),
        .mtimecmp_full_out(div_mtimecmp_full)
    );

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (cyc > 1000) begin
            $display("MMIO_STAGE_RESULT: FAIL timeout");
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

    task mmio_op;
        input        store_i;
        input [2:0]  f3_i;
        input [31:0] pa_i;
        input [31:0] data_i;
        begin
            @(negedge clk);
            is_store = store_i;
            funct3 = f3_i;
            pa = pa_i;
            store_data = data_i;
            start = 1'b1;
            while (!done) @(negedge clk);
            cap_load = load_data;
            cap_fault = fault;
            cap_cause = cause;
            cap_uart_we = uart_we;
            cap_uart_data = uart_data;
            cap_halt = halt;
            cap_exit_code = exit_code;
            @(negedge clk);
            start = 1'b0;
            @(negedge clk);
        end
    endtask

    task inject_rx;
        input [7:0] value;
        begin
            @(negedge clk);
            rx_byte_in = value;
            rx_valid = 1'b1;
            #1;
            chk(rx_ready, "rx_ready_when_empty");
            @(posedge clk);
            @(negedge clk);
            rx_valid = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        chk(div_mtime == 32'd0, "mtime_div_holds_before_period");
        @(posedge clk);
        #1;
        chk(div_mtime == 32'd1, "mtime_div_ticks_on_period");

        mmio_op(1'b1, 3'b000, 32'h1000_0000, 32'h0000_0041);
        chk(!cap_fault && cap_uart_we && cap_uart_data == 8'h41,
            "uart_thr_store_emits_tx");

        mmio_op(1'b0, 3'b100, 32'h1000_0005, 32'd0);
        chk(!cap_fault && cap_load == 32'h0000_0060,
            "uart_lsr_empty_reports_thre_temt");

        inject_rx(8'h5A);
        mmio_op(1'b0, 3'b100, 32'h1000_0005, 32'd0);
        chk(!cap_fault && cap_load == 32'h0000_0061,
            "uart_lsr_reports_rx_ready");
        mmio_op(1'b0, 3'b100, 32'h1000_0000, 32'd0);
        chk(!cap_fault && cap_load == 32'h0000_005A,
            "uart_rbr_read_returns_rx_byte");
        mmio_op(1'b0, 3'b100, 32'h1000_0005, 32'd0);
        chk(!cap_fault && cap_load == 32'h0000_0060,
            "uart_rbr_read_consumes_rx_byte");

        mmio_op(1'b1, 3'b000, 32'h1000_0001, 32'h0000_0001);
        chk(!cap_fault, "uart_ier_enables_rx_irq");
        inject_rx(8'h33);
        mmio_op(1'b1, 3'b010, 32'h0C00_0004, 32'h0000_0001);
        chk(!cap_fault, "plic_priority_write");
        mmio_op(1'b1, 3'b010, 32'h0C00_2080, 32'h0000_0002);
        chk(!cap_fault && irq_pending[9], "plic_seip_pending_from_uart");
        mmio_op(1'b0, 3'b010, 32'h0C20_1004, 32'd0);
        chk(!cap_fault && cap_load == 32'd1 && !irq_pending[9],
            "plic_claim_reads_source_and_marks_claimed");
        mmio_op(1'b1, 3'b010, 32'h0C20_1004, 32'd1);
        chk(!cap_fault && irq_pending[9], "plic_complete_allows_repending");

        mmio_op(1'b1, 3'b010, 32'h0200_0000, 32'h0000_0001);
        chk(!cap_fault && irq_pending[3], "clint_msip_set");
        mmio_op(1'b1, 3'b010, 32'h0200_0000, 32'h0000_0000);
        chk(!cap_fault && !irq_pending[3], "clint_msip_clear");
        mmio_op(1'b1, 3'b010, 32'h0200_4000, 32'h0000_0000);
        chk(!cap_fault, "clint_mtimecmp_lo_write");
        mmio_op(1'b1, 3'b010, 32'h0200_4004, 32'h0000_0000);
        chk(!cap_fault && irq_pending[7], "clint_mtip_pending");

        mmio_op(1'b0, 3'b001, 32'h1000_0001, 32'd0);
        chk(cap_fault && cap_cause == 4'd4, "misaligned_half_load_fault");

        mmio_op(1'b1, 3'b010, 32'h1110_0000, 32'h0000_5555);
        chk(!cap_fault && cap_halt && cap_exit_code == 32'd0,
            "syscon_poweroff_exit_zero");

        if (fails == 0) $display("MMIO_STAGE_RESULT: PASS");
        else            $display("MMIO_STAGE_RESULT: FAIL (%0d errors)", fails);
        $finish;
    end
endmodule
