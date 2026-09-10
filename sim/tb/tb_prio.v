//
// tb_prio.v - exhaustive sweep of escape_prio.v.
//
// Walks every input combination of the priority comparator
//   mo_valid(2) x mo_prio(4) x mo_color(16) x mo_pix(16)
//              x pf_color(16) x pf_pix(16)     = 524288 rows
// and writes each row's inputs plus every decoded ASIC signal and the final
// colour RAM index to sim/build/prio_sweep.txt.
//
// sim/tools/check_prio.py replays the same rows through
// sim/tools/mo_priority_model.py - a literal transcription of the equations
// and the merge loop in reference/eprom.cpp - and reports agreement.
//
`default_nettype none
`timescale 1ns/1ns

module tb_prio;

    reg        mo_valid;
    reg  [1:0] mo_prio;
    reg  [3:0] mo_color, mo_pix, pf_color, pf_pix;

    wire       forcemc0, shade, m7, pfm, mo_win;
    wire [10:0] pen;

escape_prio dut (
    .guts(1'b0),
    .mo_valid ( mo_valid ),
    .mo_prio  ( mo_prio ),
    .mo_color ( mo_color ),
    .mo_pix   ( mo_pix ),
    .pf_color ( pf_color ),
    .pf_pix   ( pf_pix ),
    .forcemc0 ( forcemc0 ),
    .shade    ( shade ),
    .m7       ( m7 ),
    .pfm      ( pfm ),
    .mo_win   ( mo_win ),
    .pen      ( pen )
);

    // GUTS-168: a second comparator in Guts mode, checked in-line against the
    // rule transcribed from MAME screen_update_guts (the only reference):
    //   MO wins iff mo_valid && (!PFX3 || mo_prio >= pf_color[2:1]);
    //   pen = MO ? 0x100|colour<<4|pix : 0x200|colour<<4|pix; no SHADE, no
    //   FORCEMC0, no M7, no PF/M.
    wire       g_forcemc0, g_shade, g_m7, g_pfm, g_mo_win;
    wire [10:0] g_pen;
escape_prio dut_guts (
    .guts(1'b1),
    .mo_valid ( mo_valid ),
    .mo_prio  ( mo_prio ),
    .mo_color ( mo_color ),
    .mo_pix   ( mo_pix ),
    .pf_color ( pf_color ),
    .pf_pix   ( pf_pix ),
    .forcemc0 ( g_forcemc0 ),
    .shade    ( g_shade ),
    .m7       ( g_m7 ),
    .pfm      ( g_pfm ),
    .mo_win   ( g_mo_win ),
    .pen      ( g_pen )
);
    wire        g_exp_win = mo_valid && (!pf_pix[3] || (mo_prio >= pf_color[2:1]));
    wire [10:0] g_exp_pen = g_exp_win ? {3'b001, mo_color, mo_pix} : {2'b01, 1'b0, pf_color, pf_pix};
    integer g_bad;

    integer fd;
    integer v, p, mc, mx, pc, px;
    integer rows;

    initial begin
        fd = $fopen("sim/build/prio_sweep.txt", "w");
        // header documents the column order for the python checker
        $fwrite(fd, "# mo_valid mo_prio mo_color mo_pix pf_color pf_pix ");
        $fwrite(fd, "forcemc0 shade m7 pfm mo_win pen\n");
        rows = 0; g_bad = 0;
        for (v = 0; v <= 1; v = v + 1)
        for (p = 0; p < 4; p = p + 1)
        for (mc = 0; mc < 16; mc = mc + 1)
        for (mx = 0; mx < 16; mx = mx + 1)
        for (pc = 0; pc < 16; pc = pc + 1)
        for (px = 0; px < 16; px = px + 1) begin
            mo_valid = v[0];
            mo_prio  = p[1:0];
            mo_color = mc[3:0];
            mo_pix   = mx[3:0];
            pf_color = pc[3:0];
            pf_pix   = px[3:0];
            #1;
            $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    mo_valid, mo_prio, mo_color, mo_pix, pf_color, pf_pix,
                    forcemc0, shade, m7, pfm, mo_win, pen);
            rows = rows + 1;
            if (g_mo_win !== g_exp_win || g_pen !== g_exp_pen ||
                g_forcemc0 !== 1'b0 || g_shade !== 1'b0 || g_m7 !== 1'b0 || g_pfm !== 1'b0) begin
                if (g_bad < 10)
                    $display("GUTS PRIO MISMATCH v=%0d mp=%0d mc=%0d mx=%0d pc=%0d px=%0d: win %0d exp %0d pen %03x exp %03x",
                             mo_valid, mo_prio, mo_color, mo_pix, pf_color, pf_pix, g_mo_win, g_exp_win, g_pen, g_exp_pen);
                g_bad = g_bad + 1;
            end
        end
        $fclose(fd);
        $display("TB_PRIO DONE: %0d rows -> sim/build/prio_sweep.txt", rows);
        if (g_bad == 0) $display("GUTS PRIO CHECK PASS: Guts-mode comparator matches screen_update_guts on all %0d rows", rows);
        else            $display("GUTS PRIO CHECK FAIL: %0d mismatching rows", g_bad);
        $finish;
    end

endmodule

`default_nettype wire
