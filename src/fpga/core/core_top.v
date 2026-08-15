//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
// cram0 pins driven by the psram controller (bake-off lane 3)

assign cram1_a = 'h0;
assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;
assign cram1_adv_n = 1;
assign cram1_cre = 0;
assign cram1_ce0_n = 1;
assign cram1_ce1_n = 1;
assign cram1_oe_n = 1;
assign cram1_we_n = 1;
assign cram1_ub_n = 1;
assign cram1_lb_n = 1;

// dram is driven by sdram_simple + escape integration below

assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// for bridge write data, we just broadcast it to all bus devices
// for bridge read data, we have to mux it
// add your own devices here
always @(*) begin
    casex(bridge_addr)
    default: begin
        bridge_rd_data <= 0;
    end
    32'h10xxxxxx: begin
        // example
        // bridge_rd_data <= example_device_data;
        bridge_rd_data <= 0;
    end
    32'hF8xxxxxx: begin
        bridge_rd_data <= cmd_bridge_rd_data;
    end
    endcase
end


//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;
    
// bridge host commands
// synchronous to clk_74a
    wire            status_boot_done = pll_core_locked_s; 
    wire            status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;
    
    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;
    
    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a

    reg             target_dataslot_read;       
    reg             target_dataslot_write;
    reg             target_dataslot_getfile;    // require additional param/resp structs to be mapped
    reg             target_dataslot_openfile;   // require additional param/resp structs to be mapped
    
    wire            target_dataslot_ack;        
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    reg     [15:0]  target_dataslot_id;
    reg     [31:0]  target_dataslot_slotoffset;
    reg     [31:0]  target_dataslot_bridgeaddr;
    reg     [31:0]  target_dataslot_length;
    
    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands
    
// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),
    
    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    
    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),
    
    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),
    
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    
    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);



////////////////////////////////////////////////////////////////////////////////////////



// video generation
// ~7,159,091 hz pixel clock (Atari Escape native: 456x262 total, 336x240 active, ~59.92 Hz)
//
// we want our video mode of 320x240 @ 60hz, this results in 204800 clocks per frame
// we need to add hblank and vblank times to this, so there will be a nondisplay area. 
// it can be thought of as a border around the visible area.
// to make numbers simple, we can have 400 total clocks per line, and 320 visible.
// dividing 204800 by 400 results in 512 total lines per frame, and 240 visible.
// this pixel clock is fairly high for the relatively low resolution, but that's fine.
// PLL output has a minimum output frequency anyway.


assign video_rgb_clock = clk_sys_7159;
assign video_rgb_clock_90 = clk_sys_7159_90deg;
assign video_rgb = vidout_rgb;
assign video_de = vidout_de;
assign video_skip = vidout_skip;
assign video_vs = vidout_vs;
assign video_hs = vidout_hs;

    localparam  VID_V_BPORCH = 'd12;
    localparam  VID_V_ACTIVE = 'd240;
    localparam  VID_V_TOTAL = 'd262;
    localparam  VID_H_BPORCH = 'd60;
    localparam  VID_H_ACTIVE = 'd336;
    localparam  VID_H_TOTAL = 'd456;

    reg [15:0]  frame_count;
    
    reg [9:0]   x_count;
    reg [9:0]   y_count;
    
    wire [9:0]  visible_x = x_count - VID_H_BPORCH;
    wire [9:0]  visible_y = y_count - VID_V_BPORCH;

    reg [23:0]  vidout_rgb;
    reg         vidout_de, vidout_de_1;
    reg         vidout_skip;
    reg         vidout_vs;
    reg         vidout_hs, vidout_hs_1;
    
    reg [9:0]   square_x = 'd135;
    reg [9:0]   square_y = 'd95;

always @(posedge clk_sys_7159 or negedge reset_n) begin

    if(~reset_n) begin
    
        x_count <= 0;
        y_count <= 0;
        
    end else begin
        vidout_de <= 0;
        vidout_skip <= 0;
        vidout_vs <= 0;
        vidout_hs <= 0;
        
        vidout_hs_1 <= vidout_hs;
        vidout_de_1 <= vidout_de;
        
        // x and y counters
        x_count <= x_count + 1'b1;
        if(x_count == VID_H_TOTAL-1) begin
            x_count <= 0;
            
            y_count <= y_count + 1'b1;
            if(y_count == VID_V_TOTAL-1) begin
                y_count <= 0;
            end
        end
        
        // generate sync 
        if(x_count == 0 && y_count == 0) begin
            // sync signal in back porch
            // new frame
            vidout_vs <= 1;
            frame_count <= frame_count + 1'b1;
        end
        
        // we want HS to occur a bit after VS, not on the same cycle
        if(x_count == 3) begin
            // sync signal in back porch
            // new line
            vidout_hs <= 1;
        end

        // inactive screen areas are black
        vidout_rgb <= 24'h0;
        // generate active video
        if(x_count >= VID_H_BPORCH && x_count < VID_H_ACTIVE+VID_H_BPORCH) begin

            if(y_count >= VID_V_BPORCH && y_count < VID_V_ACTIVE+VID_V_BPORCH) begin
                // data enable. this is the active region of the line
                vidout_de <= 1;

                // alpha (text) layer, with a 6px diagnostic strip at the bottom:
                // 7 segments left->right = init/slot/chk/ok/fetch/pc/extra
                if(diag_on && visible_y >= 'd228 && visible_y < 'd234) begin
                    // chk2_val bit display: 16 x 16px blocks from x=40 (MSB first)
                    if(visible_x >= 'd40 && visible_x < 'd296) begin
                        vidout_rgb <= chk2_val['d15 - ((visible_x - 'd40) >> 4)]
                                      ? 24'hFFFFFF : 24'h303030;
                    end else if(ver_on) begin
                        // BUILD_ID digits (cyan): on-device version check
                        vidout_rgb <= ver_px ? 24'h00FFFF : 24'h101010;
                    end else begin
                        vidout_rgb <= 24'h101010;
                    end
                end else if(diag_on && visible_y >= 'd234) begin
                    case(visible_x[8:6])
                        3'd0: vidout_rgb <= sdram_init_done_s      ? 24'h00A000 : 24'hA00000;
                        3'd1: vidout_rgb <= dataslot_allcomplete_s ? 24'h00A000 : 24'hA00000;
                        3'd2: vidout_rgb <= chk2_ok_s              ? 24'h00A000 : 24'hA00000;
                        3'd3: vidout_rgb <= chk_ok_s               ? 24'h00A000 : 24'hA00000;
                        3'd4: vidout_rgb <= rom_req_seen           ? 24'h00A000 : 24'hA00000;
                        3'd5: vidout_rgb <= (dbg_v_pc_fetch & dbg_e_running) ? 24'h00A000 : 24'hA00000;
                        default: vidout_rgb <= dbg_alpha_wr        ? 24'h00FF00 : 24'h404040;
                    endcase
                end else if(diag_on && in_hexrow) begin
                    vidout_rgb <= hex_px ? 24'hFFFF00 : 24'h101040;
                end else begin
                    vidout_rgb <= alpha_rgb;
                end

            end
        end
    end
end




//
// audio i2s silence generator
// see other examples for actual audio generation
//

assign audio_mclk = audgen_mclk;
assign audio_dac = audgen_dac;
assign audio_lrck = audgen_lrck;

// generate MCLK = 12.288mhz with fractional accumulator
    reg         [21:0]  audgen_accum;
    reg                 audgen_mclk;
    parameter   [20:0]  CYCLE_48KHZ = 21'd122880 * 2;
always @(posedge clk_74a) begin
    audgen_accum <= audgen_accum + CYCLE_48KHZ;
    if(audgen_accum >= 21'd742500) begin
        audgen_mclk <= ~audgen_mclk;
        audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
    end
end

// generate SCLK = 3.072mhz by dividing MCLK by 4
    reg [1:0]   aud_mclk_divider;
    wire        audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
    reg         audgen_lrck_1;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// shift out audio data as I2S 
// 32 total bits per channel, but only 16 active bits at the start and then 16 dummy bits
//
    reg     [4:0]   audgen_lrck_cnt;    
    reg             audgen_lrck;
    reg             audgen_dac;
    // JSA audio: samples from the 7.159 domain; quasi-static double-register
    // (tearing at 48 kHz boundaries is inaudible)
    reg     [15:0]  aud_l_m, aud_l_s, aud_r_m, aud_r_s;
    reg     [15:0]  audgen_shift;
always @(negedge audgen_sclk) begin
    aud_l_m <= aud_l_feed;  aud_l_s <= aud_l_m;
    aud_r_m <= aud_r_feed;  aud_r_s <= aud_r_m;
    // I2S: MSB-first 16 active bits, then zeros for the rest of the 32-bit slot
    audgen_dac   <= audgen_shift[15];
    audgen_shift <= {audgen_shift[14:0], 1'b0};
    // 48khz * 64
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        // switch channels; load the next channel's sample
        audgen_lrck  <= ~audgen_lrck;
        audgen_shift <= audgen_lrck ? aud_l_s : aud_r_s;
    end 
end


///////////////////////////////////////////////


    wire    clk_sys_7159;
    wire    clk_sys_7159_90deg;
    wire    clk_sdram;
    wire    clk_sdram_chip;
    
    wire    pll_core_locked;
    wire    pll_core_locked_s;
synch_3 s01(pll_core_locked, pll_core_locked_s, clk_74a);

mf_pllbase mp1 (
    .refclk         ( clk_74a ),
    .rst            ( 0 ),
    
    .outclk_0       ( clk_sys_7159 ),
    .outclk_1       ( clk_sys_7159_90deg ),
    .outclk_2       ( clk_sdram ),
    .outclk_3       ( clk_sdram_chip ),
    
    .locked         ( pll_core_locked )
);



///////////////////////////////////////////////
// Atari Dual 68k integration: SDRAM + ROM download + escape_core
///////////////////////////////////////////////

assign dram_clk = clk_sdram_chip;

    // ---------------- bridge ROM download (0x10000000 region) -> SDRAM
    // Each bridge write is one 32-bit big-endian word = two 16-bit SDRAM words.
    reg         dl_req_74;          // toggle
    reg  [24:0] dl_addr_74;
    reg  [31:0] dl_data_74;
    reg [21:0] dl_quiet_ctr;
    reg        dl_seen;
always @(posedge clk_74a) begin
    if(bridge_wr && bridge_addr[31:24] == 8'h10) begin
        dl_addr_74 <= bridge_addr[24:0];
        dl_data_74 <= bridge_wr_data;
        dl_req_74  <= ~dl_req_74;
        dl_quiet_ctr <= 22'd0;
        dl_seen      <= 1'b1;
    end else if(!(&dl_quiet_ctr)) begin
        dl_quiet_ctr <= dl_quiet_ctr + 22'd1;
    end
end

    // ---------------- Interact menu (interact.json): service switch + soft reset
    // 0xA0000000: 'Service Mode' checkbox -> self-test lever (260010 D1, active low)
    // 0xA0000010: 'Soft Reset Core' action -> ~56ms CPU reset pulse, like the
    //             cabinet's watchdog restart (flip lever + reset = service menu)
    reg        svc_mode_74 = 1'b0;
    reg        skip_test_74 = 1'b0;   // 0xA0000020: 'Skip Self-Test' checkbox
    reg        wdis_74      = 1'b0;   // 0xA0000030: 'Watchdog Disable' (authentic
                                      // WDIS line, schematic sheet 4 test hook)
    reg        pfprobe_74   = 1'b0;   // 0xA0000060: 'PF Fetch Probe' - HUD fields
                                      // 1/3 become {probed tile code} and
                                      // {fetched gfx word0} for screen cell (16,16)
    reg [2:0]  prefd_74     = 3'd3;   // 0xA0000070: 'PF Prefetch Cells' slider 2-4
    reg        armor_74     = 1'b1;   // 0xA0000080: 'Video Read Armor' (default ON)
    reg        irqstrict_74 = 1'b0;   // 0xA0000090: 'Strict IRQ Ack' (coin suspect)
    reg        inprobe_74   = 1'b0;   // 0xA00000A0: 'Input Probe' - field1 = raw cont1_key
    reg        pfmap_74     = 1'b0;   // 0xA0000050: 'PF Map Debug' - render each
                                      // playfield cell as a flat color hashed from
                                      // its TILE CODE (no gfx fetch): structured
                                      // layout = map content good, gfx side guilty;
                                      // noise = the game writes garbage (extra CPU)
    reg        tone_74      = 1'b0;   // 0xA0000040: 'Audio Test Tone' - splits
                                      // i2s-path faults from JSA-side silence
    reg [22:0] soft_rst_ctr = 23'd0;
always @(posedge clk_74a) begin
    if(bridge_wr && bridge_addr == 32'hA0000000) svc_mode_74 <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000020) skip_test_74 <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000030) wdis_74      <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000040) tone_74      <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000050) pfmap_74     <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000070) prefd_74     <= bridge_wr_data[2:0];
    if(bridge_wr && bridge_addr == 32'hA0000080) armor_74     <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000090) irqstrict_74 <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA00000A0) inprobe_74   <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000060) pfprobe_74   <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000010) soft_rst_ctr <= 23'd1;
    else if(soft_rst_ctr != 23'd0)               soft_rst_ctr <= soft_rst_ctr + 23'd1;
end
    wire soft_rst_74 = (soft_rst_ctr != 23'd0);   // ~113ms self-clearing pulse
    wire svc_mode_s, soft_rst_s, skip_test_s, wdis_s, tone_s, pfmap_s, pfprobe_s;
synch_3 s_pfmap(pfmap_74, pfmap_s, clk_sys_7159);
    wire armor_s, irqstrict_s, inprobe_s;
    wire [2:0] prefd_s;
synch_3 s_armor(armor_74, armor_s, clk_sdram);
synch_3 s_irqst(irqstrict_74, irqstrict_s, clk_sys_7159);
synch_3 s_inpb(inprobe_74, inprobe_s, clk_sys_7159);
synch_3 #(.WIDTH(3)) s_prefd(prefd_74, prefd_s, clk_sys_7159);
synch_3 s_pfprobe(pfprobe_74, pfprobe_s, clk_sys_7159);
synch_3 s_tone(tone_74, tone_s, clk_sys_7159);
synch_3 s_skip(skip_test_74, skip_test_s, clk_sys_7159);
synch_3 s_wdis(wdis_74, wdis_s, clk_sys_7159);
synch_3 s_svc(svc_mode_74, svc_mode_s, clk_sys_7159);
synch_3 s_srst(soft_rst_74, soft_rst_s, clk_sys_7159);
    // high ~56ms after the last download write (and only once a download was seen)
    wire dl_quiet_74 = dl_seen && (&dl_quiet_ctr);
    wire dl_quiet_sd;
synch_3 s_dq(dl_quiet_74, dl_quiet_sd, clk_sdram);

    wire dl_req_s;
synch_3 s_dl(dl_req_74, dl_req_s, clk_sdram);

    reg        dl_req_last;
    reg  [1:0] dl_phase;      // 0 idle, 1 wait ack, 2 wait ack-drop
    reg        sd_wr_req;
    reg [24:0] sd_wr_addr;
    reg [31:0] sd_wr_data;
    wire       sd_wr_ack;
    reg [15:0] blktab [0:1023];        // per-4KB-block checksum table (whole image)
    reg [15:0] dl_blk_sum = 16'd0;
    reg [9:0]  dl_blk_cur = 10'd0;
    reg [9:0]  blk_max    = 10'd0;
    reg        dlq_d      = 1'b0;      // final-block flush on download-quiet edge
    // v58 shadow-fill regs (clk_sdram domain; dual-clock rams inside escape_core)
    reg [23:0] shad_waddr = 24'd0;
    reg [15:0] shad_wdata = 16'd0;
    reg        shad_we    = 1'b0;
    reg [15:0] shad_pend  = 16'd0;
    reg        shad_second= 1'b0;
    // v59: fill-stream checksums. Expected (from the verified image):
    // vshad = 16'h11E9, eshad = 16'h8318. HUD shows both; a mismatch on
    // device = the fill writer corrupted the hot-code shadow.
    reg [15:0] shad_sum_v = 16'd0;
    reg [15:0] shad_sum_e = 16'd0;
always @(posedge clk_sdram) begin
    // second beat of the shadow fill; default release
    if(shad_second) begin
        shad_waddr  <= shad_waddr + 24'd2;
        shad_wdata  <= shad_pend;
        shad_we     <= 1;
        shad_second <= 0;
    end else begin
        shad_we <= 0;
    end
    if(shad_we) begin
        if(shad_waddr[23:16] == 8'h00) shad_sum_v <= shad_sum_v + shad_wdata;
        if(shad_waddr[23:16] == 8'h08) shad_sum_e <= shad_sum_e + shad_wdata;
    end
    case(dl_phase)
    2'd0: begin
        if(dl_req_s != dl_req_last) begin
            dl_req_last <= dl_req_s;
            sd_wr_addr <= dl_addr_74;
            sd_wr_data <= dl_data_74;      // both halves: one burst write
            sd_wr_req  <= 1;
            dl_phase   <= 2'd1;
            // v58: hot-code shadow fill (word 0 now, word 1 next cycle)
            shad_waddr <= dl_addr_74[23:0];
            shad_wdata <= dl_data_74[31:16];
            shad_we    <= 1;
            shad_pend  <= dl_data_74[15:0];
            shad_second<= 1;
            // ROVING scrubber ground truth: per-4KB-block checksum of the WHOLE
            // image. Sequential download: accumulate; flush on block crossing.
            if(dl_addr_74[21:12] != dl_blk_cur) begin
                blktab[dl_blk_cur] <= dl_blk_sum;
                dl_blk_cur <= dl_addr_74[21:12];
                dl_blk_sum <= dl_data_74[31:16] + dl_data_74[15:0];
                if(dl_addr_74[21:12] > blk_max) blk_max <= dl_addr_74[21:12];
            end else begin
                dl_blk_sum <= dl_blk_sum + dl_data_74[31:16] + dl_data_74[15:0];
            end
        end
    end
    2'd1: begin
        if(sd_wr_ack) begin
            sd_wr_req <= 0;
            dl_phase  <= 2'd2;
        end
    end
    2'd2: begin
        if(!sd_wr_ack) dl_phase <= 2'd0;
    end
    default: dl_phase <= 2'd0;
    endcase
    // flush the final block's sum once the download goes quiet
    dlq_d <= dl_quiet_sd;
    if(dl_quiet_sd && !dlq_d) blktab[dl_blk_cur] <= dl_blk_sum;
end

    // ---------------- CRAM0: graphics assets on their own bus (bake-off #3)
    // Gfx region (image 0x110000+) mirrors into CRAM0 during download; the
    // vg/mg video fetch channels are served ENTIRELY from CRAM - the SDRAM
    // belongs to the CPUs (+scrubber). True separate buses, PCB-style.
    wire        cram_busy;
    reg         cram_read_en;
    reg  [21:0] cram_addr;
    wire [15:0] cram_dout;
    wire        cram_avail;
    reg         cram_write_en;
    reg  [15:0] cram_din;

psram #(.CLOCK_SPEED(85.909)) cram0 (
    .clk        ( clk_sdram ),
    .bank_sel   ( 1'b0 ),
    .addr       ( cram_addr ),
    .write_en   ( cram_write_en ),
    .data_in    ( cram_din ),
    .write_high_byte ( 1'b1 ),
    .write_low_byte  ( 1'b1 ),
    .read_en    ( cram_read_en ),
    .read_avail ( cram_avail ),
    .data_out   ( cram_dout ),
    .busy       ( cram_busy ),
    .cram_a     ( cram0_a ),
    .cram_dq    ( cram0_dq ),
    .cram_wait  ( cram0_wait ),
    .cram_clk   ( cram0_clk ),
    .cram_adv_n ( cram0_adv_n ),
    .cram_cre   ( cram0_cre ),
    .cram_ce0_n ( cram0_ce0_n ),
    .cram_ce1_n ( cram0_ce1_n ),
    .cram_oe_n  ( cram0_oe_n ),
    .cram_we_n  ( cram0_we_n ),
    .cram_ub_n  ( cram0_ub_n ),
    .cram_lb_n  ( cram0_lb_n )
);

    // download mirror: queue gfx-region words for CRAM while SDRAM write runs
    reg  [21:0] cq_addr [0:3];
    reg  [15:0] cq_data [0:3];
    reg  [1:0]  cq_wr = 0, cq_rd = 0;
    reg  [2:0]  cq_n = 0;
    reg  [1:0]  cwr_ph = 0;
    // video fetch service from CRAM: two words per 32-bit request
    reg  [1:0]  cvg_ph = 0, cmg_ph = 0;
    reg  [15:0] cvg_hi, cmg_hi;
    reg         cwr_snoop_d = 0;

    // ---------------- escape_core ROM fetch (7.159 domain) -> SDRAM (85.9 domain)
    wire [23:0] core_rom_addr;
    wire        core_rom_req;
    wire        core_rom_req_s;
    reg         core_rom_ack_85;
    wire        core_rom_ack_s;
    wire [31:0] sd_rd_data;
    reg  [31:0] core_rom_data;
    reg         core_rom_par;
    reg         sd_rd_req;
    reg  [24:0] rd_addr_q;   // per-grant latched read address (v39)
    reg         rd_pre_q;    // v42: armor CPU reads only
    wire        sd_rd_ack;
synch_3 s_rr(core_rom_req, core_rom_req_s, clk_sdram);
synch_3 s_ra(core_rom_ack_85, core_rom_ack_s, clk_sys_7159);

    // SDRAM self-check: after init + full ROM download, read word 0 and compare with
    // the known first ROM word (0x003F = high word of the reset SP). Proves the
    // download+readback path with no CPU involvement. Runs before the CPU is released.
    reg        chk_done, chk_ok, chk2_ok;
    reg [15:0] chk2_val;
    reg [15:0] probe0, probe1;      // words @0x000000 (expect 003F) and @0x110400 (expect 33CC)

    reg [23:0] recheck_ctr;
    reg        vg_req_last, vg_done_85, cpu_owner;
    reg        scrub_phase = 1'd0;         // read-integrity scrubber state
    reg [11:0] scrub_tick  = 12'd0;        // ~114us periodic slot timer
    reg        scrub_urgent= 1'd0;         // guaranteed-slot request
    reg [10:0] scrub_addr  = 11'd0;        // word index into first 4KB (steps of 2)
    reg [15:0] scrub_sum   = 16'd0;
    reg [15:0] scrub_err   = 16'd0;        // blocks that mismatched their checksum
    reg [15:0] scrub_pass  = 16'd0;        // completed full-image sweeps
    reg [9:0]  scrub_blk   = 10'd0;        // roving 4KB block index
    reg [15:0] scrub_bad   = 16'h0FFF;     // last failing block (0FFF = none yet)
    reg [15:0] blk_exp     = 16'd0;
    reg [1:0]  vg_phase;
    reg [31:0] vg_data;
    reg        mg_req_last, mg_done_85;
    reg [1:0]  mg_phase;
    reg [31:0] mg_data;
    wire       mg_req_s;
    wire       mo_gfx_req;
    wire [23:0] mo_gfx_addr;
synch_3 s_mg(mo_gfx_req, mg_req_s, clk_sdram);
    wire mg_done_s;
synch_3 s_mgd(mg_done_85, mg_done_s, clk_sys_7159);
    wire       vg_req_s;
    reg        vg_req_px;                 // pixel-domain request toggle
    reg [23:0] vg_addr_px;                // stable while request in flight
synch_3 s_vg(vg_req_px, vg_req_s, clk_sdram);
    wire vg_done_s;
synch_3 s_vgd(vg_done_85, vg_done_s, clk_sys_7159);
    reg [3:0]  chk_state;
    // char ROM DMA: combined image 0x110000..0x113FFF -> 8192x16 BRAM
    reg [13:0] chr_dma_word;         // word index 0..8191
    reg        chr_we;
    reg [15:0] chr_wdata;
    wire       allcomplete_sd;
synch_3 s_acsd(dataslot_allcomplete, allcomplete_sd, clk_sdram);
    wire vidkill_sd;
    wire vidkill_src = cont1_key[11] | m_vidkill_px;
synch_3 s_vk(vidkill_src, vidkill_sd, clk_sdram);   // R2 hold or debug mode 6

always @(posedge clk_sdram) begin
    // CRAM download mirror: ALWAYS active (the original placement inside
    // the 4'd10 steady-state arm meant it never ran during the download -
    // CRAM stayed virgin and reads returned constants: the checkerboard).
        // download-mirror: snoop SDRAM writes (gfx range), enqueue words
        cwr_snoop_d <= sd_wr_req;
        if(sd_wr_req && !cwr_snoop_d && sd_wr_addr >= 25'h110000 && cq_n <= 3'd2) begin
            cq_addr[cq_wr]      <= sd_wr_addr[22:1] - 22'h88000;
            cq_data[cq_wr]      <= sd_wr_data[31:16];
            cq_addr[cq_wr+2'd1] <= (sd_wr_addr[22:1] - 22'h88000) + 22'd1;
            cq_data[cq_wr+2'd1] <= sd_wr_data[15:0];
            cq_wr <= cq_wr + 2'd2;
            cq_n  <= cq_n + 3'd2;
        end
        // download-mirror drain (idle slots only)
        if(cq_n != 3'd0 && cvg_ph==2'd0 && cmg_ph==2'd0
           && !cram_busy && !cram_read_en && cwr_ph==2'd0) begin
            cram_addr     <= cq_addr[cq_rd];
            cram_din      <= cq_data[cq_rd];
            cram_write_en <= 1'b1;
            cwr_ph        <= 2'd1;
        end
        if(cwr_ph==2'd1) begin
            cram_write_en <= 1'b0;
            if(!cram_busy) begin
                cq_rd  <= cq_rd + 2'd1;
                cq_n   <= cq_n - 3'd1;
                cwr_ph <= 2'd0;
            end
        end

    case(chk_state)
    4'd0: if(sdram_init_done && allcomplete_sd && dl_quiet_sd) begin
        sd_rd_req <= 1;                       // probe0 @ 0x000000
        chk_state <= 4'd1;
    end
    4'd1: if(sd_rd_ack) begin
        probe0 <= sd_rd_data[31:16];
        chk_ok <= (sd_rd_data[31:16] == 16'h003F);
        sd_rd_req <= 0;
        chk_state <= 4'd2;
    end
    4'd2: if(!sd_rd_ack) begin
        sd_rd_req <= 1;                       // probe1 @ 0x110400
        chk_state <= 4'd3;
    end
    4'd3: if(sd_rd_ack) begin
        probe1 <= sd_rd_data[31:16];
        sd_rd_req <= 0;
        chk_state <= 4'd4;
    end
    4'd4: if(!sd_rd_ack) begin
        sd_rd_req <= 1;                       // probe2 (deep check) @ 0x110410
        chk_state <= 4'd5;
    end
    4'd5: if(sd_rd_ack) begin
        chk2_val <= sd_rd_data[31:16];
        chk2_ok  <= (sd_rd_data[31:16] == 16'h3388);
        sd_rd_req <= 0;
        chk_state <= 4'd6;
    end
    4'd6: if(!sd_rd_ack) begin
        chr_dma_word <= 14'd0;
        chk_state <= 4'd7;                    // char-ROM DMA
    end
    4'd7: begin
        chr_we <= 0;
        if(!sd_rd_ack) begin
            sd_rd_req <= 1;
            chk_state <= 4'd8;
        end
    end
    4'd8: if(sd_rd_ack) begin
        sd_rd_req <= 0;
        chr_wdata <= sd_rd_data[31:16];
        chr_we    <= 1;
        chk_state <= 4'd9;
    end
    4'd9: begin
        chr_we <= 0;
        if(chr_dma_word == 14'd8191) begin
            chk_done  <= 1;
            chk_state <= 4'd10;
        end else begin
            chr_dma_word <= chr_dma_word + 14'd1;
            chk_state <= 4'd7;
        end
    end
    4'd10: begin
        // VIDEO gfx fetch (v64): TWO word-0-only reads instead of one burst.
        // The second burst word is the capture proven marginal across the
        // v45-v51 CPU saga; the CPU path was cured by word-0-only serving
        // but the video path kept consuming word 1 - that asymmetry is the
        // in-tile playfield/sprite noise. Each beat takes sd_rd_data[31:16]
        // only. Bandwidth: the arbiter just lost the JSA client and the 68ks
        // run hot code from BRAM, so SDRAM is nearly video-exclusive now.
        // (v64: mg_phase==0 required too - the two-beat fetches leave an
        // idle gap between beats that the other client must not fire into)
        if(!vidkill_sd && vg_req_s != vg_req_last && !sd_rd_req && !sd_rd_ack
           && vg_phase==2'd0 && mg_phase==2'd0
           && !(m_mopri_sd && mg_req_s != mg_req_last)) begin
            vg_req_last <= vg_req_s;
            sd_rd_req   <= 1;
            rd_addr_q   <= {1'b0, vg_addr_px};
            rd_pre_q    <= 1'b0;    // v79: video fast path (IO-cell capture
                                    // made the v69-era armor obsolete)
            vg_phase    <= 2'd1;
        end
        if(vg_phase==2'd1 && sd_rd_ack) begin
            vg_data   <= sd_rd_data;   // v68: back to single burst - latency margin
            sd_rd_req <= 0;
            vg_done_85 <= ~vg_done_85;
            vg_phase  <= 2'd0;
        end
        // diagnostic (hold R2): consume video-fetch toggles WITHOUT touching
        // SDRAM - isolates the vg/mg service from the CPU path on hardware
        if(vidkill_sd) begin
            if(vg_req_s != vg_req_last && vg_phase==2'd0) begin
                vg_req_last <= vg_req_s; vg_data <= 32'd0; vg_done_85 <= ~vg_done_85;
            end
            if(mg_req_s != mg_req_last && mg_phase==2'd0) begin
                mg_req_last <= mg_req_s; mg_data <= 32'd0; mg_done_85 <= ~mg_done_85;
            end
        end
        // MO gfx from CRAM: outranks a new vg start (cvg gate above yields
        // via cmg_ph check); two reads per request
        if(!vidkill_sd && mg_req_s != mg_req_last && cvg_ph==2'd0 && cmg_ph==2'd0
           && cwr_ph==2'd0 && !cram_busy && !cram_read_en) begin
            mg_req_last  <= mg_req_s;
            cram_addr    <= mo_gfx_addr[22:1] - 22'h88000;
            cram_read_en <= 1'b1;
            cmg_ph       <= 2'd1;
        end
        if(cmg_ph==2'd1) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin cmg_hi <= cram_dout; cmg_ph <= 2'd2; end
        end
        if(cmg_ph==2'd2 && !cram_busy && !cram_read_en) begin
            cram_addr    <= (mo_gfx_addr[22:1] - 22'h88000) | 22'd1;
            cram_read_en <= 1'b1;
            cmg_ph       <= 2'd3;
        end
        if(cmg_ph==2'd3) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin
                mg_data    <= {cmg_hi, cram_dout};
                mg_done_85 <= ~mg_done_85;
                cmg_ph     <= 2'd0;
            end
        end
        // CPU fetch service. MUST also yield to a PENDING MO request
        // (mg_req_s != mg_req_last), not just an in-flight one: without that
        // check both gates fire on the same edge, one read goes out with the
        // MO address, and the CPU is served sprite pixels as instructions.
        // (Root cause of the v14-v19 per-boot corruption: phantom RAM-test
        // failures, wrong palettes, duplicated chars in ROM-sourced text.)
        // CRAM lane: video no longer touches SDRAM - the CPU service
        // must NOT wait on video-channel state (a stuck CRAM path was
        // starving CPU fetches -> extra CPU death -> watchdog boot loop)
        if(!scrub_urgent && scrub_phase==1'd0) begin
            if(core_rom_req_s && !core_rom_ack_85 && !sd_rd_req && !sd_rd_ack) begin
                sd_rd_req <= 1;
                rd_addr_q <= {1'b0, core_rom_addr};
                rd_pre_q  <= 1;                     // CPU: full armor
                cpu_owner <= 1;
            end
        end
        if(cpu_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 0;
            cpu_owner <= 0;
            core_rom_data <= sd_rd_data;
            core_rom_par  <= ^sd_rd_data;      // even parity rides with the data
            core_rom_ack_85 <= 1;
        end
        if(!core_rom_req_s) core_rom_ack_85 <= 0;
        // READ-INTEGRITY SCRUBBER: continuously re-read the first 4KB of the
        // image and re-verify against the download checksum. A purely idle-slot
        // scrubber starves forever behind the CPUs' continuous fetch stream
        // (v23: PASSES stayed 0), so it earns a guaranteed slot every ~114us:
        // one read each tick, priority over the CPU, ~0.3% of bandwidth.
        scrub_tick <= scrub_tick + 12'd1;
        if(&scrub_tick) scrub_urgent <= 1;
        if(scrub_urgent && scrub_phase==1'd0 && !sd_rd_req && !sd_rd_ack
           && !cpu_owner) begin
            sd_rd_req    <= 1;
            rd_addr_q    <= {3'd0, scrub_blk, scrub_addr, 1'b0};
            rd_pre_q     <= 1;
            scrub_phase  <= 1'd1;
            scrub_urgent <= 0;
        end
        blk_exp <= blktab[scrub_blk];              // registered table read
        if(scrub_phase==1'd1 && sd_rd_ack) begin
            sd_rd_req   <= 0;
            scrub_phase <= 1'd0;
            if(scrub_addr == 11'd2046) begin       // block done: verify + rove on
                scrub_addr <= 11'd0;
                if((scrub_sum + sd_rd_data[31:16] + sd_rd_data[15:0]) != blk_exp) begin
                    scrub_err <= scrub_err + 16'd1;
                    scrub_bad <= {6'd0, scrub_blk};
                end
                scrub_sum <= 16'd0;
                if(scrub_blk >= blk_max) begin
                    scrub_blk  <= 10'd0;
                    scrub_pass <= scrub_pass + 16'd1;   // full-image sweeps
                end else begin
                    scrub_blk <= scrub_blk + 10'd1;
                end
            end else begin
                scrub_addr <= scrub_addr + 11'd2;
                scrub_sum  <= scrub_sum + sd_rd_data[31:16] + sd_rd_data[15:0];
            end
        end
        // while failing, re-probe + re-DMA every ~0.6s
        recheck_ctr <= recheck_ctr + 24'd1;
        if(!chk2_ok && recheck_ctr == 24'hFFFFFF && !sd_rd_req && !sd_rd_ack
           && !core_rom_ack_85) begin
            chk_state <= 4'd2;
        end
    end
    default: chk_state <= 4'd10;
    endcase
end

    // ---------------- SDRAM controller
    wire sdram_init_done;
sdram_simple sdr (
    .clk        ( clk_sdram ),
    .reset_n    ( pll_core_locked ),
    .dram_a     ( dram_a ),
    .dram_ba    ( dram_ba ),
    .dram_dq    ( dram_dq ),
    .dram_dqm   ( dram_dqm ),
    .dram_cas_n ( dram_cas_n ),
    .dram_ras_n ( dram_ras_n ),
    .dram_we_n  ( dram_we_n ),
    .dram_cke   ( dram_cke ),
    .wr_req     ( sd_wr_req ),
    .wr_ack     ( sd_wr_ack ),
    .wr_addr    ( sd_wr_addr ),
    .wr_data    ( sd_wr_data ),
    .rd_req     ( sd_rd_req ),
    .rd_ack     ( sd_rd_ack ),
    // v39 ROOT-CAUSE FIX: in service (state 10) the address is LATCHED at the
    // grant edge (rd_addr_q), one register per transaction - never a live mux
    // over cross-domain wires. v38 forensics proved the CPU was served the
    // word from a wrong ROW (same column, row bits from a hot prior address):
    // valid data, valid parity, wrong location - invisible to every checker.
    .rd_pre     ( (chk_state == 4'd10) ? rd_pre_q : 1'b1 ),   // v48: probes/DMA armored too
    .rd_addr    ( (chk_state == 4'd10) ? rd_addr_q :
                  (chk_state == 4'd1) ? 25'd0 :
                  (chk_state == 4'd3) ? 25'h0110400 :
                  (chk_state == 4'd5) ? 25'h0110410 :
                  (chk_state == 4'd8 || chk_state == 4'd7) ? (25'h0110000 + {10'd0, chr_dma_word, 1'b0}) :
                  {1'b0, core_rom_addr} ),
    .rd_data    ( sd_rd_data ),
    .init_done  ( sdram_init_done )
);

    // ---------------- core reset: wait for ROM fully downloaded + sdram up
    wire dataslot_allcomplete_s, sdram_init_done_s;
synch_3 s_ac(dataslot_allcomplete, dataslot_allcomplete_s, clk_sys_7159);
synch_3 s_id(sdram_init_done, sdram_init_done_s, clk_sys_7159);
    wire chk_done_s, chk_ok_s, chk2_ok_s;
synch_3 s_cd(chk_done, chk_done_s, clk_sys_7159);
synch_3 s_co(chk_ok,   chk_ok_s,   clk_sys_7159);
synch_3 s_c2(chk2_ok,  chk2_ok_s,  clk_sys_7159);
    // watchdog timeout from the game core: pulse a core reset (~113ms) and
    // count occurrences (counter survives the core reset; cleared by APF reset)
    reg [22:0] wdog_rst_ctr = 23'd0;
    reg [7:0]  wdog_rst_cnt = 8'd0;
    reg        wdog_exp_d   = 1'b0;
    always @(posedge clk_sys_7159) begin
        wdog_exp_d <= wdog_expired;
        if(!reset_n) begin
            wdog_rst_ctr <= 23'd0; wdog_rst_cnt <= 8'd0;
        end else begin
            // WDIS: authentic watchdog-disable (debug). If expiry latches
            // while disabled, re-enable takes effect after the next core reset.
            if(wdog_expired && !wdog_exp_d && !wdis_s) begin
                wdog_rst_ctr <= 23'd1;
                wdog_rst_cnt <= wdog_rst_cnt + 8'd1;
            end else if(wdog_rst_ctr != 23'd0)
                wdog_rst_ctr <= wdog_rst_ctr + 23'd1;
        end
    end
    wire wdog_rst = (wdog_rst_ctr != 23'd0);

    // crash site: PC of the last FAULTing instruction, surviving watchdog resets
    reg [15:0] crash_pc = 16'd0;
    reg [15:0] crash_data = 16'd0;   // the opcode word the CPU actually received
    reg [1:0]  crash_src  = 2'd0;    // 00 BRAM, 01 prefetch, 10 cache, 11 SDRAM
    always @(posedge clk_sys_7159) begin
        if(!reset_n) begin
            crash_pc <= 16'd0; crash_data <= 16'd0; crash_src <= 2'd0;
        // FIRST fault of the session only: the root cause, not the cascade
        end else if(dbg_fault && crash_pc == 16'd0) begin
            crash_pc   <= dbg_pc;
            crash_data <= dbg_fdata;
            crash_src  <= dbg_fsrc;
        end
    end

    wire core_reset_n = reset_n & dataslot_allcomplete_s & sdram_init_done_s & chk_done_s
                        & ~soft_rst_s & ~wdog_rst;

    // sticky: CPU has issued at least one ROM fetch
    reg rom_req_seen;
always @(posedge clk_sys_7159) begin
    if(!core_reset_n) rom_req_seen <= 0;
    else if(core_rom_req) rom_req_seen <= 1;
end

    // vblank from the raster generator
    wire vblank_w = ~((y_count >= VID_V_BPORCH) && (y_count < VID_V_BPORCH+VID_V_ACTIVE));

    // ---------------- char ROM BRAM: 8192x16, written by DMA (sdram clk), read by scanout
    reg [15:0] chr_ram [0:8191];
    always @(posedge clk_sdram) begin
        if(chr_we) chr_ram[chr_dma_word] <= chr_wdata;
    end
    reg  [15:0] chr_q;
    reg  [12:0] chr_raddr;
    always @(posedge clk_sys_7159) chr_q <= chr_ram[chr_raddr];

    // ---------------- probe hex display: 4x6 font, 3 values of 4 digits
    // rows 100-123 (4x scale), slots of 16px from x=44:
    //   [p0 p0 p0 p0] _ [p1 p1 p1 p1] _ [p2 p2 p2 p2]   (14 slots, 224px)
    function [3:0] hexfont(input [3:0] d, input [2:0] row);
        case({d, row})
        {4'h0,3'd0}: hexfont=4'b1111; {4'h0,3'd1}: hexfont=4'b1001; {4'h0,3'd2}: hexfont=4'b1001;
        {4'h0,3'd3}: hexfont=4'b1001; {4'h0,3'd4}: hexfont=4'b1001; {4'h0,3'd5}: hexfont=4'b1111;
        {4'h1,3'd0}: hexfont=4'b0010; {4'h1,3'd1}: hexfont=4'b0110; {4'h1,3'd2}: hexfont=4'b0010;
        {4'h1,3'd3}: hexfont=4'b0010; {4'h1,3'd4}: hexfont=4'b0010; {4'h1,3'd5}: hexfont=4'b0111;
        {4'h2,3'd0}: hexfont=4'b1111; {4'h2,3'd1}: hexfont=4'b0001; {4'h2,3'd2}: hexfont=4'b1111;
        {4'h2,3'd3}: hexfont=4'b1000; {4'h2,3'd4}: hexfont=4'b1000; {4'h2,3'd5}: hexfont=4'b1111;
        {4'h3,3'd0}: hexfont=4'b1111; {4'h3,3'd1}: hexfont=4'b0001; {4'h3,3'd2}: hexfont=4'b0111;
        {4'h3,3'd3}: hexfont=4'b0001; {4'h3,3'd4}: hexfont=4'b0001; {4'h3,3'd5}: hexfont=4'b1111;
        {4'h4,3'd0}: hexfont=4'b1001; {4'h4,3'd1}: hexfont=4'b1001; {4'h4,3'd2}: hexfont=4'b1111;
        {4'h4,3'd3}: hexfont=4'b0001; {4'h4,3'd4}: hexfont=4'b0001; {4'h4,3'd5}: hexfont=4'b0001;
        {4'h5,3'd0}: hexfont=4'b1111; {4'h5,3'd1}: hexfont=4'b1000; {4'h5,3'd2}: hexfont=4'b1111;
        {4'h5,3'd3}: hexfont=4'b0001; {4'h5,3'd4}: hexfont=4'b0001; {4'h5,3'd5}: hexfont=4'b1111;
        {4'h6,3'd0}: hexfont=4'b1111; {4'h6,3'd1}: hexfont=4'b1000; {4'h6,3'd2}: hexfont=4'b1111;
        {4'h6,3'd3}: hexfont=4'b1001; {4'h6,3'd4}: hexfont=4'b1001; {4'h6,3'd5}: hexfont=4'b1111;
        {4'h7,3'd0}: hexfont=4'b1111; {4'h7,3'd1}: hexfont=4'b0001; {4'h7,3'd2}: hexfont=4'b0010;
        {4'h7,3'd3}: hexfont=4'b0100; {4'h7,3'd4}: hexfont=4'b0100; {4'h7,3'd5}: hexfont=4'b0100;
        {4'h8,3'd0}: hexfont=4'b1111; {4'h8,3'd1}: hexfont=4'b1001; {4'h8,3'd2}: hexfont=4'b1111;
        {4'h8,3'd3}: hexfont=4'b1001; {4'h8,3'd4}: hexfont=4'b1001; {4'h8,3'd5}: hexfont=4'b1111;
        {4'h9,3'd0}: hexfont=4'b1111; {4'h9,3'd1}: hexfont=4'b1001; {4'h9,3'd2}: hexfont=4'b1111;
        {4'h9,3'd3}: hexfont=4'b0001; {4'h9,3'd4}: hexfont=4'b0001; {4'h9,3'd5}: hexfont=4'b1111;
        {4'hA,3'd0}: hexfont=4'b0110; {4'hA,3'd1}: hexfont=4'b1001; {4'hA,3'd2}: hexfont=4'b1111;
        {4'hA,3'd3}: hexfont=4'b1001; {4'hA,3'd4}: hexfont=4'b1001; {4'hA,3'd5}: hexfont=4'b1001;
        {4'hB,3'd0}: hexfont=4'b1110; {4'hB,3'd1}: hexfont=4'b1001; {4'hB,3'd2}: hexfont=4'b1110;
        {4'hB,3'd3}: hexfont=4'b1001; {4'hB,3'd4}: hexfont=4'b1001; {4'hB,3'd5}: hexfont=4'b1110;
        {4'hC,3'd0}: hexfont=4'b1111; {4'hC,3'd1}: hexfont=4'b1000; {4'hC,3'd2}: hexfont=4'b1000;
        {4'hC,3'd3}: hexfont=4'b1000; {4'hC,3'd4}: hexfont=4'b1000; {4'hC,3'd5}: hexfont=4'b1111;
        {4'hD,3'd0}: hexfont=4'b1110; {4'hD,3'd1}: hexfont=4'b1001; {4'hD,3'd2}: hexfont=4'b1001;
        {4'hD,3'd3}: hexfont=4'b1001; {4'hD,3'd4}: hexfont=4'b1001; {4'hD,3'd5}: hexfont=4'b1110;
        {4'hE,3'd0}: hexfont=4'b1111; {4'hE,3'd1}: hexfont=4'b1000; {4'hE,3'd2}: hexfont=4'b1110;
        {4'hE,3'd3}: hexfont=4'b1000; {4'hE,3'd4}: hexfont=4'b1000; {4'hE,3'd5}: hexfont=4'b1111;
        {4'hF,3'd0}: hexfont=4'b1111; {4'hF,3'd1}: hexfont=4'b1000; {4'hF,3'd2}: hexfont=4'b1110;
        {4'hF,3'd3}: hexfont=4'b1000; {4'hF,3'd4}: hexfont=4'b1000; {4'hF,3'd5}: hexfont=4'b1000;
        default: hexfont=4'b0000;
        endcase
    endfunction

    wire [8:0] hx  = visible_x - 9'd44;
    wire [3:0] slot = hx[8:4];                       // 16px per digit slot
    wire [1:0] gx   = hx[3:2];                       // glyph column (4px scale)
    wire [2:0] gy   = (visible_y - 'd100) >> 2;      // glyph row
    // scrub counters cross clk_sdram -> pixel domain; quasi-static, 2-stage reg
    reg [15:0] scrub_err_px, scrub_pass_px, scrub_bad_px;
    reg [15:0] scrub_err_m,  scrub_pass_m,  scrub_bad_m;
    always @(posedge clk_sys_7159) begin
        scrub_err_m  <= scrub_err;   scrub_err_px  <= scrub_err_m;
        scrub_pass_m <= scrub_pass;  scrub_pass_px <= scrub_pass_m;
        scrub_bad_m  <= scrub_bad;   scrub_bad_px  <= scrub_bad_m;
    end
    // v54 live button probe: the exact nibble the game scanner reads
    // v75: R button (bit 9) cycles an on-device debug mode 0-7, shown as
    // the first digit of the on-screen build ID:
    //   0 normal | 1 PF map debug | 2 input probe | 3 PF fetch probe
    //   4 video armor OFF | 5 strict IRQ ack | 6 vidkill | 7 reserved
    reg [2:0] dbgmode = 3'd0;
    reg       rbtn_d  = 1'b0;
    always @(posedge clk_sys_7159) begin
        rbtn_d <= cont1_key[9];
        if(cont1_key[9] & ~rbtn_d) dbgmode <= dbgmode + 3'd1;
    end
    wire m_pfmap   = pfmap_s   | (dbgmode == 3'd1);
    wire m_inprobe = inprobe_s | (dbgmode == 3'd2);
    wire m_pfprobe = pfprobe_s | (dbgmode == 3'd3);
    // v81 render-timing lab: mode 4 = early pf gfx request (cell phase 1
    // instead of 3, +2px deadline margin); mode 5 = MO fetches win over PF
    // when both pending (PF always won before - sprite shimmer suspect)
    wire m_mopri_px     = (dbgmode == 3'd5);
    wire m_mokill       = (dbgmode == 3'd4);   // v86: sprite-layer kill -
                                               // isolates the dash overlay
    wire m_mopri_sd;
synch_3 s_mopri(m_mopri_px, m_mopri_sd, clk_sdram);
    wire m_vidkill_px   = (dbgmode == 3'd6);
    wire m_moprobe      = (dbgmode == 3'd7);
    reg [7:0] mgreq_cnt, mopen_cnt;
    reg [15:0] moprobe_fr;
    reg mgreq_d2;
    always @(posedge clk_sys_7159) begin
        mgreq_d2 <= mo_gfx_req;
        if(mo_gfx_req != mgreq_d2) mgreq_cnt <= mgreq_cnt + 8'd1;
        if(mo_valid && mo_pen[3:0] != 4'h0) mopen_cnt <= mopen_cnt + 8'd1;
        if(vblank_w && !vb_hud_d) begin
            moprobe_fr <= {mgreq_cnt, mopen_cnt};
            mgreq_cnt  <= 8'd0;
            mopen_cnt  <= 8'd0;
        end
    end
    // v74: user-decoded probe truth: Y+B+A(+X held) = 0x01B0 - so A=4,
    // B=5, Y=7 are the DOCUMENTED bits after all; the only deviation is
    // X = bit 8 (not 6). The lone 0x0100 presses were X itself (macro
    // tests). v73's wholesale shift reverted; macro source moved to [8].
    wire [3:0] btn_probe = {cont1_key[4]|cont1_key[8], 1'b0,
                            cont1_key[5]|cont1_key[8], cont1_key[7]|cont1_key[8]};
    // per-frame display latches for fast-changing HUD values
    reg [15:0] epc_fr, mbox_fr;
    reg        vb_hud_d;
    reg [15:0] jsapc_fr, jsalink_fr;
    reg [15:0] respstat_fr, coincred_fr;
    always @(posedge clk_sys_7159) begin
        vb_hud_d <= vblank_w;
        if(vblank_w && !vb_hud_d) begin
            epc_fr    <= dbg_epc;
            mbox_fr   <= dbg_mbox_resp;
            jsapc_fr  <= dbg_jsa_pc;
            jsalink_fr<= dbg_jsa_link;
            respstat_fr <= dbg_resp_stat;
            coincred_fr <= dbg_coin_cred;
        end
    end
    reg  [3:0] hex_digit;
    always @(*) begin
        // HUD: PC | WRHI | BOOT(flag.reboots)
        // PC = last video-CPU instruction fetch (low 16 bits; boot/march code is
        // all below 0x10000) -> photographing the wedge shows the spin loop.
        // WRHI = last data-write address [23:8] -> names the march region:
        // 16xx shared, 3F5x work, 3F0x pf, 3F2x mo, 3F4x alpha, 3E0x color.
        case(slot)
        // field 1 (v62): {NONZERO-response count, last NONZERO byte}.
        // v61 proved reads churn healthily and coin edges are clean while
        // credits appear - this catches the sub-frame phantom bytes:
        // count ~06 after boot with credits=6 = 6502 greeting leak.
        4'd0:  hex_digit = m_moprobe ? moprobe_fr[15:12] :
                           m_inprobe ? cont1_key[15:12] :
                           m_pfprobe ? probe_code[15:12] : respstat_fr[15:12];
        4'd1:  hex_digit = m_moprobe ? moprobe_fr[11:8] :
                           m_inprobe ? cont1_key[11:8]  :
                           m_pfprobe ? probe_code[11:8]  : respstat_fr[11:8];
        4'd2:  hex_digit = m_moprobe ? moprobe_fr[7:4] :
                           m_inprobe ? cont1_key[7:4]   :
                           m_pfprobe ? probe_code[7:4]   : respstat_fr[7:4];
        4'd3:  hex_digit = m_moprobe ? moprobe_fr[3:0] :
                           m_inprobe ? cont1_key[3:0]   :
                           m_pfprobe ? probe_code[3:0]   : respstat_fr[3:0];
        // middle field (v65): {scrub pass count, scrub ERROR count}. The
        // roving scrubber re-reads the WHOLE image (gfx included) verifying
        // BOTH burst words against download truth. err=00 with passes
        // climbing = SDRAM content and read path proven good, so the pf
        // corruption is in what the CPUs WRITE (game logic / extra CPU);
        // err climbing = the read path is still lying to us.
        4'd5:  hex_digit = scrub_pass_px[7:4];   4'd6:  hex_digit = scrub_pass_px[3:0];
        4'd7:  hex_digit = scrub_err_px[7:4];    4'd8:  hex_digit = scrub_err_px[3:0];
        // field 3 (v61): {coin-line edge count, game credit count $3F7F55}.
        // Edges ticking without Select presses = input line glitching.
        // (replaces the v59 shadow checksum, verified 8318 on device)
        4'd10: hex_digit = m_pfprobe ? probe_data[15:12] : coincred_fr[15:12];
        4'd11: hex_digit = m_pfprobe ? probe_data[11:8]  : coincred_fr[11:8];
        4'd12: hex_digit = m_pfprobe ? probe_data[7:4]   : coincred_fr[7:4];
        4'd13: hex_digit = m_pfprobe ? probe_data[3:0]   : coincred_fr[3:0];
        default: hex_digit = 4'h0;
        endcase
    end
    wire hex_slot_on = (slot!=4'd4 && slot!=4'd9 && slot<4'd14);
    wire [3:0] hex_row = hexfont(hex_digit, gy);
    wire hex_px = hex_slot_on && hex_row[2'd3 - gx];

    // ---------------- on-device build version (diag strip, right of bit row)
    // BUMP EVERY RELEASE and verify on-screen digits match the packaged zip:
    // guards against flashing/labeling control issues.
    localparam [15:0] BUILD_ID = 16'h3034;   // lane 3d - screen shows '34'
    // x264..328: fully inside the 336-wide viewport (x300+ was clipped on device)
    wire [8:0] vx0      = visible_x - 9'd264;
    wire       ver_on   = (visible_x >= 'd264) && (visible_x < 'd328);
    wire [1:0] ver_slot = vx0[5:4];
    reg  [3:0] ver_digit;
    always @(*) case(ver_slot)
        2'd0: ver_digit = {1'b0, dbgmode};  2'd1: ver_digit = BUILD_ID[15:12];
        2'd2: ver_digit = BUILD_ID[7:4];   default: ver_digit = BUILD_ID[3:0];
    endcase
    wire [2:0] ver_gy  = visible_y[2:0] - 3'd4;      // y228..233 -> rows 0..5
    wire [3:0] ver_row = hexfont(ver_digit, ver_gy);
    wire       ver_px  = (vx0[3]==1'b0) && ver_row[2'd3 - vx0[2:1]];
    wire in_hexrow = (visible_y >= 'd100) && (visible_y < 'd124) && (visible_x >= 'd44) && (visible_x < 'd268);

    // ---------------- playfield pipeline (pixel domain)
    // Prefetch 2 cells ahead: map lookup at phase 0, SDRAM gfx request at phase 3
    // (chunky 4bpp row = 2 words via the priority video channel), show via
    // fetch->show buffering at cell boundaries.
    reg  [11:0] pf_vaddr;
    wire [15:0] pf_vdata, pfx_vdata;
    wire [8:0]  xscroll, yscroll;

    wire [8:0] pf_y   = visible_y[8:0] + yscroll;           // scrolled row (mod 512)
    wire [8:0] pf_x2  = vis_x[8:0] + 9'd24 + xscroll;   // v72: fixed 3 ahead again -
                                                        // the runtime depth mux sent
                                                        // the fitter into a 90-minute
                                                        // spiral twice; slider deferred
    reg  [4:0] pfcol_q0, pfcol_q1, pfcol_q2, pfcol_q3, pfcol_show;  // {flip, color[3:0]}
    reg  [3:0] pfcode_q0, pfcode_q1, pfcode_q2, pfcode_q3, pfcode_show; // v66 map debug
    reg [15:0] probe_code = 16'd0, probe_data = 16'd0;      // v67 fetch-truth probe
    reg        probe_arm = 1'b0;
    reg        vg_pending = 1'b0;   // v68: outstanding-fetch flag (the handshake)
    reg  [31:0] pf_fetch, pf_show;
    // v81b: SLOT-ADDRESSED RING replaces the shift pipe. A late completion
    // in the shift design landed in the NEXT cell's slot - the alternating
    // correct/wrong columns ('scrunch') seen when sprite fetches interleave.
    // Each fetch now delivers into the slot for ITS OWN cell whenever it
    // completes; rp re-syncs to wp at every line start (-4 = 0 mod 4).
    reg  [31:0] pfring0, pfring1, pfring2, pfring3;
    reg  [1:0]  pf_wp, pf_infl, pf_rp;
    // v84: request queue decouples issue cadence from channel latency.
    // The old unconditional toggle CANCELLED an unserved request when the
    // next cell's phase arrived (two toggles = no net change) - each burst
    // of MO/CPU/scrub traffic vaporized a fetch = trailing ghost columns.
    reg  [23:0] pfq_addr0, pfq_addr1, pfq_addr2, pfq_addr3;
    reg  [1:0]  pfq_slot0, pfq_slot1, pfq_slot2, pfq_slot3;
    reg  [2:0]  pfq_count;
    reg  [1:0]  pfq_wr, pfq_rd;
    reg  vg_done_last;

    always @(posedge clk_sys_7159) begin
        case(vis_x[2:0])
            3'd0: begin
                pf_vaddr <= {pf_y[8:3], pf_x2[8:3]};        // map row*64 + col
                // cell boundary: advance pipelines
                // show the slot for THIS cell; a still-pending fetch shows
                // that slot's previous-line row (localized, non-spreading)
                case(pf_rp)
                    2'd0: pf_show <= pfring0;  2'd1: pf_show <= pfring1;
                    2'd2: pf_show <= pfring2;  default: pf_show <= pfring3;
                endcase
                pf_rp <= pf_rp + 2'd1;
                pfcol_show <= pfcol_q3;
                pfcode_show<= pfcode_q3;
                pfcol_q3   <= pfcol_q2;
                pfcol_q2   <= pfcol_q1;
                pfcol_q1   <= pfcol_q0;
                pfcode_q3  <= pfcode_q2;
                pfcode_q2  <= pfcode_q1;
                pfcode_q1  <= pfcode_q0;
            end
            3'd3: begin
                // enqueue this cell's fetch (issue side drains when free)
                if(y_count >= VID_V_BPORCH - 2 && y_count < VID_V_BPORCH + VID_V_ACTIVE
                   && pfq_count != 3'd4) begin
                    case(pfq_wr)
                        2'd0: begin pfq_addr0 <= 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0}; pfq_slot0 <= pf_wp; end
                        2'd1: begin pfq_addr1 <= 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0}; pfq_slot1 <= pf_wp; end
                        2'd2: begin pfq_addr2 <= 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0}; pfq_slot2 <= pf_wp; end
                        default: begin pfq_addr3 <= 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0}; pfq_slot3 <= pf_wp; end
                    endcase
                    pfq_wr    <= pfq_wr + 2'd1;
                    pfq_count <= pfq_count + 3'd1;
                    pf_wp     <= pf_wp + 2'd1;
                end
                pfcol_q0   <= {pf_vdata[15], pfx_vdata[11:8]};
                pfcode_q0  <= pf_vdata[3:0] ^ pf_vdata[7:4] ^ pf_vdata[11:8];
                // v67 fetch-truth probe: fixed map cell row16/col16, tile row 0
                if(pf_vaddr == 12'h410 && pf_y[2:0] == 3'd0) begin
                    probe_code <= pf_vdata;
                end
            end
            default: ;
        endcase
        // completion delivers into the in-flight request's own slot
        vg_done_last <= vg_done_s;
        if(vg_done_s != vg_done_last) begin
            case(pf_infl)
                2'd0: pfring0 <= vg_data;  2'd1: pfring1 <= vg_data;
                2'd2: pfring2 <= vg_data;  default: pfring3 <= vg_data;
            endcase
            vg_pending <= 1'b0;
        end
        // issue side: drain the queue whenever the channel is free.
        if(!vg_pending && pfq_count != 3'd0 && !(vg_done_s != vg_done_last)
           && !(mg_req_s != mg_req_last)) begin
            case(pfq_rd)
                2'd0: begin vg_addr_px <= pfq_addr0; pf_infl <= pfq_slot0; end
                2'd1: begin vg_addr_px <= pfq_addr1; pf_infl <= pfq_slot1; end
                2'd2: begin vg_addr_px <= pfq_addr2; pf_infl <= pfq_slot2; end
                default: begin vg_addr_px <= pfq_addr3; pf_infl <= pfq_slot3; end
            endcase
            vg_req_px  <= ~vg_req_px;
            vg_pending <= 1'b1;
            pfq_rd     <= pfq_rd + 2'd1;
            pfq_count  <= pfq_count - 3'd1;
        end
        // line-start re-sync (lead 4 = 0 mod 4) + queue flush
        if(x_count == 10'd0) begin
            pf_rp <= pf_wp;
            pfq_count <= 3'd0; pfq_rd <= pfq_wr;
        end
        // v67 probe: when the request for the probed cell goes out, remember
        // to capture its returned word0 on the next completion
        if(probe_arm && vg_done_s != vg_done_last) begin
            probe_data <= vg_data[31:16];
            probe_arm  <= 1'b0;
        end
        if(vis_x[2:0]==3'd3 && pf_vaddr == 12'h410 && pf_y[2:0]==3'd0
           && y_count >= VID_V_BPORCH - 2 && y_count < VID_V_BPORCH + VID_V_ACTIVE)
            probe_arm <= 1'b1;
    end

    // pixel extraction: chunky nibbles px0..px7 across the 32-bit row; xflip reverses
    wire [2:0] pf_n   = pfcol_show[4] ? (3'd7 - visible_x[2:0]) : visible_x[2:0];
    reg  [3:0] pf_pix;
    always @(*) begin
        if(m_pfmap) begin
            pf_pix = pfcode_show;    // v66 map-debug: flat color per tile code
        end else
        case(pf_n)
            3'd0: pf_pix = pf_show[31:28]; 3'd1: pf_pix = pf_show[27:24];
            3'd2: pf_pix = pf_show[23:20]; 3'd3: pf_pix = pf_show[19:16];
            3'd4: pf_pix = pf_show[15:12]; 3'd5: pf_pix = pf_show[11:8];
            3'd6: pf_pix = pf_show[7:4];   default: pf_pix = pf_show[3:0];
        endcase
    end

    // ---------------- motion objects
    wire [11:0] mo_vaddr;
    wire [15:0] mo_vdata;
    wire [6:0]  cfg_vaddr;
    wire [15:0] cfg_vdata;
    wire [7:0]  mo_pen;
    wire        mo_valid_raw;
    wire        mo_valid = mo_valid_raw & ~m_mokill;

escape_mob umob (
    .clk      ( clk_sys_7159 ),
    .reset_n  ( core_reset_n ),
    .x_count  ( x_count ),
    .y_count  ( y_count ),
    .vbporch  ( VID_V_BPORCH ),
    .vactive  ( VID_V_ACTIVE ),
    .hbporch  ( VID_H_BPORCH ),
    .xscroll  ( xscroll ),
    .yscroll  ( yscroll ),
    .mo_vaddr ( mo_vaddr ),
    .mo_vdata ( mo_vdata ),
    .cfg_vaddr( cfg_vaddr ),
    .cfg_vdata( cfg_vdata ),
    .gfx_req  ( mo_gfx_req ),
    .gfx_addr ( mo_gfx_addr ),
    .gfx_done ( mg_done_s ),
    .gfx_data ( mg_data ),
    .disp_x   ( visible_x[8:0] ),
    .disp_pen ( mo_pen ),
    .disp_valid( mo_valid_raw )
);

    // ---------------- alpha scanout pipeline (pixel clock domain)
    // char cell: 8x8. During pixel phases 4..7 of each cell we prefetch the NEXT cell:
    //   phase 4: present alpha map address    phase 5: latch alpha word (BRAM reg'd)
    //   phase 6: present char row address     phase 7: latch char row + attributes
    wire [10:0] alpha_vaddr;
    wire [15:0] alpha_vdata;
    reg  [10:0] color_vaddr;
    wire [15:0] color_vdata;
    wire [3:0]  eintensity;
    wire        evideo_off;

    reg  [15:0] a_word;       // latched alpha entry (next cell)
    reg  [15:0] a_row;        // latched char row bits (next cell)
    reg  [5:0]  a_color;      // latched color (next cell)
    reg  [15:0] r_row;        // active cell shift source
    reg  [5:0]  r_color;      // active cell color
    reg         r_opaque;

    wire [9:0]  vis_x    = x_count - VID_H_BPORCH;           // wraps during blanking; 456%8==0 keeps phase
    wire [9:0]  next_x   = vis_x + 10'd8;                    // cell being prefetched
    wire [5:0]  cell_col = next_x[8:3];
    wire [4:0]  cell_row = visible_y[7:3];
    assign alpha_vaddr = {cell_row, cell_col};               // row*64 + col

    // row-0 injected test text (ASCII-mapped font): proves the scanout end-to-end
    reg [9:0] test_code;
    always @(*) begin
        case(cell_col)
            6'd1:  test_code = "A"; 6'd2:  test_code = "T"; 6'd3:  test_code = "A";
            6'd4:  test_code = "R"; 6'd5:  test_code = "I"; 6'd7:  test_code = "D";
            6'd8:  test_code = "U"; 6'd9:  test_code = "A"; 6'd10: test_code = "L";
            6'd12: test_code = "6"; 6'd13: test_code = "8"; 6'd14: test_code = "K";
            6'd16: test_code = "A"; 6'd17: test_code = "L"; 6'd18: test_code = "P";
            6'd19: test_code = "H"; 6'd20: test_code = "A"; 6'd22: test_code = "O";
            6'd23: test_code = "K";
            default: test_code = 10'h000;
        endcase
    end
    wire        inject   = (cell_row == 5'd0) && diag_on;
    wire [15:0] eff_alpha = inject ? {6'b000000, test_code} : alpha_vdata;
    reg         r_inject, a_inject;

    always @(posedge clk_sys_7159) begin
        case(vis_x[2:0])
            3'd5: begin
                a_word <= eff_alpha;
            end
            3'd6: begin
                chr_raddr <= {eff_alpha[9:0], visible_y[2:0]};    // code*8 + line
                a_color   <= {eff_alpha[14], 1'b0, eff_alpha[13:10]};
                a_inject  <= inject;
            end
            3'd7: ;
            3'd0: begin
                r_row    <= chr_q;
                r_color  <= a_color;
                r_opaque <= a_word[15];
                r_inject <= a_inject;
            end
            default: ;
        endcase
    end

    // pixel extraction: n = x within cell; MSB plane in high nibbles, LSB in low
    wire [2:0] pxn = visible_x[2:0];
    wire [15:0] act_row = (pxn == 3'd0) ? chr_q : r_row;
    wire       msb = pxn[2] ? act_row[7  - pxn[1:0]] : act_row[15 - pxn[1:0]];
    wire       lsb = pxn[2] ? act_row[3  - pxn[1:0]] : act_row[11 - pxn[1:0]];
    wire [1:0] pix = {msb, lsb};

    // pen -> color RAM (alpha section: pens 0..255)
    wire [5:0] act_color  = (pxn == 3'd0) ? a_color : r_color;
    wire       act_opaque = (pxn == 3'd0) ? a_word[15] : r_opaque;
    wire       alpha_vis_raw = (pix != 2'b00) || act_opaque;
    // layer-isolation debug (a bring-up tool): R (cont1_key[9]) hides MO,
    // L2 (cont1_key[10]) hides the game's alpha layer. Combine to see PF alone.
    // Tied through synch_3 to the pixel clock domain.
    wire       alpha_vis  = alpha_vis_raw & ~iso_alpha_off;
    wire       mo_show    = mo_valid      & ~iso_mo_off;
    // pens: alpha 0..255 = {3'b000,color6,pix2}; playfield 512..767 = {3'b010,color4,pix4}
    always @(posedge clk_sys_7159)
        color_vaddr <= alpha_vis ? {3'b000, act_color, pix}
                     : mo_show   ? {3'b001, mo_pen}
                                 : {3'b010, pfcol_show[3:0], pf_pix};

    // palette: IRGB4444 with intensity: i=(I+1)*(4-intensity), ch8 = ch4*i/4
    wire [3:0] ints   = (eintensity > 4'd4) ? 4'd4 : eintensity;
    wire [6:0] ifac   = ({3'd0, color_vdata[15:12]} + 7'd1) * (7'd4 - {5'd0, ints[2:0]});
    wire [10:0] r_m   = color_vdata[11:8] * ifac;
    wire [10:0] g_m   = color_vdata[7:4]  * ifac;
    wire [10:0] b_m   = color_vdata[3:0]  * ifac;
    wire [7:0] pal_r  = (r_m[10:2] > 9'd255) ? 8'd255 : r_m[9:2];
    wire [7:0] pal_g  = (g_m[10:2] > 9'd255) ? 8'd255 : g_m[9:2];
    wire [7:0] pal_b  = (b_m[10:2] > 9'd255) ? 8'd255 : b_m[9:2];
    reg  inj_px1, inj_px2;   // align inject flag with the 2-cycle color path
    always @(posedge clk_sys_7159) begin
        inj_px1 <= (pxn == 3'd0) ? a_inject : r_inject;
        inj_px2 <= inj_px1;
    end
    reg  [1:0] pix_d1;
    always @(posedge clk_sys_7159) pix_d1 <= pix;
    wire [23:0] inj_rgb = (pix_d1 != 2'b00) ? 24'hFFFFFF : 24'h202020;
    wire [23:0] alpha_rgb = evideo_off ? 24'h000000 :
                            inj_px2    ? inj_rgb    : {pal_r, pal_g, pal_b};

    wire dbg_v_pc_fetch, dbg_e_running, dbg_alpha_wr;
    wire [15:0] dbg_mbox_cmd, dbg_mbox_resp, dbg_mbox_ramr, dbg_mbox_sum;
    wire [15:0] dbg_pf_wcnt, dbg_pf_last, dbg_col_wcnt;
    wire [15:0] dbg_boot;
    wire [15:0] dbg_retry;
    wire [15:0] dbg_a84_wr, dbg_a84_rd;
    wire [15:0] dbg_pc, dbg_wrhi;
    wire [15:0] dbg_vec;
    wire        dbg_fault;
    wire [15:0] dbg_fdata;
    wire [1:0]  dbg_fsrc;
    wire [15:0] dbg_epc;
    wire [15:0] dbg_jsa_link, dbg_jsa_pc;
    wire [15:0] dbg_resp_stat, dbg_coin_cred;
    wire        wdog_expired;
    wire diag_on;
synch_3 s_diag(cont1_key[8], diag_on, clk_sys_7159);
    wire coin1_s, coin2_s;
synch_3 s_coin(cont1_key[14], coin1_s, clk_sys_7159);   // Select = coin 1 (JSA)
synch_3 s_coin2(cont2_key[14], coin2_s, clk_sys_7159);  // P2 Select = coin 2
    wire step_s;
synch_3 s_step(cont1_key[15], step_s, clk_sys_7159);    // Start = self-test step/continue
    wire [15:0] core_audio_l, core_audio_r;
    // ~440Hz square test tone (7159091 / 8134 / 2), modest amplitude
    reg  [12:0] tone_div = 13'd0;
    reg         tone_sq  = 1'b0;
    always @(posedge clk_sys_7159) begin
        if(tone_div == 13'd8134) begin tone_div <= 13'd0; tone_sq <= ~tone_sq; end
        else tone_div <= tone_div + 13'd1;
    end
    wire [15:0] aud_l_feed = tone_s ? (tone_sq ? 16'h1800 : 16'hE800) : core_audio_l;
    wire [15:0] aud_r_feed = tone_s ? (tone_sq ? 16'h1800 : 16'hE800) : core_audio_r;
    wire iso_mo_off, iso_alpha_off;
synch_3 s_isomo(cont1_key[9],  iso_mo_off,    clk_sys_7159);   // R: hide motion objects
synch_3 s_isoal(cont1_key[10], iso_alpha_off, clk_sys_7159);   // L2: hide alpha layer
    // hall-effect stick emulation: d-pad -> absolute ADC axis targets, analog
    // stick (dock) takes priority when deflected — see rtl/hall_stick.v
    wire [7:0] adc_p1x, adc_p1y, adc_p2x, adc_p2y;
hall_stick hall_p1 (
    .clk   ( clk_sys_7159 ),
    .up    ( cont1_key[0] ),   .down  ( cont1_key[1] ),
    .left  ( cont1_key[2] ),   .right ( cont1_key[3] ),
    .joy_x ( cont1_joy[7:0] ), .joy_y ( cont1_joy[15:8] ),
    .adc_x ( adc_p1x ),        .adc_y ( adc_p1y )
);
hall_stick hall_p2 (
    .clk   ( clk_sys_7159 ),
    .up    ( cont2_key[0] ),   .down  ( cont2_key[1] ),
    .left  ( cont2_key[2] ),   .right ( cont2_key[3] ),
    .joy_x ( cont2_joy[7:0] ), .joy_y ( cont2_joy[15:8] ),
    .adc_x ( adc_p2x ),        .adc_y ( adc_p2y )
);
escape_core ecore (
    .clk        ( clk_sys_7159 ),
    .reset_n    ( core_reset_n ),
    .rom_addr   ( core_rom_addr ),
    .rom_data   ( core_rom_data ),
    .rom_par    ( core_rom_par ),
    .rom_req    ( core_rom_req ),
    .rom_ack    ( core_rom_ack_s ),
    .shad_wclk  ( clk_sdram ),
    .shad_waddr ( shad_waddr ),
    .shad_wdata ( shad_wdata ),
    .shad_we    ( shad_we ),
    .vblank_in  ( vblank_w ),
    // {duck, spare, fire, jump} = Pocket {A, -, B, Y}   (schematic sheet 3: CD11..CD8;
    // MAME eprom: D9 = button 1 fire, D8 = button 2 jump, D11 = button 3 duck)
    // QoL layout: Jump on the left (Y), Fire in the middle (B), Duck on the right (A);
    // X (top, otherwise unused) = all three at once = the in-game BOMB
    .p1_buttons ( {cont1_key[4]|cont1_key[8], 1'b0, cont1_key[5]|cont1_key[8], cont1_key[7]|cont1_key[8]} ),
    .svc_n      ( ~svc_mode_s ),
    .coin1      ( coin1_s ),
    .coin2      ( coin2_s ),
    .step_btn   ( step_s ),
    .skip_test  ( skip_test_s ),
    .irq_strict ( irqstrict_s ),
    .audio_l    ( core_audio_l ),
    .audio_r    ( core_audio_r ),
    .p2_buttons ( {cont2_key[4]|cont2_key[8], 1'b0, cont2_key[5]|cont2_key[8], cont2_key[7]|cont2_key[8]} ),
    .adc_p1x    ( adc_p1x ),
    .adc_p1y    ( adc_p1y ),
    .adc_p2x    ( adc_p2x ),
    .adc_p2y    ( adc_p2y ),
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
    .dbg_v_pc_fetch ( dbg_v_pc_fetch ),
    .dbg_e_running  ( dbg_e_running ),
    .dbg_alpha_wr   ( dbg_alpha_wr ),
    .dbg_mbox_cmd   ( dbg_mbox_cmd ),
    .dbg_mbox_resp  ( dbg_mbox_resp ),
    .dbg_mbox_ramr  ( dbg_mbox_ramr ),
    .dbg_mbox_sum   ( dbg_mbox_sum ),
    .dbg_pf_wcnt    ( dbg_pf_wcnt ),
    .dbg_pf_last    ( dbg_pf_last ),
    .dbg_col_wcnt   ( dbg_col_wcnt ),
    .dbg_boot       ( dbg_boot ),
    .dbg_retry      ( dbg_retry ),
    .dbg_a84_wr     ( dbg_a84_wr ),
    .dbg_a84_rd     ( dbg_a84_rd ),
    .dbg_pc         ( dbg_pc ),
    .dbg_wrhi       ( dbg_wrhi ),
    .dbg_vec        ( dbg_vec ),
    .dbg_fault      ( dbg_fault ),
    .dbg_fdata      ( dbg_fdata ),
    .dbg_fsrc       ( dbg_fsrc ),
    .dbg_epc        ( dbg_epc ),
    .dbg_jsa_link   ( dbg_jsa_link ),
    .dbg_jsa_pc     ( dbg_jsa_pc ),
    .dbg_resp_stat  ( dbg_resp_stat ),
    .dbg_coin_cred  ( dbg_coin_cred ),
    .wdog_expired   ( wdog_expired )
);

endmodule

