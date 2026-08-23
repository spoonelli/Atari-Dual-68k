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
    // M10K comes up zeroed on the device; mirror that for simulation so the
    // occupancy probe below reads a defined value on the very first line
    // instead of X. Simulation-only: kept out of synthesis so it can never
    // perturb RAM inference.
    // synthesis translate_off
    integer bi;
    initial for(bi = 0; bi < 512; bi = bi + 1) begin buf0[bi] = 20'd0; buf1[bi] = 20'd0; end
    // synthesis translate_on
    reg        fpar = 1'b0;
    reg        built_fp0 = 1'b0, built_fp1 = 1'b0;
    always @(posedge clk)
        if(y_count == 10'd0 && x_count == 10'd0) fpar <= ~fpar;
    reg        build_sel;               // which buffer is being built
    reg [8:0]  built_ly0, built_ly1;    // the ly each buffer was last built for
    reg [19:0] disp_q0, disp_q1;
    reg [8:0]  blit_x;                  // declared early: feeds the probe read
    // MOPLACE-2: the buffer being BUILT is not the one being displayed, so its
    // read port sat idle at disp_x every cycle. Point it at blit_x instead and
    // it becomes an occupancy probe for first-write-wins (see S_BLIT). Still
    // one read + one write per buffer, so this is free: no extra M10K, no
    // extra port, no extra cycle.
    wire [8:0] rd_addr0 = build_sel ? disp_x : blit_x;
    wire [8:0] rd_addr1 = build_sel ? blit_x : disp_x;
    always @(posedge clk) begin
        disp_q0 <= buf0[rd_addr0];
        disp_q1 <= buf1[rd_addr1];
    end
    // "this entry holds a real pixel written for the line this buffer was last
    // built for". S_BLIT only ever writes pix != 0 (pen 0 is transparent), so
    // requiring pix != 0 makes an all-zero entry unrepresentable as a hit -
    // which is what a powered-up (or never-written) M10K location reads.
    // Without that, an untouched entry aliases the tag {fpar=0, ly=0}.
    wire hit0 = (disp_q0[19:10] == {built_fp0, built_ly0}) && (disp_q0[3:0] != 4'd0);
    wire hit1 = (disp_q1[19:10] == {built_fp1, built_ly1}) && (disp_q1[3:0] != 4'd0);

    assign disp_pen   = build_sel ? disp_q0[7:0] : disp_q1[7:0];
    assign disp_prio  = build_sel ? disp_q0[9:8] : disp_q1[9:8];
    assign disp_valid = build_sel ? hit0 : hit1;

    // Occupancy of the build buffer at the pixel wr_x/wr_en are aiming at: the
    // probe read and the wr_x/wr_en registers both sample blit_x in the same
    // cycle, and the buffer write commits one cycle later, so this is exactly
    // "what is already at wr_x, before this write".
    wire bld_occupied = build_sel ? hit1 : hit0;

    // write port
    reg  [8:0]  wr_x;
    reg  [19:0] wr_data;
    reg         wr_en;
    always @(posedge clk) begin
        if(wr_en && !bld_occupied) begin
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
    // The scout's REJECT loop only ever touches w0 (link) and w3 (y/height) -
    // the two words that decide an entry's fate - so a rejected entry still
    // costs 2 cycles and the walk stays as cheap as MOFETCH-3 made it.
    //
    // MOCOV-1: on a HIT it now reads w1 (the tile code) as well, computes the
    // sprite's code_row, and ISSUES THE FIRST TILE-ROW FETCH ITSELF. That is
    // the whole point: the per-sprite startup latency was 54-74% of all
    // S_PRIME time (see tb_mob_perf's prime_split), because the first tile of
    // a sprite could not be asked for until the blitter had walked to the
    // sprite and read its code - and with sprites averaging 1-3 tile-rows
    // there is nothing to amortise that wait against. Issued from the scout,
    // the fetch is in flight during the whole of the PREVIOUS sprite's blit.
    //
    // The blitter still reads w2 for itself, and still decodes colour, x and
    // PRIORITY at sprite-load time in S_MATCH - so spr_prio reaches
    // escape_prio.v from exactly where it always did. Only w1, which carries
    // no priority information at all, moved to the scout. That is what makes
    // the prefetch compatible with keeping the priority decode blitter-side.
    //
    // Cost, escape_mob synthesised standalone for the 5CEBA4F23C8 (Quartus
    // 18.1, virtual pins, clk constrained at the real 139.68ns pixel period):
    //          ALMs   regs   block-mem bits   DSP   worst setup slack
    //   before  439    305       20,480        1        +129.395 ns
    //   after   493    308       20,480        1        +126.571 ns
    // M10K delta 0 - the line buffers are untouched at 2 x 512 x 20, so the
    // 308-block ceiling is not approached. DSP delta 0 confirms the code_row
    // multiply MOVED to the scout rather than being duplicated. The engine
    // uses ~13ns of a 139.68ns budget either way; the new critical path is
    // ly -> mo_vaddr (the scout's own address decode), and every output that
    // crosses to the 85.9MHz SDRAM domain (gfx_req*, gfx_addr*) is still
    // registered here, so nothing combinational was added to that crossing.
    localparam SC_IDLE  = 3'd0;
    localparam SC_E0    = 3'd1;
    localparam SC_E1    = 3'd2;
    localparam SC_E2    = 3'd3;
    localparam SC_E3    = 3'd4;
    localparam SC_HOLD  = 3'd5;         // a hit is parked, waiting to be taken
    localparam SC_DONE  = 3'd6;         // list exhausted for this line
    localparam SC_W1    = 3'd7;         // MOCOV-1: w1 addressed, in the pipe

    reg [2:0]  sstate;
    reg        hit_pending;             // a matching entry is parked
    reg [9:0]  hit_link;                // ...this one
    reg [15:0] h_w3;                    // ...with this geometry word
    reg [8:0]  h_ydiff;                 // ...and its row within the sprite
    reg        sc_last;                 // the parked hit is the list's last entry
    reg        sc_restart;              // blitter -> scout: port is yours again

    // MOCOV-1: the scout's decode of the parked sprite's FIRST tile-row.
    // pf_code_row/pf_row are computed for every parked hit (so the blitter
    // always takes code_row from here and no longer multiplies at all - the
    // multiplier MOVED, it was not duplicated). sc_pf_valid says the fetch was
    // also already issued, on channel sc_pf_ch.
    reg [14:0] pf_code_row;
    reg [2:0]  pf_row;
    reg        pf_armed;                // pf_code_row/pf_row describe the park
    reg        sc_pf_valid;             // ...and its tile 0 is in flight
    reg        sc_pf_ch;                // ...on this channel (0=A, 1=B)
    // blitter side: the channel the CURRENT sprite's tile 0 lives on, which
    // sets the parity for every later tile (tile k is on pf_ch ^ k[0]).
    reg        pf_ch;
    reg        pf_hit;                  // tile 0 was prefetched, do not re-issue

    reg [3:0]  state;
    reg [8:0]  ly;                      // playfield-space line being built
    reg [9:0]  first_link, link;
    reg [9:0]  nlink;                   // MOFETCH-1: this entry's link, read early
    reg [6:0]  ent_count;
    // MOCOV-1: w1 is gone - the blitter no longer reads the code word at all,
    // the scout does (and turns it straight into pf_code_row).
    reg [15:0] w0, w2, w3;
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

    // ---- MOCOV-1: channel selection ------------------------------------
    // Tile k of the current sprite rides channel pf_ch ^ k[0]. With pf_ch
    // always 0 this is exactly the old even-A/odd-B parity; pf_ch exists
    // because the scout issues tile 0 on whichever channel happened to be
    // free, so the parity base is no longer always A.
    wire ch_cur = pf_ch ^ tx[0];        // channel the blitter is consuming
    wire ch_iss = pf_ch ^ tx_f[0];      // channel the blitter will issue on
    wire pend_cur = ch_cur ? pendB : pendA;
    wire [31:0] data_cur = ch_cur ? gfx_dataB : gfx_dataA;
    wire busy_iss = ch_iss ? (inflB || pendB) : (inflA || pendA);

    // A channel is free when nothing is outstanding on it AND nothing has
    // landed on it that somebody still has to consume.
    wire freeA = !inflA && !pendA;
    wire freeB = !inflB && !pendB;
    // The scout may only take a channel the blitter cannot still want. The
    // blitter claims channels only for tiles it has not issued yet, so
    // "tx_f > width_t" (every tile of the sprite in progress is already in
    // flight or done) is the safe window. It opens immediately for a 1-tile
    // sprite - which is the common case, and exactly where the startup cost
    // hurt most - and during the last tile's blit for a wider one.
    // ...and never in the two cycles the hit is changing hands. S_NEXT (with a
    // hit parked) transitions to S_E0 next cycle, and S_E0 is where the
    // blitter samples sc_pf_valid; issuing in either would let the blitter
    // read "no prefetch", issue tile 0 itself, and leave the scout's request
    // in flight as an orphan that the next sprite would mis-pair with.
    wire sc_handoff = (state == S_NEXT) || (state == S_E0);
    wire sc_may_pf = hit_pending && pf_armed && !sc_pf_valid && !sc_handoff
                     && (tx_f > width_t) && (fetch_budget != 7'd0)
                     && (freeA || freeB);
    wire sc_pf_pick = !freeA;           // prefer A, take B when A is busy

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
            pf_armed <= 0; sc_pf_valid <= 0; sc_pf_ch <= 0;
            pf_hit <= 0; pf_ch <= 0;
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
                // MOPLACE-1: the buffer built during raster line Y is displayed
                // on line Y+1, i.e. at visible_y = Y - vbporch + 1. The
                // reference puts screen line v at playfield row v + yscroll
                // (core_top's own pf_y is exactly visible_y + yscroll), so
                //   ly = (Y - vbporch + 1) + yscroll.
                // The old "+2" made every sprite land one scanline too high;
                // cross-correlating the engine's output against MAME's showed a
                // clean (dx=0, dy=+1) peak covering 88% of the matched pixels.
                ly <= (y_count - vbporch + 10'd1 + {1'b0, yscroll}) & 9'h1FF;
                // tag bookkeeping: the buffer we are about to build will hold
                // pixels for this ly (stale content mismatches by definition)
                if(build_sel) begin
                    built_ly0 <= (y_count - vbporch + 10'd1 + {1'b0, yscroll}) & 9'h1FF;
                    built_fp0 <= fpar;
                end else begin
                    built_ly1 <= (y_count - vbporch + 10'd1 + {1'b0, yscroll}) & 9'h1FF;
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
                // MOCOV-1: the parked prefetch belongs to the line being
                // abandoned. Its request, if still outstanding, is covered by
                // the discA/discB marking just above - exactly like a
                // blitter-issued one, since it went out on the same channels.
                pf_armed <= 1'b0; sc_pf_valid <= 1'b0;
                pf_hit   <= 1'b0; pf_ch <= 1'b0;
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
                    // MOCOV-1: ...and go read this entry's w1 (the tile code)
                    // so the first tile-row can be asked for right away. The
                    // address is issued now; MO RAM answers two cycles later,
                    // in SC_W1's successor. The blitter may re-point mo_vaddr
                    // at w2 in the meantime - harmless, this read has already
                    // been committed to the RAM's address register.
                    h_ydiff  <= ydiff_e;
                    pf_armed <= 1'b0;
                    mo_vaddr <= {link, 2'd1};
                    sstate   <= SC_W1;
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

            // MOCOV-1: w1 is in the RAM's pipe. Do NOT touch mo_vaddr here -
            // the blitter's S_E0 is very likely driving it at w2 this cycle.
            SC_W1: sstate <= SC_HOLD;

            SC_HOLD: begin
                // MOCOV-1: on the FIRST cycle here, w1 is on the bus. Decode
                // the sprite's first tile-row: code + ty*width, ty = ydiff>>3.
                // This is the multiply the blitter used to do in S_FETCH - it
                // moved here, it is not a second one.
                if(!pf_armed) begin
                    pf_code_row <= mo_vdata[14:0]
                                 + ( h_ydiff[8:3] * ({3'b0, h_w3[6:4]} + 4'd1) );
                    pf_row      <= h_ydiff[2:0];
                    pf_armed    <= 1'b1;
                end else if(sc_may_pf) begin
                    // A channel is free and the blitter cannot want it: put
                    // tile 0 in flight NOW, while the previous sprite is still
                    // blitting. fetch_budget is deliberately NOT decremented
                    // here - the blitter accounts for tile 0 when it starts the
                    // sprite, which keeps fetch_budget single-writer.
                    if(sc_pf_pick) begin
                        gfx_addrB <= 24'h120000 + { pf_code_row, 5'd0 }
                                                + { pf_row, 2'd0 };
                        gfx_reqB  <= ~gfx_reqB;
                        inflB     <= 1'b1;
                    end else begin
                        gfx_addrA <= 24'h120000 + { pf_code_row, 5'd0 }
                                                + { pf_row, 2'd0 };
                        gfx_reqA  <= ~gfx_reqA;
                        inflA     <= 1'b1;
                    end
                    sc_pf_ch    <= sc_pf_pick;
                    sc_pf_valid <= 1'b1;
                end
                // The blitter releases the port one cycle after it takes the
                // hit (it addresses w2 of the parked entry itself).
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
                // MOCOV-1: take over the scout's prefetch. pf_ch is the parity
                // base for every tile of this sprite; pf_hit says tile 0 is
                // already in flight so S_PRIME must not issue it again.
                pf_hit      <= sc_pf_valid;
                pf_ch       <= sc_pf_valid ? sc_pf_ch : 1'b0;
                sc_pf_valid <= 1'b0;
                state <= S_WAIT;
            end

            // The port is handed straight back: mo_vaddr is driven here for the
            // last time this sprite, and sc_restart lets the scout resume on the
            // NEXT cycle, so the two never drive the address in the same cycle.
            // ymatch (the registered form) is valid here - spr_y/height_t were
            // loaded one cycle ago - which is what the existing benches probe.
            S_WAIT: begin
                // MOCOV-1: w1 is the SCOUT's job now, so this cycle no longer
                // drives an address at all - the port goes back a cycle
                // cleaner. code_row/row_in_tile come from the scout's decode,
                // which has been armed since the cycle S_E0 ran (SC_HOLD arms
                // it two cycles after SC_E3, S_E0 is two cycles after SC_E3).
                code_row    <= pf_code_row;
                row_in_tile <= pf_row;
                sc_restart  <= 1'b1;
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
                // MOCOV-1: code_row/row_in_tile were latched at S_WAIT from the
                // scout's decode, so nothing is read off the bus here any more.
                tx_f  <= 3'd0;                  // next tile to ISSUE
                tx    <= 3'd0;                  // next tile to LATCH/blit
                blit_n <= 4'd15;                // marker: nothing in flight
                // MOFETCH-4: spr_x is known now (S_MATCH, one cycle ago). If
                // every column this object covers would be clipped away, drop
                // it here - before any fetch is issued. Not a semantic change:
                // S_BLIT would have discarded all of its pixels anyway.
                // MOCOV-1: the scout could not know this (spr_dead needs x,
                // which lives in w2 and stays blitter-side), so a prefetch for
                // a wholly off-screen object has to be thrown away. Swallow its
                // completion rather than let the next sprite mis-pair with it.
                if(spr_dead && pf_hit) begin
                    if(pf_ch) begin
                        if(inflB && !doneB_edge) discB <= 1'b1; else pendB <= 1'b0;
                    end else begin
                        if(inflA && !doneA_edge) discA <= 1'b1; else pendA <= 1'b0;
                    end
                    pf_hit <= 1'b0;
                end
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
                  if(pf_hit) begin
                    // MOCOV-1: tile 0 is ALREADY in flight (or landed) on
                    // pf_ch - the scout put it there during the previous
                    // sprite's blit, which is the whole saving. Only tile 1
                    // has to be issued, on the other channel. It still costs
                    // its budget slot; tile 0's is charged here too, since the
                    // scout deliberately leaves fetch_budget single-writer.
                    if(width_t != 3'd0 && fetch_budget > 7'd1
                       && !(pf_ch ? (inflA || pendA) : (inflB || pendB))) begin
                        if(pf_ch) begin
                            gfx_addrA <= 24'h120000
                                        + { (code_row + 15'd1), 5'd0 }
                                        + { row_in_tile, 2'd0 };
                            gfx_reqA  <= ~gfx_reqA;
                            inflA     <= 1'b1;
                        end else begin
                            gfx_addrB <= 24'h120000
                                        + { (code_row + 15'd1), 5'd0 }
                                        + { row_in_tile, 2'd0 };
                            gfx_reqB  <= ~gfx_reqB;
                            inflB     <= 1'b1;
                        end
                        tx_f <= 3'd2;
                        fetch_budget <= fetch_budget - 7'd2;
                    end else begin
                        // tile 1 could not be issued yet (channel still busy);
                        // the refill arm below picks it up when tile 0 lands.
                        tx_f <= 3'd1;
                        fetch_budget <= fetch_budget - 7'd1;
                    end
                    blit_n <= 4'd14;
                  end else if(!inflA && !(width_t != 3'd0 && inflB)) begin
                    // FALLBACK: the scout could not prefetch (no free channel,
                    // or it never got the chance). Identical to the pre-MOCOV
                    // path - tile 0 on A, tile 1 on B - and pf_ch is 0, so the
                    // parity below degenerates to the old even-A/odd-B rule.
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
                end else if(pend_cur) begin
                    // tile tx's data has landed on its parity channel
                    rowdata <= data_cur;
                    if(ch_cur) pendB <= 1'b0; else pendA <= 1'b0;
                    blit_x  <= blit_x_new;
                    // MOFETCH-4: a tile-row that lands wholly in the clipped
                    // 344..504 window costs one cycle instead of eight. Jumping
                    // straight to blit_n 7 keeps the existing end-of-tile
                    // handoff intact, and the single write it attempts is
                    // rejected by S_BLIT's own blit_x < 344 clip - so not one
                    // line-buffer write changes, only the cycles spent.
                    blit_n  <= tile_dead ? 4'd7 : 4'd0;
                    // refill the channel just freed with tile tx_f
                    // (MOCOV-1: on the pf_ch parity, not raw tile parity)
                    if(tx_f <= width_t && tx_f != 3'd0 && fetch_budget != 7'd0) begin
                        if(ch_iss) begin
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
                // MOPLACE-3: FIRST-write-wins. eprom's MO config sets
                // "render in reverse order" (reference/eprom.cpp s_mob_config),
                // so atarimo draws the linked list from its TAIL back to its
                // HEAD - the head entry is painted last and therefore wins every
                // pixel it touches. We must walk head-first (the list is singly
                // linked), so the equivalent is to refuse to overwrite a pixel
                // already written for THIS line: earliest entry wins, same
                // result. The refusal happens in the buffer write enable via
                // bld_occupied; this used to be last-wins, which handed
                // overlapping sprites to the wrong object (16% of MO pixels in
                // the reference frame).
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
