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

    integer fd;
    integer v, p, mc, mx, pc, px;
    integer rows;

    initial begin
        fd = $fopen("sim/build/prio_sweep.txt", "w");
        // header documents the column order for the python checker
        $fwrite(fd, "# mo_valid mo_prio mo_color mo_pix pf_color pf_pix ");
        $fwrite(fd, "forcemc0 shade m7 pfm mo_win pen\n");
        rows = 0;
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
        end
        $fclose(fd);
        $display("TB_PRIO DONE: %0d rows -> sim/build/prio_sweep.txt", rows);
        $finish;
    end

endmodule

`default_nettype wire
