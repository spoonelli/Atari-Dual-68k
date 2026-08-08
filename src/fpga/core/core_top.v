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
assign cram0_a = 'h0;
assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;
assign cram0_adv_n = 1;
assign cram0_cre = 0;
assign cram0_ce0_n = 1;
assign cram0_ce1_n = 1;
assign cram0_oe_n = 1;
assign cram0_we_n = 1;
assign cram0_ub_n = 1;
assign cram0_lb_n = 1;

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
                if(visible_y >= 'd234) begin
                    case(visible_x[8:6])
                        3'd0: vidout_rgb <= sdram_init_done_s      ? 24'h00A000 : 24'hA00000;
                        3'd1: vidout_rgb <= dataslot_allcomplete_s ? 24'h00A000 : 24'hA00000;
                        3'd2: vidout_rgb <= chk_done_s             ? 24'h00A000 : 24'hA00000;
                        3'd3: vidout_rgb <= chk_ok_s               ? 24'h00A000 : 24'hA00000;
                        3'd4: vidout_rgb <= rom_req_seen           ? 24'h00A000 : 24'hA00000;
                        3'd5: vidout_rgb <= dbg_v_pc_fetch         ? 24'h00A000 : 24'hA00000;
                        default: vidout_rgb <= dbg_e_running       ? 24'h00A000 : 24'hA00000;
                    endcase
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
always @(negedge audgen_sclk) begin
    audgen_dac <= 1'b0;
    // 48khz * 64
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        // switch channels
        audgen_lrck <= ~audgen_lrck;
        
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
always @(posedge clk_74a) begin
    if(bridge_wr && bridge_addr[31:24] == 8'h10) begin
        dl_addr_74 <= bridge_addr[24:0];
        dl_data_74 <= bridge_wr_data;
        dl_req_74  <= ~dl_req_74;
    end
end

    wire dl_req_s;
synch_3 s_dl(dl_req_74, dl_req_s, clk_sdram);

    reg        dl_req_last;
    reg  [1:0] dl_phase;      // 0 idle, 1 write hi word, 2 write lo word
    reg        sd_wr_req;
    reg [24:0] sd_wr_addr;
    reg [15:0] sd_wr_data;
    wire       sd_wr_ack;
always @(posedge clk_sdram) begin
    case(dl_phase)
    2'd0: begin
        if(dl_req_s != dl_req_last) begin
            dl_req_last <= dl_req_s;
            sd_wr_addr <= dl_addr_74;
            sd_wr_data <= dl_data_74[31:16];
            sd_wr_req  <= 1;
            dl_phase   <= 2'd1;
        end
    end
    2'd1: begin
        if(sd_wr_ack) begin
            sd_wr_req <= 0;
            dl_phase  <= 2'd2;
        end
    end
    2'd2: begin
        if(!sd_wr_ack) begin
            sd_wr_addr <= sd_wr_addr + 25'd2;
            sd_wr_data <= dl_data_74[15:0];
            sd_wr_req  <= 1;
            dl_phase   <= 2'd3;
        end
    end
    2'd3: begin
        if(sd_wr_ack) begin
            sd_wr_req <= 0;
            dl_phase  <= 2'd0;
        end
    end
    endcase
end

    // ---------------- escape_core ROM fetch (7.159 domain) -> SDRAM (85.9 domain)
    wire [23:0] core_rom_addr;
    wire        core_rom_req;
    wire        core_rom_req_s;
    reg         core_rom_ack_85;
    wire        core_rom_ack_s;
    wire [15:0] sd_rd_data;
    reg  [15:0] core_rom_data;
    reg         sd_rd_req;
    wire        sd_rd_ack;
synch_3 s_rr(core_rom_req, core_rom_req_s, clk_sdram);
synch_3 s_ra(core_rom_ack_85, core_rom_ack_s, clk_sys_7159);

    // SDRAM self-check: after init + full ROM download, read word 0 and compare with
    // the known first ROM word (0x003F = high word of the reset SP). Proves the
    // download+readback path with no CPU involvement. Runs before the CPU is released.
    reg        chk_done, chk_ok;
    reg [2:0]  chk_state;
    // char ROM DMA: combined image 0x110000..0x113FFF -> 8192x16 BRAM
    reg [13:0] chr_dma_word;         // word index 0..8191
    reg        chr_we;
    reg [15:0] chr_wdata;
    wire       allcomplete_sd;
synch_3 s_acsd(dataslot_allcomplete, allcomplete_sd, clk_sdram);

always @(posedge clk_sdram) begin
    case(chk_state)
    3'd0: if(sdram_init_done && allcomplete_sd) begin
        sd_rd_req <= 1;
        chk_state <= 3'd1;
    end
    3'd1: if(sd_rd_ack) begin
        chk_ok    <= (sd_rd_data == 16'h003F);
        sd_rd_req <= 0;
        chk_state <= 3'd2;
    end
    3'd2: if(!sd_rd_ack) begin
        chk_state <= 3'd3;          // now DMA the char ROM into BRAM
    end
    3'd3: begin                     // issue one char-ROM read
        chr_we <= 0;
        if(!sd_rd_ack) begin
            sd_rd_req <= 1;
            chk_state <= 3'd4;
        end
    end
    3'd4: if(sd_rd_ack) begin       // capture -> BRAM write
        sd_rd_req <= 0;
        chr_wdata <= sd_rd_data;
        chr_we    <= 1;
        chk_state <= 3'd5;
    end
    3'd5: begin
        chr_we <= 0;
        if(chr_dma_word == 14'd8191) begin
            chk_done  <= 1;         // DMA finished: release the CPUs
            chk_state <= 3'd6;
        end else begin
            chr_dma_word <= chr_dma_word + 14'd1;
            chk_state <= 3'd3;
        end
    end
    3'd6: begin
        // CPU fetch service
        if(core_rom_req_s && !core_rom_ack_85 && !sd_rd_req && !sd_rd_ack) begin
            sd_rd_req <= 1;
        end
        if(sd_rd_req && sd_rd_ack) begin
            sd_rd_req <= 0;
            core_rom_data <= sd_rd_data;
            core_rom_ack_85 <= 1;
        end
        if(!core_rom_req_s) core_rom_ack_85 <= 0;
    end
    default: chk_state <= 3'd6;
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
    .rd_addr    ( chk_done   ? {1'b0, core_rom_addr} :
                  (chk_state >= 3'd3) ? (25'h0110000 + {10'd0, chr_dma_word, 1'b0}) :
                  25'd0 ),
    .rd_data    ( sd_rd_data ),
    .init_done  ( sdram_init_done )
);

    // ---------------- core reset: wait for ROM fully downloaded + sdram up
    wire dataslot_allcomplete_s, sdram_init_done_s;
synch_3 s_ac(dataslot_allcomplete, dataslot_allcomplete_s, clk_sys_7159);
synch_3 s_id(sdram_init_done, sdram_init_done_s, clk_sys_7159);
    wire chk_done_s, chk_ok_s;
synch_3 s_cd(chk_done, chk_done_s, clk_sys_7159);
synch_3 s_co(chk_ok,   chk_ok_s,   clk_sys_7159);
    wire core_reset_n = reset_n & dataslot_allcomplete_s & sdram_init_done_s & chk_done_s;

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

    always @(posedge clk_sys_7159) begin
        case(vis_x[2:0])
            3'd5: begin
                a_word <= alpha_vdata;
            end
            3'd6: begin
                chr_raddr <= {alpha_vdata[9:0], visible_y[2:0]};  // code*8 + line
                a_color   <= {alpha_vdata[14], 1'b0, alpha_vdata[13:10]};
            end
            3'd7: ;
            3'd0: begin
                r_row    <= chr_q;
                r_color  <= a_color;
                r_opaque <= a_word[15];
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
    wire [5:0] act_color = (pxn == 3'd0) ? a_color : r_color;
    always @(posedge clk_sys_7159) color_vaddr <= {3'b000, act_color, pix};

    // palette: IRGB4444 with intensity: i=(I+1)*(4-intensity), ch8 = ch4*i/4
    wire [3:0] ints   = (eintensity > 4'd4) ? 4'd4 : eintensity;
    wire [6:0] ifac   = ({3'd0, color_vdata[15:12]} + 7'd1) * (7'd4 - {5'd0, ints[2:0]});
    wire [10:0] r_m   = color_vdata[11:8] * ifac;
    wire [10:0] g_m   = color_vdata[7:4]  * ifac;
    wire [10:0] b_m   = color_vdata[3:0]  * ifac;
    wire [7:0] pal_r  = (r_m[10:2] > 9'd255) ? 8'd255 : r_m[9:2];
    wire [7:0] pal_g  = (g_m[10:2] > 9'd255) ? 8'd255 : g_m[9:2];
    wire [7:0] pal_b  = (b_m[10:2] > 9'd255) ? 8'd255 : b_m[9:2];
    wire [23:0] alpha_rgb = evideo_off ? 24'h000000 : {pal_r, pal_g, pal_b};

    wire dbg_v_pc_fetch, dbg_e_running;
escape_core ecore (
    .clk        ( clk_sys_7159 ),
    .reset_n    ( core_reset_n ),
    .rom_addr   ( core_rom_addr ),
    .rom_data   ( core_rom_data ),
    .rom_req    ( core_rom_req ),
    .rom_ack    ( core_rom_ack_s ),
    .vblank_in  ( vblank_w ),
    // {duck, spare, fire, jump} = Pocket {X, -, B, A}   (schematic sheet 3: CD11..CD8)
    .p1_buttons ( {cont1_key[6], 1'b0, cont1_key[5], cont1_key[4]} ),
    .p2_buttons ( 4'b0000 ),
    .alpha_vaddr( alpha_vaddr ),
    .alpha_vdata( alpha_vdata ),
    .color_vaddr( color_vaddr ),
    .color_vdata( color_vdata ),
    .intensity_out( eintensity ),
    .video_off_out( evideo_off ),
    .dbg_v_pc_fetch ( dbg_v_pc_fetch ),
    .dbg_e_running  ( dbg_e_running )
);

endmodule

