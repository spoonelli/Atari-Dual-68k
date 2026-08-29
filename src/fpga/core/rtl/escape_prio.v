//
// Escape motion-object vs playfield PRIORITY comparator (the GPC/PAL pair).
//
// Purely combinational; replaces the old fixed "MO always in front of PF"
// ladder in core_top.v. Transcribed from the GAL equations verified off the
// real PCB and quoted in reference/eprom.cpp (screen_update_eprom):
//
//   FORCEMC0 = !PFX3*PFX4*PFX5*!MPR0
//            + !PFX3*PFX5*!MPR1
//            + !PFX3*PFX4*!MPR0*!MPR1
//
//   !SHADE   = !MPX0 + MPX1 + MPX2 + MPX3 + !MPX4*!MPX5*!MPX6*!MPX7 + FORCEMC0
//
//   !PF/M    = MPR0*MPR1 + PFX3 + !PFX4*MPR1 + !PFX5*MPR1 + !PFX5*MPR0
//            + !PFX4*!PFX5*!MPR0*!MPR1
//
//   M7       = MPX0*!MPX1*!MPX2*!MPX3
//
//   CRA10 = CL10 (1 if pf), CRA9 = SHADE*CL10 + CL9 (1 if mo)
//
// Signal mapping into this core's pixel pipeline (derived from MAME's
// tile-info + pen construction for eprom - see docs/investigations/mo_priority.md):
//
//   MPR2:MPR0  motion-object entry word 2 bits [6:4]   (config mask 0x0070)
//   MPX7:MPX4  motion-object colour  = mo_pen[7:4]
//   MPX3:MPX0  motion-object pixel   = mo_pen[3:0]
//   PFX5:PFX4  playfield priority    = low two bits of the playfield tile
//              colour attribute, i.e. pf_att[1:0] = pfx_vdata[9:8], because
//              MAME's playfield pen is 0x200 | (colour<<4) | pixel and the
//              reference reads pfpriority as (pf[x] >> 4) & 3
//   PFX3       playfield pixel bit 3 = pf_pix[3]  (reference: pf[x] & 8)
//
// MPR2 never reaches this module. escape_mob.v does write special
// (mopriority & 4) pixels into the line buffer - they have to be there to mask
// normal sprites and to drive the stain pass (MOSTAIN-1) - but it clears
// disp_valid for them, so this comparator sees exactly what the reference's
// first pass sees after its `continue`.
//
// The two derived facts below are proved exhaustively by sim/tb/tb_prio.v
// against sim/tools/mo_priority_model.py (a literal transcription of the
// reference), over all 2*4*16*16*16*16 input combinations:
//
//   FORCEMC0 == PF/M == (!PFX3 && mo_prio < pf_prio)
//   MO wins  == (PFX3 || mo_prio >= pf_prio) && !M7
//
// Because FORCEMC0 and PF/M are the same function, FORCEMC0 is never set on
// the branch where the MO wins, so the reference's `mo & DATA_MASK & ~0x70`
// (the "force 3 bits of the MO colour to 0") arm is unreachable. It is left
// out of the hardware deliberately; the equivalence is machine-checked.
//
`default_nettype none

module escape_prio (
    // motion object at this pixel
    input  wire       mo_valid,      // line buffer has a (non-special) MO pixel
    input  wire [1:0] mo_prio,       // MPR1:MPR0
    input  wire [3:0] mo_color,      // MPX7:MPX4
    input  wire [3:0] mo_pix,        // MPX3:MPX0
    // playfield at this pixel
    input  wire [3:0] pf_color,      // tile colour attribute nibble
    input  wire [3:0] pf_pix,        // playfield 4bpp pixel

    // decoded ASIC signals (exported for the bench / debug)
    output wire       forcemc0,
    output wire       shade,
    output wire       m7,
    output wire       pfm,
    output wire       mo_win,        // CL9: render the motion object

    // resulting 11-bit colour RAM index (CRA10..CRA0)
    output wire [10:0] pen
);

    wire [1:0] pf_prio = pf_color[1:0];   // PFX5:PFX4
    wire       pfx3    = pf_pix[3];       // PFX3

    // --- FORCEMC0 (sum of products, literally) ---------------------------
    wire fmc = (~pfx3 &  pf_prio[0] &  pf_prio[1] & ~mo_prio[0])
             | (~pfx3 &  pf_prio[1] &                ~mo_prio[1])
             | (~pfx3 &  pf_prio[0] & ~mo_prio[0] & ~mo_prio[1]);
    assign forcemc0 = mo_valid & fmc;

    // --- PF/M -------------------------------------------------------------
    wire n_pfm = ( mo_prio[0] &  mo_prio[1])
               |   pfx3
               | (~pf_prio[0] &  mo_prio[1])
               | (~pf_prio[1] &  mo_prio[1])
               | (~pf_prio[1] &  mo_prio[0])
               | (~pf_prio[0] & ~pf_prio[1] & ~mo_prio[0] & ~mo_prio[1]);
    assign pfm = mo_valid & ~n_pfm;

    // --- M7 ---------------------------------------------------------------
    wire m7_raw = (mo_pix == 4'd1);
    assign m7 = mo_valid & m7_raw;

    // --- SHADE ------------------------------------------------------------
    assign shade = mo_valid & m7_raw & (mo_color != 4'd0) & ~fmc;

    // --- layer select -----------------------------------------------------
    // reference: if (!pfm && !m7) -> MO, else -> PF
    assign mo_win = mo_valid & ~pfm & ~m7;

    // --- colour RAM index -------------------------------------------------
    // MO branch : pen = mo & DATA_MASK = 0x100 | colour<<4 | pixel  (CRA9=1)
    // PF branch : pen = 0x200 | colour<<4 | pixel  (CRA10=1), then
    //               |0x100 if SHADE  -> CRA9, the alternate PF colour bank
    //               |0x080 if M7     -> the upper MO bit fed to the GPC
    wire [10:0] mo_pen11 = {3'b001, mo_color, mo_pix};
    wire [10:0] pf_pen11 = {2'b01, shade, pf_color[3] | m7, pf_color[2:0], pf_pix};

    assign pen = mo_win ? mo_pen11 : pf_pen11;

endmodule

`default_nettype wire
