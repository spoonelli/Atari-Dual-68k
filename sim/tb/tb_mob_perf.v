// tb_mob_perf: MOFETCH performance bench for the MO line engine.
//
// Deliberately a SEPARATE file from sim/tb/tb_mob.v so the fetch-path work and
// the priority work can be developed and merged independently. This bench only
// cares about THROUGHPUT: how much of the scene the engine manages to build
// inside the 456-cycle scanline budget, and where those cycles go.
//
// It renders one frame of the MO layer to sim/build/mob_perf_pixels.txt, which
// sim/tools/mob_golden.py scores against a golden model of the engine's own
// intended output (see that file: divergence == time starvation, by design).
//
// Cycle accounting is by FSM state, so escape_mob.v must keep
//   S_IDLE == 0, S_BLIT == 11, S_PRIME == 13
// for the phase split to stay meaningful across revisions.
//
// Run: sim/run_mob_perf.sh   (MOB_PARAMS='-Ptb_mob_perf.XSCROLL=50 ...')
`timescale 1ns/1ps

module tb_mob_perf;
    parameter XSCROLL = 50;
    parameter YSCROLL = 157;
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
    integer gi, nz_code, nz_slip;
    initial begin
        $readmemh("sim/work/game_mo.hex", momem);
        $readmemh("sim/work/game_cfg.hex", cfgmem);
        // fixture guard: docs/LESSONS.md - $readmemh failure is not an error,
        // and an all-zero MO fixture silently renders a blank layer.
        nz_code = 0; nz_slip = 0;
        for(gi = 0; gi < 1024; gi = gi + 1)
            if(momem[gi*4+1] !== 16'h0000) nz_code = nz_code + 1;
        for(gi = 16'h40; gi < 16'h80; gi = gi + 1)
            if(cfgmem[gi] !== 16'h0000) nz_slip = nz_slip + 1;
        $display("FIXTURE entries_with_code=%0d populated_slip_bands=%0d", nz_code, nz_slip);
        if(nz_code < 8 || nz_slip < 2)
            $fatal(1, "tb_mob_perf: sim/work/game_{mo,cfg}.hex holds no scene");
    end
    wire [11:0] mo_vaddr;
    reg  [15:0] mo_vdata;
    wire [6:0]  cfg_vaddr;
    reg  [15:0] cfg_vdata;
    always @(posedge clk) begin
        mo_vdata  <= momem[mo_vaddr];
        cfg_vdata <= cfgmem[cfg_vaddr];
    end

    // ---------------- gfx model: real chunky image bytes, GFX_LAT latency
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

    // ---------------- MOFETCH instrumentation
    // Everything below is measured over ONE frame (the measured window), so the
    // numbers are directly comparable to the 456 cycles x 240 lines a frame has.
    localparam S_IDLE = 4'd0, S_BLIT = 4'd11, S_PRIME = 4'd13;

    reg measuring = 0, dumping = 0;
    integer c_idle, c_trav, c_prime, c_blit;     // cycles by phase, this frame
    integer n_lines, n_complete, n_aborted;      // build outcome per line
    integer n_ymatch, n_wren, n_wren_off, n_reqs;
    integer n_budget_out;                        // lines that hit fetch_budget==0
    integer px_seen;
    integer line_entries, max_entries, n_entries;
    reg [3:0] state_d = 0;
    reg [9:0] mo_vaddr_d = 0;

    initial begin
        c_idle=0; c_trav=0; c_prime=0; c_blit=0;
        n_lines=0; n_complete=0; n_aborted=0;
        n_ymatch=0; n_wren=0; n_wren_off=0; n_reqs=0; n_budget_out=0;
        px_seen=0; line_entries=0; max_entries=0; n_entries=0;
    end

    always @(posedge clk) if(measuring) begin
        case(dut.state)
            S_IDLE:  c_idle  = c_idle  + 1;
            S_BLIT:  c_blit  = c_blit  + 1;
            S_PRIME: c_prime = c_prime + 1;
            default: c_trav  = c_trav  + 1;
        endcase
        if(dut.wr_en) n_wren = n_wren + 1;
        // An entry visit == a rising edge of "word 0 of some entry is being
        // addressed". Every walk order reads w0 exactly once per entry, so this
        // stays valid across FSM revisions (the old FSM addresses 0,1,2,3; the
        // pipelined one addresses 0,3 then 1,2).
        if(mo_vaddr[1:0] == 2'd0 && mo_vaddr_d[1:0] != 2'd0) begin
            n_entries = n_entries + 1;
            line_entries = line_entries + 1;
        end
        mo_vaddr_d <= {8'd0, mo_vaddr[1:0]};
        // end of scanline: did the build for the NEXT line finish?
        if(x_count == VID_H_TOTAL-1
           && y_count >= VID_V_BPORCH-1 && y_count < VID_V_BPORCH+VID_V_ACTIVE-1) begin
            n_lines = n_lines + 1;
            if(dut.state == S_IDLE) n_complete = n_complete + 1;
            else                    n_aborted  = n_aborted  + 1;
            if(dut.fetch_budget == 0) n_budget_out = n_budget_out + 1;
            if(line_entries > max_entries) max_entries = line_entries;
            line_entries = 0;
        end
    end
    always @(gfx_reqA) if(measuring) n_reqs = n_reqs + 1;
    always @(gfx_reqB) if(measuring) n_reqs = n_reqs + 1;

    // ---------------- fetch-pairing check (MO-ARTIFACT-RESEARCH.md root cause B)
    // The gfx handshake is edge-based, so a completion that lands across a line
    // abort can pair every later tile with the previous tile's data ("right art,
    // wrong place"). Verify directly: the word the engine latches must be the
    // word at the address the engine's own code_row/tx say it wanted.
    wire [23:0] exp_addr = 24'h120000
                         + { (dut.code_row + {12'b0, dut.tx}), 5'd0 }
                         + { dut.row_in_tile, 2'd0 };
    wire [31:0] exp_data = {gfx[exp_addr], gfx[exp_addr+1],
                            gfx[exp_addr+2], gfx[exp_addr+3]};
    integer n_pairslip;
    initial n_pairslip = 0;
    always @(posedge clk) if(measuring) begin
        if(dut.state == S_PRIME && dut.blit_n != 4'd15
           && (dut.tx[0] ? dut.pendB : dut.pendA)) begin
            if((dut.tx[0] ? gfx_dataB : gfx_dataA) !== exp_data)
                n_pairslip = n_pairslip + 1;
        end
    end

    // ---------------- ghost detector
    // The line buffers are never cleared; a pixel is hidden only by its
    // {frame-parity, ly} tag, and one parity bit cannot mask a 2-frame-old
    // write (MO-ARTIFACT-RESEARCH.md root cause C). That is a real defect but
    // it is NOT a fetch-path defect, and it shows up in the golden compare as
    // "wrong"/"spurious" pixels. Separate it out here so a fetch change can be
    // judged on its own: shadow every wr_en of the build in progress, hand the
    // shadow over when the buffer flips, and flag any displayed pixel that this
    // frame's build did not actually write.
    reg [7:0] sh_pen  [0:511];      // being built now
    reg       sh_val  [0:511];
    reg [7:0] dsh_pen [0:511];      // being displayed now
    reg       dsh_val [0:511];
    integer si;
    integer n_ghost, n_mismatch;
    initial begin
        n_ghost = 0; n_mismatch = 0;
        for(si = 0; si < 512; si = si + 1) begin
            sh_val[si] = 0; dsh_val[si] = 0; sh_pen[si] = 0; dsh_pen[si] = 0;
        end
    end
    always @(posedge clk) begin
        if(x_count == 10'd0 && y_count >= VID_V_BPORCH-1
           && y_count < VID_V_BPORCH+VID_V_ACTIVE-1) begin
            for(si = 0; si < 512; si = si + 1) begin
                dsh_val[si] = sh_val[si]; dsh_pen[si] = sh_pen[si];
                sh_val[si]  = 0;
            end
        end
        if(dut.wr_en) begin
            sh_pen[dut.wr_x] = dut.wr_data[7:0];
            sh_val[dut.wr_x] = 1'b1;
        end
    end

    // ---------------- frame dump
    integer fd;
    initial begin
        fd = $fopen("sim/build/mob_perf_pixels.txt", "w");
        @(posedge rstn);
        repeat (2 * VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        @(negedge clk);
        measuring = 1; dumping = 1;
        repeat (VID_V_TOTAL * VID_H_TOTAL) @(posedge clk);
        @(negedge clk);
        measuring = 0; dumping = 0;
        $fclose(fd);
        $display("PERF pixels=%0d gfx_reqs=%0d wren=%0d entries=%0d max_entries_line=%0d",
                 px_seen, n_reqs, n_wren, n_entries, max_entries);
        $display("PERF lines=%0d complete=%0d aborted=%0d budget_exhausted=%0d",
                 n_lines, n_complete, n_aborted, n_budget_out);
        $display("PERF pairing_slips=%0d", n_pairslip);
        $display("PERF ghosts=%0d pen_mismatch=%0d  (stale-tag pixels this frame's build never wrote)",
                 n_ghost, n_mismatch);
        $display("PERF cycles idle=%0d traverse=%0d prime=%0d blit=%0d (per line: %0d/%0d/%0d/%0d)",
                 c_idle, c_trav, c_prime, c_blit,
                 c_idle/240, c_trav/240, c_prime/240, c_blit/240);
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
                if(!dsh_val[visible_x - 10'd1])          n_ghost    = n_ghost + 1;
                else if(dsh_pen[visible_x - 10'd1] != disp_pen)
                                                         n_mismatch = n_mismatch + 1;
            end
        end
    end
endmodule
