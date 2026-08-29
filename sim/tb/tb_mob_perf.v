// tb_mob_perf: MOFETCH performance bench for the MO line engine.
//
// Deliberately a SEPARATE file from sim/tb/tb_mob.v so the fetch-path work and
// the priority work can be developed and merged independently. This bench only
// cares about THROUGHPUT: how much of the scene the engine manages to build
// inside the 456-cycle scanline budget, and where those cycles go.
//
// It renders one frame of the MO layer to sim/build/mob_perf_pixels.txt, which
// sim/tools/mob_golden.py scores against a golden model of the engine's own
// intended output (see that file: divergence == time starvation, by design).
//
// Cycle accounting is by FSM state, so escape_mob.v must keep
//   S_IDLE == 0, S_BLIT == 11, S_PRIME == 13
// for the phase split to stay meaningful across revisions.
//
// Run: sim/run_mob_perf.sh   (MOB_PARAMS='-Ptb_mob_perf.XSCROLL=50 ...')
`timescale 1ns/1ps

module tb_mob_perf;
    parameter XSCROLL = 50;
    parameter YSCROLL = 157;
    parameter GFX_LAT = 8;   // pixel-clock cycles per fetch (device-realistic)
    // MOCHAN-4: SHARED-SERVER OCCUPANCY, in pixel clocks. The per-channel
    // latency model below is a LATENCY model: every channel's round trip runs
    // independently, which is what "N channels in flight divides the effective
    // per-tile cost by N" assumes. The real MO path is not N independent
    // servers - core_top serializes every MO fetch through one SDRAM read port
    // (mo_owner), so only the round trip overlaps, not the port occupancy.
    // That is a fair model as long as occupancy << GFX_LAT/NCH: an MO burst
    // holds mo_owner for ~10 clocks at 35.795455MHz = 279ns, against a
    // 139.68ns pixel clock.
    // CLKFIX-106/PERFDIV-111: this used to read "10 clocks at 85.909MHz =
    // 116ns ... so real occupancy is well under ONE pixel clock". clk_sdram is
    // 35.795455 MHz (mf_pllbase outclk_2), so the period is 27.94ns and the
    // burst is 279ns - TWO pixel clocks, not "well under one". The stated
    // justification for the independent-latency model was therefore backwards:
    // occupancy is NOT << GFX_LAT/NCH. Use GFX_OCC (below) to re-measure any
    // concurrency claim against a serialized port rather than trusting the
    // independent model's absolute numbers.
    // GFX_OCC forces a minimum spacing between fetch STARTS across all four
    // channels so the concurrency win can be re-measured against a serialized
    // port. 0 = the independent model (matches the pre-MOCHAN-4 bench exactly).
    parameter GFX_OCC = 0;
    parameter NCH     = 4;

    reg clk = 0;
    always #69.84 clk = ~clk;           // 7.159MHz pixel clock

    localparam VID_V_BPORCH = 'd12;
    localparam VID_V_ACTIVE = 'd240;
    localparam VID_V_TOTAL  = 'd262;
    localparam VID_H_BPORCH = 'd60;
    localparam VID_H_ACTIVE = 'd336;
    localparam VID_H_TOTAL  = 'd456;
    reg [9:0] x_count = 0, y_count = 0;
    always @(posedge clk) begin
        x_count <= x_count + 1'b1;
        if(x_count == VID_H_TOTAL-1) begin
            x_count <= 0;
            y_count <= y_count + 1'b1;
            if(y_count == VID_V_TOTAL-1) y_count <= 0;
        end
    end
    wire [9:0] visible_x = x_count - VID_H_BPORCH;
    wire [9:0] visible_y = y_count - VID_V_BPORCH;

    // ---------------- RAM models (single-registered reads, BRAM-equivalent)
    reg [15:0] momem [0:4095];
    reg [15:0] cfgmem [0:127];
    integer gi, nz_code, nz_slip;
    initial begin
        $readmemh("sim/work/game_mo.hex", momem);
        $readmemh("sim/work/game_cfg.hex", cfgmem);
        // fixture guard: docs/investigations/LESSONS.md - $readmemh failure is not an error,
        // and an all-zero MO fixture silently renders a blank layer.
        nz_code = 0; nz_slip = 0;
        for(gi = 0; gi < 1024; gi = gi + 1)
            if(momem[gi*4+1] !== 16'h0000) nz_code = nz_code + 1;
        for(gi = 16'h40; gi < 16'h80; gi = gi + 1)
            if(cfgmem[gi] !== 16'h0000) nz_slip = nz_slip + 1;
        $display("FIXTURE entries_with_code=%0d populated_slip_bands=%0d", nz_code, nz_slip);
        if(nz_code < 8 || nz_slip < 2)
            $fatal(1, "tb_mob_perf: sim/work/game_{mo,cfg}.hex holds no scene");
    end
    wire [11:0] mo_vaddr;
    reg  [15:0] mo_vdata;
    wire [6:0]  cfg_vaddr;
    reg  [15:0] cfg_vdata;
    always @(posedge clk) begin
        mo_vdata  <= momem[mo_vaddr];
        cfg_vdata <= cfgmem[cfg_vaddr];
    end

    // measurement window flag - declared early, the gfx model's concurrency
    // census below needs it
    reg measuring = 0, dumping = 0;
    // the line-abort/restart cycle, exactly as escape_mob tests for it
    wire abort_now = (x_count == 10'd0 && y_count >= VID_V_BPORCH-1
                      && y_count < VID_V_BPORCH+VID_V_ACTIVE-1);

    // ---------------- gfx model: real chunky image bytes, GFX_LAT latency
    reg [7:0] gfx [0:(1<<22)-1];        // image bytes 0..0x220000
    initial $readmemh("sim/work/image_bytes.hex", gfx);
    wire [3:0]   gfx_req;
    wire [95:0]  gfx_addr;
    reg  [3:0]   gfx_done = 4'd0;
    reg  [127:0] gfx_data;
    reg  [3:0]   req_d = 4'd0;
    reg  [6:0]   lat  [0:3];            // 0 = channel idle
    reg  [23:0]  addr_l [0:3];
    reg  [6:0]   occ_ctr = 0;           // shared-server spacing countdown
    integer      k;
    // concurrency census: how many fetches are genuinely in flight at once.
    // This is the POSITIVE EXERCISE METRIC for this change - if it never
    // exceeds 2 then the four channels are not actually being used and any
    // coverage change came from somewhere else.
    integer conc_hist [0:4];
    integer inflight_now, conc_max;
    initial begin
        for(k = 0; k < 4; k = k + 1) begin lat[k] = 0; addr_l[k] = 0; end
        for(k = 0; k < 5; k = k + 1) conc_hist[k] = 0;
        gfx_data = 0; conc_max = 0;
    end
    always @(posedge clk) begin
        if(occ_ctr != 0) occ_ctr <= occ_ctr - 7'd1;
        for(k = 0; k < NCH; k = k + 1) begin
            if(gfx_req[k] != req_d[k] && lat[k] == 0
               && (GFX_OCC == 0 || occ_ctr == 0)) begin
                req_d[k]  <= gfx_req[k];
                addr_l[k] <= gfx_addr[k*24 +: 24];
                lat[k]    <= GFX_LAT[6:0];
                if(GFX_OCC != 0) occ_ctr <= GFX_OCC[6:0];
            end else if(lat[k] != 0) begin
                lat[k] <= lat[k] - 7'd1;
                if(lat[k] == 7'd1) begin
                    gfx_data[k*32 +: 32] <= {gfx[addr_l[k]],   gfx[addr_l[k]+1],
                                             gfx[addr_l[k]+2], gfx[addr_l[k]+3]};
                    gfx_done[k] <= ~gfx_done[k];
                end
            end
        end
    end
    always @(posedge clk) if(measuring) begin
        inflight_now = 0;
        for(k = 0; k < NCH; k = k + 1) if(lat[k] != 0) inflight_now = inflight_now + 1;
        conc_hist[inflight_now] = conc_hist[inflight_now] + 1;
        if(inflight_now > conc_max) conc_max = inflight_now;
    end

    // ---------------- DUT
    reg rstn = 0;
    initial begin rstn = 0; repeat (20) @(posedge clk); rstn = 1; end
    wire [7:0] disp_pen;
    wire       disp_valid;
    escape_mob dut (
        .clk      ( clk ),
        .reset_n  ( rstn ),
        .x_count  ( x_count ),
        .y_count  ( y_count ),
        .vbporch  ( 10'd12 ),
        .vactive  ( 10'd240 ),
        .hbporch  ( 10'd60 ),
        .xscroll  ( XSCROLL[8:0] ),
        .yscroll  ( YSCROLL[8:0] ),
        .mo_vaddr ( mo_vaddr ),
        .mo_vdata ( mo_vdata ),
        .cfg_vaddr( cfg_vaddr ),
        .cfg_vdata( cfg_vdata ),
        .gfx_req  ( gfx_req ),
        .gfx_addr ( gfx_addr ),
        .gfx_done ( gfx_done ),
        .gfx_data ( gfx_data ),
        .disp_x   ( visible_x[8:0] ),
        .disp_pen ( disp_pen ),
        .disp_valid( disp_valid )
    );

    // ---------------- MOFETCH instrumentation
    // Everything below is measured over ONE frame (the measured window).
    //
    // PERFDIV-111: that window is `repeat (VID_V_TOTAL * VID_H_TOTAL)` - all
    // 262 scanlines, blanking included - and the phase counters below are
    // gated on `measuring` alone, so they accumulate over 262 lines, not 240.
    // The per-line divisors used to be a literal 240 (and chan_occupancy a
    // literal 240*456), which inflated every per-line figure this bench ever
    // printed by 262/240 = 1.0917, i.e. ~9.2% high. The tell was visible in
    // the output the whole time: "per line: 186/63/55/192" sums to 496 cycles
    // on a scanline that only has 456. The comment that seeded the mistake
    // read "directly comparable to the 456 cycles x 240 lines a frame has" -
    // it confused the ACTIVE-area budget with the ACCUMULATION window.
    //
    // The error is common-mode: it scaled every phase and every configuration
    // identically, so all relative comparisons and all conclusions drawn from
    // them are unaffected. Only the absolute per-line numbers were wrong.
    //
    // Divisors now reference the localparams so they cannot drift again, and
    // PERF cycles_check below asserts the identity that would have caught it.
    //
    // "Per line" is now stated TWICE, because there are two defensible
    // denominators and the old output silently mixed them:
    //
    //   frame-mean  = total / VID_V_TOTAL (262). Every scanline in the frame,
    //                 blanking included. Sums to exactly VID_H_TOTAL.
    //   during-build= in-build total / VID_V_ACTIVE (240). escape_mob only
    //                 STARTS a build for y in [vbporch-1, vbporch+vactive-1),
    //                 which is 240 lines, so this answers "when a build is
    //                 running, where do the 456 cycles of that line go".
    //
    // MEASURED, not assumed: a build started on the last build line runs on
    // into vblank, so the phase counters are NOT confined to the 240 build
    // lines (a representative run leaves trav=66 prime=125 blit=669 cycles in
    // the 22 vblank lines). Dividing the whole-frame total by 240 - which is
    // what this bench used to do - is therefore wrong under BOTH definitions.
    // The two splits are printed side by side so nobody has to guess again.
    localparam S_IDLE = 4'd0, S_BLIT = 4'd11, S_PRIME = 4'd13;

    integer c_idle, c_trav, c_prime, c_blit;     // cycles by phase, this frame
    // PERFDIV-111: same four phases, restricted to the build window.
    integer b_idle, b_trav, b_prime, b_blit, b_win, v_win;
    integer n_lines, n_complete, n_aborted;      // build outcome per line
    integer n_ymatch, n_wren, n_wren_off, n_reqs;
    integer n_budget_out;                        // lines that hit fetch_budget==0
    integer n_deadtile, n_blitpx;                // tile-rows blitted wholly offscreen
    integer px_seen;
    integer line_entries, max_entries, n_entries;
    reg [3:0] state_d = 0;
    reg [9:0] mo_vaddr_d = 0;
    // MOCOV: how many SPRITES were loaded, and how wide were they. The split of
    // S_PRIME between "per-sprite startup latency" and "steady-state tile
    // pipelining" decides which lever is worth pulling, and it is entirely a
    // question of tiles-per-sprite: a 1-tile sprite can never amortise a fetch.
    integer n_sprites, n_tilerows;
    // MOCHAN-4/MODEPTH-1 diagnostics for the STARTUP term (which is a pure
    // latency and does NOT divide by channel count, unlike the steady-state
    // term):
    //   n_pfhit    - sprites loaded with tile 0 already in flight
    //   c_sc_block - cycles the scout wanted to prefetch but could not spare a
    //                channel (fewer than two free)
    //   c_sc_noarm - cycles with nothing parked to prefetch at all (the scout
    //                had not walked far enough)
    //   c_sc_done  - cycles with every parked entry already prefetched
    integer n_pfhit, c_sc_block, c_sc_noarm, c_sc_done, n_leadsum, n_leadn;
    integer pf_issue_t, now_t;
`ifndef MOB_BASE
    // MODEPTH-1: THE POSITIVE EXERCISE METRIC for prefetch depth. If the park
    // queue never reaches 2, or if n_pf_b is 0, the second slot is not being
    // used and any coverage change came from somewhere else.
    //   c_q0/1/2   - cycles at each queue occupancy
    //   n_pf_a/b   - prefetches issued for the head slot / the second slot
    //   c_sc_room  - cycles the scout was stalled with the queue FULL. This is
    //                the number that says whether a THIRD slot would pay.
    //   c_sc_walk  - cycles the scout spent actually walking the list
    //   c_yield    - cycles the walk gave the MO RAM port back to the blitter
    //   n_chclash  - a fetch issued to a channel that was still busy. MUST be 0:
    //                it is the invariant the rotation used to provide and the
    //                free list now provides, and it is what makes the two-deep
    //                queue safe rather than merely lucky.
    integer c_qd [0:8];          // cycles at each park-queue occupancy
    integer n_pf_slot [0:8];     // prefetches issued for each queue slot
    integer c_sc_room, c_sc_walk, c_yield;
    integer n_chclash, qk;
    // lead time per slot, shadowing the queue's own shift
    integer pf_t [0:8];
    // MODIAG-1: WHERE THE FETCH STALL ACTUALLY IS.
    // startup/steady splits the S_PRIME stall by tiles-per-sprite, which says
    // WHICH sprite the engine is waiting on but not WHY. These say why, and
    // they are what decide whether the next lever is channels or issue time.
    //   c_pr_unissued - waiting for a tile whose fetch has NOT gone out yet.
    //                   That is issue bandwidth: a free channel, or the pump's
    //                   one-issue-per-cycle rate. More channels, deeper queues
    //                   and row buffers all attack this term.
    //   c_pr_inflight - the fetch is out and we are waiting for memory. Pure
    //                   GFX_LAT. Nothing downstream of the issue touches it;
    //                   only asking EARLIER does.
    //   c_pr_t1/c_pr_tn - and which tile. The pump cannot ask for a sprite's
    //                   tile 1 until pump_live, i.e. until the blitter has
    //                   LOADED that sprite; tile 0 then blits for 8 cycles
    //                   while tile 1 is still GFX_LAT-8 away. Tiles 2,3,...
    //                   went out on the following cycles and have nearly
    //                   caught up by the time they are wanted.
    //   c_pumpblk     - the pump wanting a channel and not getting one, counted
    //                   ONLY while the blitter is simultaneously stalled.
    //                   Unqualified it over-counts wildly: a sprite with all
    //                   four tiles in flight has no free channel and is not
    //                   stalled at all.
    //   c_chbusy      - summed channels held (infl|pend); over the window this
    //                   is mean channel occupancy out of NCH.
    // Uses only signals every revision since MOCHAN-4 has, so it scores the
    // shipping engine without any RTL change.
    //
    // ---- WHAT THEY SAID, THE FIRST TIME THEY WERE READ -------------------
    // Recorded here so the next person does not have to re-derive it, and so a
    // later change can be diffed against a real baseline rather than a memory.
    // Shipping engine (BUILD 106 escape_mob.v, byte-identical to 105's) at
    // scene 50/157, GFX_LAT=31, one frame:
    //
    //   prime 33,682  =  startup 9,395  +  steady 24,287
    //   unissued 50      inflight 33,632
    //   tx1 17,153       txN 7,134
    //   pump_blocked 16,937            chan_occupancy 2.00 / 4
    //
    // Two readings, and they point the same way:
    //
    //  1. 99.85% of the fetch stall (33,632 of 33,682) is waiting for MEMORY on
    //     a fetch that has already gone out. Only 50 cycles a frame are spent
    //     waiting for a tile nobody has asked for yet. The pump is therefore
    //     NOT channel-starved, and anything that merely frees channels sooner
    //     has almost nothing to free. That is not a prediction: MOHARV-1 built
    //     exactly such a change - harvesting the pump's completed rows out of
    //     their channels into an in-order row buffer, so a channel is released
    //     at completion instead of at blit - and measured it. It worked as
    //     designed (4,383 harvests a frame, chan_occupancy 2.00 -> 1.80, scout
    //     channel starvation 13,604 -> 7,931 cycles, prime 33,682 -> 33,181)
    //     and moved COVERAGE NOT AT ALL, in all nine sweep cells and at lat 40,
    //     48 and 62 as well. It was dropped. See branch mo-harvest if the
    //     channel theory ever looks attractive again; it is already refuted.
    //
    //  2. 71% of the whole steady-state term (17,153 of 24,287) is ONE sprite's
    //     SECOND tile. The cause is structural, not statistical: pump_ready
    //     requires pump_live, which is S_PRIME|S_BLIT, so a sprite's tile 1
    //     cannot be requested until the blitter has already LOADED that sprite.
    //     Tile 0 then blits for 8 cycles while tile 1 is still GFX_LAT-8 cycles
    //     away - 23 of them at lat31 - and that is one unavoidable stall per
    //     sprite. Tiles 2,3,... are issued on the cycles immediately after tile
    //     1 and have nearly caught up by the time they are wanted, which is why
    //     txN is a third of tx1 despite covering every later tile of every
    //     sprite in the frame. (At lat62 the two converge - tx1 18,079 vs txN
    //     18,237 - because there even the trailing tiles can no longer catch
    //     up. The lever below widens to tiles 1..n at that point.)
    //
    // So the next sprite-throughput lever is ISSUE TIME: the SCOUT prefetching
    // tile 1 (and, at high latency, tiles 1..n) of a sprite that is still
    // PARKED, so the fetch is in flight before the blitter ever loads it. The
    // scout already decodes and holds code_row and row for every queue slot, so
    // tile k's address is code_row + k with no new decode; and chan_occupancy
    // of 1.80-2.00 out of 4 says the channels to do it with are sitting idle.
    // Note that such a prefetch WOULD need MOHARV-1's harvest to come back with
    // it - a prefetched later tile parked behind the blitter would otherwise
    // pin its channel from issue all the way to its blit - so the two changes
    // belong together, in that order, and neither is worth landing alone.
    integer c_pr_unissued, c_pr_inflight, c_pr_t1, c_pr_tn, c_pumpblk, c_chbusy;
    integer chb;
`endif
    // DRAW-ORDER PROOF. The sequence of sprites the blitter loads, per built
    // line, dumped so the depth engine can be diffed against the depth-1 one:
    // both walk the list head-first, so the shorter run must be a strict PREFIX
    // of the longer. Uses only signals every revision has - at S_WAIT, mo_vaddr
    // still holds w2's address of the entry just loaded.
    integer ofd;
    reg [1023:0] ordpath;
    integer n_orderslip;
    integer ord_q [0:1023];
    integer ord_h, ord_t;
    // ...and WHERE in S_PRIME the engine waits:
    //   issue   - blit_n==15: the sprite-start issue cycle, or blocked on a
    //             channel still in flight after a line abort
    //   startup - blit_n==14 && tx==0: waiting for THIS sprite's FIRST tile.
    //             Unavoidable per-sprite latency unless the fetch is issued
    //             before the blitter reaches the sprite (MOCOV-1).
    //   steady  - blit_n==14 && tx!=0: waiting for a later tile of a sprite
    //             already in progress. This is what more channels in flight
    //             would shorten - and a 1-tile sprite never gets here.
    integer c_pr_issue, c_pr_start, c_pr_steady;

    initial begin
        c_idle=0; c_trav=0; c_prime=0; c_blit=0;
        b_idle=0; b_trav=0; b_prime=0; b_blit=0; b_win=0; v_win=0;
        n_lines=0; n_complete=0; n_aborted=0;
        n_ymatch=0; n_wren=0; n_wren_off=0; n_reqs=0; n_budget_out=0;
        px_seen=0; line_entries=0; max_entries=0; n_entries=0;
        n_deadtile=0; n_blitpx=0; n_sprites=0; n_tilerows=0;
        c_pr_issue=0; c_pr_start=0; c_pr_steady=0;
        n_pfhit=0; c_sc_block=0; c_sc_noarm=0; c_sc_done=0; n_leadsum=0; n_leadn=0;
        pf_issue_t=0; now_t=0;
`ifndef MOB_BASE
        for(qk = 0; qk < 9; qk = qk + 1) begin
            c_qd[qk]=0; n_pf_slot[qk]=0; pf_t[qk]=0;
        end
        c_sc_room=0; c_sc_walk=0; c_yield=0; n_chclash=0;
        c_pr_unissued=0; c_pr_inflight=0; c_pr_t1=0; c_pr_tn=0;
        c_pumpblk=0; c_chbusy=0; chb=0;
`endif
        n_orderslip=0; ord_h=0; ord_t=0;
    end

    // MOCHAN-4: the pump issues in parallel with S_PRIME/S_BLIT, so the old
    // blit_n==15 "dedicated issue cycle" no longer exists and the issue bucket
    // reads 0 on this engine. startup/steady keep their meaning exactly.
    always @(posedge clk) if(measuring) begin
        // a sprite LOAD == entering S_E0 (the blitter taking a parked hit)
        now_t = now_t + 1;
        if(dut.state == 4'd4 && state_d != 4'd4) begin
            n_sprites = n_sprites + 1;
`ifdef MOB_BASE
            // ORDFIX-131: the base arm probed sc_pf_valid/pf_issue_t, signals
            // of an engine generation that no resolvable BASE_REF still has -
            // the gate failed to elaborate for EVERY recent base, and had been
            // doing so silently inside run_all_gates. All queue-era bases
            // expose q_pf/pf_t, so probe those in both arms; the gate is
            // documented as adjacent-commits-only anyway.
            // (no lead-time term here: pf_t lives behind the MODEPTH probe
            // guard, and this gate's verdict is the +ord order diff, not the
            // diagnostics - the base arm only has to elaborate and count.)
            if(dut.q_pf[0]) n_pfhit = n_pfhit + 1;
`else
            if(dut.q_pf[0]) begin
                n_pfhit = n_pfhit + 1;
                // LEAD TIME: cycles between the prefetch going out and the
                // blitter adopting it. This must reach GFX_LAT for the
                // per-sprite startup wait to be fully hidden. With a queue the
                // timestamp travels with the slot, so it is shadowed below.
                n_leadsum = n_leadsum + (now_t - pf_t[0]);
                n_leadn   = n_leadn + 1;
            end
`endif
        end
`ifdef MOB_BASE
        // ORDFIX-131: same modernization as above - the queue-era census works
        // on every base this gate can actually resolve.
        if(dut.pump_live && !dut.pump_ready) begin
            if(!dut.sc_want)           c_sc_done  = c_sc_done  + 1;
            else if(dut.q_cnt == 3'd0) c_sc_noarm = c_sc_noarm + 1;
        end
`else
        // ---- MODEPTH-1 census ----------------------------------------------
        // where the scout's time goes, and how deep the queue actually gets
        c_qd[dut.q_cnt] = c_qd[dut.q_cnt] + 1;
        if(dut.sstate == 4'd7) c_sc_room = c_sc_room + 1;              // SC_ROOM
        if(dut.sstate >= 4'd1 && dut.sstate <= 4'd6) c_sc_walk = c_sc_walk + 1;
        if(dut.blit_port && dut.sstate >= 4'd1 && dut.sstate <= 4'd4)
            c_yield = c_yield + 1;
        // why the scout is NOT prefetching, over the same window the MOCHAN-4
        // bench measured (the blitter in prime/blit with all its tiles issued)
        if(dut.pump_live && !dut.pump_ready) begin
            if(!dut.sc_want)           c_sc_done  = c_sc_done  + 1;
            else if(dut.q_cnt == 3'd0) c_sc_noarm = c_sc_noarm + 1;
            else if(!dut.ch_two)       c_sc_block = c_sc_block + 1;
        end
        // CHANNEL EXCLUSIVITY. The free list must never hand out a channel that
        // still has a fetch outstanding or an unconsumed completion on it -
        // that is the whole basis of the two-deep queue's deadlock argument.
        if(dut.iss_en && (dut.infl[dut.ch_pick] || dut.pend[dut.ch_pick]))
            n_chclash = n_chclash + 1;
        // prefetch bookkeeping, shadowing the queue's own shift so a lead time
        // follows its slot down
        if(dut.iss_scout) begin
            n_pf_slot[dut.sc_sel] = n_pf_slot[dut.sc_sel] + 1;
            pf_t[dut.sc_sel] = now_t;
        end
        // ---- MODIAG-1 census ----------------------------------------------
        if(dut.state == S_PRIME && !dut.tile_rdy
           && dut.pump_ready && !dut.pump_pref && !dut.ch_any)
            c_pumpblk = c_pumpblk + 1;
        chb = 0;
        for(qk = 0; qk < NCH; qk = qk + 1)
            if(dut.infl[qk] || dut.pend[qk]) chb = chb + 1;
        c_chbusy = c_chbusy + chb;
        if(dut.state == S_PRIME && dut.blit_n == 4'd14) begin
            if(!dut.tile_live)      c_pr_unissued = c_pr_unissued + 1;
            else                    c_pr_inflight = c_pr_inflight + 1;
            if(dut.tx == 3'd1)      c_pr_t1 = c_pr_t1 + 1;
            else if(dut.tx > 3'd1)  c_pr_tn = c_pr_tn + 1;
        end
`endif
`ifndef MOB_BASE
        // ---- DRAW-ORDER INVARIANT, checked in the bench's own FIFO ----------
        // The scout pushes parked entries in list-walk order and the blitter
        // pops them; if a queue ever reordered or dropped one, the sprite that
        // wins an overlapping pixel would change. Model the FIFO independently
        // and check the link the blitter actually loads against it.
        if(abort_now) begin
            ord_h = 0; ord_t = 0;              // the line abort flushes the queue
        end else begin
            if(dut.q_pop) begin
                if(ord_h == ord_t)                     n_orderslip = n_orderslip + 1;
                else begin
                    if(ord_q[ord_h % 1024] != dut.q_link[0])
                                                       n_orderslip = n_orderslip + 1;
                    ord_h = ord_h + 1;
                end
                // ...and the lead-time shadow shifts with the slots
                for(qk = 0; qk < 8; qk = qk + 1) pf_t[qk] = pf_t[qk+1];
            end
            if(dut.q_push) begin ord_q[ord_t % 1024] = dut.s_link; ord_t = ord_t + 1; end
        end
`endif
        // a tile-row BLIT == entering S_BLIT at blit_n==0
        if(dut.state == S_BLIT && state_d != S_BLIT && dut.blit_n == 4'd0)
            n_tilerows = n_tilerows + 1;
        state_d <= dut.state;
        // PERFDIV-111: build-window split. Same gate escape_mob.v uses to
        // start a build, so b_win is exactly VID_V_ACTIVE lines.
        if(y_count >= VID_V_BPORCH-1 && y_count < VID_V_BPORCH+VID_V_ACTIVE-1) begin
            b_win = b_win + 1;
            case(dut.state)
                S_IDLE:  b_idle  = b_idle  + 1;
                S_BLIT:  b_blit  = b_blit  + 1;
                S_PRIME: b_prime = b_prime + 1;
                default: b_trav  = b_trav  + 1;
            endcase
        end else
            v_win = v_win + 1;
        case(dut.state)
            S_IDLE:  c_idle  = c_idle  + 1;
            S_BLIT:  c_blit  = c_blit  + 1;
            S_PRIME: begin
                c_prime = c_prime + 1;
                if(dut.blit_n == 4'd15)     c_pr_issue  = c_pr_issue  + 1;
                else if(dut.tx == 3'd0)     c_pr_start  = c_pr_start  + 1;
                else                        c_pr_steady = c_pr_steady + 1;
            end
            default: c_trav  = c_trav  + 1;
        endcase
`ifdef MOB_BASE
        if(dut.wr_en) n_wren = n_wren + 1;
`else
        // MOPAIR-131: two independent bank writes per cycle
        if(dut.wr_en_e) n_wren = n_wren + 1;
        if(dut.wr_en_o) n_wren = n_wren + 1;
`endif
        // tile-rows blitted entirely into the invisible 344..504 window: the
        // whole 8 pixels are clipped away, so the fetch and the 8 blit cycles
        // bought nothing. (505..511 wraps back into view, so it is NOT dead.)
        if(dut.state == S_BLIT && dut.blit_n == 4'd0
           && dut.blit_x >= 9'd344 && dut.blit_x <= 9'd504)
            n_deadtile = n_deadtile + 1;
        if(dut.state == S_BLIT) n_blitpx = n_blitpx + 1;
        // An entry visit == a rising edge of "word 0 of some entry is being
        // addressed". Every walk order reads w0 exactly once per entry, so this
        // stays valid across FSM revisions (the old FSM addresses 0,1,2,3; the
        // pipelined one addresses 0,3 then 1,2).
        if(mo_vaddr[1:0] == 2'd0 && mo_vaddr_d[1:0] != 2'd0) begin
            n_entries = n_entries + 1;
            line_entries = line_entries + 1;
        end
        mo_vaddr_d <= {8'd0, mo_vaddr[1:0]};
        // end of scanline: did the build for the NEXT line finish?
        if(x_count == VID_H_TOTAL-1
           && y_count >= VID_V_BPORCH-1 && y_count < VID_V_BPORCH+VID_V_ACTIVE-1) begin
            n_lines = n_lines + 1;
            if(dut.state == S_IDLE) n_complete = n_complete + 1;
            else                    n_aborted  = n_aborted  + 1;
            if(dut.fetch_budget == 0) n_budget_out = n_budget_out + 1;
            if(line_entries > max_entries) max_entries = line_entries;
            line_entries = 0;
        end
    end
    // ---------------- sprite LOAD ORDER dump
    // At S_WAIT the blitter has just driven w2's address of the sprite it is
    // loading, so mo_vaddr[11:2] IS that sprite's link - true of every revision
    // of this engine, which is what makes the dump comparable across them.
    // One line per sprite load: "<ly> <link>", in load order, per built line.
    integer gfd; integer gclk; reg [1023:0] gtracepath;
    initial begin gfd = 0; gclk = 0; end
    reg [3:0] ostate_d = 0;
    always @(posedge clk) begin
        if(measuring && ofd && dut.state == 4'd10 && ostate_d != 4'd10)
            $fwrite(ofd, "%0d %0d\n", dut.ly, dut.mo_vaddr[11:2]);
        ostate_d <= dut.state;
    end

    reg [3:0] req_cnt_d = 4'd0;
    always @(posedge clk) begin
        if(measuring)
            for(k = 0; k < NCH; k = k + 1)
                if(gfx_req[k] != req_cnt_d[k]) begin
                    n_reqs = n_reqs + 1;
                    // SDRAM-ARCH: +gtrace=<path> writes the real MO graphics
                    // fetch address stream - "<pixel_clk> <channel> <byte_addr>"
                    // - one line per ISSUED request, from real sprite data in
                    // sim/work/game_mo.hex against real image_bytes.hex. This
                    // is the only realistic MO address sequence available, and
                    // sdram_simple sees exactly this sequence on hardware.
                    if(gfd) $fwrite(gfd, "%0d %0d %06h\n",
                                    gclk, k, gfx_addr[k*24 +: 24]);
                end
        req_cnt_d <= gfx_req;
        if(measuring) gclk = gclk + 1;
    end

    // ---------------- fetch-pairing check (MO-ARTIFACT-RESEARCH.md root cause B)
    // The gfx handshake is edge-based, so a completion that lands across a line
    // abort can pair every later tile with the previous tile's data ("right art,
    // wrong place"). Verify directly: the word the engine latches must be the
    // word at the address the engine's own code_row/tx say it wanted.
    wire [23:0] exp_addr = 24'h120000
                         + { (dut.code_row + {12'b0, dut.tx}), 5'd0 }
                         + { dut.row_in_tile, 2'd0 };
    wire [31:0] exp_data = {gfx[exp_addr], gfx[exp_addr+1],
                            gfx[exp_addr+2], gfx[exp_addr+3]};
    // MOCHAN-4: STALE-PEND check. The blitter consumes tile tx from channel
    // (pf_ch+tx)&3 purely on that channel's pend bit, so a completion left
    // unconsumed by a PREVIOUS sprite would be silently blitted as this
    // sprite's tile. The invariant that forbids it: when a sprite is loaded,
    // no channel holds an unconsumed completion except the one the scout
    // prefetched tile 0 onto. Checked directly rather than argued.
    // MODEPTH-1: the allowance widens to the queued prefetches. A landed
    // completion belonging to a sprite still sitting in the park queue is
    // exactly what prefetch depth buys, so it is legal; ANY OTHER unconsumed
    // completion is still a stale pend and would be blitted as this sprite's
    // tile. The check stays strict, it just knows about the queue now.
    integer n_stalepend;
    reg [3:0] pf_hit_mask;
    integer n_pairslip;
    initial begin n_pairslip = 0; n_stalepend = 0; end
    always @(posedge clk) if(measuring && dut.state == 4'd9) begin   // S_FETCH
        pf_hit_mask = dut.pf_hit ? (4'b0001 << dut.pf_ch) : 4'b0000;
`ifndef MOB_BASE
        for(qk = 0; qk < 8; qk = qk + 1)
            if(dut.q_cnt > qk && qk < dut.QDEPTH && dut.q_pf[qk] && !dut.q_got[qk])
                pf_hit_mask = pf_hit_mask | (4'b0001 << dut.q_ch[qk]);
`endif
        if((dut.pend & ~pf_hit_mask) != 4'd0) n_stalepend = n_stalepend + 1;
    end
    always @(posedge clk) if(measuring) begin
        // Checked at the point of USE rather than at the channel mux: when the
        // first pixel of tile tx is about to be blitted, the row the engine
        // latched must be the row at the address its own code_row/tx name.
        // Deliberately phrased without naming a channel - MOCOV-1 made the
        // tile->channel map pf_ch ^ tx[0] instead of tx[0], and this bench has
        // to keep scoring the pre-MOCOV engine too.
        if(dut.state == S_BLIT && dut.blit_n == 4'd0) begin
            if(dut.rowdata !== exp_data) n_pairslip = n_pairslip + 1;
        end
    end

    // ---------------- ghost detector
    // The line buffers are never cleared; a pixel is hidden only by its
    // {frame-parity, ly} tag, and one parity bit cannot mask a 2-frame-old
    // write (MO-ARTIFACT-RESEARCH.md root cause C). That is a real defect but
    // it is NOT a fetch-path defect, and it shows up in the golden compare as
    // "wrong"/"spurious" pixels. Separate it out here so a fetch change can be
    // judged on its own: shadow every wr_en of the build in progress, hand the
    // shadow over when the buffer flips, and flag any displayed pixel that this
    // frame's build did not actually write.
    reg [7:0] sh_pen  [0:511];      // being built now
    reg       sh_val  [0:511];
    reg [7:0] dsh_pen [0:511];      // being displayed now
    reg       dsh_val [0:511];
    integer si;
    integer n_ghost, n_mismatch;
    initial begin
        n_ghost = 0; n_mismatch = 0;
        for(si = 0; si < 512; si = si + 1) begin
            sh_val[si] = 0; dsh_val[si] = 0; sh_pen[si] = 0; dsh_pen[si] = 0;
        end
    end
    always @(posedge clk) begin
        // Record FIRST, then swap. wr_en is registered, so the last blit cycle
        // of a line lands its write during x_count==0 - after the abort has
        // flipped build_sel but into the buffer that was being built, which is
        // correct - and it belongs to the line that just finished.
`ifdef MOB_BASE
        if(dut.wr_en) begin
            sh_pen[dut.wr_x] = dut.wr_data[7:0];
            sh_val[dut.wr_x] = 1'b1;
        end
`else
        // MOPAIR-131: shadow both bank writes; address reconstitutes as
        // {bank addr, parity}, pen as {color (wr_hi low nibble), pix}.
        if(dut.wr_en_e) begin
            sh_pen[{dut.wr_xe, 1'b0}] = {dut.wr_hi[3:0], dut.wr_pen_e};
            sh_val[{dut.wr_xe, 1'b0}] = 1'b1;
        end
        if(dut.wr_en_o) begin
            sh_pen[{dut.wr_xo, 1'b1}] = {dut.wr_hi[3:0], dut.wr_pen_o};
            sh_val[{dut.wr_xo, 1'b1}] = 1'b1;
        end
`endif
        if(x_count == 10'd0 && y_count >= VID_V_BPORCH-1
           && y_count < VID_V_BPORCH+VID_V_ACTIVE-1) begin
            for(si = 0; si < 512; si = si + 1) begin
                dsh_val[si] = sh_val[si]; dsh_pen[si] = sh_pen[si];
                sh_val[si]  = 0;
            end
        end
    end

    // ---------------- frame dump
    integer fd;
    // MOCOV: +out=<path> so a sweep can run its cells in PARALLEL - they used
    // to all write sim/build/mob_perf_pixels.txt and clobber each other.
    reg [1023:0] outpath;
    initial begin
        if(!$value$plusargs("out=%s", outpath))
            outpath = "sim/build/mob_perf_pixels.txt";
        fd = $fopen(outpath, "w");
        // +ord=<path> writes the per-line sprite LOAD ORDER. Both the depth-1
        // and the depth-2 engine can emit it (it reads only mo_vaddr and ly at
        // S_WAIT), which is what lets sim/tools/mob_order_check.py prove the
        // deeper queue did not reorder anything - see that file.
        ofd = 0;
        if($value$plusargs("ord=%s", ordpath)) ofd = $fopen(ordpath, "w");
        gfd = 0;
        if($value$plusargs("gtrace=%s", gtracepath)) gfd = $fopen(gtracepath, "w");
        @(posedge rstn);
        repeat (2 * VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        @(negedge clk);
        measuring = 1; dumping = 1;
        repeat (VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        @(negedge clk);
        measuring = 0; dumping = 0;
        $fclose(fd);
        if(ofd) $fclose(ofd);
        if(gfd) $fclose(gfd);
        $display("PERF pixels=%0d gfx_reqs=%0d wren=%0d entries=%0d max_entries_line=%0d",
                 px_seen, n_reqs, n_wren, n_entries, max_entries);
        $display("PERF lines=%0d complete=%0d aborted=%0d budget_exhausted=%0d",
                 n_lines, n_complete, n_aborted, n_budget_out);
        $display("PERF pairing_slips=%0d stale_pend=%0d dead_tiles=%0d (%0d wasted blit cycles of %0d)",
                 n_pairslip, n_stalepend, n_deadtile, n_deadtile*8, n_blitpx);
        $display("PERF concurrency max=%0d hist0=%0d hist1=%0d hist2=%0d hist3=%0d hist4=%0d",
                 conc_max, conc_hist[0], conc_hist[1], conc_hist[2],
                 conc_hist[3], conc_hist[4]);
        $display("PERF ghosts=%0d pen_mismatch=%0d  (stale-tag pixels this frame's build never wrote)",
                 n_ghost, n_mismatch);
        $display("PERF sprites=%0d tilerows=%0d tiles_per_sprite=%0d.%02d prime_per_sprite=%0d.%02d",
                 n_sprites, n_tilerows,
                 n_sprites ? n_tilerows/n_sprites : 0,
                 n_sprites ? (100*n_tilerows/n_sprites)%100 : 0,
                 n_sprites ? c_prime/n_sprites : 0,
                 n_sprites ? (100*c_prime/n_sprites)%100 : 0);
        $display("PERF startup_diag pf_hits=%0d/%0d sc_blocked=%0d sc_nohit=%0d sc_alreadydone=%0d mean_lead=%0d.%02d",
                 n_pfhit, n_sprites, c_sc_block, c_sc_noarm, c_sc_done,
                 n_leadn ? n_leadsum/n_leadn : 0,
                 n_leadn ? (100*n_leadsum/n_leadn)%100 : 0);
`ifndef MOB_BASE
        $display("PERF depth QDEPTH=%0d qdepth=%0d/%0d/%0d/%0d/%0d/%0d pf_by_slot=%0d/%0d/%0d/%0d/%0d",
                 dut.QDEPTH, c_qd[0], c_qd[1], c_qd[2], c_qd[3], c_qd[4], c_qd[5],
                 n_pf_slot[0], n_pf_slot[1], n_pf_slot[2], n_pf_slot[3], n_pf_slot[4]);
        $display("PERF scout walk=%0d queue_full=%0d port_yield=%0d chan_clash=%0d order_slips=%0d",
                 c_sc_walk, c_sc_room, c_yield, n_chclash, n_orderslip);
        $display("PERF primewhy unissued=%0d inflight=%0d tx1=%0d txN=%0d pump_blocked=%0d chan_occupancy=%0d.%02d (of prime %0d)",
                 c_pr_unissued, c_pr_inflight, c_pr_t1, c_pr_tn, c_pumpblk,
                 c_chbusy/(VID_V_TOTAL*VID_H_TOTAL),                 // PERFDIV-111: was 240*456
                 (100*c_chbusy/(VID_V_TOTAL*VID_H_TOTAL))%100, c_prime);
`endif
        $display("PERF prime_split issue=%0d startup=%0d steady=%0d (startup is %0d%% of prime)",
                 c_pr_issue, c_pr_start, c_pr_steady,
                 c_prime ? (100*c_pr_start)/c_prime : 0);
        // PERFDIV-111: divide by the ACCUMULATION window (VID_V_TOTAL lines),
        // not by VID_V_ACTIVE. See the instrumentation header above.
        $display("PERF cycles idle=%0d traverse=%0d prime=%0d blit=%0d (per line of %0d: %0d.%02d/%0d.%02d/%0d.%02d/%0d.%02d)",
                 c_idle, c_trav, c_prime, c_blit, VID_V_TOTAL,
                 c_idle /VID_V_TOTAL, (100*c_idle /VID_V_TOTAL)%100,
                 c_trav /VID_V_TOTAL, (100*c_trav /VID_V_TOTAL)%100,
                 c_prime/VID_V_TOTAL, (100*c_prime/VID_V_TOTAL)%100,
                 c_blit /VID_V_TOTAL, (100*c_blit /VID_V_TOTAL)%100);
        // PERFDIV-111 self-check: the four phases partition every measured
        // clock, so they MUST sum to exactly the measurement window. If this
        // ever prints MISMATCH, either a divisor drifted again or a counter
        // stopped being gated on `measuring` alone - do not trust any per-line
        // figure from that run.
        $display("PERF cycles_build idle=%0d traverse=%0d prime=%0d blit=%0d (per build line of %0d: %0d.%02d/%0d.%02d/%0d.%02d/%0d.%02d)",
                 b_idle, b_trav, b_prime, b_blit, VID_V_ACTIVE,
                 b_idle /VID_V_ACTIVE, (100*b_idle /VID_V_ACTIVE)%100,
                 b_trav /VID_V_ACTIVE, (100*b_trav /VID_V_ACTIVE)%100,
                 b_prime/VID_V_ACTIVE, (100*b_prime/VID_V_ACTIVE)%100,
                 b_blit /VID_V_ACTIVE, (100*b_blit /VID_V_ACTIVE)%100);
        // How much engine work lands outside the build window. If these are
        // nonzero (they are), the "phases only happen on build lines" model
        // is false and total/VID_V_ACTIVE is not a valid per-line figure.
        $display("PERF cycles_vblank idle=%0d traverse=%0d prime=%0d blit=%0d (over %0d vblank lines)",
                 c_idle-b_idle, c_trav-b_trav, c_prime-b_prime, c_blit-b_blit,
                 v_win/VID_H_TOTAL);
        if(c_idle + c_trav + c_prime + c_blit === VID_V_TOTAL*VID_H_TOTAL
           && b_win === VID_V_ACTIVE*VID_H_TOTAL)
            $display("PERF cycles_check OK frame_sum=%0d == %0d, build_win=%0d == %0d (both per-line divisors are sound)",
                     c_idle+c_trav+c_prime+c_blit, VID_V_TOTAL*VID_H_TOTAL,
                     b_win, VID_V_ACTIVE*VID_H_TOTAL);
        else
            $display("PERF cycles_check MISMATCH frame_sum=%0d (want %0d) build_win=%0d (want %0d) -- per-line figures from this run are NOT trustworthy",
                     c_idle+c_trav+c_prime+c_blit, VID_V_TOTAL*VID_H_TOTAL,
                     b_win, VID_V_ACTIVE*VID_H_TOTAL);
        $finish;
    end
    always @(posedge clk) begin
        if(dumping
           && x_count >= VID_H_BPORCH+1 && x_count < VID_H_BPORCH+VID_H_ACTIVE+1
           && y_count >= VID_V_BPORCH && y_count < VID_V_BPORCH+VID_V_ACTIVE) begin
            // disp read is registered: pen for visible_x N is valid one cycle later
            if(disp_valid) begin
                $fwrite(fd, "%0d %0d %h\n", visible_x - 10'd1, visible_y, disp_pen);
                px_seen = px_seen + 1;
                if(!dsh_val[visible_x - 10'd1])          n_ghost    = n_ghost + 1;
                else if(dsh_pen[visible_x - 10'd1] != disp_pen)
                                                         n_mismatch = n_mismatch + 1;
            end
        end
    end
endmodule
