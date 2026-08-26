// tb_stain: the first bench in this tree that drives the SHIPPED compositor.
//
// GFXDASH-3. Two gaps this closes, both of which let a real artifact through
// eleven passing gates:
//
//   1. sim/run_mob_tb.sh's fixture reports "0 special pixels" and "SHADE
//      pixels=0". The gate that would catch a stain bug had no stain in its
//      scene, so it could not fail for the right reason.
//   2. The apply_stain automaton lived inline in core_top.v, which NO sim
//      script compiles. sim/tools/check_stain_automaton.py therefore tests a
//      TRANSCRIPTION of it. This bench instantiates escape_stain.v - the same
//      file core_top.v instantiates - so the gates being exercised are the
//      gates that ship.
//
// What IS benched here: escape_mob.v's line buffers, first-write-wins,
// staleness tagging, the special/MPR2 flag and the START/END pen decode, plus
// escape_stain.v's scanline automaton, over SIX consecutive frames of a scene
// that changes between them.
//
// What is NOT benched here: everything else in core_top.v's compositor - the
// MO/playfield priority merge (that is sim/run_prio_tb.sh and tb_mob.v), the
// colour-RAM address arithmetic, the alpha overlay, and the one-pixel
// alignment between the stain and the playfield that docs/mo_priority.md
// leaves open. This bench says the stain covers the right COLUMNS of the right
// SCANLINES; it says nothing about which palette entry they land in.
//
// Scene and reference answer: sim/tools/make_stain_scene.py.
// Scoring: sim/tools/check_stain.py. Run: sim/run_stain_tb.sh
`timescale 1ns/1ps
`default_nettype none

module tb_stain;
    // The synthetic scene is authored in screen space, so both scrolls are 0.
    // (Scrolled placement is tb_mob.v's job and is checked against MAME there.)
    parameter XSCROLL = 0;
    parameter YSCROLL = 0;
    parameter GFX_LAT = 8;              // pixel-clock cycles per fetch
    parameter NFRAMES = 6;              // must match make_stain_scene.NFRAMES
    parameter FIRST_SCORED = 2;         // frames 0..1 warm the line buffers

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

    // ---------------- the scene, reloaded at every frame boundary
    reg [15:0] momem  [0:4095];
    reg [15:0] cfgmem [0:127];
    integer frame = 0;
    reg [8*64-1:0] fname;
    task load_frame(input integer f);
        begin
            $sformat(fname, "sim/work/stain_mo_f%0d.hex", f);
            $readmemh(fname, momem);
        end
    endtask
    initial begin
        $readmemh("sim/work/stain_cfg.hex", cfgmem);
        load_frame(0);
    end
    // The MO list for frame N must be in place before frame N's FIRST line
    // build, which the engine triggers at y_count == vbporch-1. Loading at the
    // top of the frame is 11 lines earlier than that, and it lands on the same
    // edge as escape_mob's own frame-parity flip, so the list and the tag the
    // buffers are stamped with always belong to the same frame.
    always @(posedge clk)
        if(y_count == 10'd0 && x_count == 10'd0) begin
            frame = frame + 1;
            if(frame < NFRAMES) load_frame(frame);
        end

    wire [11:0] mo_vaddr;
    reg  [15:0] mo_vdata;
    wire [6:0]  cfg_vaddr;
    reg  [15:0] cfg_vdata;
    always @(posedge clk) begin
        mo_vdata  <= momem[mo_vaddr];
        cfg_vdata <= cfgmem[cfg_vaddr];
    end

    // ---------------- gfx model
    // Sparse by construction: escape_mob asks for byte address
    // 0x120000 + code*32 + row*4, so (addr - 0x120000) >> 2 == code*8 + row
    // indexes one 32-bit tile row directly and no 4 MB array is needed.
    reg [31:0] tilerow [0:8191];
    initial $readmemh("sim/work/stain_gfx.hex", tilerow);
    localparam NCH = 4;
    wire [3:0]   gfx_req;
    wire [95:0]  gfx_addr;
    reg  [3:0]   gfx_done = 4'd0;
    reg  [127:0] gfx_data;
    reg  [3:0]   req_d = 4'd0;
    reg  [6:0]   lat    [0:3];
    reg  [23:0]  addr_l [0:3];
    integer k;
    initial begin
        for(k = 0; k < 4; k = k + 1) begin lat[k] = 0; addr_l[k] = 0; end
        gfx_data = 0;
    end
    function [12:0] rowidx(input [23:0] a);
        rowidx = (a - 24'h120000) >> 2;
    endfunction
    always @(posedge clk) begin
        for(k = 0; k < NCH; k = k + 1) begin
            if(gfx_req[k] != req_d[k] && lat[k] == 0) begin
                req_d[k]  <= gfx_req[k];
                addr_l[k] <= gfx_addr[k*24 +: 24];
                lat[k]    <= GFX_LAT[6:0];
            end else if(lat[k] != 0) begin
                lat[k] <= lat[k] - 7'd1;
                if(lat[k] == 7'd1) begin
                    gfx_data[k*32 +: 32] <= tilerow[rowidx(addr_l[k])];
                    gfx_done[k] <= ~gfx_done[k];
                end
            end
        end
    end

    // ---------------- DUT 1: the real line engine
    reg rstn = 0;
    initial begin rstn = 0; repeat (20) @(posedge clk); rstn = 1; end
    wire [7:0] disp_pen;
    wire [1:0] disp_prio;
    wire       disp_valid;
    wire       disp_stain_s, disp_stain_e;
    escape_mob dut (
        .clk      ( clk ),
        .reset_n  ( rstn ),
        .x_count  ( x_count ),
        .y_count  ( y_count ),
        .vbporch  ( VID_V_BPORCH[9:0] ),
        .vactive  ( VID_V_ACTIVE[9:0] ),
        .hbporch  ( VID_H_BPORCH[9:0] ),
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
        // MOALIGN-129: the DUT's display leg now reads at disp_x+1, aligning
        // delivery with consumption; the old visible_x-1 logging compensation
        // is gone to match (same change as tb_mob).
        .disp_x   ( visible_x[8:0] ),
        .disp_pen ( disp_pen ),
        .disp_prio( disp_prio ),
        .disp_valid( disp_valid ),
        .disp_stain_s( disp_stain_s ),
        .disp_stain_e( disp_stain_e )
    );

    // ---------------- DUT 2: the real compositor automaton
    // Wired exactly as core_top.v wires it, including the line_start term.
    wire stain_now;
    escape_stain ustain (
        .clk        ( clk ),
        .line_start ( x_count == VID_H_BPORCH - 1 ),   // MOALIGN-129: clear visible AT pixel 0
        .s_in       ( disp_stain_s ),
        .e_in       ( disp_stain_e ),
        .stain      ( stain_now )
    );

    // ---------------- dump
    // The line-buffer read is registered, so the pixel presented at visible_x
    // is visible_x-1 - the same compensation tb_mob.v makes. core_top.v
    // registers pr_pen and the stain into color_vaddr on the same edge, so
    // this is the alignment the hardware has.
    integer fd, n_stain, n_pix, n_s, n_e;
    initial begin
        fd = $fopen("sim/build/stain_actual.txt", "w");
        n_stain = 0; n_pix = 0; n_s = 0; n_e = 0;
        @(posedge rstn);
        wait (frame == NFRAMES);
        $fclose(fd);
        $display("TB_STAIN DONE: frames %0d..%0d scored, %0d stained px, %0d MO px",
                 FIRST_SCORED, NFRAMES-1, n_stain, n_pix);
        $display("TB_STAIN MARKERS: %0d START px, %0d END px", n_s, n_e);
        // A run that saw no markers at all would make check_stain.py's diff
        // vacuously clean, so fail loudly here rather than quietly there.
        if(n_s == 0 || n_e == 0) begin
            $display("TB_STAIN FAIL: no START/END markers seen - the fixture is missing or wrong, this is NOT a pass");
            $fatal(1);
        end
        $finish;
    end

    always @(posedge clk) begin
        if(frame >= FIRST_SCORED && frame < NFRAMES
           && x_count >= VID_H_BPORCH && x_count < VID_H_BPORCH+VID_H_ACTIVE
           && y_count >= VID_V_BPORCH && y_count < VID_V_BPORCH+VID_V_ACTIVE) begin
            if(stain_now) begin
                $fwrite(fd, "S %0d %0d %0d\n", frame, visible_y, visible_x);
                n_stain = n_stain + 1;
            end
            if(disp_valid) begin
                $fwrite(fd, "P %0d %0d %0d %0d\n", frame, visible_y,
                        visible_x, disp_pen[3:0]);
                n_pix = n_pix + 1;
            end
            if(disp_stain_s) n_s = n_s + 1;
            if(disp_stain_e) n_e = n_e + 1;
        end
    end

    // never-wedge: the scene is six frames, so anything past that is a hang
    initial begin
        repeat ((NFRAMES + 2) * VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        $display("TB_STAIN FAIL: bench did not reach frame %0d", NFRAMES);
        $fatal(1);
    end
endmodule
`default_nettype wire
