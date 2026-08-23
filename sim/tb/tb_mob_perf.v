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
    // holds mo_owner for ~10 clocks at 85.909MHz = 116ns, against a 139.68ns
    // pixel clock, so real occupancy is well under ONE pixel clock.
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
        // fixture guard: docs/LESSONS.md - $readmemh failure is not an error,
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
    // Everything below is measured over ONE frame (the measured window), so the
    // numbers are directly comparable to the 456 cycles x 240 lines a frame has.
    localparam S_IDLE = 4'd0, S_BLIT = 4'd11, S_PRIME = 4'd13;

    integer c_idle, c_trav, c_prime, c_blit;     // cycles by phase, this frame
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
    // MOCHAN-4 diagnostics for the STARTUP term (which is a pure latency and
    // does NOT divide by channel count, unlike the steady-state term):
    //   n_pfhit    - sprites loaded with tile 0 already in flight
    //   c_sc_block - cycles the scout wanted to prefetch but its rotation slot
    //                was still busy
    //   c_sc_noarm - cycles the blitter was idle-in-prime with no parked hit to
    //                prefetch at all (the scout had not walked far enough)
    integer n_pfhit, c_sc_block, c_sc_noarm, c_sc_done, n_leadsum, n_leadn;
    integer pf_issue_t, now_t;
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
        n_lines=0; n_complete=0; n_aborted=0;
        n_ymatch=0; n_wren=0; n_wren_off=0; n_reqs=0; n_budget_out=0;
        px_seen=0; line_entries=0; max_entries=0; n_entries=0;
        n_deadtile=0; n_blitpx=0; n_sprites=0; n_tilerows=0;
        c_pr_issue=0; c_pr_start=0; c_pr_steady=0;
        n_pfhit=0; c_sc_block=0; c_sc_noarm=0; c_sc_done=0; n_leadsum=0; n_leadn=0;
        pf_issue_t=0; now_t=0;
    end

    // MOCHAN-4: the pump issues in parallel with S_PRIME/S_BLIT, so the old
    // blit_n==15 "dedicated issue cycle" no longer exists and the issue bucket
    // reads 0 on this engine. startup/steady keep their meaning exactly.
    always @(posedge clk) if(measuring) begin
        // a sprite LOAD == entering S_E0 (the blitter taking a parked hit)
        now_t = now_t + 1;
        if(dut.state == 4'd4 && state_d != 4'd4) begin
            n_sprites = n_sprites + 1;
            if(dut.sc_pf_valid) begin
                n_pfhit = n_pfhit + 1;
                // LEAD TIME: cycles between the prefetch going out and the
                // blitter adopting it. This must reach GFX_LAT for the
                // per-sprite startup wait to be fully hidden.
                n_leadsum = n_leadsum + (now_t - pf_issue_t);
                n_leadn   = n_leadn + 1;
            end
        end
        if(dut.iss_en && !dut.pump_want) pf_issue_t = now_t;
        // Split the scout's idle window three ways - which one dominates
        // decides whether MORE CHANNELS or a DEEPER prefetch queue is the
        // next lever.
        if(dut.pump_live && !dut.pump_ready) begin
            if(dut.sc_pf_valid)            c_sc_done  = c_sc_done  + 1;
            else if(!dut.hit_pending || !dut.pf_armed)
                                           c_sc_noarm = c_sc_noarm + 1;
            else if(dut.busy_iss)          c_sc_block = c_sc_block + 1;
        end
        // a tile-row BLIT == entering S_BLIT at blit_n==0
        if(dut.state == S_BLIT && state_d != S_BLIT && dut.blit_n == 4'd0)
            n_tilerows = n_tilerows + 1;
        state_d <= dut.state;
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
        if(dut.wr_en) n_wren = n_wren + 1;
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
    reg [3:0] req_cnt_d = 4'd0;
    always @(posedge clk) begin
        if(measuring)
            for(k = 0; k < NCH; k = k + 1)
                if(gfx_req[k] != req_cnt_d[k]) n_reqs = n_reqs + 1;
        req_cnt_d <= gfx_req;
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
    integer n_stalepend;
    reg [3:0] pf_hit_mask;
    integer n_pairslip;
    initial begin n_pairslip = 0; n_stalepend = 0; end
    always @(posedge clk) if(measuring && dut.state == 4'd9) begin   // S_FETCH
        pf_hit_mask = dut.pf_hit ? (4'b0001 << dut.pf_ch) : 4'b0000;
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
        if(dut.wr_en) begin
            sh_pen[dut.wr_x] = dut.wr_data[7:0];
            sh_val[dut.wr_x] = 1'b1;
        end
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
        @(posedge rstn);
        repeat (2 * VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        @(negedge clk);
        measuring = 1; dumping = 1;
        repeat (VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        @(negedge clk);
        measuring = 0; dumping = 0;
        $fclose(fd);
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
        $display("PERF prime_split issue=%0d startup=%0d steady=%0d (startup is %0d%% of prime)",
                 c_pr_issue, c_pr_start, c_pr_steady,
                 c_prime ? (100*c_pr_start)/c_prime : 0);
        $display("PERF cycles idle=%0d traverse=%0d prime=%0d blit=%0d (per line: %0d/%0d/%0d/%0d)",
                 c_idle, c_trav, c_prime, c_blit,
                 c_idle/240, c_trav/240, c_prime/240, c_blit/240);
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
