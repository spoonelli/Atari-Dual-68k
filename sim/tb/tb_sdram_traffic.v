// tb_sdram_traffic: the SDRAM controller under REALISTIC multi-client load.
//
// STAGE 1 of the open-row work. It answers three questions the repo has never
// had an instrument for:
//
//   1. what fraction of accesses would HIT an already-open row,
//   2. what CAUSES the misses - same-client stride, client switch, or refresh,
//   3. what the access latency actually is, mean and worst, per client.
//
// and one more that decides the whole project:
//
//   4. with the ROM shadows off, can the controller keep up with the motion
//      objects' real per-frame fetch demand, or does a backlog build?
//
// WHAT IS REAL HERE AND WHAT IS NOT. This matters more than the numbers.
//
//  REAL - the controller. src/fpga/core/rtl/sdram_simple.v, unmodified.
//  REAL - the memory. sim/tb/sdram_model.v, which serves from the physically
//         open row and checks every JEDEC timing (its own mutation gate is
//         sim/run_sdram_model_tb.sh).
//  REAL - the motion-object address stream AND its arrival times.
//         sim/work/mo_addr.hex / mo_time.hex are captured from tb_mob_perf.v
//         driving the real escape_mob.v against real sprite RAM
//         (sim/work/game_mo.hex) and real graphics (sim/work/image_bytes.hex),
//         one full frame, 8185 fetches. Nothing about MO is invented.
//  REAL - the video CPU program-fetch address stream, when USE_CPU_TRACE=1:
//         sim/work/cpu_addr.hex from tb_escape_core.vhd running the REAL game
//         ROM through the REAL TG68K with SHAD_EN=>0.
//
//  MODELLED - the arbiter. core_top.v's read arbitration is not instantiable
//         by any bench (it is welded into a 3000-line module), so the priority
//         chain is reproduced here. Every grant condition is quoted verbatim
//         from core_top.v above the code that implements it, so a drift is
//         reviewable. THIS IS THE WEAKEST LINK IN THE BENCH and it is called
//         out rather than buried.
//  MODELLED - the extra CPU's addresses: the video trace offset by +0x080000,
//         which is the region escape_core actually maps it to. Its locality is
//         therefore assumed equal to the video CPU's, not measured.
//  MODELLED - CPU fill RATE. VFILL_PCT/EFILL_PCT set what fraction of 4-clock
//         bus cycles produce an SDRAM fill. docs/VSHAD3.md measures ~39% with
//         shadows on and ~70% with them off; both are selectable.
//
// THE CPU LOCALITY CAVEAT, stated plainly. The captured CPU trace covers early
// boot, which sits in a tight RAM-test loop: 7633 fetches over TWO 1 KB rows,
// 99.99% same-row. That is real code but it is not steady-state gameplay, and
// using it alone would flatter the open-row case enormously. So the default is
// USE_CPU_TRACE=0 and a SYNTHETIC stream parameterised by CPU_ROW_RES - the
// mean number of consecutive fetches before the CPU jumps to an unrelated row.
// The bench is meant to be SWEPT over CPU_ROW_RES, and the conclusion reported
// only if it holds across the whole plausible range. A single number from a
// single locality assumption would not be evidence.
//
`timescale 1ns/1ps
`default_nettype none

module tb_sdram_traffic;
    parameter real    CLK_NS      = 27.936508; // 35.795455 MHz
    parameter integer CPU_RATIO   = 5;         // SDRAM clocks per CPU clock
    parameter integer CPU_BUSCYC  = 4;         // CPU clocks per bus cycle (zero wait)
    parameter integer VFILL_PCT   = 70;        // % of video bus cycles needing a fill
    parameter integer EFILL_PCT   = 70;        // ditto extra CPU
    parameter integer CPU_ROW_RES = 64;        // synthetic: fetches per row before a jump
    parameter integer USE_CPU_TRACE = 0;       // 1 = real captured video-CPU trace
    parameter integer MO_EN       = 1;
    parameter integer CPU_EN      = 1;
    parameter integer RUN_CLKS    = 600000;    // ~one frame of SDRAM clocks
    parameter integer MO_N        = 8185;      // records in the MO trace
    parameter integer CPU_N       = 7633;      // records in the CPU trace
    parameter integer MO_OUTSTAND = 4;         // escape_mob has 4 fetch channels
    parameter integer VERBOSE     = 0;
    // Only used when compiled with -DDUT_OPENROW. Kept here so the two halves
    // of the change can be measured SEPARATELY: open-row alone, banks alone,
    // and both. A combined-only number gives nobody anything to bisect.
    parameter integer OPENROW_EN  = 1;
    parameter integer BANKMAP_EN  = 1;

    // Client ids
    localparam C_NONE = 0, C_FPV = 1, C_FPE = 2, C_MO = 3;

    reg clk = 0;
    always #(CLK_NS/2.0) clk = ~clk;
    reg reset_n = 0;

    // ---- DUT + memory ---------------------------------------------------
    wire [12:0] dram_a;
    wire [1:0]  dram_ba, dram_dqm;
    wire        dram_cas_n, dram_ras_n, dram_we_n, dram_cke;
    wire [15:0] dram_dq;
    wire        init_done;

    reg         sd_rd_req = 0;
    wire        sd_rd_ack;
    reg  [24:0] rd_addr_q = 25'd0;
    wire [31:0] sd_rd_data;

`ifdef DUT_OPENROW
    sdram_openrow #(.OPENROW_EN(OPENROW_EN), .BANKMAP_EN(BANKMAP_EN)) dut (
`else
    sdram_simple dut (
`endif
        .clk(clk), .reset_n(reset_n),
        .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq),
        .dram_dqm(dram_dqm), .dram_cas_n(dram_cas_n), .dram_ras_n(dram_ras_n),
        .dram_we_n(dram_we_n), .dram_cke(dram_cke),
        .wr_req(1'b0), .wr_ack(), .wr_addr(25'd0), .wr_data(32'd0),
        .rd_req(sd_rd_req), .rd_ack(sd_rd_ack), .rd_addr(rd_addr_q),
        .rd_pre(1'b1),                      // core_top.v hardwires this to 1
        .rd_data(sd_rd_data), .init_done(init_done)
    );

    sdram_model #(.CLK_NS(CLK_NS)) mem (
        .clk(clk), .cke(dram_cke), .a(dram_a), .ba(dram_ba),
        .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n),
        .dqm(dram_dqm), .dq(dram_dq)
    );

    // ---- traces ---------------------------------------------------------
    reg [23:0] mo_addr [0:MO_N-1];
    reg [31:0] mo_time [0:MO_N-1];
    reg [23:0] cpu_addr[0:CPU_N-1];
    initial begin
        $readmemh("sim/work/mo_addr.hex",  mo_addr);
        $readmemh("sim/work/mo_time.hex",  mo_time);
        $readmemh("sim/work/cpu_addr.hex", cpu_addr);
        // Fixture guard. sim/work/ is gitignored; a missing fixture reads back
        // as all-X and would otherwise produce a confident zero. A
        // zero-fetch/zero-cell result is a MISSING FIXTURE, not a pass.
        if (MO_EN && (mo_addr[0] === 24'hxxxxxx || mo_addr[MO_N-1] === 24'hxxxxxx)) begin
            $display("TB_SDRAM_TRAFFIC FAIL: sim/work/mo_addr.hex missing or short - fixtures not copied");
            $finish;
        end
        if (USE_CPU_TRACE && cpu_addr[0] === 24'hxxxxxx) begin
            $display("TB_SDRAM_TRAFFIC FAIL: sim/work/cpu_addr.hex missing - fixtures not copied");
            $finish;
        end
    end

    integer now;                // SDRAM clock counter since arming
    reg     armed;

    // ---- client demand generators ---------------------------------------
    // Video / extra CPU: one bus cycle every CPU_RATIO*CPU_BUSCYC SDRAM clocks
    // (5*4 = 20 at the shipping ratio = the zero-wait-state 4-clock bus cycle
    // the schematic audit established for the real board). A percentage of
    // those bus cycles need an SDRAM fill; the rest hit a shadow or a cache.
    localparam integer BUSCLKS = CPU_RATIO * CPU_BUSCYC;

    reg        fpv_pend, fpe_pend;
    reg [23:0] fpv_a, fpe_a;
    integer    fpv_due, fpe_due;          // clock the request became pending
    integer    fpv_i, fpe_i;              // stream position
    integer    fpv_run, fpe_run;          // fetches since last row jump
    reg [31:0] lfsr;

    // MO: replayed in issue order with its REAL arrival times. Up to
    // MO_OUTSTAND may be in flight at once (escape_mob has 4 channels), which
    // is what lets a backlog form and be measured rather than silently
    // throttling demand to whatever the controller can manage.
    integer    mo_next;                   // next trace record to become due
    integer    mo_head;                   // next record to be served
    reg        mo_pend;
    reg [23:0] mo_a;
    integer    mo_due;
    integer    mo_backlog, mo_backlog_max;

    // ---- ownership (mirrors core_top.v) ----------------------------------
    integer    owner;
    integer    grant_clk;                 // clock the grant was issued
    integer    demand_clk;                // clock that request became pending

    // ---- open-row bookkeeping (the Stage 1 measurement) ------------------
    // We are measuring what an open-row policy WOULD achieve against the
    // access sequence the real arbiter produces. The current FSM closes the
    // row every time, so this is a counterfactual - but the SEQUENCE is real.
    // Per-BANK open row, because with bank interleaving each bank keeps its
    // own. Modelling a single global open row would understate the banked
    // case by exactly the amount the change is worth.
    reg [3:0]  orb_valid;
    reg [12:0] orb_row [0:3];
    reg        or_valid;
    reg [1:0]  or_bank;
    reg [12:0] or_row;
    integer    prev_client;
    // Per-BANK last client. With bank interleaving the question "did a client
    // switch cost us this row?" must be asked about the previous access TO
    // THAT BANK, not the previous access overall - each bank keeps its own
    // open row, so what some other client did to some other bank is
    // irrelevant. Using the global previous client (as the first version of
    // this taxonomy did) mislabels a client's OWN stride miss as a client
    // switch whenever another client happened to be served in between, which
    // in the banked configuration is almost always.
    integer    prev_client_bank [0:3];
    reg        refresh_closed;            // a refresh closed the row since last access

    integer n_acc, n_hit, n_miss_switch, n_miss_stride, n_miss_refresh, n_miss_cold;
    // n_seqrow: accesses whose (bank,row) equals the PREVIOUS ACCESS's,
    // ignoring refresh entirely. This is a pure property of the address
    // sequence, so it can be cross-checked against an offline analysis of the
    // same trace - which is what control cell C1 does. n_hit is the same
    // quantity WITH refresh closing the row, and is therefore always lower;
    // comparing n_hit against the offline figure (as the first version of the
    // C1 control did) compares two different things and fails spuriously.
    integer n_seqrow;
    reg        pr_valid;
    reg [1:0]  pr_bank;
    reg [12:0] pr_row;
    integer n_acc_c   [0:3];
    integer n_hit_c   [0:3];
    // latency accumulators, per client: service = grant->ack, total = demand->ack
    integer svc_sum   [0:3];
    integer svc_max   [0:3];
    integer tot_sum   [0:3];
    integer tot_max   [0:3];
    integer n_served  [0:3];

    integer mo_demanded, mo_served;

    // ---- DATA CHECKING ---------------------------------------------------
    // Without this the bench measures throughput and says nothing about
    // correctness - and an open-row policy's characteristic failure is a
    // WRONG-ROW SERVE, which is fast and wrong. sdram_model.v returns
    // f(bank, physically_latched_row, col), so if the controller skips an
    // ACTIVE on a row that is not actually open, the returned word is
    // f(some other row) and this comparison catches it.
    //
    // The expected address is the REMAPPED one, because with BANKMAP_EN the
    // word at byte address A lives at {bank_of(A), row_of(A), col_of(A)}.
    // Checking against the un-remapped address would fail on every access and
    // checking against whatever the model returned would pass on every access;
    // the point is that the remap must be the SAME function on both sides.
    integer n_dchk, n_dbad;
    reg [23:0] chk_word;
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
    function [23:0] remap(input [23:0] wa);
        begin
            remap = {gbank(wa), wa[21:9], wa[8:0]};
        end
    endfunction

    // refresh watcher
    wire [2:0] cmdbus = {dram_ras_n, dram_cas_n, dram_we_n};
    reg  [2:0] cmdbus_d;

    integer k;
    initial begin
        now = 0; armed = 0;
        fpv_pend = 0; fpe_pend = 0; mo_pend = 0;
        fpv_i = 0; fpe_i = 0; fpv_run = 0; fpe_run = 0;
        fpv_a = 24'h000000; fpe_a = 24'h080000;
        fpv_due = 0; fpe_due = 0; mo_due = 0;
        mo_next = 0; mo_head = 0; mo_backlog = 0; mo_backlog_max = 0;
        owner = C_NONE; grant_clk = 0; demand_clk = 0;
        or_valid = 0; or_bank = 0; or_row = 0; prev_client = C_NONE;
        orb_valid = 4'd0;
        for (k = 0; k < 4; k = k + 1) begin
            orb_row[k] = 13'd0; prev_client_bank[k] = C_NONE;
        end
        refresh_closed = 0; cmdbus_d = 3'b111;
        lfsr = 32'h1234_5678;
        n_seqrow = 0; pr_valid = 0; pr_bank = 0; pr_row = 0;
        n_acc = 0; n_hit = 0; n_miss_switch = 0; n_miss_stride = 0;
        n_miss_refresh = 0; n_miss_cold = 0;
        mo_demanded = 0; mo_served = 0; n_dchk = 0; n_dbad = 0;
        for (k = 0; k < 4; k = k + 1) begin
            n_acc_c[k] = 0; n_hit_c[k] = 0; svc_sum[k] = 0; svc_max[k] = 0;
            tot_sum[k] = 0; tot_max[k] = 0; n_served[k] = 0;
        end
    end

    // next synthetic CPU address
    function [23:0] next_cpu_addr(input [23:0] cur, input integer run, input [23:0] base);
        begin
            if (run >= CPU_ROW_RES)
                // jump to an unrelated location in this CPU's 512 KB region
                next_cpu_addr = base | ({8'd0, lfsr[18:0], 1'b0} & 24'h07FFFE);
            else
                next_cpu_addr = cur + 24'd2;
        end
    endfunction

    always @(posedge clk) begin
        cmdbus_d <= cmdbus;
        // An AUTO REFRESH requires all banks precharged, so under ANY open-row
        // policy the open row cannot survive it. Model that.
        if ((cmdbus == 3'b001) && (cmdbus_d != 3'b001)) begin
            if (|orb_valid) refresh_closed <= 1'b1;
            orb_valid <= 4'd0;      // AUTO REFRESH precharges every bank
            or_valid  <= 1'b0;
        end

        if (armed) begin
            now <= now + 1;
            lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};

            // ---- demand: CPUs ------------------------------------------
            if (CPU_EN && (now % BUSCLKS) == 0) begin
                if (!fpv_pend && ((lfsr[15:8] % 100) < VFILL_PCT)) begin
                    if (USE_CPU_TRACE) begin
                        fpv_a <= cpu_addr[fpv_i];
                        fpv_i <= (fpv_i + 1) % CPU_N;
                    end else begin
                        fpv_a   <= next_cpu_addr(fpv_a, fpv_run, 24'h000000);
                        fpv_run <= (fpv_run >= CPU_ROW_RES) ? 0 : fpv_run + 1;
                    end
                    fpv_pend <= 1'b1;
                    fpv_due  <= now;
                end
            end
            if (CPU_EN && (now % BUSCLKS) == (BUSCLKS/2)) begin
                // the extra CPU is an independent 68000; offset its bus phase
                // so the two do not lock-step, which would be an artefact.
                if (!fpe_pend && ((lfsr[23:16] % 100) < EFILL_PCT)) begin
                    if (USE_CPU_TRACE) begin
                        fpe_a <= cpu_addr[fpe_i] + 24'h080000;
                        fpe_i <= (fpe_i + 1) % CPU_N;
                    end else begin
                        fpe_a   <= next_cpu_addr(fpe_a, fpe_run, 24'h080000);
                        fpe_run <= (fpe_run >= CPU_ROW_RES) ? 0 : fpe_run + 1;
                    end
                    fpe_pend <= 1'b1;
                    fpe_due  <= now;
                end
            end

            // ---- demand: MO, at its real captured arrival times ----------
            // mo_time is in 7.159 MHz pixel clocks; CPU_RATIO converts.
            if (MO_EN && mo_next < MO_N) begin
                if (now >= mo_time[mo_next] * CPU_RATIO) begin
                    mo_next     <= mo_next + 1;
                    mo_demanded <= mo_demanded + 1;
                    mo_backlog  <= mo_backlog + 1;
                    if (mo_backlog + 1 > mo_backlog_max) mo_backlog_max <= mo_backlog + 1;
                end
            end
            // present the head of the MO queue if a channel is free
            if (MO_EN && !mo_pend && mo_head < mo_next && (mo_next - mo_head) > 0) begin
                mo_pend <= 1'b1;
                mo_a    <= mo_addr[mo_head];
                mo_due  <= now;
            end

            // ---- arbitration -------------------------------------------
            // core_top.v:1619 -- fastpath fills outrank everything:
            //   if((fpv_want || fpe_want) && !sd_rd_req && !sd_rd_ack
            //      && !cpu_owner && !mo_owner && !fpv_owner && !fpe_owner)
            // core_top.v:1704 -- MO is the LOWEST priority read client and
            // yields to a pending CPU fetch, not merely an in-flight one:
            //   if(!vidkill_sd && mo_pend_q
            //      && !(core_rom_req_s && !core_rom_ack_85)
            //      && !sd_rd_req && !sd_rd_ack && !cpu_owner && !mo_owner
            //      && !fpv_owner && !fpe_owner && !fpv_want && !fpe_want)
            if (!sd_rd_req && !sd_rd_ack && owner == C_NONE) begin
                if (fpv_pend) begin
                    rd_addr_q  <= {1'b0, fpv_a};
                    sd_rd_req  <= 1'b1;
                    owner      <= C_FPV;
                    grant_clk  <= now;
                    demand_clk <= fpv_due;
                end else if (fpe_pend) begin
                    rd_addr_q  <= {1'b0, fpe_a};
                    sd_rd_req  <= 1'b1;
                    owner      <= C_FPE;
                    grant_clk  <= now;
                    demand_clk <= fpe_due;
                end else if (mo_pend) begin
                    rd_addr_q  <= {1'b0, mo_a};
                    sd_rd_req  <= 1'b1;
                    owner      <= C_MO;
                    grant_clk  <= now;
                    demand_clk <= mo_due;
                end
            end

            // ---- completion --------------------------------------------
            if (owner != C_NONE && sd_rd_req && sd_rd_ack) begin
                sd_rd_req <= 1'b0;
                case (owner)
                C_FPV: fpv_pend <= 1'b0;
                C_FPE: fpe_pend <= 1'b0;
                C_MO:  begin
                    mo_pend    <= 1'b0;
                    mo_head    <= mo_head + 1;
                    mo_served  <= mo_served + 1;
                    mo_backlog <= mo_backlog - 1;
                end
                default: ;
                endcase
                // check the returned burst against the remapped address
                n_dchk = n_dchk + 2;
                if (sd_rd_data[31:16] !== expf(remap(chk_word)))
                    n_dbad = n_dbad + 1;
                if (sd_rd_data[15:0]  !== expf(remap({chk_word[23:1], 1'b1})))
                    n_dbad = n_dbad + 1;
                n_served[owner] = n_served[owner] + 1;
                svc_sum[owner]  = svc_sum[owner] + (now - grant_clk);
                if ((now - grant_clk) > svc_max[owner]) svc_max[owner] = now - grant_clk;
                tot_sum[owner]  = tot_sum[owner] + (now - demand_clk);
                if ((now - demand_clk) > tot_max[owner]) tot_max[owner] = now - demand_clk;
                owner <= C_NONE;
            end
        end
    end

    // ---- the open-row counterfactual, sampled at each GRANT ---------------
    // Sampled on the grant edge, using the same address split the controller
    // uses: word = addr[24:1]; ba = word[23:22]; row = word[21:9].
    reg        gr_d;
    wire [23:0] gw = rd_addr_q[24:1];
    // The counterfactual must use the SAME address split the DUT uses, or the
    // hit accounting measures a map that is not in silicon. With
    // -DDUT_OPENROW + BANKMAP_EN the bank comes from the region map.
    function [1:0] gbank(input [23:0] wa);
        begin
`ifdef DUT_OPENROW
            if (BANKMAP_EN == 0)          gbank = wa[23:22];
            else if (wa[23:16] < 8'h04)   gbank = 2'd0;
            else if (wa[23:16] < 8'h08)   gbank = 2'd1;
            else if (wa[23:16] < 8'h09)   gbank = 2'd2;
            else                          gbank = 2'd3;
`else
            gbank = wa[23:22];
`endif
        end
    endfunction
    always @(posedge clk) begin
        gr_d <= sd_rd_req;
        if (armed && sd_rd_req && !gr_d) begin
            n_acc          = n_acc + 1;
            n_acc_c[owner] = n_acc_c[owner] + 1;
            if (pr_valid && gbank(gw) == pr_bank && gw[21:9] == pr_row)
                n_seqrow = n_seqrow + 1;
            pr_valid <= 1'b1; pr_bank <= gbank(gw); pr_row <= gw[21:9];
            if (orb_valid[gbank(gw)] && orb_row[gbank(gw)] == gw[21:9]) begin
                n_hit          = n_hit + 1;
                n_hit_c[owner] = n_hit_c[owner] + 1;
            end else if (!orb_valid[gbank(gw)] && refresh_closed) begin
                n_miss_refresh = n_miss_refresh + 1;
            end else if (!orb_valid[gbank(gw)] && !or_valid) begin
                n_miss_cold = n_miss_cold + 1;
            end else if (owner != prev_client_bank[gbank(gw)]) begin
                n_miss_switch = n_miss_switch + 1;
            end else begin
                n_miss_stride = n_miss_stride + 1;
            end
            prev_client_bank[gbank(gw)] = owner;
            chk_word <= gw;
            orb_valid[gbank(gw)] <= 1'b1;
            orb_row[gbank(gw)]   <= gw[21:9];
            or_valid       <= 1'b1;
            or_bank        <= gbank(gw);
            or_row         <= gw[21:9];
            refresh_closed <= 1'b0;
            prev_client     = owner;
        end
    end

    // ---- run -------------------------------------------------------------
    real hitpct, mo_pct;
    initial begin
        reset_n = 0;
        repeat (20) @(posedge clk);
        reset_n = 1;
        @(posedge init_done);
        repeat (200) @(posedge clk);
        armed = 1;
        repeat (RUN_CLKS) @(posedge clk);
        armed = 0;
        report_all;
        $finish;
    end

    task report_all;
        begin
        $display("TB_SDRAM_TRAFFIC cfg clk=%0.6fns ratio=%0d:1 buscyc=%0d vfill=%0d%% efill=%0d%% cpu_row_res=%0d use_cpu_trace=%0d mo=%0d cpu=%0d run=%0d",
                 CLK_NS, CPU_RATIO, CPU_BUSCYC, VFILL_PCT, EFILL_PCT,
                 CPU_ROW_RES, USE_CPU_TRACE, MO_EN, CPU_EN, RUN_CLKS);
        if (n_acc == 0) begin
            $display("TB_SDRAM_TRAFFIC FAIL: zero accesses - the bench measured NOTHING.");
            $display("  A zero result is a broken rig or a missing fixture, never a pass.");
        end else begin
        hitpct = 100.0 * n_hit / n_acc;
        $display("TB_SDRAM_TRAFFIC accesses=%0d  in %0d clks  (%.3f%% of frame budget 597360)",
                 n_acc, RUN_CLKS, 100.0*RUN_CLKS/597360.0);
        $display("TB_SDRAM_TRAFFIC ROW-HIT RATE (open-row counterfactual) = %0d/%0d = %.2f%%",
                 n_hit, n_acc, hitpct);
        $display("TB_SDRAM_TRAFFIC SEQ-ROW (same row as previous access, refresh ignored) = %0d/%0d = %.2f%%",
                 n_seqrow, n_acc, 100.0*n_seqrow/n_acc);
        $display("TB_SDRAM_TRAFFIC MISS SPLIT: client_switch=%0d (%.2f%%)  same_client_stride=%0d (%.2f%%)  refresh=%0d (%.2f%%)  cold=%0d",
                 n_miss_switch, 100.0*n_miss_switch/n_acc,
                 n_miss_stride, 100.0*n_miss_stride/n_acc,
                 n_miss_refresh, 100.0*n_miss_refresh/n_acc,
                 n_miss_cold);
        $display("TB_SDRAM_TRAFFIC per-client: FPV acc=%0d hit=%0d  FPE acc=%0d hit=%0d  MO acc=%0d hit=%0d",
                 n_acc_c[C_FPV], n_hit_c[C_FPV], n_acc_c[C_FPE], n_hit_c[C_FPE],
                 n_acc_c[C_MO],  n_hit_c[C_MO]);
        for (k = 1; k <= 3; k = k + 1) begin
            if (n_served[k] > 0)
                $display("TB_SDRAM_TRAFFIC latency %0s: n=%0d service mean=%.2f max=%0d | demand-to-ack mean=%.2f max=%0d (clks)",
                         (k==C_FPV)?"FPV":(k==C_FPE)?"FPE":"MO ", n_served[k],
                         1.0*svc_sum[k]/n_served[k], svc_max[k],
                         1.0*tot_sum[k]/n_served[k], tot_max[k]);
        end
        if (MO_EN) begin
            mo_pct = (mo_demanded > 0) ? 100.0*mo_served/mo_demanded : 0.0;
            $display("TB_SDRAM_TRAFFIC MO demand=%0d served=%0d (%.2f%%) backlog_max=%0d  UNSERVED=%0d",
                     mo_demanded, mo_served, mo_pct, mo_backlog_max,
                     mo_demanded - mo_served);
        end
        $display("TB_SDRAM_TRAFFIC DATA CHECK: words=%0d mismatches=%0d", n_dchk, n_dbad);
        if (n_dchk == 0)
            $display("TB_SDRAM_TRAFFIC FAIL: no words were data-checked");
        else if (n_dbad != 0)
            $display("TB_SDRAM_TRAFFIC FAIL: %0d wrong words returned - WRONG-ROW SERVE", n_dbad);
        mem.report_model;
        end
        $display("TB_SDRAM_TRAFFIC DONE");
        end
    endtask

    // watchdog
    initial begin
        #(CLK_NS * (RUN_CLKS + 60000) * 1.2);
        $display("TB_SDRAM_TRAFFIC FAIL: timeout");
        $finish;
    end
endmodule

`default_nettype wire
