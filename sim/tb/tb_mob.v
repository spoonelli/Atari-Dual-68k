// tb_mob: the REAL escape_mob.v against REAL in-game state dumped live from
// MAME mid-gameplay (robots + player on screen): MO RAM, SLIP/config RAM,
// playfield + playfield-palette RAM, scroll registers, and the real chunky
// gfx. Fixtures come from sim/tools/make_scene_hex.py.
//
// Renders one frame of the MO layer to sim/build/mob_pixels.txt
// ("<x> <y> <pen> <prio>"); sim/tools/render_scene.py turns that into an image
// for direct comparison against the synchronized MAME screenshot.
//
// MOPRI-1: it also drives escape_prio.v with the real MO and playfield fields
// and logs every priority decision to sim/build/mob_prio.txt, which
// sim/tools/check_mob_prio.py replays through the reference model
// (sim/tools/mo_priority_model.py). See docs/mo_priority.md.
//
// The other question this answers: where do in-game sprites actually land under
// real nonzero scroll? See docs/mo_placement.md - the engine was building each
// line for ly+1 and letting the LAST list entry win overlaps instead of the
// first. Both are fixed; what remains is fetch-budget truncation.
//
// Run: XSCROLL=224 YSCROLL=421 sim/run_mob_tb.sh
// (NOT MOB_PARAMS='-PXSCROLL=...': iverilog silently ignores the bare -P form,
//  so the bench would run at the defaults below while being diffed against a
//  differently-scrolled scene. run_mob_tb.sh now rejects that spelling.)
`timescale 1ns/1ps

module tb_mob;
    parameter XSCROLL = 123;
    parameter YSCROLL = 253;
    parameter GFX_LAT = 8;   // pixel-clock cycles per fetch (device-realistic)
    // MOJIT-116: per-request latency JITTER. Default 0 keeps every existing
    // gate bit-identical.
    //
    // Why this exists: with a constant GFX_LAT every channel completes in
    // issue order with identical timing, so a defect that needs completions to
    // arrive out of the order the consumer assumes CANNOT occur here. That is
    // the shape of the tile-hole artifact seen on device (docs/MO_TILE_HOLES.md,
    // frame 5629 wrong / 5636 right - same sprite, so the cause is transient,
    // not static). All three existing detectors pass because the sprite IS
    // accepted and IS drawn; only one tile inside it is missing.
    //
    // Real SDRAM latency varies with bank state, refresh and contention. This
    // models that as GFX_LAT + (lfsr % (GFX_JIT+1)), per request, per channel.
    // The LFSR is used rather than $random so a failing run is reproducible
    // from GFX_SEED alone and can be handed to someone else.
    parameter GFX_JIT  = 0;
    parameter GFX_SEED = 16'hACE1;

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
    initial begin
        $readmemh("sim/work/game_mo.hex", momem);
        $readmemh("sim/work/game_cfg.hex", cfgmem);
    end
    // MOPRI-1: playfield tile RAM + tile "palette" (extmem) RAM for the
    // priority comparison. 64x64 map, TILEMAP_SCAN_COLS -> index = col*64+row.
    reg [15:0] pfmem  [0:4095];
    reg [15:0] pfxmem [0:4095];
    initial begin
        $readmemh("sim/work/game_pf.hex",  pfmem);
        $readmemh("sim/work/game_pfx.hex", pfxmem);
    end
    wire [11:0] mo_vaddr;
    reg  [15:0] mo_vdata;
    wire [6:0]  cfg_vaddr;
    reg  [15:0] cfg_vdata;
    always @(posedge clk) begin
        mo_vdata  <= momem[mo_vaddr];
        cfg_vdata <= cfgmem[cfg_vaddr];
    end

    // ---------------- gfx model: real chunky image bytes, ~4-cycle latency
    reg [7:0] gfx [0:(1<<22)-1];        // image bytes 0..0x220000
    initial $readmemh("sim/work/image_bytes.hex", gfx);
    // MOCHAN-4: four packed fetch channels (was the A/B ping-pong)
    localparam NCH = 4;
    wire [3:0]   gfx_req;
    wire [95:0]  gfx_addr;
    reg  [3:0]   gfx_done = 4'd0;
    reg  [127:0] gfx_data;
    reg  [3:0]   req_d = 4'd0;
    reg  [6:0]   lat    [0:3];
    reg  [15:0]  jit_r = GFX_SEED;   // MOJIT-116 galois LFSR, deterministic
    reg  [23:0]  addr_l [0:3];
    integer k;
    initial begin
        for(k = 0; k < 4; k = k + 1) begin lat[k] = 0; addr_l[k] = 0; end
        gfx_data = 0;
    end
    always @(posedge clk) begin
        for(k = 0; k < NCH; k = k + 1) begin
            if(gfx_req[k] != req_d[k] && lat[k] == 0) begin
                req_d[k]  <= gfx_req[k];
                addr_l[k] <= gfx_addr[k*24 +: 24];
                lat[k]    <= GFX_LAT[6:0] + (GFX_JIT == 0 ? 7'd0
                                             : (jit_r % (GFX_JIT + 1)));
                jit_r     <= {jit_r[14:0], jit_r[15] ^ jit_r[13]
                                         ^ jit_r[12] ^ jit_r[10]};
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

    // ---------------- DUT
    reg rstn = 0;
    initial begin rstn = 0; repeat (20) @(posedge clk); rstn = 1; end
    wire [7:0] disp_pen;
    wire [1:0] disp_prio;
    wire       disp_valid;
    wire       disp_stain_s, disp_stain_e;    // MOSTAIN-1
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
        .disp_prio( disp_prio ),
        .disp_valid( disp_valid ),
        .disp_stain_s( disp_stain_s ),
        .disp_stain_e( disp_stain_e )
    );

    // ---------------- MOPRI-1: playfield pen for this pixel
    // A direct model of MAME's playfield tilemap for eprom (get_playfield_tile_info
    // + pfmolayout, chunky-repacked): NOT core_top's prefetch pipeline, which is a
    // scheduling detail. Keeping it independent means a disagreement here is a
    // priority-logic disagreement, not a fetch-timing one.
    // The visible pixel is one clock behind visible_x (registered line-buffer read),
    // so the playfield must be sampled at visible_x-1 to line up with disp_pen.
    wire [9:0] pf_sx  = visible_x - 10'd1;
    wire [8:0] pf_x2  = (pf_sx[8:0] + XSCROLL[8:0]) & 9'h1FF;
    wire [8:0] pf_y2  = (visible_y[8:0] + YSCROLL[8:0]) & 9'h1FF;
    wire [11:0] pf_idx = {pf_x2[8:3], pf_y2[8:3]};       // col*64 + row
    wire [15:0] pf_w1  = pfmem[pf_idx];
    wire [15:0] pf_wx  = pfxmem[pf_idx];
    wire [14:0] pf_code = pf_w1[14:0];
    wire        pf_flip = pf_w1[15];
    wire [3:0]  pf_color = pf_wx[11:8];
    wire [2:0]  pf_px   = pf_flip ? (3'd7 - pf_x2[2:0]) : pf_x2[2:0];
    // chunky: 4 bytes per tile row, high nibble first
    wire [23:0] pf_rowa = 24'h120000 + {pf_code, 5'd0} + {pf_y2[2:0], 2'd0};
    wire [7:0]  pf_byte = gfx[pf_rowa + {1'b0, pf_px[2:1]}];
    wire [3:0]  pf_pix  = pf_px[0] ? pf_byte[3:0] : pf_byte[7:4];

    // ---------------- MOPRI-1: the comparator under test
    wire        pr_forcemc0, pr_shade, pr_m7, pr_pfm, pr_mo_win;
    wire [10:0] pr_pen;
escape_prio uprio (
    .mo_valid ( disp_valid ),
    .mo_prio  ( disp_prio ),
    .mo_color ( disp_pen[7:4] ),
    .mo_pix   ( disp_pen[3:0] ),
    .pf_color ( pf_color ),
    .pf_pix   ( pf_pix ),
    .forcemc0 ( pr_forcemc0 ),
    .shade    ( pr_shade ),
    .m7       ( pr_m7 ),
    .pfm      ( pr_pfm ),
    .mo_win   ( pr_mo_win ),
    .pen      ( pr_pen )
);

    // ---------------- debug: what does the engine actually do per line?
    reg dumping = 0;
    integer n_slip, n_entries, n_ymatch, n_fetch, n_wren, n_wren_off;
    integer n_pend, n_done, n_blitst; reg pend0_d = 0, done0_d = 0;
    integer n_mowin, n_shade, n_m7, n_occl;   // MOPRI-1 decision census
    integer n_spec;                            // MOSTAIN-1 special pixels seen
    initial begin n_slip=0; n_entries=0; n_ymatch=0; n_fetch=0; n_wren=0; n_wren_off=0; n_pend=0; n_done=0; n_blitst=0;
                  n_mowin=0; n_shade=0; n_m7=0; n_occl=0; n_spec=0; end
    reg [3:0] state_d = 0;
    always @(posedge clk) begin
        state_d <= dut.state;
        if(dut.state == 4'd3 && state_d != 4'd3) n_slip = n_slip + 1;          // S_SLIP1
        if(dut.state == 4'd8 && state_d != 4'd8) n_entries = n_entries + 1;    // S_MATCH
        if(dut.state == 4'd10 && state_d != 4'd10 && dut.ymatch) n_ymatch = n_ymatch + 1;
        // MOCHAN-4: the pump issues in parallel with the blit, so there is no
        // blit_n==15 issue cycle any more; count sprite loads (S_E0) instead.
        if(dut.state == 4'd4 && state_d != 4'd4) n_fetch = n_fetch + 1;
        if(dut.pend[0] && !pend0_d) n_pend = n_pend + 1;
        pend0_d = dut.pend[0];
        if(gfx_done[0] != done0_d) n_done = n_done + 1;
        if(gfx_done[0] != done0_d && n_done < 25)
            $display("FETCH addr=%06x data=%08x", addr_l[0],
                     {gfx[addr_l[0]], gfx[addr_l[0]+1], gfx[addr_l[0]+2], gfx[addr_l[0]+3]});
        done0_d = gfx_done[0];
        if(dut.state == 4'd12 && state_d != 4'd12) n_blitst = n_blitst + 1;
        if(dut.wr_en) n_wren = n_wren + 1;
        if(dut.state == 4'd11 && dut.blit_n < 4'd8 && dut.pix_val != 0 && dut.blit_x >= 9'd344)
            n_wren_off = n_wren_off + 1;
        if(dumping && dut.wr_en && n_wren < 30)
            $display("WR line=%0d ly=%0d x=%0d pen=%02x", y_count, dut.ly, dut.wr_x, dut.wr_data[7:0]);
    end

    // ---------------- frame dump
    integer fd, px_seen, reqs;
    reg [3:0] req_cnt_d = 4'd0;
    always @(posedge clk) begin
        for(k = 0; k < NCH; k = k + 1)
            if(gfx_req[k] != req_cnt_d[k]) reqs = reqs + 1;
        req_cnt_d <= gfx_req;
    end
    integer fdp;                        // MOPRI-1: per-pixel priority decision log
    integer fds;                        // MOSTAIN-1: special (MPR2) pixels: x y S E
    initial begin
        $display("TB_MOB scroll: XSCROLL=%0d YSCROLL=%0d", XSCROLL, YSCROLL);
        fd  = $fopen("sim/build/mob_pixels.txt", "w");
        fdp = $fopen("sim/build/mob_prio.txt", "w");
        fds = $fopen("sim/build/mob_special.txt", "w");
        $fwrite(fdp, "# x y mo_valid mo_prio mo_color mo_pix pf_color pf_pix ");
        $fwrite(fdp, "forcemc0 shade m7 pfm mo_win pen layer\n");
        px_seen = 0; reqs = 0;
        @(posedge rstn);
        repeat (2 * VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        dumping = 1;
        repeat (VID_V_TOTAL * VID_H_TOTAL + 10) @(posedge clk);
        $fclose(fd);
        $fclose(fdp);
        $fclose(fds);
        $display("TB_MOB DONE: %0d pixels, %0d gfx reqs, %0d special pixels", px_seen, reqs, n_spec);
        $display("DBG3 mo_win=%0d shade=%0d m7=%0d occluded=%0d",
                 n_mowin, n_shade, n_m7, n_occl);
        $display("DBG slips=%0d entries=%0d ymatch=%0d fetch=%0d wren=%0d offscreen_px=%0d",
                 n_slip, n_entries, n_ymatch, n_fetch, n_wren, n_wren_off);
        $display("DBG2 done=%0d pend=%0d blitstate=%0d", n_done, n_pend, n_blitst);
        $finish;
    end
    always @(posedge clk) begin
        if(dumping
           && x_count >= VID_H_BPORCH+1 && x_count < VID_H_BPORCH+VID_H_ACTIVE+1
           && y_count >= VID_V_BPORCH && y_count < VID_V_BPORCH+VID_V_ACTIVE) begin
            // disp read is registered: pen for visible_x N is valid one cycle later
            if(disp_valid) begin
                $fwrite(fd, "%0d %0d %h %0d\n", visible_x - 10'd1, visible_y,
                        disp_pen, disp_prio);
                px_seen = px_seen + 1;
            end
            // MOSTAIN-1: the special pass's own pixels. They never draw; the
            // compositor uses their START/END markers to stain what is under
            // them (sim/tools/render_scene.py replays the same rule).
            if(disp_stain_s || disp_stain_e) begin
                $fwrite(fds, "%0d %0d %0d %0d\n", visible_x - 10'd1, visible_y,
                        disp_stain_s, disp_stain_e);
                n_spec = n_spec + 1;
            end
            // MOPRI-1: log every pixel the MO layer covers, with the full set of
            // priority-decision inputs and the layer that won.
            if(disp_valid) begin
                $fwrite(fdp, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0s\n",
                        visible_x - 10'd1, visible_y,
                        disp_valid, disp_prio, disp_pen[7:4], disp_pen[3:0],
                        pf_color, pf_pix,
                        pr_forcemc0, pr_shade, pr_m7, pr_pfm, pr_mo_win, pr_pen,
                        pr_mo_win ? "mo" : "pf");
                n_mowin = n_mowin + (pr_mo_win ? 1 : 0);
                n_shade = n_shade + (pr_shade ? 1 : 0);
                n_m7    = n_m7    + (pr_m7    ? 1 : 0);
                n_occl  = n_occl  + (pr_mo_win ? 0 : 1);
            end
        end
    end
endmodule
