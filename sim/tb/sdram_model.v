// sdram_model: behavioural MT48LC16M16A2 with a JEDEC protocol checker.
//
// Written for the open-row work (SDRAM_ARCH). The repo had NO SDRAM memory
// model at all - `tb_sdram_refresh.v` watches the command bus and ties dq to
// Z, which is fine for measuring refresh gaps and useless for proving that a
// controller which HOLDS ROWS OPEN still returns the right data.
//
// The single most important property of this model, and the reason it is
// worth its length:
//
//     READS ARE SERVED FROM THE PHYSICALLY OPEN ROW, NOT FROM THE ADDRESS
//     THE CONTROLLER MEANT TO READ.
//
// A real SDRAM has no idea what row you intended. It latches a row on ACTIVE
// into the sense amplifiers, and a subsequent READ selects a COLUMN of
// whatever is currently latched. If a controller skips an ACTIVE because it
// believes the right row is open and it is wrong, the part cheerfully returns
// valid-looking data from the wrong row. That is exactly the v38 failure this
// project already had once ("valid data, valid parity, wrong location -
// invisible to every checker"), and an open-row policy is precisely the class
// of change that can reintroduce it. A model that returned f(intended_addr)
// would be incapable of catching it. This one returns f(bank, open_row, col).
//
// Memory contents: a pure hash of the full 24-bit word address (see `fdata`),
// overridden by a direct-mapped write table. No large array - iverilog would
// need ~256 MB for the full 16M-word space, and this build of iverilog has no
// associative-array support (verified: `reg [15:0] m [*]` is a syntax error).
// Every address therefore has a distinct expected value with no storage cost,
// which is what makes wrong-row detection total rather than sampled.
//
// Timings default to the -75 speed grade. NOTE: no speed grade is recorded
// anywhere in this repo for the fitted part, so -75 is an ASSUMPTION, chosen
// because it is the slowest grade the MT48LC16M16A2 is offered in and is
// therefore the conservative one. Every timing is a parameter in NANOSECONDS
// and is converted to clocks here, so the checker stays correct if the clock
// changes - which matters, because raising the SDRAM clock is on the table.
//
`default_nettype none

module sdram_model #(
    parameter real CLK_NS       = 27.936508,  // 35.795455 MHz
    // MT48LC16M16A2-75 AC characteristics, nanoseconds.
    parameter real T_RCD_NS     = 20.0,   // ACTIVE -> READ/WRITE, same bank
    parameter real T_RP_NS      = 20.0,   // PRECHARGE -> ACTIVE, same bank
    parameter real T_RAS_MIN_NS = 45.0,   // ACTIVE -> PRECHARGE, same bank
    parameter real T_RAS_MAX_NS = 120000.0, // row may not stay open longer
    parameter real T_RC_NS      = 65.0,   // ACTIVE -> ACTIVE, same bank
    parameter real T_RRD_NS     = 15.0,   // ACTIVE -> ACTIVE, different bank
    parameter real T_RFC_NS     = 66.0,   // REFRESH -> any command
    parameter real T_WR_NS      = 15.0,   // last write data -> PRECHARGE
    // Effective read latency in CONTROLLER-VISIBLE clocks: the number of
    // clocks from the model registering a READ to the controller being able to
    // register the returned word.
    //
    // This is 1, not the nominal CL2, and the value is CALIBRATED against the
    // shipping controller rather than derived. State that plainly because it
    // matters: the shipping FSM captures `rd_data[31:16]` in S_DATA, which in
    // a zero-delay cycle model is one clock after the READ appears on the pins,
    // and that half of the burst is the one every client except MO consumes
    // (core_top.v:1443,1453,1462,1480,1643,1649) and is known-good on hardware
    // - `chk_ok` compares it against a fixed constant and the core boots.
    //
    // The missing clock is the 90-degree `clk_sdram_chip` phase lead
    // (mf_pllbase_0002.v phase_shift3 = 6984 ps) plus FAST_INPUT_REGISTER
    // capture in the IO cell (ap_core.qsf:810). That is a SUB-CYCLE
    // relationship, and a cycle-accurate model cannot adjudicate it - which is
    // exactly the "one-clock skew, phase-dependent" of SDSCHED-83. So this
    // parameter encodes an observed fact about the shipping design, and any
    // conclusion that depends on the ABSOLUTE value of the data latency (as
    // opposed to comparisons between controller variants measured the same
    // way) has to be settled on hardware, not here.
    parameter integer CL_EFF    = 1,
    parameter integer CHECK_EN  = 1,      // 0 disables violation reporting
    parameter integer VERBOSE   = 0       // 1 = $display every violation
) (
    input  wire        clk,
    input  wire        cke,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [1:0]  dqm,
    inout  wire [15:0] dq
);

    // ---- timing, converted to whole clocks (ceiling) -------------------
    // A command issued at clock N may be followed by the dependent command at
    // clock N + CLKS(t). ceil() because a partial clock does not satisfy a
    // minimum.
    function integer ceil_clks(input real ns);
        real q;
        begin
            q = ns / CLK_NS;
            ceil_clks = (q == $rtoi(q)) ? $rtoi(q) : $rtoi(q) + 1;
        end
    endfunction

    integer C_RCD, C_RP, C_RAS_MIN, C_RAS_MAX, C_RC, C_RRD, C_RFC, C_WR;
    initial begin
        C_RCD     = ceil_clks(T_RCD_NS);
        C_RP      = ceil_clks(T_RP_NS);
        C_RAS_MIN = ceil_clks(T_RAS_MIN_NS);
        C_RAS_MAX = ceil_clks(T_RAS_MAX_NS);
        C_RC      = ceil_clks(T_RC_NS);
        C_RRD     = ceil_clks(T_RRD_NS);
        C_RFC     = ceil_clks(T_RFC_NS);
        C_WR      = ceil_clks(T_WR_NS);
    end

    // ---- mode register -------------------------------------------------
    reg [2:0] mr_burst   = 3'd0;   // encoded: 000=1, 001=2, 010=4, 011=8
    reg [2:0] mr_cas     = 3'd2;
    reg       mr_seq     = 1'b0;
    reg       mode_set   = 1'b0;
    integer   burst_len; initial burst_len = 1;

    // ---- bank state ----------------------------------------------------
    // st: 0 = idle (precharged), 1 = activating/active, 2 = precharging
    reg [1:0]  bk_st      [0:3];
    reg [12:0] bk_row     [0:3];
    integer    bk_t_act   [0:3];   // clock of the ACTIVE command
    integer    bk_t_pre   [0:3];   // clock the PRECHARGE was issued/started
    integer    bk_t_idle  [0:3];   // clock the bank becomes idle again
    integer    bk_t_lastwr[0:3];   // clock of the last write data element
    integer    bk_ap      [0:3];   // 1 = auto-precharge pending on this bank

    integer now;                   // free-running clock counter
    integer t_last_act;            // any bank, for tRRD
    integer t_refresh;             // clock of the last AUTO REFRESH

    // ---- violation counters --------------------------------------------
    integer v_read_no_row;    // READ to a bank with no open row
    integer v_write_no_row;   // WRITE to a bank with no open row
    integer v_act_on_open;    // ACTIVE to a bank that is already active
    integer v_trcd, v_trp, v_tras_min, v_tras_max, v_trc, v_trrd, v_trfc, v_twr;
    integer v_refresh_open;   // AUTO REFRESH issued with a bank not precharged
    integer v_total;
    // Informational, not violations.
    integer n_act, n_read, n_write, n_pre, n_preall, n_refresh;
    integer n_read_ap, n_write_ap;

    integer i;
    initial begin
        for (i = 0; i < 4; i = i + 1) begin
            bk_st[i] = 2'd0; bk_row[i] = 13'd0;
            bk_t_act[i] = -100000; bk_t_pre[i] = -100000;
            bk_t_idle[i] = -100000; bk_t_lastwr[i] = -100000; bk_ap[i] = 0;
        end
        now = 0; t_last_act = -100000; t_refresh = -100000;
        v_read_no_row = 0; v_write_no_row = 0; v_act_on_open = 0;
        v_trcd = 0; v_trp = 0; v_tras_min = 0; v_tras_max = 0;
        v_trc = 0; v_trrd = 0; v_trfc = 0; v_twr = 0;
        v_refresh_open = 0; v_total = 0;
        n_act = 0; n_read = 0; n_write = 0; n_pre = 0; n_preall = 0;
        n_refresh = 0; n_read_ap = 0; n_write_ap = 0;
    end

    task viol(input [1023:0] what);
        begin
            v_total = v_total + 1;
            if (CHECK_EN && VERBOSE)
                $display("SDRAM_MODEL VIOLATION @%0t clk=%0d: %0s", $time, now, what);
        end
    endtask

    // ---- memory contents ------------------------------------------------
    // Pure function of the FULL word address. Two different rows never share
    // an expected value except by 1-in-65536 collision, so a wrong-row serve
    // is caught with probability 65535/65536 per word.
    function [15:0] fdata(input [23:0] wa);
        reg [31:0] h;
        begin
            h = {8'h00, wa} ^ 32'h9E3779B9;
            h = h * 32'h85EBCA6B;
            h = h ^ (h >> 13);
            h = h * 32'hC2B2AE35;
            h = h ^ (h >> 16);
            fdata = h[15:0];
        end
    endfunction

    // Direct-mapped write override. WT_COLL is exported so a bench can prove
    // it did not silently lose a write to a tag collision - a lost write would
    // otherwise read back as a data mismatch and be blamed on the controller.
    localparam WT_BITS = 15;
    localparam WT_N    = (1 << WT_BITS);
    reg [23:0] wt_tag [0:WT_N-1];
    reg [15:0] wt_dat [0:WT_N-1];
    reg        wt_val [0:WT_N-1];
    integer    wt_coll;
    initial begin
        for (i = 0; i < WT_N; i = i + 1) begin
            wt_val[i] = 1'b0; wt_tag[i] = 24'd0; wt_dat[i] = 16'd0;
        end
        wt_coll = 0;
    end

    // Index by a HASH of the full word address, not by its low bits. Direct
    // indexing on wa[14:0] made every region whose base is a multiple of
    // 0x8000 alias to the same entries - and the four regions this design
    // actually uses (0, 0x48000, 0x88000, 0x98000 in words) are all such
    // multiples, so a cross-region write test evicted itself 100% of the time.
    // The collision counter caught that rather than reporting it as wrong data,
    // which is the whole reason it exists.
    function [WT_BITS-1:0] wt_index(input [23:0] wa);
        reg [31:0] h;
        begin
            h = {8'h00, wa} * 32'h9E3779B1;
            h = h ^ (h >> 15);
            wt_index = h[WT_BITS-1:0];
        end
    endfunction

    // OPEN ADDRESSING with linear probing, so a write NEVER evicts another
    // address. Direct mapping (even hashed) evicts on collision, and an
    // evicted write reads back as the underlying pattern - i.e. as a DATA
    // MISMATCH that looks exactly like the wrong-row bug this model exists to
    // find. With probing, `wt_coll` can only be non-zero if the table is
    // genuinely full, so a mismatch is always the controller's fault.
    localparam WT_PROBE = 64;

    function integer wt_lookup(input [23:0] wa);   // -1 if absent
        integer ix, j, r;
        begin
            r = -1;
            ix = wt_index(wa);
            for (j = 0; j < WT_PROBE; j = j + 1) begin
                if (r == -1) begin
                    if (!wt_val[(ix + j) % WT_N])              r = -2;  // empty: absent
                    else if (wt_tag[(ix + j) % WT_N] == wa)    r = (ix + j) % WT_N;
                end
            end
            wt_lookup = (r < 0) ? -1 : r;
        end
    endfunction

    function [15:0] mem_read(input [23:0] wa);
        integer ix;
        begin
            ix = wt_lookup(wa);
            if (ix >= 0) mem_read = wt_dat[ix];
            else         mem_read = fdata(wa);
        end
    endfunction

    task mem_write(input [23:0] wa, input [15:0] d);
        integer ix, j, done;
        begin
            ix = wt_index(wa);
            done = 0;
            for (j = 0; j < WT_PROBE; j = j + 1) begin
                if (!done) begin
                    if (!wt_val[(ix + j) % WT_N] || wt_tag[(ix + j) % WT_N] == wa) begin
                        wt_val[(ix + j) % WT_N] = 1'b1;
                        wt_tag[(ix + j) % WT_N] = wa;
                        wt_dat[(ix + j) % WT_N] = d;
                        done = 1;
                    end
                end
            end
            // Only reachable if WT_PROBE consecutive slots are all occupied by
            // OTHER addresses - i.e. the table is saturated, not a hash clash.
            if (!done) wt_coll = wt_coll + 1;
        end
    endtask

    // ---- read data pipeline (CAS latency) --------------------------------
    // Calibrated against the shipping controller by direct trace (see
    // sim/tb/tb_sdram_model.v MODE 0). The accounting, stated explicitly
    // because an off-by-one here would silently invalidate every data check:
    //
    //   edge j    : the model REGISTERS the READ command from the pins.
    //               data is loaded at pipeline index CL-1.
    //   edge j+1  : ... shifts down ...
    //   edge j+CL-1: index reaches 0 and `dq_drv` is assigned, so dq carries
    //               the word during the period (j+CL-1, j+CL).
    //   edge j+CL : the CONTROLLER registers it.
    //
    // i.e. the controller sees data CL clocks after the chip registered the
    // READ, which is the JEDEC definition of CAS latency. Verified against the
    // unmodified FSM: READ registered at clock 11, `rd_data[31:16]` captured
    // at clock 13.
    //
    // Depth 8 covers CL2..CL3 with slack.
    reg [15:0] rd_pipe [0:7];
    reg        rd_pipe_v [0:7];
    initial for (i = 0; i < 8; i = i + 1) begin rd_pipe[i] = 16'h0; rd_pipe_v[i] = 1'b0; end

    reg [15:0] dq_drv;
    reg        dq_oe;
    assign dq = dq_oe ? dq_drv : 16'hZZZZ;

    // ---- command decode ---------------------------------------------------
    wire [2:0] cmd = {ras_n, cas_n, we_n};
    localparam CMD_NOP     = 3'b111;
    localparam CMD_ACTIVE  = 3'b011;
    localparam CMD_READ    = 3'b101;
    localparam CMD_WRITE   = 3'b100;
    localparam CMD_PRECHG  = 3'b010;
    localparam CMD_REFRESH = 3'b001;
    localparam CMD_MODE    = 3'b000;

    integer b, prech_start;
    reg [23:0] wa;

    always @(posedge clk) begin
        now = now + 1;

        // ---- retire bank precharge / auto-precharge -----------------------
        for (b = 0; b < 4; b = b + 1) begin
            if (bk_st[b] == 2'd2 && now >= bk_t_idle[b]) bk_st[b] = 2'd0;
            // tRAS(max): a row may not be held open indefinitely. At 120 us
            // this cannot trip under any refresh policy that meets tREF, but
            // an open-row controller that stopped refreshing would trip it,
            // and that is worth catching explicitly rather than assuming.
            if (bk_st[b] == 2'd1 && (now - bk_t_act[b]) > C_RAS_MAX) begin
                viol("tRAS(max) - row held open too long");
                v_tras_max = v_tras_max + 1;
                bk_st[b] = 2'd0;   // report once per activate
            end
        end

        // ---- advance the read-data pipeline ------------------------------
        // Shift FIRST, then the command decode below loads index CL-1, then
        // the bus is driven from index 0 at the very end of this block. See
        // the latency accounting at the pipeline declaration.
        for (i = 0; i < 7; i = i + 1) begin
            rd_pipe[i]   = rd_pipe[i+1];
            rd_pipe_v[i] = rd_pipe_v[i+1];
        end
        rd_pipe[7] = 16'h0; rd_pipe_v[7] = 1'b0;

        if (cke) begin
        case (cmd)
        // -----------------------------------------------------------------
        CMD_MODE: begin
            if (ba == 2'b00) begin
                mr_burst = a[2:0];
                mr_seq   = a[3];
                mr_cas   = a[6:4];
                mode_set = 1'b1;
                burst_len = (a[2:0] == 3'd0) ? 1 : (a[2:0] == 3'd1) ? 2 :
                            (a[2:0] == 3'd2) ? 4 : (a[2:0] == 3'd3) ? 8 : 1;
            end
        end
        // -----------------------------------------------------------------
        CMD_ACTIVE: begin
            n_act = n_act + 1;
            b = ba;
            if (bk_st[b] == 2'd1) begin
                // The bank already has a row in the sense amps. On real
                // silicon this is illegal and the result is undefined.
                viol("ACTIVE to a bank that is already ACTIVE (no PRECHARGE)");
                v_act_on_open = v_act_on_open + 1;
            end else if (bk_st[b] == 2'd2 && now < bk_t_idle[b]) begin
                viol("tRP - ACTIVE too soon after PRECHARGE");
                v_trp = v_trp + 1;
            end
            if ((now - bk_t_act[b]) < C_RC) begin
                viol("tRC - ACTIVE to ACTIVE same bank too soon");
                v_trc = v_trc + 1;
            end
            if ((now - t_last_act) < C_RRD) begin
                viol("tRRD - ACTIVE to ACTIVE different bank too soon");
                v_trrd = v_trrd + 1;
            end
            if ((now - t_refresh) < C_RFC) begin
                viol("tRFC - command too soon after AUTO REFRESH");
                v_trfc = v_trfc + 1;
            end
            bk_st[b]    = 2'd1;
            bk_row[b]   = a;
            bk_t_act[b] = now;
            bk_ap[b]    = 0;
            t_last_act  = now;
        end
        // -----------------------------------------------------------------
        CMD_READ: begin
            n_read = n_read + 1;
            b = ba;
            if (a[10]) n_read_ap = n_read_ap + 1;
            if (bk_st[b] != 2'd1) begin
                viol("READ to a bank with no open row");
                v_read_no_row = v_read_no_row + 1;
                rd_pipe[CL_EFF-1]   = 16'hXXXX;
                rd_pipe_v[CL_EFF-1] = 1'b1;
            end else begin
                if ((now - bk_t_act[b]) < C_RCD) begin
                    viol("tRCD - READ too soon after ACTIVE");
                    v_trcd = v_trcd + 1;
                end
                // THE POINT OF THIS MODEL: the row comes from the sense amps,
                // not from anything the controller intended.
                wa = {b[1:0], bk_row[b], a[8:0]};
                rd_pipe[CL_EFF-1]   = mem_read(wa);
                rd_pipe_v[CL_EFF-1] = 1'b1;
                if (a[10]) begin
                    // read with auto-precharge: precharge begins after the
                    // burst, but never before tRAS(min) is satisfied.
                    prech_start = now + burst_len;
                    if (prech_start < bk_t_act[b] + C_RAS_MIN)
                        prech_start = bk_t_act[b] + C_RAS_MIN;
                    bk_st[b]     = 2'd2;
                    bk_t_pre[b]  = prech_start;
                    bk_t_idle[b] = prech_start + C_RP;
                end
            end
        end
        // -----------------------------------------------------------------
        CMD_WRITE: begin
            n_write = n_write + 1;
            b = ba;
            if (a[10]) n_write_ap = n_write_ap + 1;
            if (bk_st[b] != 2'd1) begin
                viol("WRITE to a bank with no open row");
                v_write_no_row = v_write_no_row + 1;
            end else begin
                if ((now - bk_t_act[b]) < C_RCD) begin
                    viol("tRCD - WRITE too soon after ACTIVE");
                    v_trcd = v_trcd + 1;
                end
                wa = {b[1:0], bk_row[b], a[8:0]};
                if (dqm != 2'b11) mem_write(wa, dq);
                bk_t_lastwr[b] = now;
                if (a[10]) begin
                    prech_start = now + burst_len + C_WR;
                    if (prech_start < bk_t_act[b] + C_RAS_MIN)
                        prech_start = bk_t_act[b] + C_RAS_MIN;
                    bk_st[b]     = 2'd2;
                    bk_t_pre[b]  = prech_start;
                    bk_t_idle[b] = prech_start + C_RP;
                end
            end
        end
        // -----------------------------------------------------------------
        CMD_PRECHG: begin
            if (a[10]) begin
                n_preall = n_preall + 1;
                for (b = 0; b < 4; b = b + 1) begin
                    if (bk_st[b] == 2'd1) begin
                        if ((now - bk_t_act[b]) < C_RAS_MIN) begin
                            viol("tRAS(min) - PRECHARGE ALL too soon after ACTIVE");
                            v_tras_min = v_tras_min + 1;
                        end
                        if ((now - bk_t_lastwr[b]) < C_WR) begin
                            viol("tWR - PRECHARGE ALL too soon after write data");
                            v_twr = v_twr + 1;
                        end
                        bk_st[b]     = 2'd2;
                        bk_t_pre[b]  = now;
                        bk_t_idle[b] = now + C_RP;
                    end
                end
            end else begin
                n_pre = n_pre + 1;
                b = ba;
                if (bk_st[b] == 2'd1) begin
                    if ((now - bk_t_act[b]) < C_RAS_MIN) begin
                        viol("tRAS(min) - PRECHARGE too soon after ACTIVE");
                        v_tras_min = v_tras_min + 1;
                    end
                    if ((now - bk_t_lastwr[b]) < C_WR) begin
                        viol("tWR - PRECHARGE too soon after write data");
                        v_twr = v_twr + 1;
                    end
                    bk_st[b]     = 2'd2;
                    bk_t_pre[b]  = now;
                    bk_t_idle[b] = now + C_RP;
                end
            end
        end
        // -----------------------------------------------------------------
        CMD_REFRESH: begin
            n_refresh = n_refresh + 1;
            // AUTO REFRESH requires ALL banks precharged. This is the single
            // check that an open-row policy is most likely to break, and the
            // reason this model exists in the form it does.
            for (b = 0; b < 4; b = b + 1) begin
                if (bk_st[b] == 2'd1) begin
                    viol("AUTO REFRESH issued with a bank still ACTIVE");
                    v_refresh_open = v_refresh_open + 1;
                end else if (bk_st[b] == 2'd2 && now < bk_t_idle[b]) begin
                    viol("AUTO REFRESH issued while a bank is still precharging (tRP)");
                    v_trp = v_trp + 1;
                end
            end
            if ((now - t_refresh) < C_RFC) begin
                viol("tRFC - AUTO REFRESH too soon after AUTO REFRESH");
                v_trfc = v_trfc + 1;
            end
            t_refresh = now;
        end
        default: ; // NOP / command inhibit
        endcase
        end

        // ---- drive the bus from the head of the pipeline -----------------
        // Assigned last so a READ decoded this clock lands at index CL-1 and
        // is driven CL-1 clocks from now, i.e. registered by the controller
        // exactly CL clocks after the chip registered the READ.
        dq_oe  = rd_pipe_v[0];
        dq_drv = rd_pipe[0];
    end

    // ---- reporting --------------------------------------------------------
    task report_model;
        begin
            $display("SDRAM_MODEL cmds: act=%0d read=%0d(ap=%0d) write=%0d(ap=%0d) pre=%0d preall=%0d refresh=%0d",
                     n_act, n_read, n_read_ap, n_write, n_write_ap, n_pre, n_preall, n_refresh);
            $display("SDRAM_MODEL timing clocks: tRCD=%0d tRP=%0d tRASmin=%0d tRC=%0d tRRD=%0d tRFC=%0d tWR=%0d (clk=%0.6f ns)",
                     C_RCD, C_RP, C_RAS_MIN, C_RC, C_RRD, C_RFC, C_WR, CLK_NS);
            $display("SDRAM_MODEL mode reg: CL=%0d burst=%0d (CL_EFF used for data return = %0d)",
                     mr_cas, burst_len, CL_EFF);
            $display("SDRAM_MODEL violations: total=%0d", v_total);
            $display("SDRAM_MODEL   read_no_row=%0d write_no_row=%0d act_on_open=%0d refresh_with_open_bank=%0d",
                     v_read_no_row, v_write_no_row, v_act_on_open, v_refresh_open);
            $display("SDRAM_MODEL   tRCD=%0d tRP=%0d tRASmin=%0d tRASmax=%0d tRC=%0d tRRD=%0d tRFC=%0d tWR=%0d",
                     v_trcd, v_trp, v_tras_min, v_tras_max, v_trc, v_trrd, v_trfc, v_twr);
            $display("SDRAM_MODEL write-table tag collisions = %0d (nonzero invalidates data checking)",
                     wt_coll);
        end
    endtask

endmodule

`default_nettype wire
