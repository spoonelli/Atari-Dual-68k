// MOARB crowd-load bench: measures the MiSTer arbiter's motion-object fetch
// service under crowd-scene demand WITH fastpath (speculative CPU) pressure,
// alongside the real free-running playfield pipeline.
//
// Why it exists (MOARB-143 lesson): three arbiter policies went to hardware
// on intuition; one regressed live inputs. This bench scores a policy in
// numbers before it touches a device:
//   - MO tiles served per scanline (the dropout question: a dense line
//     needs ~40 tile fetches; fewer served = truncated sprites),
//   - MO fetch latency avg/max in clk_sdram,
//   - fastpath grants per line (the CPU-health proxy: this is where 137/143
//     starved the machine).
//
// The MO engine is modelled: 4 channels re-issue REISSUE_GAP clks after each
// completion (the blitter's tile turnaround), which approximates a line so
// dense the engine always has the next tile to ask for. The fastpath is
// modelled as an always-hungry sequential consumer. The playfield is NOT
// modelled - the real pipeline runs and fetches.
`timescale 1ns/1ps
`default_nettype none

module tb_mister_moarb;

    localparam real T_SYS = 69.78409;
    localparam real T_SDR = 13.95682;
    localparam integer REISSUE_GAP = 20;   // ~4 pixel clks of blit per tile
    localparam integer LINES       = 100;  // measured window, scanlines
    localparam integer LINE_CLKS   = 2280; // 456 px * 5

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
        .uvol_ym      ( 3'b111 ),
        .uvol_tms     ( 3'b111 ),
        .credits_page ( 2'd0 ),
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

    sdram_model_mem #(.WORDS(25'h1000000)) chip (
        .clk(clk_sdram), .a(SDRAM_A), .ba(SDRAM_BA), .dq(SDRAM_DQ),
        .dqm({SDRAM_DQMH, SDRAM_DQML}),
        .cas_n(SDRAM_nCAS), .ras_n(SDRAM_nRAS), .we_n(SDRAM_nWE),
        .cke(SDRAM_CKE)
    );

    // ---------------- download helpers ----------------
    task put_byte(input [24:0] adr, input [7:0] d);
        begin
            while (ioctl_wait) @(posedge clk_sdram);
            @(posedge clk_sdram);
            ioctl_addr <= adr; ioctl_dout <= d; ioctl_wr <= 1'b1;
            @(posedge clk_sdram);
            ioctl_wr <= 1'b0;
        end
    endtask
    task put_group(input [24:0] adr, input [31:0] d);
        begin
            put_byte(adr + 0, d[31:24]);
            put_byte(adr + 1, d[23:16]);
            put_byte(adr + 2, d[15:8]);
            put_byte(adr + 3, d[7:0]);
        end
    endtask

    // ---------------- MO engine model ----------------
    reg        crowd_on = 0;
    reg [3:0]  mo_model = 4'd0;
    reg [3:0]  busy     = 4'd0;
    reg [3:0]  done_d   = 4'd0;
    integer    gap   [0:3];
    integer    t0    [0:3];
    integer    cyc = 0;
    integer    served = 0, lat_sum = 0, lat_max = 0;
    integer    fp_grants = 0, pf_grants = 0, cpu_grants = 0, mo_grants = 0;
    reg        fpv_own_d = 0, fpe_own_d = 0, pf_own_d = 0, cpu_own_d = 0, mo_own_d = 0;
    integer    ch;

    // fastpath consumer model: bump the wanted address whenever it turns valid
    reg [23:0] fp_addr = 24'h000100;
    reg [23:0] fpe_addr = 24'h040100;
    always @(posedge clk_sdram) if (crowd_on) begin
        if (dut.fpv_valid && (dut.fpv_tag == dut.fpv_addr_s)) fp_addr  <= fp_addr  + 24'd2;
        if (dut.fpe_valid && (dut.fpe_tag == dut.fpe_addr_s)) fpe_addr <= fpe_addr + 24'd2;
    end

    always @(posedge clk_sdram) if (crowd_on) begin
        cyc <= cyc + 1;
        done_d <= dut.mg_done_85;
        for (ch = 0; ch < 4; ch = ch + 1) begin
            if (busy[ch] && (dut.mg_done_85[ch] !== done_d[ch])) begin
                busy[ch] <= 1'b0;
                gap[ch]   = REISSUE_GAP;
                served    = served + 1;
                lat_sum   = lat_sum + (cyc - t0[ch]);
                if ((cyc - t0[ch]) > lat_max) lat_max = cyc - t0[ch];
            end else if (!busy[ch]) begin
                if (gap[ch] == 0) begin
                    mo_model[ch] <= ~mo_model[ch];
                    busy[ch]     <= 1'b1;
                    t0[ch]        = cyc;
                end else gap[ch] = gap[ch] - 1;
            end
        end
        if (dut.fpv_owner & ~fpv_own_d) fp_grants  = fp_grants  + 1;
        if (dut.fpe_owner & ~fpe_own_d) fp_grants  = fp_grants  + 1;
        if (dut.pf_owner  & ~pf_own_d)  pf_grants  = pf_grants  + 1;
        if (dut.cpu_owner & ~cpu_own_d) cpu_grants = cpu_grants + 1;
        if (dut.mo_owner  & ~mo_own_d)  mo_grants  = mo_grants  + 1;
        fpv_own_d <= dut.fpv_owner; fpe_own_d <= dut.fpe_owner;
        pf_own_d  <= dut.pf_owner;  cpu_own_d <= dut.cpu_owner;
        mo_own_d  <= dut.mo_owner;
    end

    integer i;
    integer fails = 0;
    task want(input cond, input [8*44:1] what);
        begin
            if (cond) $display("  PASS  %0s", what);
            else begin $display("  FAIL  %0s", what); fails = fails + 1; end
        end
    endtask

    initial begin
        $display("== tb_mister_moarb : crowd-load MO service vs fastpath pressure ==");
        for (ch = 0; ch < 4; ch = ch + 1) begin gap[ch] = 0; t0[ch] = 0; end
        repeat (10) @(posedge clk_sdram);
        pll_locked <= 1'b1;
        repeat (10) @(posedge clk_sdram);
        reset <= 1'b0;
        wait (dut.sdram_init_done === 1'b1);

        ioctl_download <= 1'b1;
        repeat (4) @(posedge clk_sdram);
        put_group(25'h0000000, 32'h003F_0000);
        put_group(25'h0110410, 32'h3388_0000);
        put_group(25'h0110400, 32'h1111_2222);
        for (i = 0; i < 16; i = i + 1)
            put_group(25'h0110000 + i*4, 32'hA5A5_5A5A);
        repeat (60000) @(posedge clk_sdram);
        ioctl_download <= 1'b0;
        wait (rom_ready === 1'b1);
        $display("[%0t] rom_ready; forcing crowd load", $time);

        // MO demand: forced onto the arbiter's synchronized request stage,
        // with real sprite-bank addresses so openrow's bank map is exercised.
        force dut.mg_req_s_q = mo_model;
        force dut.mo_gfx_addr = {24'h120300, 24'h120200, 24'h120100, 24'h120000};
        // fastpath pressure: both CPUs' speculative lanes always hungry
        force dut.fpv_spec_s = 1'b1;
        force dut.fpe_spec_s = 1'b1;
        force dut.fpv_addr_s = fp_addr;
        force dut.fpe_addr_s = fpe_addr;

        // measure over LINES scanlines of active-ish video
        crowd_on = 1;
        repeat (LINES * LINE_CLKS) @(posedge clk_sdram);
        crowd_on = 0;

        $display("---- crowd window: %0d scanlines (%0d clk_sdram) ----",
                 LINES, LINES*LINE_CLKS);
        $display("  MO tiles served      : %0d  (%0d.%02d per line; dense line needs ~40)",
                 served, served/LINES, (served%LINES)*100/LINES);
        if (served > 0)
            $display("  MO fetch latency     : avg %0d clks, max %0d clks",
                     lat_sum/served, lat_max);
        $display("  fastpath grants      : %0d  (%0d.%02d per line)",
                 fp_grants, fp_grants/LINES, (fp_grants%LINES)*100/LINES);
        $display("  playfield grants     : %0d", pf_grants);
        $display("  demand-CPU grants    : %0d", cpu_grants);
        $display("  MO grants (owner)    : %0d", mo_grants);

        // scoring gates: a policy must BOTH fill a dense line AND keep the
        // fastpath alive. 144's numbers are the recorded baseline; these
        // bounds catch only outright pathology (blanket-rule-style collapse).
        want(served   >= LINES*40, "MO service fills a dense line (>=40/line)");
        want(fp_grants >= LINES*5, "fastpath not starved (>=5 grants/line)");
        want(pf_grants > 0,        "playfield still served");

        if (fails == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL (%0d checks failed)", fails);
        $finish;
    end

endmodule
`default_nettype wire
