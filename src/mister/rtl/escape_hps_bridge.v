//============================================================================
// escape_hps_bridge.v - MiSTer framework (hps_io) <-> machine, across clocks.
//
// hps_io runs on clk_ram (35.795455 MHz). The machine and its EEPROM run on
// clk_sys (7.159091 MHz, the same PLL, exactly 1/5). A one-cycle hps_io
// strobe lasts 28 ns; clk_sys samples every 140 ns, so anything that watches
// an ioctl strobe from clk_sys sees it about one time in five. Everything
// here captures in clk_ram and hands the result to clk_sys explicitly.
//
// 1. GAME SELECT (GAMESEL-167, fixed NVRAM-170). The MRA's <rom index="1">
//    byte (00 Escape, 01 Klax prototype, 02 Guts n' Glory) is latched on
//    clk_ram and double-registered into clk_sys. Builds 164-167 latched it on
//    clk_sys directly and so usually missed it: Klax and Guts mostly booted
//    as Escape. game_sel resets to 00 with the FPGA, which Main reprograms on
//    every MRA launch, so MRAs without the byte (all Escape ones) get 00.
//
// 2. EEPROM PERSISTENCE (NVRAM-170). The 2804 is 512 bytes, byte-wide; the
//    core exposes it as port B of its EEPROM RAM (ee_saddr/ee_sdin/ee_swe/
//    ee_sq, clk_sys, one-cycle registered read) plus ee_wrpulse when the CPU
//    stores a byte. The MRA declares <nvram index="4" size="512"/>:
//    - LOAD: after the ROMs, Main sends the saved file as an index-4
//      download. Each byte is handed to clk_sys with a toggle handshake while
//      ioctl_wait holds the HPS off, then written through port B. No file
//      (first run) means no download: the EEPROM keeps its erased 0xFF state
//      and the game initialises it, as on a fresh board.
//    - SAVE: a 512x8 mirror, written from clk_sys by a scrubber that
//      re-reads port B continuously (3 clk_sys per byte, a full pass every
//      ~215 us), is read on clk_ram, so ioctl_din follows ioctl_addr with
//      one clk_ram of latency - hps_io's upload has no wait states.
//    - WHEN (NVRAM-171, the Arcade-Cave convention): ee_wrpulse marks the
//      EEPROM dirty. upload_req pulses only (a) at the instant the OSD
//      opens, if "Autosave NVRAM" is on (default Off) and the EEPROM is
//      dirty, or (b) when "Save NVRAM" is chosen. Main also saves on its own
//      "Save settings". NVRAM-170 raised the request on every game write;
//      Escape rewrites a four-byte counter every 10-20 s in attract, and
//      Main polls the request on every main-menu redraw, so "Saving..."
//      appeared on nearly every menu change. Main names the file after the
//      MRA, so every game keeps its own. The format is the Pocket's .sav
//      format (512 bytes, the EEPROM's low byte per word).
//============================================================================
`default_nettype none

module escape_hps_bridge (
    input  wire        clk_ram,          // hps_io domain
    input  wire        clk_sys,          // machine / EEPROM domain

    // hps_io (clk_ram)
    input  wire        ioctl_download,
    input  wire        ioctl_upload,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    input  wire [15:0] ioctl_index,
    output wire  [7:0] ioctl_din,        // upload data for ioctl_addr
    output wire        nv_wait,          // OR into ioctl_wait
    output reg         upload_req = 1'b0,// to hps_io ioctl_upload_req (one-clock pulses)
    input  wire        osd_status,       // OSD_STATUS (synchronised here)
    input  wire        autosave,         // "Autosave NVRAM" (clk_ram, from status)
    input  wire        save_now,         // "Save NVRAM" trigger (clk_ram, from status)

    // machine (clk_sys)
    output reg   [1:0] game_sel = 2'b00,
    output reg   [8:0] ee_saddr = 9'd0,
    output reg   [7:0] ee_sdin  = 8'd0,
    output reg         ee_swe   = 1'b0,
    input  wire  [7:0] ee_sq,
    input  wire        ee_wrpulse
);
    localparam [15:0] IDX_GAME  = 16'd1;
    localparam [15:0] IDX_NVRAM = 16'd4;

    //------------------------------------------------------------ game select
    reg [1:0] gs_ram = 2'b00;
    always @(posedge clk_ram)
        if (ioctl_wr && ioctl_download && ioctl_index == IDX_GAME && ioctl_addr == 27'd0)
            gs_ram <= ioctl_dout[1:0];
    reg [1:0] gs_s1 = 2'b00;
    always @(posedge clk_sys) begin
        gs_s1    <= gs_ram;            // static long before reset releases
        game_sel <= gs_s1;
    end

    //------------------------------------------------------------ NVRAM load
    // clk_ram: capture one byte, raise busy (ioctl_wait), toggle the request.
    reg       ld_req_t = 1'b0;
    reg       ld_busy  = 1'b0;
    reg [8:0] ld_addr  = 9'd0;
    reg [7:0] ld_data  = 8'd0;
    reg [1:0] ld_ack_s = 2'b00;
    reg       ld_ack_t = 1'b0;        // clk_sys side
    always @(posedge clk_ram) begin
        ld_ack_s <= {ld_ack_s[0], ld_ack_t};
        if (ld_busy) begin
            if (ld_ack_s[1] == ld_req_t) ld_busy <= 1'b0;
        end else if (ioctl_wr && ioctl_download && ioctl_index == IDX_NVRAM
                     && ioctl_addr[26:9] == 18'd0) begin
            ld_addr  <= ioctl_addr[8:0];
            ld_data  <= ioctl_dout;
            ld_req_t <= ~ld_req_t;
            ld_busy  <= 1'b1;
        end
    end
    assign nv_wait = ld_busy;

    //------------------------------------------------------------ port B owner
    // clk_sys: a pending load byte is written as soon as its request toggle
    // arrives (ld_addr/ld_data are stable while ld_busy holds them); in every
    // other cycle the scrubber walks the EEPROM into the mirror.
    reg [2:0] ld_req_s = 3'b000;
    reg [1:0] sc_st    = 2'd0;
    reg [8:0] sc_addr  = 9'd0;
    reg       mir_we   = 1'b0;
    reg [8:0] mir_wa   = 9'd0;
    reg [7:0] mir_wd   = 8'd0;
    always @(posedge clk_sys) begin
        ld_req_s <= {ld_req_s[1:0], ld_req_t};
        ee_swe   <= 1'b0;
        mir_we   <= 1'b0;
        if (ld_req_s[2] != ld_req_s[1]) begin
            ee_saddr <= ld_addr;
            ee_sdin  <= ld_data;
            ee_swe   <= 1'b1;
            ld_ack_t <= ld_req_s[1];
            sc_st    <= 2'd0;          // restart the current scrub byte
        end else begin
            case (sc_st)
                2'd0: begin ee_saddr <= sc_addr; sc_st <= 2'd1; end
                2'd1: sc_st <= 2'd2;   // RAM samples the address this edge
                default: begin
                    mir_wa  <= sc_addr;
                    mir_wd  <= ee_sq;
                    mir_we  <= 1'b1;
                    sc_addr <= sc_addr + 9'd1;
                    sc_st   <= 2'd0;
                end
            endcase
        end
    end

    //------------------------------------------------------------ mirror
    reg [7:0] mirror [0:511];
    integer i;
    initial for (i = 0; i < 512; i = i + 1) mirror[i] = 8'hFF;
    always @(posedge clk_sys)
        if (mir_we) mirror[mir_wa] <= mir_wd;
    reg [7:0] up_q = 8'hFF;
    always @(posedge clk_ram)
        up_q <= mirror[ioctl_addr[8:0]];
    assign ioctl_din = up_q;

    //------------------------------------------------------------ save request
    // ee_wrpulse (clk_sys) -> toggle -> clk_ram; dirty stays set until an
    // upload starts, and a write during the upload sets it again.
    reg       wr_t = 1'b0;
    reg       wrp_d = 1'b0;
    always @(posedge clk_sys) begin
        wrp_d <= ee_wrpulse;
        if (ee_wrpulse && !wrp_d) wr_t <= ~wr_t;
    end
    reg [2:0] wr_s = 3'b000;
    reg       dirty = 1'b0;
    reg       up_d  = 1'b0;
    reg [2:0] osd_s = 3'b000;
    reg       sv_d  = 1'b0;
    always @(posedge clk_ram) begin
        wr_s  <= {wr_s[1:0], wr_t};
        up_d  <= ioctl_upload;
        osd_s <= {osd_s[1:0], osd_status};
        sv_d  <= save_now;
        if (ioctl_upload && !up_d) dirty <= 1'b0;
        if (wr_s[2] != wr_s[1])     dirty <= 1'b1;
        upload_req <= (autosave && dirty && osd_s[1] && !osd_s[2])
                   || (save_now && !sv_d);
    end
endmodule

`default_nettype wire
