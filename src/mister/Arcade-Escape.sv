//============================================================================
//  Arcade: Atari "Escape from the Planet of the Robot Monsters"
//
//  MiSTer (DE10-Nano) port of the Analogue Pocket openFPGA core in this
//  repository.  The machine RTL is shared verbatim with the Pocket build;
//  see src/mister/rtl/escape_mister.v for the platform glue and
//  docs/MISTER.md for what is known-working and what is untested.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	output        CE_PIXEL,

	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

`ifdef MISTER_FB
	// MISTER-158: DDR3 framebuffer, driven by sys screen_rotate for the
	// Rotate / Flip 180 options.  With both off the framebuffer disengages
	// (FB_EN low) and video takes the same direct path as build 153.
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`endif

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Default values for ports not used in this core /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM_* is owned by screen_rotate (MISTER-158) - see the VIDEO section.
assign FB_FORCE_BLANK = 0;

assign VGA_F1      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;

assign AUDIO_S   = 1'b1;      // signed samples out of the JSA mixer
assign AUDIO_MIX = 2'd0;

assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];
// MISTER-158: a rotated picture swaps the 4:3 default (Psikyo's arx/ary swap)
assign VIDEO_ARX = (!ar) ? (rotate_en ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	// Plain modern core id (Cave/IGSPGM style; the "A." arcade prefix is
	// the DK-era legacy).  Renaming moves the saved-config namespace.
	"ESCAPE;;",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	// MISTER-158: for rotated / flipped cabinets, the Psikyo core's rows
	"P1O[16:15],Rotate,No,CCW,CW;",
	"P1O[17],Flip 180,Off,On;",
	"P1O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1-;",
	"P1O[27:24],CRT H Adjust,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P1O[31:28],CRT V Adjust,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;",
	// MISTER-159: root spacer between every page link, the Cave layout
	"-;",
	"P2,Audio;",
	// Audio sliders: SENSE IS INVERTED - status powers up 0 and bit-clear
	// must be the default, so the labels count DOWN and the wires are
	// driven ~status[].  Default (status 0) = "7" = full volume.
	"P2O[11:9],Music Volume,7,6,5,4,3,2,1,0;",
	"P2O[14:12],Speech Volume,7,6,5,4,3,2,1,0;",
	"-;",
	// MISTER-157: the DonkeyKong-family pause idiom - a mappable Pause
	// button plus this page - replaces the Psikyo three-state (155/156).
	// OSD-pause defaults Off (owner call, diverging from the DK family's
	// On) so its sense is plain; the dim row IS INVERTED like O[8] -
	// status powers up 0, dim defaults On, wire driven ~status[20].
	"P3,Pause options;",
	"P3O[18],Pause when OSD is open,Off,On;",
	"P3O[20],Dim video after 10s,On,Off;",
	"-;",
	"P4,Debug;",
	// VSHAD3-112 runtime toggle, moved to the Debug page for the
	// mister-devel menu conventions (MISTER-154).  SENSE IS INVERTED ON
	// PURPOSE: status powers up 0 and the shadow's default is ON, so
	// 0 = On and the wire is driven ~status[8].  Writing this "Off,On"
	// would ship every first-boot player the non-default configuration.
	"P4O[8],ROM Shadow 0x54000,On,Off;",
	"P4O[7],Skip Self-Test,Off,On;",
	"-;",
	"O[6],Service Mode,Off,On;",
	"-;",
	"R[0],Reset;",
	"-;",
	"J1,Jump,Fire,Duck,Bomb,Start,Coin,Pause;",
	// owner default: Jump=Y(left) Fire=B(bottom) Duck=A(right) Bomb=X(top);
	// Pause rides the left shoulder, same slot the DK core gives it
	"jn,Y,B,A,X,Start,Select,L;",
	// Renders as "ESCAPE v260901 by spoonelli" - the family convention
	// (Cave's author-credit form): the date IS the version, matching the
	// CoreName_YYYYMMDD.rbf naming.  No internal build number on screen -
	// the build <-> release mapping lives in the release notes.  Main
	// prepends the core id, and the whole line must stay within the OSD's
	// 32 columns or the credit truncates (v158 proved it at 33).
	"V,v",`BUILD_DATE," by spoonelli;"
};

////////////////////////////   CLOCKS   //////////////////////////
wire clk_sys;      //  7.159091 MHz - CPU + pixel
wire clk_ram;      // 35.795455 MHz - SDRAM controller
wire clk_ram_ph;   // 35.795455 MHz - SDRAM chip clock (+90 deg)
wire pll_locked;

pll pll
(
	.refclk   (CLK_50M),
	.rst      (1'b0),
	.outclk_0 (clk_sys),
	.outclk_1 (clk_ram),
	.outclk_2 (clk_ram_ph),
	.locked   (pll_locked)
);

assign SDRAM_CLK = clk_ram_ph;

////////////////////////////   HPS   /////////////////////////////
// hps_io runs on clk_ram so the whole ROM-download path is single-domain.
wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;
wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         ioctl_wait;
wire  [31:0] joystick_0, joystick_1;
wire  [15:0] joystick_l_analog_0, joystick_l_analog_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_ram),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({1'b0, direct_video}),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.ps2_key(ps2_key)
);

// Only ROM index 0 feeds the loader.  The machine has no DIP switches (the
// cabinet is configured through its 93C46 EEPROM), so there is no index-1
// config blob the way the Atari System 1 core carries its slapstic type.
wire rom_wr = ioctl_wr && ioctl_download && (ioctl_index == 16'd0);

/////////////////////////   KEYBOARD   ///////////////////////////
reg kb_up1, kb_dn1, kb_lf1, kb_rt1, kb_jump1, kb_fire1, kb_duck1, kb_bomb1;
reg kb_start1, kb_coin1, kb_start2, kb_coin2;
wire pressed = ps2_key[9];
always @(posedge clk_sys) begin
	reg old_state;
	old_state <= ps2_key[10];
	if (old_state != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h175: kb_up1    <= pressed;   // up arrow
			9'h172: kb_dn1    <= pressed;   // down arrow
			9'h16B: kb_lf1    <= pressed;   // left arrow
			9'h174: kb_rt1    <= pressed;   // right arrow
			9'h014: kb_fire1  <= pressed;   // left ctrl
			9'h011: kb_jump1  <= pressed;   // left alt
			9'h029: kb_duck1  <= pressed;   // space
			9'h012: kb_bomb1  <= pressed;   // left shift
			9'h016: kb_start1 <= pressed;   // 1
			9'h01E: kb_start2 <= pressed;   // 2
			9'h02E: kb_coin1  <= pressed;   // 5
			9'h036: kb_coin2  <= pressed;   // 6
			default: ;
		endcase
	end
end

/////////////////////////   THE MACHINE   ////////////////////////
wire [7:0] core_r, core_g, core_b;
wire       core_hs, core_vs, core_hb, core_vb;
wire [15:0] core_aud_l, core_aud_r;
wire        rom_ready;

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

// MISTER-157: DonkeyKong-family pause - the mappable Pause button toggles,
// OSD-open pauses when the (default-Off, plain-sense) option says so, and
// reset cancels a held pause.  status[19] (155's hard-On state) is retired.
wire pause_btn = joystick_0[10] | joystick_1[10];
reg  pause_toggle = 1'b0;
reg  pause_btn_d  = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (pause_btn & ~pause_btn_d) pause_toggle <= ~pause_toggle;
	if (reset) pause_toggle <= 1'b0;
end
wire pause = pause_toggle | (OSD_STATUS & status[18]);


escape_mister machine
(
	.clk_sys        (clk_sys),
	.clk_sdram      (clk_ram),
	.pll_locked     (pll_locked),
	.reset          (reset),

	.ioctl_download (ioctl_download),
	.ioctl_wr       (rom_wr),
	.ioctl_addr     (ioctl_addr[24:0]),
	.ioctl_dout     (ioctl_dout),
	.ioctl_wait     (ioctl_wait),

	.SDRAM_A        (SDRAM_A),
	.SDRAM_BA       (SDRAM_BA),
	.SDRAM_DQ       (SDRAM_DQ),
	.SDRAM_DQML     (SDRAM_DQML),
	.SDRAM_DQMH     (SDRAM_DQMH),
	.SDRAM_nCS      (SDRAM_nCS),
	.SDRAM_nCAS     (SDRAM_nCAS),
	.SDRAM_nRAS     (SDRAM_nRAS),
	.SDRAM_nWE      (SDRAM_nWE),
	.SDRAM_CKE      (SDRAM_CKE),

	.VGA_R          (core_r),
	.VGA_G          (core_g),
	.VGA_B          (core_b),
	.HSync          (core_hs),
	.VSync          (core_vs),
	.HBlank         (core_hb),
	.VBlank         (core_vb),

	.audio_l        (core_aud_l),
	.audio_r        (core_aud_r),

	// MiSTer joystick bit order: [0]=right [1]=left [2]=down [3]=up,
	// buttons from bit 4 in CONF_STR order (Jump, Fire, Duck, Bomb, Start, Coin)
	.p1_up      (joystick_0[3] | kb_up1),
	.p1_down    (joystick_0[2] | kb_dn1),
	.p1_left    (joystick_0[1] | kb_lf1),
	.p1_right   (joystick_0[0] | kb_rt1),
	.p1_jump    (joystick_0[4] | kb_jump1),
	.p1_fire    (joystick_0[5] | kb_fire1),
	.p1_duck    (joystick_0[6] | kb_duck1),
	.p1_bomb    (joystick_0[7] | kb_bomb1),

	.p2_up      (joystick_1[3]),
	.p2_down    (joystick_1[2]),
	.p2_left    (joystick_1[1]),
	.p2_right   (joystick_1[0]),
	.p2_jump    (joystick_1[4]),
	.p2_fire    (joystick_1[5]),
	.p2_duck    (joystick_1[6]),
	.p2_bomb    (joystick_1[7]),

	// hps_io analog sticks are signed, 0x00 centred; the hall-stick model
	// wants unsigned with 0x80 centred, so flip the sign bit.
	.p1_analog  ({joystick_l_analog_0[15:8] ^ 8'h80, joystick_l_analog_0[7:0] ^ 8'h80}),
	.p2_analog  ({joystick_l_analog_1[15:8] ^ 8'h80, joystick_l_analog_1[7:0] ^ 8'h80}),
	.p1_has_analog (1'b1),
	.p2_has_analog (1'b1),

	.coin1      (joystick_0[9] | kb_coin1),
	.coin2      (joystick_1[9] | kb_coin2),
	.start1     (joystick_0[8] | joystick_1[8] | kb_start1 | kb_start2),
	.service    (status[6]),
	.skip_test  (status[7]),
	// Inverted: see the CONF_STR comment. 0 (power-up / no saved config) =
	// shadow ON, which is the default the Pocket ships.
	.vshad3_on  (~status[8]),

	// MISTER-132: inverted-sense sliders (see CONF_STR comment) + overlay page
	.uvol_ym      (~status[11:9]),
	.uvol_tms     (~status[14:12]),
	.crt_hadj     (status[27:24]),
	.crt_vadj     (status[31:28]),
	.pause        (pause),

	.rom_ready  (rom_ready)
);

assign AUDIO_L = core_aud_l;
assign AUDIO_R = core_aud_r;

////////////////////////////   VIDEO   ///////////////////////////
// arcade_video needs a real CE_PIXEL pulse (it edge-detects it), so the video
// pipeline is clocked at the SDRAM rate with one enable per 7.159 MHz pixel.
// The two clocks are 5:1 siblings off one PLL, so the toggle crossing below
// is a timed path, not a synchroniser.
reg  pix_tog = 1'b0;
always @(posedge clk_sys) pix_tog <= ~pix_tog;
reg [2:0] pix_tog_s = 3'd0;
always @(posedge clk_ram) pix_tog_s <= {pix_tog_s[1:0], pix_tog};
wire core_ce_pix = pix_tog_s[2] ^ pix_tog_s[1];

// MISTER-155: dim the frozen frame to half brightness after 10 s of pause,
// the burn-in guard from JimmyStones' Pause_MiSTer (idiom only, no code
// copied - the Psikyo pause we modelled doesn't carry it, the wider arcade
// family does).  The timer runs in the pixel/CPU domain; the flag flips at
// most once per pause with the picture already frozen, so a two-flop
// resync into clk_ram is plenty.
wire       dim_en = ~status[20];   // inverted sense - see CONF_STR comment
reg [26:0] dim_ctr = 27'd0;
wire       dim_hit = (dim_ctr == 27'd71_590_910);   // 10 s at 7.159091 MHz
always @(posedge clk_sys) begin
	if (pause && dim_en) begin
		if (!dim_hit) dim_ctr <= dim_ctr + 27'd1;
	end else begin
		dim_ctr <= 27'd0;
	end
end
reg [1:0] dim_s = 2'd0;
always @(posedge clk_ram) dim_s <= {dim_s[0], dim_hit};

wire [23:0] RGB_in = dim_s[1] ? {1'b0, core_r[7:1], 1'b0, core_g[7:1], 1'b0, core_b[7:1]}
                              : {core_r, core_g, core_b};
wire  [2:0] fx = status[5:3];

// MISTER-158: Rotate / Flip 180 through the framework's screen_rotate
// (sys/arcade_video.v) and its triple-buffered DDR3 framebuffer.  Wiring
// per the Psikyo core; module and buffer are framework code (sys/ NOTICE
// row).  Rotation is forced off under direct video, matching the DK core.
// With Rotate=No and Flip off, FB_EN stays low and the scaler takes the
// direct VGA_* path - bit-identical to what shipped in 153.
wire [1:0] rotate_sel = status[16:15];
wire       rotate_en  = (rotate_sel != 2'd0) & ~direct_video;
wire       rotate_ccw = (rotate_sel == 2'd1);
wire       flip       = status[17];
wire       no_rotate  = ~rotate_en;
wire       video_rotated;

screen_rotate screen_rotate (.*);

arcade_video #(.WIDTH(336), .DW(24)) arcade_video
(
	// .* wires RGB_in, fx, forced_scandoubler, gamma_bus, CLK_VIDEO,
	// CE_PIXEL and the VGA_* ports by name; everything the core renames is
	// connected explicitly below.
	.*,
	.clk_video(clk_ram),
	.ce_pix(core_ce_pix),
	.HBlank(core_hb),
	.VBlank(core_vb),
	.HSync(core_hs),
	.VSync(core_vs)
);

endmodule
