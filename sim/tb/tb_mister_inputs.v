// tb_mister_inputs: per-game input mapping, both players (INPUTS-180).
//
// Drives the REAL src/mister/rtl/escape_mister.v (VHDL machine stubbed) and
// checks what reaches the machine's input ports for each game_sel:
//   p1_buttons / p2_buttons = {D11, D10, D9, D8} of 260000 / 260010,
//   p1_joy / p2_joy (Klax's digital sticks), adc_p1x/y / adc_p2x/y,
//   coin1 / coin2, step_btn.
// Expected bits come from MAME eprom.cpp's input ports (eprom / klaxp / guts)
// and the MAME traces in docs (Klax reads only D8; Guts D9/D8/D11).
// Each pad's controls must land on its own player's port and nowhere else.
`timescale 1ns/1ps
`default_nettype none

module tb_mister_inputs;
    localparam real T_SYS = 69.78409;
    localparam real T_SDR = 13.95682;
    reg clk_sys = 0, clk_sdram = 0;
    always #(T_SYS) clk_sys   = ~clk_sys;
    always #(T_SDR) clk_sdram = ~clk_sdram;

    reg pll_locked = 0, reset = 1;
    reg  [1:0] game_sel = 2'b00;
    reg p1_up=0,p1_down=0,p1_left=0,p1_right=0,p1_fire=0,p1_jump=0,p1_duck=0,p1_bomb=0;
    reg p2_up=0,p2_down=0,p2_left=0,p2_right=0,p2_fire=0,p2_jump=0,p2_duck=0,p2_bomb=0;
    reg [15:0] p1_analog = 16'h8080, p2_analog = 16'h8080;
    reg coin1=0, coin2=0, start1=0;

    wire        ioctl_wait;
    wire [12:0] SDRAM_A;  wire [1:0] SDRAM_BA;  wire [15:0] SDRAM_DQ;
    wire SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE, SDRAM_CKE;
    wire [7:0] VGA_R, VGA_G, VGA_B;  wire HSync, VSync, HBlank, VBlank;
    wire [15:0] audio_l, audio_r;  wire rom_ready;

    escape_mister dut (
        .uvol_ym(3'b111), .uvol_tms(3'b111), .crt_hadj(4'd0), .crt_vadj(4'd0), .pause(1'b0),
        .clk_sys(clk_sys), .clk_sdram(clk_sdram), .pll_locked(pll_locked), .reset(reset),
        .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(25'd0), .ioctl_dout(8'd0),
        .ioctl_wait(ioctl_wait),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
        .VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
        .HSync(HSync), .VSync(VSync), .HBlank(HBlank), .VBlank(VBlank),
        .audio_l(audio_l), .audio_r(audio_r),
        .p1_up(p1_up), .p1_down(p1_down), .p1_left(p1_left), .p1_right(p1_right),
        .p1_fire(p1_fire), .p1_jump(p1_jump), .p1_duck(p1_duck), .p1_bomb(p1_bomb),
        .p2_up(p2_up), .p2_down(p2_down), .p2_left(p2_left), .p2_right(p2_right),
        .p2_fire(p2_fire), .p2_jump(p2_jump), .p2_duck(p2_duck), .p2_bomb(p2_bomb),
        .p1_analog(p1_analog), .p2_analog(p2_analog),
        .p1_has_analog(1'b1), .p2_has_analog(1'b1),
        .coin1(coin1), .coin2(coin2), .start1(start1),
        .service(1'b0), .skip_test(1'b0), .game_sel(game_sel),
        .rom_ready(rom_ready)
    );

    integer fails = 0, checks = 0;
    task settle; begin repeat (12) @(posedge clk_sys); end endtask
    task expect_btn(input [8*24-1:0] what, input [3:0] e1, input [3:0] e2);
        begin
            settle; checks = checks + 1;
            if (dut.ecore.p1_buttons !== e1 || dut.ecore.p2_buttons !== e2) begin
                fails = fails + 1;
                $display("FAIL game %0d %0s: p1_buttons=%b (want %b) p2_buttons=%b (want %b)",
                         game_sel, what, dut.ecore.p1_buttons, e1, dut.ecore.p2_buttons, e2);
            end else
                $display("ok   game %0d %0s: p1=%b p2=%b", game_sel, what, e1, e2);
        end
    endtask

    // expected {D11,D10,D9,D8} for jump/fire/duck/bomb (MRA positions 1..4)
    function [15:0] want(input [1:0] g);
        case (g)
            2'b00: want = {4'b0001, 4'b0010, 4'b1000, 4'b1011};   // Escape: Jump D8, Fire D9, Duck D11, Bomb = all three
            2'b01: want = {4'b0001, 4'b0001, 4'b0000, 4'b0000};   // Klax: Flip and Flip (2nd) both D8
            default: want = {4'b0010, 4'b0001, 4'b1000, 4'b0000}; // Guts: Button 1 D9, Button 2 D8, Button 3 D11
        endcase
    endfunction

    integer g, t;
    reg [15:0] w;
    initial begin
        repeat (20) @(posedge clk_sys); pll_locked = 1;
        repeat (50) @(posedge clk_sys); reset = 0;
        for (g = 0; g < 3; g = g + 1) begin
            game_sel = g[1:0];
            w = want(g[1:0]);
            expect_btn("idle", 4'b0000, 4'b0000);
            p1_jump = 1; expect_btn("P1 pos1", w[15:12], 4'b0000); p1_jump = 0;
            p1_fire = 1; expect_btn("P1 pos2", w[11:8],  4'b0000); p1_fire = 0;
            p1_duck = 1; expect_btn("P1 pos3", w[7:4],   4'b0000); p1_duck = 0;
            p1_bomb = 1; expect_btn("P1 pos4", w[3:0],   4'b0000); p1_bomb = 0;
            p2_jump = 1; expect_btn("P2 pos1", 4'b0000, w[15:12]); p2_jump = 0;
            p2_fire = 1; expect_btn("P2 pos2", 4'b0000, w[11:8]);  p2_fire = 0;
            p2_duck = 1; expect_btn("P2 pos3", 4'b0000, w[7:4]);   p2_duck = 0;
            p2_bomb = 1; expect_btn("P2 pos4", 4'b0000, w[3:0]);   p2_bomb = 0;
            // digital sticks: {up, down, left, right} per player, nothing crosses over
            p2_up = 1; p2_right = 1; settle; checks = checks + 1;
            if (dut.ecore.p2_joy !== 4'b1001 || dut.ecore.p1_joy !== 4'b0000) begin
                fails = fails + 1; $display("FAIL game %0d P2 stick: p2_joy=%b p1_joy=%b", g, dut.ecore.p2_joy, dut.ecore.p1_joy);
            end else $display("ok   game %0d P2 stick up+right -> p2_joy=1001, p1_joy=0000", g);
            p2_up = 0; p2_right = 0;
            p1_down = 1; p1_left = 1; settle; checks = checks + 1;
            if (dut.ecore.p1_joy !== 4'b0110 || dut.ecore.p2_joy !== 4'b0000) begin
                fails = fails + 1; $display("FAIL game %0d P1 stick: p1_joy=%b p2_joy=%b", g, dut.ecore.p1_joy, dut.ecore.p2_joy);
            end else $display("ok   game %0d P1 stick down+left -> p1_joy=0110, p2_joy=0000", g);
            p1_down = 0; p1_left = 0;
        end
        // analog: P2's stick moves only P2's ADC channels (hall model may ramp)
        p2_analog = 16'h00FF;            // y = 0x00 (up), x = 0xFF (right)
        t = 0; while (t < 200000 && (dut.ecore.adc_p2y == 8'h80 || dut.ecore.adc_p2x == 8'h80)) begin @(posedge clk_sys); t = t + 1; end
        checks = checks + 1;
        if (dut.ecore.adc_p2y == 8'h80 || dut.ecore.adc_p2x == 8'h80 || dut.ecore.adc_p1x != 8'h80 || dut.ecore.adc_p1y != 8'h80) begin
            fails = fails + 1; $display("FAIL analog: p2 x/y=%h/%h p1 x/y=%h/%h", dut.ecore.adc_p2x, dut.ecore.adc_p2y, dut.ecore.adc_p1x, dut.ecore.adc_p1y);
        end else $display("ok   analog: P2 stick -> adc_p2 x/y=%h/%h after %0d clk, P1 stays %h/%h", dut.ecore.adc_p2x, dut.ecore.adc_p2y, t, dut.ecore.adc_p1x, dut.ecore.adc_p1y);
        p2_analog = 16'h8080;
        // coins: each pad's Coin reaches its own coin input
        coin2 = 1; settle; checks = checks + 1;
        if (dut.ecore.coin2 !== 1'b1 || dut.ecore.coin1 !== 1'b0) begin fails = fails + 1; $display("FAIL coin2: coin1=%b coin2=%b", dut.ecore.coin1, dut.ecore.coin2); end
        else $display("ok   pad 2 Coin -> coin2 only");
        coin2 = 0; coin1 = 1; settle; checks = checks + 1;
        if (dut.ecore.coin1 !== 1'b1 || dut.ecore.coin2 !== 1'b0) begin fails = fails + 1; $display("FAIL coin1: coin1=%b coin2=%b", dut.ecore.coin1, dut.ecore.coin2); end
        else $display("ok   pad 1 Coin -> coin1 only");
        coin1 = 0;
        // Start: today it drives step_btn (260000 D0) - recorded, not judged here
        start1 = 1; settle; $display("info Start -> step_btn=%b", dut.ecore.step_btn); start1 = 0;
        $display("%0d checks, %0d failures", checks, fails);
        if (fails == 0) $display("INPUTS PASS"); else $display("INPUTS FAIL");
        $finish;
    end
endmodule
