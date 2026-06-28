`timescale 1ns/1ps
// Sequential Sv32 page-table walker for the future multi-cycle rvlinux core.
// Access encoding at this PTW: 0=fetch(X), 1=load(R), 2=store/amo(W),
// 3=store-check/translate-only(W). The memory boundary maps load translate-only
// requests onto access=1, and maps store translate-only requests onto access=3.
module sv32_ptw #(
    parameter MEMWORDS = 16*1024*1024,
    parameter [31:0] RAMBASE = 32'h8000_0000
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [31:0] satp,
    input  wire [31:0] va,
    input  wire [1:0]  access,
    input  wire [1:0]  priv,
    input  wire        sum,
    input  wire        mxr,

    output reg         busy,
    output reg         done,
    output reg         fault,
    output reg  [3:0]  cause,
    output reg  [31:0] pa,
    output reg  [31:0] leaf_pte,
    output reg  [31:0] leaf_pte_pa,
    output reg         set_a,
    output reg         set_d,

    output reg         m_req,
    output reg         m_we,
    output reg  [31:0] m_addr,
    output reg  [31:0] m_wdata,
    input  wire [31:0] m_rdata,
    input  wire        m_ack
);
    localparam PRV_M = 2'd3;
    localparam ACC_FETCH = 2'd0;
    localparam ACC_LOAD  = 2'd1;
    localparam ACC_STORE = 2'd2;
    localparam ACC_STORE_CHECK = 2'd3;

    localparam S_IDLE  = 3'd0;
    localparam S_L1REQ = 3'd1;
    localparam S_L1ACK = 3'd2;
    localparam S_L0REQ = 3'd3;
    localparam S_L0ACK = 3'd4;
    localparam S_WAIT  = 3'd5;

    localparam [31:0] RAMBYTES = MEMWORDS * 4;
    localparam [31:0] RAMLAST  = RAMBASE + RAMBYTES;

    reg [2:0] state;
    reg [31:0] va_r;
    reg [1:0]  access_r;
    reg [1:0]  priv_r;
    reg        sum_r;
    reg        mxr_r;
    reg [31:0] pte1_pa_r;
    reg [31:0] pte0_pa_r;

    wire [31:0] start_pte1_pa = {satp[19:0], 12'b0} + {va[31:22], 2'b0};

    function in_ram;
        input [31:0] a;
        begin
            in_ram = (a >= RAMBASE) && (a < RAMLAST);
        end
    endfunction

    function is_bad_pte;
        input [31:0] pte;
        begin
            is_bad_pte = !pte[0] || (!pte[1] && pte[2]);
        end
    endfunction

    function is_leaf_pte;
        input [31:0] pte;
        begin
            is_leaf_pte = pte[3] || pte[1];
        end
    endfunction

    function is_misaligned_superpage;
        input [31:0] pte;
        begin
            is_misaligned_superpage = pte[19:10] != 10'd0;
        end
    endfunction

    function perm_ok;
        input [31:0] pte;
        input [1:0]  acc;
        input [1:0]  prv;
        input        sum_i;
        input        mxr_i;
        reg          readable;
        begin
            readable = pte[1] | (mxr_i & pte[3]);
            if (acc == ACC_FETCH)
                perm_ok = pte[3] && ((prv == 2'd0) ? pte[4] : !pte[4]);
            else
                perm_ok = ((acc == ACC_LOAD) ? readable : pte[2]) &&
                          ((prv == 2'd0) ? pte[4] : (!pte[4] | sum_i));
        end
    endfunction

    function [3:0] fault_cause;
        input [1:0] acc;
        begin
            fault_cause = (acc == ACC_FETCH) ? 4'd12 :
                          (acc == ACC_LOAD)  ? 4'd13 : 4'd15;
        end
    endfunction

    task finish_fault;
        begin
            busy <= 1'b0;
            done <= 1'b1;
            fault <= 1'b1;
            cause <= fault_cause(access_r);
            set_a <= 1'b0;
            set_d <= 1'b0;
            m_req <= 1'b0;
            state <= S_WAIT;
        end
    endtask

    task finish_leaf;
        input [31:0] pte;
        input [31:0] pte_pa;
        input        level1;
        begin
            busy <= 1'b0;
            done <= 1'b1;
            fault <= 1'b0;
            cause <= 4'd0;
            leaf_pte <= pte;
            leaf_pte_pa <= pte_pa;
            set_a <= !pte[6];
            set_d <= ((access_r == ACC_STORE) ||
                      (access_r == ACC_STORE_CHECK)) && !pte[7];
            pa <= level1 ? {pte[29:20], va_r[21:0]} : {pte[29:10], va_r[11:0]};
            m_req <= 1'b0;
            state <= S_WAIT;
        end
    endtask

    always @(posedge clk) begin
        done <= 1'b0;
        m_we <= 1'b0;
        m_wdata <= 32'd0;

        if (rst) begin
            state <= S_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            fault <= 1'b0;
            cause <= 4'd0;
            pa <= 32'd0;
            leaf_pte <= 32'd0;
            leaf_pte_pa <= 32'd0;
            set_a <= 1'b0;
            set_d <= 1'b0;
            m_req <= 1'b0;
            m_we <= 1'b0;
            m_addr <= 32'd0;
            m_wdata <= 32'd0;
            va_r <= 32'd0;
            access_r <= 2'd0;
            priv_r <= 2'd0;
            sum_r <= 1'b0;
            mxr_r <= 1'b0;
            pte1_pa_r <= 32'd0;
            pte0_pa_r <= 32'd0;
        end else begin
            case (state)
            S_IDLE: begin
                m_req <= 1'b0;
                set_a <= 1'b0;
                set_d <= 1'b0;
                if (start) begin
                    va_r <= va;
                    access_r <= access;
                    priv_r <= priv;
                    sum_r <= sum;
                    mxr_r <= mxr;
                    leaf_pte <= 32'd0;
                    leaf_pte_pa <= 32'd0;
                    cause <= 4'd0;
                    fault <= 1'b0;

                    if (!satp[31] || priv == PRV_M) begin
                        pa <= va;
                        busy <= 1'b0;
                        done <= 1'b1;
                        state <= S_WAIT;
                    end else begin
                        busy <= 1'b1;
                        pte1_pa_r <= start_pte1_pa;
                        if (!in_ram(start_pte1_pa)) begin
                            done <= 1'b1;
                            busy <= 1'b0;
                            fault <= 1'b1;
                            cause <= fault_cause(access);
                            state <= S_WAIT;
                        end else begin
                            m_addr <= start_pte1_pa;
                            state <= S_L1REQ;
                        end
                    end
                end
            end

            S_L1REQ: begin
                m_req <= 1'b1;
                m_addr <= pte1_pa_r;
                state <= S_L1ACK;
            end

            S_L1ACK: begin
                m_req <= 1'b1;
                m_addr <= pte1_pa_r;
                if (m_ack) begin
                    m_req <= 1'b0;
                    if (is_bad_pte(m_rdata)) begin
                        finish_fault();
                    end else if (is_leaf_pte(m_rdata)) begin
                        if (is_misaligned_superpage(m_rdata) ||
                            !perm_ok(m_rdata, access_r, priv_r, sum_r, mxr_r))
                            finish_fault();
                        else
                            finish_leaf(m_rdata, pte1_pa_r, 1'b1);
                    end else begin
                        pte0_pa_r <= {m_rdata[29:10], 12'b0} + {va_r[21:12], 2'b0};
                        if (!in_ram({m_rdata[29:10], 12'b0} + {va_r[21:12], 2'b0})) begin
                            finish_fault();
                        end else begin
                            m_addr <= {m_rdata[29:10], 12'b0} + {va_r[21:12], 2'b0};
                            state <= S_L0REQ;
                        end
                    end
                end
            end

            S_L0REQ: begin
                m_req <= 1'b1;
                m_addr <= pte0_pa_r;
                state <= S_L0ACK;
            end

            S_L0ACK: begin
                m_req <= 1'b1;
                m_addr <= pte0_pa_r;
                if (m_ack) begin
                    m_req <= 1'b0;
                    if (is_bad_pte(m_rdata) || !is_leaf_pte(m_rdata) ||
                        !perm_ok(m_rdata, access_r, priv_r, sum_r, mxr_r))
                        finish_fault();
                    else
                        finish_leaf(m_rdata, pte0_pa_r, 1'b0);
                end
            end

            S_WAIT: begin
                m_req <= 1'b0;
                if (!start) state <= S_IDLE;
            end

            default: begin
                state <= S_IDLE;
                busy <= 1'b0;
                m_req <= 1'b0;
            end
            endcase
        end
    end
endmodule
