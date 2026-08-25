// tb_pf_reset: does the playfield fetch channel survive a core reset?
//
// PFRESET-111.  This bench exists to make one specific failure REPRODUCIBLE
// rather than argued: a reset taken while a playfield fetch is in flight
// leaves inflA/inflB set forever and wedges the channel for the rest of the
// session.  It is the Pocket-side backport of the MiSTer PFRESET-107 bench
// (sim/tb/tb_mister_pf.v, commit dcd1196), where the identical omission
// rendered the playfield as a flat fill on real DE10-Nano hardware.
//
// WHAT IS REAL HERE AND WHAT IS NOT.  This bench does NOT re-implement the
// RTL it grades.  sim/tools/mk_pf_reset_slice.py cuts three blocks verbatim
// out of src/fpga/core/core_top.v every run and drops them in as `include
// fragments, so the logic under test is byte-identical to what synthesises
// and cannot drift:
//
//   `include "pf_pixel.vh"    the pixel-domain PF pipeline (enqueue -> A/B
//                             issue -> completion -> slot ring), core_top's
//                             always @(posedge clk_sys_7159) at :2254
//   `include "pf_service.vh"  the sdram-domain CRAM read-start chain and the
//                             cvg_ph fetch FSM, core_top :1477-1582 - including
//                             the cst forensics reader, a real competing
//                             client for the same controller
//   `include "pf_resync.vh"   the SDSCHED-75 reset resync, core_top :1708 -
//                             the block that eats the request edges
//
// The third_party psram.sv controller is the real one, against the same
// behavioural 70ns ADmux chip model tb_pf_cram.v uses.  What is modelled and
// not real: the 68000s, the SDRAM side, the CRAM drain/fill queue (cq_n is
// held at 0 here, which makes the CRAM controller LESS busy than hardware and
// therefore makes the bug HARDER to hit, not easier), and the map contents.
//
// The bench proves the channel is alive or wedged.  It does not prove the
// pixels are the right pixels - sim/run_pf_tb.sh is the gate for that.
//
// ---------------------------------------------------------------------------
// THE FAILING CASE IS FIRST-CLASS.  Run with the fix excised:
//
//     PFRESET_DEFEAT=1 ./sim/run_pf_reset_tb.sh
//
// mk_pf_reset_slice.py --defeat-fix removes the PFRESET-111 reset block from
// the extracted pixel-domain slice and nothing else.  The failing run is
// therefore the SHIPPED block with exactly the fix taken out, not a
// hand-written imitation of the old code.  run_pf_reset_tb.sh runs both
// configurations and requires the defeated one to WEDGE: a bench whose
// negative control passes is measuring nothing.
// ---------------------------------------------------------------------------
//
// PHASE selects which reset the bench drives:
//
//   PHASE=0  STEADY-STATE RESET.  chk_state is pinned at 4'd10 the whole run,
//            so the CRAM read-start chain is live and CAN serve playfield
//            fetches while the core is held in reset.  This is the Pocket's
//            reachable exposure - menu soft reset, rescue reboot, watchdog -
//            and it is the WEAKER of the two cases, because the chain gets one
//            cycle to catch each request edge before the resync retires it.
//            A wedge here is a race the hardware genuinely runs.
//   PHASE=1  BOOT DOWNLOAD.  chk_state is held at 4'd0 while reset is held and
//            released to 4'd10 with the core, so no fetch can be served at
//            all.  This is the MiSTer PFRESET-107 sequence exactly, and it is
//            deterministic rather than racy.
//
`timescale 1ns/1ps

module tb_pf_reset;
    parameter PHASE      = 0;    // 0 = idle steady state, 1 = boot download,
                                 // 2 = steady state with CRAM drain traffic
    parameter BASE_LINES = 60;   // scanlines in the baseline measurement window
    parameter RESET_LINES= 8;    // scanlines the reset is held
    parameter POST_LINES = 60;   // scanlines in the post-release window
    parameter WR_PERIOD  = 24;   // PHASE 2: clk_sdram cycles between gfx-region
                                 // SDRAM writes feeding the CRAM mirror queue

    // ---------------- clocks: 35.795455MHz sdram, 7.159091MHz pixel (5:1)
    // mf_pllbase siblings on hardware, so phase-locked; derived from one 2x
    // master here for the same reason tb_pf_cram.v does it - both derived
    // clocks update in the same NBA region, no same-timestep clock race.
    reg clk2x = 0;
    always #6.984127 clk2x = ~clk2x;         // 71.590909MHz
    reg [2:0] pdiv = 0;
    reg clk_sdram     = 0;
    reg clk_sys_7159  = 0;
    always @(posedge clk2x) begin
        clk_sdram <= ~clk_sdram;                                    // /2
        if(pdiv == 3'd4) begin pdiv <= 0; clk_sys_7159 <= ~clk_sys_7159; end
        else pdiv <= pdiv + 3'd1;                                   // /10
    end

    // ---------------- video counters.  core_top.v:538 holds these ONLY under
    // the Pocket-level reset_n, never under core_reset_n - which is the whole
    // reason the PF pipeline keeps issuing fetches while the core is in reset.
    // Reproduced faithfully: nothing here is gated by core_reset_n.
    localparam VID_V_BPORCH = 'd12;
    localparam VID_V_ACTIVE = 'd240;
    localparam VID_V_TOTAL  = 'd262;
    localparam VID_H_BPORCH = 'd60;
    localparam VID_H_ACTIVE = 'd336;
    localparam VID_H_TOTAL  = 'd456;
    reg [9:0] x_count = 0, y_count = 0;
    reg [15:0] frame_id = 0;
    always @(posedge clk_sys_7159) begin
        x_count <= x_count + 1'b1;
        if(x_count == VID_H_TOTAL-1) begin
            x_count <= 0;
            y_count <= y_count + 1'b1;
            if(y_count == VID_V_TOTAL-1) begin
                y_count  <= 0;
                frame_id <= frame_id + 16'd1;
            end
        end
    end
    wire [9:0] visible_x = x_count - VID_H_BPORCH;
    wire [9:0] visible_y = y_count - VID_V_BPORCH;
    wire [9:0] vis_x     = x_count - VID_H_BPORCH;
    wire       vblank_w  = ~((y_count >= VID_V_BPORCH)
                             && (y_count < VID_V_BPORCH+VID_V_ACTIVE));
    reg [15:0] frame_ctr = 16'd0;
    reg        vb_fr_d = 0;
    always @(posedge clk_sys_7159) begin
        vb_fr_d <= vblank_w;
        if(vblank_w && !vb_fr_d) frame_ctr <= frame_ctr + 16'd1;
    end

    // ---------------- reset stimulus
    reg core_reset_n = 1'b1;
    reg core_rstn_sd = 1'b1;
    always @(posedge clk_sdram) core_rstn_sd <= core_reset_n;   // core_top:1367
    reg [3:0] chk_state = 4'd10;

    // ---------------- PSRAM chip model: async ADmux, 70ns access
    // (identical to tb_pf_cram.v's model; the controller below is the real one)
    wire [21:16] cram0_a;
    wire [15:0]  cram0_dq;
    wire         cram0_wait;
    wire         cram0_clk, cram0_adv_n, cram0_cre;
    wire         cram0_ce0_n, cram0_ce1_n, cram0_oe_n, cram0_we_n;
    wire         cram0_ub_n, cram0_lb_n;
    assign cram0_wait = 1'b0;

    reg [15:0] cmem [0:(1<<21)-1];
    reg [21:0] chip_addr;
    reg        chip_rd_valid;
    integer k;
    initial begin
        chip_rd_valid = 0;
        // same multiplicative-hash fill as tb_pf_cram.v (PFSIM-113): a
        // bijection mod 2^16, so no wrong-address read returns a plausible
        // neighbouring value.  This bench does not check pixels, but the fill
        // still keeps a wedge from being confused with a benign constant.
        for(k = 0; k < (1<<21); k = k + 1)
            cmem[k] = (k * 32'd2654435761) & 32'h0000FFFF;
    end
    always @(*) if(!cram0_adv_n && (!cram0_ce0_n || !cram0_ce1_n))
        chip_addr = {cram0_a[21:16], cram0_dq};
    always @(posedge cram0_adv_n) begin
        chip_rd_valid <= 0;
        chip_rd_valid <= #62 1'b1;
    end
    assign cram0_dq = (!cram0_ce0_n && !cram0_oe_n && cram0_we_n)
                      ? (chip_rd_valid ? cmem[chip_addr[20:0]] : 16'hxxxx)
                      : 16'hzzzz;

    // ---------------- the real controller
    wire        cram_busy;
    reg         cram_read_en = 0;
    reg  [21:0] cram_addr = 0;
    wire [15:0] cram_dout;
    wire        cram_avail;
    reg         cram_write_en = 0;
    reg  [15:0] cram_din = 0;

    psram #(.CLOCK_SPEED(35.795455)) cram0 (
        .clk        ( clk_sdram ),
        .bank_sel   ( 1'b0 ),
        .addr       ( cram_addr ),
        .write_en   ( cram_write_en ),
        .data_in    ( cram_din ),
        .write_high_byte ( 1'b1 ),
        .write_low_byte  ( 1'b1 ),
        .read_en    ( cram_read_en ),
        .read_avail ( cram_avail ),
        .data_out   ( cram_dout ),
        .busy       ( cram_busy ),
        .cram_a     ( cram0_a ),
        .cram_dq    ( cram0_dq ),
        .cram_wait  ( cram0_wait ),
        .cram_clk   ( cram0_clk ),
        .cram_adv_n ( cram0_adv_n ),
        .cram_cre   ( cram0_cre ),
        .cram_ce0_n ( cram0_ce0_n ),
        .cram_ce1_n ( cram0_ce1_n ),
        .cram_oe_n  ( cram0_oe_n ),
        .cram_we_n  ( cram0_we_n ),
        .cram_ub_n  ( cram0_ub_n ),
        .cram_lb_n  ( cram0_lb_n )
    );

    // ---------------- nets the shipped slices reference
    // pixel-domain PF pipeline
    wire [8:0] xscroll = 9'd0, yscroll = 9'd0;
    wire [8:0] pf_y  = visible_y[8:0] + yscroll;
    wire [8:0] pf_x2 = vis_x[8:0] + 9'd16 + xscroll;
    reg  [11:0] pf_vaddr = 0;
    reg  [15:0] pf_vdata = 0;
    wire [15:0] pfx_vdata = 16'h0000;
    always @(posedge clk_sys_7159)
        pf_vdata <= {2'b00, pf_vaddr[11:0], 2'b00} | {4'd0, pf_vaddr};
    reg  [4:0] pfcol_q0, pfcol_q1, pfcol_q2, pfcol_q3, pfcol_show, pfcol_next;
    reg  [3:0] pfcode_q0, pfcode_q1, pfcode_q2, pfcode_q3, pfcode_show;
    reg  [31:0] pfring0, pfring1, pfring2, pfring3;
    reg  [31:0] pf_show, pf_next;
    reg  [1:0]  pf_wp = 0, pf_inflA = 0, pf_inflB = 0, pf_rp = 0;
    reg  [23:0] pfq_addr0, pfq_addr1, pfq_addr2, pfq_addr3;
    reg  [1:0]  pfq_slot0, pfq_slot1, pfq_slot2, pfq_slot3;
    reg  [2:0]  pfq_count = 0;
    reg  [1:0]  pfq_wr = 0, pfq_rd = 0;
    reg         inflA = 1'b0, inflB = 1'b0;
    reg         vg_reqA_px = 0, vg_reqB_px = 0;
    reg  [23:0] vg_addrA_px = 0, vg_addrB_px = 0;
    reg         vg_doneA_last = 0, vg_doneB_last = 0;
    reg  [31:0] vg_dataA = 0, vg_dataB = 0;

    // CDC, single capture FF each way (SDSCHED-74, core_top :1341/:1348)
    wire vg_reqA_s, vg_reqB_s;
    reg  vg_reqA_s_q = 0, vg_reqB_s_q = 0;
    always @(posedge clk_sdram) begin
        vg_reqA_s_q <= vg_reqA_px;
        vg_reqB_s_q <= vg_reqB_px;
    end
    assign vg_reqA_s = vg_reqA_s_q;
    assign vg_reqB_s = vg_reqB_s_q;
    wire vg_doneA_s, vg_doneB_s;
    reg  vg_doneA_s_q = 0, vg_doneB_s_q = 0;
    reg  vg_doneA_85 = 0, vg_doneB_85 = 0;
    always @(posedge clk_sys_7159) begin
        vg_doneA_s_q <= vg_doneA_85;
        vg_doneB_s_q <= vg_doneB_85;
    end
    assign vg_doneA_s = vg_doneA_s_q;
    assign vg_doneB_s = vg_doneB_s_q;

    // sdram-domain service chain
    reg         vg_reqA_last = 0, vg_reqB_last = 0;
    reg  [1:0]  cvg_ph = 0;
    reg  [2:0]  cmg_ph = 0;
    reg  [15:0] cvg_hi = 0;
    reg         cvg_ch = 0;
    reg         vgmg_last_mo = 0;
    reg  [1:0]  cst_ph = 0;
    reg  [8:0]  cst_i = 0;
    reg  [15:0] cst_sum0 = 0, cst_sum1 = 0;
    reg         cst_go = 0, cst_done = 0;
    reg         vb_cst_d = 0;
    wire        vidkill_sd = 1'b0;   // no R2 / mode-6 diagnostic in this bench

    // CRAM download-mirror queue - the real one, sliced out of core_top and
    // included below.  It is the client that competes with the playfield for
    // the controller, and it is live at every chk_state because core_top
    // places it OUTSIDE the chk_state case.
    reg  [21:0] cq_addr [0:7];
    reg  [15:0] cq_data [0:7];
    reg  [2:0]  cq_wr = 0, cq_rd = 0;
    reg  [3:0]  cq_n = 0;
    reg  [1:0]  cwr_ph = 0;
    reg         cwr_snoop_d = 0;
    reg         cq_enq, cq_deq;
    // synthetic SDRAM gfx-region write stream feeding that queue: one 32-bit
    // word every WR_PERIOD clk_sdram cycles while wr_run is set.  WR_PERIOD
    // is swept by the runner script rather than fixed, because the point is
    // to find where the exposure starts, not to pick a number that passes.
    reg  [24:0] sd_wr_addr = 25'h0120000;
    reg  [31:0] sd_wr_data = 32'h12345678;
    reg         sd_wr_req  = 0;
    reg         wr_run     = 0;
    integer     wr_ctr     = 0;
    always @(posedge clk_sdram) begin
        sd_wr_req <= 1'b0;
        if(wr_run) begin
            if(wr_ctr >= WR_PERIOD) begin
                wr_ctr     <= 0;
                sd_wr_req  <= 1'b1;
                sd_wr_addr <= sd_wr_addr + 25'd4;
                sd_wr_data <= sd_wr_data + 32'h01010101;
            end else wr_ctr <= wr_ctr + 1;
        end
    end
    // MO is served from SDRAM on this branch; these exist only because the
    // extracted vidkill drain arm and the resync reference them.
    wire [3:0] mg_req_s = 4'd0;
    reg  [3:0] mg_req_last = 4'd0, mg_done_85 = 4'd0;
    reg  [127:0] mg_data = 0;
    integer mci;
    reg fpv_valid = 0, fpe_valid = 0, fpv_vpre = 0, fpe_vpre = 0;

    // ======================= THE SHIPPED RTL ==========================
    `include "pf_pixel.vh"

    always @(posedge clk_sdram) begin
        // core_top puts all three of these in ONE always block, in this order:
        // the download-mirror queue first (outside the chk_state case), then
        // the case, then the resync.  The order is load-bearing - it decides
        // who wins a same-cycle write to cram_addr and to vg_reqA_last - so it
        // is reproduced exactly.
        `include "pf_drain.vh"
        if(chk_state == 4'd10) begin
            `include "pf_service.vh"
        end
        // the resync is OUTSIDE the chk_state case in core_top (:1704), and it
        // is the LAST writer of vg_reqA_last/vg_reqB_last in that always block.
        // Both properties are load-bearing and are preserved here.
        `include "pf_resync.vh"
    end
    // ==================================================================

    // ---------------- instrumentation (observation only; drives nothing)
    // All counters use non-blocking assignment so a read from the stimulus
    // block immediately after a clock edge always sees the pre-edge value,
    // whichever order the simulator schedules the two blocks in.  With
    // blocking counters the window boundaries would be off by an
    // unpredictable +-1.
    // An issue is an inflA/inflB RISING edge, not a request-toggle change.
    // The two are the same thing in the issue arm, but the fix also drives
    // vg_reqA_px to 0 under reset, and counting that as an issue would let a
    // fixed build look like it had issued (and lost) two requests it never
    // made.  inflA is only ever SET in the issue arm, so its rising edge is
    // exactly "a fetch was launched".
    integer issueA = 0, issueB = 0, doneA = 0, doneB = 0;
    integer enq = 0;
    reg vgA_d = 0, vgB_d = 0, dA_d = 0, dB_d = 0;
    always @(posedge clk_sys_7159) begin
        vgA_d <= inflA;  vgB_d <= inflB;
        if(inflA && !vgA_d) issueA <= issueA + 1;
        if(inflB && !vgB_d) issueB <= issueB + 1;
        if(vis_x[2:0] == 3'd3
           && y_count >= VID_V_BPORCH - 2 && y_count < VID_V_BPORCH + VID_V_ACTIVE
           && pfq_count != 3'd4) enq <= enq + 1;
    end
    always @(posedge clk_sdram) begin
        dA_d <= vg_doneA_85;  dB_d <= vg_doneB_85;
        if(vg_doneA_85 !== dA_d) doneA <= doneA + 1;
        if(vg_doneB_85 !== dB_d) doneB <= doneB + 1;
    end
    // "was this channel ever seen idle after the reset released?"  A wedged
    // channel sits at infl=1 forever; a live one is idle between fetches.
    reg watch_post = 0;
    reg seenA_idle = 0, seenB_idle = 0;
    always @(posedge clk_sys_7159) if(watch_post) begin
        if(!inflA) seenA_idle <= 1'b1;
        if(!inflB) seenB_idle <= 1'b1;
    end
    // Whole-run accounting.  The windowed numbers are not enough on their own:
    // in PHASE 1 the requests that get eaten are eaten in the first few
    // scanlines, long before the measurement windows open, so a windowed
    // "lost" count reads 0 for a channel that has been dead since t=0.
    integer iss_in_reset = 0;    // fetches launched while core_reset_n was low
    always @(posedge clk_sys_7159)
        if(!core_reset_n)
            iss_in_reset <= iss_in_reset + ((inflA && !vgA_d) ? 1 : 0)
                                         + ((inflB && !vgB_d) ? 1 : 0);

    // ---------------- stimulus
    integer iA0, iB0, dA0, dB0, e0;
    integer base_i, base_d, base_e;
    integer rst_i, rst_d;
    integer post_i, post_d, post_e;
    integer expect_post, lost;

    task wait_line(input [15:0] f, input [9:0] yy);
        begin
            @(posedge clk_sys_7159);
            while(!(frame_id == f && y_count == yy && x_count == 10'd0))
                @(posedge clk_sys_7159);
        end
    endtask

    initial begin
        $display("### tb_pf_reset  PHASE=%0d  BASE_LINES=%0d RESET_LINES=%0d POST_LINES=%0d WR_PERIOD=%0d",
                 PHASE, BASE_LINES, RESET_LINES, POST_LINES, WR_PERIOD);
        if(PHASE == 1) begin
            // boot download: the machine is held in reset and chk_state is
            // pinned at 0, so the CRAM read-start chain cannot run at all.
            core_reset_n = 1'b0;
            chk_state    = 4'd0;
        end

        // ---- warm-up: one whole frame, so the pipeline and the psram
        // controller are in steady state before anything is measured.
        wait_line(16'd1, VID_V_BPORCH);

        // ---- baseline window (PHASE 0/2 only: PHASE 1 is still in reset)
        iA0 = issueA; iB0 = issueB; dA0 = doneA; dB0 = doneB; e0 = enq;
        wait_line(16'd1, VID_V_BPORCH + BASE_LINES);
        base_i = (issueA - iA0) + (issueB - iB0);
        base_d = (doneA  - dA0) + (doneB  - dB0);
        base_e = enq - e0;
        $display("### baseline   %0d lines: enqueued %0d  issued %0d  completed %0d  (issueA %0d issueB %0d)",
                 BASE_LINES, base_e, base_i, base_d, issueA - iA0, issueB - iB0);

        // ---- the reset
        iA0 = issueA; iB0 = issueB; dA0 = doneA; dB0 = doneB;
        if(PHASE == 1) begin
            $display("### t=%0t  boot download: reset held since t=0, chk_state 4'd0", $time);
            wait_line(16'd1, VID_V_BPORCH + BASE_LINES + RESET_LINES);
            chk_state = 4'd10;
        end else begin
            // PHASE 2 additionally opens the CRAM download-mirror queue: a
            // gfx-region SDRAM write stream, snooped by the real drain block,
            // which holds cq_n non-zero and the controller busy.  The shipped
            // read-start chain requires cq_n == 4'd0, so while that traffic
            // runs the chain cannot always catch a request edge in the single
            // cycle it has before the resync retires it.
            if(PHASE == 2) wr_run = 1'b1;
            core_reset_n = 1'b0;
            $display("### t=%0t  core_reset_n LOW at y=%0d (chk_state stays 4'd10, drain %0s)",
                     $time, y_count, (PHASE == 2) ? "RUNNING" : "idle");
            wait_line(16'd1, VID_V_BPORCH + BASE_LINES + RESET_LINES);
        end
        rst_i = (issueA - iA0) + (issueB - iB0);
        rst_d = (doneA  - dA0) + (doneB  - dB0);
        core_reset_n = 1'b1;
        wr_run = 1'b0;
        $display("### t=%0t  core_reset_n HIGH.  during reset: issued %0d  completed %0d  (LOST %0d)",
                 $time, rst_i, rst_d, rst_i - rst_d);

        // ---- settle, then the post-release window
        wait_line(16'd1, VID_V_BPORCH + BASE_LINES + RESET_LINES + 4);
        watch_post = 1'b1;
        iA0 = issueA; iB0 = issueB; dA0 = doneA; dB0 = doneB; e0 = enq;
        wait_line(16'd1, VID_V_BPORCH + BASE_LINES + RESET_LINES + 4 + POST_LINES);
        post_i = (issueA - iA0) + (issueB - iB0);
        post_d = (doneA  - dA0) + (doneB  - dB0);
        post_e = enq - e0;
        // The reference the post-reset window has to match.
        //
        // PHASE 0 compares against the SAME RUN's pre-reset throughput, which
        // is the tightest available invariant and cannot be detuned: the only
        // thing that changed between the two windows is the reset.
        //
        // PHASE 1 has no usable pre-reset window (the core is held in reset
        // for all of it), so it uses the pipeline's own full rate: 57 enqueue
        // phases per scanline (VID_H_TOTAL 456 / 8), every one inside active
        // video.  Same reasoning as the MiSTer bench's 57 x 242 = 13,794 -
        // a structural number, not a threshold tuned to pass.
        expect_post = (PHASE == 1) ? 57 * POST_LINES : base_i;

        $display("### post-reset %0d lines: enqueued %0d  issued %0d  completed %0d  (issueA %0d issueB %0d)",
                 POST_LINES, post_e, post_i, post_d, issueA - iA0, issueB - iB0);
        $display("### reference issues %0d   inflA=%0d inflB=%0d   idle-seen A=%0d B=%0d",
                 expect_post, inflA, inflB, seenA_idle, seenB_idle);
        $display("### whole run: issued %0d (A %0d B %0d)  completed %0d  UNRETIRED %0d  issued-under-reset %0d",
                 issueA + issueB, issueA, issueB, doneA + doneB,
                 (issueA + issueB) - (doneA + doneB), iss_in_reset);

        // ---- verdict.  Printed in a machine-greppable form; the runner
        // script grades a PAIR of runs (fix present / fix excised) so a
        // negative control that stops failing is itself a failure.
        //
        // lost = fetches launched over the WHOLE run that never came back.
        // Deliberately not the windowed count: in PHASE 1 the eaten requests
        // are eaten in the first scanlines, long before any window opens.
        lost = (issueA + issueB) - (doneA + doneB);
        if(post_i == 0)
            $display("PFRESET_RESULT PHASE=%0d VERDICT=WEDGED_BOTH lost=%0d post_issued=%0d expected=%0d",
                     PHASE, lost, post_i, expect_post);
        else if(!seenA_idle || !seenB_idle)
            $display("PFRESET_RESULT PHASE=%0d VERDICT=WEDGED_ONE lost=%0d post_issued=%0d expected=%0d",
                     PHASE, lost, post_i, expect_post);
        else if(post_i < expect_post - 57)
            $display("PFRESET_RESULT PHASE=%0d VERDICT=DEGRADED lost=%0d post_issued=%0d expected=%0d",
                     PHASE, lost, post_i, expect_post);
        else
            $display("PFRESET_RESULT PHASE=%0d VERDICT=ALIVE lost=%0d post_issued=%0d expected=%0d",
                     PHASE, lost, post_i, expect_post);
        $display("PFRESET_BASELINE PHASE=%0d base_issued=%0d base_expected=%0d rst_issued=%0d inreset=%0d",
                 PHASE, base_i, 57 * BASE_LINES, rst_i, iss_in_reset);
        $finish;
    end

    // hard stop: never let a hung bench look like a clean exit
    initial begin
        #200_000_000;
        $display("PFRESET_RESULT PHASE=%0d VERDICT=TIMEOUT lost=0 post_issued=0 expected=0", PHASE);
        $fatal(1, "tb_pf_reset: timed out");
    end
endmodule
