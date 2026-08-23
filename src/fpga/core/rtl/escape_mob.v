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

    reg [3:0]  state;
    reg [8:0]  ly;                      // playfield-space line being built
    reg [9:0]  first_link, link;
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
    reg [31:0] rowdata;
    reg [3:0]  blit_n;
    reg [8:0]  blit_x;
    reg [5:0]  fetch_budget;
    reg [9:0]  cur_line_latch;

    // v80: MAME atarimo ground truth - the entry Y field is NEGATED and
    // offset by the sprite height: top = -yfield - (height+1)*8. So
    // ydiff = ly - top = ly + yfield + (height+1)*8. The raw-field compare
    // matched almost nothing (v79 probe: 97 fetches, 12 pixels/frame).
    wire [8:0] ydiff = (ly + spr_y + {1'b0, height_t, 3'b000} + 9'd8) & 9'h1FF;
    wire       ymatch = ydiff < {height_t, 3'b000} + 9'd8;   // (height+1)*8 lines

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
            gfx_reqA <= 0; gfx_reqB <= 0;
            pendA <= 0; pendB <= 0;
            wr_en <= 0;
            build_sel <= 0;
            built_ly0 <= 9'h1FF; built_ly1 <= 9'h1FF;
            gfx_doneA_last <= 0; gfx_doneB_last <= 0;
        end else begin
            wr_en <= 0;
            gfx_doneA_last <= gfx_doneA;
            gfx_doneB_last <= gfx_doneB;
            // completions can land while blitting: LATCH them (an edge is
            // visible for one cycle only - depth-2 lost edges without this)
            if(gfx_doneA != gfx_doneA_last) pendA <= 1'b1;
            if(gfx_doneB != gfx_doneB_last) pendB <= 1'b1;

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
                state <= S_CLEAR;
            end else
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
                fetch_budget <= 6'd62;
                state <= S_E0;
            end

            S_E0: begin mo_vaddr <= {link, 2'd0}; state <= S_E1; end
            S_E1: begin mo_vaddr <= {link, 2'd1}; state <= S_E2; end
            S_E2: begin mo_vaddr <= {link, 2'd2}; w0 <= mo_vdata; state <= S_E3; end
            S_E3: begin mo_vaddr <= {link, 2'd3}; w1 <= mo_vdata; state <= S_MATCH; end

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
                w3 <= mo_vdata;
                spr_y    <= mo_vdata[15:7];
                width_t  <= mo_vdata[6:4];
                height_t <= mo_vdata[2:0];
                hflip    <= mo_vdata[3];
                tx <= 0;
                state <= S_WAIT;
            end

            S_WAIT: begin
                // now spr_y etc are valid: decide match and start tile loop
                if(ymatch && fetch_budget != 0) begin
                    // code for this row: code + ty*width + tx  (ty = ydiff>>3)
                    code_row    <= w1[14:0] + ( (ydiff[8:3]) * ({3'b0,width_t}+4'd1) );
                    row_in_tile <= ydiff[2:0];
                    tx_f  <= 3'd0;                  // next tile to ISSUE
                    tx    <= 3'd0;                  // next tile to LATCH/blit
                    state <= S_PRIME;
                    blit_n <= 4'd15;                // marker: nothing in flight
                end else begin
                    state <= S_NEXT;
                end
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
                if(blit_n == 4'd15) begin
                    // sprite start: issue tile 0 (A) and, if any, tile 1 (B)
                    gfx_addrA <= 24'h120000
                                + { code_row, 5'd0 }
                                + { row_in_tile, 2'd0 };
                    gfx_reqA  <= ~gfx_reqA;
                    if(width_t != 3'd0 && fetch_budget > 6'd1) begin
                        gfx_addrB <= 24'h120000
                                    + { (code_row + 15'd1), 5'd0 }
                                    + { row_in_tile, 2'd0 };
                        gfx_reqB  <= ~gfx_reqB;
                        tx_f <= 3'd2;
                        fetch_budget <= fetch_budget - 6'd2;
                    end else begin
                        tx_f <= 3'd1;
                        fetch_budget <= fetch_budget - 6'd1;
                    end
                    blit_n <= 4'd14;
                end else if(tx[0] ? pendB : pendA) begin
                    // tile tx's data has landed on its parity channel
                    rowdata <= tx[0] ? gfx_dataB : gfx_dataA;
                    if(tx[0]) pendB <= 1'b0; else pendA <= 1'b0;
                    blit_x  <= (spr_x + (hflip ? {(width_t - tx), 3'b000}
                                              : {tx, 3'b000})
                                - {1'b0, xscroll}) & 9'h1FF;
                    blit_n  <= 4'd0;
                    // refill the channel just freed with tile tx_f
                    if(tx_f <= width_t && tx_f != 3'd0 && fetch_budget != 6'd0) begin
                        if(tx_f[0]) begin
                            gfx_addrB <= 24'h120000
                                        + { (code_row + {12'b0, tx_f}), 5'd0 }
                                        + { row_in_tile, 2'd0 };
                            gfx_reqB  <= ~gfx_reqB;
                        end else begin
                            gfx_addrA <= 24'h120000
                                        + { (code_row + {12'b0, tx_f}), 5'd0 }
                                        + { row_in_tile, 2'd0 };
                            gfx_reqA  <= ~gfx_reqA;
                        end
                        fetch_budget <= fetch_budget - 6'd1;
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
                    else if(tx_f == tx + 3'd1 && fetch_budget == 6'd0) state <= S_NEXT;
                    else begin
                        tx     <= tx + 3'd1;
                        blit_n <= 4'd14;   // that tile's data is in flight
                        state  <= S_PRIME;
                    end
                end else begin
                    blit_n <= blit_n + 4'd1;
                end
            end

            S_NEXT: begin
                ent_count <= ent_count + 7'd1;
                link <= w0[9:0];
                if(w0[9:0] == first_link || ent_count == 7'd63 || fetch_budget == 0)
                    state <= S_IDLE;
                else
                    state <= S_E0;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
