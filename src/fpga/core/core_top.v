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
    32'h20xxxxxx: begin
        // EEPROM save slot window. Deliberately decoded across the whole
        // 0x20 region, not just the 512 bytes: APF's read pipeline is
        // buffered by one word, so it issues one transaction PAST the end
        // of a block to collect the final word, and that trailing address
        // must still select this register.
        bridge_rd_data <= ee_bridge_rd_data;
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
    // EEPROM save slot: APF sends [0080 Data slot request read] and then reads
    // our bridge window out to the SD card. Hold the handshake off until the
    // save engine has refreshed that window, so APF can never capture a
    // half-built image. Driven (and timed out) in the EEPROM save block below,
    // so a wedged engine delays the exit rather than hanging the Pocket.
    wire            dataslot_requestread_ack;
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

    reg             target_dataslot_read     = 0;
    reg             target_dataslot_write    = 0;
    reg             target_dataslot_getfile  = 0;   // require additional param/resp structs to be mapped
    reg             target_dataslot_openfile = 0;   // require additional param/resp structs to be mapped
    
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
                        // EEPROM save state - the one thing you cannot see from
                        // the game itself until you have already power-cycled:
                        //   red     virgin EEPROM, no save file was loaded
                        //   teal    save file loaded, nothing written back yet
                        //   amber   the game changed the EEPROM, save pending
                        //   blue    snapshot taken, APF has not confirmed it
                        //   green   APF wrote the save file to the SD card
                        //   magenta APF refused or never answered a save
                        3'd6: vidout_rgb <= (ee_wr_err_s != 8'd0) ? 24'hA000A0 :
                                            ee_dirty_c            ? 24'hA0A000 :
                                            (ee_wr_ok_s  != 8'd0) ? 24'h00A000 :
                                            (ee_savecnt_c!= 8'd0) ? 24'h0000A0 :
                                            ee_loaded_s           ? 24'h008080 :
                                                                    24'hA00000;
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
    reg [4:0]  vpshift_74   = 5'd16;  // 0xA00000B0: 'World X Align' - pf map lead
    reg        invx_74      = 1'b0;   // 0xA00000C0: 'Invert Stick X'
    reg        invy_74      = 1'b0;   // 0xA00000D0: 'Invert Stick Y'
    reg        swapxy_74    = 1'b0;   // 0xA00000E0: 'Swap Stick Axes'
    reg [4:0]  deadzn_74    = 5'd8;   // 0xA00000F0: 'Analog Deadzone'
    // MIX-100 per-FM-channel mixer: 0xA0000120..0x13C, one per YM2151 channel.
    // Defaults are all unity - this is a control surface, not a rebalance.
    reg [2:0]  uvolfm_74 [0:7];
    integer fmi;
    initial for(fmi=0; fmi<8; fmi=fmi+1) uvolfm_74[fmi] = 3'd7;
    reg [2:0]  uvolym_74    = 3'd7;   // 0xA0000100: 'Music Volume' (0=mute,7=unity)
    reg [2:0]  uvoltms_74   = 3'd7;   // 0xA0000110: 'Speech Volume'
    reg        pfmap_74     = 1'b0;   // 0xA0000050: 'PF Map Debug' - render each
                                      // playfield cell as a flat color hashed from
                                      // its TILE CODE (no gfx fetch): structured
                                      // layout = map content good, gfx side guilty;
                                      // noise = the game writes garbage (extra CPU)
    reg        tone_74      = 1'b0;   // 0xA0000040: 'Audio Test Tone' - splits
                                      // i2s-path faults from JSA-side silence
    reg        ee_autoen_74 = 1'b1;   // 0xA0000140: 'EEPROM Autosave' (default ON)
                                      // (0x120-0x13C belong to the MIX-100
                                      //  per-FM-channel mixer)
                                      // ON  = push the EEPROM to the SD card
                                      //       ~1.2 s after the game stops
                                      //       writing it, so a score survives
                                      //       an unclean power-off
                                      // OFF = only the save APF performs when
                                      //       the core is exited normally
    reg [22:0] soft_rst_ctr = 23'd0;
always @(posedge clk_74a) begin
    if(bridge_wr && bridge_addr == 32'hA0000140) ee_autoen_74 <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000000) svc_mode_74 <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000020) skip_test_74 <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000030) wdis_74      <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000040) tone_74      <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000050) pfmap_74     <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000070) prefd_74     <= bridge_wr_data[2:0];
    if(bridge_wr && bridge_addr == 32'hA0000080) armor_74     <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA0000090) irqstrict_74 <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA00000A0) inprobe_74   <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA00000B0) vpshift_74   <= bridge_wr_data[4:0];
    if(bridge_wr && bridge_addr == 32'hA00000C0) invx_74      <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA00000D0) invy_74      <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA00000E0) swapxy_74    <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr == 32'hA00000F0) deadzn_74    <= bridge_wr_data[4:0];
    if(bridge_wr && bridge_addr == 32'hA0000060) pfprobe_74   <= bridge_wr_data[0];
    if(bridge_wr && bridge_addr[31:8] == 24'hA00001 && bridge_addr[7:0] >= 8'h20
       && bridge_addr[7:0] <= 8'h3C && bridge_addr[1:0] == 2'b00)
        uvolfm_74[bridge_addr[4:2]] <= bridge_wr_data[2:0];
    if(bridge_wr && bridge_addr == 32'hA0000100) uvolym_74    <= bridge_wr_data[2:0];
    if(bridge_wr && bridge_addr == 32'hA0000110) uvoltms_74   <= bridge_wr_data[2:0];
    if(bridge_wr && bridge_addr == 32'hA0000010) soft_rst_ctr <= 23'd1;
    else if(soft_rst_ctr != 23'd0)               soft_rst_ctr <= soft_rst_ctr + 23'd1;
end
    wire soft_rst_74 = (soft_rst_ctr != 23'd0);   // ~113ms self-clearing pulse
    wire svc_mode_s, soft_rst_s, skip_test_s, wdis_s, tone_s, pfmap_s, pfprobe_s;
    wire invx_s, invy_s, swapxy_s;
    wire [4:0] vpshift_s, deadzn_s;
synch_3 #(.WIDTH(5)) s_dzn(deadzn_74, deadzn_s, clk_sys_7159);
    wire [2:0] uvolym_s, uvoltms_s;
    wire [23:0] uvolfm_74_flat = {uvolfm_74[7], uvolfm_74[6], uvolfm_74[5], uvolfm_74[4],
                                  uvolfm_74[3], uvolfm_74[2], uvolfm_74[1], uvolfm_74[0]};
    wire [23:0] uvolfm_s;
synch_3 #(.WIDTH(3)) s_uvy(uvolym_74, uvolym_s, clk_sys_7159);
synch_3 #(.WIDTH(3)) s_uvt(uvoltms_74, uvoltms_s, clk_sys_7159);
synch_3 #(.WIDTH(24)) s_uvfm(uvolfm_74_flat, uvolfm_s, clk_sys_7159);
synch_3 s_swx(swapxy_74, swapxy_s, clk_sys_7159);
synch_3 #(.WIDTH(5)) s_vps(vpshift_74, vpshift_s, clk_sys_7159);
synch_3 s_invx(invx_74, invx_s, clk_sys_7159);
synch_3 s_invy(invy_74, invy_s, clk_sys_7159);
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

    // ---------------- EEPROM non-volatile save (APF data slot 2)
    //
    // The game keeps its high-score table and every operator setting in a
    // 2804 EEPROM (68k 0x0E0000-0x0E03FF, low byte only - MAME maps it
    // umask16(0x00ff), so 512 locations). It is BRAM inside escape_core, so
    // without this block everything resets on each power-on, which the real
    // cabinet never did.
    //
    // data.json declares slot 2 as a nonvolatile slot loading at bridge
    // address 0x20000000, 512 bytes. APF then:
    //   * at startup, writes the .sav file into this window (plain bridge
    //     writes, bracketed by [0082] and [008F Data slot access all
    //     complete]) - ee_save copies it into the EEPROM before the 68000s
    //     leave reset;
    //   * at core exit, sends [0080 Data slot request read] and reads the
    //     window back out to the SD card - ee_save refreshes it first, gated
    //     by dataslot_requestread_ack above;
    //   * on demand, honours target command [0184 Data slot write], which the
    //     little FSM below issues whenever the game has finished writing the
    //     EEPROM. That write-through is what makes a score survive a battery
    //     pull rather than only a clean exit.
    //
    // Nothing here can stall the game: ee_save owns only port B of the EEPROM
    // BRAM, and every handshake with APF is timed out.
    localparam [15:0] EE_SLOT_ID   = 16'd2;
    localparam [31:0] EE_BRIDGE_AD = 32'h20000000;
    localparam [31:0] EE_BYTES     = 32'd512;

    // Writes are decoded strictly (512 bytes) so a stray write outside the
    // slot cannot alias into the buffer; reads are decoded across 0x20xxxxxx
    // (see the bridge_rd_data mux for why).
    wire        ee_rgn_74 = (bridge_addr[31:24] == 8'h20);
    wire        ee_sel_74 = ee_rgn_74 && (bridge_addr[23:9] == 15'd0);
    wire [31:0] ee_bridge_rd_data;
    wire        ee_loaded_74, ee_snapdone_74, ee_savereq_74;
    reg         ee_snapreq_74 = 1'b0;
    reg         ee_saveack_74 = 1'b0;
    wire [8:0]  ee_saddr;
    wire [7:0]  ee_sdin, ee_sq, ee_savecnt_c;
    wire        ee_swe, ee_wrpulse, ee_ready_c, ee_dirty_c;
    wire        ee_autoen_s, ee_loaded_s;
    wire [7:0]  ee_wr_ok_s, ee_wr_err_s;
    reg  [7:0]  ee_wr_ok  = 8'd0;    // slot writes APF completed  (diag strip)
    reg  [7:0]  ee_wr_err = 8'd0;    // slot writes that failed    (diag strip)
synch_3 s_eeauto(ee_autoen_74, ee_autoen_s, clk_sys_7159);
    // diag-strip status, into the pixel domain
synch_3 s_eeld(ee_loaded_74, ee_loaded_s, clk_sys_7159);
synch_3 #(.WIDTH(8)) s_eeok(ee_wr_ok,  ee_wr_ok_s,  clk_sys_7159);
synch_3 #(.WIDTH(8)) s_eeerr(ee_wr_err, ee_wr_err_s, clk_sys_7159);

ee_save ee (
    .bclk       ( clk_74a ),
    .b_sel      ( ee_sel_74 ),
    .b_wr       ( bridge_wr ),
    // latch only on reads aimed at our region, so an unrelated bridge read
    // between the last data word and APF's trailing pipeline read cannot
    // clobber the word still owed to APF
    .b_rd       ( bridge_rd & ee_rgn_74 ),
    .b_addr     ( bridge_addr[8:2] ),
    .b_wdata    ( bridge_wr_data ),
    .b_rdata    ( ee_bridge_rd_data ),
    .b_loaded   ( ee_loaded_74 ),
    .b_allcomp  ( dataslot_allcomplete ),
    .b_snapreq  ( ee_snapreq_74 ),
    .b_snapdone ( ee_snapdone_74 ),
    .b_savereq  ( ee_savereq_74 ),
    .b_saveack  ( ee_saveack_74 ),
    .cclk       ( clk_sys_7159 ),
    .c_ready    ( ee_ready_c ),
    .c_autoen   ( ee_autoen_s ),
    .c_wrpulse  ( ee_wrpulse ),
    .c_addr     ( ee_saddr ),
    .c_din      ( ee_sdin ),
    .c_we       ( ee_swe ),
    .c_q        ( ee_sq ),
    .c_savecnt  ( ee_savecnt_c ),
    .c_dirty    ( ee_dirty_c )
);

    // exit-time readback gate. ~452 ms at 74.25 MHz before we give up and let
    // APF read whatever the window already holds - which is always a complete
    // older image, never a partial one.
    wire        ee_rd_pending = dataslot_requestread & (dataslot_requestread_id == EE_SLOT_ID);
    reg  [24:0] ee_rd_to = 25'd0;
assign dataslot_requestread_ack = ~ee_rd_pending | ee_snapdone_74 | (&ee_rd_to);
always @(posedge clk_74a) begin
    if(ee_rd_pending) begin
        ee_snapreq_74 <= 1'b1;
        if(!(&ee_rd_to)) ee_rd_to <= ee_rd_to + 25'd1;
    end else begin
        ee_snapreq_74 <= 1'b0;
        ee_rd_to      <= 25'd0;
    end
end

    // [0184 Data slot write] issuer. Four-phase with ee_save: it snapshots the
    // EEPROM, raises b_savereq, we push the slot to disk, we ack, it releases.
    // ~226 ms timeout on APF's reply so a framework that never answers costs
    // us one skipped save, not a stuck engine.
    reg  [2:0]  ee_tw     = 3'd0;
    reg  [23:0] ee_tw_to  = 24'd0;
always @(posedge clk_74a) begin
    target_dataslot_read     <= 1'b0;
    target_dataslot_getfile  <= 1'b0;
    target_dataslot_openfile <= 1'b0;
    target_dataslot_write    <= 1'b0;   // rising-edge triggered: one-cycle pulse
    case(ee_tw)
    3'd0: begin
        ee_saveack_74 <= 1'b0;
        ee_tw_to      <= 24'd0;
        // never race APF's own exit-time readback of the same slot
        if(ee_savereq_74 && !ee_rd_pending && ee_autoen_74) begin
            target_dataslot_id         <= EE_SLOT_ID;
            target_dataslot_slotoffset <= 32'd0;
            target_dataslot_bridgeaddr <= EE_BRIDGE_AD;
            target_dataslot_length     <= EE_BYTES;
            ee_tw <= 3'd1;
        end else if(ee_savereq_74) begin
            // autosave disabled, or APF is reading the slot anyway: drop it
            ee_tw <= 3'd4;
        end
    end
    3'd1: begin
        target_dataslot_write <= 1'b1;
        ee_tw <= 3'd2;
    end
    3'd2: begin
        // target_dataslot_done is sticky from the previous command until
        // core_bridge_cmd starts this one; wait for it to clear first
        ee_tw_to <= ee_tw_to + 24'd1;
        if(!target_dataslot_done) ee_tw <= 3'd3;
        else if(&ee_tw_to) begin ee_wr_err <= ee_wr_err + 8'd1; ee_tw <= 3'd4; end
    end
    3'd3: begin
        ee_tw_to <= ee_tw_to + 24'd1;
        if(target_dataslot_done) begin
            if(target_dataslot_err == 3'd0) ee_wr_ok  <= ee_wr_ok  + 8'd1;
            else                            ee_wr_err <= ee_wr_err + 8'd1;
            ee_tw <= 3'd4;
        end else if(&ee_tw_to) begin
            ee_wr_err <= ee_wr_err + 8'd1;   // APF never answered
            ee_tw <= 3'd4;
        end
    end
    3'd4: begin
        ee_saveack_74 <= 1'b1;
        if(!ee_savereq_74) ee_tw <= 3'd0;
    end
    default: ee_tw <= 3'd0;
    endcase
end

    reg        dl_req_last;
    reg  [1:0] dl_phase;      // 0 idle, 1 wait ack, 2 wait ack-drop
    reg        sd_wr_req;
    reg [24:0] sd_wr_addr;
    reg [31:0] sd_wr_data;
    wire       sd_wr_ack;
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
        end
    end
    2'd1: begin
        if(sd_wr_ack) begin
            sd_wr_req <= 0;
            dl_phase  <= 2'd2;
        end
    end
    2'd2: begin
        // LANE3e backpressure: hold the download step until the CRAM
        // mirror queue has drained - zero dropped gfx words by construction
        if(!sd_wr_ack && cq_bp_ok) dl_phase <= 2'd0;
    end
    default: dl_phase <= 2'd0;
    endcase
    dlq_d <= dl_quiet_sd;
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
    reg  [21:0] cq_addr [0:7];
    reg  [15:0] cq_data [0:7];
    reg  [2:0]  cq_wr = 0, cq_rd = 0;
    reg  [3:0]  cq_n = 0;
    reg  [1:0]  cwr_ph = 0;
    // video fetch service from CRAM: two words per 32-bit request
    reg  [1:0]  cvg_ph = 0;
    reg  [2:0]  cmg_ph = 0;
    reg         vgmg_last_mo = 1'b0;   // mo-fair: round-robin PF/MO state
    reg  [15:0] cvg_hi, cmg_hi;
    reg         cwr_snoop_d = 0;
    wire        cq_bp_ok = (cq_n <= 4'd2);
    reg         cq_enq, cq_deq;
    // LANE3g CRAM self-test: after download, read back 256 words from the
    // char region (cram words 0..255 = image 0x110000..0x1101FF) and 256
    // from the sprite region (words 0x8000.. = image 0x120000..); sum16s
    // shown on HUD fields. Python computes expected from the local image.
    reg  [1:0]  cst_ph = 0;
    reg  [8:0]  cst_i = 0;
    reg  [15:0] cst_sum0 = 0, cst_sum1 = 0;
    reg         cst_go = 0, cst_done = 0;
    reg         vb_cst_d = 0;   // LANE4m re-arm edge

    // ---------------- escape_core ROM fetch (7.159 domain) -> SDRAM (85.9 domain)
    wire [23:0] core_rom_addr;
    wire        core_rom_req;
    wire        core_rom_req_s;
    reg         core_rom_ack_85;
    wire        core_rom_ack_s;
    wire [31:0] sd_rd_data;
    reg  [31:0] core_rom_data;
    reg         core_rom_par;
    reg  [3:0]  core_rom_par4;               // SDSCHED-81 per-byte parity
    reg         sd_rd_req;
    reg  [24:0] rd_addr_q;   // per-grant latched read address (v39)
    reg         rd_pre_q;    // v42: armor CPU reads only
    wire        sd_rd_ack;
    // sdram-sched: 7.159 and 85.909 are same-PLL siblings (12:1) and the
    // SDC now groups them synchronous, so a single capture FF is a TIMED
    // path - not a metastability risk. The 3-stage ack-return chain alone
    // cost ~2 CPU clocks on every SDRAM access; this is the tier-2 fast
    // path, first stage (scheduled TDM service comes next if this proves).
    reg core_rom_req_s_q;
    always @(posedge clk_sdram)    core_rom_req_s_q <= core_rom_req;
    assign core_rom_req_s = core_rom_req_s_q;
    reg core_rom_ack_s_q;
    always @(posedge clk_sys_7159) core_rom_ack_s_q <= core_rom_ack_85;
    assign core_rom_ack_s = core_rom_ack_s_q;

    // SDSCHED-88 ZERO-WAIT FASTPATH: per-CPU one-word read cache, filled
    // SPECULATIVELY from the live 7.159-domain bus. escape_core exports each
    // CPU's image address + a raw ROM-region decode (no as_n): the TG68K
    // kernel presents the next fetch address a full CPU clock before AS
    // falls, so the ~13-clk armored SDRAM read completes well before the
    // first post-AS CPU edge and DTACK lands at the authentic 4-clock phase.
    // ROM is read-only, so a speculative read can never have side effects,
    // and ready is tag-compared against the CPU's CURRENT address every 85.9
    // clock, so a stale serve is structurally impossible. All crossings are
    // single-FF timed paths (SDSCHED-73/74 SDC grouping); fpv/fpe_data
    // settle >=2 sdram clocks before ready can assert (vpre stage), and the
    // 7.159 side consumes them through escape_core's registered v_di_r/
    // e_di_r capture (SDSCHED-83), so data is stable long before the CPU
    // takes it.
    // BISECT-93: fastpath OFF. Device evidence beats bench greens: coin-in
    // worked on '88 (pre-zerowait) and fails on '90-'92, and speech now
    // cuts out mid-phrase - BOTH are JSA-subsystem symptoms that the
    // interrupt work never touched but the zero-wait merge did (constant
    // speculative fills = far more SDRAM traffic; refresh deferral). This
    // build isolates: legacy memory path + the '92 armed-IRQ fix.
    localparam FASTPATH_EN = 1;   // 95: back ON, now with authentic SCOM link timing
    // TASLOCK-102: shared-RAM read-modify-write interlock (the TAS-atomicity
    // fix). 1 = on (ship). 0 = off, i.e. exactly the pre-102 shared RAM, and
    // the whole block prunes - that is the A/B baseline for resources and the
    // one-line revert if the device ever disagrees. 2 = DTACK-only, a bench
    // diagnostic that is deliberately broken; never ship it.
    localparam TASLOCK_EN  = 1;
    wire [23:0] fpv_addr_w, fpe_addr_w;      // escape_core exports (7.159 dom)
    wire        fpv_spec_w, fpe_spec_w;
    reg  [23:0] fpv_addr_s, fpe_addr_s;      // 85.9-domain samples
    reg         fpv_spec_s = 1'b0, fpe_spec_s = 1'b0;
    always @(posedge clk_sdram) begin
        fpv_addr_s <= fpv_addr_w;  fpv_spec_s <= fpv_spec_w;
        fpe_addr_s <= fpe_addr_w;  fpe_spec_s <= fpe_spec_w;
    end
    reg  [23:0] fpv_tag,  fpe_tag;           // cached word's image address
    reg         fpv_valid = 1'b0, fpe_valid = 1'b0;  // tag/data pair live
    reg         fpv_vpre  = 1'b0, fpe_vpre  = 1'b0;  // data landed, valid next clk
    reg  [15:0] fpv_data,  fpe_data;
    reg         fpv_owner = 1'b0, fpe_owner = 1'b0;  // fill in flight on sd_rd
    reg         fpv_ready_q = 1'b0, fpe_ready_q = 1'b0;
    reg         fp_last_v = 1'b0;            // fair alternation on collision
    wire fpv_want = FASTPATH_EN && core_rstn_sd && fpv_spec_s && !fpv_owner
                    && !fpv_vpre && !(fpv_valid && fpv_tag == fpv_addr_s);
    wire fpe_want = FASTPATH_EN && core_rstn_sd && fpe_spec_s && !fpe_owner
                    && !fpe_vpre && !(fpe_valid && fpe_tag == fpe_addr_s);
    always @(posedge clk_sdram) begin
        fpv_ready_q <= FASTPATH_EN && fpv_valid && fpv_spec_s && (fpv_tag == fpv_addr_s);
        fpe_ready_q <= FASTPATH_EN && fpe_valid && fpe_spec_s && (fpe_tag == fpe_addr_s);
    end

    // SDRAM self-check: after init + full ROM download, read word 0 and compare with
    // the known first ROM word (0x003F = high word of the reset SP). Proves the
    // download+readback path with no CPU involvement. Runs before the CPU is released.
    reg        chk_done, chk_ok, chk2_ok;
    reg [15:0] chk2_val;
    reg [15:0] probe0, probe1;      // words @0x000000 (expect 003F) and @0x110400 (expect 33CC)

    reg [23:0] recheck_ctr;
    // LANE3i: TWO PF fetch channels (A/B ping-pong). One-in-flight paid the
    // full CDC round trip per word (~420ns done-sync + issue gap) on top of
    // the ~280ns two-read CRAM service = ~875ns/word against a 1117ns budget;
    // any MO fetch pushed a line over and the deficit accumulated rightward
    // (build 39: perfect left column, double-struck right). Two in flight
    // overlaps the round trips - throughput becomes service-bound.
    reg        vg_reqA_last, vg_doneA_85;
    reg        vg_reqB_last, vg_doneB_85;
    reg        cpu_owner;
    reg        mo_owner = 1'b0;           // MO-SDRAM read in flight
    reg [1:0]  mo_sd_ch = 2'd0;           // which MO channel it serves
    reg [31:0] vg_dataA, vg_dataB;
    reg        cvg_ch;                    // channel served by the in-flight cvg op
    // LANE3o: MO got the same A/B ping-pong as PF - two fetches in flight
    // across the CDC (the serial channel starved late links: Jake invisible).
    // MOCHAN-4: FOUR channels. Two in flight left the engine bound by fetch
    // concurrency at the measured worst-case round trip (per-tile cost
    // max(8 blit, 31/2) = 15.5); four make the steady-state term max(8, 31/4)
    // = 8, i.e. blit-bound.
    reg [3:0]  mg_req_last, mg_done_85;
    reg [127:0] mg_data;                  // 4 x 32
    reg        cmg_ch;
    wire [3:0] mg_req_s;
    wire [3:0]  mo_gfx_req;
    wire [95:0] mo_gfx_addr;              // 4 x 24
    // SDSCHED-74: same-family crossings (7.159 -> 85.909, timed since the
    // '73 SDC grouping) - single capture FFs. The 3-stage done-return
    // chains cost ~400ns per fetched sprite row (~1/3 of the row budget).
    integer   mci;                        // MOCHAN-4 per-channel loop index
    reg [3:0] mg_req_s_q;
    always @(posedge clk_sdram) mg_req_s_q <= mo_gfx_req;
    assign mg_req_s = mg_req_s_q;
    wire [3:0] mg_done_s;
    reg  [3:0] mg_done_s_q;
    always @(posedge clk_sys_7159) mg_done_s_q <= mg_done_85;
    assign mg_done_s = mg_done_s_q;

    // ---- MOCHAN-4: REGISTERED MO ARBITRATION PRE-DECODE --------------------
    // This is the whole reason the channel count could be doubled without
    // growing the SDRAM grant condition, which is the tightest timing path in
    // the design AND is shared with both CPUs' read clients.
    //
    // Before: the grant tested
    //     (mgA_req_s != mgA_req_last || mgB_req_s != mgB_req_last)
    // - two XORs feeding an OR, in front of the eight-term AND chain that also
    // gates the CPU fastpath and CPU fetch arms. Four channels done the same
    // way would have made that four XORs feeding a 4-input OR, i.e. one more
    // level of logic on the shared path, and the address mux on rd_addr_q
    // would have grown from 2:1 to 4:1 on the same path.
    //
    // After: the pending test, the channel choice AND the address selection
    // are all computed one clock EARLIER and presented to the grant as plain
    // register outputs. The grant sees a single flop bit (mo_pend_q) where it
    // used to see XOR+OR, and rd_addr_q's MO leg is a register-to-register
    // path where it used to be a 2:1 mux. Combinational depth on the
    // CPU-shared grant therefore goes DOWN, not up, at four channels.
    //
    // Cost: one clk_sdram cycle (11.6ns) of extra arbitration latency per MO
    // fetch, against a round trip of ~1.1us. Fixed priority 0>1>2>3 keeps the
    // old "A before B" order.
    //
    // Safety of looking one cycle back: mg_req_last only ever CLEARS a pending
    // bit, and only in the grant arm, which also sets mo_owner - and the grant
    // requires !mo_owner, so no second grant can fire off the stale bit. Every
    // other transition only ADDS pending bits. So a channel that was pending
    // last cycle is still pending this cycle, and mo_naddr_q still holds its
    // address (the engine holds gfx_addr stable until the completion returns).
    wire [3:0] mg_pend_w = mg_req_s ^ mg_req_last;
    reg        mo_pend_q;
    reg [1:0]  mo_nch_q;
    reg [23:0] mo_naddr_q;
    always @(posedge clk_sdram) begin
        // gated by core_rstn_sd here (NOT in the reset-resync block below):
        // one always block per net. SDSCHED-75 resyncs mg_req_last under
        // reset; this keeps the registered pending bit from carrying a
        // one-cycle stale "pending" across the release as the engine zeroes
        // its request toggles.
        mo_pend_q  <= core_rstn_sd && (|mg_pend_w);
        mo_nch_q   <= mg_pend_w[0] ? 2'd0 : mg_pend_w[1] ? 2'd1
                    : mg_pend_w[2] ? 2'd2 : 2'd3;
        mo_naddr_q <= mg_pend_w[0] ? mo_gfx_addr[23:0]
                    : mg_pend_w[1] ? mo_gfx_addr[47:24]
                    : mg_pend_w[2] ? mo_gfx_addr[71:48]
                                   : mo_gfx_addr[95:72];
    end
    wire       vg_reqA_s, vg_reqB_s;
    reg        vg_reqA_px, vg_reqB_px;    // pixel-domain request toggles
    reg [23:0] vg_addrA_px, vg_addrB_px;  // stable while request in flight
    reg vg_reqA_s_q, vg_reqB_s_q;
    always @(posedge clk_sdram) begin
        vg_reqA_s_q <= vg_reqA_px;
        vg_reqB_s_q <= vg_reqB_px;
    end
    assign vg_reqA_s = vg_reqA_s_q;
    assign vg_reqB_s = vg_reqB_s_q;
    wire vg_doneA_s, vg_doneB_s;
    reg vg_doneA_s_q, vg_doneB_s_q;
    always @(posedge clk_sys_7159) begin
        vg_doneA_s_q <= vg_doneA_85;
        vg_doneB_s_q <= vg_doneB_85;
    end
    assign vg_doneA_s = vg_doneA_s_q;
    assign vg_doneB_s = vg_doneB_s_q;
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

always @(posedge clk_sdram) core_rstn_sd <= core_reset_n;

always @(posedge clk_sdram) begin
    // CRAM download mirror: ALWAYS active (the original placement inside
    // the 4'd10 steady-state arm meant it never ran during the download -
    // CRAM stayed virgin and reads returned constants: the checkerboard).
        // download-mirror: snoop SDRAM writes (gfx range), enqueue words
        cwr_snoop_d <= sd_wr_req;
        // LANE3f: enqueue/drain must share ONE counter update - the split
        // nonblocking writes collided on same-cycle enq+deq (last wins),
        // drifting cq_n into phantom-full skips and phantom-empty drains.
        cq_enq = (sd_wr_req && !cwr_snoop_d && sd_wr_addr >= 25'h110000 && cq_n <= 4'd6);
        if(cq_enq) begin
            cq_addr[cq_wr]      <= sd_wr_addr[22:1] - 22'h88000;
            cq_data[cq_wr]      <= sd_wr_data[31:16];
            cq_addr[cq_wr+3'd1] <= (sd_wr_addr[22:1] - 22'h88000) + 22'd1;
            cq_data[cq_wr+3'd1] <= sd_wr_data[15:0];
            cq_wr <= cq_wr + 3'd2;
        end
        // download-mirror drain (idle slots only)
        if(cq_n != 4'd0 && cvg_ph==2'd0 && cmg_ph==3'd0 && cst_ph==2'd0
           && !cram_busy && !cram_read_en && cwr_ph==2'd0) begin
            cram_addr     <= cq_addr[cq_rd];
            cram_din      <= cq_data[cq_rd];
            cram_write_en <= 1'b1;
            cwr_ph        <= 2'd1;
        end
        cq_deq = 1'b0;
        if(cwr_ph==2'd1) begin
            cram_write_en <= 1'b0;
            if(!cram_busy) begin
                cq_rd  <= cq_rd + 3'd1;
                cq_deq = 1'b1;
                cwr_ph <= 2'd0;
            end
        end
        cq_n <= cq_n + (cq_enq ? 4'd2 : 4'd0) - (cq_deq ? 4'd1 : 4'd0);

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
        // LANE3h: the missing half of the lane. cvg_ph existed but its FSM
        // was never written - PF gfx was STILL served from SDRAM, and the
        // LANE3c CPU-gate decoupling removed the mutual exclusion that had
        // kept the PF and CPU arms apart. Both could fire on the same clock
        // (both saw an idle bus), both wrote rd_addr_q, last-writer won, and
        // the PF channel captured data fetched from the CPU's address: the
        // flat tiles. Proof the fix belongs on CRAM: the mode-7 self-test
        // read back both gfx regions through this controller sum-exact
        // (A8DC/FF80 on hardware). PF now uses that identical handshake.
        // SDRAM belongs to the CPUs + scrubber alone; every CRAM start goes
        // through ONE strict-priority chain - drain > PF > MO > self-test -
        // so no two clients can ever collide by construction.
        // diagnostic (hold R2 / mode 6): consume video-fetch toggles WITHOUT
        // touching CRAM - isolates the gfx service from everything else
        if(vidkill_sd) begin
            if(vg_reqA_s != vg_reqA_last && cvg_ph==2'd0) begin
                vg_reqA_last <= vg_reqA_s; vg_dataA <= 32'd0; vg_doneA_85 <= ~vg_doneA_85;
            end
            if(vg_reqB_s != vg_reqB_last && cvg_ph==2'd0) begin
                vg_reqB_last <= vg_reqB_s; vg_dataB <= 32'd0; vg_doneB_85 <= ~vg_doneB_85;
            end
            // MOCHAN-4: same drain, four channels. This arm is exclusive with
            // the real MO grant below (that one requires !vidkill_sd), so
            // mg_req_last still has exactly one writer per cycle.
            if(cmg_ph==3'd0) begin
                for(mci = 0; mci < 4; mci = mci + 1) begin
                    if(mg_req_s[mci] != mg_req_last[mci]) begin
                        mg_req_last[mci]      <= mg_req_s[mci];
                        mg_data[mci*32 +: 32] <= 32'd0;
                        mg_done_85[mci]       <= ~mg_done_85[mci];
                    end
                end
            end
        end
        // unified CRAM read-start chain (drain owns cq_n!=0 cycles; reads
        // require cq_n==0 - write vs read starts are exclusive on cq_n)
        if(cvg_ph==2'd0 && cmg_ph==3'd0 && cst_ph==2'd0 && cwr_ph==2'd0
           && cq_n==4'd0 && !cram_busy && !cram_read_en && !cram_write_en) begin
            // mo-fair branch: ROUND-ROBIN between PF and MO when both pend.
            // PF always won before; tb_mob latency sweep proved MO starvation
            // (pixel writes 47490 @lat8 -> 35382 @lat31 = the sprite striping
            // seen in gameplay). PF tolerates sharing: it prefetches 2-4
            // cells ahead (prefd slider), MO has hard line deadlines.
            // MO-SDRAM branch: MO fetches moved to SDRAM (see chk_state 10);
            // CRAM now serves the playfield alone - no round-robin needed.
            if(!vidkill_sd && (vg_reqA_s != vg_reqA_last || vg_reqB_s != vg_reqB_last)) begin
                if(vg_reqA_s != vg_reqA_last) begin
                    vg_reqA_last <= vg_reqA_s;
                    cram_addr    <= vg_addrA_px[22:1] - 22'h88000;
                    cvg_ch       <= 1'b0;
                end else begin
                    vg_reqB_last <= vg_reqB_s;
                    cram_addr    <= vg_addrB_px[22:1] - 22'h88000;
                    cvg_ch       <= 1'b1;
                end
                cram_read_en <= 1'b1;
                cvg_ph       <= 2'd1;
                vgmg_last_mo <= 1'b0;
            end else if(cst_go && !cst_done) begin
                // LANE4m CRAM forensics: window A = the confetti STAIRS-sign
                // tiles (image 0x182E80+ = words 0x39740+), window B = a
                // known-good robot sprite (code 0x502A = words 0x582A0+).
                // Sums re-run every 64 frames: STABLE-WRONG sum A = written
                // wrong at download; CHURNING sum A = read instability.
                cram_addr    <= (cst_i < 9'd256)
                                ? (22'h39740 + {13'd0, cst_i})
                                : (22'h582A0 + {14'd0, cst_i[7:0]});
                cram_read_en <= 1'b1;
                cst_ph       <= 2'd1;
            end
        end
        // PF gfx from CRAM: two words per 32-bit request, {even, odd} to
        // match the SDRAM burst byte order the pixel side already expects
        if(cvg_ph==2'd1) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin cvg_hi <= cram_dout; cvg_ph <= 2'd2; end
        end
        if(cvg_ph==2'd2 && !cram_busy && !cram_read_en) begin
            // cram_addr still holds the first-read word (nothing else may
            // write it mid-transaction): |1 in place - no recompute from the
            // live cross-domain bus (v39 latched-address discipline; the
            // duplicated subtractor cones were a router congestion hotspot)
            cram_addr    <= cram_addr | 22'd1;
            cram_read_en <= 1'b1;
            cvg_ph       <= 2'd3;
        end
        if(cvg_ph==2'd3) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin
                if(cvg_ch) begin
                    vg_dataB    <= {cvg_hi, cram_dout};
                    vg_doneB_85 <= ~vg_doneB_85;
                end else begin
                    vg_dataA    <= {cvg_hi, cram_dout};
                    vg_doneA_85 <= ~vg_doneA_85;
                end
                cvg_ph     <= 2'd0;
            end
        end
        // MO gfx CRAM FSM removed - MO is served from SDRAM (mo-sdram
        // branch). cmg_ph is held at 0; CRAM belongs to PF + forensics.
        // CRAM self-test reader (lowest priority; permanent regression fixture)
        if(cst_ph==2'd1) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin
                if(cst_i < 9'd256) cst_sum0 <= cst_sum0 + cram_dout;
                else               cst_sum1 <= cst_sum1 + cram_dout;
                cst_i  <= cst_i + 9'd1;
                cst_ph <= 2'd0;
                if(cst_i == 9'd511) cst_done <= 1'b1;
            end
        end
        // trigger once the machine reaches steady state (download over)
        if(chk_state == 4'd10) cst_go <= 1'b1;
        // LANE4m: continuous re-sum every 64 frames
        if(cst_done && vblank_w && !vb_cst_d && frame_ctr[5:0] == 6'd0) begin
            cst_done <= 1'b0; cst_i <= 9'd0;
            cst_sum0 <= 16'd0; cst_sum1 <= 16'd0;
        end
        vb_cst_d <= vblank_w;
        // SDSCHED-88 fastpath fills: the highest-priority read clients. The
        // two grant arms are ONE if/else chain (v14-v19 lesson: two arms
        // firing on one clock = last-writer-wins address corruption), and
        // every other read client below excludes fp wants/owners.
        if((fpv_want || fpe_want)
           && !sd_rd_req && !sd_rd_ack && !cpu_owner && !mo_owner
           && !fpv_owner && !fpe_owner) begin
            if(fpv_want && (!fpe_want || !fp_last_v)) begin
                fpv_tag   <= fpv_addr_s;
                fpv_valid <= 0;
                rd_addr_q <= {1'b0, fpv_addr_s};
                rd_pre_q  <= 1;                 // CPU: full armor
                sd_rd_req <= 1;
                fpv_owner <= 1;
                fp_last_v <= 1'b1;
            end else begin
                fpe_tag   <= fpe_addr_s;
                fpe_valid <= 0;
                rd_addr_q <= {1'b0, fpe_addr_s};
                rd_pre_q  <= 1;
                sd_rd_req <= 1;
                fpe_owner <= 1;
                fp_last_v <= 1'b0;
            end
        end
        if(fpv_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 0;
            fpv_owner <= 0;
            fpv_data  <= sd_rd_data[31:16];
            fpv_vpre  <= 1;                     // valid follows next clock
        end
        if(fpe_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 0;
            fpe_owner <= 0;
            fpe_data  <= sd_rd_data[31:16];
            fpe_vpre  <= 1;
        end
        if(fpv_vpre) begin fpv_valid <= 1; fpv_vpre <= 0; end
        if(fpe_vpre) begin fpe_valid <= 1; fpe_vpre <= 0; end
        // CPU fetch service. MUST also yield to a PENDING MO request
        // (mg_req_s != mg_req_last), not just an in-flight one: without that
        // check both gates fire on the same edge, one read goes out with the
        // MO address, and the CPU is served sprite pixels as instructions.
        // (Root cause of the v14-v19 per-boot corruption: phantom RAM-test
        // failures, wrong palettes, duplicated chars in ROM-sourced text.)
        // CRAM lane: video no longer touches SDRAM - the CPU service
        // must NOT wait on video-channel state (a stuck CRAM path was
        // starving CPU fetches -> extra CPU death -> watchdog boot loop)
        // (SDSCHED-88: with FASTPATH_EN this legacy client only fires on the
        // escape_core fast-watchdog fallback; it stays fully wired for
        // FASTPATH_EN=0 builds and as the never-wedge escape hatch.)
        begin
            if(core_rom_req_s && !core_rom_ack_85 && !sd_rd_req && !sd_rd_ack
               && !fpv_owner && !fpe_owner && !fpv_want && !fpe_want) begin
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
            core_rom_par4 <= {^sd_rd_data[31:24], ^sd_rd_data[23:16],
                              ^sd_rd_data[15:8],  ^sd_rd_data[7:0]};
            core_rom_ack_85 <= 1;
        end
        if(!core_rom_req_s) core_rom_ack_85 <= 0;
        // MO-SDRAM: sprite tile-row fetches served here. The graphics live
        // in the loaded image (0x120000+) so the request address IS the
        // SDRAM byte address; one burst-of-2 = the {even,odd} word pair the
        // CRAM path used to deliver. CPUs always outrank MO: an MO grant
        // requires no pending/in-flight CPU work, and one MO read (~10 clks
        // @85.9MHz) is far shorter than a CPU bus cycle, so worst-case CPU
        // latency grows by well under one 7.16MHz cycle.
        // (SDSCHED-88: MO stays the LOWEST-priority SDRAM read client, now
        // also below both CPU fastpath fills. A fill is ~13 clks and each
        // CPU issues at most one per 48-clk bus cycle, so MO keeps >=40% of
        // the bus even with both CPUs streaming fetches.)
        // MOCHAN-4: the ONLY change to this condition is that the two-channel
        // XOR/OR pending test became the single registered bit mo_pend_q. Every
        // CPU-first term is byte-for-byte what it was: MO still yields to a
        // pending CPU fetch (core_rom_req_s && !core_rom_ack_85), to either
        // fastpath want or owner, and to any read already in flight. MO remains
        // the LOWEST-priority SDRAM read client. (v14-v19: two grant arms
        // firing on one clock is last-writer-wins address corruption - this is
        // still one if, one arm.)
        if(!vidkill_sd && mo_pend_q
           && !(core_rom_req_s && !core_rom_ack_85)
           && !sd_rd_req && !sd_rd_ack && !cpu_owner && !mo_owner
           && !fpv_owner && !fpe_owner && !fpv_want && !fpe_want) begin
            mg_req_last[mo_nch_q] <= mg_req_s[mo_nch_q];
            rd_addr_q <= {1'b0, mo_naddr_q};
            mo_sd_ch  <= mo_nch_q;
            rd_pre_q  <= 1;                     // same armor as CPU reads
            sd_rd_req <= 1;
            mo_owner  <= 1;
        end
        if(mo_owner && sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 0;
            mo_owner  <= 0;
            mg_data[mo_sd_ch*32 +: 32] <= sd_rd_data;
            mg_done_85[mo_sd_ch]       <= ~mg_done_85[mo_sd_ch];
        end
        // LANE3i2: the READ-INTEGRITY SCRUBBER is RETIRED. It answered its
        // questions (v23-v29 exoneration arc; final verdict 0100 = full pass,
        // zero errors during LANE3g) and the routing ceiling now blocks the
        // lane verdict - the roving FSM + blktab BRAM + guaranteed-slot
        // arbitration buy back real interconnect. chk_ok/chk2_ok strip
        // probes remain as the SDRAM canary. Restore from git if needed.
        // while failing, re-probe + re-DMA every ~0.6s
        recheck_ctr <= recheck_ctr + 24'd1;
        if(!chk2_ok && recheck_ctr == 24'hFFFFFF && !sd_rd_req && !sd_rd_ack
           && !core_rom_ack_85) begin
            chk_state <= 4'd2;
        end
    end
    default: chk_state <= 4'd10;
    endcase
    // SDSCHED-75: fetch-tracker resync under core reset. The mob zeroes its
    // req toggles on reset (menu soft-reset, rescue reboot) but these
    // trackers kept stale values - an inverted pair = one phantom serve per
    // channel per reset. Track the live toggles while reset is held.
    if(!core_rstn_sd) begin
        mg_req_last <= mg_req_s;
        // MOCHAN-4: mo_pend_q is held low under reset too, but that has to be
        // done in the pre-decode's OWN always block - it is a separate block
        // and Quartus rejects two blocks driving one net ("Can't resolve
        // multiple constant drivers"). iverilog accepts it silently, so this
        // is not something the simulation benches can catch.
        vg_reqA_last <= vg_reqA_s;
        vg_reqB_last <= vg_reqB_s;
        // SDSCHED-88: fastpath caches die with the core - a re-download
        // changes ROM content under a valid tag otherwise
        fpv_valid <= 0; fpe_valid <= 0;
        fpv_vpre  <= 0; fpe_vpre  <= 0;
    end
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
        wdog_exp_d <= wdog_expired | e_dead | mbox_dead;
        if(!reset_n) begin
            wdog_rst_ctr <= 23'd0; wdog_rst_cnt <= 8'd0;
        end else begin
            // WDIS: authentic watchdog-disable (debug). If expiry latches
            // while disabled, re-enable takes effect after the next core reset.
            // LANE4i: a dead extra CPU (frozen world) reboots the core the
            // same way a watchdog timeout does - counted in wdog_rst_cnt
            // LANE4r: a wedged 5A5A/4321 mailbox handshake ('68 freeze:
            // both CPUs alive, logic deadlocked) reboots the core too
            if((wdog_expired || e_dead || mbox_dead) && !wdog_exp_d && !wdis_s) begin
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

    // ee_ready_c: the EEPROM has been restored from the save slot (or skipped,
    // when no save file was loaded). Bounded - ee_save reaches it within ~290 us
    // of dataslot_allcomplete, unconditionally - so it can never brick a boot,
    // but it does guarantee the 68000s never read a half-restored EEPROM.
    // It latches once and survives watchdog/soft resets, which must not re-run
    // the restore over scores earned since boot.
    wire core_reset_n = reset_n & dataslot_allcomplete_s & sdram_init_done_s & chk_done_s
                        & ee_ready_c & ~soft_rst_s & ~wdog_rst;

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
    always @(posedge clk_sys_7159) begin
    end
    // LANE3y: R cycles FOUR debug pages, every click meaningful (the old
    // 0-7 counter had two dead duplicates and put destructive vidkill in
    // the walk path - it faked a broken floor on the 2026-08-19 video):
    //   0 JSA (resp/coin+credits) | 1 extra-CPU (PC/mbox)
    //   2 main-CPU (PC/wr-region) | 3 engine (actor head/mode bytes)
    // vidkill stays on R2 HOLD only; CRAM sums retired (sim benches cover).
    reg [1:0] dbgmode = 2'd0;
    // SDSCHED-85 trace view: L2 toggles (demotes the alpha-hide bringup
    // tool); R steps backward through entries while active.
    reg       m_trace = 1'b0;
    reg       l2_d = 1'b0;
    reg [6:0] tr_back = 7'd0;      // steps back from newest entry
    reg       rbtn_d  = 1'b0;
    always @(posedge clk_sys_7159) begin
        rbtn_d <= cont1_key[9];
        l2_d <= cont1_key[10];
        if(cont1_key[10] & ~l2_d) begin
            m_trace <= ~m_trace;
            tr_back <= 7'd0;
        end
        if(cont1_key[9] & ~rbtn_d) begin
            if(m_trace) tr_back <= tr_back + 7'd1;
            else        dbgmode <= dbgmode + 2'd1;
        end
    end
    // LANE3h3: modes 1-5 RETIRED (answered questions - PF map, input probe,
    // fetch probe, MO-kill, MO-priority). The design sits at the routing
    // ceiling (constant hotspot X33_Y23-X43_Y33: 63% peak on '37', 74% on
    // failed '38' attempts); these probes held wide muxes + counters alive
    // through the render path. Tied off so Quartus prunes them. Modes kept:
    // 0 normal | 6 vidkill | 7 CRAM self-test sums.
    wire m_pfmap   = 1'b0;
    // LANE3k: mode 2 returns as the SECOND-PROCESSOR window - the extra 68k
    // draws the in-game world; when gameplay fails to populate, this names
    // where it is: field1 = extra-CPU PC (frame-latched; frozen = wedged/
    // quiesced, churning = alive), field3 = last mailbox response word.
    wire m_eprobe  = (dbgmode == 2'd1);
    // LANE3m: mode 3 = MAIN-CPU window (field1 = video-CPU PC frame-latched,
    // field3 = last main data-write addr [23:8]) - names where the game
    // state machine sits when the world is drawn but objects never move.
    wire m_vprobe  = (dbgmode == 2'd2);
    // LANE3r: mode 4 = ENGINE window. field1 = actor-table head word 3F5000
    // (MAME truth: 0000 on attract art pages, 0x12xx when the demo/game has
    // spawned actors); field3 = {mode byte 3F7F16, mode byte 3F7F23} (MAME:
    // 60/18 on art pages, 54/2a during demo play).
    wire m_gprobe  = (dbgmode == 2'd3);
    wire m_pfprobe = 1'b0;
    wire m_mopri_px     = 1'b0;
    wire m_mokill       = 1'b0;
    wire m_mopri_sd;
synch_3 s_mopri(m_mopri_px, m_mopri_sd, clk_sdram);
    wire m_vidkill_px   = 1'b0;   // LANE3y: cycle slot removed; R2 hold remains
    wire m_moprobe      = 1'b0;   // LANE3y: CRAM sums retired (muxes prune)
    reg [7:0] mgreq_cnt, mopen_cnt;
    reg [15:0] moprobe_fr;
    reg [15:0] cst0_px, cst1_px, cst0_m, cst1_m;
    reg mgreq_d2;
    always @(posedge clk_sys_7159) begin
        mgreq_d2 <= mo_gfx_req[0];
        if(mo_gfx_req[0] != mgreq_d2) mgreq_cnt <= mgreq_cnt + 8'd1;
        if(mo_valid && mo_pen[3:0] != 4'h0) mopen_cnt <= mopen_cnt + 8'd1;
        cst0_m <= cst_sum0; cst0_px <= cst0_m;
        cst1_m <= cst_sum1; cst1_px <= cst1_m;
        if(vblank_w && !vb_hud_d) begin
            moprobe_fr <= {mgreq_cnt, mopen_cnt};
            mgreq_cnt  <= 8'd0;
            mopen_cnt  <= 8'd0;
        end
    end
    // per-frame display latches for fast-changing HUD values
    reg [15:0] epc_fr, mbox_fr, vpc_fr, wrhi_fr, engine_fr, gmode_fr;
    reg [15:0] vcyc_fr, ecyc_fr; // LANE4s: bus cycles/frame per CPU (speed meter)
    reg        vb_hud_d;
    reg [15:0] jsapc_fr, jsalink_fr;
    reg [15:0] coincred_fr;
    always @(posedge clk_sys_7159) begin
        vb_hud_d <= vblank_w;
        if(vblank_w && !vb_hud_d) begin
            epc_fr    <= dbg_epc;
            vpc_fr    <= dbg_pc;
            wrhi_fr   <= dbg_wrhi;
            // SDSCHED-83: once an impostor is caught, this slot shows the
            // PREDECESSOR read address (replay-source confirmation)
            mbox_fr   <= ewrong_seen ? ewrong_prev_keep
                                     : {dbg_erestart, dbg_mbox_cmd[7:0]};
            vcyc_fr   <= dbg_vcyc;
            ecyc_fr   <= dbg_ecyc;
            engine_fr <= dbg_engine;
            gmode_fr  <= dbg_awr;   // SDSCHED-75: was dbg_mode (static, long proven)
            jsapc_fr  <= dbg_jsa_pc;
            jsalink_fr<= dbg_jsa_link;
            coincred_fr <= dbg_coin_cred;
        end
    end
    // LANE4a page-2 forensics fields (see mux comment below)
    wire [15:0] pg2_f1 = (crash_pc != 16'd0) ? crash_pc : vpc_fr;
    // LANE4m: page-2 idle fields were the CRAM sums (sign / robot).
    // TASLOCK-102: those retired - they have read E789/2D55 through every
    // freeze since the '73 session, i.e. long-since proven, and the sim
    // benches cover the CRAM path. Page 2's two idle fields now carry the
    // TAS-interlock evidence instead:
    //   group 2 = {writes blocked, bus cycles blocked}, 8 bits each,
    //             saturating. NON-ZERO = the interlock really engaged; the
    //             left pair non-zero = a WRITE was held off, which is the
    //             swallowed-release case that wedged the machine.
    //   group 3 = byte address of the FIRST collision (0000 = never).
    //             CCCC / CC00 / CCC6-CCCD are the inter-CPU mutex bytes.
    // The fault latches are untouched: a non-zero crash_pc still overrides
    // both fields exactly as before, and trace view (L2) is not involved.
    wire [15:0] pg2_f2 = (crash_pc != 16'd0) ? crash_data : dbg_tas_cnt;
    wire [15:0] pg2_f3 = (crash_pc != 16'd0) ? {dbg_vec[7:0], wdog_rst_cnt} : dbg_tas_addr;

    // LANE4f page-1 forensics: live extra-CPU PC until its first genuine
    // exception, then LOCK the faulting PC; field2 shows the last mailbox
    // command until a fault, then the opcode word the extra CPU received
    wire        e_faulted = (dbg_ecrash_pc != 16'd0);
    // LANE4s: while the extra is executing the data table (the '69 wedge)
    // show WHERE IT JUMPED FROM instead of the meaningless in-table PC
    // SDSCHED-76: an impostor 0x80E word outranks everything - it IS the
    // root cause, caught in the act.
    wire [15:0] pg1_f1 = ewrong_seen ? ewrong_keep
                       : e_faulted ? dbg_ecrash_pc : (dbg_eintab ? dbg_ewild : epc_fr);
    // field2 pre-fault: {extra restart count, last mbox cmd low byte} -
    // boot leaves a small known restart count; +1 at the freeze moment
    // confirms the mid-game-restart hypothesis in one photo
    // LANE4r: non-fault path now shows the mailbox ledger {5A5A cmds, 4321
    // acks} - equal at freeze = video missed the ack, cmds ahead = extra
    // never answered. (erestart+mcmd moved to the old resp slot.)
    wire [15:0] pg1_f2 = e_faulted ? dbg_ecrash_data : dbg_mbox_cnts;
    // LANE4c: free-running FRAME COUNTER (vblank edges since APF reset;
    // deliberately NOT cleared by watchdog/core resets so reboot loops can
    // be timed off video frames). Shown as page-3 field2.
    reg [15:0] frame_ctr = 16'd0;
    always @(posedge clk_sys_7159) begin
        if(!reset_n) frame_ctr <= 16'd0;
        else if(vblank_w && !vb_hud_d) frame_ctr <= frame_ctr + 16'd1;
    end
    reg  [3:0] hex_digit;
    always @(posedge clk_sys_7159)
        trace_idx <= trace_wp - 7'd1 - tr_back;
    wire [23:0] tr_addr = {trace_q[38:16], 1'b0};
    wire [15:0] tr_data = trace_q[15:0];
    wire [3:0]  tr_flag = trace_q[42:39];        // {rw, fc[2:0]}
    wire [7:0]  tr_step = {1'b0, tr_back} ^ {8{1'b0}};

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
        // LANE4a page 2 = main-CPU FORENSICS: field1 shows the live PC until
        // the first fault, then locks the faulting address (survives watchdog
        // resets); field2 = the opcode word the CPU received at the fault;
        // field3 = {vector offset, watchdog reset count}. MAME truth: real
        // attract NEVER resets after boot (extra released once at T=11s,
        // runs forever) - our ~35s reboot loop = a main-CPU death, and this
        // page names it.
        4'd0:  hex_digit = m_trace ? tr_step[7:4] : m_moprobe ? cst0_px[15:12] : m_eprobe ? pg1_f1[15:12] : m_vprobe ? pg2_f1[15:12] : m_gprobe ? engine_fr[15:12] : vcyc_fr[15:12];
        4'd1:  hex_digit = m_trace ? tr_step[3:0] : m_moprobe ? cst0_px[11:8]  : m_eprobe ? pg1_f1[11:8]  : m_vprobe ? pg2_f1[11:8]  : m_gprobe ? engine_fr[11:8]  : vcyc_fr[11:8];
        4'd2:  hex_digit = m_trace ? (trace_frozen ? 4'hF : 4'h0) : m_moprobe ? cst0_px[7:4]   : m_eprobe ? pg1_f1[7:4]   : m_vprobe ? pg2_f1[7:4]   : m_gprobe ? engine_fr[7:4]   : vcyc_fr[7:4];
        4'd3:  hex_digit = m_trace ? tr_addr[23:20] : m_moprobe ? cst0_px[3:0]   : m_eprobe ? pg1_f1[3:0]   : m_vprobe ? pg2_f1[3:0]   : m_gprobe ? engine_fr[3:0]   : vcyc_fr[3:0];
        // middle field: retired with the scrubber (LANE3i2) - shows 0000.
        // BOTH burst words against download truth. err=00 with passes
        // climbing = SDRAM content and read path proven good, so the pf
        // corruption is in what the CPUs WRITE (game logic / extra CPU);
        // err climbing = the read path is still lying to us.
        // field2: page 1 = last mailbox COMMAND (LANE4f - the freeze specimen
        // showed the extra CPU derailed into its 0xB00 march band mid-game;
        // this names the command that sent it); page 2 = fault opcode;
        // page 3 = FRAME COUNTER (LANE4c)
        // page 0 field2 = LANE4l max extra bus-cycle length: normal cycles
        // are tiny (< 0x0040); a stuck write shows FFFF = the invisible
        // freeze mode (bus active, rescue can't see it)
        4'd5:  hex_digit = m_trace ? tr_addr[19:16] : m_vprobe ? pg2_f2[15:12] : m_gprobe ? frame_ctr[15:12] : m_eprobe ? pg1_f2[15:12] : ecyc_fr[15:12];
        4'd6:  hex_digit = m_trace ? tr_addr[15:12] : m_vprobe ? pg2_f2[11:8]  : m_gprobe ? frame_ctr[11:8]  : m_eprobe ? pg1_f2[11:8]  : ecyc_fr[11:8];
        4'd7:  hex_digit = m_trace ? tr_addr[11:8] : m_vprobe ? pg2_f2[7:4]   : m_gprobe ? frame_ctr[7:4]   : m_eprobe ? pg1_f2[7:4]   : ecyc_fr[7:4];
        4'd8:  hex_digit = m_trace ? tr_addr[7:4] : m_vprobe ? pg2_f2[3:0]   : m_gprobe ? frame_ctr[3:0]   : m_eprobe ? pg1_f2[3:0]   : ecyc_fr[3:0];
        // field 3 (v61): {coin-line edge count, game credit count $3F7F55}.
        // Edges ticking without Select presses = input line glitching.
        // (replaces the v59 shadow checksum, verified 8318 on device)
        4'd10: hex_digit = m_trace ? tr_data[15:12] : m_moprobe ? cst1_px[15:12] : m_eprobe ? mbox_fr[15:12] : m_vprobe ? pg2_f3[15:12] : m_gprobe ? gmode_fr[15:12] : coincred_fr[15:12];
        4'd11: hex_digit = m_trace ? tr_data[11:8] : m_moprobe ? cst1_px[11:8]  : m_eprobe ? mbox_fr[11:8]  : m_vprobe ? pg2_f3[11:8]  : m_gprobe ? gmode_fr[11:8]  : coincred_fr[11:8];
        4'd12: hex_digit = m_trace ? tr_data[7:4] : m_moprobe ? cst1_px[7:4]   : m_eprobe ? mbox_fr[7:4]   : m_vprobe ? pg2_f3[7:4]   : m_gprobe ? gmode_fr[7:4]   : coincred_fr[7:4];
        4'd13: hex_digit = m_trace ? tr_data[3:0] : m_moprobe ? cst1_px[3:0]   : m_eprobe ? mbox_fr[3:0]   : m_vprobe ? pg2_f3[3:0]   : m_gprobe ? gmode_fr[3:0]   : coincred_fr[3:0];
        // LANE4c: slot 14 (the gap) shows the crash SOURCE digit on page 2
        // (0=BRAM 1=prefetch 2=cache 3=fresh-SDRAM) - names which serve
        // path delivered the wrong opcode word
        4'd14: hex_digit = m_trace ? tr_addr[3:0] : {2'b00, crash_src};
        4'd15: hex_digit = m_trace ? tr_flag : {2'b00, dbgmode};
        default: hex_digit = 4'h0;
        endcase
    end
    // LANE3t: slot 15 = the DEBUG MODE digit, always shown at the row's
    // right end so photos are self-labeling (slot 14 stays blank as a gap)
    // (LANE3v: the '46 blue-bar bug was `slot < 4'd16` - the 4-bit literal
    // truncates 16 to 0, making the whole term constant-false: no digits)
    wire hex_slot_on = (slot!=4'd4 && slot!=4'd9 && (slot!=4'd14 || (m_vprobe && crash_pc != 16'd0)));
    wire [3:0] hex_row = hexfont(hex_digit, gy);
    wire hex_px = hex_slot_on && hex_row[2'd3 - gx];

    // ---------------- on-device build version (diag strip, right of bit row)
    // BUMP EVERY RELEASE and verify on-screen digits match the packaged zip:
    // guards against flashing/labeling control issues.
    localparam [15:0] BUILD_ID = 16'h3104;   // MO 4-channel fetch + 3-deep prefetch queue - screen shows '04'
    // x264..328: fully inside the 336-wide viewport (x300+ was clipped on device)
    wire [8:0] vx0      = visible_x - 9'd264;
    wire       ver_on   = (visible_x >= 'd264) && (visible_x < 'd328);
    wire [1:0] ver_slot = vx0[5:4];
    reg  [3:0] ver_digit;
    always @(*) case(ver_slot)
        2'd0: ver_digit = {2'b00, dbgmode}; 2'd1: ver_digit = BUILD_ID[15:12];
        2'd2: ver_digit = BUILD_ID[7:4];   default: ver_digit = BUILD_ID[3:0];
    endcase
    wire [2:0] ver_gy  = visible_y[2:0] - 3'd4;      // y228..233 -> rows 0..5
    wire [3:0] ver_row = hexfont(ver_digit, ver_gy);
    wire       ver_px  = (vx0[3]==1'b0) && ver_row[2'd3 - vx0[2:1]];
    wire in_hexrow = (visible_y >= 'd100) && (visible_y < 'd124) && (visible_x >= 'd44) && (visible_x < 'd300);

    // ---------------- playfield pipeline (pixel domain)
    // Prefetch 2 cells ahead: map lookup at phase 0, SDRAM gfx request at phase 3
    // (chunky 4bpp row = 2 words via the priority video channel), show via
    // fetch->show buffering at cell boundaries.
    reg  [11:0] pf_vaddr;
    wire [15:0] pf_vdata, pfx_vdata;
    wire [8:0]  xscroll, yscroll;

    wire [8:0] pf_y   = visible_y[8:0] + yscroll;           // scrolled row (mod 512)
    // LANE3p: world X alignment - sim-proven correct at +32 (map col lookup
    // only; fetch timing untouched). Menu slider fine-tunes: +16+vpshift.
    wire [8:0] pf_x2  = vis_x[8:0] + 9'd16 + {4'd0, vpshift_s} + xscroll;   // v72: fixed 3 ahead again -
                                                        // the runtime depth mux sent
                                                        // the fitter into a 90-minute
                                                        // spiral twice; slider deferred
    reg  [4:0] pfcol_q0, pfcol_q1, pfcol_q2, pfcol_q3, pfcol_show;  // {flip, color[3:0]}
    reg  [31:0] pf_next;      // SDSCHED-84: the FOLLOWING cell's row word
    reg  [4:0]  pfcol_next;   // ...and its attributes (fine-scroll window)
    reg  [3:0] pfcode_q0, pfcode_q1, pfcode_q2, pfcode_q3, pfcode_show; // v66 map debug
    // LANE3i: two fetches in flight (A/B ping-pong) - see channel decls at
    // the sdram-domain end. inflA/inflB = per-channel outstanding flags.
    reg        inflA = 1'b0, inflB = 1'b0;
    reg  [31:0] pf_fetch, pf_show;
    // v81b: SLOT-ADDRESSED RING replaces the shift pipe. A late completion
    // in the shift design landed in the NEXT cell's slot - the alternating
    // correct/wrong columns ('scrunch') seen when sprite fetches interleave.
    // Each fetch now delivers into the slot for ITS OWN cell whenever it
    // completes; rp re-syncs to wp at every line start (-4 = 0 mod 4).
    reg  [31:0] pfring0, pfring1, pfring2, pfring3;
    reg  [1:0]  pf_wp, pf_inflA, pf_inflB, pf_rp;
    // v84: request queue decouples issue cadence from channel latency.
    // The old unconditional toggle CANCELLED an unserved request when the
    // next cell's phase arrived (two toggles = no net change) - each burst
    // of MO/CPU/scrub traffic vaporized a fetch = trailing ghost columns.
    reg  [23:0] pfq_addr0, pfq_addr1, pfq_addr2, pfq_addr3;
    reg  [1:0]  pfq_slot0, pfq_slot1, pfq_slot2, pfq_slot3;
    reg  [2:0]  pfq_count;
    reg  [1:0]  pfq_wr, pfq_rd;
    reg  vg_doneA_last, vg_doneB_last;

    always @(posedge clk_sys_7159) begin
        case(vis_x[2:0])
            3'd0: begin
                // LANE3j: the pf map is COLUMN-MAJOR scanned (MAME SCAN_COLS
                // semantics; proven empirically - rendering the live MAME map
                // dump with idx=col*64+row reproduces the attract art pixel-
                // exact, row-major produces the on-device diagonal hash).
                // Our row-major read transposed every map lookup since v13:
                // symmetric tiles (borders/pillars) hid it for 90+ builds.
                pf_vaddr <= {pf_x2[8:3], pf_y[8:3]};        // map col*64 + row
                // cell boundary: advance pipelines
                // show the slot for THIS cell; a still-pending fetch shows
                // that slot's previous-line row (localized, non-spreading)
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
            end
            3'd7: begin
                // LANE3k: show-registers load one pixel EARLY (phase 7) so
                // they are fresh when pixel 0 samples them. Loading at phase
                // 0 left pixel 0 rendering the PREVIOUS cell's word - the
                // 1px vertical tears at every cell boundary in detailed art
                // (proven in the real-data art sim: 100% of mismatches were
                // pixel-in-cell 0 showing the left cell's first pixel).
                case(pf_rp)
                    2'd0: pf_show <= pfring0;  2'd1: pf_show <= pfring1;
                    2'd2: pf_show <= pfring2;  default: pf_show <= pfring3;
                endcase
                // SDSCHED-84: also stage the FOLLOWING cell - with a nonzero
                // horizontal fine scroll the last (xscroll&7) pixels of each
                // 8px window belong to the next tile over.
                case(pf_rp + 2'd1)
                    2'd0: pf_next <= pfring0;  2'd1: pf_next <= pfring1;
                    2'd2: pf_next <= pfring2;  default: pf_next <= pfring3;
                endcase
                pf_rp <= pf_rp + 2'd1;
                pfcol_show <= pfcol_q3;
                pfcol_next <= pfcol_q2;
                pfcode_show<= pfcode_q3;
            end
            default: ;
        endcase
        // completions deliver into each in-flight request's own slot; the
        // two channels are independent (slot tags differ for consecutive
        // fetches, so same-cycle delivery never collides on a ring slot)
        vg_doneA_last <= vg_doneA_s;
        if(vg_doneA_s != vg_doneA_last) begin
            case(pf_inflA)
                2'd0: pfring0 <= vg_dataA;  2'd1: pfring1 <= vg_dataA;
                2'd2: pfring2 <= vg_dataA;  default: pfring3 <= vg_dataA;
            endcase
            inflA <= 1'b0;
        end
        vg_doneB_last <= vg_doneB_s;
        if(vg_doneB_s != vg_doneB_last) begin
            case(pf_inflB)
                2'd0: pfring0 <= vg_dataB;  2'd1: pfring1 <= vg_dataB;
                2'd2: pfring2 <= vg_dataB;  default: pfring3 <= vg_dataB;
            endcase
            inflB <= 1'b0;
        end
        // issue side: drain the queue into whichever channel is free (one
        // issue per pixel clock; the old wait-for-MO gate is gone - the
        // sdram-domain priority chain arbitrates PF vs MO now)
        if(pfq_count != 3'd0) begin
            if(!inflA && !(vg_doneA_s != vg_doneA_last)) begin
                case(pfq_rd)
                    2'd0: begin vg_addrA_px <= pfq_addr0; pf_inflA <= pfq_slot0; end
                    2'd1: begin vg_addrA_px <= pfq_addr1; pf_inflA <= pfq_slot1; end
                    2'd2: begin vg_addrA_px <= pfq_addr2; pf_inflA <= pfq_slot2; end
                    default: begin vg_addrA_px <= pfq_addr3; pf_inflA <= pfq_slot3; end
                endcase
                vg_reqA_px <= ~vg_reqA_px;
                inflA      <= 1'b1;
                pfq_rd     <= pfq_rd + 2'd1;
                pfq_count  <= pfq_count - 3'd1;
            end else if(!inflB && !(vg_doneB_s != vg_doneB_last)) begin
                case(pfq_rd)
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
        // line-start re-sync (lead 4 = 0 mod 4) + queue flush
        if(x_count == 10'd0) begin
            pf_rp <= pf_wp;
            pfq_count <= 3'd0; pfq_rd <= pfq_wr;
        end
    end

    // pixel extraction: chunky nibbles px0..px7 across the 32-bit row.
    // SDSCHED-84 HORIZONTAL FINE SCROLL: the pixel index is the SCROLLED
    // fine X (pf_x2[2:0]), not raw screen X - the coarse column already
    // came from pf_x2[8:3], but the sub-tile phase was dropped, quantizing
    // all horizontal motion to 8px tile lurches (device 60fps capture:
    // dx = 0,0,...,+8 vs MAME's smooth +-1..3; vertical was always fine
    // because pf_y feeds both lookup and row). When the fine phase wraps
    // (pf_x2[2:0] < visible_x[2:0]) the pixel lives in the NEXT cell.
    wire        pf_cross = pf_x2[2:0] < visible_x[2:0];
    wire [31:0] pf_word  = pf_cross ? pf_next    : pf_show;
    wire [4:0]  pf_att   = pf_cross ? pfcol_next : pfcol_show;
    wire [2:0] pf_n   = pf_att[4] ? (3'd7 - pf_x2[2:0]) : pf_x2[2:0];
    reg  [3:0] pf_pix;
    always @(*) begin
        if(m_pfmap) begin
            pf_pix = pfcode_show;    // v66 map-debug: flat color per tile code
        end else
        case(pf_n)
            3'd0: pf_pix = pf_word[31:28]; 3'd1: pf_pix = pf_word[27:24];
            3'd2: pf_pix = pf_word[23:20]; 3'd3: pf_pix = pf_word[19:16];
            3'd4: pf_pix = pf_word[15:12]; 3'd5: pf_pix = pf_word[11:8];
            3'd6: pf_pix = pf_word[7:4];   default: pf_pix = pf_word[3:0];
        endcase
    end

    // ---------------- motion objects
    wire [11:0] mo_vaddr;
    wire [15:0] mo_vdata;
    wire [6:0]  cfg_vaddr;
    wire [15:0] cfg_vdata;
    wire [7:0]  mo_pen;
    wire [1:0]  mo_prio;                // MOPRI-1: MPR1:MPR0 of the owning sprite
    wire        mo_valid_raw;
    wire        mo_valid = mo_valid_raw & ~m_mokill;
    wire        mo_stain_s_raw, mo_stain_e_raw;      // MOSTAIN-1
    wire        mo_stain_s = mo_stain_s_raw & ~m_mokill;
    wire        mo_stain_e = mo_stain_e_raw & ~m_mokill;

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
    .disp_prio( mo_prio ),
    .disp_valid( mo_valid_raw ),
    .disp_stain_s( mo_stain_s_raw ),
    .disp_stain_e( mo_stain_e_raw )
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

    // MOPRI-1: the real motion-object / playfield priority comparator replaces
    // the old fixed alpha > MO > playfield ladder (robots drew in front of
    // scenery that should occlude them). escape_prio.v holds the transcribed
    // GAL equations; the playfield priority bits PFX5:PFX4 are pf_att[1:0] and
    // PFX3 is pf_pix[3] - see docs/mo_priority.md for the derivation.
    // The alpha layer still wins outright: the reference draws it AFTER the
    // MO/PF merge, so it sits on top of whatever the comparator chose.
    wire        pr_mo_win, pr_shade, pr_m7, pr_pfm, pr_forcemc0;
    wire [10:0] pr_pen;
escape_prio uprio (
    .mo_valid ( mo_show ),
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
    // MOSTAIN-1: the SECOND motion-object pass (atarimo apply_stain), which the
    // reference runs over the FINISHED picture - after the MO/PF merge AND after
    // the alpha tilemap - to OR 0x400 into every pixel a "special" (MPR2) sprite
    // covers. That 0x400 is colour-RAM bit 10, the top half of the 2048-entry
    // colour RAM this core has always addressed and never used: the FACTORY MAP
    // screen's route markers live entirely in that bank, which is why they came
    // out as raw un-recoloured art (see docs/mo_priority.md).
    //
    // The reference restarts the scan at every marker pixel; the union of all
    // those scans is this one-flip-flop automaton along the scanline:
    //
    //   stain(x)  = S(x) | alive(x-1)
    //   alive(x)  = stain(x) & ~( E(x-1) & ~S(x) )
    //
    // with S = "special pixel here with pen bit 1" (START_MARKER) and
    //      E = "special pixel here with pen bit 2" (END_MARKER).
    // A solid marker (pen 6 = both bits) therefore stains its own silhouette
    // plus the one pixel past its right edge, exactly like the C loop; a pen-2
    // marker stains to the end of the line, also exactly like the C loop.
    reg        stain_alive = 1'b0;
    reg        stain_e_q   = 1'b0;
    wire       stain_now   = mo_stain_s | stain_alive;
    wire       stain_brk   = stain_e_q & ~mo_stain_s;
    always @(posedge clk_sys_7159) begin
        if(visible_x == 10'd0) begin        // first cycle of a new line
            stain_alive <= 1'b0;
            stain_e_q   <= 1'b0;
        end else begin
            stain_alive <= stain_now & ~stain_brk;
            stain_e_q   <= mo_stain_e;
        end
    end

    // pens: alpha 0..255 = {3'b000,color6,pix2}; MO 256..511 = {3'b001,color4,pix4};
    // playfield 512..767 = {3'b010,color4,pix4}; SHADE moves the playfield into
    // the alternate bank 768..1023 (CRA9), matching CRA9 = SHADE*CL10 + CL9.
    // The stain then moves whatever won into the 1024..2047 bank.
    always @(posedge clk_sys_7159)
        color_vaddr <= (alpha_vis ? {3'b000, act_color, pix}
                                  : pr_pen) | {stain_now, 10'd0};

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
    wire [15:0] dbg_mbox_cnts;                    // LANE4r {5A5A cmds, 4321 acks}
    wire        mbox_dead;                        // LANE4r handshake deadlock
    wire [15:0] dbg_pf_wcnt, dbg_pf_last, dbg_col_wcnt;
    wire [15:0] dbg_boot;
    wire [15:0] dbg_retry;
    wire [15:0] dbg_a84_wr, dbg_a84_rd;
    wire [15:0] dbg_pc, dbg_wrhi, dbg_engine, dbg_mode;
    wire [15:0] dbg_ecrash_pc, dbg_ecrash_data;   // LANE4f e-side first fault
    wire [7:0]  dbg_erestart;                     // LANE4h restart counter
    wire        e_dead;                           // LANE4i freeze rescue
    wire [15:0] dbg_estall;                       // LANE4l stall probe (unused in HUD now)
    wire [15:0] dbg_vcyc, dbg_ecyc;               // LANE4s speed meters
    wire [15:0] dbg_ewild;                        // LANE4s wild-jump source PC
    wire        dbg_eintab;                       // extra executing data table now
    wire [15:0] dbg_awr;                          // SDSCHED-75 alpha writes/frame
    // TASLOCK-102 proof counters: {writes-blocked, cycles-blocked} and the
    // byte address of the first cross-port collision on an in-flight
    // read-modify-write. Both saturate; both survive everything but a real
    // reset. Shown on HUD page 2 (see the hex_digit mux).
    wire [15:0] dbg_tas_cnt, dbg_tas_addr;
    wire [15:0] dbg_ewrong;                       // SDSCHED-76 impostor 0x80E word
    wire [3:0]  dbg_ewrong_cnt;
    wire [15:0] dbg_ewrong_prev;                  // SDSCHED-81 predecessor read addr
    // SDSCHED-85 flight recorder
    reg  [6:0]  trace_idx = 7'd0;
    wire [42:0] trace_q;
    wire [6:0]  trace_wp;
    wire        trace_frozen;
    // SDSCHED-79: impostor evidence SURVIVES core resets (the '78 rescue
    // reboot wiped its own proof). Cleared only by APF reset.
    reg  [15:0] ewrong_keep = 16'd0;
    reg  [15:0] ewrong_prev_keep = 16'd0;
    reg         ewrong_seen = 1'b0;
    always @(posedge clk_sys_7159) begin
        if(!reset_n) begin
            ewrong_keep <= 16'd0; ewrong_seen <= 1'b0;
        end else if(!ewrong_seen && dbg_ewrong_cnt != 4'd0) begin
            ewrong_keep <= dbg_ewrong; ewrong_prev_keep <= dbg_ewrong_prev;
            ewrong_seen <= 1'b1;
        end
    end
    reg         core_rstn_sd = 1'b0;              // core reset, sdram-domain view
    wire [15:0] dbg_vec;
    wire        dbg_fault;
    wire [15:0] dbg_fdata;
    wire [1:0]  dbg_fsrc;
    wire [15:0] dbg_epc;
    wire [15:0] dbg_jsa_link, dbg_jsa_pc;
    wire [15:0] dbg_resp_stat, dbg_coin_cred;
    wire        wdog_expired;
    // LANE3x: L1 TOGGLES the debug overlay (was hold-to-show). Starts ON.
    wire l1_s;
synch_3 s_diag(cont1_key[8], l1_s, clk_sys_7159);
    reg  diag_on = 1'b1;
    reg  l1_d = 1'b0;
    always @(posedge clk_sys_7159) begin
        l1_d <= l1_s;
        if(l1_s & ~l1_d) diag_on <= ~diag_on;
    end
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
    .inv_x ( invx_s ), .inv_y ( invy_s ),
    .swap_xy ( swapxy_s ), .deadzone ( deadzn_s ),
    .has_analog ( cont1_key[31:28] >= 4'd2 ),
    .clk   ( clk_sys_7159 ),
    .up    ( cont1_key[0] ),   .down  ( cont1_key[1] ),
    .left  ( cont1_key[2] ),   .right ( cont1_key[3] ),
    .joy_x ( cont1_joy[7:0] ), .joy_y ( cont1_joy[15:8] ),
    .adc_x ( adc_p1x ),        .adc_y ( adc_p1y )
);
hall_stick hall_p2 (
    .inv_x ( invx_s ), .inv_y ( invy_s ),
    .swap_xy ( swapxy_s ), .deadzone ( deadzn_s ),
    .has_analog ( cont2_key[31:28] >= 4'd2 ),
    .clk   ( clk_sys_7159 ),
    .up    ( cont2_key[0] ),   .down  ( cont2_key[1] ),
    .left  ( cont2_key[2] ),   .right ( cont2_key[3] ),
    .joy_x ( cont2_joy[7:0] ), .joy_y ( cont2_joy[15:8] ),
    .adc_x ( adc_p2x ),        .adc_y ( adc_p2y )
);
// EIRQ_MODE 0 = the schematic-literal model and what this build SHIPS: one
// shared vblank latch, cleared by either CPU's 0x360000 access. The board has
// exactly one vblank flip-flop (60M LS74; CLR = /VACK off a common-bus decoder
// that cannot tell which CPU is driving), so modes 1 and 2 model a structure
// the hardware does not have - they are kept only for A/B. The entity's own
// default is still 2 and is overridden here; read THIS line, not the default.
// (The previous comment here claimed mode 2 while the line passed 0.)
escape_core #(.PAR4_EN(1), .FASTPATH_EN(FASTPATH_EN), .EIRQ_MODE(0),
              .TASLOCK_EN(TASLOCK_EN)) ecore (
    .clk        ( clk_sys_7159 ),
    .reset_n    ( core_reset_n ),
    .rom_addr   ( core_rom_addr ),
    .rom_data   ( core_rom_data ),
    .rom_par    ( core_rom_par ),
    .rom_par4   ( core_rom_par4 ),
    .rom_req    ( core_rom_req ),
    .rom_ack    ( core_rom_ack_s ),
    // SDSCHED-88 zero-wait fastpath (clk_sdram read caches above)
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
    // EEPROM non-volatile port (ee_save, above)
    .ee_saddr   ( ee_saddr ),
    .ee_sdin    ( ee_sdin ),
    .ee_swe     ( ee_swe ),
    .ee_sq      ( ee_sq ),
    .ee_wrpulse ( ee_wrpulse ),
    .vblank_in  ( vblank_w ),
    // {duck, spare, fire, jump} = Pocket {A, -, B, Y}   (schematic sheet 3: CD11..CD8;
    // MAME eprom: D9 = button 1 fire, D8 = button 2 jump, D11 = button 3 duck)
    // QoL layout: Jump on the left (Y), Fire in the middle (B), Duck on the right (A);
    // X (top, otherwise unused) = all three at once = the in-game BOMB
    // MOSDRAM-72: BOMB macro restored on X = bit 6 (APF spec). History:
    // v74 concluded 'X=bit8' from a probe, but bit 8 is L1 - the 0x0100
    // presses in that test were the L button, mislabeled. The L-macro then
    // had to be removed when L became the overlay toggle ('4A': every HUD
    // toggle fed phantom Jump+Fire+Duck), orphaning X entirely - the
    // 'bomb does nothing' report. Bit 6 has no other binding, no conflict.
    .p1_buttons ( {cont1_key[4]|cont1_key[6], 1'b0,
                   cont1_key[5]|cont1_key[6], cont1_key[7]|cont1_key[6]} ),
    .uvol_ym    ( uvolym_s ),
    .uvol_tms   ( uvoltms_s ),
    .uvol_fm    ( uvolfm_s ),
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
    .dbg_ecrash_pc  ( dbg_ecrash_pc ),
    .dbg_erestart   ( dbg_erestart ),
    .e_dead         ( e_dead ),
    .dbg_estall     ( dbg_estall ),
    .dbg_vcyc       ( dbg_vcyc ),
    .dbg_ecyc       ( dbg_ecyc ),
    .dbg_ewild      ( dbg_ewild ),
    .dbg_eintab     ( dbg_eintab ),
    .dbg_awr        ( dbg_awr ),
    .dbg_tas_cnt    ( dbg_tas_cnt ),
    .dbg_tas_addr   ( dbg_tas_addr ),
    .dbg_ewrong     ( dbg_ewrong ),
    .dbg_ewrong_cnt ( dbg_ewrong_cnt ),
    .dbg_ewrong_prev( dbg_ewrong_prev ),
    .trace_idx      ( trace_idx ),
    .trace_hold     ( m_trace ),
    .trace_q        ( trace_q ),
    .trace_wp       ( trace_wp ),
    .trace_frozen   ( trace_frozen ),
    .dbg_ecrash_data( dbg_ecrash_data ),
    .dbg_mbox_cmd   ( dbg_mbox_cmd ),
    .dbg_mbox_resp  ( dbg_mbox_resp ),
    .dbg_mbox_ramr  ( dbg_mbox_ramr ),
    .dbg_mbox_sum   ( dbg_mbox_sum ),
    .dbg_mbox_cnts  ( dbg_mbox_cnts ),
    .mbox_dead      ( mbox_dead ),
    .dbg_pf_wcnt    ( dbg_pf_wcnt ),
    .dbg_pf_last    ( dbg_pf_last ),
    .dbg_col_wcnt   ( dbg_col_wcnt ),
    .dbg_boot       ( dbg_boot ),
    .dbg_retry      ( dbg_retry ),
    .dbg_a84_wr     ( dbg_a84_wr ),
    .dbg_a84_rd     ( dbg_a84_rd ),
    .dbg_engine     ( dbg_engine ),
    .dbg_mode       ( dbg_mode ),
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

