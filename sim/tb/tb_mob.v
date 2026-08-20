// tb_mob: the REAL escape_mob.v against REAL in-game state dumped live from
// MAME mid-gameplay (robots + player on screen): MO RAM, SLIP/config RAM,
// scroll registers, and the real chunky gfx. Renders one frame of the MO
// layer to mob_pixels.txt; sim/tools/check_mob_frame.py turns it into an
// image for direct comparison against the synchronized MAME screenshot.
//
// The question this answers: where do in-game sprites actually land under
// real nonzero scroll (x~123 y~253)? On device they are invisible in-game
// while attract sprites (scroll 0) are pixel-perfect.
//
// Run: sim/run_mob_tb.sh
`timescale 1ns/1ps

module tb_mob;
    parameter XSCROLL = 123;
    parameter YSCROLL = 253;
    parameter GFX_LAT = 8;   // pixel-clock cycles per fetch (device-realistic)

    reg clk = 0;
    always #69.84 clk = ~clk;           // 7.159MHz pixel clock

    localparam VID_V_BPORCH = 'd12;
    localparam VID_V_ACTIVE = 'd240;
    localparam VID_V_TOTAL  = 'd262;
    localparam VID_H_BPORCH = 'd60;
    localparam VID_H_ACTIVE = 'd336;
    localparam VID_H_TOTAL  = 'd456;
    reg [9:0] x_count = 0, y_count = 0;
    always @(posedge clk) begin
        x_count <= x_count + 1'b1;
        if(x_count == VID_H_TOTAL-1) begin
            x_count <= 0;
            y_count <= y_count + 1'b1;
            if(y_count == VID_V_TOTAL-1) y_count <= 0;
        end
    end
    wire [9:0] visible_x = x_count - VID_H_BPORCH;
    wire [9:0] visible_y = y_count - VID_V_BPORCH;

    // ---------------- RAM models (single-registered reads, BRAM-equivalent)
    reg [15:0] momem [0:4095];
    reg [15:0] cfgmem [0:127];
    initial begin
        $readmemh("sim/work/game_mo.hex", momem);
        $readmemh("sim/work/game_cfg.hex", cfgmem);
    end
    wire [11:0] mo_vaddr;
    reg  [15:0] mo_vdata;
    wire [6:0]  cfg_vaddr;
    reg  [15:0] cfg_vdata;
    always @(posedge clk) begin
        mo_vdata  <= momem[mo_vaddr];
        cfg_vdata <= cfgmem[cfg_vaddr];
    end

    // ---------------- gfx model: real chunky image bytes, ~4-cycle latency
    reg [7:0] gfx [0:(1<<22)-1];        // image bytes 0..0x220000
    initial $readmemh("sim/work/image_bytes.hex", gfx);
    wire        gfx_reqA, gfx_reqB;
    wire [23:0] gfx_addrA, gfx_addrB;
    reg         gfx_doneA = 0, gfx_doneB = 0;
    reg  [31:0] gfx_dataA, gfx_dataB;
    reg         reqA_d = 0, reqB_d = 0;
    reg  [4:0]  latA = 0, latB = 0;
    reg  [23:0] addrA_l, addrB_l;
    always @(posedge clk) begin
        if(gfx_reqA != reqA_d && latA == 0) begin
            reqA_d <= gfx_reqA; addrA_l <= gfx_addrA; latA <= GFX_LAT[4:0];
        end else if(latA != 0) begin
            latA <= latA - 5'd1;
            if(latA == 5'd1) begin
                gfx_dataA <= {gfx[addrA_l], gfx[addrA_l+1], gfx[addrA_l+2], gfx[addrA_l+3]};
                gfx_doneA <= ~gfx_doneA;
            end
        end
        if(gfx_reqB != reqB_d && latB == 0) begin
            reqB_d <= gfx_reqB; addrB_l <= gfx_addrB; latB <= GFX_LAT[4:0];
        end else if(latB != 0) begin
            latB <= latB - 5'd1;
            if(latB == 5'd1) begin
                gfx_dataB <= {gfx[addrB_l], gfx[addrB_l+1], gfx[addrB_l+2], gfx[addrB_l+3]};
                gfx_doneB <= ~gfx_doneB;
            end
        end
    end

    // ---------------- DUT
    reg rstn = 0;
    initial begin rstn = 0; repeat (20) @(posedge clk); rstn = 1; end
    wire [7:0] disp_pen;
    wire       disp_valid;
    escape_mob dut (
        .clk      ( clk ),
        .reset_n  ( rstn ),
        .x_count  ( x_count ),
        .y_count  ( y_count ),
        .vbporch  ( 10'd12 ),
        .vactive  ( 10'd240 ),
        .hbporch  ( 10'd60 ),
        .xscroll  ( XSCROLL[8:0] ),
        .yscroll  ( YSCROLL[8:0] ),
        .mo_vaddr ( mo_vaddr ),
        .mo_vdata ( mo_vdata ),
        .cfg_vaddr( cfg_vaddr ),
        .cfg_vdata( cfg_vdata ),
        .gfx_reqA ( gfx_reqA ),
        .gfx_reqB ( gfx_reqB ),
        .gfx_addrA( gfx_addrA ),
        .gfx_addrB( gfx_addrB ),
        .gfx_doneA( gfx_doneA ),
        .gfx_doneB( gfx_doneB ),
        .gfx_dataA( gfx_dataA ),
        .gfx_dataB( gfx_dataB ),
        .disp_x   ( visible_x[8:0] ),
        .disp_pen ( disp_pen ),
        .disp_valid( disp_valid )
    );

    // ---------------- debug: what does the engine actually do per line?
    reg dumping = 0;
    integer n_slip, n_entries, n_ymatch, n_fetch, n_wren, n_wren_off;
    integer n_pend, n_done, n_blitst; reg pendA_d = 0, doneA_d = 0;
    initial begin n_slip=0; n_entries=0; n_ymatch=0; n_fetch=0; n_wren=0; n_wren_off=0; n_pend=0; n_done=0; n_blitst=0; end
    reg [3:0] state_d = 0;
    always @(posedge clk) begin
        state_d <= dut.state;
        if(dut.state == 4'd3 && state_d != 4'd3) n_slip = n_slip + 1;          // S_SLIP1
        if(dut.state == 4'd8 && state_d != 4'd8) n_entries = n_entries + 1;    // S_MATCH
        if(dut.state == 4'd10 && state_d != 4'd10 && dut.ymatch) n_ymatch = n_ymatch + 1;
        if(dut.state == 4'd11 && dut.blit_n == 4'd15) n_fetch = n_fetch + 1;
        if(dut.pendA && !pendA_d) n_pend = n_pend + 1;
        pendA_d = dut.pendA;
        if(gfx_doneA != doneA_d) n_done = n_done + 1;
        if(gfx_doneA != doneA_d && n_done < 25)
            $display("FETCH addr=%06x data=%08x", addrA_l, {gfx[addrA_l], gfx[addrA_l+1], gfx[addrA_l+2], gfx[addrA_l+3]});
        doneA_d = gfx_doneA;
        if(dut.state == 4'd12 && state_d != 4'd12) n_blitst = n_blitst + 1;
        if(dut.wr_en) n_wren = n_wren + 1;
        if(dut.state == 4'd11 && dut.blit_n < 4'd8 && dut.pix_val != 0 && dut.blit_x >= 9'd344)
            n_wren_off = n_wren_off + 1;
        if(dumping && dut.wr_en && n_wren < 30)
            $display("WR line=%0d ly=%0d x=%0d pen=%02x", y_count, dut.ly, dut.wr_x, dut.wr_data[7:0]);
    end

    // ---------------- frame dump
    integer fd, px_seen, reqs;
    always @(gfx_reqA) reqs = reqs + 1;
    always @(gfx_reqB) reqs = reqs + 1;
    initial begin
        fd = $fopen("sim/build/mob_pixels.txt", "w");
        px_seen = 0; reqs = 0;
        @(posedge rstn);
        repeat (2 * VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        dumping = 1;
        repeat (VID_V_TOTAL * VID_H_TOTAL + 10) @(posedge clk);
        $fclose(fd);
        $display("TB_MOB DONE: %0d pixels, %0d gfx reqs", px_seen, reqs);
        $display("DBG slips=%0d entries=%0d ymatch=%0d fetch=%0d wren=%0d offscreen_px=%0d",
                 n_slip, n_entries, n_ymatch, n_fetch, n_wren, n_wren_off);
        $display("DBG2 done=%0d pend=%0d blitstate=%0d", n_done, n_pend, n_blitst);
        $finish;
    end
    always @(posedge clk) begin
        if(dumping
           && x_count >= VID_H_BPORCH+1 && x_count < VID_H_BPORCH+VID_H_ACTIVE+1
           && y_count >= VID_V_BPORCH && y_count < VID_V_BPORCH+VID_V_ACTIVE) begin
            // disp read is registered: pen for visible_x N is valid one cycle later
            if(disp_valid) begin
                $fwrite(fd, "%0d %0d %h\n", visible_x - 10'd1, visible_y, disp_pen);
                px_seen = px_seen + 1;
            end
        end
    end
endmodule
