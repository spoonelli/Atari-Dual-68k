// tb_pf_cram: art-in-sim for the CRAM playfield path (LANE3i validation).
//
// Instantiates the REAL third_party psram.sv controller against a behavioral
// 70ns ADmux PSRAM chip model, and replicates core_top's pixel-domain PF
// pipeline (queue -> A/B ping-pong channels -> slot ring -> extraction) plus
// the sdram-domain unified CRAM service chain, at the real 5:1 clock ratio
// (35.795455MHz service / 7.159091MHz pixel). A competing CRAM client is
// injected at MO_BURST 2-read fetches per 8-pixel slot, modelling the
// drain/fill and forensics traffic the playfield shares that controller with.
//
// The CRAM model is preloaded with a synthetic pattern where word[a] is a
// function of the address, and the map holds a distinct tile in every cell -
// any wrong-address, wrong-pair, stale-slot or latency bug lands visibly.
// Each visible pixel's extracted nibble is dumped to pf_pixels.txt; Python
// (sim/tools/check_pf_frame.py) computes the expected frame and reports
// mismatches PER COLUMN - the accumulating-rightward signature that convicted
// the one-in-flight design on hardware (build 39) shows up directly here.
//
// Run:  ./sim/run_pf_tb.sh          (docker iverilog wrapper)
//
// ---------------------------------------------------------------------------
// PFSIM-113: this rig had NEVER passed since it was created in 3d03b63. Three
// independent faults, all of them in the RIG, none in the shipped RTL:
//
//   (1) CHECKER PATTERN. check_pf_frame.py modelled the CRAM contents as
//       low16(a * 2654435761) while the chip model here filled cmem[k]=k[15:0].
//       Resolved in favour of the hash - see CRAM FILL PATTERN below.
//   (2) CHECKER MAP LAYOUT. check_pf_frame.py computed the map index
//       row-major, (ycell<<6)|xcell. The RTL has been COLUMN-major,
//       (xcell<<6)|ycell, since LANE3j - i.e. the checker was written against
//       the pre-LANE3j convention that LANE3j's own comment calls out as the
//       bug that "transposed every map lookup since v13".
//   (3) CLOCK RATIO (this file). The service clock was 85.909MHz with a /12
//       divider. The real core runs psram on clk_sdram = 35.795455MHz against
//       clk_sys_7159 = 7.159091MHz - a 5:1 same-PLL ratio (see CLKFIX-106 at
//       core_top.v:1080 and psram #(.CLOCK_SPEED(35.795455)) at :1088).
//       The rig therefore handed the PF path ~2.4x the service bandwidth the
//       hardware has. Channel A alone always retired before the next cell's
//       request arrived, so channel B was NEVER armed and the entire
//       two-in-flight A/B ping-pong - the only thing this rig exists to
//       validate - went unexercised (issueB=0 in every run ever recorded).
//
// (2) is why the offset search found nothing; (3) plus the arbiter/stimulus
// faults noted at the interference generator and the read-start chain below
// are why issueB stayed 0.
//
// inflA=1 in the end-of-run debug line was NEVER a stuck flag, and this rig is
// not an instance of the PFRESET-107 no-reset failure. doneA is counted in the
// sdram domain while inflA is cleared in the pixel domain a CDC stage later,
// so inflA=1 alongside issueA==doneA is the expected skew at an arbitrary
// sampling instant. It is also just a snapshot: with the rig fixed, inflA is
// observed both set and clear across the run and the queue keeps draining.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_pf_cram;
    parameter SINGLE_CH = 0;   // 1 = old one-in-flight design (control run)
    parameter REAL_DATA = 0;   // 1 = load real gfx (cram_words.hex) + real map (pf_map.hex)
    // Competing-CRAM-client burst length: EXTRA 2-word pairs the competitor
    // keeps the controller for after the first, once granted (so 1 = two
    // pairs = four reads per grant).
    //
    // PFSIM-113 - how this value was chosen, since "the number that makes the
    // gate pass" is exactly the wrong way to pick it. The operating point is
    // the HIGHEST contention at which the design's own flow control is not
    // overrun, i.e. at which every enqueued cell still gets issued and none is
    // dropped at the queue. That is an objective criterion, and the checker
    // enforces it directly (issueA+issueB must equal the enqueued-cell count),
    // so it cannot be quietly detuned later. Measured, dumped-frame counts:
    //
    //     MO_BURST   issueA   issueB   issueA+issueB   (13794 enqueued)
    //        1        9773     4021       13794   <- no drops, B armed 29%
    //        2        9579     2432       12011   <- queue overflowing
    //        3        7749     2546       10295   <- queue overflowing
    //        4        6954        3        6957   <- queue overflowing
    //        6        4675     4558        9233   <- queue overflowing
    //
    // At 2 and above the PF queue drops fetches, and the mismatches that
    // follow are raw starvation rather than anything about the A/B pair, so
    // they would not be attributable evidence either way. 1 is the strongest
    // legitimate stress: it delays enough PF fetches past their 8-pixel cell
    // deadline to route 29% of them through channel B.
    //
    // PFRESET-111 - the issueB=3 at MO_BURST=4 is NOT a wedged channel.
    // That column reads like the PFRESET-111 signature (a channel that stops
    // being used for the rest of the run) so it was checked directly rather
    // than assumed: at MO_BURST=4 the frame line reports
    // "issueA=6954 issueB=3 doneA=6954 doneB=3" - every B issue COMPLETED, so
    // inflB was never stuck, and the @2ms snapshot shows inflA=1 inflB=1, so B
    // is reachable. B is simply almost never ARMED.
    //
    // That follows from the issue arm's shape (core_top.v:2339): B is taken
    // only when a queue entry is ready on a pixel clock where A is ALREADY in
    // flight. So issueB measures a phase relationship between the competitor's
    // grant period and the 8-pixel cell cadence, not a rate - and a phase
    // relationship is non-monotonic in burst length by construction. The
    // 4021 -> 2432 -> 2546 -> 3 -> 4558 sequence is a beat, not a defect, and
    // every point in it except the first is inside the region the checker
    // already rejects as unattributable (STIMULUS ERROR, queue overflowed).
    // Nothing to fix in the RTL; recorded so the next reader does not have to
    // re-derive it.
    parameter MO_BURST  = 1;
    // ---------------- clocks: 35.795455MHz service, 7.159091MHz pixel (5:1)
    // These are mf_pllbase siblings on hardware (outclk_2 and the 7.159 core
    // clock), so their edges are phase-locked. Both are derived here from one
    // 2x master so the two derived clocks always update in the same NBA region
    // and downstream sampling is deterministic - no same-timestep clock race.
    reg clk2x = 0;
    always #6.984127 clk2x = ~clk2x;        // 71.590909MHz, 13.968254ns period
    reg [2:0] pdiv = 0;
    reg clk_sd = 0;                          // 35.795455MHz  (was clk85)
    reg clk_px = 0;                          //  7.159091MHz
    always @(posedge clk2x) begin
        clk_sd <= ~clk_sd;                   // /2
        if(pdiv == 3'd4) begin pdiv <= 0; clk_px <= ~clk_px; end
        else pdiv <= pdiv + 3'd1;            // /10  => clk_sd/clk_px = 5
    end

    // ---------------- video counters (copied semantics from core_top)
    localparam VID_V_BPORCH = 'd12;
    localparam VID_V_ACTIVE = 'd240;
    localparam VID_V_TOTAL  = 'd262;
    localparam VID_H_BPORCH = 'd60;
    localparam VID_H_ACTIVE = 'd336;
    localparam VID_H_TOTAL  = 'd456;
    reg [9:0] x_count = 0, y_count = 0;
    always @(posedge clk_px) begin
        x_count <= x_count + 1'b1;
        if(x_count == VID_H_TOTAL-1) begin
            x_count <= 0;
            y_count <= y_count + 1'b1;
            if(y_count == VID_V_TOTAL-1) y_count <= 0;
        end
    end
    wire [9:0] visible_x = x_count - VID_H_BPORCH;
    wire [9:0] visible_y = y_count - VID_V_BPORCH;
    wire [9:0] vis_x     = x_count - VID_H_BPORCH;

    // ---------------- PSRAM chip model: async ADmux, 70ns access
    wire [21:16] cram0_a;
    wire [15:0]  cram0_dq;
    wire         cram0_wait;
    wire         cram0_clk, cram0_adv_n, cram0_cre;
    wire         cram0_ce0_n, cram0_ce1_n, cram0_oe_n, cram0_we_n;
    wire         cram0_ub_n, cram0_lb_n;
    assign cram0_wait = 1'b0;

    reg [15:0] cmem [0:(1<<21)-1];          // 2M words is plenty for the test
    reg [21:0] chip_addr;
    reg        chip_rd_valid;
    integer k;
    initial begin
        chip_rd_valid = 0;
        if (REAL_DATA) begin
            $readmemh("sim/build/cram_words.hex", cmem);
        end else begin
            // CRAM FILL PATTERN (PFSIM-113) - MUST stay in lockstep with
            // cram_word() in sim/tools/check_pf_frame.py. Knuth's 32-bit
            // multiplicative hash, truncated to 16 bits:
            //
            //     word[a] = low16(a * 2654435761)
            //
            // The rig previously filled cmem[k]=k[15:0] while the checker
            // already modelled the hash. Resolved toward the hash, not the
            // identity, because the identity pattern is STRUCTURED: adjacent
            // addresses give adjacent words, so a wrong-address bug returns a
            // near-correct value that still lines up with a neighbouring
            // cell's expected word under a shifted column offset. Measured on
            // the identity dump: the global-offset search scored 128/296 at a
            // 16-cell shift and 56/296 at 12, purely from that structure -
            // i.e. a real 1-cell addressing error had a plausible chance of
            // being absorbed by the offset search instead of reported. The
            // multiplier is odd, so a -> low16(a*K) is a bijection mod 2^16
            // and every distinct address in a 64K window gets an unrelated
            // word; spurious partial matches collapse to noise.
            //
            // COST of this choice: you can no longer read the fetch address
            // straight off cram_dq in a waveform dump, which was genuinely
            // handy when debugging the address arithmetic. Flip both this
            // loop and cram_word() back to the identity together if you need
            // that for a debug session - never one without the other.
            for(k = 0; k < (1<<21); k = k + 1)
                cmem[k] = (k * 32'd2654435761) & 32'h0000FFFF;
        end
    end
    reg [15:0] mapmem [0:4095];
    initial if (REAL_DATA) $readmemh("sim/build/pf_map.hex", mapmem);
    // latch address while ADV low (controller drives addr on a+dq)
    always @(*) if(!cram0_adv_n && (!cram0_ce0_n || !cram0_ce1_n))
        chip_addr = {cram0_a[21:16], cram0_dq};
    // data valid 62ns after ADV rises (inside the 70ns budget)
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
        .clk        ( clk_sd ),
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

    // ---------------- competing-CRAM-client interference generator (pixel dom)
    //
    // PFSIM-113. This was written as an "MO interference" model, back when MO
    // gfx was fetched from CRAM. On the shipped mo-sdram branch it is not:
    // core_top.v:1561 says "MO gfx CRAM FSM removed - MO is served from SDRAM
    // ...; CRAM belongs to PF + forensics". So this generator no longer models
    // MO. What it DOES still model, and what CRAM genuinely still has to share
    // with the playfield today, is the other read/write traffic on that
    // controller: the cq_n drain/fill queue and the cst forensics reader
    // (core_top.v:1386, :1498, :1520). Those hold strict priority over PF
    // reads - a PF read cannot start unless cq_n==0 - so competing traffic can
    // and does push a PF fetch past its cell deadline. Covering that push is
    // the ENTIRE purpose of the A/B pair, so the rig has to generate it.
    //
    // Two bugs fixed here:
    //   * LIVELOCK. The old generator re-armed only when mo_burst_left==0 and
    //     decremented only on a completion. Once the arbiter starved this
    //     client (see the round-robin fix in the service chain below), no
    //     completion ever arrived, mo_burst_left stuck non-zero, and the
    //     generator went permanently silent - measured: cmg fell from 1842 to
    //     3 for the whole run once the clock ratio was corrected. A rig whose
    //     stimulus can switch itself off is a rig that reports a clean frame
    //     for a path it never drove.
    //   * PROTOCOL. It could toggle mo_gfx_req again while a request was still
    //     outstanding, which the toggle-handshake CDC cannot represent.
    // The generator now keeps exactly ONE request outstanding, refreshes its
    // per-slot allowance unconditionally, and therefore cannot wedge.
    reg mo_gfx_req = 0;
    reg [23:0] mo_gfx_addr = 24'h130000;
    wire mg_done_s;
    reg  mg_done_px_d = 0;
    wire mg_done_px_d_issue = mg_done_s;  // old gate: block issue while MO pending
    reg  [3:0] mo_left = 0;
    reg        mo_busy = 0;
    always @(posedge clk_px) begin
        mg_done_px_d <= mg_done_s;
        if(mo_busy) begin
            if(mg_done_s != mg_done_px_d) mo_busy <= 1'b0;
        end else if(mo_left != 4'd0) begin
            mo_gfx_addr <= 24'h130000 + {visible_y[7:0], 2'd0} + {mo_left, 2'd0};
            mo_gfx_req  <= ~mo_gfx_req;
            mo_busy     <= 1'b1;
            mo_left     <= mo_left - 4'd1;
        end
        // allowance refresh LAST so it wins a same-cycle collision with the
        // decrement above - the allowance must never be silently swallowed.
        if(vis_x[2:0]==3'd5
           && y_count >= VID_V_BPORCH && y_count < VID_V_BPORCH+VID_V_ACTIVE)
            mo_left <= MO_BURST[3:0];
    end

    // ---------------- pixel-domain PF pipeline (replicated from core_top)
    wire [8:0] xscroll = 9'd0, yscroll = 9'd0;
    wire [8:0] pf_y  = visible_y[8:0] + yscroll;
    wire [8:0] pf_x2 = vis_x[8:0] + 9'd32 + xscroll;

    // map BRAM model: registered read; synthetic distinct codes, or the
    // real MAME map dump when REAL_DATA (col-major scanned, matching LANE3j)
    reg  [11:0] pf_vaddr;
    reg  [15:0] pf_vdata;
    always @(posedge clk_px)
        pf_vdata <= REAL_DATA ? mapmem[pf_vaddr]
                              : ({1'b0, 1'b0, pf_vaddr[11:0], 2'b00} | {4'd0, pf_vaddr});
    wire [15:0] pfx_vdata = 16'h0000;

    reg  [4:0] pfcol_q0, pfcol_q1, pfcol_q2, pfcol_q3, pfcol_show;
    reg        inflA = 0, inflB = 0;
    reg [31:0] pf_show;
    reg [31:0] pfring0, pfring1, pfring2, pfring3;
    reg [1:0]  pf_wp = 0, pf_inflA = 0, pf_inflB = 0, pf_rp = 0;
    reg [23:0] pfq_addr0, pfq_addr1, pfq_addr2, pfq_addr3;
    reg [1:0]  pfq_slot0, pfq_slot1, pfq_slot2, pfq_slot3;
    reg [2:0]  pfq_count = 0;
    reg [1:0]  pfq_wr = 0, pfq_rd = 0;
    reg  vg_doneA_last = 0, vg_doneB_last = 0;
    reg  vg_reqA_px = 0, vg_reqB_px = 0;
    reg [23:0] vg_addrA_px, vg_addrB_px;
    wire vg_doneA_s, vg_doneB_s;
    reg [31:0] vg_dataA, vg_dataB, mg_data;

    always @(posedge clk_px) begin
        case(vis_x[2:0])
            3'd0: begin
                pf_vaddr <= {pf_x2[8:3], pf_y[8:3]};   // LANE3j col-major
                pfcol_q3   <= pfcol_q2;
                pfcol_q2   <= pfcol_q1;
                pfcol_q1   <= pfcol_q0;
            end
            3'd3: begin
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
                pfcol_q0 <= {pf_vdata[15], pfx_vdata[11:8]};
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
                pf_rp <= pf_rp + 2'd1;
                pfcol_show <= pfcol_q3;
            end
            default: ;
        endcase
        vg_doneA_last <= vg_doneA_s;
        if(vg_doneA_s != vg_doneA_last) begin
            case(pf_inflA)
                2'd0: pfring0 <= vg_dataA;  2'd1: pfring1 <= vg_dataA;
                2'd2: pfring2 <= vg_dataA;  default: pfring3 <= vg_dataA;
            endcase
            inflA <= 1'b0;
        end
        vg_doneB_last <= vg_doneB_s;
        if(vg_doneB_s != vg_doneB_last) begin
            case(pf_inflB)
                2'd0: pfring0 <= vg_dataB;  2'd1: pfring1 <= vg_dataB;
                2'd2: pfring2 <= vg_dataB;  default: pfring3 <= vg_dataB;
            endcase
            inflB <= 1'b0;
        end
        if(pfq_count != 3'd0 && !(SINGLE_CH && (mo_gfx_req != mg_done_px_d_issue))) begin
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
            end else if(!SINGLE_CH && !inflB && !(vg_doneB_s != vg_doneB_last)) begin
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
            end
        end
        if(x_count == 10'd0) begin
            pf_rp <= pf_wp;
            pfq_count <= 3'd0; pfq_rd <= pfq_wr;
        end
    end

    // pixel extraction
    wire [2:0] pf_n = pfcol_show[4] ? (3'd7 - visible_x[2:0]) : visible_x[2:0];
    reg  [3:0] pf_pix;
    always @(*) begin
        case(pf_n)
            3'd0: pf_pix = pf_show[31:28]; 3'd1: pf_pix = pf_show[27:24];
            3'd2: pf_pix = pf_show[23:20]; 3'd3: pf_pix = pf_show[19:16];
            3'd4: pf_pix = pf_show[15:12]; 3'd5: pf_pix = pf_show[11:8];
            3'd6: pf_pix = pf_show[7:4];   default: pf_pix = pf_show[3:0];
        endcase
    end

    // ---------------- CDC + sdram-domain service chain
    // PFSIM-113: the rig used synch_3 (three stages) in BOTH directions. The
    // shipped RTL does not: clk_sys_7159 and clk_sdram are same-PLL siblings
    // and SDSCHED-74 (core_top.v:1277) crosses them on SINGLE capture FFs -
    // see vg_reqA_s_q/vg_reqB_s_q at core_top.v:1341 and vg_doneA_s_q/
    // vg_doneB_s_q at :1348. Three stages added ~280ns of phantom return
    // latency per PF fetch (2 extra clk_px) that the hardware does not have,
    // i.e. the rig was modelling a SLOWER path than the one that ships. Now
    // matched to the RTL.
    wire vg_reqA_s, vg_reqB_s, mg_req_s;
    reg  vg_doneA_85 = 0, vg_doneB_85 = 0, mg_done_85 = 0;
    reg  vg_reqA_s_q = 0, vg_reqB_s_q = 0, mg_req_s_q = 0;
    always @(posedge clk_sd) begin
        vg_reqA_s_q <= vg_reqA_px;
        vg_reqB_s_q <= vg_reqB_px;
        mg_req_s_q  <= mo_gfx_req;
    end
    assign vg_reqA_s = vg_reqA_s_q;
    assign vg_reqB_s = vg_reqB_s_q;
    assign mg_req_s  = mg_req_s_q;
    reg  vg_doneA_s_q = 0, vg_doneB_s_q = 0, mg_done_s_q = 0;
    always @(posedge clk_px) begin
        vg_doneA_s_q <= vg_doneA_85;
        vg_doneB_s_q <= vg_doneB_85;
        mg_done_s_q  <= mg_done_85;
    end
    assign vg_doneA_s = vg_doneA_s_q;
    assign vg_doneB_s = vg_doneB_s_q;
    assign mg_done_s  = mg_done_s_q;

    reg vg_reqA_last = 0, vg_reqB_last = 0, mg_req_last = 0;
    reg [1:0] cvg_ph = 0, cmg_ph = 0;
    reg [15:0] cvg_hi, cmg_hi;
    reg cvg_ch = 0;
    reg [3:0] cmg_burst = 0;               // competitor's remaining burst pairs
    reg vgmg_last_mo = 0;                  // round-robin state (see below)

    always @(posedge clk_sd) begin
        // Unified CRAM read-start chain (drain/cst omitted: mem preloaded).
        //
        // PFSIM-113 ARBITER FIX. This chain gave PF absolute priority: the
        // competing client was looked at only in the else-arm, i.e. only when
        // no PF request happened to be pending at an idle instant. At the
        // corrected 5:1 clock ratio PF is dense enough that this NEVER
        // happened - the competing client was served 3 times in a 50ms run and
        // starved thereafter (measured). Two consequences, both fatal to the
        // rig: there was no contention left to delay a PF fetch, so channel B
        // was never armed; and the starved client wedged the stimulus
        // generator (see the livelock note above).
        //
        // The shipped chain does NOT behave this way. Drain/fill traffic holds
        // strict priority over PF reads there (a PF read requires cq_n==0,
        // core_top.v:1498), and core_top even carries the vgmg_last_mo
        // round-robin flag from the mo-fair branch (:1519) whose comment
        // records that PF-always-wins was proven to starve the other client.
        // Round-robin is used here rather than strict competitor priority
        // because it is the weaker, more conservative of the two: if the A/B
        // pair holds under round-robin it is not because the rig went easy on
        // the competitor's side, and PF keeps a guaranteed share so a failure
        // is attributable to the ping-pong rather than to raw starvation.
        if(cvg_ph==2'd0 && cmg_ph==2'd0
           && !cram_busy && !cram_read_en && !cram_write_en) begin
            if((mg_req_s != mg_req_last)
               && !(vgmg_last_mo && (vg_reqA_s != vg_reqA_last
                                     || vg_reqB_s != vg_reqB_last))) begin
                mg_req_last  <= mg_req_s;
                cram_addr    <= mo_gfx_addr[22:1] - 22'h88000;
                cram_read_en <= 1'b1;
                cmg_ph       <= 2'd1;
                cmg_burst    <= MO_BURST[3:0];
                vgmg_last_mo <= 1'b1;
            end else if(vg_reqA_s != vg_reqA_last || vg_reqB_s != vg_reqB_last) begin
                if(vg_reqA_s != vg_reqA_last) begin
                    vg_reqA_last <= vg_reqA_s;
                    cram_addr    <= vg_addrA_px[22:1] - 22'h88000;
                    cvg_ch       <= 1'b0;
                end else begin
                    vg_reqB_last <= vg_reqB_s;
                    cram_addr    <= vg_addrB_px[22:1] - 22'h88000;
                    cvg_ch       <= 1'b1;
                end
                cram_read_en <= 1'b1;
                cvg_ph       <= 2'd1;
                vgmg_last_mo <= 1'b0;
            end
        end
        if(cvg_ph==2'd1) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin cvg_hi <= cram_dout; cvg_ph <= 2'd2; end
        end
        if(cvg_ph==2'd2 && !cram_busy && !cram_read_en) begin
            cram_addr    <= cram_addr | 22'd1;
            cram_read_en <= 1'b1;
            cvg_ph       <= 2'd3;
        end
        if(cvg_ph==2'd3) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin
                if(cvg_ch) begin
                    vg_dataB    <= {cvg_hi, cram_dout};
                    vg_doneB_85 <= ~vg_doneB_85;
                end else begin
                    vg_dataA    <= {cvg_hi, cram_dout};
                    vg_doneA_85 <= ~vg_doneA_85;
                end
                cvg_ph <= 2'd0;
            end
        end
        if(cmg_ph==2'd1) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin cmg_hi <= cram_dout; cmg_ph <= 2'd2; end
        end
        if(cmg_ph==2'd2 && !cram_busy && !cram_read_en) begin
            cram_addr    <= cram_addr | 22'd1;
            cram_read_en <= 1'b1;
            cmg_ph       <= 2'd3;
        end
        if(cmg_ph==2'd3) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin
                mg_data <= {cmg_hi, cram_dout};
                // PFSIM-113: the competing client holds the controller for a
                // BURST once granted, instead of handing it straight back
                // after a single 2-word pair. This is what the shipped
                // competitor actually does: the cq_n drain queue keeps PF
                // reads blocked for as long as cq_n != 0 (core_top.v:1386 and
                // the cq_n==4'd0 term in the read-start gate at :1498), so a
                // burst of fills occupies CRAM for many consecutive accesses.
                // A single-pair competitor can delay a PF fetch by at most one
                // pair, which is never enough to push it past its 8-pixel cell
                // deadline - measured: with the one-pair competitor, channel B
                // stayed at issueB=0 for every MO_BURST from 2 to 8.
                if(cmg_burst != 4'd0) begin
                    cmg_burst    <= cmg_burst - 4'd1;
                    cram_addr    <= (cram_addr & ~22'd1) + 22'd2;
                    cram_read_en <= 1'b1;
                    cmg_ph       <= 2'd1;
                end else begin
                    mg_done_85 <= ~mg_done_85;
                    cmg_ph     <= 2'd0;
                end
            end
        end
    end

    // ---------------- debug counters
    integer n_issueA = 0, n_issueB = 0, n_doneA = 0, n_doneB = 0;
    integer n_cvg = 0, n_cmg = 0, n_avail = 0;
    always @(posedge clk_px) begin
        if(vg_reqA_px !== vg_reqA_px) ;
        if(inflA == 1'b0 && $time > 0) ;
    end
    always @(vg_reqA_px) n_issueA = n_issueA + 1;
    always @(vg_reqB_px) n_issueB = n_issueB + 1;
    always @(vg_doneA_85) begin n_doneA = n_doneA + 1;
        if(n_doneA < 4) $display("DBG doneA #%0d data=%h t=%0t", n_doneA, vg_dataA, $time);
    end
    always @(vg_doneB_85) n_doneB = n_doneB + 1;
    always @(posedge clk_sd) if(cram_avail === 1'b1) n_avail = n_avail + 1;
    always @(posedge clk_sd) if(cvg_ph==2'd3 && cram_avail===1'b1) n_cvg = n_cvg + 1;
    always @(posedge clk_sd) if(cmg_ph==2'd3 && cram_avail===1'b1) n_cmg = n_cmg + 1;
    initial begin
        #2000000;  // 2ms in
        $display("DBG @2ms: issueA=%0d issueB=%0d doneA=%0d doneB=%0d avail=%0d cvg=%0d cmg=%0d cvg_ph=%0d cmg_ph=%0d busy=%b pfq=%0d inflA=%b inflB=%b",
                 n_issueA, n_issueB, n_doneA, n_doneB, n_avail, n_cvg, n_cmg, cvg_ph, cmg_ph, cram_busy, pfq_count, inflA, inflB);
    end

    // ---------------- frame dump + finish
    integer fd, sfd, px_seen;
    integer f0_issueA, f0_issueB, f0_doneA, f0_doneB;
    reg dumping = 0;
    initial begin
        fd = $fopen("sim/build/pf_pixels.txt", "w");
        px_seen = 0;
        // let two full frames elapse (first frame fills pipes), dump the third
        @(posedge clk_px);
        repeat (2 * VID_V_TOTAL * VID_H_TOTAL) @(posedge clk_px);
        f0_issueA = n_issueA; f0_issueB = n_issueB;
        f0_doneA  = n_doneA;  f0_doneB  = n_doneB;
        dumping = 1;
        repeat (VID_V_TOTAL * VID_H_TOTAL + 10) @(posedge clk_px);
        $fclose(fd);
        // PFSIM-113: the checker refuses to pass a run in which channel B was
        // never armed, so a rig that silently stops exercising the A/B
        // ping-pong (the ONLY thing this rig validates) fails loudly instead
        // of reporting a clean frame. Counters are deltas over the dumped
        // frame, not since power-on.
        sfd = $fopen("sim/build/pf_stats.txt", "w");
        $fwrite(sfd, "single_ch %0d\n", SINGLE_CH);
        $fwrite(sfd, "pixels %0d\n",    px_seen);
        $fwrite(sfd, "issueA %0d\n",    n_issueA - f0_issueA);
        $fwrite(sfd, "issueB %0d\n",    n_issueB - f0_issueB);
        $fwrite(sfd, "doneA %0d\n",     n_doneA  - f0_doneA);
        $fwrite(sfd, "doneB %0d\n",     n_doneB  - f0_doneB);
        $fclose(sfd);
        $display("TB_PF_CRAM DONE: %0d pixels dumped", px_seen);
        $display("TB_PF_CRAM FRAME: issueA=%0d issueB=%0d doneA=%0d doneB=%0d (single_ch=%0d)",
                 n_issueA - f0_issueA, n_issueB - f0_issueB,
                 n_doneA - f0_doneA,   n_doneB - f0_doneB, SINGLE_CH);
        $finish;
    end
    always @(posedge clk_px) begin
        if(dumping
           && x_count >= VID_H_BPORCH && x_count < VID_H_BPORCH+VID_H_ACTIVE
           && y_count >= VID_V_BPORCH && y_count < VID_V_BPORCH+VID_V_ACTIVE) begin
            $fwrite(fd, "%0d %0d %h\n", visible_x, visible_y, pf_pix);
            px_seen = px_seen + 1;
        end
    end
endmodule

// PFSIM-113: the synch_3 model that used to live here is gone. Both CDC
// crossings in this rig are single capture FFs now, matching SDSCHED-74 in
// core_top.v - keeping an unused 3-stage synchroniser in a bench whose whole
// subject is fetch latency was an invitation to re-introduce it.
