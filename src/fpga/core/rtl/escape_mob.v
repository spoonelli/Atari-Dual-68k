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
// pixel and leave via disp_prio for the priority comparator in escape_prio.v.
// MOSTAIN-1: MPR2 (the "special rendering" flag) rides with the pixel too. A
// special pixel occupies its slot (masking normal sprites beneath it, as the
// reference's single MO bitmap does) but never draws; its pen bits 1/2 leave
// via disp_stain_s/disp_stain_e and drive the compositor's apply_stain pass.
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

    // MOCHAN-4: gfx fetch channels, now FOUR (was the LANE3o A/B ping-pong).
    // Per-tile cost is max(8 blit cycles, round_trip/NCH). At the measured
    // worst-case round trip of 31 pixel clocks, NCH=2 gives max(8,15.5)=15.5
    // - fetch-concurrency-bound - and NCH=4 gives max(8,7.75)=8, i.e. the
    // engine becomes blit-bound, which is the floor.
    //
    // The ports are PACKED rather than named A/B/C/D so that the request and
    // completion vectors stay one object each: core_top's SDRAM grant tests a
    // single registered "some MO channel is pending" bit instead of a widening
    // OR of per-channel comparators (see core_top.v, MOCHAN-4).
    // Channel c occupies gfx_addr[c*24 +: 24] and gfx_data[c*32 +: 32].
    output wire [3:0]  gfx_req,         // toggles, one per channel
    output wire [95:0] gfx_addr,        // 4 x 24
    input  wire [3:0]  gfx_done,        // toggles, one per channel
    input  wire [127:0] gfx_data,       // 4 x 32

    // display-side pixel query (current line)
    input  wire [8:0]  disp_x,
    output wire [7:0]  disp_pen,        // {color[3:0], pix[3:0]}
    output wire [1:0]  disp_prio,       // MPR1:MPR0 of the sprite that owns this pixel
    output wire        disp_valid,
    // MOSTAIN-1: the "special" (MPR2) pass. A special pixel never draws, but it
    // OWNS its line-buffer slot (so it masks normal sprites under it, exactly
    // like the reference's single motion-object bitmap) and its own pen bits 1
    // and 2 are the START/END markers that drive apply_stain in the compositor.
    // MOTEL-129: quantifiable degradation telemetry, latched once per frame.
    // dbg_trunc  = lines this frame whose walk was cut by fetch_budget
    //              exhaustion with work remaining (the dropout event itself).
    // dbg_maxlat = worst gfx fetch round trip this frame, in pixel clocks,
    //              saturating at 255.
    output reg  [7:0]  dbg_trunc,
    output reg  [7:0]  dbg_maxlat,
    output wire        disp_stain_s,    // special pixel here, pen bit 1 set
    output wire        disp_stain_e     // special pixel here, pen bit 2 set
);

    // MOCHAN-4: per-channel registers behind the packed ports. Keeping the
    // address in a real register array and flattening it with a concatenation
    // means every signal that crosses into the 35.8MHz SDRAM domain is still
    // a plain register output - nothing combinational was added to the
    // crossing, exactly as MOCOV-1 left it.
    localparam NCH = 4;
    reg  [23:0] gaddr [0:3];
    reg  [3:0]  greq;
    assign gfx_addr = {gaddr[3], gaddr[2], gaddr[1], gaddr[0]};
    assign gfx_req  = greq;
    wire [31:0] gdata0 = gfx_data[31:0];
    wire [31:0] gdata1 = gfx_data[63:32];
    wire [31:0] gdata2 = gfx_data[95:64];
    wire [31:0] gdata3 = gfx_data[127:96];

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
    // compositor can run the real PF/M comparator (see docs/investigations/mo_priority.md).
    // MOSTAIN-1: MPR2 ("special", mopriority&4) is now CARRIED as a flag rather
    // than being thrown away at write time. Two things needed it:
    //   1. the reference draws specials into the ONE motion-object bitmap like
    //      any other sprite, so they mask normal sprites underneath; suppressing
    //      the write let the sprite below show through;
    //   2. the second pass (atarimo apply_stain) reads those very pixels and
    //      ORs 0x400 into the finished picture under them - the FACTORY MAP's
    //      "you are here" markers are drawn entirely by that pass.
    // The flag is paid for by narrowing the line tag from ly[8:0] to ly[7:0]:
    // one frame covers 240 scanlines, so two lines of the same frame can only
    // collide in ly[7:0] if their ly differ by exactly 256 - impossible over a
    // 240-line span - and cross-frame staleness is caught by fpar exactly as
    // before. The entry therefore stays at 20 bits = the native M10K geometry
    // (512x20), so this costs ZERO extra blocks: the 308-M10K ceiling is spent.
    // MOPAIR-131: each line buffer is TWO banks, even and odd screen columns,
    // written in the same clock - which is what the REAL BOARD does: sheet 9
    // of SP-332 shows the line buffer as a PAIR of LB customs (92U/85U)
    // handling MOL0/1 and MOR0/1 with a 14 MHz DCLK - the MO fill path is two
    // pixels per RCLK, twice this engine's old rate. The crowd fixture
    // (xs=473 ys=412) proved the deficit ARCHITECTURAL: its worst lines need
    // ~102 stamps = ~816 fill cycles against the 456 a scanline has, so 527
    // reference pixels dropped at ZERO memory latency - no cache, clock or
    // arbitration change could ever recover them. Pairing the banks halves
    // blit occupancy to <= 408 cycles on that same line, which fits.
    // Bank E holds even x at address x>>1, bank O odd x at the same shift;
    // a pair write lands E and O in one clock (addresses differ by one when
    // the pair straddles, see S_BLIT). Cost: the same 20 Kbit split across
    // four 256x20 BRAMs instead of two 512x20 - two more M10K blocks.
    reg [19:0] buf0e [0:255];           // {fpar, tag[7:0], special, prio[1:0], color[3:0], pix[3:0]}
    reg [19:0] buf0o [0:255];
    reg [19:0] buf1e [0:255];
    reg [19:0] buf1o [0:255];
    // M10K comes up zeroed on the device; mirror that for simulation so the
    // occupancy probe below reads a defined value on the very first line
    // instead of X. Simulation-only: kept out of synthesis so it can never
    // perturb RAM inference.
    // synthesis translate_off
    integer bi;
    initial for(bi = 0; bi < 256; bi = bi + 1) begin
        buf0e[bi] = 20'd0; buf0o[bi] = 20'd0;
        buf1e[bi] = 20'd0; buf1o[bi] = 20'd0;
    end
    // synthesis translate_on
    reg        fpar = 1'b0;
    reg        built_fp0 = 1'b0, built_fp1 = 1'b0;
    always @(posedge clk)
        if(y_count == 10'd0 && x_count == 10'd0) fpar <= ~fpar;
    reg        build_sel;               // which buffer is being built
    reg [7:0]  built_ly0, built_ly1;    // the ly each buffer was last built for
    reg [8:0]  blit_x;                  // declared early: feeds the probe read
    // MOPLACE-2: the buffer being BUILT is not the one being displayed, so its
    // read port sat idle at disp_x every cycle. Point it at blit_x instead and
    // it becomes an occupancy probe for first-write-wins (see S_BLIT). Still
    // one read + one write per buffer, so this is free: no extra M10K, no
    // extra port, no extra cycle.
    // MOALIGN-129: the DISPLAY leg reads at disp_x + 1, not disp_x. The read
    // is registered, so presenting address N at clock T delivers data at T+1,
    // when the compositor is already on pixel N+1. tb_mob knew and logged at
    // visible_x MINUS ONE to compensate, so every gate was pixel-perfect while
    // the DEVICE composited the MO layer - and the stain markers, which come
    // from the same registered read - one pixel RIGHT of the playfield. A 1px
    // MO offset is invisible on sprites; the stain is where it showed: the
    // leftmost column of every stained region went uncovered, which is the
    // map specks and the shed checkerboard fragments. Reading at disp_x+1
    // aligns delivery with consumption; the bench compensation is removed in
    // the same commit, and the gates passing unchanged proves the change is a
    // pure one-pixel alignment.
    // MOPAIR-131: the display leg addresses pixel N via bank N[0] at N>>1;
    // both banks are read at the same shifted address and the registered
    // parity bit picks the winner, so the delivered stream is identical to
    // the old single-bank read (same disp_x+1 issue/consume alignment).
    // The build leg's read ports become the occupancy PROBE for the pair
    // being written: bank E and bank O each probe their own half.
    wire [8:0] nxt_x   = disp_x + 9'd1;
    wire [8:0] blit_xb = blit_x + 9'd1;      // second pixel of the pair
    // per-bank probe addresses for the pair (x at blit_x, x+1 at blit_xb):
    // the even-x member goes to bank E, the odd-x member to bank O.
    wire [7:0] pr_addr_e = blit_x[0] ? blit_xb[8:1] : blit_x[8:1];
    wire [7:0] pr_addr_o = blit_x[0] ? blit_x[8:1]  : blit_xb[8:1];
    reg  [19:0] disp_q0e, disp_q0o, disp_q1e, disp_q1o;
    reg         nxp_d0, nxp_d1;              // registered parity of the read
    always @(posedge clk) begin
        if(build_sel) begin
            disp_q0e <= buf0e[nxt_x[8:1]];
            disp_q0o <= buf0o[nxt_x[8:1]];
            disp_q1e <= buf1e[pr_addr_e];
            disp_q1o <= buf1o[pr_addr_o];
            nxp_d0   <= nxt_x[0];
        end else begin
            disp_q0e <= buf0e[pr_addr_e];
            disp_q0o <= buf0o[pr_addr_o];
            disp_q1e <= buf1e[nxt_x[8:1]];
            disp_q1o <= buf1o[nxt_x[8:1]];
            nxp_d1   <= nxt_x[0];
        end
    end
    wire [19:0] disp_q0 = nxp_d0 ? disp_q0o : disp_q0e;
    wire [19:0] disp_q1 = nxp_d1 ? disp_q1o : disp_q1e;
    // "this entry holds a real pixel written for the line this buffer was last
    // built for". S_BLIT only ever writes pix != 0 (pen 0 is transparent), so
    // requiring pix != 0 makes an all-zero entry unrepresentable as a hit -
    // which is what a powered-up (or never-written) M10K location reads.
    // Without that, an untouched entry aliases the tag {fpar=0, ly=0}.
    // "occupied" = a real pixel written for the line this buffer was built for,
    // special or not. "hit" = one that is allowed to DRAW (i.e. not special).
    wire occ0 = (disp_q0[19:11] == {built_fp0, built_ly0}) && (disp_q0[3:0] != 4'd0);
    wire occ1 = (disp_q1[19:11] == {built_fp1, built_ly1}) && (disp_q1[3:0] != 4'd0);
    wire hit0 = occ0 && !disp_q0[10];
    wire hit1 = occ1 && !disp_q1[10];
    // MOPAIR-131: per-bank occupancy of the BUILD buffer, for first-write-wins
    // on each half of the pair independently.
    wire [19:0] bld_qe = build_sel ? disp_q1e : disp_q0e;
    wire [19:0] bld_qo = build_sel ? disp_q1o : disp_q0o;
    wire        bld_fp = build_sel ? built_fp1 : built_fp0;
    wire [7:0]  bld_ly = build_sel ? built_ly1 : built_ly0;
    wire occ_e = (bld_qe[19:11] == {bld_fp, bld_ly}) && (bld_qe[3:0] != 4'd0);
    wire occ_o = (bld_qo[19:11] == {bld_fp, bld_ly}) && (bld_qo[3:0] != 4'd0);

    assign disp_pen   = build_sel ? disp_q0[7:0] : disp_q1[7:0];
    assign disp_prio  = build_sel ? disp_q0[9:8] : disp_q1[9:8];
    assign disp_valid = build_sel ? hit0 : hit1;

    // MOSTAIN-1: the special-pass markers for the compositor's stain automaton.
    wire       spc_hit = build_sel ? (occ0 && disp_q0[10]) : (occ1 && disp_q1[10]);
    wire [3:0] spc_pen = build_sel ? disp_q0[3:0] : disp_q1[3:0];
    assign disp_stain_s = spc_hit & spc_pen[1];
    assign disp_stain_e = spc_hit & spc_pen[2];

    // Occupancy of the build buffer at the pixel wr_x/wr_en are aiming at: the
    // probe read and the wr_x/wr_en registers both sample blit_x in the same
    // cycle, and the buffer write commits one cycle later, so this is exactly
    // "what is already at wr_x, before this write".
    // MOPAIR-131: bld_occupied is per-bank now (occ_e / occ_o above).

    // write ports: one per bank, sharing everything but the pen nibble
    reg  [7:0]  wr_xe, wr_xo;
    reg  [15:0] wr_hi;                  // {fpar, ly, special, prio, color}
    reg  [3:0]  wr_pen_e, wr_pen_o;
    reg         wr_en_e, wr_en_o;

    // GFXDASH-3: SELF-CLEARING READOUT - the thing the real MOHLB does, and
    // the thing LANE3n's comment above says it does instead of tagging.
    //
    // The tag is {fpar, ly[7:0]} and fpar is ONE bit, so it distinguishes this
    // frame from LAST frame and from nothing else. An entry written two frames
    // ago carries the same parity as this frame; if nothing has rewritten that
    // column in that buffer since, it reads back as LIVE. LANE4q fixed the
    // one-frame ghost and left the two-frame ghost, at half the rate and with
    // a 30 Hz flicker - which is exactly the 2-frame parity measured on
    // hardware in docs/investigations/GFX_DASH_ARTIFACT.md sections 3(c) and 7.
    //
    // It costs pixels twice over. The stale entry DISPLAYS (a sprite in two
    // places at once), and - worse - it satisfies bld_occupied, so a live
    // sprite arriving at that column has its write REFUSED by a ghost. When
    // the refused write is a stain END marker, the automaton in escape_stain.v
    // never sees its terminator and the stain runs from the marker's
    // world-anchored left edge to the last screen column. Both failures are
    // reproduced, before this change, by sim/run_stain_tb.sh (cases D and E).
    //
    // Widening the tag is not available: the entry is 20 bits, which is
    // exactly the native 512x20 M10K geometry, and a 21st bit doubles both
    // line buffers to 2 blocks each. The design is at the 308-block ceiling.
    //
    // So clear on readout instead. Each buffer already has one read port and
    // one write port; while a buffer is being DISPLAYED its write port is
    // idle, because blit writes go to the other one. Writing zero there costs
    // no port, no block and no cycle - and an all-zero entry is unrepresentable
    // as a hit (S_BLIT only ever writes pix != 0), so it can never alias.
    //
    // clr_x is disp_x delayed one cycle, so the clear NEVER touches the address
    // the display side is reading in the same cycle - no read-during-write
    // behaviour is relied on, which is what would otherwise cost a bypass mux
    // or an inference warning. disp_x sweeps 0..394 (and 452..511) every line
    // and S_BLIT writes only below 344, so every writable column is cleared
    // exactly once per line. Buffers alternate every line, so each one is
    // cleared during the line immediately BEFORE it is built: every build now
    // starts from an empty buffer, and staleness is impossible by construction
    // rather than by an argument about tag width. The tags stay anyway - they
    // still cover the reset state and cost nothing.
    // MOPAIR-131: the clear sweeps pair addresses - both banks zeroed at
    // (disp_x-1)>>1 each clock, so every pair is cleared twice per line (a
    // harmless double zero). The in-flight display read is at (disp_x+1)>>1,
    // which differs from the clear address by exactly one always, so the old
    // no-read-during-write guarantee is preserved bank-for-bank.
    reg [8:0] clr_x;
    always @(posedge clk) clr_x <= disp_x;

    always @(posedge clk) begin
        if(build_sel) begin
            if(wr_en_e && !occ_e) buf1e[wr_xe] <= {wr_hi, wr_pen_e};
            if(wr_en_o && !occ_o) buf1o[wr_xo] <= {wr_hi, wr_pen_o};
            buf0e[clr_x[8:1]] <= 20'd0;
            buf0o[clr_x[8:1]] <= 20'd0;
        end else begin
            if(wr_en_e && !occ_e) buf0e[wr_xe] <= {wr_hi, wr_pen_e};
            if(wr_en_o && !occ_o) buf0o[wr_xo] <= {wr_hi, wr_pen_o};
            buf1e[clr_x[8:1]] <= 20'd0;
            buf1o[clr_x[8:1]] <= 20'd0;
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
    // crosses to the 35.8MHz SDRAM domain (gfx_req*, gfx_addr*) is still
    // registered here, so nothing combinational was added to that crossing.
    //
    // MODEPTH-1 measured the same way, against MOCHAN-4 (the two rows above
    // predate the four-channel change, so they are not directly comparable to
    // these; each row is measured against the revision immediately before it):
    //          ALMs   regs   M10K   block-mem bits   DSP   worst setup slack
    //   before  530    361      2       20,480        1        +129.216 ns
    //   after   768    607      2       20,480        1        +127.059 ns
    // M10K and block-memory-bits deltas are both 0, which is the number that
    // matters: the design is AT the 308-block ceiling. The park queue is
    // deliberately registers, and tch_v is a flat vector indexed by part-select
    // rather than an array of regs, precisely so neither can be inferred as
    // memory. DSP delta 0 again - the code_row multiply travelled with the
    // decode into SC_DEC rather than being duplicated per queue slot. The
    // engine now spends 12.6ns of the 139.68ns budget, up from 10.5ns, and
    // core_top.v is unchanged, so the SDRAM grant - shared with both CPUs and
    // the tightest path in the design - sees exactly what it saw before.
    //
    // MODEPTH-1: PREFETCH DEPTH. MOCHAN-4 left the steady-state per-tile cost
    // at max(8 blit, 31/4) = 8, i.e. blit-bound, but per-sprite STARTUP barely
    // moved (14.22 -> 12.54 cycles) and became 42-54% of all fetch stall.
    // Startup is a pure LATENCY and channel count does not divide a latency;
    // the only thing that hides it is asking EARLIER. The scout held exactly
    // one prefetch, so it spent 29,668 cycles a frame parked with nothing left
    // to do while its mean lead (29.6 cycles) fell just short of the 31-cycle
    // round trip. It now holds a PARK QUEUE (QDEPTH slots) and keeps walking.
    //
    // Three things had to change with it:
    //
    //  * CHANNEL ALLOCATION. MOCHAN-4 gave tile k of a sprite channel
    //    (pf_ch+k)&3, a fixed rotation, and kept the scout's single prefetch
    //    safe by only ever letting it go out AFTER every tile of the sprite in
    //    progress was already issued. With two prefetches that rule is not
    //    enough: a prefetch for the SECOND queued sprite can land on a channel
    //    the FIRST queued sprite's later tiles will rotate onto, and since the
    //    second sprite is consumed after the first, that is a deadlock, not a
    //    stall. Channels are now taken from a FREE LIST instead - a channel is
    //    only ever claimed when nothing is outstanding or unconsumed on it -
    //    and the channel each tile went to is recorded in tch_v. A collision
    //    is then impossible by construction rather than by rotation argument.
    //
    //  * HARVESTING (see q_dat/q_got below). A completion holds its channel
    //    from issue until somebody CONSUMES it, so a prefetch parked two
    //    sprites ahead used to pin a channel across the whole of the sprite in
    //    front of it. That is both a throughput tax - two pinned channels left
    //    the blitter's own pipeline running at (31+8)/2 per tile instead of
    //    (31+8)/4 - and the thing that would have capped QDEPTH at NCH-1.
    //    Landed prefetches are now copied into their slot and the channel is
    //    handed straight back, which unhooks channel occupancy from queue depth
    //    entirely and makes forward progress independent of the blitter.
    //
    //  * WALK vs PORT. The scout used to stop dead at its one park, so the
    //    blitter's w2 read (S_E0 assigns the address) never collided with it.
    //    A scout that keeps walking does collide, so the walk YIELDS that one
    //    cycle and redoes the entry it was on. Re-reading w0/w3 of `link`
    //    reaches the same verdict every time and neither `link` nor ent_count
    //    advances until an entry is finished, so a yield costs cycles and
    //    changes nothing else.
    //
    // DEADLOCK-FREEDOM, which the rotation used to provide, now rests on two
    // independent arguments, either of which is sufficient:
    //   - The pump can only be BLOCKED while it is waiting to issue tile tx_f
    //     AND the blitter is waiting for that same tile (tx == tx_f). Tiles are
    //     consumed in issue order, so tx == tx_f means this sprite has NOTHING
    //     outstanding, and every busy channel is busy with a scout prefetch.
    //     QDEPTH (3) of those against NCH (4) channels leaves one free.
    //   - Independently of that count: a prefetch's channel is released by the
    //     HARVEST, which fires on the completion and asks nothing of the
    //     blitter, so no prefetch can hold a channel indefinitely whatever the
    //     depth.
    //
    // What did NOT change: the queue is a strict FIFO - the scout pushes at the
    // tail in list order, the blitter pops at the head - so the blitter loads
    // sprites in EXACTLY the order a depth-1 park delivered them. First-write-
    // wins therefore still hands an overlapped pixel to the entry nearest the
    // list head, which is what reproduces eprom's reverse render order. That is
    // checked, not argued: sim/tools/mob_order_check.py diffs the per-line
    // sprite load sequence against the depth-1 engine's (the shorter run must
    // be an exact prefix of the longer) and sim/tools/mob_vs_mame.py scores the
    // rendered layer against MAME's own tail-first atarimo renderer.
    localparam SC_IDLE  = 4'd0;
    localparam SC_E0    = 4'd1;
    localparam SC_E1    = 4'd2;
    localparam SC_E2    = 4'd3;
    localparam SC_E3    = 4'd4;
    localparam SC_W1    = 4'd5;         // MOCOV-1: w1 addressed, in the pipe
    localparam SC_DEC   = 4'd6;         // w1 on the bus: decode and PUSH
    localparam SC_ROOM  = 4'd7;         // queue full - wait for the blitter
    localparam SC_DONE  = 4'd8;         // list exhausted for this line

    reg [3:0]  sstate;
    // the entry the scout is decoding, between SC_E3 and the push at SC_DEC
    reg [9:0]  s_link;
    reg [15:0] s_w3;
    reg [8:0]  s_ydiff;
    reg        s_last;                  // ...and it is the list's last entry

    // ---- the PARK QUEUE. Slot 0 is the head - the next sprite the blitter
    // will load - and the scout pushes at the tail. Every queued slot is
    // complete: the scout decodes the first tile-row (code + ty*width - the
    // multiply MOCOV-1 moved here from the blitter) before it pushes, so the
    // blitter never has to wait for a half-built park.
    // QDEPTH is the whole knob this change exists to turn, and it is MEASURED,
    // not guessed: at the worst-case round trip (lat31, scene 50/157) coverage
    // goes 82.70 -> 90.50 -> 93.51 for one, two and three slots, and 4, 5 and 6
    // slots reproduce the three-slot frame to the pixel. Three is the knee -
    // past it the queue is simply never that full while a sprite is still
    // waiting, and the residual startup has moved to channel availability.
    //
    // The harvest below is what removes the ceiling on this number. Without it
    // a prefetch pins its channel until its sprite is DRAWN, so more than NCH-1
    // slots could starve the blitter's own pump of channels and hang the line;
    // with it a prefetch holds a channel only for the flight, is harvested the
    // cycle its row lands, and does so with no dependence whatever on blitter
    // progress. Three is under NCH-1 anyway, so both arguments hold here.
    localparam QDEPTH = 3;
    reg [9:0]  q_link [0:QDEPTH-1];
    reg [15:0] q_w3   [0:QDEPTH-1];
    reg [14:0] q_code [0:QDEPTH-1];     // first tile-row of that sprite
    reg [2:0]  q_row  [0:QDEPTH-1];     // row within the tile
    reg        q_pf   [0:QDEPTH-1];     // tile 0 is already in flight...
    reg [1:0]  q_ch   [0:QDEPTH-1];     // ...on this channel
    // MODEPTH-2: ...and once it LANDS it is harvested out of that channel
    // immediately instead of sitting in `pend` until the blitter gets here.
    // This is what makes depth affordable. A completion holds its channel from
    // issue until somebody consumes it, so a prefetch parked two sprites ahead
    // used to pin a channel for the whole of the sprite in front of it - two
    // slots pinned two of the four channels, and the blitter's own pipeline was
    // left running at (31+8)/2 = 19.5 cycles a tile instead of (31+8)/4 = 9.75.
    // Depth was paying for itself out of the steady-state term. Harvesting the
    // row into the slot costs 32 bits and hands the channel straight back.
    reg [31:0] q_dat  [0:QDEPTH-1];
    reg        q_got  [0:QDEPTH-1];     // ...and the row is here, not in a channel
    // MOPF2-132: a SECOND prefetch lane per slot, for the sprite's tile 1.
    // The mo-harvest instrumentation said it plainly: 99.85% of fetch stall is
    // waiting on memory for a fetch already issued, and 71% of steady state is
    // ONE SPRITE'S SECOND TILE - the pump cannot ask for tile 1 until the
    // blitter has LOADED the sprite (pump_live), so tile 0 blits (4 cycles
    // since MOPAIR) while tile 1 is still a full round trip away. The scout
    // already holds everything needed to ask earlier: q_code+1 is tile 1's
    // row. Lane 2 fills only after every parked tile 0 is in flight, only for
    // sprites wider than one tile, through the same single issue port, same
    // free list, same harvest - so every structural argument (deadlock
    // freedom, draw order, one-issuer) carries over unchanged.
    reg        q_pf2  [0:QDEPTH-1];     // tile 1 is already in flight...
    reg [1:0]  q_ch2  [0:QDEPTH-1];     // ...on this channel
    reg [31:0] q_dat2 [0:QDEPTH-1];
    reg        q_got2 [0:QDEPTH-1];
    reg [2:0]  q_cnt;                   // 0..QDEPTH
    integer    qi;

    // blitter side: which channel each tile of the CURRENT sprite went out on.
    // Two bits per tile, flat rather than an array so it can never be inferred
    // as memory - the design is at the 308-M10K ceiling and this must cost 0.
    reg [15:0] tch_v;                   // tile k -> tch_v[k*2 +: 2]
    wire [1:0] pf_ch = tch_v[1:0];      // tile 0's channel
    reg        pf_hit;                  // tile 0 was prefetched, do not re-issue
    reg        pf_got;                  // ...and its row was harvested into
    reg [31:0] pf_dat;                  // ...here, so no channel holds it
    // MOPF2-132: same trio for tile 1; its channel is tch_v[3:2], written at
    // the pop exactly like tile 0's.
    reg        pf2_hit;
    reg        pf2_got;
    reg [31:0] pf2_dat;
    wire [1:0] pf_ch2 = tch_v[3:2];

    integer    ci;                      // MOCHAN-4: per-channel loop index
    reg [3:0]  state;
    reg [8:0]  ly;                      // playfield-space line being built
    reg [9:0]  first_link, link;
    reg [9:0]  nlink;                   // MOFETCH-1: this entry's link, read early
    reg [6:0]  ent_count;
    // MOCOV-1: w1 is gone - the blitter no longer reads the code word at all,
    // the scout does (and turns it straight into the queue slot's code).
    reg [15:0] w0, w2, w3;
    reg [8:0]  spr_y;
    reg [3:0]  spr_color;
    reg [2:0]  spr_prio;                // w2[6:4] - MPR2:MPR0
    reg [8:0]  spr_x;
    reg [2:0]  width_t, height_t;
    reg        hflip;
    reg [2:0]  tx;                      // next tile to LATCH/blit
    // MOCHAN-4: tx_f is 4 bits. With 3 bits it wrapped to 0 on an 8-tile
    // sprite (width_t==7) the moment the last tile was issued, which silently
    // read as "not finished issuing" and suppressed the scout prefetch for the
    // sprite after it. 4 bits makes tx_f > width_t say what it means.
    reg [3:0]  tx_f;                    // next tile to ISSUE
    reg [14:0] code_row;                // code + ty*width
    reg [2:0]  row_in_tile;
    reg [3:0]  gfx_done_last;
    reg [3:0]  pend;                    // completion seen, not yet consumed
    // MOFETCH-2: per-channel in-flight tracking. v87 resynced the done toggles
    // on a line abort, which discards a completion that has ALREADY arrived -
    // but a request issued before the abort and served after it still toggles
    // done, sets pend, and gets consumed by the new line's first tile with the
    // previous request's data. From then on every tile on that channel is
    // paired with the wrong tile-row: real sprite art at the wrong X.
    reg [3:0]  infl;                    // issued, completion not yet seen
    reg [3:0]  disc;                    // swallow one completion (aborted line)
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
    // MOTEL-129 accumulators (frame-local), latched into dbg_* at frame start.
    reg [7:0]  tel_trunc = 8'd0;
    reg [7:0]  tel_maxlat = 8'd0;
    reg [7:0]  tel_lat [0:3];
    reg [3:0]  tel_req_d = 4'd0, tel_done_d = 4'd0;
    integer    ti;
    initial begin dbg_trunc=8'd0; dbg_maxlat=8'd0; for(ti=0;ti<4;ti=ti+1) tel_lat[ti]=8'd0; end
    always @(posedge clk) begin
        // per-channel fetch latency: req toggle -> done toggle, pixel clocks
        tel_req_d  <= gfx_req;
        tel_done_d <= gfx_done;
        for(ti=0;ti<4;ti=ti+1) begin
            if(gfx_req[ti] != tel_req_d[ti]) tel_lat[ti] <= 8'd1;
            else if(gfx_done[ti] != tel_done_d[ti]) begin
                if(tel_lat[ti] > tel_maxlat) tel_maxlat <= tel_lat[ti];
            end else if(tel_lat[ti] != 8'd0 && tel_lat[ti] != 8'hFF)
                tel_lat[ti] <= tel_lat[ti] + 8'd1;
        end
        // frame boundary: latch and clear
        if(y_count == 10'd0 && x_count == 10'd0) begin
            dbg_trunc  <= tel_trunc;
            dbg_maxlat <= tel_maxlat;
            tel_trunc  <= 8'd0;
            tel_maxlat <= 8'd0;
        end
        // truncation: the walk leaves S_NEXT for S_IDLE because the budget is
        // gone while work remains (queue non-empty or scout not done).
        if(state == S_NEXT && fetch_budget == 0
           && (q_cnt != 3'd0 || (sstate != SC_DONE && sstate != SC_IDLE))
           && tel_trunc != 8'hFF)
            tel_trunc <= tel_trunc + 8'd1;
        // MOTEL-131: TIME truncation. The v85 line trigger aborts a build
        // that is still walking - work remains but no budget was exhausted,
        // so the counter above never saw it. The crowd fixture (pre-MOPAIR)
        // measured 85 such lines per frame with dbg_trunc reading ZERO: this
        // was the dropout mechanism, invisible to the old counter. Count a
        // line trigger only when UNCONSUMED entries remain - the scout still
        // walking the list, or matched entries parked unblitted. A walk merely
        // finishing its final stamp has drawn everything it was asked to and
        // is not a truncation.
        if(x_count == 10'd0 && y_count >= vbporch - 10'd1
           && y_count < vbporch + vactive - 10'd1
           && (q_cnt != 3'd0 || (sstate != SC_DONE && sstate != SC_IDLE))
           && tel_trunc != 8'hFF)
            tel_trunc <= tel_trunc + 8'd1;
    end

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
    wire [3:0] done_edge = gfx_done ^ gfx_done_last;

    // ---- MODEPTH-1: channel FREE LIST and the SINGLE issue port ----------
    // A channel is free when nothing is outstanding on it AND nothing has
    // landed on it that somebody still has to consume. MOCHAN-4 tested one
    // rotation-chosen channel for that; the issue port now picks any free one,
    // which is what lets the scout run two prefetches ahead of the blitter
    // without a rotation collision (see the MODEPTH-1 note above).
    wire [3:0] ch_free = ~(infl | pend);
    wire [1:0] ch_pick = ch_free[0] ? 2'd0 : ch_free[1] ? 2'd1
                       : ch_free[2] ? 2'd2 : 2'd3;
    wire       ch_any  = |ch_free;
    // at least TWO free: the scout leaves one for the blitter's own pump, so a
    // prefetch for a sprite further down the list can never make the sprite
    // being drawn wait. (Deadlock-freedom does not depend on this - see the
    // counting argument above - throughput does.)
    wire       ch_two  = ((ch_free & (ch_free - 4'd1)) != 4'd0);

    // channel the blitter is consuming: recorded at issue, not derived from a
    // rotation, so tile tx always reads back the channel tile tx went out on.
    wire [1:0] ch_cur = tch_v[{tx, 1'b0} +: 2];
    wire       pend_cur = pend[ch_cur];
    wire [31:0] data_cur = ch_cur[1] ? (ch_cur[0] ? gdata3 : gdata2)
                                     : (ch_cur[0] ? gdata1 : gdata0);
    // ...and it is only meaningful once tile tx has actually been issued. With
    // a rotation the channel for tile tx was always computable; with a recorded
    // map it is stale until the issue happens, so S_PRIME is told explicitly
    // that the tile it is waiting for exists. (tx==0 with pf_hit is issued too:
    // the scout put it in flight before this sprite was even loaded.)
    wire       tile_live = (tx_f > {1'b0, tx}) || ((tx == 3'd0) && pf_hit)
                        || ((tx == 3'd1) && pf2_hit);   // MOPF2-132

    // MODEPTH-2: tile 0 of a prefetched sprite may already have been harvested
    // out of its channel, in which case it comes from pf_dat and there is no
    // pend bit to clear. Every other tile is read straight off its channel.
    wire        t0_harvested = (tx == 3'd0) && pf_got;
    wire        t1_harvested = (tx == 3'd1) && pf2_got;   // MOPF2-132
    wire        tile_rdy = t0_harvested || t1_harvested
                         || (tile_live && pend_cur);
    wire [31:0] tile_dat = t0_harvested ? pf_dat
                         : t1_harvested ? pf2_dat : data_cur;

    // A prefetch whose row has landed but not been harvested yet. Harvesting
    // every slot in the same cycle is safe: the free list guarantees the
    // channels of two outstanding prefetches are different.
    wire [QDEPTH-1:0] hv;
    wire [31:0] hv_dat [0:QDEPTH-1];
    genvar gq;
    wire [QDEPTH-1:0] hv2;                       // MOPF2-132 lane-2 harvest
    wire [31:0] hv_dat2 [0:QDEPTH-1];
    generate for(gq = 0; gq < QDEPTH; gq = gq + 1) begin : HARVEST
        wire [1:0] c = q_ch[gq];
        assign hv_dat[gq] = c[1] ? (c[0] ? gdata3 : gdata2)
                                 : (c[0] ? gdata1 : gdata0);
        assign hv[gq] = (q_cnt > gq) && q_pf[gq] && !q_got[gq] && pend[c];
        // Lane 2, same shape. The free list guarantees the two lanes' live
        // prefetches sit on DIFFERENT channels, so both harvests landing in
        // one cycle touch disjoint pend bits.
        wire [1:0] c2 = q_ch2[gq];
        assign hv_dat2[gq] = c2[1] ? (c2[0] ? gdata3 : gdata2)
                                   : (c2[0] ? gdata1 : gdata0);
        assign hv2[gq] = (q_cnt > gq) && q_pf2[gq] && !q_got2[gq] && pend[c2];
    end endgenerate

    // THE ISSUE PORT. There is exactly ONE fetch issuer in this module now.
    // Before MOCHAN-4 there were four separate ones (the scout's prefetch, the
    // blitter's tile-0 issue, its tile-1 issue and its steady-state refill),
    // each with its own address adder and each writing gfx_req/gfx_addr/infl -
    // four writers to the same registers, kept apart only by an argument about
    // states. Collapsing them removes three adders AND makes the mutual
    // exclusion structural: the arbitration below is an if/else chain, so at
    // most one request can ever be launched in a cycle. (Same lesson as the
    // v14-v19 SDRAM misrouting: two grant arms firing on one clock is
    // last-writer-wins address corruption.)
    //
    // The blitter's PUMP: while a sprite is in progress, issue the next
    // un-issued tile as soon as its rotation slot frees up. One tile per
    // cycle is plenty - a tile takes 8 cycles to blit - and it fills the pipe
    // to all four channels without four parallel address adders. It also
    // costs no dedicated issue cycle at sprite start, which the old
    // blit_n==15 arm did.
    wire pump_live  = (state == S_PRIME) || (state == S_BLIT);
    wire pump_ready = pump_live && (tx_f <= {1'b0, width_t})
                      && (fetch_budget != 7'd0);
    // tile 0 was already put in flight by the scout: charge its budget slot
    // and step tx_f past it, but do NOT issue it again.
    wire pump_pref  = pump_ready && (tx_f == 4'd0) && pf_hit;
    // MOPF2-132: tile 1 already in flight from the scout - step past it
    // exactly like tile 0, charging budget without re-issuing.
    wire pump_pref2 = pump_ready && (tx_f == 4'd1) && pf2_hit;
    wire pump_want  = pump_ready && !pump_pref && !pump_pref2 && ch_any;

    // The SCOUT's prefetch, one per queue slot, head slot first (it is needed
    // soonest). MOCHAN-4 could only issue this once every tile of the sprite in
    // progress was already issued, because a rotation-chosen channel might
    // otherwise be one that sprite still wanted. With a free list that cannot
    // happen, so the window opens as soon as two channels are free - which for
    // a wide sprite is long before its last tile goes out.
    //
    // The one thing still forbidden is prefetching in the cycle the blitter
    // POPS the head (S_E0). S_E0 reads qa_pf to decide pf_hit and the queue
    // shifts B down into A in the same cycle, so a prefetch recorded there
    // would be written into a slot that is being overwritten - an orphan fetch
    // nobody consumes. One cycle a sprite, and the invariant stays structural.
    // the parked entry nearest the head that has no prefetch yet: it is the one
    // the blitter will reach soonest, so it is the one worth asking for first
    reg  [2:0] sc_sel;
    reg        sc_want;
    reg        sc_lane2;    // MOPF2-132: this request is for the slot's tile 1
    always @(*) begin
        sc_sel = 3'd0; sc_want = 1'b0; sc_lane2 = 1'b0;
        // Lane 2 scans first so the loop's LAST match wins overall priority:
        // any slot still missing its tile 0 outranks every tile-1 request
        // (tile 0 is needed strictly sooner), and within a lane the slot
        // nearest the head wins, exactly as before.
        for(qi = QDEPTH-1; qi >= 0; qi = qi - 1)
            if((q_cnt > qi) && q_pf[qi] && !q_pf2[qi]
               && (q_w3[qi][6:4] != 3'd0)) begin
                sc_sel = qi[2:0]; sc_want = 1'b1; sc_lane2 = 1'b1;
            end
        for(qi = QDEPTH-1; qi >= 0; qi = qi - 1)
            if((q_cnt > qi) && !q_pf[qi]) begin
                sc_sel = qi[2:0]; sc_want = 1'b1; sc_lane2 = 1'b0;
            end
    end
    wire sc_may_pf = sc_want && (fetch_budget != 7'd0)
                     && ch_two && (state != S_E0);

    // one address adder, one req toggle, one infl set - for both issuers
    wire        iss_scout = !pump_want && sc_may_pf;
    wire        iss_en    = pump_want || iss_scout;
    wire [14:0] iss_code  = pump_want ? (code_row + {11'b0, tx_f})
                                      : (q_code[sc_sel]
                                         + {14'b0, sc_lane2});   // MOPF2-132
    wire [2:0]  iss_row   = pump_want ? row_in_tile : q_row[sc_sel];
    wire [23:0] iss_addr = 24'h120000 + {iss_code, 5'd0} + {iss_row, 2'd0};

    // ---- queue push/pop. Push is the scout's decode cycle, pop is the
    // blitter taking the head. They are handled as ONE atomic update below so
    // that a push and a pop landing together cannot lose or reorder an entry.
    wire q_push = (sstate == SC_DEC);
    wire q_pop  = (state  == S_E0);
    // the slot a push lands in: the count, less the head a pop is retiring
    wire [2:0] q_tl = q_cnt - (q_pop ? 3'd1 : 3'd0);
    // the entry being pushed, assembled from the scout's staging registers and
    // the tile code that is on the MO RAM bus this cycle
    wire [14:0] q_new_code = mo_vdata[14:0]
                           + ( s_ydiff[8:3] * ({3'b0, s_w3[6:4]} + 4'd1) );

    // The blitter owns mo_vaddr for exactly ONE cycle: S_E0 assigns w2's
    // address, which therefore STANDS during S_WAIT, and the RAM answers into
    // S_MATCH. A scout write during S_WAIT lands one cycle later still and
    // cannot disturb that read, so the walk only has to yield S_E0 itself.
    // (Yielding S_WAIT as well cost 8,140 scout cycles a frame on the sparse
    // 0/0 scene - where the scout, not the blitter, is the limiter - for a
    // hold the MO RAM never needed.)
    wire blit_port = (state == S_E0);

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
    // MOPAIR-131: TWO pixels per blit cycle - pix_val for screen x = blit_x
    // (tile column blit_n), pix_val_b for x = blit_x+1 (column blit_n+1).
    // hflip mirrors the column index exactly as before, per pixel.
    wire [2:0] pn   = hflip ? (3'd7 - blit_n[2:0]) : blit_n[2:0];
    wire [2:0] pn_b = hflip ? (3'd7 - (blit_n[2:0] + 3'd1))
                            : (blit_n[2:0] + 3'd1);
    reg  [3:0] pix_val, pix_val_b;
    always @(*) begin
        case(pn)
            3'd0: pix_val = rowdata[31:28]; 3'd1: pix_val = rowdata[27:24];
            3'd2: pix_val = rowdata[23:20]; 3'd3: pix_val = rowdata[19:16];
            3'd4: pix_val = rowdata[15:12]; 3'd5: pix_val = rowdata[11:8];
            3'd6: pix_val = rowdata[7:4];   default: pix_val = rowdata[3:0];
        endcase
        case(pn_b)
            3'd0: pix_val_b = rowdata[31:28]; 3'd1: pix_val_b = rowdata[27:24];
            3'd2: pix_val_b = rowdata[23:20]; 3'd3: pix_val_b = rowdata[19:16];
            3'd4: pix_val_b = rowdata[15:12]; 3'd5: pix_val_b = rowdata[11:8];
            3'd6: pix_val_b = rowdata[7:4];   default: pix_val_b = rowdata[3:0];
        endcase
    end

    always @(posedge clk) begin
        if(!reset_n) begin
            state <= S_IDLE;
            sstate <= SC_IDLE;
            q_cnt <= 3'd0;
            for(qi = 0; qi < QDEPTH; qi = qi + 1) begin
                q_pf[qi] <= 1'b0; q_got[qi] <= 1'b0;
                q_pf2[qi] <= 1'b0; q_got2[qi] <= 1'b0;
            end
            pf_hit <= 0; pf_got <= 0; pf2_hit <= 0; pf2_got <= 0;
            tch_v <= 16'd0; tx_f <= 4'd0;
            greq <= 4'd0;
            pend <= 4'd0; infl <= 4'd0; disc <= 4'd0;
            wr_en_e <= 0; wr_en_o <= 0;
            build_sel <= 0;
            built_ly0 <= 8'hFF; built_ly1 <= 8'hFF;
            gfx_done_last <= 4'd0;
        end else begin
            wr_en_e <= 0; wr_en_o <= 0;
            gfx_done_last <= gfx_done;
            // completions can land while blitting: LATCH them (an edge is
            // visible for one cycle only - depth-2 lost edges without this)
            // MOFETCH-2: a completion always retires the in-flight marker, but
            // it only becomes a usable tile-row if it belongs to THIS line.
            for(ci = 0; ci < NCH; ci = ci + 1) begin
                if(done_edge[ci]) begin
                    infl[ci] <= 1'b0;
                    if(disc[ci]) disc[ci] <= 1'b0; else pend[ci] <= 1'b1;
                end
            end

            // MODEPTH-2: HARVEST. A prefetched row that has landed is copied
            // into its queue slot and its channel handed straight back, instead
            // of pinning the channel until the blitter walks to that sprite.
            // The channels this touches are disjoint from the one S_PRIME
            // consumes below (the free list never lends out a channel that
            // still holds an unconsumed row), so this and S_PRIME can never
            // write the same pend bit in the same cycle.
            for(qi = 0; qi < QDEPTH; qi = qi + 1) begin
                if(hv[qi]) begin
                    q_dat[qi] <= hv_dat[qi];
                    q_got[qi] <= 1'b1;
                    pend[q_ch[qi]] <= 1'b0;
                end
                // MOPF2-132: lane 2 harvests identically; different channel
                // by the free-list argument, so the pend bits are disjoint.
                if(hv2[qi]) begin
                    q_dat2[qi] <= hv_dat2[qi];
                    q_got2[qi] <= 1'b1;
                    pend[q_ch2[qi]] <= 1'b0;
                end
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
                    built_ly0 <= (y_count - vbporch + 10'd1 + {1'b0, yscroll}) & 10'h0FF;
                    built_fp0 <= fpar;
                end else begin
                    built_ly1 <= (y_count - vbporch + 10'd1 + {1'b0, yscroll}) & 10'h0FF;
                    built_fp1 <= fpar;
                end
                wr_en_e <= 0; wr_en_o <= 0;
                // v87: RESYNC the gfx handshakes on restart (see history)
                gfx_done_last <= gfx_done;
                pend <= 4'd0;
                // MOFETCH-2: v87 discarded completions that had already landed;
                // this discards the one still in flight. A request outstanding
                // right now belongs to the line being abandoned, so mark its
                // completion to be swallowed rather than paired with the new
                // line's first tile. If the completion is landing in THIS very
                // cycle it is already being retired above, so no discard is due.
                disc <= infl & ~done_edge;
                sstate <= SC_IDLE;
                // MOCOV-1/MODEPTH-1: every parked entry belongs to the line
                // being abandoned, so the whole queue goes. Their prefetches,
                // if still outstanding, are covered by the disc marking just
                // above - exactly like blitter-issued ones, since they went out
                // on the same four channels.
                q_cnt  <= 3'd0;
                for(qi = 0; qi < QDEPTH; qi = qi + 1) begin
                    q_pf[qi] <= 1'b0; q_got[qi] <= 1'b0;
                    q_pf2[qi] <= 1'b0; q_got2[qi] <= 1'b0;
                end
                pf_hit <= 1'b0; pf_got <= 1'b0;
                pf2_hit <= 1'b0; pf2_got <= 1'b0; tx_f  <= 4'd0;
                state <= S_CLEAR;
            end else begin

            // ================= LINK SCOUT =================
            // Owns mo_vaddr except during the blitter's two sprite-load cycles
            // (S_E0 / S_WAIT). Runs right through S_PRIME and S_BLIT, so on a
            // busy line the entire list walk is hidden behind the pixels - and
            // since MODEPTH-1 it no longer stops at its first find, so the walk
            // stays ahead of the blitter instead of restarting behind it.
            if(blit_port && (sstate == SC_E0 || sstate == SC_E1
                             || sstate == SC_E2 || sstate == SC_E3)) begin
                // THE YIELD. The blitter is assigning mo_vaddr this cycle, and
                // its assignment comes last, so any address the scout wrote now
                // would be silently dropped along with the read it was waiting
                // for. Redo the entry instead:
                // SC_E0..SC_E3 read w0 and w3 of `link` and reach the same
                // verdict every time, and neither `link` nor ent_count advances
                // until an entry is finished, so a yield costs cycles only.
                // SC_W1/SC_DEC/SC_ROOM are deliberately NOT yielded - they
                // drive no address, and SC_DEC's read was committed two cycles
                // ago and is unaffected.
                sstate <= SC_E0;
            end else
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
                if(ymatch_e && fetch_budget != 0) begin
                    // Stage it. Only the link and the raw geometry word are
                    // kept - nothing the blitter is currently drawing with is
                    // touched, which is what makes running ahead safe.
                    s_link  <= link;
                    s_w3    <= mo_vdata;
                    s_ydiff <= ydiff_e;
                    s_last  <= (nlink == first_link) || (ent_count == 7'd63);
                    // MOCOV-1: ...and go read this entry's w1 (the tile code)
                    // so the first tile-row can be asked for right away. The
                    // address is issued now; MO RAM answers two cycles later,
                    // in SC_W1's successor. The blitter may re-point mo_vaddr
                    // at w2 in the meantime - harmless, this read has already
                    // been committed to the RAM's address register.
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
            SC_W1: sstate <= SC_DEC;

            SC_DEC: begin
                // w1 is on the bus. Decode the sprite's first tile-row -
                // code + ty*width, ty = ydiff>>3, the multiply MOCOV-1 moved
                // here from the blitter - and PUSH the finished slot in this
                // one cycle (the push itself is in the queue block below).
                //
                // There is always room: the walk only ever leaves SC_ROOM with
                // q_cnt <= 1, and between there and here the only writer of
                // q_cnt other than this push is the blitter's pop, which can
                // only make room. So a decoded entry is never dropped.
                if(s_last || fetch_budget == 0) sstate <= SC_DONE;
                else begin
                    ent_count <= ent_count + 7'd1;
                    link      <= nlink;
                    // straight back to the walk if this push does not fill the
                    // queue (q_cnt is the PRE-push count here); SC_ROOM only
                    // exists for the cycles where it does
                    sstate    <= ((q_cnt + (q_pop ? 0 : 1)) < QDEPTH)
                                 ? SC_E0 : SC_ROOM;
                end
            end

            // Both slots are parked: nothing to do until the blitter takes one.
            // This is the cycle count that says whether a THIRD slot would pay.
            SC_ROOM: if(q_cnt < QDEPTH) sstate <= SC_E0;

            default: sstate <= SC_DONE;
            endcase

            // ================= BLITTER =================
            case(state)
            S_IDLE: begin
            end

            S_CLEAR: begin
                // GFXDASH-3: still no clear PASS here - the buffer about to be
                // built was zeroed column-by-column during the line it spent
                // being displayed (see the self-clearing readout above), which
                // is what the real MOHLB does and what the tags were standing
                // in for. This state is now purely the SLIP address cycle.
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
            // MODEPTH-1: POP THE HEAD. Everything the blitter needs about the
            // sprite except w2 is already in slot A - the scout decoded the
            // first tile-row before it pushed - so the load is one register
            // transfer and the queue shifts B down in the same cycle.
            S_E0: begin
                mo_vaddr <= {q_link[0], 2'd2};
                spr_y    <= q_w3[0][15:7];
                width_t  <= q_w3[0][6:4];
                height_t <= q_w3[0][2:0];
                hflip    <= q_w3[0][3];
                w3       <= q_w3[0];
                code_row    <= q_code[0];
                row_in_tile <= q_row[0];
                // take over this slot's prefetch: pf_hit says tile 0 is already
                // in flight so the pump must not issue it again, and tch_v[0]
                // records the channel it went out on so S_PRIME consumes it
                // from the right one.
                pf_hit      <= q_pf[0];
                // a harvest landing in this very cycle comes with it, otherwise
                // the row would be cleared out of `pend` and then dropped
                pf_got      <= q_got[0] | hv[0];
                pf_dat      <= hv[0] ? hv_dat[0] : q_dat[0];
                tch_v[1:0]  <= q_ch[0];
                // MOPF2-132: tile 1's prefetch comes over the same way
                pf2_hit     <= q_pf2[0];
                pf2_got     <= q_got2[0] | hv2[0];
                pf2_dat     <= hv2[0] ? hv_dat2[0] : q_dat2[0];
                tch_v[3:2]  <= q_ch2[0];
                state <= S_WAIT;
            end

            // MO RAM's second cycle for w2: the address driven in S_E0 has to
            // stand through here, which is why blit_port covers both cycles and
            // the scout's walk yields them.
            // ymatch (the registered form) is valid here - spr_y/height_t were
            // loaded one cycle ago - which is what the existing benches probe.
            S_WAIT: state <= S_MATCH;

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
                tx_f  <= 4'd0;                  // next tile to ISSUE
                tx    <= 3'd0;                  // next tile to LATCH/blit
                // MOCHAN-4: 14 == "the tile we are waiting for is (or is about
                // to be) in flight". The old 15 marked a dedicated issue cycle
                // in S_PRIME; the issue pump does that work in parallel now,
                // so S_PRIME's first cycle can already consume a landed tile.
                blit_n <= 4'd14;
                // MOFETCH-4: spr_x is known now (S_MATCH, one cycle ago). If
                // every column this object covers would be clipped away, drop
                // it here - before any fetch is issued. Not a semantic change:
                // S_BLIT would have discarded all of its pixels anyway.
                // MOCOV-1: the scout could not know this (spr_dead needs x,
                // which lives in w2 and stays blitter-side), so a prefetch for
                // a wholly off-screen object has to be thrown away. Swallow its
                // completion rather than let the next sprite mis-pair with it.
                if(spr_dead && pf_hit) begin
                    // MODEPTH-2: if it was already harvested the channel is
                    // long since back in the free list and there is nothing to
                    // swallow - just drop the row on the floor.
                    if(pf_got)                           pf_got <= 1'b0;
                    else if(infl[pf_ch] && !done_edge[pf_ch]) disc[pf_ch] <= 1'b1;
                    else                                 pend[pf_ch] <= 1'b0;
                    pf_hit <= 1'b0;
                end
                // MOPF2-132: and its tile 1, on its own channel (free list
                // guarantees the two are different, so these writes are
                // disjoint from the tile-0 swallow above).
                if(spr_dead && pf2_hit) begin
                    if(pf2_got)                          pf2_got <= 1'b0;
                    else if(infl[pf_ch2] && !done_edge[pf_ch2]) disc[pf_ch2] <= 1'b1;
                    else                                 pend[pf_ch2] <= 1'b0;
                    pf2_hit <= 1'b0;
                end
                state <= spr_dead ? S_NEXT : S_PRIME;
            end

            // LANE3o: FETCH-AHEAD. The serial issue-wait-blit loop paid the
            // full CRAM+CDC round trip (~1us) per tile-row ON TOP of the 8
            // blit cycles - a busy line ran out of time before late links
            // (Jake) were reached. The next tile's fetch is in flight WHILE
            // the current one blits: effective cost = max(fetch, blit/NCH).
            //
            // MOCHAN-4: S_PRIME no longer issues anything. It is purely
            // "wait for tile tx to land, then hand it to the blit loop" - the
            // issue pump below keeps all four channels loaded, running in
            // parallel with this state and with S_BLIT. That removed the old
            // blit_n==15 dedicated issue cycle per sprite as a side effect.
            S_PRIME: begin
                if(tile_rdy) begin
                    // tile tx's row: off its channel, or - for a prefetched
                    // tile 0 - out of the slot it was harvested into
                    rowdata <= tile_dat;
                    if(!t0_harvested && !t1_harvested) pend[ch_cur] <= 1'b0;
                    if(tx == 3'd0) pf_got  <= 1'b0;
                    if(tx == 3'd1) pf2_got <= 1'b0;     // MOPF2-132
                    blit_x  <= blit_x_new;
                    // MOFETCH-4: a tile-row that lands wholly in the clipped
                    // 344..504 window costs one cycle instead of eight. Jumping
                    // straight to blit_n 7 keeps the existing end-of-tile
                    // handoff intact, and the single write it attempts is
                    // rejected by S_BLIT's own blit_x < 344 clip - so not one
                    // line-buffer write changes, only the cycles spent.
                    // MOPAIR-131: the dead-tile shortcut parks on the LAST
                    // pair (>= 6 ends the tile after one clipped pair write).
                    blit_n  <= tile_dead ? 4'd6 : 4'd0;
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
                // MOSTAIN-1: spr_prio[2] (mopriority & 4) = "special rendering".
                // The reference `continue`s on it in the MERGE loop - but only
                // there: atarimo's draw() has already put the pixel into the one
                // motion-object bitmap, where it masks anything under it, and
                // the second pass (apply_stain) reads it back. So the pixel IS
                // written; it carries a special flag that stops it drawing and
                // hands its marker bits to the compositor. Nothing else changes:
                // the fetch budget, ring walk, blit loop and handshakes are
                // untouched, so timing and throughput are exactly as before.
                // MOPAIR-131: two pixels per cycle. The even-x member of the
                // pair goes to bank E, the odd-x member to bank O; each half
                // clips and drops pen 0 independently, so the written set is
                // bit-identical to the old one-per-cycle loop.
                wr_hi <= {fpar, ly[7:0], spr_prio[2], spr_prio[1:0],
                          spr_color};
                if(blit_x[0] == 1'b0) begin
                    if(pix_val != 4'd0 && blit_x < 9'd344) begin
                        wr_xe <= blit_x[8:1]; wr_pen_e <= pix_val; wr_en_e <= 1;
                    end
                    if(pix_val_b != 4'd0 && blit_xb < 9'd344) begin
                        wr_xo <= blit_xb[8:1]; wr_pen_o <= pix_val_b; wr_en_o <= 1;
                    end
                end else begin
                    if(pix_val != 4'd0 && blit_x < 9'd344) begin
                        wr_xo <= blit_x[8:1]; wr_pen_o <= pix_val; wr_en_o <= 1;
                    end
                    if(pix_val_b != 4'd0 && blit_xb < 9'd344) begin
                        wr_xe <= blit_xb[8:1]; wr_pen_e <= pix_val_b; wr_en_e <= 1;
                    end
                end
                blit_x <= (blit_x + 9'd2) & 9'h1FF;
                if(blit_n >= 4'd6) begin
                    if(tx == width_t) state <= S_NEXT;
                    // the next tile was never issued and the budget is spent,
                    // so nothing will ever land for it: end the sprite rather
                    // than wait in S_PRIME for a completion that cannot come.
                    else if(tx_f == {1'b0, tx} + 4'd1 && fetch_budget == 7'd0)
                        state <= S_NEXT;
                    else begin
                        tx     <= tx + 3'd1;
                        blit_n <= 4'd14;   // that tile's data is in flight
                        state  <= S_PRIME;
                    end
                end else begin
                    blit_n <= blit_n + 4'd2;
                end
            end

            // MOFETCH-3: the blitter no longer walks anything. It takes the
            // next entry the scout has already found, or - only if the scout
            // has run the list out - ends the line. Sitting here is the only
            // place the blitter can now be blocked by traversal, and on a busy
            // line the scout has always got there first.
            S_NEXT: begin
                if(q_cnt != 3'd0 && fetch_budget != 0) state <= S_E0;
                // SC_IDLE is included defensively: the scout is only ever left
                // idle by reset or a line abort, both of which also drive the
                // blitter out of S_NEXT, but a stuck S_NEXT would silently cost
                // a whole scanline of MO and the test is free.
                else if(sstate == SC_DONE || sstate == SC_IDLE
                        || fetch_budget == 0) state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase

            // ================= ISSUE PORT =================
            // The ONLY place a gfx fetch is launched. It runs in parallel with
            // S_PRIME/S_BLIT, so filling four channels costs no state cycles.
            // pump_want and sc_may_pf are mutually exclusive by construction
            // (sc_may_pf requires !pump_ready, pump_want requires pump_ready),
            // and this if/else makes that structural rather than argued.
            //
            // tx_f and fetch_budget are written HERE AND NOWHERE ELSE except
            // sprite start (S_FETCH: tx_f<=0), line start (S_SLIP1: budget) and
            // the line abort - all states in which pump_live is false. So they
            // stay single-writer, which is what let the scout be added without
            // a second budget accountant.
            if(iss_en) begin
                gaddr[ch_pick] <= iss_addr;
                greq[ch_pick]  <= ~greq[ch_pick];
                infl[ch_pick]  <= 1'b1;
            end
            // MODEPTH-1: record where it went. The pump writes the tile->channel
            // map; the scout writes the queue slot it prefetched for. These are
            // different registers in every case (a scout prefetch is blocked in
            // the pop cycle and a freshly pushed slot is never the prefetch
            // target), so the queue block below can safely have the last word.
            if(pump_want) tch_v[{tx_f[2:0], 1'b0} +: 2] <= ch_pick;
            if(iss_scout) begin
                if(sc_lane2) begin
                    q_pf2[sc_sel] <= 1'b1; q_ch2[sc_sel] <= ch_pick;
                end else begin
                    q_pf[sc_sel]  <= 1'b1; q_ch[sc_sel]  <= ch_pick;
                end
            end
            if(pump_want || pump_pref || pump_pref2) begin
                tx_f         <= tx_f + 4'd1;
                fetch_budget <= fetch_budget - 7'd1;
            end

            // ================= PARK QUEUE =================
            // One atomic update for both ends, so a push and a pop landing in
            // the same cycle cannot lose an entry or swap two. Push is always
            // at the tail and pop always at the head, which is what keeps the
            // blitter's sprite order identical to the scout's list walk order -
            // and therefore keeps first-write-wins handing every overlapped
            // pixel to the same sprite a depth-1 park did.
            // A pop slides every slot down one. A harvest landing in the same
            // cycle travels with its slot rather than being overwritten by the
            // pre-harvest copy.
            if(q_pop) begin
                for(qi = 0; qi < QDEPTH-1; qi = qi + 1) begin
                    q_link[qi] <= q_link[qi+1];  q_w3[qi]  <= q_w3[qi+1];
                    q_code[qi] <= q_code[qi+1];  q_row[qi] <= q_row[qi+1];
                    q_pf[qi]   <= q_pf[qi+1];    q_ch[qi]  <= q_ch[qi+1];
                    q_got[qi]  <= hv[qi+1] ? 1'b1      : q_got[qi+1];
                    q_dat[qi]  <= hv[qi+1] ? hv_dat[qi+1] : q_dat[qi+1];
                    // MOPF2-132: lane 2 travels with its slot, harvest included
                    q_pf2[qi]  <= q_pf2[qi+1];   q_ch2[qi] <= q_ch2[qi+1];
                    q_got2[qi] <= hv2[qi+1] ? 1'b1       : q_got2[qi+1];
                    q_dat2[qi] <= hv2[qi+1] ? hv_dat2[qi+1] : q_dat2[qi+1];
                end
            end
            // ...and the push lands at the tail AFTER that slide, so a push and
            // a pop in one cycle put the new entry behind everything already
            // queued. Order in equals order out, which is the property the
            // draw order depends on.
            if(q_push) begin
                q_link[q_tl] <= s_link;
                q_w3[q_tl]   <= s_w3;
                q_code[q_tl] <= q_new_code;
                q_row[q_tl]  <= s_ydiff[2:0];
                q_pf[q_tl]   <= 1'b0;
                q_got[q_tl]  <= 1'b0;
                q_pf2[q_tl]  <= 1'b0;    // MOPF2-132
                q_got2[q_tl] <= 1'b0;
            end
            if(q_push != q_pop)
                q_cnt <= q_push ? (q_cnt + 3'd1) : (q_cnt - 3'd1);
            end
        end
    end

endmodule
