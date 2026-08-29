// escape_stain: the compositor's apply_stain automaton.
//
// GFXDASH-3: this logic used to live inline in core_top.v, which NO simulation
// script compiles. That is why sim/tools/check_stain_automaton.py tests a
// TRANSCRIPTION of it rather than the shipped instance, and why the stain bug
// this module was extracted to bench survived eleven passing gates. It is now
// one module, instantiated once by core_top.v and once by sim/tb/tb_stain.v,
// so the bench drives the same gates the Pocket ships.
//
// Nothing about the behaviour changed in the extraction: the registers, their
// reset value, the clear condition and the two equations are byte-identical to
// what BUILD 107 shipped. Pure logic - two flip-flops - so the M10K delta is
// structurally zero.
//
// The reference (reference/atarimo.cpp, apply_stain) is:
//
//   offnext = false
//   for (x = x0; x < width; x++) {
//       pf[x] |= 0x400;                        // <-- stain_now
//       if (offnext && !S(x)) break;
//       offnext = E(x);
//   }
//
// restarted at every marker pixel by eprom.cpp's second iterate_dirty_rects
// pass. The union of all those scans is this one-flip-flop recurrence:
//
//   stain(x) = S(x) | alive(x-1)
//   alive(x) = stain(x) & ~( E(x-1) & ~S(x) )
//
// with S = "special (MPR2) pixel here whose pen has bit 1 set" (START_MARKER)
// and E = "...whose pen has bit 2 set" (END_MARKER), matching the reference's
//   START_MARKER = (4 << PRIORITY_SHIFT) | 2
//   END_MARKER   = (4 << PRIORITY_SHIFT) | 4
// exactly (both halves of each mask must match, which is what `spc_hit` in
// escape_mob.v contributes).
//
// A solid marker (pen 6 = both bits) therefore stains its own silhouette plus
// the one pixel past its right edge, exactly like the C loop; a pen-2 marker
// stains to the end of the line, also exactly like the C loop. That second
// mode is the failure signature documented in docs/investigations/GFX_DASH_ARTIFACT.md: a
// marker that loses its END pixel stains to the end of the scanline.
module escape_stain (
    input  wire clk,
    input  wire line_start,    // first cycle of a new scanline (visible_x == 0)
    input  wire s_in,          // START marker at this pixel
    input  wire e_in,          // END marker at this pixel
    output wire stain          // OR 0x400 into the colour-RAM index here
);
    reg  stain_alive = 1'b0;
    reg  stain_e_q   = 1'b0;
    wire stain_now   = s_in | stain_alive;
    wire stain_brk   = stain_e_q & ~s_in;
    assign stain = stain_now;
    always @(posedge clk) begin
        if(line_start) begin                // first cycle of a new line
            stain_alive <= 1'b0;
            stain_e_q   <= 1'b0;
        end else begin
            stain_alive <= stain_now & ~stain_brk;
            stain_e_q   <= e_in;
        end
    end
endmodule
