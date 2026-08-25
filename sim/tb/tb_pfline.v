// tb_pfline: does the playfield pipeline draw the FIRST PIXELS OF A LINE from
// this line's data, or from something stale?
//
// This is the bench that did not exist. The left-edge strip absorbed two
// shipped "fixes" reasoned from the source, because the pipeline lived inside
// core_top.v and nothing could compile it. PFEXTRACT-120 lifted it into
// escape_pf.v so this bench can drive the SHIPPED instance.
//
// THE TEST AVOIDS RE-IMPLEMENTING THE ADDRESS MATH ON PURPOSE. Computing an
// expected pixel from the map and tile geometry would mean writing the same
// arithmetic the DUT uses, and any misunderstanding I hold would be baked into
// both sides - which is exactly how the last two fixes passed my own review.
//
// Instead the fixture is UNIFORM and the test is for STALENESS:
//
//   * every map cell returns the same tile code
//   * the gfx model returns the same 32-bit word for EVERY address, and that
//     word CHANGES between frames
//
// So within a frame, every visible pixel must be the same nibble. A pixel that
// carries the PREVIOUS frame's value is stale by construction, no geometry
// required. That is precisely the device artifact: native columns 0..N showing
// the previous scene while the rest of the line shows this one.
//
// Reported: the leftmost native column at which the line becomes correct, per
// line. The device says this is 8 - (fine scroll & 7) pixels wide, i.e. 1..8
// varying with XSCROLL, so the bench sweeps XSCROLL and expects the width to
// track it - a prediction, not just a pass/fail.
`default_nettype none
`timescale 1ns/1ps

module tb_pfline;
    localparam [9:0] V_BPORCH = 10'd12,  V_ACTIVE = 10'd240;
    localparam [9:0] H_BPORCH = 10'd60,  H_ACTIVE = 10'd336;
    localparam [9:0] H_TOTAL  = 10'd456, V_TOTAL  = 10'd262;

    parameter [8:0] XSCROLL = 9'd0;
    parameter integer GFX_LAT = 6;     // fetch latency in pixel clocks

    reg clk = 0; always #5 clk = ~clk;
    reg rstn = 0;

    reg [9:0] x_count = 0, y_count = 0;
    wire [9:0] vis_x     = x_count - H_BPORCH;
    wire [9:0] visible_x = x_count - H_BPORCH;
    wire [9:0] visible_y = y_count - V_BPORCH;
    wire in_active = (x_count >= H_BPORCH) && (x_count < H_BPORCH + H_ACTIVE)
                  && (y_count >= V_BPORCH) && (y_count < V_BPORCH + V_ACTIVE);

    always @(posedge clk) begin
        if(x_count == H_TOTAL - 1) begin
            x_count <= 0;
            y_count <= (y_count == V_TOTAL - 1) ? 10'd0 : y_count + 10'd1;
        end else x_count <= x_count + 10'd1;
    end

    wire [11:0] pf_vaddr;
    wire [3:0]  pf_pix;
    wire [4:0]  pf_att;

    // ---- fixture: every CELL is distinct, and the test is a SPATIAL RAMP ----
    // A uniform map cannot see this bug, and neither can a row-encoded one: on
    // a given line every cell fetches the SAME address, so reading the wrong
    // ring slot returns identical data. Both earlier fixtures passed a DUT
    // deliberately mutated to read the wrong slot - blind checks.
    //
    // So: the map returns the COLUMN as the tile code (pf_vaddr = col*64+row,
    // hence col = pf_vaddr[11:6]), which makes each cell's fetch address
    // distinct. The gfx model returns the tile's low nibble, read straight off
    // the address it was handed (addr = 0x120000 + {tile,5'd0} + {row,2'd0},
    // so addr[8:5] = tile[3:0]).
    //
    // The expected picture is then a RAMP: the nibble increments by one every
    // eight pixels across the line, wrapping at 16. That is checkable without
    // re-implementing the DUT's scroll/fine-phase arithmetic - which matters,
    // because duplicating that arithmetic is how a wrong model gets baked into
    // both sides of a test.
    wire [15:0] pf_vdata  = {10'd0, pf_vaddr[11:6]};
    wire [15:0] pfx_vdata = 16'h0000;
    function [31:0] cellword(input [23:0] a);
        cellword = {8{a[8:5]}};
    endfunction

    wire [23:0] vg_addrA_px, vg_addrB_px;
    wire        vg_reqA_px,  vg_reqB_px;
    reg  [31:0] vg_dataA = 0, vg_dataB = 0;
    reg         vg_doneA_s = 0, vg_doneB_s = 0;
    reg         reqA_d = 0, reqB_d = 0;
    reg  [7:0]  latA = 0, latB = 0;

    always @(posedge clk) begin
        if(vg_reqA_px != reqA_d && latA == 0) begin reqA_d <= vg_reqA_px; latA <= GFX_LAT; end
        else if(latA != 0) begin
            latA <= latA - 8'd1;
            if(latA == 8'd1) begin vg_dataA <= cellword(vg_addrA_px); vg_doneA_s <= ~vg_doneA_s; end
        end
        if(vg_reqB_px != reqB_d && latB == 0) begin reqB_d <= vg_reqB_px; latB <= GFX_LAT; end
        else if(latB != 0) begin
            latB <= latB - 8'd1;
            if(latB == 8'd1) begin vg_dataB <= cellword(vg_addrB_px); vg_doneB_s <= ~vg_doneB_s; end
        end
    end

    escape_pf #(.VID_V_BPORCH(V_BPORCH), .VID_V_ACTIVE(V_ACTIVE)) dut (
        .clk(clk), .core_reset_n(rstn),
        .vis_x(vis_x), .visible_x(visible_x), .visible_y(visible_y),
        .x_count(x_count), .y_count(y_count),
        .xscroll(XSCROLL), .yscroll(9'd0),
        .vpshift_s(5'd0), .m_pfmap(1'b0),
        .pf_vaddr(pf_vaddr), .pf_vdata(pf_vdata), .pfx_vdata(pfx_vdata),
        .vg_addrA_px(vg_addrA_px), .vg_addrB_px(vg_addrB_px),
        .vg_reqA_px(vg_reqA_px),   .vg_reqB_px(vg_reqB_px),
        .vg_dataA(vg_dataA), .vg_dataB(vg_dataB),
        .vg_doneA_s(vg_doneA_s), .vg_doneB_s(vg_doneB_s),
        .pf_pix_o(pf_pix), .pf_att_o(pf_att)
    );

    // ---- scoring -----------------------------------------------------------
    integer bad_px, lines_bad, first_ok_min, first_ok_max, lines_scored;
    integer this_line_first_ok, i;
    reg     scoring;

    initial begin
        bad_px = 0; lines_bad = 0; lines_scored = 0;
        first_ok_min = 999; first_ok_max = -1;
        this_line_first_ok = -1; scoring = 0;
        rstn = 0;
        repeat (40) @(posedge clk);
        rstn = 1;
        // let two frames go by so the pipeline is warm and the ring is full
        wait_frames(2);          // warm the pipeline and fill the ring
        scoring = 1;
        wait_frames(3);
        scoring = 0;
        report_result;
        $finish;
    end

    // Frame boundaries come from y_count wrapping. The first version of this
    // waited on `in_active`, which deasserts every LINE, not every frame - so
    // it advanced three lines and scored three. The vacuity guard caught zero
    // but not "implausibly few", which is why there is now a floor as well.
    task wait_frames(input integer n);
        integer k;
        begin
            for(k = 0; k < n; k = k + 1) begin
                @(posedge clk); while(y_count != 10'd0) @(posedge clk);
                @(posedge clk); while(y_count == 10'd0) @(posedge clk);
            end
        end
    endtask

    // per-pixel check inside the active area
    // ---- the ramp property, which needs no geometry -----------------------
    // Each cell is 8 pixels and carries a nibble one greater than the cell to
    // its left, so for every x >= 8:
    //
    //     pix(x) == pix(x-8) + 1   (mod 16)
    //
    // This holds whatever the fine scroll is, because scrolling shifts where
    // the cell boundaries fall but not the fact that cells are 8 apart and
    // increment by one. Stale pixels at the start of a line break it at
    // x = 8..15, which is where the artifact lives.
    reg [3:0] hist [0:335];
    integer   viol_first;
    always @(posedge clk) if(scoring && in_active) begin
        if(visible_x == 0) begin this_line_first_ok = -1; viol_first = -1; end
        hist[visible_x] = pf_pix;
        if(visible_x >= 10'd8) begin
            if(pf_pix !== ((hist[visible_x-8] + 4'd1) & 4'hF)) begin
                bad_px = bad_px + 1;
                if(viol_first < 0) viol_first = visible_x;
            end
        end
        if(visible_x == H_ACTIVE - 1) begin
            lines_scored = lines_scored + 1;
            if(viol_first >= 0) begin
                lines_bad = lines_bad + 1;
                if(viol_first < first_ok_min) first_ok_min = viol_first;
                if(viol_first > first_ok_max) first_ok_max = viol_first;
            end
        end
    end

    task report_result;
        begin
            $display("PFLINE xscroll=%0d  lines scored=%0d  lines with a stale left edge=%0d",
                     XSCROLL, lines_scored, lines_bad);
            $display("PFLINE first ramp violation per line: min x=%0d max x=%0d  (total bad pixels=%0d)",
                     (first_ok_min==999)?0:first_ok_min,
                     (first_ok_max<0)?0:first_ok_max, bad_px);
            // Vacuity guard: a run that scored nothing is not a pass.
            if(lines_scored == 0) begin
                $display("PFLINE VACUOUS: no lines were scored - the raster never entered the");
                $display("  active area, so this run is not evidence either way.");
                $fatal;
            end
            // A run must score roughly V_ACTIVE lines per frame. Scoring a
            // handful means the frame stepping is broken and the numbers
            // describe a transition, not steady state - which is exactly what
            // the first version of this bench did.
            if(lines_scored < 3*V_ACTIVE - V_ACTIVE) begin
                $display("PFLINE VACUOUS: only %0d lines scored, expected ~%0d.",
                         lines_scored, 3*V_ACTIVE);
                $display("  The frame stepping is wrong; do not read the widths above.");
                $fatal;
            end
            if(lines_bad == 0)
                $display("PFLINE GATE: PASS - the cell ramp is unbroken on every line");
            else begin
                $display("PFLINE GATE: FAIL - %0d of %0d lines break the cell ramp",
                         lines_bad, lines_scored);
                $display("  Expected on unfixed RTL. Device says the width is");
                $display("  8 - (xscroll & 7) = %0d for this xscroll.", 8 - (XSCROLL & 7));
            end
        end
    endtask
endmodule

`default_nettype wire
