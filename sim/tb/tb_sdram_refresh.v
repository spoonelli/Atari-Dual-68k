// tb_sdram_refresh: JEDEC retention gate for sdram_simple's auto-refresh.
//
// REFRESH-111. The same spec violation was "fixed" three different ways on
// three branches (Pocket 160, mister-port 224, sdram-sched 250 + deferral
// deleted), each justified by hand arithmetic, none by measurement. This
// bench measures the thing that actually matters:
//
//   the MAXIMUM number of clocks between two consecutive AUTO REFRESH
//   commands on the SDRAM command bus, under adversarial bus pressure.
//
// That is the quantity JEDEC bounds. For the MT48LC16M16A2 the requirement is
// 8192 rows in 64 ms, i.e. one AUTO REFRESH every 7.8125 us on average, and
// the per-row retention limit is what a burst of deferral eats into.
//
// Why measure rather than compute: the paper model everyone used was
//     worst case = REFRESH_INTERVAL + DEFER_CAP
// and it is wrong in the safe-looking direction. `refresh_due` is only
// consumed from S_IDLE, so when the deferral cap expires the controller must
// still finish the transaction in flight (a precharge-armored CPU read is 15
// clocks) and clear the read ack before it can issue the refresh. The paper
// model silently drops those clocks and reports more margin than exists.
//
// The bench drives the DUT with continuous back-to-back rd_pre reads, which is
// the pattern that maximises deferral: every read re-arms the "a read is
// pending" condition that the refresh yields to, and rd_pre selects the
// longest transaction the FSM has.
//
// Run: ./sim/run_sdram_refresh_tb.sh   (sweeps the candidate policies)
`timescale 1ns/1ps

module tb_sdram_refresh;
    parameter REFRESH_INTERVAL = 160;
    parameter DEFER_CAP        = 48;
    // Adversary: 1 = saturate the read port (worst case), 0 = idle bus.
    parameter READ_PRESSURE    = 1;
    // Write pressure runs the ROM-download client concurrently.
    parameter WRITE_PRESSURE   = 0;
    // Clock period, ns. 35.795455 MHz -> 27.936508 ns (mf_pllbase outclk_2).
    parameter real CLK_NS      = 27.936508;
    // MT48LC16M16A2: 8192 rows / 64 ms.
    parameter real JEDEC_US    = 7.8125;
    parameter integer RUN_CLKS = 400000;   // ~11 ms of SDRAM time

    reg clk = 0;
    always #(CLK_NS/2.0) clk = ~clk;
    reg reset_n = 0;

    wire [12:0] dram_a;
    wire [1:0]  dram_ba, dram_dqm;
    wire        dram_cas_n, dram_ras_n, dram_we_n, dram_cke;
    wire        init_done;

    wire        rd_req;
    reg         rd_req_q = 0;
    reg         wr_req = 0;
    wire        rd_ack, wr_ack;
    reg  [24:0] rd_addr = 25'h0100000, wr_addr = 25'h0200000;
    reg  [31:0] wr_data = 32'hA5A5_5A5A;
    wire [31:0] rd_data;
    // rd_pre selects the precharge-armored CPU read: the longest transaction
    // the FSM has, and therefore the one that stretches the deferral furthest.
    reg         rd_pre = 1;

    wire [15:0] dram_dq;
    assign dram_dq = 16'hZZZZ;      // no memory model needed: we watch commands

`ifdef DUT_OPENROW
    // SDRAM-ARCH: the same JEDEC retention gate, run against the open-row
    // controller. An open row must never survive a refresh window, and the
    // worst-case row interval must still be inside 7.8125 us WITH the extra
    // PRECHARGE ALL that a refresh now has to issue first. Both negative
    // controls must still be rejected.
    sdram_openrow #(
        .REFRESH_INTERVAL (REFRESH_INTERVAL),
        .DEFER_CAP        (DEFER_CAP)
    ) dut (
`else
    sdram_simple #(
        .REFRESH_INTERVAL (REFRESH_INTERVAL),
        .DEFER_CAP        (DEFER_CAP)
    ) dut (
`endif
        .clk(clk), .reset_n(reset_n),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq),
        .dram_dqm(dram_dqm), .dram_cas_n(dram_cas_n), .dram_ras_n(dram_ras_n),
        .dram_we_n(dram_we_n), .dram_cke(dram_cke),
        .wr_req(wr_req), .wr_ack(wr_ack), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_req(rd_req), .rd_ack(rd_ack), .rd_addr(rd_addr), .rd_pre(rd_pre),
        .rd_data(rd_data), .init_done(init_done)
    );

    // ---- adversarial read clients ----
    // READ_PRESSURE selects how hard the read port is driven. The distinction
    // MATTERS, and getting it wrong is how a bench like this lulls you:
    //
    //   0 - idle. No reads at all.
    //   1 - "polite" back-to-back: drop rd_req on seeing rd_ack, re-assert the
    //       next clock. This looks like saturation but does NOT engage the
    //       deferral. The deferral yields only to a request that is pending AND
    //       UNACKED (`rd_req && ~rd_ack`). A polite client still has rd_req
    //       high while rd_ack is high, so at S_IDLE the term is false and the
    //       refresh wins immediately. Worst gap lands at interval + ~11.
    //   2 - "handshake-tight": rd_req = ~rd_ack. This is what an arbiter with
    //       another client already queued looks like: rd_ack clears on one
    //       S_IDLE cycle, and on the very next cycle rd_req is high with
    //       rd_ack low, so `rd_req && ~rd_ack` holds and the refresh defers
    //       until refresh_age reaches DEFER_CAP.
    //   3 - BURSTY (the actual worst case). Mode 2 is still not enough, and
    //       the reason is worth stating because it is a trap:
    //
    //       refresh_ctr is free-running and is reset when refresh_due is SET,
    //       not when the refresh is SERVICED. So the request rate is exactly
    //       REFRESH_INTERVAL regardless of deferral, and the command-to-command
    //       gap is  INTERVAL + delay(n+1) - delay(n).  Under CONSTANT
    //       saturation every refresh waits the same ~DEFER_CAP+15 clocks, the
    //       delays cancel, and the measured gap collapses back to INTERVAL+1 -
    //       a comfortable-looking number that hides the whole problem.
    //
    //       The worst case is a TRANSITION: one refresh serviced instantly on
    //       an idle bus (delay 0) followed by one serviced at the cap
    //       (delay DEFER_CAP+15). That gap is INTERVAL + DEFER_CAP + 15. Mode 3
    //       drives the bus in LFSR-gated bursts so every phase relationship
    //       between the burst edges and the refresh timer gets sampled.
    //
    // Modes 1 and 2 are kept because they are the traps: both report
    // comfortable margin for policies that mode 3 shows to be out of spec.
    reg [15:0] lfsr = 16'hACE1;
    reg        burst = 0;
    reg [5:0]  burst_ctr = 0;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        burst_ctr <= burst_ctr + 6'd1;
        if (burst_ctr == 6'd0) burst <= lfsr[0];   // re-roll every 64 clocks
    end
    assign rd_req = (READ_PRESSURE == 2) ? (reset_n && ~rd_ack)
                  : (READ_PRESSURE == 3) ? (reset_n && burst && ~rd_ack)
                  : rd_req_q;
    always @(posedge clk) begin
        if (!reset_n) rd_req_q <= 1'b0;
        else if (READ_PRESSURE == 1) begin
            if (!rd_req_q)    rd_req_q <= 1'b1;
            else if (rd_ack) begin
                rd_req_q <= 1'b0;           // drop; re-asserted next clock
                rd_addr  <= rd_addr + 25'd4;
            end
        end
    end
    always @(posedge clk) begin
        if (!reset_n) wr_req <= 1'b0;
        else if (WRITE_PRESSURE) begin
            if (!wr_req)      wr_req <= 1'b1;
            else if (wr_ack) begin
                wr_req  <= 1'b0;
                wr_addr <= wr_addr + 25'd4;
            end
        end
    end

    // ---- the measurement: gaps between AUTO REFRESH commands ----
    // CMD_REFRESH is {ras_n,cas_n,we_n} == 3'b001. The command bus is
    // registered and holds its value, so count an ISSUE only on the cycle the
    // bus enters that encoding.
    wire [2:0] cmdbus = {dram_ras_n, dram_cas_n, dram_we_n};
    reg  [2:0] cmdbus_d = 3'b111;
    wire       refresh_issue = (cmdbus == 3'b001) && (cmdbus_d != 3'b001);

    integer max_age;      // highest refresh_age seen: did the deferral engage?
    integer max_svc;      // max refresh_age AT THE MOMENT OF ISSUE = how many
                          // clocks a due refresh actually waited for service.
    integer n_lost;       // intervals that elapsed while a refresh was ALREADY
                          // due: that request is merged, i.e. a refresh is LOST.
    integer gap, max_gap, n_ref, n_clk, armed, n_over;
    integer gap_hist_le_interval, total_gap;
    real    max_us, mean_us, occupancy_pct, jedec_clks;

    initial begin
        gap = 0; max_gap = 0; n_ref = 0; n_clk = 0; armed = 0; n_over = 0;
        total_gap = 0; max_age = 0; max_svc = 0; n_lost = 0;
        reset_n = 0;
        repeat (20) @(posedge clk);
        reset_n = 1;
        @(posedge init_done);
        repeat (200) @(posedge clk);     // let the FSM settle past init
        armed = 1;
        repeat (RUN_CLKS) @(posedge clk);
        armed = 0;

        jedec_clks = (JEDEC_US * 1000.0) / CLK_NS;
        max_us  = max_gap * CLK_NS / 1000.0;
        mean_us = (n_ref > 1) ? (total_gap * CLK_NS / 1000.0) / (n_ref - 1) : 0.0;
        // Each refresh costs the issue cycle plus tRFC (wait_ctr 9 -> 10 clks).
        occupancy_pct = (n_ref > 1)
                      ? 100.0 * 11.0 * (n_ref - 1) / total_gap : 0.0;

        $display("TB_SDRAM_REFRESH cfg interval=%0d defer_cap=%0d read_pressure=%0d write_pressure=%0d clk=%0.6fns",
                 REFRESH_INTERVAL, DEFER_CAP, READ_PRESSURE, WRITE_PRESSURE, CLK_NS);
        $display("TB_SDRAM_REFRESH refreshes=%0d over %0d clks", n_ref, n_clk);
        $display("TB_SDRAM_REFRESH mean gap  = %0.3f us", mean_us);
        $display("TB_SDRAM_REFRESH WORST gap = %0d clks = %0.4f us   (JEDEC limit %0.4f us = %0.1f clks)",
                 max_gap, max_us, JEDEC_US, jedec_clks);
        $display("TB_SDRAM_REFRESH margin    = %0.4f us (%0.2f%% of the JEDEC budget)",
                 JEDEC_US - max_us, 100.0 * max_us / JEDEC_US);
        $display("TB_SDRAM_REFRESH paper model (interval+defer_cap) would have said %0d clks = %0.4f us -- understates by %0d clks",
                 REFRESH_INTERVAL + DEFER_CAP,
                 (REFRESH_INTERVAL + DEFER_CAP) * CLK_NS / 1000.0,
                 max_gap - (REFRESH_INTERVAL + DEFER_CAP));
        $display("TB_SDRAM_REFRESH refresh occupancy = %0.3f%% of SDRAM bus clocks",
                 occupancy_pct);
        // If max_age never approaches DEFER_CAP the deferral never engaged and
        // this run is NOT a worst-case measurement, whatever the gap says.
        $display("TB_SDRAM_REFRESH max refresh_age = %0d (DEFER_CAP=%0d) -> deferral %0s",
                 max_age, DEFER_CAP,
                 (DEFER_CAP != 0 && max_age >= DEFER_CAP) ? "ENGAGED to the cap"
                 : (max_age > 1) ? "engaged partially" : "never engaged");
        $display("TB_SDRAM_REFRESH max service delay = %0d clks (refresh_age when the command actually issued)",
                 max_svc);
        $display("TB_SDRAM_REFRESH merged/lost refresh requests = %0d", n_lost);

        if (n_ref < 10)
            $display("TB_SDRAM_REFRESH FAIL: only %0d refreshes observed - the bench measured nothing", n_ref);
        else if (max_us > JEDEC_US)
            $display("TB_SDRAM_REFRESH FAIL: worst-case row interval %0.4f us EXCEEDS the %0.4f us JEDEC limit",
                     max_us, JEDEC_US);
        else
            $display("TB_SDRAM_REFRESH PASS: worst-case row interval %0.4f us is within the %0.4f us JEDEC limit",
                     max_us, JEDEC_US);
        $finish;
    end

    always @(posedge clk) begin
        cmdbus_d <= cmdbus;
        if (armed) begin
            if (dut.refresh_age > max_age) max_age = dut.refresh_age;
            if (refresh_issue && dut.refresh_age > max_svc)
                max_svc = dut.refresh_age;
            // A second interval expiring while refresh_due is still set does
            // not queue a second refresh - refresh_due is a single flag, so
            // the request is silently merged and one row refresh is LOST.
            if (dut.refresh_due && dut.refresh_ctr == REFRESH_INTERVAL[9:0])
                n_lost = n_lost + 1;
            n_clk <= n_clk + 1;
            gap = gap + 1;
            if (refresh_issue) begin
                n_ref = n_ref + 1;
                if (n_ref > 1) begin          // first gap is a partial interval
                    total_gap = total_gap + gap;
                    if (gap > max_gap) max_gap = gap;
                    if (gap * CLK_NS / 1000.0 > JEDEC_US) n_over = n_over + 1;
                end
                gap = 0;
            end
        end
    end
endmodule
