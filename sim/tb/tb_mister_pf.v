// tb_mister_pf - does the MiSTer playfield graphics channel ever fetch?
//
// WHY THIS BENCH EXISTS
// ---------------------
// BUILD 105 booted on a real DE10-Nano with a completely flat playfield: the
// tilemap and the per-tile colour attributes were plainly correct (the stairs
// structure appeared as a correctly-shaped black silhouette) but every tile's
// PIXELS were the constant 0.  Motion objects, which read the SAME repacked
// graphics region at the SAME byte addresses, were pixel-perfect - so the ROM
// image and the loader's plane->chunky repack were not the suspects.  That
// leaves the PF fetch path.
//
// This bench drives the REAL src/mister/rtl/escape_mister.v (with a tied-off
// stub for the VHDL machine and a behavioural SDRAM chip) through the exact
// hardware sequence: power-on -> long ROM download with the core held in reset
// -> reset release -> free run.  It then counts how many playfield fetches the
// SDRAM arbiter actually serves per frame.
//
// PASS  = the playfield channel keeps fetching after reset release.
// FAIL  = it services zero (or near-zero) fetches, i.e. the flat playfield.
//
// The bench also checks its OWN SDRAM model (SDMODEL) by requiring the core's
// two power-on readback probes to succeed; a mis-calibrated model latency
// fails that check rather than silently invalidating the result.
`timescale 1ns/1ps
`default_nettype none

module tb_mister_pf;

    // 7.159091 MHz / 35.795455 MHz, the shipping frequencies
    localparam real T_SYS = 69.78409;    // half period, ns
    localparam real T_SDR = 13.95682;    // half period, ns

    reg clk_sys = 0, clk_sdram = 0;
    always #(T_SYS) clk_sys   = ~clk_sys;
    always #(T_SDR) clk_sdram = ~clk_sdram;

    reg pll_locked = 0;
    reg reset      = 1;

    reg         ioctl_download = 0;
    reg         ioctl_wr       = 0;
    reg  [24:0] ioctl_addr     = 0;
    reg  [7:0]  ioctl_dout     = 0;
    wire        ioctl_wait;

    wire [12:0] SDRAM_A;
    wire [1:0]  SDRAM_BA;
    wire [15:0] SDRAM_DQ;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS;
    wire        SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;

    wire [7:0] VGA_R, VGA_G, VGA_B;
    wire HSync, VSync, HBlank, VBlank;
    wire [15:0] audio_l, audio_r;
    wire rom_ready;

    escape_mister dut (
        .clk_sys(clk_sys), .clk_sdram(clk_sdram),
        .pll_locked(pll_locked), .reset(reset),
        .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
        .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_wait(ioctl_wait),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .HSync(HSync), .VSync(VSync), .HBlank(HBlank), .VBlank(VBlank),
        .audio_l(audio_l), .audio_r(audio_r),
        .p1_up(1'b0), .p1_down(1'b0), .p1_left(1'b0), .p1_right(1'b0),
        .p1_fire(1'b0), .p1_jump(1'b0), .p1_duck(1'b0), .p1_bomb(1'b0),
        .p2_up(1'b0), .p2_down(1'b0), .p2_left(1'b0), .p2_right(1'b0),
        .p2_fire(1'b0), .p2_jump(1'b0), .p2_duck(1'b0), .p2_bomb(1'b0),
        .p1_analog(16'h8080), .p2_analog(16'h8080),
        .p1_has_analog(1'b0), .p2_has_analog(1'b0),
        .coin1(1'b0), .coin2(1'b0), .start1(1'b0),
        .service(1'b0), .skip_test(1'b0),
        .rom_ready(rom_ready)
    );

    // MERGE-117: renamed - see sim/tb/sdram_model_mem.v for why there are two.
    sdram_model_mem #(.WORDS(25'h00A0000)) chip (
        .clk(clk_sdram), .a(SDRAM_A), .ba(SDRAM_BA), .dq(SDRAM_DQ),
        .dqm({SDRAM_DQMH, SDRAM_DQML}),
        .cas_n(SDRAM_nCAS), .ras_n(SDRAM_nRAS), .we_n(SDRAM_nWE),
        .cke(SDRAM_CKE)
    );

    // ---------------- instrumentation ----------------
    integer pf_grants = 0, mo_grants = 0, cpu_grants = 0;
    integer pf_done   = 0, mo_done   = 0;
    reg     pf_own_d = 0, mo_own_d = 0, cpu_own_d = 0;
    reg [1:0] vgd_d = 0;
    reg [3:0] mgd_d = 0;
    reg       counting = 0;

    always @(posedge clk_sdram) begin
        if (counting) begin
            if (dut.pf_owner  & ~pf_own_d)  pf_grants  = pf_grants  + 1;
            if (dut.mo_owner  & ~mo_own_d)  mo_grants  = mo_grants  + 1;
            if (dut.cpu_owner & ~cpu_own_d) cpu_grants = cpu_grants + 1;
            if (dut.vg_done_85 !== vgd_d)   pf_done    = pf_done    + 1;
            if (dut.mg_done_85 !== mgd_d)   mo_done    = mo_done    + 1;
        end
        pf_own_d  <= dut.pf_owner;
        mo_own_d  <= dut.mo_owner;
        cpu_own_d <= dut.cpu_owner;
        vgd_d     <= dut.vg_done_85;
        mgd_d     <= dut.mg_done_85;
    end

    // ---------------- ROM download helper ----------------
    task put_byte(input [24:0] adr, input [7:0] d);
        begin
            while (ioctl_wait) @(posedge clk_sdram);
            @(posedge clk_sdram);
            ioctl_addr <= adr; ioctl_dout <= d; ioctl_wr <= 1'b1;
            @(posedge clk_sdram);
            ioctl_wr <= 1'b0;
        end
    endtask

    // write one 32-bit group (four consecutive byte addresses)
    task put_group(input [24:0] adr, input [31:0] d);
        begin
            put_byte(adr + 0, d[31:24]);
            put_byte(adr + 1, d[23:16]);
            put_byte(adr + 2, d[15:8]);
            put_byte(adr + 3, d[7:0]);
        end
    endtask

    integer i;
    integer frames_seen;
    reg vs_d;

    // exit codes / results
    integer fails = 0;
    task want(input cond, input [8*40:1] what);
        begin
            if (cond) $display("  PASS  %0s", what);
            else begin $display("  FAIL  %0s", what); fails = fails + 1; end
        end
    endtask

    initial begin
        $display("== tb_mister_pf : playfield fetch service on the MiSTer arbiter ==");
        repeat (10) @(posedge clk_sdram);
        pll_locked <= 1'b1;
        repeat (10) @(posedge clk_sdram);
        reset <= 1'b0;

        // wait for the controller's power-up sequence
        wait (dut.sdram_init_done === 1'b1);
        $display("[%0t] SDRAM init done", $time);

        // ---- ROM download, core held in reset the whole time ----
        ioctl_download <= 1'b1;
        repeat (4) @(posedge clk_sdram);

        // the two power-on probe landmarks the loader checks
        put_group(25'h0000000, 32'h003F_0000);   // reset SP high word
        put_group(25'h0110410, 32'h3388_0000);   // char-ROM landmark
        put_group(25'h0110400, 32'h1111_2222);
        // a little alphanumerics content so the char DMA has something real
        for (i = 0; i < 16; i = i + 1)
            put_group(25'h0110000 + i*4, 32'hA5A5_5A5A);

        // HOLD the download long enough for the free-running pixel pipeline to
        // reach active video and issue playfield fetches - this is the whole
        // point.  On hardware the 2.2 MB transfer covers tens of frames; 26
        // lines is already past the y_count >= VID_V_BPORCH-2 gate.
        $display("[%0t] holding ioctl_download across active video...", $time);
        repeat (60000) @(posedge clk_sdram);
        $display("[%0t] download window over: y_count=%0d inflA=%b inflB=%b pfq_count=%0d",
                 $time, dut.y_count, dut.inflA, dut.inflB, dut.pfq_count);

        ioctl_download <= 1'b0;

        // ---- wait for the core to be released ----
        wait (rom_ready === 1'b1);
        $display("[%0t] rom_ready, chk_ok=%b chk2_ok=%b", $time, dut.chk_ok, dut.chk2_ok);

        // SDMODEL: if the behavioural chip's read latency were wrong these two
        // readbacks would not match, and the rest of the run would be noise.
        want(dut.chk_ok  === 1'b1, "SDMODEL readback probe 0x000000");
        want(dut.chk2_ok === 1'b1, "SDMODEL readback probe 0x110410");

        // let the machine settle a frame, then measure one full frame
        frames_seen = 0; vs_d = VSync;
        while (frames_seen < 1) begin
            @(posedge clk_sys);
            if (VSync & ~vs_d) frames_seen = frames_seen + 1;
            vs_d = VSync;
        end

        pf_grants = 0; mo_grants = 0; cpu_grants = 0; pf_done = 0; mo_done = 0;
        counting  = 1;
        frames_seen = 0;
        while (frames_seen < 1) begin
            @(posedge clk_sys);
            if (VSync & ~vs_d) frames_seen = frames_seen + 1;
            vs_d = VSync;
        end
        counting = 0;

        $display("");
        $display("---- one frame after reset release ----");
        $display("  playfield fetches granted   : %0d", pf_grants);
        $display("  playfield fetches completed : %0d", pf_done);
        $display("  motion-object fetches       : %0d (completed %0d)", mo_grants, mo_done);
        $display("  CPU legacy fetches          : %0d", cpu_grants);
        $display("  channel state: inflA=%b inflB=%b pfq_count=%0d vg_req=%b vg_req_last=%b",
                 dut.inflA, dut.inflB, dut.pfq_count, dut.vg_req_s, dut.vg_req_last);
        $display("");

        // A healthy frame is 42 cells x 240 lines = ~10080 playfield fetches.
        // Anything above a few hundred means the channel is alive; zero means
        // the flat playfield seen on hardware.
        want(pf_done > 500, "playfield channel services fetches");
        want(pf_grants > 500, "playfield channel is granted the bus");

        // ---- PHASE 2: a SECOND ROM download, i.e. loading another .mra
        // without a power cycle.  This tears down an in-flight read (chk_state
        // goes to 0 and sd_rd_req drops) while some client still owns the bus.
        // If the owner flags are not cleared with it, every grant arm - which
        // all require !cpu_owner && !mo_owner && !pf_owner && !fpv_owner &&
        // !fpe_owner - is dead for good and the whole video tier goes with it.
        // The hazard only exists if the download lands while a client actually
        // owns the bus, so SYNCHRONISE to that instead of hoping: a playfield
        // read owns the bus roughly a third of the time, and an unsynchronised
        // version of this test passes by luck about two runs in three.
        $display("---- phase 2: second ROM download (no power cycle) ----");
        while (dut.pf_owner !== 1'b1) @(posedge clk_sdram);
        ioctl_download <= 1'b1;
        @(posedge clk_sdram);
        $display("[%0t] download asserted with pf_owner=%b (must be 1)",
                 $time, dut.pf_owner);
        if (dut.pf_owner !== 1'b1) begin
            $display("  FAIL  phase 2 did not catch an in-flight read");
            fails = fails + 1;
        end
        repeat (3000) @(posedge clk_sdram);
        put_group(25'h0000000, 32'h003F_0000);
        put_group(25'h0110410, 32'h3388_0000);
        repeat (3000) @(posedge clk_sdram);
        ioctl_download <= 1'b0;
        wait (rom_ready === 1'b1);
        $display("[%0t] rom_ready again, owners: cpu=%b mo=%b pf=%b",
                 $time, dut.cpu_owner, dut.mo_owner, dut.pf_owner);

        frames_seen = 0;
        while (frames_seen < 1) begin
            @(posedge clk_sys);
            if (VSync & ~vs_d) frames_seen = frames_seen + 1;
            vs_d = VSync;
        end
        pf_grants = 0; pf_done = 0; mo_grants = 0; mo_done = 0; cpu_grants = 0;
        counting = 1;
        frames_seen = 0;
        while (frames_seen < 1) begin
            @(posedge clk_sys);
            if (VSync & ~vs_d) frames_seen = frames_seen + 1;
            vs_d = VSync;
        end
        counting = 0;
        $display("  playfield fetches after re-download: %0d granted, %0d completed",
                 pf_grants, pf_done);
        want(pf_done > 500, "playfield survives a second ROM download");

        $display("");
        if (fails == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL (%0d checks failed)", fails);
        $finish;
    end

    initial begin
        #900_000_000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
