// escape_mo_cache: a shared tile-row cache in front of the motion-object gfx
// fetch channels.
//
// WHY. The tile-hole artifact (docs/MO_TILE_HOLES.md) appears at PEAK sprite
// load - an explosion, or a crowd - and peak load on this game means MANY
// COPIES OF THE SAME SPRITE. A dozen identical robots on one scanline fetch
// the identical tile row a dozen times, each one a separate SDRAM transaction
// competing with the CPU and the playfield for a bus where the MO engine is
// the lowest-priority client. The demand peaks exactly when the supply is
// worst.
//
// A cache attacks that directly, and it is the only lever whose benefit GROWS
// with sprite density. Raising MO priority just moves the shortage onto the
// CPU; a deeper park queue is already measured not to help (escape_mob.v:380 -
// 4, 5 and 6 slots reproduce the 3-slot frame to the pixel).
//
// WHERE IT SITS. Between escape_mob's gfx ports and whatever serves them, with
// the SAME interface on both sides, so escape_mob's state machine is not
// touched at all. The MO side cannot tell a hit from a very fast miss.
//
//     escape_mob  <-- req/addr --> [ this ] <-- req/addr --> SDRAM fetcher
//                 <-- done/data -->        <-- done/data --
//
// PROTOCOL. req and done are TOGGLES, one bit per channel, matching the
// existing ports: the requester flips req[c], the server flips done[c] when
// data[c] is valid. That is preserved exactly, including on a hit - a hit
// flips done[c] one clock later, which is simply the fastest possible miss.
//
// M10K. The fit is at 299/308 blocks, so this must NOT infer block RAM. The
// storage is `ramstyle = "MLAB"`, i.e. distributed LUT RAM. ENTRIES is a
// parameter so the size can be traded against the fit, and the tile-hole gate
// scores each choice (sim/tools/mob_vs_mame.py, tb_mob GFX_JIT=48/96).
//
// COHERENCE. Tile graphics are read-only ROM image data for the life of a
// frame, so there is no invalidation problem to solve. The cache is flushed on
// reset only.
`default_nettype none

module escape_mo_cache #(
    parameter integer ENTRIES  = 32,     // must be a power of two
    parameter integer IDXBITS  = 5,      // log2(ENTRIES)
    parameter integer ADDRBITS = 24
) (
    input  wire         clk,
    input  wire         reset_n,

    // ---- motion-object side (looks like the memory to escape_mob)
    input  wire [3:0]   mo_req,          // toggle per channel
    input  wire [95:0]  mo_addr,         // 4 x 24
    output reg  [3:0]   mo_done,         // toggle per channel
    output reg  [127:0] mo_data,         // 4 x 32

    // ---- memory side (looks like escape_mob to the fetcher)
    output reg  [3:0]   mem_req,         // toggle per channel
    output reg  [95:0]  mem_addr,
    input  wire [3:0]   mem_done,        // toggle per channel
    input  wire [127:0] mem_data,

    // ---- instrumentation: saturating, for the HUD and for benches
    output reg  [15:0]  hit_cnt,
    output reg  [15:0]  miss_cnt
);
    localparam integer TAGBITS = ADDRBITS - IDXBITS;

    // Storage. MLAB, not M10K - see the header note about the 299/308 fit.
    (* ramstyle = "MLAB" *) reg [31:0]        c_data [0:ENTRIES-1];
    (* ramstyle = "MLAB" *) reg [TAGBITS-1:0] c_tag  [0:ENTRIES-1];
    reg [ENTRIES-1:0] c_val;

    reg [3:0] mo_req_d, mem_done_d;

    // Per-channel in-flight bookkeeping for misses.
    reg [ADDRBITS-1:0] pend_addr [0:3];
    reg [3:0]          pend_busy;

    integer i;
    genvar gc;

    // Combinational lookup per channel, on the address presented with the
    // request edge.
    wire [3:0] req_edge = mo_req ^ mo_req_d;
    wire [3:0] don_edge = mem_done ^ mem_done_d;

    // A single fill port keeps this to one write per clock. Fills are rare
    // relative to the clock, and a channel whose fill loses arbitration simply
    // completes without populating the cache - correctness never depends on a
    // fill landing.
    reg               fill_en;
    reg [IDXBITS-1:0] fill_idx;
    reg [TAGBITS-1:0] fill_tag;
    reg [31:0]        fill_dat;

    always @(posedge clk) begin
        if(!reset_n) begin
            mo_req_d   <= 4'd0;
            mem_done_d <= 4'd0;
            mo_done    <= 4'd0;
            mem_req    <= 4'd0;
            mo_data    <= 128'd0;
            mem_addr   <= 96'd0;
            pend_busy  <= 4'd0;
            c_val      <= {ENTRIES{1'b0}};
            hit_cnt    <= 16'd0;
            miss_cnt   <= 16'd0;
            fill_en    <= 1'b0;
            for(i = 0; i < 4; i = i + 1) pend_addr[i] <= {ADDRBITS{1'b0}};
        end else begin
            mo_req_d   <= mo_req;
            mem_done_d <= mem_done;
            fill_en    <= 1'b0;

            // ---- new requests from the MO engine
            for(i = 0; i < 4; i = i + 1) begin
                if(req_edge[i] && !pend_busy[i]) begin
                    if(c_val[mo_addr[i*24 +: IDXBITS]] &&
                       c_tag[mo_addr[i*24 +: IDXBITS]] ==
                           mo_addr[i*24 + IDXBITS +: TAGBITS]) begin
                        // HIT: answer next clock, no bus transaction at all.
                        mo_data[i*32 +: 32] <=
                            c_data[mo_addr[i*24 +: IDXBITS]];
                        mo_done[i] <= ~mo_done[i];
                        if(hit_cnt != 16'hFFFF) hit_cnt <= hit_cnt + 16'd1;
                    end else begin
                        // MISS: forward it and remember what we asked for, so
                        // the completion can be filed under the right tag.
                        pend_addr[i] <= mo_addr[i*24 +: ADDRBITS];
                        pend_busy[i] <= 1'b1;
                        mem_addr[i*24 +: ADDRBITS] <= mo_addr[i*24 +: ADDRBITS];
                        mem_req[i] <= ~mem_req[i];
                        if(miss_cnt != 16'hFFFF) miss_cnt <= miss_cnt + 16'd1;
                    end
                end
            end

            // ---- completions from memory
            for(i = 0; i < 4; i = i + 1) begin
                if(don_edge[i] && pend_busy[i]) begin
                    mo_data[i*32 +: 32] <= mem_data[i*32 +: 32];
                    mo_done[i]   <= ~mo_done[i];
                    pend_busy[i] <= 1'b0;
                    // Populate, if the single fill port is free this clock.
                    if(!fill_en) begin
                        fill_en  <= 1'b1;
                        fill_idx <= pend_addr[i][IDXBITS-1:0];
                        fill_tag <= pend_addr[i][ADDRBITS-1:IDXBITS];
                        fill_dat <= mem_data[i*32 +: 32];
                    end
                end
            end

            if(fill_en) begin
                c_data[fill_idx] <= fill_dat;
                c_tag [fill_idx] <= fill_tag;
                c_val [fill_idx] <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
