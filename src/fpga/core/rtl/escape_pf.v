// escape_pf: the playfield pipeline, lifted VERBATIM out of core_top.v.
//
// WHY. core_top.v is compiled by NO simulation - it is mixed with VHDL and
// APF-specific ports, so nothing can reach this code. That blind spot is not
// academic: the left-edge strip absorbed TWO shipped fixes reasoned from the
// source with nothing able to contradict them, and the second provably cannot
// work (VID_H_BPORCH = 60 puts the line-start prime sixty clocks and eight
// phase-7 reloads before visible pixel 0). Same treatment escape_stain.v got:
// move the code unchanged so a bench drives the SHIPPED instance.
//
// THE EXTRACTION CHANGES NO BEHAVIOUR. The boundary was derived mechanically:
// of everything declared in the region, only pf_att, pf_pix and pf_vaddr are
// referenced outside it, plus the vg_* fetch registers. Region bounds were
// taken by ANCHOR - from the section comment to the `end` closing the
// `always @(*)` - after a first attempt cut mid-block and lost that `end`.
// Verify with CI: M10K delta 0 and timing unchanged.
`default_nettype none

module escape_pf #(
    parameter [9:0] VID_V_BPORCH = 10'd0,
    parameter [9:0] VID_V_ACTIVE = 10'd0,
    // PFBW-122: fetch lead in pixels. Any MULTIPLE OF 8 leaves pf_x2[2:0] -
    // the display fine phase - bit-identical, so only the coarse column moves.
    parameter [8:0]   LEAD = 9'd16,
    // PFBW-122: playfield fetch channels, 2 or 4. Motion objects already have
    // 4; the playfield had 2, and the drain rate is what the strip measurement
    // says is binding. Note LEAD and NCH only help TOGETHER: with a 2-cell
    // lead there are never more than ~2 requests outstanding, so extra
    // channels have nothing to drain - which is why raising LEAD alone did
    // nothing when it was tried on its own.
    parameter integer NCH  = 2,
    // PFBW-122: the line-start resync sets rp = wp, i.e. ZERO ring buffering -
    // the slot being read is the one just written. Backing rp off by N gives
    // the fetch N cells of slack, which is what LEAD alone could not deliver.
    parameter [1:0]   RP_OFF = 2'd0
) (
    input  wire        clk,
    input  wire        core_reset_n,
    input  wire [9:0]  vis_x,
    input  wire [9:0]  visible_x,
    input  wire [9:0]  visible_y,
    input  wire [9:0]  x_count,
    input  wire [9:0]  y_count,
    input  wire [8:0]  xscroll,
    input  wire [8:0]  yscroll,
    input  wire [4:0]  vpshift_s,
    input  wire        m_pfmap,
    output reg  [11:0] pf_vaddr,
    input  wire [15:0] pf_vdata,
    input  wire [15:0] pfx_vdata,
    output reg  [23:0] vg_addrA_px,
    output reg  [23:0] vg_addrB_px,
    output reg  [23:0] vg_addrC_px,
    output reg  [23:0] vg_addrD_px,
    output reg         vg_reqA_px,
    output reg         vg_reqB_px,
    output reg         vg_reqC_px,
    output reg         vg_reqD_px,
    input  wire [31:0] vg_dataA,
    input  wire [31:0] vg_dataB,
    input  wire [31:0] vg_dataC,
    input  wire [31:0] vg_dataD,
    input  wire        vg_doneA_s,
    input  wire        vg_doneB_s,
    input  wire        vg_doneC_s,
    input  wire        vg_doneD_s,
    output wire [3:0]  pf_pix_o,
    output wire [4:0]  pf_att_o
);
    reg  [3:0] pf_pix;
    // The body is a verbatim lift and still says clk_sys_7159; alias rather
    // than rename so a diff against the old core_top region stays readable.
    wire clk_sys_7159 = clk;

    // ---------------- playfield pipeline (pixel domain)
    // Prefetch 2 cells ahead: map lookup at phase 0, SDRAM gfx request at phase 3
    // (chunky 4bpp row = 2 words via the priority video channel), show via
    // fetch->show buffering at cell boundaries.
    // (now a port) reg  [11:0] pf_vaddr;
    // (now a port) wire [15:0] pf_vdata, pfx_vdata;
    // (now a port) wire [8:0]  xscroll, yscroll;

    wire [8:0] pf_y   = visible_y[8:0] + yscroll;           // scrolled row (mod 512)
    // LANE3p: world X alignment - sim-proven correct at +32 (map col lookup
    // only; fetch timing untouched). Menu slider fine-tunes: +16+vpshift.
    // PFBW-122: fetch lead is a parameter. Any multiple of 8 leaves
    // pf_x2[2:0] - the DISPLAY fine phase - bit-identical, so only the coarse
    // column (map lookup, hence the fetch) moves earlier.
    wire [8:0] pf_x2  = vis_x[8:0] + LEAD + {4'd0, vpshift_s} + xscroll;   // v72: fixed 3 ahead again -
                                                        // the runtime depth mux sent
                                                        // the fitter into a 90-minute
                                                        // spiral twice; slider deferred
    reg  [4:0] pfcol_q0, pfcol_q1, pfcol_q2, pfcol_q3, pfcol_show;  // {flip, color[3:0]}
    reg  [31:0] pf_next;      // SDSCHED-84: the FOLLOWING cell's row word
    reg  [4:0]  pfcol_next;   // ...and its attributes (fine-scroll window)
    reg  [3:0] pfcode_q0, pfcode_q1, pfcode_q2, pfcode_q3, pfcode_show; // v66 map debug
    // LANE3i: two fetches in flight (A/B ping-pong) - see channel decls at
    // the sdram-domain end. inflA/inflB = per-channel outstanding flags.
    reg        inflA = 1'b0, inflB = 1'b0, inflC = 1'b0, inflD = 1'b0;
    reg  [31:0] pf_fetch, pf_show;
    // v81b: SLOT-ADDRESSED RING replaces the shift pipe. A late completion
    // in the shift design landed in the NEXT cell's slot - the alternating
    // correct/wrong columns ('scrunch') seen when sprite fetches interleave.
    // Each fetch now delivers into the slot for ITS OWN cell whenever it
    // completes; rp re-syncs to wp at every line start (-4 = 0 mod 4).
    reg  [31:0] pfring0, pfring1, pfring2, pfring3;
    reg  [1:0]  pf_wp, pf_inflA, pf_inflB, pf_inflC, pf_inflD, pf_rp;
    // v84: request queue decouples issue cadence from channel latency.
    // The old unconditional toggle CANCELLED an unserved request when the
    // next cell's phase arrived (two toggles = no net change) - each burst
    // of MO/CPU/scrub traffic vaporized a fetch = trailing ghost columns.
    reg  [23:0] pfq_addr0, pfq_addr1, pfq_addr2, pfq_addr3;
    reg  [1:0]  pfq_slot0, pfq_slot1, pfq_slot2, pfq_slot3;
    reg  [2:0]  pfq_count;
    reg  [1:0]  pfq_wr, pfq_rd;
    reg  vg_doneA_last, vg_doneB_last, vg_doneC_last, vg_doneD_last;

    always @(posedge clk_sys_7159) begin
        case(vis_x[2:0])
            3'd0: begin
                // LANE3j: the pf map is COLUMN-MAJOR scanned (MAME SCAN_COLS
                // semantics; proven empirically - rendering the live MAME map
                // dump with idx=col*64+row reproduces the attract art pixel-
                // exact, row-major produces the on-device diagonal hash).
                // Our row-major read transposed every map lookup since v13:
                // symmetric tiles (borders/pillars) hid it for 90+ builds.
                pf_vaddr <= {pf_x2[8:3], pf_y[8:3]};        // map col*64 + row
                // cell boundary: advance pipelines
                // show the slot for THIS cell; a still-pending fetch shows
                // that slot's previous-line row (localized, non-spreading)
                pfcol_q3   <= pfcol_q2;
                pfcol_q2   <= pfcol_q1;
                pfcol_q1   <= pfcol_q0;
                pfcode_q3  <= pfcode_q2;
                pfcode_q2  <= pfcode_q1;
                pfcode_q1  <= pfcode_q0;
            end
            3'd3: begin
                // enqueue this cell's fetch (issue side drains when free)
                if(y_count >= VID_V_BPORCH - 2 && y_count < VID_V_BPORCH + VID_V_ACTIVE
                   && pfq_count != 3'd4) begin
                    case(pfq_wr)
                        2'd0: begin pfq_addr0 <= 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0}; pfq_slot0 <= pf_wp; end
                        2'd1: begin pfq_addr1 <= 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0}; pfq_slot1 <= pf_wp; end
                        2'd2: begin pfq_addr2 <= 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0}; pfq_slot2 <= pf_wp; end
                        default: begin pfq_addr3 <= 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0}; pfq_slot3 <= pf_wp; end
                    endcase
                    pfq_wr    <= pfq_wr + 2'd1;
                    pfq_count <= pfq_count + 3'd1;
                    pf_wp     <= pf_wp + 2'd1;
                end
                pfcol_q0   <= {pf_vdata[15], pfx_vdata[11:8]};
                pfcode_q0  <= pf_vdata[3:0] ^ pf_vdata[7:4] ^ pf_vdata[11:8];
            end
            3'd7: begin
                // LANE3k: show-registers load one pixel EARLY (phase 7) so
                // they are fresh when pixel 0 samples them. Loading at phase
                // 0 left pixel 0 rendering the PREVIOUS cell's word - the
                // 1px vertical tears at every cell boundary in detailed art
                // (proven in the real-data art sim: 100% of mismatches were
                // pixel-in-cell 0 showing the left cell's first pixel).
                case(pf_rp)
                    2'd0: pf_show <= pfring0;  2'd1: pf_show <= pfring1;
                    2'd2: pf_show <= pfring2;  default: pf_show <= pfring3;
                endcase
                // SDSCHED-84: also stage the FOLLOWING cell - with a nonzero
                // horizontal fine scroll the last (xscroll&7) pixels of each
                // 8px window belong to the next tile over.
                case(pf_rp + 2'd1)
                    2'd0: pf_next <= pfring0;  2'd1: pf_next <= pfring1;
                    2'd2: pf_next <= pfring2;  default: pf_next <= pfring3;
                endcase
                pf_rp <= pf_rp + 2'd1;
                pfcol_show <= pfcol_q3;
                pfcol_next <= pfcol_q2;
                pfcode_show<= pfcode_q3;
            end
            default: ;
        endcase
        // completions deliver into each in-flight request's own slot; the
        // two channels are independent (slot tags differ for consecutive
        // fetches, so same-cycle delivery never collides on a ring slot)
        vg_doneA_last <= vg_doneA_s;
        if(vg_doneA_s != vg_doneA_last) begin
            case(pf_inflA)
                2'd0: pfring0 <= vg_dataA;  2'd1: pfring1 <= vg_dataA;
                2'd2: pfring2 <= vg_dataA;  default: pfring3 <= vg_dataA;
            endcase
            inflA <= 1'b0;
        end
        // PFBW-122: channels C/D, present only when NCH==4. With NCH==2 the
        // generate below ties their requests off and nothing ever completes,
        // so these branches are dead and the netlist matches the 2-channel
        // build.
        vg_doneC_last <= vg_doneC_s;
        if(NCH == 4 && vg_doneC_s != vg_doneC_last) begin
            case(pf_inflC)
                2'd0: pfring0 <= vg_dataC;  2'd1: pfring1 <= vg_dataC;
                2'd2: pfring2 <= vg_dataC;  default: pfring3 <= vg_dataC;
            endcase
            inflC <= 1'b0;
        end
        vg_doneD_last <= vg_doneD_s;
        if(NCH == 4 && vg_doneD_s != vg_doneD_last) begin
            case(pf_inflD)
                2'd0: pfring0 <= vg_dataD;  2'd1: pfring1 <= vg_dataD;
                2'd2: pfring2 <= vg_dataD;  default: pfring3 <= vg_dataD;
            endcase
            inflD <= 1'b0;
        end
        vg_doneB_last <= vg_doneB_s;
        if(vg_doneB_s != vg_doneB_last) begin
            case(pf_inflB)
                2'd0: pfring0 <= vg_dataB;  2'd1: pfring1 <= vg_dataB;
                2'd2: pfring2 <= vg_dataB;  default: pfring3 <= vg_dataB;
            endcase
            inflB <= 1'b0;
        end
        // issue side: drain the queue into whichever channel is free (one
        // issue per pixel clock; the old wait-for-MO gate is gone - the
        // sdram-domain priority chain arbitrates PF vs MO now)
        if(pfq_count != 3'd0) begin
            if(!inflA && !(vg_doneA_s != vg_doneA_last)) begin
                case(pfq_rd)
                    2'd0: begin vg_addrA_px <= pfq_addr0; pf_inflA <= pfq_slot0; end
                    2'd1: begin vg_addrA_px <= pfq_addr1; pf_inflA <= pfq_slot1; end
                    2'd2: begin vg_addrA_px <= pfq_addr2; pf_inflA <= pfq_slot2; end
                    default: begin vg_addrA_px <= pfq_addr3; pf_inflA <= pfq_slot3; end
                endcase
                vg_reqA_px <= ~vg_reqA_px;
                inflA      <= 1'b1;
                pfq_rd     <= pfq_rd + 2'd1;
                pfq_count  <= pfq_count - 3'd1;
            end else if(!inflB && !(vg_doneB_s != vg_doneB_last)) begin
                case(pfq_rd)
                    2'd0: begin vg_addrB_px <= pfq_addr0; pf_inflB <= pfq_slot0; end
                    2'd1: begin vg_addrB_px <= pfq_addr1; pf_inflB <= pfq_slot1; end
                    2'd2: begin vg_addrB_px <= pfq_addr2; pf_inflB <= pfq_slot2; end
                    default: begin vg_addrB_px <= pfq_addr3; pf_inflB <= pfq_slot3; end
                endcase
                vg_reqB_px <= ~vg_reqB_px;
                inflB      <= 1'b1;
                pfq_rd     <= pfq_rd + 2'd1;
                pfq_count  <= pfq_count - 3'd1;
            end else if(NCH == 4 && !inflC && !(vg_doneC_s != vg_doneC_last)) begin
                case(pfq_rd)
                    2'd0: begin vg_addrC_px <= pfq_addr0; pf_inflC <= pfq_slot0; end
                    2'd1: begin vg_addrC_px <= pfq_addr1; pf_inflC <= pfq_slot1; end
                    2'd2: begin vg_addrC_px <= pfq_addr2; pf_inflC <= pfq_slot2; end
                    default: begin vg_addrC_px <= pfq_addr3; pf_inflC <= pfq_slot3; end
                endcase
                vg_reqC_px <= ~vg_reqC_px;
                inflC      <= 1'b1;
                pfq_rd     <= pfq_rd + 2'd1;
                pfq_count  <= pfq_count - 3'd1;
            end else if(NCH == 4 && !inflD && !(vg_doneD_s != vg_doneD_last)) begin
                case(pfq_rd)
                    2'd0: begin vg_addrD_px <= pfq_addr0; pf_inflD <= pfq_slot0; end
                    2'd1: begin vg_addrD_px <= pfq_addr1; pf_inflD <= pfq_slot1; end
                    2'd2: begin vg_addrD_px <= pfq_addr2; pf_inflD <= pfq_slot2; end
                    default: begin vg_addrD_px <= pfq_addr3; pf_inflD <= pfq_slot3; end
                endcase
                vg_reqD_px <= ~vg_reqD_px;
                inflD      <= 1'b1;
                pfq_rd     <= pfq_rd + 2'd1;
                pfq_count  <= pfq_count - 3'd1;
            end
        end
        // line-start re-sync (lead 4 = 0 mod 4) + queue flush
        if(x_count == 10'd0) begin
            pf_rp <= pf_wp - RP_OFF;   // PFBW-122
            pfq_count <= 3'd0; pfq_rd <= pfq_wr;
            // PFLINE-116: PRIME the show registers here too.
            //
            // The bug: pf_show/pf_next were loaded ONLY in the vis_x[2:0]==7
            // branch, so from line start until the first phase-7 they still
            // held whatever was staged at the PREVIOUS line's last cell - and
            // worse, staged off the pre-resync pf_rp, i.e. a slot that is not
            // this line's first cell at all. The first pixels of every line
            // were therefore served from a stale, unrelated ring slot.
            //
            // Measured on device (build 113 capture, transition screen at
            // t=17.0): native columns 0-1 carried the PREVIOUS SCENE's
            // playfield - red wall and grey floor over a flat navy map screen
            // - 100% non-navy in cols 0-1 against 0% in cols 2-9. Scene-level
            // staleness, not one line's residue, which is exactly what an
            // unprimed register that only reloads mid-cell produces.
            //
            // It also ate sprites: anything drawn in those columns was painted
            // over by the stale playfield, which reads as a motion object
            // "cut off before the draw window" while the floor still renders
            // to its left.
            //
            // The load mirrors the phase-7 case exactly, but off the value
            // pf_rp is being resynced TO (pf_wp), not the old pf_rp - reading
            // the register here would give the pre-assignment value.
            // PFLINE reverted (was 116 and 117). Two attempts primed
            // pf_show/pf_next here; neither was verified and the second
            // provably cannot work:
            //
            //   VID_H_BPORCH = 60, so x_count==0 is SIXTY clocks before
            //   visible pixel 0, and vis_x[2:0] hits 7 EIGHT times in that gap
            //   (x_count = 3,11,19,27,35,43,51,59). Each re-runs the phase-7
            //   load and advances pf_rp, so anything primed here is
            //   overwritten eight times before pixel 0 is drawn.
            //
            // Build 116 nevertheless CHANGED the artifact measurably on device
            // (cols 0-1: 62-69 distinct colours -> exactly one, sd 0.0), so the
            // model both fixes came from is wrong. What IS confirmed is the
            // shape: the strip is 8 - (fine scroll & 7) native pixels, 1..8
            // varying with horizontal scroll - measured 2 on a map screen and
            // 3 in gameplay. See docs/MO_TILE_HOLES.md.
        end

        // ---- PFRESET-111: the playfield fetch channel MUST reset with the
        // core. Backport of PFRESET-107 (dcd1196) from the MiSTer port, where
        // this exact omission rendered the playfield as a flat fill on real
        // DE10-Nano hardware while sprites and alphanumerics stayed perfect.
        //
        // The mechanism, which is platform-independent:
        //
        //   * x_count/y_count and therefore this whole block free-run from
        //     power-on - they are held only by the Pocket-level reset_n
        //     (:538), never by core_reset_n. So this block keeps enqueueing
        //     cells and issuing fetches while the core is held in reset.
        //   * a fetch issued here sets inflA (or inflB) and toggles
        //     vg_reqA_px. inflA is cleared in exactly ONE place - the
        //     completion edge at :2325 - and nowhere else.
        //   * meanwhile the SDSCHED-75 reset resync at :1708-1716 runs on
        //     EVERY clk_sdram edge that core_rstn_sd is low and does
        //     "vg_reqA_last <= vg_reqA_s", which RETIRES that pending request
        //     edge without ever completing it. It is the last writer of
        //     vg_reqA_last in that always block, so it also overrides the CRAM
        //     read-start chain at :1508 in a same-cycle collision - but only
        //     the resync's value is written, and the chain's cram_read_en /
        //     cvg_ph side effects still happen, so a fetch the chain DID pick
        //     up still completes. The lost ones are the fetches the chain
        //     could not start that cycle (cq_n != 0, cram_busy, cvg_ph != 0,
        //     or chk_state != 4'd10) - the chain gets exactly one cycle to
        //     catch each edge before the resync eats it.
        //   * reset releases with inflA (and/or inflB) stuck at 1 and
        //     vg_reqA_last == vg_reqA_s. The issue side above requires
        //     !inflA / !inflB, so that channel never toggles a request again
        //     and the arbiter never sees a pending edge again. The channel is
        //     wedged for the rest of the session: one channel wedged silently
        //     degrades the A/B ping-pong to the one-in-flight design that
        //     PF_SINGLE_CH exists to reject; both wedged leaves pfring0..3 at
        //     their power-on zeros and every tile decodes to pixel index 0.
        //
        // The resync is CORRECT for the motion objects: escape_mob zeroes its
        // own request toggles and in-flight state under reset (:646-658), so
        // the tracker there is following a real reset, not eating a real
        // request. The playfield was the one client with no reset at all.
        //
        // Why this has not visibly failed on Pocket, MEASURED rather than
        // assumed (sim/run_pf_reset_tb.sh, three scenarios):
        //
        //   * reset with the CRAM controller IDLE: no loss. 456 fetches
        //     issued across an 8-line reset, all 456 completed. The
        //     read-start chain is not gated by core_rstn_sd the way the
        //     MiSTer port's pf_pend_q is, so it catches every edge in the one
        //     cycle it has. This is the case a bare menu soft reset hits, and
        //     it is why the playfield has survived 35+ builds.
        //   * reset with chk_state != 4'd10: wedges both channels every time.
        //   * reset with chk_state == 4'd10 AND the download-mirror drain
        //     running (cq_n != 0 blocks a PF read start): wedges both channels
        //     - i.e. any dataslot re-download, which drops
        //     dataslot_allcomplete and therefore core_reset_n while chk_state
        //     is already 4'd10 and the mirror queue is busy.
        //
        // So the exposure is narrow, not absent, and its narrow edge is sharp:
        // TWO lost requests kill the layer, and losing only one silently
        // reverts the design to the one-in-flight arrangement that
        // PF_SINGLE_CH exists to reject. docs/PIPELINES.md already flags a
        // toggle-handshake channel with no reset as "a latent wedge on every
        // platform"; this removes the dependence on that margin.
        //
        // The fix is to give this channel the same reset escape_mob gives its
        // own: while reset is held the request toggles sit at 0, the resync
        // tracks 0, and release starts both sides in agreement with nothing in
        // flight. Registers only - no new storage, no change to the SDRAM
        // grant path. Demonstrated failing-then-fixed in sim/tb/tb_pf_reset.v.
        if(!core_reset_n) begin
            vg_reqA_px <= 1'b0;  vg_reqB_px <= 1'b0;
            inflA      <= 1'b0;  inflB      <= 1'b0;
            pfq_count  <= 3'd0;  pfq_wr     <= 2'd0;  pfq_rd <= 2'd0;
            pf_wp      <= 2'd0;  pf_rp      <= 2'd0;
        end
    end

    // pixel extraction: chunky nibbles px0..px7 across the 32-bit row.
    // SDSCHED-84 HORIZONTAL FINE SCROLL: the pixel index is the SCROLLED
    // fine X (pf_x2[2:0]), not raw screen X - the coarse column already
    // came from pf_x2[8:3], but the sub-tile phase was dropped, quantizing
    // all horizontal motion to 8px tile lurches (device 60fps capture:
    // dx = 0,0,...,+8 vs MAME's smooth +-1..3; vertical was always fine
    // because pf_y feeds both lookup and row). When the fine phase wraps
    // (pf_x2[2:0] < visible_x[2:0]) the pixel lives in the NEXT cell.
    wire        pf_cross = pf_x2[2:0] < visible_x[2:0];
    wire [31:0] pf_word  = pf_cross ? pf_next    : pf_show;
    wire [4:0]  pf_att   = pf_cross ? pfcol_next : pfcol_show;
    wire [2:0] pf_n   = pf_att[4] ? (3'd7 - pf_x2[2:0]) : pf_x2[2:0];
    // (now a port) reg  [3:0] pf_pix;
    always @(*) begin
        if(m_pfmap) begin
            pf_pix = pfcode_show;    // v66 map-debug: flat color per tile code
        end else
        case(pf_n)
            3'd0: pf_pix = pf_word[31:28]; 3'd1: pf_pix = pf_word[27:24];
            3'd2: pf_pix = pf_word[23:20]; 3'd3: pf_pix = pf_word[19:16];
            3'd4: pf_pix = pf_word[15:12]; 3'd5: pf_pix = pf_word[11:8];
            3'd6: pf_pix = pf_word[7:4];   default: pf_pix = pf_word[3:0];
        endcase
    end

    // Assigned at the end: pf_att is declared partway down the body and
    // `default_nettype none` rejects a forward reference to it.
    assign pf_pix_o = pf_pix;
    assign pf_att_o = pf_att;
endmodule

`default_nettype wire
