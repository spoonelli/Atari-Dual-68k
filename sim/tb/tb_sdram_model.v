// tb_sdram_model: self-test for sim/tb/sdram_model.v.
//
// The model is the instrument every later open-row claim rests on, so it gets
// its own gate FIRST, and that gate is built out of MUTATIONS: each mode below
// injects one specific defect and asserts that the model REPORTS it. A checker
// that has never been seen to fail is not evidence, and this repo has been
// burned fourteen times by exactly that.
//
//   MODE 0  clean run: the shipping controller against the model.
//           EXPECT violations = 0 and data mismatches = 0.
//   MODE 1  wrong-row serve. After the controller opens a row we corrupt the
//           model's latched row. EXPECT data mismatches > 0.
//           This is the v38 bug class - "valid data, valid parity, wrong
//           location" - and it is the one an open-row policy can reintroduce.
//   MODE 2  READ with no row open. EXPECT read_no_row > 0.
//   MODE 3  AUTO REFRESH with a bank left ACTIVE. EXPECT refresh_with_open_bank > 0.
//           This is the specific hazard of holding rows open.
//   MODE 4  tRCD violation: READ issued the clock after ACTIVE.
//           EXPECT tRCD > 0.
//   MODE 5  tRAS(min) violation: PRECHARGE immediately after ACTIVE.
//           EXPECT tRASmin > 0.
//
// MODES 4 AND 5 RUN AT 100 MHz, NOT 35.795455, AND THAT IS THE POINT.
// At 35.795455 MHz the device minimums round to tRCD = tRP = 1 clock and
// tRAS(min) = 2, so ACTIVE followed by READ on the very next clock is
// PERFECTLY LEGAL and there is no way to express a tRCD violation at all.
// The first version of this bench ran them at the shipping clock, injected
// "violations" that were not violations, and correctly reported nothing -
// which would have been indistinguishable from a broken checker. Running them
// at 10 ns makes tRCD = 2 and tRAS(min) = 5, so back-to-back commands really
// do violate the part and the checker really is exercised.
//
// It also measures something useful in its own right: those minimums are
// nearly free at 35.8 MHz, which is why an open-row policy has so much timing
// headroom here, and why that headroom shrinks if the clock is raised.
//
// Modes 2-5 drive the model's pins DIRECTLY from the bench rather than through
// the controller, because the point is to test the model, not the controller.
`timescale 1ns/1ps
`default_nettype none

module tb_sdram_model;
    parameter integer MODE   = 0;
    parameter real    CLK_NS = 27.936508;
    parameter integer NREADS = 300;

    reg clk = 0;
    always #(CLK_NS/2.0) clk = ~clk;
    reg reset_n = 0;

    // ---- controller <-> model wiring ----
    wire [12:0] c_a;
    wire [1:0]  c_ba, c_dqm;
    wire        c_ras_n, c_cas_n, c_we_n, c_cke;
    wire [15:0] dq;

    // Bench override of the command bus for the direct-drive modes.
    reg         ovr    = 1'b0;
    reg [12:0]  o_a    = 13'd0;
    reg [1:0]   o_ba   = 2'd0;
    reg [2:0]   o_cmd  = 3'b111;

    wire [12:0] m_a     = ovr ? o_a       : c_a;
    wire [1:0]  m_ba    = ovr ? o_ba      : c_ba;
    wire        m_ras_n = ovr ? o_cmd[2]  : c_ras_n;
    wire        m_cas_n = ovr ? o_cmd[1]  : c_cas_n;
    wire        m_we_n  = ovr ? o_cmd[0]  : c_we_n;
    wire [1:0]  m_dqm   = ovr ? 2'b00     : c_dqm;
    wire        m_cke   = ovr ? 1'b1      : c_cke;

    reg         rd_req = 0;
    wire        rd_ack;
    reg  [24:0] rd_addr = 25'h0000000;
    reg         rd_pre  = 1;
    wire [31:0] rd_data;
    wire        init_done;

    sdram_simple dut (
        .clk(clk), .reset_n(reset_n),
        .dram_a(c_a), .dram_ba(c_ba), .dram_dq(dq),
        .dram_dqm(c_dqm), .dram_cas_n(c_cas_n), .dram_ras_n(c_ras_n),
        .dram_we_n(c_we_n), .dram_cke(c_cke),
        .wr_req(1'b0), .wr_ack(), .wr_addr(25'd0), .wr_data(32'd0),
        .rd_req(rd_req), .rd_ack(rd_ack), .rd_addr(rd_addr), .rd_pre(rd_pre),
        .rd_data(rd_data), .init_done(init_done)
    );

    sdram_model #(.CLK_NS(CLK_NS), .VERBOSE(0)) mem (
        .clk(clk), .cke(m_cke), .a(m_a), .ba(m_ba),
        .ras_n(m_ras_n), .cas_n(m_cas_n), .we_n(m_we_n),
        .dqm(m_dqm), .dq(dq)
    );

    // ---- expected-data checking -----------------------------------------
    integer n_checked, n_mismatch;
    reg [23:0] exp_word;
    function [15:0] expf(input [23:0] wa);
        reg [31:0] h;
        begin
            h = {8'h00, wa} ^ 32'h9E3779B9;
            h = h * 32'h85EBCA6B;
            h = h ^ (h >> 13);
            h = h * 32'hC2B2AE35;
            h = h ^ (h >> 16);
            expf = h[15:0];
        end
    endfunction

    integer i;
    integer fails;

    // MODE 1: corrupt the model's latched row one clock after every ACTIVE, so
    // subsequent READs are served from a row the controller did not open.
    wire [2:0] cmdbus = {c_ras_n, c_cas_n, c_we_n};
    reg        act_d = 0;
    always @(posedge clk) begin
        act_d <= (cmdbus == 3'b011);
        if (MODE == 1 && act_d && reset_n)
            mem.bk_row[0] = mem.bk_row[0] ^ 13'h0040;   // flip one row bit
    end

    task do_reads(input integer n);
        begin
            for (i = 0; i < n; i = i + 1) begin
                rd_addr = 25'h0000000 + (i * 25'd4);
                @(posedge clk);
                rd_req = 1;
                wait (rd_ack == 1);
                @(posedge clk);
                exp_word = rd_addr[24:1];
                n_checked = n_checked + 2;
                if (rd_data[31:16] !== expf(exp_word))
                    n_mismatch = n_mismatch + 1;
                if (rd_data[15:0]  !== expf(exp_word + 24'd1))
                    n_mismatch = n_mismatch + 1;
                rd_req = 0;
                @(posedge clk);
                wait (rd_ack == 0);
            end
        end
    endtask

    // Direct command driver for the model-only mutation modes. Leaves the
    // bench sitting immediately after the posedge that registered the command,
    // so two consecutive calls place two commands on CONSECUTIVE clocks - which
    // is what makes a tRCD/tRAS violation expressible at all.
    task cmd_at(input [2:0] c, input [1:0] bank, input [12:0] addr);
        begin
            @(negedge clk);
            o_cmd = c; o_ba = bank; o_a = addr;
            @(posedge clk);
            o_cmd = 3'b111;
        end
    endtask

    task idle_clks(input integer n);
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    initial begin
        n_checked = 0; n_mismatch = 0; fails = 0;
        reset_n = 0;
        repeat (20) @(posedge clk);
        reset_n = 1;
        @(posedge init_done);
        repeat (50) @(posedge clk);

        if (MODE == 0 || MODE == 1) begin
            do_reads(NREADS);
        end else begin
            // Take the command bus away from the controller. The controller is
            // idle (rd_req low) so it emits only NOPs; we drive the mutation.
            ovr = 1;
            idle_clks(20);
            case (MODE)
            2: begin
                // READ with no row open.
                cmd_at(3'b101, 2'd0, 13'h0010);
            end
            3: begin
                // ACTIVE, wait out tRCD/tRAS, then AUTO REFRESH with the row
                // still open - no PRECHARGE in between.
                cmd_at(3'b011, 2'd0, 13'h0123);
                idle_clks(6);
                cmd_at(3'b001, 2'd0, 13'h0000);
            end
            4: begin
                // tRCD: READ on the very next clock after ACTIVE.
                cmd_at(3'b011, 2'd1, 13'h0055);
                cmd_at(3'b101, 2'd1, 13'h0010);
            end
            5: begin
                // tRAS(min): PRECHARGE on the very next clock after ACTIVE.
                cmd_at(3'b011, 2'd2, 13'h0077);
                cmd_at(3'b010, 2'd2, 13'h0000);
            end
            default: ;
            endcase
            idle_clks(40);
        end

        $display("TB_SDRAM_MODEL mode=%0d", MODE);
        $display("TB_SDRAM_MODEL words checked=%0d mismatches=%0d", n_checked, n_mismatch);
        mem.report_model;

        // ---- verdicts: each mode asserts the SPECIFIC thing it injected ----
        case (MODE)
        0: begin
            if (mem.v_total != 0) begin
                $display("TB_SDRAM_MODEL FAIL: clean run reported %0d protocol violations", mem.v_total);
                fails = 1;
            end
            if (n_mismatch != 0) begin
                $display("TB_SDRAM_MODEL FAIL: clean run had %0d data mismatches", n_mismatch);
                fails = 1;
            end
            if (n_checked < 2*NREADS) begin
                $display("TB_SDRAM_MODEL FAIL: only %0d words checked - the bench did not run", n_checked);
                fails = 1;
            end
        end
        1: if (n_mismatch == 0) begin
            $display("TB_SDRAM_MODEL FAIL: wrong-row mutation produced NO data mismatch -");
            $display("  the model is not serving from the latched row, so it could never");
            $display("  catch a stale-row serve. This invalidates every open-row result.");
            fails = 1;
        end
        2: if (mem.v_read_no_row == 0) begin
            $display("TB_SDRAM_MODEL FAIL: READ with no open row was not reported"); fails = 1;
        end
        3: if (mem.v_refresh_open == 0) begin
            $display("TB_SDRAM_MODEL FAIL: AUTO REFRESH with an ACTIVE bank was not reported -");
            $display("  this is THE open-row hazard and the model cannot see it."); fails = 1;
        end
        4: if (mem.v_trcd == 0) begin
            $display("TB_SDRAM_MODEL FAIL: tRCD violation was not reported"); fails = 1;
        end
        5: if (mem.v_tras_min == 0) begin
            $display("TB_SDRAM_MODEL FAIL: tRAS(min) violation was not reported"); fails = 1;
        end
        default: ;
        endcase

        if (fails) $display("TB_SDRAM_MODEL RESULT FAIL");
        else       $display("TB_SDRAM_MODEL RESULT PASS");
        $finish;
    end

    // Watchdog: a hung handshake must not look like a pass.
    initial begin
        #(CLK_NS * 400000);
        $display("TB_SDRAM_MODEL RESULT FAIL: timeout - handshake hung");
        $finish;
    end
endmodule

`default_nettype wire
