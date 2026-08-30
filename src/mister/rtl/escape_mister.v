//============================================================================
// Atari "Escape from the Planet of the Robot Monsters" - MiSTer machine
// assembly.
//
// This is the MiSTer equivalent of the portable half of the Pocket's
// src/fpga/core/core_top.v.  It instantiates the SAME machine RTL:
//
//     escape_core   (src/fpga/core/rtl/escape_core.vhd)  - dual 68000 + JSA
//     escape_mob    (src/fpga/core/rtl/escape_mob.v)     - motion objects
//     escape_prio   (src/fpga/core/rtl/escape_prio.v)    - MO/PF priority
//     escape_stain  (src/fpga/core/rtl/escape_stain.v)   - apply_stain pass
//     hall_stick    (src/fpga/core/rtl/hall_stick.v)     - analog stick model
//     sdram_simple  (src/fpga/core/rtl/sdram_simple.v)   - SDRAM controller
//
// Nothing in the machine is forked.  What lives here is platform glue:
// the ROM download writer, the SDRAM arbiter, the raster generator, and the
// playfield / alphanumerics scanout pipelines.
//
// ---------------------------------------------------------------------------
// DIFFERENCES FROM THE POCKET BUILD - read these before debugging hardware
// ---------------------------------------------------------------------------
// 1. NO SECOND MEMORY BUS.  The Pocket serves playfield graphics from its
//    CRAM/PSRAM chip and only the CPUs + motion objects from SDRAM.  The
//    DE10-Nano has one SDRAM and no PSRAM, so the playfield graphics channel
//    (vg A/B) has been moved onto the SDRAM arbiter alongside the motion
//    objects.  PF and MO share the lowest priority tier round-robin.
//    MiSTer does NOT use the psram/CLOCK_SPEED path at all - third_party's
//    psram.sv is not in this project's file list.
//
// 2. SDRAM CLOCK IS UNCHANGED at 35.795455 MHz (5 x CPU) with the same +90
//    degree chip-clock phase the Pocket ships.  It is tempting to raise it to
//    pay for (1), but sdram_simple's CL2 read FSM captures on a fixed cycle
//    count and its margin was tuned empirically against THIS frequency and
//    THIS phase - raising one without re-tuning the other is how you get
//    reads that return the right-looking wrong data.  The cost is that the
//    playfield now competes for a bus that was already the tightest resource
//    in the design.  THIS IS THE #1 THING TO WATCH ON FIRST FLASH.
//
// 3. ALL reads carry rd_pre = 1 (precharge-all armor) since MISTER-133.
//    PF originally used the rd_pre = 0 fast path on the theory that "a
//    wrong-row serve on a PF read is one wrong tile row for one frame" -
//    device captures (131/132) showed those serves are frequent enough to
//    be constant visible garbage, and PF was the one client without armor,
//    which is exactly why only the playfield showed it.
//
// 4. No debug HUD, no Interact menu, no test-tone, no layer isolation.  The
//    Pocket's forensics tooling is deliberately absent.
//
// 5. Sprite graphics arrive from the MRA as four interleaved bit-planes and
//    are converted to the chunky 4bpp layout the machine expects by the
//    download writer below (see the SPRITE REPACK block).  The Pocket does
//    the same transform offline in support/build_rom.py.
//
// 6. EEPROM persistence (BUILD 103, rtl/ee_save.vhd) is NOT wired here.  That
//    engine talks to the APF bridge and data slots directly, so it is Pocket
//    -only; escape_core's ee_* ports all carry defaults and are left open.
//    High scores and operator settings therefore do not survive a power cycle
//    on MiSTer yet.  The MiSTer-native route is an <nvram index="4" size="512">
//    element in the .mra plus the matching hps_io ioctl index-4 wiring.
//    Because ee_save.vhd is not compiled here, its two "MLAB" ramstyle
//    attributes - which exist only because the Pocket has zero spare M10K -
//    cost this build nothing, so they are deliberately left alone rather than
//    forked.
//============================================================================
`default_nettype none

module escape_mister (
    input  wire        clk_sys,      //  7.159091 MHz - CPU + pixel domain
    input  wire        clk_sdram,    // 35.795455 MHz - SDRAM controller domain
    input  wire        pll_locked,
    input  wire        reset,        // active high, async-ish (from sys_top)

    // ---- ROM download (MiSTer ioctl, clk_sdram domain) --------------------
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [24:0] ioctl_addr,
    input  wire [7:0]  ioctl_dout,
    output wire        ioctl_wait,

    // ---- SDRAM chip -------------------------------------------------------
    output wire [12:0] SDRAM_A,
    output wire [1:0]  SDRAM_BA,
    inout  wire [15:0] SDRAM_DQ,
    output wire        SDRAM_DQML,
    output wire        SDRAM_DQMH,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nWE,
    output wire        SDRAM_CKE,

    // ---- video (clk_sys domain, one pixel per clock) ----------------------
    output reg  [7:0]  VGA_R,
    output reg  [7:0]  VGA_G,
    output reg  [7:0]  VGA_B,
    output reg         HSync,
    output reg         VSync,
    output reg         HBlank,
    output reg         VBlank,

    // ---- audio ------------------------------------------------------------
    output wire [15:0] audio_l,
    output wire [15:0] audio_r,

    // ---- controls (any domain; synchronised inside) -----------------------
    input  wire        p1_up, p1_down, p1_left, p1_right,
    input  wire        p1_fire, p1_jump, p1_duck, p1_bomb,
    input  wire        p2_up, p2_down, p2_left, p2_right,
    input  wire        p2_fire, p2_jump, p2_duck, p2_bomb,
    input  wire [15:0] p1_analog,   // {y[15:8], x[7:0]}, 0x80 centred
    input  wire [15:0] p2_analog,
    input  wire        p1_has_analog,
    input  wire        p2_has_analog,
    input  wire        coin1,
    input  wire        coin2,
    input  wire        start1,      // doubles as the self-test step/continue key
    input  wire        service,     // active high = service mode
    input  wire        skip_test,
    // VSHAD3-112 runtime toggle for the 16 KB partial ROM shadow at 0x54000.
    // 1 = shadow serves 0x54000-0x57FFF from BRAM (default, matches the
    // Pocket's Interact id 37 default); 0 = those addresses take the SDRAM
    // fastpath instead.  The BRAM is instantiated and filled either way, so
    // this costs no M10K and the owner can A/B it on the device without a
    // reflash.  Synchronised into clk_sys below, then resampled inside
    // escape_core only between bus cycles.  See Arcade-Escape.sv CONF_STR.
    input  wire        vshad3_on,

    // MISTER-132: OSD audio sliders (CONF_STR options, default-max via the
    // inverted-sense convention documented there) and the credits overlay
    // page from the mappable Credits button (0 = off).
    input  wire [2:0]  uvol_ym,
    input  wire [2:0]  uvol_tms,
    input  wire [1:0]  credits_page,

    // ---- status -----------------------------------------------------------
    output wire        rom_ready    // SDRAM up, image loaded, self-check done
);

// ===========================================================================
// raster generator - identical geometry to the Pocket build
//   456 x 262 total, 336 x 240 active, 7.159091 MHz -> 59.9227 Hz
// ===========================================================================
localparam VID_V_BPORCH = 10'd12;
localparam VID_V_ACTIVE = 10'd240;
localparam VID_V_TOTAL  = 10'd262;
localparam VID_H_BPORCH = 10'd60;
localparam VID_H_ACTIVE = 10'd336;
localparam VID_H_TOTAL  = 10'd456;
// sync pulses live in the front porch (active .. front porch .. sync .. back
// porch).  The Pocket emitted 1-clock pulses, which the APF scaler accepts;
// MiSTer's scandoubler/ascal need real widths.
localparam HS_START = 10'd404, HS_END = 10'd436;   // 32 clocks
localparam VS_START = 10'd254, VS_END = 10'd257;   // 3 lines

reg [9:0] x_count = 10'd0;
reg [9:0] y_count = 10'd0;

wire [9:0] visible_x = x_count - VID_H_BPORCH;
wire [9:0] visible_y = y_count - VID_V_BPORCH;
wire [9:0] vis_x     = x_count - VID_H_BPORCH;     // alias used by the pipelines

wire h_active = (x_count >= VID_H_BPORCH) && (x_count < VID_H_BPORCH + VID_H_ACTIVE);
wire v_active = (y_count >= VID_V_BPORCH) && (y_count < VID_V_BPORCH + VID_V_ACTIVE);
wire vblank_w = ~v_active;                          // what escape_core sees

always @(posedge clk_sys) begin
    x_count <= x_count + 10'd1;
    if (x_count == VID_H_TOTAL - 10'd1) begin
        x_count <= 10'd0;
        y_count <= (y_count == VID_V_TOTAL - 10'd1) ? 10'd0 : y_count + 10'd1;
    end
end

// ===========================================================================
// reset / core release
// ===========================================================================
wire        sdram_init_done;
reg         chk_done  = 1'b0;
reg         chk_ok    = 1'b0;
reg         chk2_ok   = 1'b0;
wire        sdram_init_done_s, chk_done_s, dl_idle_s;

sync2 s_sid (clk_sys, sdram_init_done, sdram_init_done_s);
sync2 s_cdn (clk_sys, chk_done,        chk_done_s);
sync2 s_dli (clk_sys, ~ioctl_download, dl_idle_s);

assign rom_ready = sdram_init_done_s & chk_done_s & dl_idle_s;

// watchdog / freeze rescue - kept from the Pocket build.  A watchdog timeout,
// a dead extra CPU or a wedged inter-CPU mailbox reboots the machine instead
// of leaving a frozen screen.
wire wdog_expired, e_dead, mbox_dead;
reg [22:0] wdog_rst_ctr = 23'd0;
reg        wdog_exp_d   = 1'b0;
reg        reset_s_1 = 1'b1, reset_s = 1'b1;
always @(posedge clk_sys) begin
    reset_s_1 <= reset;
    reset_s   <= reset_s_1;
    wdog_exp_d <= wdog_expired | e_dead | mbox_dead;
    if (reset_s) begin
        wdog_rst_ctr <= 23'd0;
    end else if ((wdog_expired || e_dead || mbox_dead) && !wdog_exp_d) begin
        wdog_rst_ctr <= 23'd1;
    end else if (wdog_rst_ctr != 23'd0) begin
        wdog_rst_ctr <= wdog_rst_ctr + 23'd1;   // ~1.17 s pulse @ 7.16 MHz
    end
end
wire wdog_rst = (wdog_rst_ctr != 23'd0);

wire core_reset_n = ~reset_s & rom_ready & ~wdog_rst;
reg  core_rstn_sd = 1'b0;
always @(posedge clk_sdram) core_rstn_sd <= core_reset_n;

// ===========================================================================
// ROM DOWNLOAD WRITER (clk_sdram domain - hps_io runs on clk_sdram)
//
// Stream layout produced by the .mra (see src/mister/releases/*.mra):
//   0x000000  0x080000  maincpu, 68000 even/odd interleaved
//   0x080000  0x020000  extra CPU own program
//   0x0A0000  0x040000  filler
//   0x0E0000  0x020000  shared program copy (extra CPU view of 0x60000)
//   0x100000  0x010000  JSA 6502 program + TMS5220 speech
//   0x110000  0x004000  alphanumerics
//   0x114000  0x00C000  filler
//   0x120000  0x100000  sprite/tile graphics, FOUR INTERLEAVED BIT-PLANES
//
// Everything below 0x120000 is written through unchanged.  The sprite region
// is repacked byte-for-byte into the chunky 4bpp form the machine reads.
// ===========================================================================
localparam [24:0] SPR_BASE = 25'h0120000;

reg  [7:0]  dlb0, dlb1, dlb2;      // first three bytes of the current group
reg  [24:0] dl_addr_q;
reg  [31:0] dl_data_q;
reg         dl_req      = 1'b0;    // level request into the writer FSM
reg         dl_pending  = 1'b0;
reg         dl_taken    = 1'b0;    // writer FSM finished the queued group
// SDRAM write port (driven by the writer FSM further down)
reg         sd_wr_req = 1'b0;
reg  [24:0] sd_wr_addr;
reg  [31:0] sd_wr_data;
wire        sd_wr_ack;
reg  [2:0]  dl_phase = 3'd0;   // MISTER-150: grew a mirror-write leg

// ---- SPRITE REPACK --------------------------------------------------------
// b0..b3 are the four bit-planes for one tile-row byte index, ALREADY in
// stream order (the .mra interleaves them).  MAME declares this region
// ROMREGION_INVERT, so every byte is complemented first; then plane bits are
// gathered into 4-bit pixels, two per output byte, plane0 = MSB.
// This is exactly what support/build_rom.py does offline for the Pocket.
function [7:0] chunky2;
    input [7:0] b0, b1, b2, b3;
    input [2:0] n0;                 // bit index of the first of the two pixels
    begin
        chunky2 = { b0[3'd7-n0], b1[3'd7-n0], b2[3'd7-n0], b3[3'd7-n0],
                    b0[3'd6-n0], b1[3'd6-n0], b2[3'd6-n0], b3[3'd6-n0] };
    end
endfunction

wire [7:0] iv0 = ~dlb0, iv1 = ~dlb1, iv2 = ~dlb2, iv3 = ~ioctl_dout;
wire [31:0] spr_word = { chunky2(iv0, iv1, iv2, iv3, 3'd0),
                         chunky2(iv0, iv1, iv2, iv3, 3'd2),
                         chunky2(iv0, iv1, iv2, iv3, 3'd4),
                         chunky2(iv0, iv1, iv2, iv3, 3'd6) };
wire [31:0] raw_word = { dlb0, dlb1, dlb2, ioctl_dout };
wire        in_spr   = (ioctl_addr >= SPR_BASE);

always @(posedge clk_sdram) begin
    if (ioctl_wr && ioctl_download) begin
        case (ioctl_addr[1:0])
            2'd0: dlb0 <= ioctl_dout;
            2'd1: dlb1 <= ioctl_dout;
            2'd2: dlb2 <= ioctl_dout;
            default: begin
                dl_addr_q  <= {ioctl_addr[24:2], 2'b00};
                dl_data_q  <= in_spr ? spr_word : raw_word;
                dl_req     <= 1'b1;
                dl_pending <= 1'b1;
            end
        endcase
    end
    if (dl_taken) begin dl_req <= 1'b0; dl_pending <= 1'b0; end
    // NOTE: deliberately NOT cleared when ioctl_download drops.  hps_io
    // deasserts ioctl_download right after the last byte, and the last group
    // is still queued at that moment - clearing here would silently drop the
    // final four bytes of the image.  dl_taken is the only thing that retires
    // a group, and the self-check FSM below waits on !dl_pending before it
    // releases the machine.
end

// backpressure: hold the HPS off while a group is still queued or the PLL is
// not up.  A group is 4 bytes and a burst write is ~10 clocks at 35.8 MHz, so
// this only ever throttles at the very top of the HPS transfer rate.  Three
// bytes of slack exist by construction: only the 4th byte of a group latches
// the request, so up to three in-flight bytes after ioctl_wait rises are
// still captured correctly.
assign ioctl_wait = ~pll_locked | dl_pending;

// v58 hot-code shadow fill: escape_core keeps a 64 KB BRAM shadow per CPU
// covering its low address space, filled from this same stream.
reg [23:0] shad_waddr = 24'd0;
reg [15:0] shad_wdata = 16'd0;
reg        shad_we    = 1'b0;
reg [15:0] shad_pend  = 16'd0;
reg        shad_second= 1'b0;

always @(posedge clk_sdram) begin
    dl_taken <= 1'b0;
    if (shad_second) begin
        shad_waddr  <= shad_waddr + 24'd2;
        shad_wdata  <= shad_pend;
        shad_we     <= 1'b1;
        shad_second <= 1'b0;
    end else begin
        shad_we <= 1'b0;
    end
    case (dl_phase)
    3'd0: if (dl_req) begin
        sd_wr_addr <= dl_addr_q;
        sd_wr_data <= dl_data_q;
        sd_wr_req  <= 1'b1;
        dl_phase   <= 2'd1;
        shad_waddr <= dl_addr_q[23:0];
        shad_wdata <= dl_data_q[31:16];
        shad_we    <= 1'b1;
        shad_pend  <= dl_data_q[15:0];
        shad_second<= 1'b1;
    end
    3'd1: if (sd_wr_ack) begin
        sd_wr_req <= 1'b0;
        dl_phase  <= 3'd2;
    end
    3'd2: if (!sd_wr_ack) begin
        // MISTER-150 MO TILE MIRROR: sprite-region groups are written twice -
        // primary (bank 3, the playfield's copy) and byte +0x4E0000 (bank 2,
        // the motion objects' copy). PF and MO stop evicting each other's
        // open rows: the Pocket's PSRAM separation, rebuilt out of bank
        // partitioning. ioctl_wait backpressure absorbs the extra write.
        // MISTER-151: the mirror address MUST come from the FSM-latched
        // sd_wr_addr, never from dl_addr_q - the accumulator overwrites
        // dl_addr_q the moment a following group's 4th byte lands, and the
        // doubled write window widens that race. A clobbered dl_addr_q here
        // wrote the WRONG tile into the mirror: persistent, download-
        // dependent sprite corruption (owner frames 7548/4985, build 150).
        if (sd_wr_addr >= SPR_BASE) begin
            sd_wr_addr <= sd_wr_addr + 25'h04E0000;
            sd_wr_req  <= 1'b1;
            dl_phase   <= 3'd3;
        end else begin
            dl_taken <= 1'b1;
            dl_phase <= 3'd0;
        end
    end
    3'd3: if (sd_wr_ack) begin
        sd_wr_req <= 1'b0;
        dl_phase  <= 3'd4;
    end
    3'd4: if (!sd_wr_ack) begin
        dl_taken <= 1'b1;
        dl_phase <= 3'd0;
    end
    default: dl_phase <= 3'd0;
    endcase
end

// ===========================================================================
// SDRAM read clients
// ===========================================================================
wire [23:0] core_rom_addr;
wire        core_rom_req;
reg  [31:0] core_rom_data;
reg         core_rom_par;
reg  [3:0]  core_rom_par4;
reg         core_rom_ack_85 = 1'b0;
wire [31:0] sd_rd_data;
reg         sd_rd_req = 1'b0;
reg  [24:0] rd_addr_q;
reg         rd_pre_q  = 1'b1;
wire        sd_rd_ack;

// single-FF crossings: the two clocks are same-PLL siblings (5:1) and the SDC
// declares them one synchronous group, so these are timed paths.  This is the
// Pocket build's SDSCHED-73/74 arrangement, unchanged.
reg core_rom_req_s_q;
always @(posedge clk_sdram)  core_rom_req_s_q <= core_rom_req;
wire core_rom_req_s = core_rom_req_s_q;
reg core_rom_ack_s_q;
always @(posedge clk_sys)    core_rom_ack_s_q <= core_rom_ack_85;
wire core_rom_ack_s = core_rom_ack_s_q;

// ---- zero-wait per-CPU fastpath caches (SDSCHED-88) -----------------------
// ON, and measured: the worst path across this 7.16 -> 35.8 MHz crossing is
//     escape_core|TG68K:vcpu|TG68KdotC_Kernel:cpu1|RDindex_A[2]  ->  fpv_spec_s
// at +15.537 ns of setup slack against a 27.939 ns budget.
//
// That is worth recording because this port briefly shipped FASTPATH_EN=0 on
// the theory that this cone caused the first build's -5.538 ns setup failure.
// It did not. The real cause was entirely in escape.sdc: a setup multicycle on
// the SDRAM read return with no matching hold multicycle demanded that read
// data still be in flight 27.9 ns after launch, the fitter padded routing to
// chase an impossible hold requirement, and the setup failure was collateral
// damage from that padding. Fixing the SDC took the 35.8 MHz domain from
// -5.538/-10.922 to +15.133/+0.253 with this fastpath left fully enabled.
//
// The lesson is the project's own: the elimination argument for blaming this
// cone was sound and wrong. Read the timing report, not the hypothesis.
localparam FASTPATH_EN = 1;
localparam TASLOCK_EN  = 1;
wire [23:0] fpv_addr_w, fpe_addr_w;
wire        fpv_spec_w, fpe_spec_w;
reg  [23:0] fpv_addr_s = 24'd0, fpe_addr_s = 24'd0;
reg         fpv_spec_s = 1'b0, fpe_spec_s = 1'b0;
always @(posedge clk_sdram) begin
    fpv_addr_s <= fpv_addr_w;  fpv_spec_s <= fpv_spec_w;
    fpe_addr_s <= fpe_addr_w;  fpe_spec_s <= fpe_spec_w;
end
reg  [23:0] fpv_tag = 24'd0, fpe_tag = 24'd0;
reg         fpv_valid = 1'b0, fpe_valid = 1'b0;
reg         fpv_vpre  = 1'b0, fpe_vpre  = 1'b0;
reg  [15:0] fpv_data = 16'd0,  fpe_data = 16'd0;
reg         fpv_owner = 1'b0, fpe_owner = 1'b0;
reg         fpv_ready_q = 1'b0, fpe_ready_q = 1'b0;
reg         fp_last_v = 1'b0;
wire fpv_want = FASTPATH_EN && core_rstn_sd && fpv_spec_s && !fpv_owner
                && !fpv_vpre && !(fpv_valid && fpv_tag == fpv_addr_s);
wire fpe_want = FASTPATH_EN && core_rstn_sd && fpe_spec_s && !fpe_owner
                && !fpe_vpre && !(fpe_valid && fpe_tag == fpe_addr_s);
always @(posedge clk_sdram) begin
    fpv_ready_q <= FASTPATH_EN && fpv_valid && fpv_spec_s && (fpv_tag == fpv_addr_s);
    fpe_ready_q <= FASTPATH_EN && fpe_valid && fpe_spec_s && (fpe_tag == fpe_addr_s);
end

// ---- motion-object gfx channels (MOCHAN-4: four, packed) -------------------
// BUILD 104 widened the engine from an A/B ping-pong to four channels and gave
// core_top a REGISTERED arbitration pre-decode so the grant condition sees one
// flop bit instead of a widening XOR/OR tree.  That pre-decode is reproduced
// here verbatim in intent, and it matters more on MiSTer than on the Pocket:
// the grant is the tightest path in the design AND our first build missed
// setup on this very clock domain, so keeping combinational depth off the
// shared grant is not optional here.
wire [3:0]   mo_gfx_req;
wire [95:0]  mo_gfx_addr;              // 4 x 24
reg  [3:0]   mg_req_last;
reg  [3:0]   mg_done_85 = 4'd0;
// CDCSET-136: DONE-RETURN SETTLE STAGES. The completion used to write the
// data register and flip the done toggle on the SAME clk_sdram edge; the
// 7.159 side syncs the toggle through ONE flop, and with the two clocks
// phase-locked 5:1 its capture edge can land ~0 ns behind the data bus
// (the documented near-zero hold cluster) - the consumer then reads the
// crossing bus mid-transition. That is the fixed-sprite garble (tile data
// arriving as bit soup) and, before PF-first hid it, part of the playfield
// static. The Pocket pays ~400 ns of deliberate done-return delay for
// exactly this reason (SDSCHED-74); these two-edge delay lines are that
// arrangement, ported: data lands, TWO clk_sdram periods pass (55.9 ns,
// two full clk_sys setup margins), then the toggle flips.
reg  [3:0]   mg_done_set_d1 = 4'd0, mg_done_set_d2 = 4'd0;
reg  [1:0]   vg_done_set_d1 = 2'd0, vg_done_set_d2 = 2'd0;
reg  [1:0]   rom_ack_dly = 2'd0;
reg  [127:0] mg_data;                  // 4 x 32
reg          mo_owner = 1'b0;
reg  [1:0]   mo_sd_ch = 2'd0;
reg  [3:0]   mg_req_s_q;
always @(posedge clk_sdram) mg_req_s_q <= mo_gfx_req;
wire [3:0] mg_req_s = mg_req_s_q;
reg  [3:0] mg_done_s_q;
always @(posedge clk_sys) mg_done_s_q <= mg_done_85;
wire [3:0] mg_done_s = mg_done_s_q;

// MOCACHE-119 (ported from Pocket): shared tile-row cache in front of the MO
// fetch channels. Same module, same reasoning - the tile-hole artifact peaks
// where sprite density peaks, and dense on this game means many copies of the
// SAME sprite, so the identical tile row is fetched repeatedly per line on a
// bus where MO is the lowest-priority client.
//
// Sits between escape_mob and the fetcher with the same interface on both
// sides, so the MO state machine is untouched. Pixel domain, like escape_mob,
// and mg_done_s is already synchronised into it, so the clk_sdram CDC boundary
// is unchanged. ramstyle=MLAB inside, so it takes no block RAM.
//
// STATUS: correct and transparent in simulation; its BENEFIT is not proven -
// see the Pocket-side note and docs/investigations/MO_TILE_HOLES.md. Shipped so the MiSTer
// build stays in step with Pocket rather than silently diverging.
wire [3:0]   moc_req;
wire [95:0]  moc_addr;
wire [3:0]   moc_done;
wire [127:0] moc_data;
wire [15:0]  moc_hit, moc_miss;

// MOCACHE-128 (ported): cache bypassed - device A/B (121 vs 122) found
// no-cache better and the pocket shipping path removed it in build 128.
assign moc_done    = mg_done_s;
assign moc_data    = mg_data;
assign mo_gfx_req  = moc_req;
assign mo_gfx_addr = moc_addr;
assign moc_hit     = 16'd0;
assign moc_miss    = 16'd0;
`ifdef MOCACHE_ENABLED
escape_mo_cache #(.ENTRIES(32), .IDXBITS(5)) u_mo_cache (
    .clk(clk_sys), .reset_n(core_reset_n),
    .mo_req(moc_req),   .mo_addr(moc_addr),
    .mo_done(moc_done), .mo_data(moc_data),
    .mem_req(mo_gfx_req), .mem_addr(mo_gfx_addr),
    .mem_done(mg_done_s), .mem_data(mg_data),
    .hit_cnt(moc_hit),  .miss_cnt(moc_miss)
);
`endif


// Registered MO pre-decode. Safety of looking one cycle back is the same
// argument core_top makes: mg_req_last only ever CLEARS a pending bit, and
// only in the grant arm, which also sets mo_owner - and the grant requires
// !mo_owner, so a stale bit can never fire a second grant. Everything else
// only ADDS pending bits, and the engine holds gfx_addr stable until the
// completion returns.
wire [3:0] mg_pend_w = mg_req_s ^ mg_req_last;
// MOARB-138: AGE-BOUNDED first-class MO, clk_sdram domain.
// The 137 port copied the Pocket's blanket rule - MO outranks speculative
// fastpath fills whenever it pends during active video - and it was
// catastrophic here (owner: "unbelievably slow refresh", even the boot
// self-test crawled). The platform difference the port missed: on the
// Pocket, MO is the only client sharing the bus with the CPUs, so blocking
// the fastpath interleaves MO/CPU one-for-one. On MiSTer, PF already owns
// the top of this arbiter and eats half the active-line bus - a blanket MO
// boost left the CPUs almost no active-video service at all, and the 68ks
// ran essentially in blanking only.
// The fix keeps the intent (MO must not STARVE) and drops the dominance:
// MO gets first-class rank only after its oldest pending fetch has waited
// AGE_BOOST clk_sdram cycles (~0.9 us - several CPU fetches' worth).
// MOARB-139: the 138 cut reset the age only when the pending SET emptied.
// The MO engine keeps its queue non-empty for entire active lines (garbage
// link lists at boot do it even with zero sprites on screen - the POST sat
// at "Waiting for Second Processor"), so the age saturated 0.9 us into
// every line and the boost degenerated into 137's blanket rule. The age
// must reset on every GRANT, not on queue-empty: one boosted slot per
// aging period. Worst-case MO wait is unchanged (AGE_BOOST + one
// transaction); worst-case CPU share is now bounded at ~2/3 of the
// non-PF bus instead of zero.
// MOARB-146: ONE-FOR-ONE INTERLEAVE, no blocking. Every prior boost
// (137 blanket, 139/140/144 one-shot, 145 burst) worked by BLOCKING the
// fastpath while MO pends - and escape_core gives a blocked fastpath only
// 16 CPU clocks (v_fast_to/e_fast_to) before every ROM fetch degenerates
// into timeout-plus-legacy-fallback: the 68ks crawl and the engine reads
// as input-dead (the 143 and 145 field regressions). 144 survived only
// because its pulses were shorter than the timeout - and it under-serves
// dense lines (36.45 tiles/line on tb_mister_moarb vs ~40 needed).
// The Pocket never had this problem because its rule produces a strict
// MO/CPU alternation on a two-client bus. Reproduce THAT, not the
// blocking: a turn bit arbitrates only the cycles where MO and the
// fastpath are both hungry - each grant hands the next contested cycle
// to the other side. MO gets ~half the non-playfield bus under load
// (>100 tiles/line), the fastpath's ready latency stays a few CPU
// clocks - far inside the timeout - and no starvation window exists in
// either direction. The legacy demand arm returns to its pre-140 form:
// with the fastpath never blocked, the 140 standoff cannot form.
reg [1:0] vb_sd_sync = 2'b11;
always @(posedge clk_sdram) vb_sd_sync <= {vb_sd_sync[0], VBlank};
reg mo_turn = 1'b0;   // 1 = MO takes the next contested idle cycle
reg        mo_pend_q  = 1'b0;
reg [1:0]  mo_nch_q   = 2'd0;
reg [23:0] mo_naddr_q = 24'd0;
always @(posedge clk_sdram) begin
    // gated by core_rstn_sd HERE and not in the reset-resync block below:
    // one always block per net, or Quartus rejects it as multiple drivers
    // (iverilog accepts it silently, so no bench catches this).
    mo_pend_q  <= core_rstn_sd && (|mg_pend_w);
    mo_nch_q   <= mg_pend_w[0] ? 2'd0 : mg_pend_w[1] ? 2'd1
                : mg_pend_w[2] ? 2'd2 : 2'd3;
    mo_naddr_q <= mg_pend_w[0] ? mo_gfx_addr[23:0]
                : mg_pend_w[1] ? mo_gfx_addr[47:24]
                : mg_pend_w[2] ? mo_gfx_addr[71:48]
                                : mo_gfx_addr[95:72];
end

// ---- playfield gfx channels (A/B ping-pong) - SDRAM on MiSTer -------------
// Given the same pre-decode treatment as MO, for the same reason: the PF
// client is new on this platform and must not add depth to the shared grant.
reg         vg_reqA_px = 1'b0, vg_reqB_px = 1'b0;
reg  [23:0] vg_addrA_px, vg_addrB_px;
reg  [1:0]  vg_req_last;
reg  [1:0]  vg_done_85 = 2'd0;
reg  [63:0] vg_data;                   // 2 x 32
reg         pf_owner = 1'b0;
reg         pf_sd_ch = 1'b0;
reg  [1:0]  vg_req_s_q;
always @(posedge clk_sdram) vg_req_s_q <= {vg_reqB_px, vg_reqA_px};
wire [1:0] vg_req_s = vg_req_s_q;
reg  [1:0] vg_done_s_q;
always @(posedge clk_sys) vg_done_s_q <= vg_done_85;
wire [1:0] vg_done_s = vg_done_s_q;

wire [1:0] vg_pend_w = vg_req_s ^ vg_req_last;
reg        pf_pend_q  = 1'b0;
reg        pf_nch_q   = 1'b0;
reg [23:0] pf_naddr_q = 24'd0;
always @(posedge clk_sdram) begin
    pf_pend_q  <= core_rstn_sd && (|vg_pend_w);
    pf_nch_q   <= vg_pend_w[0] ? 1'b0 : 1'b1;
    pf_naddr_q <= vg_pend_w[0] ? vg_addrA_px : vg_addrB_px;
end

reg  vid_last_pf = 1'b0;      // retired by MISTER-135 (PF is strict-highest); kept to avoid port churn

// ---- char ROM DMA + SDRAM self-check --------------------------------------
reg [3:0]  chk_state = 4'd0;
reg [13:0] chr_dma_word = 14'd0;
reg        chr_we = 1'b0;
reg [15:0] chr_wdata;
reg [23:0] recheck_ctr = 24'd0;
reg        cpu_owner = 1'b0;

always @(posedge clk_sdram) begin
    case (chk_state)
    4'd0: if (sdram_init_done && !ioctl_download && !dl_pending) begin
        sd_rd_req <= 1'b1;  chk_state <= 4'd1;      // probe0 @ 0x000000
    end
    4'd1: if (sd_rd_ack) begin
        chk_ok    <= (sd_rd_data[31:16] == 16'h003F);   // high word of reset SP
        sd_rd_req <= 1'b0;  chk_state <= 4'd2;
    end
    4'd2: if (!sd_rd_ack) begin sd_rd_req <= 1'b1; chk_state <= 4'd3; end
    4'd3: if (sd_rd_ack) begin sd_rd_req <= 1'b0; chk_state <= 4'd4; end
    4'd4: if (!sd_rd_ack) begin sd_rd_req <= 1'b1; chk_state <= 4'd5; end
    4'd5: if (sd_rd_ack) begin
        chk2_ok   <= (sd_rd_data[31:16] == 16'h3388);   // char ROM landmark
        sd_rd_req <= 1'b0;  chk_state <= 4'd6;
    end
    4'd6: if (!sd_rd_ack) begin chr_dma_word <= 14'd0; chk_state <= 4'd7; end
    4'd7: begin
        chr_we <= 1'b0;
        if (!sd_rd_ack) begin sd_rd_req <= 1'b1; chk_state <= 4'd8; end
    end
    4'd8: if (sd_rd_ack) begin
        sd_rd_req <= 1'b0;
        chr_wdata <= sd_rd_data[31:16];
        chr_we    <= 1'b1;
        chk_state <= 4'd9;
    end
    4'd9: begin
        chr_we <= 1'b0;
        if (chr_dma_word == 14'd8191) begin
            chk_done  <= 1'b1;
            chk_state <= 4'd10;
        end else begin
            chr_dma_word <= chr_dma_word + 14'd1;
            chk_state    <= 4'd7;
        end
    end
    4'd10: begin
        // ---- steady state: strict-priority read arbiter -------------------
        // fastpath fills > legacy CPU fetch > {PF, MO} round-robin.
        // CDCSET-136: the two-edge delay lines and the actual toggles.
        // d1 is set in the completion cycle below (data lands), d2 one
        // period later, and the toggle flips on the edge after that.
        vg_done_set_d2 <= vg_done_set_d1;  vg_done_set_d1 <= 2'd0;
        mg_done_set_d2 <= mg_done_set_d1;  mg_done_set_d1 <= 4'd0;
        if (vg_done_set_d2[0]) vg_done_85[0] <= ~vg_done_85[0];
        if (vg_done_set_d2[1]) vg_done_85[1] <= ~vg_done_85[1];
        if (mg_done_set_d2[0]) mg_done_85[0] <= ~mg_done_85[0];
        if (mg_done_set_d2[1]) mg_done_85[1] <= ~mg_done_85[1];
        if (mg_done_set_d2[2]) mg_done_85[2] <= ~mg_done_85[2];
        if (mg_done_set_d2[3]) mg_done_85[3] <= ~mg_done_85[3];

        // MOARB-137 (ported from Pocket MOARB-130): during ACTIVE video,
        // a pending MO fetch outranks NEW SPECULATIVE fastpath fills - the
        // legacy CPU path (the never-wedge demand fetch) keeps its rank.
        // Same rationale as the Pocket: speculative fills are the one bus
        // consumer with no deadline and no correctness stake; MO is bounded
        // per line by its fetch budget. On this platform the pressure is
        // worse than the Pocket ever saw - PF-first (needed) plus both CPU
        // tiers left MO the scraps, and big late-list machines shredded
        // into fragments frame-by-frame (owner 136 capture, t=24.4: the
        // conveyor flashing whole/fragmented). Pocket measurement showed
        // no cadence cost; the legacy path's rank is untouched.
        // MISTER-135: PF OUTRANKS THE CPUs. The 134 splash proved the new
        // rbf runs, and the streaks survived both PF-over-MO (132) and the
        // precharge armor (133) - so they are not MO contention and not
        // wrong-row serves. The remaining shape fits exactly: streaks are
        // row-shaped, worst in the TOP rows (fetched right after vblank,
        // when the game's per-frame CPU burst peaks) and in busy scenes -
        // PF fetches missing their scanline deadline behind CPU traffic.
        // On the Pocket PF lives on PSRAM and never meets the CPUs; here
        // they share one controller and the CPUs outranked it. PF has the
        // only hard realtime deadline in the system, and its demand is
        // bounded (two fetches per 8-px cell), so the CPUs wait at most
        // ~two reads - the attract-cycle benchmark has the game running
        // slightly FASTER than MAME, so that headroom exists.
        if (pf_pend_q
            && !sd_rd_req && !sd_rd_ack && !cpu_owner && !mo_owner && !pf_owner
            && !fpv_owner && !fpe_owner) begin
            vg_req_last[pf_nch_q] <= vg_req_s[pf_nch_q];
            rd_addr_q   <= {1'b0, pf_naddr_q};
            pf_sd_ch    <= pf_nch_q;
            rd_pre_q    <= 1'b1;
            sd_rd_req   <= 1'b1;
            pf_owner    <= 1'b1;
        end

        if ((fpv_want || fpe_want) && !pf_pend_q
            && !(mo_pend_q && mo_turn)
            && !sd_rd_req && !sd_rd_ack && !cpu_owner && !mo_owner && !pf_owner
            && !fpv_owner && !fpe_owner) begin
            mo_turn   <= 1'b1;              // MO gets the next contested cycle
            if (fpv_want && (!fpe_want || !fp_last_v)) begin
                fpv_tag   <= fpv_addr_s;
                fpv_valid <= 1'b0;
                rd_addr_q <= {1'b0, fpv_addr_s};
                rd_pre_q  <= 1'b1;
                sd_rd_req <= 1'b1;
                fpv_owner <= 1'b1;
                fp_last_v <= 1'b1;
            end else begin
                fpe_tag   <= fpe_addr_s;
                fpe_valid <= 1'b0;
                rd_addr_q <= {1'b0, fpe_addr_s};
                rd_pre_q  <= 1'b1;
                sd_rd_req <= 1'b1;
                fpe_owner <= 1'b1;
                fp_last_v <= 1'b0;
            end
        end
        if (fpv_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 1'b0; fpv_owner <= 1'b0;
            fpv_data  <= sd_rd_data[31:16]; fpv_vpre <= 1'b1;
        end
        if (fpe_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 1'b0; fpe_owner <= 1'b0;
            fpe_data  <= sd_rd_data[31:16]; fpe_vpre <= 1'b1;
        end
        if (fpv_vpre) begin fpv_valid <= 1'b1; fpv_vpre <= 1'b0; end
        if (fpe_vpre) begin fpe_valid <= 1'b1; fpe_vpre <= 1'b0; end

        // legacy CPU fetch (the never-wedge fallback behind the fastpath).
        // MOARB-147: 146's 'plain deference' claim was wrong in one state and
        // the game watchdog proved it (reset loop before gameplay): with a
        // demand pending AND mo_turn=1 AND fastpath wanting, the MO arm
        // defers to the demand, this arm deferred to the want, and the
        // fastpath was blocked by the turn - a standoff mo_turn can never
        // exit, because only an MO grant clears it. Same lesson as
        // MOARB-140: when the fastpath cannot move, a pending demand must
        // not wait for it. Exclusive with the MO arm by construction (it
        // requires no pending demand).
        if (core_rom_req_s && !core_rom_ack_85 && !pf_pend_q
            && !sd_rd_req && !sd_rd_ack
            && !fpv_owner && !fpe_owner
            && ((!fpv_want && !fpe_want) || (mo_pend_q && mo_turn))
            && !mo_owner && !pf_owner) begin
            sd_rd_req <= 1'b1;
            rd_addr_q <= {1'b0, core_rom_addr};
            rd_pre_q  <= 1'b1;
            cpu_owner <= 1'b1;
        end
        if (cpu_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req     <= 1'b0;
            cpu_owner     <= 1'b0;
            core_rom_data <= sd_rd_data;
            core_rom_par  <= ^sd_rd_data;
            core_rom_par4 <= {^sd_rd_data[31:24], ^sd_rd_data[23:16],
                              ^sd_rd_data[15:8],  ^sd_rd_data[7:0]};
            rom_ack_dly <= 2'b01;                 // CDCSET-136: ack later
        end
        if (rom_ack_dly == 2'b01) rom_ack_dly <= 2'b10;
        else if (rom_ack_dly == 2'b10) begin
            core_rom_ack_85 <= 1'b1; rom_ack_dly <= 2'b00;
        end
        if (!core_rom_req_s) core_rom_ack_85 <= 1'b0;

        // Video tier: playfield and motion objects, round-robin.  CPUs always
        // outrank both.  Both pending tests are single registered bits
        // (MOCHAN-4 pre-decode above), so this arm adds one 2-input OR and one
        // mux select to the shared grant, not a tree of comparators.
        // v14-v19 lesson: ONE if, ONE arm - two grant arms firing on the same
        // clock is last-writer-wins address corruption.
        // MO: below the CPUs, as before; PF has its own top-priority arm
        // above. One if, one arm - the single-grant invariant is untouched.
        if (mo_pend_q && !pf_pend_q
            && !(core_rom_req_s && !core_rom_ack_85)
            && !sd_rd_req && !sd_rd_ack && !cpu_owner && !mo_owner && !pf_owner
            && !fpv_owner && !fpe_owner
            && (mo_turn || (!fpv_want && !fpe_want))) begin
            mo_turn     <= 1'b0;            // fastpath gets the next contested cycle
            mg_req_last[mo_nch_q] <= mg_req_s[mo_nch_q];
            // MISTER-150: MO reads its own bank-2 mirror of the tile data
            rd_addr_q   <= {1'b0, mo_naddr_q} + 25'h04E0000;
            mo_sd_ch    <= mo_nch_q;
            rd_pre_q    <= 1'b1;        // MO keeps the Pocket's armor
            sd_rd_req   <= 1'b1;
            mo_owner    <= 1'b1;
        end

        if (pf_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 1'b0;
            pf_owner  <= 1'b0;
            vg_data[pf_sd_ch*32 +: 32] <= sd_rd_data;
            vg_done_set_d1[pf_sd_ch]   <= 1'b1;   // CDCSET-136: toggle later
        end
        if (mo_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 1'b0;
            mo_owner  <= 1'b0;
            mg_data[mo_sd_ch*32 +: 32] <= sd_rd_data;
            mg_done_set_d1[mo_sd_ch]   <= 1'b1;   // CDCSET-136: toggle later
        end

        // SDRAM canary: while the deep probe fails, re-probe + re-DMA
        recheck_ctr <= recheck_ctr + 24'd1;
        if (!chk2_ok && recheck_ctr == 24'hFFFFFF && !sd_rd_req && !sd_rd_ack
            && !core_rom_ack_85) chk_state <= 4'd2;
    end
    default: chk_state <= 4'd10;
    endcase

    // resync the fetch trackers whenever the machine is held in reset - the
    // mob zeroes its request toggles there, and a stale tracker is one
    // phantom serve per channel per reset (SDSCHED-75).
    if (!core_rstn_sd) begin
        mg_req_last <= mg_req_s;
        vg_req_last <= vg_req_s;
        // NOTE: mo_pend_q / pf_pend_q are held low under reset in their OWN
        // always blocks above, not here - two blocks driving one net is a
        // Quartus error that iverilog accepts silently.
        fpv_valid <= 1'b0; fpe_valid <= 1'b0;
        fpv_vpre  <= 1'b0; fpe_vpre  <= 1'b0;
    end
    if (ioctl_download) begin
        chk_state <= 4'd0;
        chk_done  <= 1'b0;
        sd_rd_req <= 1'b0;
        // PFRESET-107, same bug class as the playfield channel reset above:
        // dropping sd_rd_req here abandons whatever read was in flight, but
        // the owner flag for that client stayed set - and every grant arm
        // requires !cpu_owner && !mo_owner && !pf_owner && !fpv_owner &&
        // !fpe_owner.  A second .mra load (or any ioctl_download that lands
        // while a read is outstanding, which is every load after the first)
        // therefore wedged the ENTIRE read arbiter, not just one client.
        // Nothing had exercised that path because the first load happens
        // before any client is active.  Clear them with the request.
        cpu_owner <= 1'b0;
        mo_owner  <= 1'b0;
        pf_owner  <= 1'b0;
        fpv_owner <= 1'b0;
        fpe_owner <= 1'b0;
    end
end

sdram_openrow #(.MIRROR_BANK2_EN(1)) sdr (   // MISTER-141 controller + MISTER-150 mirror
    .clk        ( clk_sdram ),
    .reset_n    ( pll_locked ),
    .dram_a     ( SDRAM_A ),
    .dram_ba    ( SDRAM_BA ),
    .dram_dq    ( SDRAM_DQ ),
    .dram_dqm   ( {SDRAM_DQMH, SDRAM_DQML} ),
    .dram_cas_n ( SDRAM_nCAS ),
    .dram_ras_n ( SDRAM_nRAS ),
    .dram_we_n  ( SDRAM_nWE ),
    .dram_cke   ( SDRAM_CKE ),
    .wr_req     ( sd_wr_req ),
    .wr_ack     ( sd_wr_ack ),
    .wr_addr    ( sd_wr_addr ),
    .wr_data    ( sd_wr_data ),
    .rd_req     ( sd_rd_req ),
    .rd_ack     ( sd_rd_ack ),
    .rd_pre     ( (chk_state == 4'd10) ? rd_pre_q : 1'b1 ),
    // MISTER-141: each probe address must be driven from the state that
    // RAISES rd_req (0/2/4), not only the state that waits for ack (1/3/5).
    // sdram_simple accepted requests late enough to hide the stale first
    // cycle; sdram_openrow latches the address immediately and read the
    // mux default instead (bench probe 0x110410 caught it). The chr-DMA
    // pair (7/8) always covered both states - same idiom now everywhere.
    .rd_addr    ( (chk_state == 4'd10) ? rd_addr_q :
                  (chk_state == 4'd0 || chk_state == 4'd1) ? 25'd0 :
                  (chk_state == 4'd2 || chk_state == 4'd3) ? 25'h0110400 :
                  (chk_state == 4'd4 || chk_state == 4'd5) ? 25'h0110410 :
                  (chk_state == 4'd8 || chk_state == 4'd7)
                        ? (25'h0110000 + {10'd0, chr_dma_word, 1'b0}) :
                  {1'b0, core_rom_addr} ),
    .rd_data    ( sd_rd_data ),
    .init_done  ( sdram_init_done )
);

// MiSTer's SDRAM module has a chip select; the Pocket's does not.
assign SDRAM_nCS = 1'b0;

// ===========================================================================
// char ROM BRAM (8192 x 16), written by the DMA above, read by the scanout
// ===========================================================================
reg [15:0] chr_ram [0:8191];
always @(posedge clk_sdram) if (chr_we) chr_ram[chr_dma_word] <= chr_wdata;
reg  [15:0] chr_q;
reg  [12:0] chr_raddr;
always @(posedge clk_sys) chr_q <= chr_ram[chr_raddr];

// ===========================================================================
// playfield pipeline (pixel domain) - unchanged from the Pocket build except
// that the fetch requests now go to the SDRAM arbiter above.
// ===========================================================================
reg  [11:0] pf_vaddr;
wire [15:0] pf_vdata, pfx_vdata;
wire [8:0]  xscroll, yscroll;

wire [8:0] pf_y  = visible_y[8:0] + yscroll;
wire [8:0] pf_x2 = vis_x[8:0] + 9'd16 + 9'd16 + xscroll;   // LANE3p world align (+32)

reg [4:0]  pfcol_q0, pfcol_q1, pfcol_q2, pfcol_q3, pfcol_show, pfcol_next;
reg [31:0] pf_next;
reg        inflA = 1'b0, inflB = 1'b0;
reg [31:0] pf_show;
reg [31:0] pfring0, pfring1, pfring2, pfring3;
reg [1:0]  pf_wp = 2'd0, pf_inflA = 2'd0, pf_inflB = 2'd0, pf_rp = 2'd0;
reg [23:0] pfq_addr0, pfq_addr1, pfq_addr2, pfq_addr3;
reg [1:0]  pfq_slot0, pfq_slot1, pfq_slot2, pfq_slot3;
reg [2:0]  pfq_count = 3'd0;
reg [1:0]  pfq_wr = 2'd0, pfq_rd = 2'd0;
reg [1:0]  vg_done_last = 2'd0;

wire [23:0] pf_fetch_addr = 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0};

always @(posedge clk_sys) begin
    case (vis_x[2:0])
        3'd0: begin
            // column-major map scan (MAME SCAN_COLS semantics)
            pf_vaddr  <= {pf_x2[8:3], pf_y[8:3]};
            pfcol_q3  <= pfcol_q2;
            pfcol_q2  <= pfcol_q1;
            pfcol_q1  <= pfcol_q0;
        end
        3'd3: begin
            if (y_count >= VID_V_BPORCH - 10'd2
                && y_count < VID_V_BPORCH + VID_V_ACTIVE
                && pfq_count != 3'd4) begin
                case (pfq_wr)
                    2'd0: begin pfq_addr0 <= pf_fetch_addr; pfq_slot0 <= pf_wp; end
                    2'd1: begin pfq_addr1 <= pf_fetch_addr; pfq_slot1 <= pf_wp; end
                    2'd2: begin pfq_addr2 <= pf_fetch_addr; pfq_slot2 <= pf_wp; end
                    default: begin pfq_addr3 <= pf_fetch_addr; pfq_slot3 <= pf_wp; end
                endcase
                pfq_wr    <= pfq_wr + 2'd1;
                pfq_count <= pfq_count + 3'd1;
                pf_wp     <= pf_wp + 2'd1;
            end
            pfcol_q0 <= {pf_vdata[15], pfx_vdata[11:8]};
        end
        3'd7: begin
            case (pf_rp)
                2'd0: pf_show <= pfring0;  2'd1: pf_show <= pfring1;
                2'd2: pf_show <= pfring2;  default: pf_show <= pfring3;
            endcase
            case (pf_rp + 2'd1)
                2'd0: pf_next <= pfring0;  2'd1: pf_next <= pfring1;
                2'd2: pf_next <= pfring2;  default: pf_next <= pfring3;
            endcase
            pf_rp      <= pf_rp + 2'd1;
            pfcol_show <= pfcol_q3;
            pfcol_next <= pfcol_q2;
        end
        default: ;
    endcase

    vg_done_last <= vg_done_s;
    if (vg_done_s[0] != vg_done_last[0]) begin
        case (pf_inflA)
            2'd0: pfring0 <= vg_data[31:0];  2'd1: pfring1 <= vg_data[31:0];
            2'd2: pfring2 <= vg_data[31:0];  default: pfring3 <= vg_data[31:0];
        endcase
        inflA <= 1'b0;
    end
    if (vg_done_s[1] != vg_done_last[1]) begin
        case (pf_inflB)
            2'd0: pfring0 <= vg_data[63:32];  2'd1: pfring1 <= vg_data[63:32];
            2'd2: pfring2 <= vg_data[63:32];  default: pfring3 <= vg_data[63:32];
        endcase
        inflB <= 1'b0;
    end
    if (pfq_count != 3'd0) begin
        if (!inflA && !(vg_done_s[0] != vg_done_last[0])) begin
            case (pfq_rd)
                2'd0: begin vg_addrA_px <= pfq_addr0; pf_inflA <= pfq_slot0; end
                2'd1: begin vg_addrA_px <= pfq_addr1; pf_inflA <= pfq_slot1; end
                2'd2: begin vg_addrA_px <= pfq_addr2; pf_inflA <= pfq_slot2; end
                default: begin vg_addrA_px <= pfq_addr3; pf_inflA <= pfq_slot3; end
            endcase
            vg_reqA_px <= ~vg_reqA_px;
            inflA      <= 1'b1;
            pfq_rd     <= pfq_rd + 2'd1;
            pfq_count  <= pfq_count - 3'd1;
        end else if (!inflB && !(vg_done_s[1] != vg_done_last[1])) begin
            case (pfq_rd)
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
    if (x_count == 10'd0) begin
        pf_rp     <= pf_wp;
        pfq_count <= 3'd0;
        pfq_rd    <= pfq_wr;
        // PFLINE-117: PRIME the show registers, exactly as the Pocket top
        // level does (core_top.v, same defect - this pipeline is DUPLICATED
        // between the two targets, so every fix to it has to be applied twice
        // until it is factored into a shared module).
        //
        // The bug: pf_show/pf_next were loaded ONLY in the vis_x[2:0]==7
        // branch, so from line start until the first phase-7 they still held
        // what was staged at the PREVIOUS line's last cell - and staged off
        // the pre-resync pf_rp, a slot that is not this line's first cell.
        //
        // The slot is pf_wp MINUS ONE. After the resync rp = wp, and the
        // phase-7 load at vis_x=7 stages CELL 1 from ring[rp] = ring[wp]. So
        // cell N uses ring[wp + N - 1] and cell 0 needs ring[wp - 1]; priming
        // with ring[wp] hands cell 0 cell 1's data. Measured on Pocket
        // hardware: cols 0-1 went from 62-69 distinct colours down the column
        // to exactly one flat value, which is the signature of a constant
        // wrong slot. See docs/investigations/MO_TILE_HOLES.md.
        case (pf_wp - 2'd1)
            2'd0: pf_show <= pfring0;  2'd1: pf_show <= pfring1;
            2'd2: pf_show <= pfring2;  default: pf_show <= pfring3;
        endcase
        case (pf_wp)
            2'd0: pf_next <= pfring0;  2'd1: pf_next <= pfring1;
            2'd2: pf_next <= pfring2;  default: pf_next <= pfring3;
        endcase
        pfcol_show <= pfcol_q3;
        pfcol_next <= pfcol_q2;
    end

    // ---- PFRESET-107: the playfield fetch channel MUST reset with the core.
    //
    // BUILD 105 shipped without this and rendered a completely flat playfield
    // on hardware.  The mechanism, reproduced in sim/tb/tb_mister_pf.v:
    //
    //   * x_count/y_count and this whole pipeline free-run from power-on -
    //     they are not gated by core_reset_n.  So during the ~2.2 MB ROM
    //     download, with the machine held in reset, this block reaches active
    //     video and issues a playfield fetch on channel A and then on channel
    //     B, setting inflA and inflB.
    //   * the SDRAM arbiter cannot serve them: its whole video tier lives in
    //     the chk_state == 4'd10 steady-state arm, and chk_state is pinned at
    //     0 for the entire download.  pf_pend_q is gated by core_rstn_sd on
    //     top of that.
    //   * meanwhile the arbiter's SDSCHED-75 reset resync runs every clock
    //     that core_rstn_sd is low and does "vg_req_last <= vg_req_s", which
    //     RETIRES those two pending request edges without ever completing
    //     them.  That resync is correct for the motion objects, because
    //     escape_mob zeroes its own request toggles and in-flight state under
    //     reset - the tracker is following a real reset, not eating a real
    //     request.  This block had no reset at all, so it was the one client
    //     for which the resync destroyed work.
    //   * reset releases with inflA = inflB = 1 and vg_req_last == vg_req_s.
    //     The issue side requires !inflA / !inflB, so it never toggles a
    //     request again; the arbiter never sees a pending edge again.  Both
    //     channels are wedged for the rest of the session, pfring0..3 keep
    //     their power-on zeros, every tile decodes to pixel index 0, and the
    //     screen shows one flat colour per playfield colour attribute.
    //
    // That is exactly the hardware capture: correct tilemap (the stairs
    // structure is a correctly shaped silhouette), correct per-tile colour
    // attributes (two flat regions, not one), constant tile pixels, and no
    // dependence on scene complexity.  Motion objects were unaffected because
    // they read the same repacked region through a channel that does reset.
    //
    // Giving this channel the same reset the mob gives its own is the whole
    // fix: while reset is held the request toggles sit at 0, the resync tracks
    // 0, and release starts both sides in agreement with nothing in flight.
    if (!core_reset_n) begin
        vg_reqA_px <= 1'b0;  vg_reqB_px <= 1'b0;
        inflA      <= 1'b0;  inflB      <= 1'b0;
        pfq_count  <= 3'd0;  pfq_wr     <= 2'd0;  pfq_rd <= 2'd0;
        pf_wp      <= 2'd0;  pf_rp      <= 2'd0;
    end
end

// chunky-nibble pixel extraction with horizontal fine scroll (SDSCHED-84)
wire        pf_cross = pf_x2[2:0] < visible_x[2:0];
wire [31:0] pf_word  = pf_cross ? pf_next    : pf_show;
wire [4:0]  pf_att   = pf_cross ? pfcol_next : pfcol_show;
wire [2:0]  pf_n     = pf_att[4] ? (3'd7 - pf_x2[2:0]) : pf_x2[2:0];
reg  [3:0]  pf_pix;
always @(*) case (pf_n)
    3'd0: pf_pix = pf_word[31:28]; 3'd1: pf_pix = pf_word[27:24];
    3'd2: pf_pix = pf_word[23:20]; 3'd3: pf_pix = pf_word[19:16];
    3'd4: pf_pix = pf_word[15:12]; 3'd5: pf_pix = pf_word[11:8];
    3'd6: pf_pix = pf_word[7:4];   default: pf_pix = pf_word[3:0];
endcase

// ===========================================================================
// motion objects
// ===========================================================================
wire [11:0] mo_vaddr;
wire [15:0] mo_vdata;
wire [6:0]  cfg_vaddr;
wire [15:0] cfg_vdata;
wire [7:0]  mo_pen;
wire [1:0]  mo_prio;
wire        mo_valid;
wire        mo_stain_s, mo_stain_e;      // MOSTAIN-1 second-pass markers

escape_mob umob (
    .clk       ( clk_sys ),
    .reset_n   ( core_reset_n ),
    .x_count   ( x_count ),
    .y_count   ( y_count ),
    .vbporch   ( VID_V_BPORCH ),
    .vactive   ( VID_V_ACTIVE ),
    .hbporch   ( VID_H_BPORCH ),
    .xscroll   ( xscroll ),
    .yscroll   ( yscroll ),
    .mo_vaddr  ( mo_vaddr ),
    .mo_vdata  ( mo_vdata ),
    .cfg_vaddr ( cfg_vaddr ),
    .cfg_vdata ( cfg_vdata ),
    .gfx_req   ( moc_req ),
    .gfx_addr  ( moc_addr ),
    .gfx_done  ( moc_done ),
    .gfx_data  ( moc_data ),
    .disp_x    ( visible_x[8:0] ),
    .disp_pen  ( mo_pen ),
    .disp_prio ( mo_prio ),
    .disp_valid( mo_valid ),
    .disp_stain_s( mo_stain_s ),
    .disp_stain_e( mo_stain_e )
);

// ===========================================================================
// alphanumerics scanout
// ===========================================================================
wire [10:0] alpha_vaddr;
wire [15:0] alpha_vdata;
reg  [10:0] color_vaddr;
wire [15:0] color_vdata;
wire [3:0]  eintensity;
wire        evideo_off;

reg [15:0] a_word;
reg [5:0]  a_color;
reg [15:0] r_row;
reg [5:0]  r_color;
reg        r_opaque;

wire [9:0] next_x   = vis_x + 10'd8;
wire [5:0] cell_col = next_x[8:3];
wire [4:0] cell_row = visible_y[7:3];
assign alpha_vaddr = {cell_row, cell_col};

always @(posedge clk_sys) begin
    case (vis_x[2:0])
        3'd5: a_word <= alpha_vdata;
        3'd6: begin
            chr_raddr <= {alpha_vdata[9:0], visible_y[2:0]};
            a_color   <= {alpha_vdata[14], 1'b0, alpha_vdata[13:10]};
        end
        3'd0: begin
            r_row    <= chr_q;
            r_color  <= a_color;
            r_opaque <= a_word[15];
        end
        default: ;
    endcase
end

wire [2:0]  pxn = visible_x[2:0];
wire [15:0] act_row = (pxn == 3'd0) ? chr_q : r_row;
wire        msb = pxn[2] ? act_row[7  - pxn[1:0]] : act_row[15 - pxn[1:0]];
wire        lsb = pxn[2] ? act_row[3  - pxn[1:0]] : act_row[11 - pxn[1:0]];
wire [1:0]  pix = {msb, lsb};
wire [5:0]  act_color  = (pxn == 3'd0) ? a_color   : r_color;
wire        act_opaque = (pxn == 3'd0) ? a_word[15]: r_opaque;
wire        alpha_vis  = (pix != 2'b00) || act_opaque;

// MO / playfield priority comparator (docs/investigations/mo_priority.md)
wire        pr_mo_win, pr_shade, pr_m7, pr_pfm, pr_forcemc0;
wire [10:0] pr_pen;
escape_prio uprio (
    .mo_valid ( mo_valid ),
    .mo_prio  ( mo_prio ),
    .mo_color ( mo_pen[7:4] ),
    .mo_pix   ( mo_pen[3:0] ),
    .pf_color ( pf_att[3:0] ),
    .pf_pix   ( pf_pix ),
    .forcemc0 ( pr_forcemc0 ),
    .shade    ( pr_shade ),
    .m7       ( pr_m7 ),
    .pfm      ( pr_pfm ),
    .mo_win   ( pr_mo_win ),
    .pen      ( pr_pen )
);

// MOSTAIN-1: the SECOND motion-object pass (atarimo apply_stain).  The
// reference runs it over the FINISHED picture - after the MO/PF merge AND
// after the alpha tilemap - ORing 0x400 into every pixel a "special" (MPR2)
// sprite covers.  0x400 is colour-RAM bit 10, the top half of the 2048-entry
// colour RAM: the FACTORY MAP screen's route markers live entirely in that
// bank.  The reference restarts its scan at every marker pixel; the union of
// those scans is this one-flip-flop automaton along the scanline:
//
//     stain(x) = S(x) | alive(x-1)
//     alive(x) = stain(x) & ~( E(x-1) & ~S(x) )
//
// S = special pixel with pen bit 1 (START_MARKER), E = pen bit 2 (END_MARKER).
//
// GFXDASH-3: the automaton was inline here, byte-identical to the copy that
// was inline in core_top.v - two transcriptions of the same recurrence, in two
// files NO simulation script compiles.  It now lives in the shared module
// src/fpga/core/rtl/escape_stain.v, instantiated once by core_top.v (Pocket),
// once here (MiSTer) and once by sim/tb/tb_stain.v.  sim/run_stain_tb.sh
// therefore drives THE SHIPPED INSTANCE on both platforms instead of a
// third transcription in Python.
//
// The extraction is behaviour-preserving and the substitution here is exact:
// the module's line_start/s_in/e_in/stain are the old visible_x==0 /
// mo_stain_s / mo_stain_e / stain_now, with the same two flip-flops, the same
// power-up value and the same clear condition.  Pure logic - the M10K delta
// is structurally zero.
wire stain_now;
escape_stain ustain (
    .clk        ( clk_sys ),
    // MOALIGN-129 (ported): escape_mob's display read is now at disp_x+1, so
    // delivery aligns with consumption; the registered clear must be VISIBLE
    // at pixel 0, i.e. line_start asserts on the last blanking clock.
    .line_start ( x_count == VID_H_BPORCH - 1 ),
    .s_in       ( mo_stain_s ),
    .e_in       ( mo_stain_e ),
    .stain      ( stain_now )
);

// pens: alpha 0..255 = {3'b000,color6,pix2}; MO 256..511; playfield 512..767;
// SHADE moves the playfield into 768..1023 (CRA9).  The stain then moves
// whatever won into the 1024..2047 bank.
always @(posedge clk_sys)
    color_vaddr <= (alpha_vis ? {3'b000, act_color, pix}
                              : pr_pen) | {stain_now, 10'd0};

// palette: IRGB4444 with the 360010 intensity latch
wire [3:0]  ints  = (eintensity > 4'd4) ? 4'd4 : eintensity;
wire [6:0]  ifac  = ({3'd0, color_vdata[15:12]} + 7'd1) * (7'd4 - {5'd0, ints[2:0]});
wire [10:0] r_m   = color_vdata[11:8] * ifac;
wire [10:0] g_m   = color_vdata[7:4]  * ifac;
wire [10:0] b_m   = color_vdata[3:0]  * ifac;
wire [7:0]  pal_r = (r_m[10:2] > 9'd255) ? 8'd255 : r_m[9:2];
wire [7:0]  pal_g = (g_m[10:2] > 9'd255) ? 8'd255 : g_m[9:2];
wire [7:0]  pal_b = (b_m[10:2] > 9'd255) ? 8'd255 : b_m[9:2];

// ---- MISTER-132: core-credits overlay -------------------------------------
// Drawn here, in the core's own video path, because the CONF_STR submenu
// pages this replaces render EMPTY on some framework builds (see
// Arcade-Escape.sv).  escape_credits is pipelined to the same two-clock depth
// as the colour path, so its pixel lands on the pixel it belongs to.
// MISTER-142: the MISTER-134 boot splash is retired for release (owner
// gate, docs/MISTER.md status note): the machine boots clean, and the
// build number lives on credits page 1 (its second line -
// support/gen_credits_overlay.py, BUMP THEM TOGETHER), reachable via the
// OSD "Show Credits" trigger, the mappable Credits button, or keyboard C.
// The splash existed to answer "is the new rbf actually running?" during
// field-testing; the dated rbf filename plus the credits page carry that
// duty now.
wire [1:0] cr_page_eff = credits_page;

wire cr_on, cr_px;
escape_credits #(
    .H_BPORCH ( VID_H_BPORCH ), .V_BPORCH ( VID_V_BPORCH ),
    .H_ACTIVE ( VID_H_ACTIVE ), .V_ACTIVE ( VID_V_ACTIVE )
) u_credits (
    .clk     ( clk_sys ),
    .page    ( cr_page_eff ),
    .x_count ( x_count ),
    .y_count ( y_count ),
    .ov_on   ( cr_on ),
    .ov_px   ( cr_px )
);

// ---- video output registers ----------------------------------------------
// The colour path is two clocks behind the raster counters (color_vaddr is
// registered, then the colour RAM read is registered), so the sync/blank
// flags are delayed to match.
reg [1:0] de_d, hs_d, vs_d, hb_d, vb_d;
wire cur_hs = (x_count >= HS_START) && (x_count < HS_END);
wire cur_vs = (y_count >= VS_START) && (y_count < VS_END);
always @(posedge clk_sys) begin
    hs_d <= {hs_d[0], cur_hs};
    vs_d <= {vs_d[0], cur_vs};
    hb_d <= {hb_d[0], ~h_active};
    vb_d <= {vb_d[0], ~v_active};
    HSync  <= hs_d[1];
    VSync  <= vs_d[1];
    HBlank <= hb_d[1];
    VBlank <= vb_d[1];
    if (hb_d[1] || vb_d[1] || evideo_off) begin
        VGA_R <= 8'd0; VGA_G <= 8'd0; VGA_B <= 8'd0;
    end else if (cr_on) begin
        // credits overlay: lit text white, everything else the game picture
        // dimmed to a quarter so the page reads over any scene
        VGA_R <= cr_px ? 8'hFF : {2'b00, pal_r[7:2]};
        VGA_G <= cr_px ? 8'hFF : {2'b00, pal_g[7:2]};
        VGA_B <= cr_px ? 8'hFF : {2'b00, pal_b[7:2]};
    end else begin
        VGA_R <= pal_r; VGA_G <= pal_g; VGA_B <= pal_b;
    end
end

// ===========================================================================
// controls
// ===========================================================================
wire [7:0] adc_p1x, adc_p1y, adc_p2x, adc_p2y;

hall_stick hall_p1 (
    .clk ( clk_sys ),
    .inv_x ( 1'b0 ), .inv_y ( 1'b0 ), .swap_xy ( 1'b0 ), .deadzone ( 5'd8 ),
    .has_analog ( p1_has_analog ),
    .up ( p1_up ), .down ( p1_down ), .left ( p1_left ), .right ( p1_right ),
    .joy_x ( p1_analog[7:0] ), .joy_y ( p1_analog[15:8] ),
    .adc_x ( adc_p1x ), .adc_y ( adc_p1y )
);
hall_stick hall_p2 (
    .clk ( clk_sys ),
    .inv_x ( 1'b0 ), .inv_y ( 1'b0 ), .swap_xy ( 1'b0 ), .deadzone ( 5'd8 ),
    .has_analog ( p2_has_analog ),
    .up ( p2_up ), .down ( p2_down ), .left ( p2_left ), .right ( p2_right ),
    .joy_x ( p2_analog[7:0] ), .joy_y ( p2_analog[15:8] ),
    .adc_x ( adc_p2x ), .adc_y ( adc_p2y )
);

// Button word is {duck, spare, fire, jump} = schematic CD11..CD8.
// The dedicated BOMB button asserts all three at once - this is how the game
// implements the smart bomb, and the reason the core needs a single button
// that presses Jump+Fire+Duck simultaneously (see docs/CONTROLS.md).
wire coin1_s, coin2_s, start1_s, service_s, skip_s, vshad3_s;
sync2 s_c1 (clk_sys, coin1,   coin1_s);
sync2 s_c2 (clk_sys, coin2,   coin2_s);
sync2 s_st (clk_sys, start1,  start1_s);
sync2 s_sv (clk_sys, service, service_s);
sync2 s_sk (clk_sys, skip_test, skip_s);
// VSHAD3-112: hps_io drives status[] from clk_ram (35.795455), escape_core
// samples vshad3_on in clk_sys (7.159091).  Same 2-flop treatment as every
// other slow control here.  This is the CDC; the ATOMICITY gate (only
// resample between bus cycles) is s3_arm_p inside escape_core.vhd, which is
// the same split the Pocket uses via core_top's synch_3.
sync2 s_v3 (clk_sys, vshad3_on, vshad3_s);

wire [3:0] p1_btn = {p1_duck | p1_bomb, 1'b0, p1_fire | p1_bomb, p1_jump | p1_bomb};
wire [3:0] p2_btn = {p2_duck | p2_bomb, 1'b0, p2_fire | p2_bomb, p2_jump | p2_bomb};

// ===========================================================================
// the machine
// ===========================================================================
// VSHAD3_EN and CPU_TYPE are stated explicitly rather than defaulted. Both
// already default to 1 in escape_core.vhd, so this changes nothing about the
// build - it makes the two decisions visible at the instantiation, which is
// where anyone changing them will look.
//
//   VSHAD3_EN = 1  Instantiate the 16 KB partial ROM shadow at 0x54000.
//       THE M10K IS SPENT HERE AND THE BENEFIT IS NOT MEASURED HERE. On the
//       Pocket the 16 KB shadow measured a 5.19x reduction in sprite dropouts
//       (2.410e-04 vs 1.252e-03 per robot-object-frame, p=1.0e-05) and is
//       statistically indistinguishable from the old full 32 KB shadow.
//       THAT NUMBER DOES NOT TRANSFER TO MiSTer AND IS NOT CLAIMED HERE. The
//       shadow works by taking main-CPU fetches OFF the shared bus so the
//       lowest-priority client (motion objects) gets more of it - but on this
//       platform the PLAYFIELD is also on that bus (difference 1 at the top
//       of this file), so both the contention being relieved and the traffic
//       competing for the freed slots are different. The direction of the
//       effect should be the same; the magnitude is unmeasured on MiSTer.
//       Kept ON because the DE10-Nano has real M10K headroom where the Pocket
//       has none, so the wrong-way risk is a few blocks, not a failed fit.
//       WHICH half of 0x50000-0x57FFF to shadow does transfer: it is a
//       property of this ROM's access pattern, not of the memory system.
//       94.5% of main-CPU traffic in that range lands in 0x54000-0x57FFF and
//       pages 0x50000/0x51000/0x52000 are read zero times during gameplay
//       (docs/investigations/VSHAD3.md section 8), and the CPUs run the same code here.
//
//   CPU_TYPE = 1   68010, the dedicated cabinet. Both schematic sets specify
//       U68010 and the owner's board is a photographed MC68010P8; the JAMMA
//       variant shipped a 68000 and is CPU_TYPE 0. Neither is a fallback.
//       Behaviour is identical on this ROM; interrupt entry costs ~5 extra
//       clocks for the extended exception frame. See docs/CPU_AND_ARBITER.md.
escape_core #(.PAR4_EN(1), .FASTPATH_EN(FASTPATH_EN), .EIRQ_MODE(0),
              .TASLOCK_EN(TASLOCK_EN), .VSHAD3_EN(1), .CPU_TYPE(1)) ecore (
    .clk        ( clk_sys ),
    .reset_n    ( core_reset_n ),
    .rom_addr   ( core_rom_addr ),
    .rom_data   ( core_rom_data ),
    .rom_par    ( core_rom_par ),
    .rom_par4   ( core_rom_par4 ),
    .rom_req    ( core_rom_req ),
    .rom_ack    ( core_rom_ack_s ),
    .fast_v_addr ( fpv_addr_w ),
    .fast_v_spec ( fpv_spec_w ),
    .fast_v_data ( fpv_data ),
    .fast_v_ready( fpv_ready_q ),
    .fast_e_addr ( fpe_addr_w ),
    .fast_e_spec ( fpe_spec_w ),
    .fast_e_data ( fpe_data ),
    .fast_e_ready( fpe_ready_q ),
    .shad_wclk  ( clk_sdram ),
    .shad_waddr ( shad_waddr ),
    .shad_wdata ( shad_wdata ),
    .shad_we    ( shad_we ),
    .vblank_in  ( vblank_w ),
    .p1_buttons ( p1_btn ),
    .p2_buttons ( p2_btn ),
    .adc_p1x    ( adc_p1x ),
    .adc_p1y    ( adc_p1y ),
    .adc_p2x    ( adc_p2x ),
    .adc_p2y    ( adc_p2y ),
    .svc_n      ( ~service_s ),
    .coin1      ( coin1_s ),
    .coin2      ( coin2_s ),
    .step_btn   ( start1_s ),
    .skip_test  ( skip_s ),
    .irq_strict ( 1'b0 ),
    .vshad3_on  ( vshad3_s ),
    .uvol_ym    ( uvol_ym ),
    .uvol_tms   ( uvol_tms ),
    .uvol_fm    ( 24'hFFFFFF ),
    .audio_l    ( audio_l ),
    .audio_r    ( audio_r ),
    .alpha_vaddr( alpha_vaddr ),
    .alpha_vdata( alpha_vdata ),
    .color_vaddr( color_vaddr ),
    .color_vdata( color_vdata ),
    .pf_vaddr   ( pf_vaddr ),
    .pf_vdata   ( pf_vdata ),
    .pfx_vaddr  ( pf_vaddr ),
    .pfx_vdata  ( pfx_vdata ),
    .mo_vaddr   ( mo_vaddr ),
    .mo_vdata   ( mo_vdata ),
    .cfg_vaddr  ( cfg_vaddr ),
    .cfg_vdata  ( cfg_vdata ),
    .xscroll_out( xscroll ),
    .yscroll_out( yscroll ),
    .intensity_out( eintensity ),
    .video_off_out( evideo_off ),
    .e_dead       ( e_dead ),
    .mbox_dead    ( mbox_dead ),
    .wdog_expired ( wdog_expired )
);

endmodule

// 2-flop synchroniser for slow control signals.
module sync2 (input wire clk, input wire d, output reg q = 1'b0);
    reg m = 1'b0;
    always @(posedge clk) begin m <= d; q <= m; end
endmodule

`default_nettype wire
