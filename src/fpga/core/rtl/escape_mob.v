//
// Escape motion-object line engine (atarimo family, eprom config).
// During each scanline, builds the NEXT line into a line buffer:
//   SLIP[band] -> linked list of 4-word entries (link*4 layout) -> per-tile
//   chunky gfx fetches via the shared video SDRAM channel -> first-write-wins
//   pixels (equivalent to MAME's reverse render order).
// Entry: w0=link[9:0]; w1=code[14:0]; w2=color[3:0]|prio[6:4]|x[15:7];
//        w3=y[15:7]|width[6:4]|height[2:0]|hflip[3]
// Tiles walk row-major: code + ty*width + tx. Palette base 0x100.
// MOPRI-1: prio (w2[6:4]) is now captured. MPR1:MPR0 ride with every written
// pixel and leave via disp_prio for the priority comparator in escape_prio.v;
// MPR2 (the "special rendering" flag) suppresses the write instead.
//
`default_nettype none

module escape_mob (
    input  wire        clk,             // pixel clock
    input  wire        reset_n,

    input  wire [9:0]  x_count,         // raster position
    input  wire [9:0]  y_count,
    input  wire [9:0]  vbporch,         // VID_V_BPORCH
    input  wire [9:0]  vactive,         // VID_V_ACTIVE
    input  wire [9:0]  hbporch,         // VID_H_BPORCH
    input  wire [8:0]  xscroll,
    input  wire [8:0]  yscroll,

    // MO RAM video port (word addressed, registered read)
    output reg  [11:0] mo_vaddr,
    input  wire [15:0] mo_vdata,
    // SLIP via cfg RAM video port (words 0x40-0x7F)
    output reg  [6:0]  cfg_vaddr,
    input  wire [15:0] cfg_vdata,

    // gfx fetch channels (LANE3o: A/B ping-pong - two fetches in flight
    // across the CDC so per-tile cost is blit-bound, not round-trip-bound)
    output reg         gfx_reqA,
    output reg         gfx_reqB,
    output reg  [23:0] gfx_addrA,
    output reg  [23:0] gfx_addrB,
    input  wire        gfx_doneA,       // toggles
    input  wire        gfx_doneB,
    input  wire [31:0] gfx_dataA,
    input  wire [31:0] gfx_dataB,

    // display-side pixel query (current line)
    input  wire [8:0]  disp_x,
    output wire [7:0]  disp_pen,        // {color[3:0], pix[3:0]}
    output wire [1:0]  disp_prio,       // MPR1:MPR0 of the sprite that owns this pixel
    output wire        disp_valid
);

    // LANE3n: TAGGED double line buffers - no clear pass at all. The old
    // S_CLEAR wiped 512 entries per line but a line is only 456 clocks, so
    // the build NEVER finished during active video (sim: 3 SLIP walks per
    // FRAME instead of 240) - the MO layer has been structurally dead since
    // v14. Each written pixel now carries the ly it was built for; the
    // display side shows a pixel only when its tag matches the line that
    // buffer was built for - stale pixels are invisible by construction.
    // LANE4q: tags carry FRAME PARITY. ly repeats every frame, so a
    // ly-only tag let LAST frame's pixels stay 'valid' wherever this
    // frame wrote nothing - moving sprites shed trailing ghost fringes
    // and floor debris (the real MOHLB self-clears on readout instead).
    // MOPRI-1: each entry now also carries the sprite's MO priority so the
    // compositor can run the real PF/M comparator (see docs/mo_priority.md).
    // Only MPR1:MPR0 travel: MPR2 ("special", mopriority&4) is resolved at
    // WRITE time by not writing the pixel at all, which is exactly what the
    // reference does ("upper bit of MO priority signals special rendering and
    // doesn't draw anything" -> `continue`). That keeps the entry at 20 bits,
    // which is a native M10K geometry (512x20), so the widening from 18 bits
    // costs ZERO extra blocks - important, the 308-M10K ceiling is spent.
    reg [19:0] buf0 [0:511];            // {fpar, tag[8:0], prio[1:0], color[3:0], pix[3:0]}
    reg [19:0] buf1 [0:511];
    reg        fpar = 1'b0;
    reg        built_fp0 = 1'b0, built_fp1 = 1'b0;
    always @(posedge clk)
        if(y_count == 10'd0 && x_count == 10'd0) fpar <= ~fpar;
    reg        build_sel;               // which buffer is being built
    reg [8:0]  built_ly0, built_ly1;    // the ly each buffer was last built for
    reg [19:0] disp_q0, disp_q1;
    always @(posedge clk) begin
        disp_q0 <= buf0[disp_x];
        disp_q1 <= buf1[disp_x];
    end
    assign disp_pen   = build_sel ? disp_q0[7:0] : disp_q1[7:0];
    assign disp_prio  = build_sel ? disp_q0[9:8] : disp_q1[9:8];
    assign disp_valid = build_sel ? (disp_q0[19:10] == {built_fp0, built_ly0})
                                  : (disp_q1[19:10] == {built_fp1, built_ly1});

    // write port
    reg  [8:0]  wr_x;
    reg  [19:0] wr_data;
    reg         wr_en;
    always @(posedge clk) begin
        if(wr_en) begin
            if(build_sel) buf1[wr_x] <= wr_data; else buf0[wr_x] <= wr_data;
        end
    end

    // engine state
    localparam S_IDLE   = 4'd0;
    localparam S_CLEAR  = 4'd1;
    localparam S_SLIP0  = 4'd2;
    localparam S_SLIP1  = 4'd3;
    localparam S_E0     = 4'd4;
    localparam S_E1     = 4'd5;
    localparam S_E2     = 4'd6;
    localparam S_E3     = 4'd7;
    localparam S_MATCH  = 4'd8;
    localparam S_FETCH  = 4'd9;
    localparam S_WAIT   = 4'd10;
    localparam S_BLIT   = 4'd11;
    localparam S_NEXT   = 4'd12;
    localparam S_PRIME  = 4'd13;

    // MOFETCH-3: the LINK SCOUT - a second, independent state machine that owns
    // the MO RAM video port and walks the SLIP list continuously, including all
    // the way through S_PRIME/S_BLIT when the port would otherwise sit idle.
    // This is the structure the real board has: Escape's PAL16L8 at 70J drives
    // a dedicated /LINK memory slot (SP-332 sheet 7), so list walking never
    // competes with the pixel pipeline. US4894774 calls it the lookahead cycle.
    //
    // The scout only ever touches w0 (link) and w3 (y/height) - the two words
    // that decide an entry's fate. When it finds an entry that intersects the
    // line it parks JUST the link and the raw w3 and stops, so it is never more
    // than one entry ahead and never decodes a sprite the blitter is still
    // drawing. The blitter then reads w2/w1 for the parked entry itself, which
    // keeps every per-sprite field (colour, x, prio, code) decoded at
    // sprite-load time, on the blitter's side, exactly as before.
    localparam SC_IDLE  = 3'd0;
    localparam SC_E0    = 3'd1;
    localparam SC_E1    = 3'd2;
    localparam SC_E2    = 3'd3;
    localparam SC_E3    = 3'd4;
    localparam SC_HOLD  = 3'd5;         // a hit is parked, waiting to be taken
    localparam SC_DONE  = 3'd6;         // list exhausted for this line

    reg [2:0]  sstate;
    reg        hit_pending;             // a matching entry is parked
    reg [9:0]  hit_link;                // ...this one
    reg [15:0] h_w3;                    // ...with this geometry word
    reg        sc_last;                 // the parked hit is the list's last entry
    reg        sc_restart;              // blitter -> scout: port is yours again

    reg [3:0]  state;
    reg [8:0]  ly;                      // playfield-space line being built
    reg [9:0]  first_link, link;
    reg [9:0]  nlink;                   // MOFETCH-1: this entry's link, read early
    reg [6:0]  ent_count;
    reg [15:0] w0, w1, w2, w3;
    reg [8:0]  spr_y;
    reg [3:0]  spr_color;
    reg [2:0]  spr_prio;                // w2[6:4] - MPR2:MPR0
    reg [8:0]  spr_x;
    reg [2:0]  width_t, height_t;
    reg        hflip;
    reg [2:0]  tx, tx_f;
    reg [14:0] code_row;                // code + ty*width
    reg [2:0]  row_in_tile;
    reg        gfx_doneA_last, gfx_doneB_last;
    reg        pendA, pendB;            // completion seen, not yet consumed
    // MOFETCH-2: per-channel in-flight tracking. v87 resynced the done toggles
    // on a line abort, which discards a completion that has ALREADY arrived -
    // but a request issued before the abort and served after it still toggles
    // done, sets pend, and gets consumed by the new line's first tile with the
    // previous request's data. From then on every tile on that channel is
    // paired with the wrong tile-row: real sprite art at the wrong X.
    reg        inflA, inflB;            // issued, completion not yet seen
    reg        discA, discB;            // swallow one completion (aborted line)
    reg [31:0] rowdata;
    reg [3:0]  blit_n;
    reg [8:0]  blit_x;
    // MOFETCH-5: 7 bits. The 6-bit ceiling of 62 was never the binding
    // constraint while traversal ate half the line (LANE4o tuned a limiter
    // that time ran out before), but with MOFETCH-1/3/4 the engine now
    // reaches it on 20 lines a frame and truncates the walk there. The
    // golden model saturates at 40 tile-rows a line for this scene, so
    // raising it costs no pixels and removes a limiter that is no longer
    // measuring anything real. The line abort - not the budget - is what
    // bounds a build; never-wedge is unaffected.
    reg [6:0]  fetch_budget;
    reg [9:0]  cur_line_latch;

    // v80: MAME atarimo ground truth - the entry Y field is NEGATED and
    // offset by the sprite height: top = -yfield - (height+1)*8. So
    // ydiff = ly - top = ly + yfield + (height+1)*8. The raw-field compare
    // matched almost nothing (v79 probe: 97 fetches, 12 pixels/frame).
    wire [8:0] ydiff = (ly + spr_y + {1'b0, height_t, 3'b000} + 9'd8) & 9'h1FF;
    wire       ymatch = ydiff < {height_t, 3'b000} + 9'd8;   // (height+1)*8 lines

    // MOFETCH-1: the same test one cycle EARLIER, straight off the MO RAM bus
    // rather than off spr_y/height_t. The walk needs the accept/reject verdict
    // in the cycle w3 lands so a non-matching entry can be dropped without ever
    // reading w1/w2 - see the S_E2/S_E3 loop below. Identical arithmetic, so
    // ymatch_e at S_E3 == ymatch at S_WAIT for the same entry, by construction.
    wire [8:0] e_y     = mo_vdata[15:7];
    wire [2:0] e_h     = mo_vdata[2:0];
    wire [8:0] ydiff_e = (ly + e_y + {1'b0, e_h, 3'b000} + 9'd8) & 9'h1FF;
    wire       ymatch_e = ydiff_e < {e_h, 3'b000} + 9'd8;

    // MOFETCH-2: completion edges as wires - the abort block below needs to
    // know whether a completion is landing in the very cycle it aborts.
    wire doneA_edge = (gfx_doneA != gfx_doneA_last);
    wire doneB_edge = (gfx_doneB != gfx_doneB_last);

    // MOFETCH-4: OFF-SCREEN REJECTION.
    // S_BLIT already throws away any pixel at column >= 344, and 990 tile-rows
    // per frame (18% of all blit cycles, 17% of all gfx fetches) were being
    // fetched and blitted entirely into that dead window. Columns 505..511 are
    // NOT dead - blit_x wraps mod 512 and those tiles come back into view - so
    // the test is "starts at 344 or later AND does not wrap".
    wire [8:0] blit_x_new = (spr_x + (hflip ? {(width_t - tx), 3'b000}
                                            : {tx, 3'b000})
                             - {1'b0, xscroll}) & 9'h1FF;
    wire       tile_dead  = (blit_x_new >= 9'd344) && (blit_x_new <= 9'd504);
    // ...and the whole sprite, so an object scrolled off the edge costs neither
    // fetches nor blit cycles. Leftmost column is tile 0 with hflip either way.
    wire [8:0] spr_left  = (spr_x - {1'b0, xscroll}) & 9'h1FF;
    wire [9:0] spr_right = {1'b0, spr_left} + {3'b0, width_t, 3'b000} + 10'd7;
    wire       spr_dead  = (spr_left >= 9'd344) && (spr_right <= 10'd511);

    // chunky pixel extract with hflip (declared before use for iverilog)
    wire [2:0] pn = hflip ? (3'd7 - blit_n[2:0]) : blit_n[2:0];
    reg  [3:0] pix_val;
    always @(*) begin
        case(pn)
            3'd0: pix_val = rowdata[31:28]; 3'd1: pix_val = rowdata[27:24];
            3'd2: pix_val = rowdata[23:20]; 3'd3: pix_val = rowdata[19:16];
            3'd4: pix_val = rowdata[15:12]; 3'd5: pix_val = rowdata[11:8];
            3'd6: pix_val = rowdata[7:4];   default: pix_val = rowdata[3:0];
        endcase
    end

    always @(posedge clk) begin
        if(!reset_n) begin
            state <= S_IDLE;
            sstate <= SC_IDLE; hit_pending <= 0; sc_restart <= 0;
            gfx_reqA <= 0; gfx_reqB <= 0;
            pendA <= 0; pendB <= 0;
            inflA <= 0; inflB <= 0; discA <= 0; discB <= 0;
            wr_en <= 0;
            build_sel <= 0;
            built_ly0 <= 9'h1FF; built_ly1 <= 9'h1FF;
            gfx_doneA_last <= 0; gfx_doneB_last <= 0;
        end else begin
            wr_en <= 0;
            sc_restart <= 1'b0;
            gfx_doneA_last <= gfx_doneA;
            gfx_doneB_last <= gfx_doneB;
            // completions can land while blitting: LATCH them (an edge is
            // visible for one cycle only - depth-2 lost edges without this)
            // MOFETCH-2: a completion always retires the in-flight marker, but
            // it only becomes a usable tile-row if it belongs to THIS line.
            if(doneA_edge) begin
                inflA <= 1'b0;
                if(discA) discA <= 1'b0; else pendA <= 1'b1;
            end
            if(doneB_edge) begin
                inflB <= 1'b0;
                if(discB) discB <= 1'b0; else pendB <= 1'b1;
            end

            // v85: the line trigger fires from ANY state - a build stalled
            // by fetch starvation previously missed the restart and kept
            // blitting stale rows into the now-DISPLAYED buffer (the
            // interior garble on tall attract objects). Abort and restart.
            if(x_count == 10'd0 && y_count >= vbporch - 10'd1
               && y_count < vbporch + vactive - 10'd1) begin
                build_sel <= ~build_sel;
                ly <= (y_count - vbporch + 10'd2 + {1'b0, yscroll}) & 9'h1FF;
                // tag bookkeeping: the buffer we are about to build will hold
                // pixels for this ly (stale content mismatches by definition)
                if(build_sel) begin
                    built_ly0 <= (y_count - vbporch + 10'd2 + {1'b0, yscroll}) & 9'h1FF;
                    built_fp0 <= fpar;
                end else begin
                    built_ly1 <= (y_count - vbporch + 10'd2 + {1'b0, yscroll}) & 9'h1FF;
                    built_fp1 <= fpar;
                end
                wr_en <= 0;
                // v87: RESYNC the gfx handshakes on restart (see history)
                gfx_doneA_last <= gfx_doneA;
                gfx_doneB_last <= gfx_doneB;
                pendA <= 1'b0; pendB <= 1'b0;
                // MOFETCH-2: v87 discarded completions that had already landed;
                // this discards the one still in flight. A request outstanding
                // right now belongs to the line being abandoned, so mark its
                // completion to be swallowed rather than paired with the new
                // line's first tile. If the completion is landing in THIS very
                // cycle it is already being retired above, so no discard is due.
                discA <= inflA && !doneA_edge;
                discB <= inflB && !doneB_edge;
                sstate <= SC_IDLE;
                hit_pending <= 1'b0;
                state <= S_CLEAR;
            end else begin

            // ================= LINK SCOUT =================
            // Owns mo_vaddr except during the blitter's two sprite-load cycles
            // (S_E0 / S_WAIT), which it spends parked in SC_HOLD. Runs right
            // through S_PRIME and S_BLIT, so on a busy line the entire list
            // walk is hidden behind the pixels.
            case(sstate)
            SC_IDLE: begin end
            SC_DONE: begin end

            SC_E0: begin mo_vaddr <= {link, 2'd0}; sstate <= SC_E1; end
            SC_E1: begin mo_vaddr <= {link, 2'd3}; sstate <= SC_E2; end

            SC_E2: begin
                // w0 on the bus: capture the link and immediately start the
                // NEXT entry's w0 read, matched or not. That hides the MO RAM's
                // 2-cycle read latency, so the reject loop below is 2 cycles
                // per entry instead of the 8 the old in-line walk paid.
                w0    <= mo_vdata;
                nlink <= mo_vdata[9:0];
                mo_vaddr <= {mo_vdata[9:0], 2'd0};
                sstate <= SC_E3;
            end

            SC_E3: begin
                // w3 on the bus: the accept/reject verdict, one cycle earlier
                // than the registered ymatch could give it (see ymatch_e).
                h_w3 <= mo_vdata;
                if(ymatch_e && fetch_budget != 0) begin
                    // Park it. Only the link and the raw geometry word are
                    // kept - nothing the blitter is currently drawing with is
                    // touched, which is what makes running ahead safe.
                    hit_link    <= link;
                    hit_pending <= 1'b1;
                    sc_last     <= (nlink == first_link) || (ent_count == 7'd63);
                    sstate      <= SC_HOLD;
                end else if(nlink == first_link || ent_count == 7'd63
                            || fetch_budget == 0) begin
                    // the same three terminators the walk has always applied
                    sstate <= SC_DONE;
                end else begin
                    ent_count <= ent_count + 7'd1;
                    link      <= nlink;
                    mo_vaddr  <= {nlink, 2'd3};
                    sstate    <= SC_E2;
                end
            end

            SC_HOLD: begin
                // The blitter releases the port one cycle after it takes the
                // hit (it addresses w2 then w1 of the parked entry itself).
                if(sc_restart) begin
                    if(sc_last || fetch_budget == 0) sstate <= SC_DONE;
                    else begin
                        ent_count <= ent_count + 7'd1;
                        link      <= nlink;
                        sstate    <= SC_E0;
                    end
                end
            end

            default: sstate <= SC_DONE;
            endcase

            // ================= BLITTER =================
            case(state)
            S_IDLE: begin
            end

            S_CLEAR: begin
                // no clearing needed: tags invalidate stale pixels
                cfg_vaddr <= {1'b1, ly[8:3]};            // SLIP word 0x40 + band
                state <= S_SLIP0;
            end

            S_SLIP0: state <= S_SLIP1;                    // BRAM latency
            S_SLIP1: begin
                link       <= cfg_vdata[9:0];
                first_link <= cfg_vdata[9:0];
                ent_count  <= 0;
                // LANE4o: 48 starved dense crowds (whole clusters shredding
                // while lone sprites render clean) - raise toward the 6-bit
                // ceiling; the tagged line buffers still bound overruns
                fetch_budget <= 7'd126;
                sstate <= SC_E0;                         // release the scout
                state  <= S_NEXT;                        // wait for its first hit
            end

            // MOFETCH-3: SPRITE LOAD. The scout has already decided this entry
            // intersects the line and parked its link and geometry word, so all
            // that is left on the blitter's critical path is reading w2 and w1
            // - four cycles from taking the hit to S_PRIME, against the eight a
            // fully in-line walk paid per matched entry, with every rejected
            // entry between them costing the blitter nothing at all.
            S_E0: begin
                mo_vaddr <= {hit_link, 2'd2};
                spr_y    <= h_w3[15:7];
                width_t  <= h_w3[6:4];
                height_t <= h_w3[2:0];
                hflip    <= h_w3[3];
                w3       <= h_w3;
                hit_pending <= 1'b0;
                state <= S_WAIT;
            end

            // The port is handed straight back: mo_vaddr is driven here for the
            // last time this sprite, and sc_restart lets the scout resume on the
            // NEXT cycle, so the two never drive the address in the same cycle.
            // ymatch (the registered form) is valid here - spr_y/height_t were
            // loaded one cycle ago - which is what the existing benches probe.
            S_WAIT: begin
                mo_vaddr   <= {hit_link, 2'd1};
                sc_restart <= 1'b1;
                state <= S_MATCH;
            end

            S_MATCH: begin
                w2 <= mo_vdata;                           // color/x/prio
                spr_color <= mo_vdata[3:0];
                // MOPRI-1: eprom MO config, "mask for the priority" = 0x0070 in
                // word 2 (reference/eprom.cpp s_mob_config). Was parsed in the
                // comment only and discarded; now it is captured and carried.
                spr_prio  <= mo_vdata[6:4];
                spr_x     <= mo_vdata[15:7];
                state <= S_FETCH;
            end

            S_FETCH: begin
                // MOFETCH-1: w1 (code) is the LAST word read, so the tile loop
                // starts straight off the bus. The entry is already known to
                // match (decided at S_E3), so the old ymatch re-test here is
                // gone - it can no longer be false.
                w1 <= mo_vdata;
                // code for this row: code + ty*width + tx  (ty = ydiff>>3)
                code_row    <= mo_vdata[14:0] + ( (ydiff[8:3]) * ({3'b0,width_t}+4'd1) );
                row_in_tile <= ydiff[2:0];
                tx_f  <= 3'd0;                  // next tile to ISSUE
                tx    <= 3'd0;                  // next tile to LATCH/blit
                blit_n <= 4'd15;                // marker: nothing in flight
                // MOFETCH-4: spr_x is known now (S_MATCH, one cycle ago). If
                // every column this object covers would be clipped away, drop
                // it here - before any fetch is issued. Not a semantic change:
                // S_BLIT would have discarded all of its pixels anyway.
                state <= spr_dead ? S_NEXT : S_PRIME;
            end

            // LANE3o: FETCH-AHEAD. The serial issue-wait-blit loop paid the
            // full CRAM+CDC round trip (~1us) per tile-row ON TOP of the 8
            // blit cycles - a busy line ran out of time before late links
            // (Jake) were reached. Now the next tile's fetch is in flight
            // WHILE the current one blits: effective cost = max(fetch, blit).
            // LANE3o: keep BOTH channels loaded - tile parity picks the
            // channel (even tiles on A, odd on B). Issue runs up to two
            // ahead of latch; per-tile cost = max(8-cycle blit, service/2).
            S_PRIME: begin
                // MOFETCH-2: never issue on a channel that still has a request
                // outstanding. Only reachable straight after a line abort (the
                // steady-state loop refills a channel exactly when its
                // completion is consumed), and the wait is bounded by the
                // fetch service time, but issuing here would toggle req while
                // the channel is busy and lose the request outright.
                if(blit_n == 4'd15) begin
                  if(!inflA && !(width_t != 3'd0 && inflB)) begin
                    // sprite start: issue tile 0 (A) and, if any, tile 1 (B)
                    gfx_addrA <= 24'h120000
                                + { code_row, 5'd0 }
                                + { row_in_tile, 2'd0 };
                    gfx_reqA  <= ~gfx_reqA;
                    inflA     <= 1'b1;
                    if(width_t != 3'd0 && fetch_budget > 7'd1) begin
                        gfx_addrB <= 24'h120000
                                    + { (code_row + 15'd1), 5'd0 }
                                    + { row_in_tile, 2'd0 };
                        gfx_reqB  <= ~gfx_reqB;
                        inflB     <= 1'b1;
                        tx_f <= 3'd2;
                        fetch_budget <= fetch_budget - 7'd2;
                    end else begin
                        tx_f <= 3'd1;
                        fetch_budget <= fetch_budget - 7'd1;
                    end
                    blit_n <= 4'd14;
                  end
                end else if(tx[0] ? pendB : pendA) begin
                    // tile tx's data has landed on its parity channel
                    rowdata <= tx[0] ? gfx_dataB : gfx_dataA;
                    if(tx[0]) pendB <= 1'b0; else pendA <= 1'b0;
                    blit_x  <= blit_x_new;
                    // MOFETCH-4: a tile-row that lands wholly in the clipped
                    // 344..504 window costs one cycle instead of eight. Jumping
                    // straight to blit_n 7 keeps the existing end-of-tile
                    // handoff intact, and the single write it attempts is
                    // rejected by S_BLIT's own blit_x < 344 clip - so not one
                    // line-buffer write changes, only the cycles spent.
                    blit_n  <= tile_dead ? 4'd7 : 4'd0;
                    // refill the channel just freed with tile tx_f
                    if(tx_f <= width_t && tx_f != 3'd0 && fetch_budget != 7'd0) begin
                        if(tx_f[0]) begin
                            gfx_addrB <= 24'h120000
                                        + { (code_row + {12'b0, tx_f}), 5'd0 }
                                        + { row_in_tile, 2'd0 };
                            gfx_reqB  <= ~gfx_reqB;
                            inflB     <= 1'b1;
                        end else begin
                            gfx_addrA <= 24'h120000
                                        + { (code_row + {12'b0, tx_f}), 5'd0 }
                                        + { row_in_tile, 2'd0 };
                            gfx_reqA  <= ~gfx_reqA;
                            inflA     <= 1'b1;
                        end
                        fetch_budget <= fetch_budget - 7'd1;
                        tx_f <= tx_f + 3'd1;
                    end
                    state <= S_BLIT;
                end
            end

            S_BLIT: begin
                // write pixel blit_n of the row (last-wins; list order relied on)
                // MOPRI-1: spr_prio[2] (mopriority & 4) = "special rendering,
                // draws nothing" in the normal pass. The reference `continue`s
                // on it; here we simply suppress the line-buffer write. Note
                // this gates ONLY wr_en - the fetch budget, ring walk, blit
                // loop and handshakes are untouched, so timing is unchanged.
                if(pix_val != 4'd0 && !spr_prio[2] && blit_x < 9'd336+9'd0+9'd8) begin
                    wr_x    <= blit_x;
                    wr_data <= {fpar, ly, spr_prio[1:0], spr_color, pix_val};
                    wr_en   <= 1;
                end
                blit_x <= (blit_x + 9'd1) & 9'h1FF;
                if(blit_n == 4'd7) begin
                    if(tx == width_t) state <= S_NEXT;
                    else if(tx_f == tx + 3'd1 && fetch_budget == 7'd0) state <= S_NEXT;
                    else begin
                        tx     <= tx + 3'd1;
                        blit_n <= 4'd14;   // that tile's data is in flight
                        state  <= S_PRIME;
                    end
                end else begin
                    blit_n <= blit_n + 4'd1;
                end
            end

            // MOFETCH-3: the blitter no longer walks anything. It takes the
            // next entry the scout has already found, or - only if the scout
            // has run the list out - ends the line. Sitting here is the only
            // place the blitter can now be blocked by traversal, and on a busy
            // line the scout has always got there first.
            S_NEXT: begin
                if(hit_pending && fetch_budget != 0) state <= S_E0;
                // SC_IDLE is included defensively: the scout is only ever left
                // idle by reset or a line abort, both of which also drive the
                // blitter out of S_NEXT, but a stuck S_NEXT would silently cost
                // a whole scanline of MO and the test is free.
                else if(sstate == SC_DONE || sstate == SC_IDLE
                        || fetch_budget == 0) state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
            end
        end
    end

endmodule
