// tb_pf_cram: art-in-sim for the CRAM playfield path (LANE3i validation).
//
// Instantiates the REAL third_party psram.sv controller against a behavioral
// 70ns ADmux PSRAM chip model, and replicates core_top's pixel-domain PF
// pipeline (queue -> A/B ping-pong channels -> slot ring -> extraction) plus
// the sdram-domain unified CRAM service chain, at the real 12:1 clock ratio
// (85.909MHz service / 7.159MHz pixel). MO interference is injected at game
// cadence (one 2-read fetch per 8-pixel slot) to model sprite traffic.
//
// The CRAM model is preloaded with a synthetic pattern where word[a] is a
// function of the address, and the map holds a distinct tile in every cell -
// any wrong-address, wrong-pair, stale-slot or latency bug lands visibly.
// Each visible pixel's extracted nibble is dumped to pf_pixels.txt; Python
// (sim/tools/check_pf_frame.py) computes the expected frame and reports
// mismatches PER COLUMN - the accumulating-rightward signature that convicted
// the one-in-flight design on hardware (build 39) shows up directly here.
//
// Run:  ./sim/run_pf_tb.sh          (docker iverilog wrapper)
`timescale 1ns/1ps

module tb_pf_cram;
    parameter SINGLE_CH = 0;   // 1 = old one-in-flight design (control run)
    parameter REAL_DATA = 0;   // 1 = load real gfx (cram_words.hex) + real map (pf_map.hex)
    parameter MO_BURST  = 2;   // MO fetches per 8px slot (attract worst case)
    // ---------------- clocks: 85.909MHz service, /12 pixel (real PLL ratio)
    reg clk85 = 0;
    always #5.82 clk85 = ~clk85;            // 11.64ns period
    reg [3:0] div = 0;
    reg clk_px = 0;
    always @(posedge clk85) begin
        if(div == 4'd5) begin div <= 0; clk_px <= ~clk_px; end
        else div <= div + 4'd1;
    end

    // ---------------- video counters (copied semantics from core_top)
    localparam VID_V_BPORCH = 'd12;
    localparam VID_V_ACTIVE = 'd240;
    localparam VID_V_TOTAL  = 'd262;
    localparam VID_H_BPORCH = 'd60;
    localparam VID_H_ACTIVE = 'd336;
    localparam VID_H_TOTAL  = 'd456;
    reg [9:0] x_count = 0, y_count = 0;
    always @(posedge clk_px) begin
        x_count <= x_count + 1'b1;
        if(x_count == VID_H_TOTAL-1) begin
            x_count <= 0;
            y_count <= y_count + 1'b1;
            if(y_count == VID_V_TOTAL-1) y_count <= 0;
        end
    end
    wire [9:0] visible_x = x_count - VID_H_BPORCH;
    wire [9:0] visible_y = y_count - VID_V_BPORCH;
    wire [9:0] vis_x     = x_count - VID_H_BPORCH;

    // ---------------- PSRAM chip model: async ADmux, 70ns access
    wire [21:16] cram0_a;
    wire [15:0]  cram0_dq;
    wire         cram0_wait;
    wire         cram0_clk, cram0_adv_n, cram0_cre;
    wire         cram0_ce0_n, cram0_ce1_n, cram0_oe_n, cram0_we_n;
    wire         cram0_ub_n, cram0_lb_n;
    assign cram0_wait = 1'b0;

    reg [15:0] cmem [0:(1<<21)-1];          // 2M words is plenty for the test
    reg [21:0] chip_addr;
    reg        chip_rd_valid;
    integer k;
    initial begin
        chip_rd_valid = 0;
        if (REAL_DATA) begin
            $readmemh("sim/build/cram_words.hex", cmem);
        end else begin
            // word[a] = low 16 bits of address - address-unique pattern
            for(k = 0; k < (1<<21); k = k + 1)
                cmem[k] = k[15:0];
        end
    end
    reg [15:0] mapmem [0:4095];
    initial if (REAL_DATA) $readmemh("sim/build/pf_map.hex", mapmem);
    // latch address while ADV low (controller drives addr on a+dq)
    always @(*) if(!cram0_adv_n && (!cram0_ce0_n || !cram0_ce1_n))
        chip_addr = {cram0_a[21:16], cram0_dq};
    // data valid 62ns after ADV rises (inside the 70ns budget)
    always @(posedge cram0_adv_n) begin
        chip_rd_valid <= 0;
        chip_rd_valid <= #62 1'b1;
    end
    assign cram0_dq = (!cram0_ce0_n && !cram0_oe_n && cram0_we_n)
                      ? (chip_rd_valid ? cmem[chip_addr[20:0]] : 16'hxxxx)
                      : 16'hzzzz;

    // ---------------- the real controller
    wire        cram_busy;
    reg         cram_read_en = 0;
    reg  [21:0] cram_addr = 0;
    wire [15:0] cram_dout;
    wire        cram_avail;
    reg         cram_write_en = 0;
    reg  [15:0] cram_din = 0;

    psram #(.CLOCK_SPEED(85.909)) cram0 (
        .clk        ( clk85 ),
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

    // ---------------- MO interference generator (pixel domain)
    // one MO fetch per 8-pixel slot on every active line - worst-case cadence
    reg mo_gfx_req = 0;
    reg [23:0] mo_gfx_addr = 24'h130000;
    wire mg_done_s;
    reg  mg_done_px_d = 0;
    wire mg_done_px_d_issue = mg_done_s;  // old gate: block issue while MO pending
    reg  [1:0] mo_burst_left = 0;
    always @(posedge clk_px) begin
        mg_done_px_d <= mg_done_s;
        if(mg_done_s != mg_done_px_d && mo_burst_left != 0) begin
            mo_gfx_addr <= mo_gfx_addr + 24'd4;
            mo_gfx_req  <= ~mo_gfx_req;
            mo_burst_left <= mo_burst_left - 2'd1;
        end
        if(vis_x[2:0]==3'd5 && mo_burst_left == 0
           && y_count >= VID_V_BPORCH && y_count < VID_V_BPORCH+VID_V_ACTIVE) begin
            mo_gfx_addr <= 24'h130000 + {visible_y[7:0], 2'd0};
            mo_gfx_req  <= ~mo_gfx_req;
            mo_burst_left <= MO_BURST[1:0];
        end
    end

    // ---------------- pixel-domain PF pipeline (replicated from core_top)
    wire [8:0] xscroll = 9'd0, yscroll = 9'd0;
    wire [8:0] pf_y  = visible_y[8:0] + yscroll;
    wire [8:0] pf_x2 = vis_x[8:0] + 9'd32 + xscroll;

    // map BRAM model: registered read; synthetic distinct codes, or the
    // real MAME map dump when REAL_DATA (col-major scanned, matching LANE3j)
    reg  [11:0] pf_vaddr;
    reg  [15:0] pf_vdata;
    always @(posedge clk_px)
        pf_vdata <= REAL_DATA ? mapmem[pf_vaddr]
                              : ({1'b0, 1'b0, pf_vaddr[11:0], 2'b00} | {4'd0, pf_vaddr});
    wire [15:0] pfx_vdata = 16'h0000;

    reg  [4:0] pfcol_q0, pfcol_q1, pfcol_q2, pfcol_q3, pfcol_show;
    reg        inflA = 0, inflB = 0;
    reg [31:0] pf_show;
    reg [31:0] pfring0, pfring1, pfring2, pfring3;
    reg [1:0]  pf_wp = 0, pf_inflA = 0, pf_inflB = 0, pf_rp = 0;
    reg [23:0] pfq_addr0, pfq_addr1, pfq_addr2, pfq_addr3;
    reg [1:0]  pfq_slot0, pfq_slot1, pfq_slot2, pfq_slot3;
    reg [2:0]  pfq_count = 0;
    reg [1:0]  pfq_wr = 0, pfq_rd = 0;
    reg  vg_doneA_last = 0, vg_doneB_last = 0;
    reg  vg_reqA_px = 0, vg_reqB_px = 0;
    reg [23:0] vg_addrA_px, vg_addrB_px;
    wire vg_doneA_s, vg_doneB_s;
    reg [31:0] vg_dataA, vg_dataB, mg_data;

    always @(posedge clk_px) begin
        case(vis_x[2:0])
            3'd0: begin
                pf_vaddr <= {pf_x2[8:3], pf_y[8:3]};   // LANE3j col-major
                pfcol_q3   <= pfcol_q2;
                pfcol_q2   <= pfcol_q1;
                pfcol_q1   <= pfcol_q0;
            end
            3'd3: begin
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
                pfcol_q0 <= {pf_vdata[15], pfx_vdata[11:8]};
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
                pf_rp <= pf_rp + 2'd1;
                pfcol_show <= pfcol_q3;
            end
            default: ;
        endcase
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
        if(pfq_count != 3'd0 && !(SINGLE_CH && (mo_gfx_req != mg_done_px_d_issue))) begin
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
            end else if(!SINGLE_CH && !inflB && !(vg_doneB_s != vg_doneB_last)) begin
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
        if(x_count == 10'd0) begin
            pf_rp <= pf_wp;
            pfq_count <= 3'd0; pfq_rd <= pfq_wr;
        end
    end

    // pixel extraction
    wire [2:0] pf_n = pfcol_show[4] ? (3'd7 - visible_x[2:0]) : visible_x[2:0];
    reg  [3:0] pf_pix;
    always @(*) begin
        case(pf_n)
            3'd0: pf_pix = pf_show[31:28]; 3'd1: pf_pix = pf_show[27:24];
            3'd2: pf_pix = pf_show[23:20]; 3'd3: pf_pix = pf_show[19:16];
            3'd4: pf_pix = pf_show[15:12]; 3'd5: pf_pix = pf_show[11:8];
            3'd6: pf_pix = pf_show[7:4];   default: pf_pix = pf_show[3:0];
        endcase
    end

    // ---------------- CDC (real synch_3) + sdram-domain service chain
    wire vg_reqA_s, vg_reqB_s, mg_req_s;
    reg  vg_doneA_85 = 0, vg_doneB_85 = 0, mg_done_85 = 0;
    synch_3 s_vgA(vg_reqA_px, vg_reqA_s, clk85);
    synch_3 s_vgB(vg_reqB_px, vg_reqB_s, clk85);
    synch_3 s_mg (mo_gfx_req, mg_req_s,  clk85);
    synch_3 s_vgdA(vg_doneA_85, vg_doneA_s, clk_px);
    synch_3 s_vgdB(vg_doneB_85, vg_doneB_s, clk_px);
    synch_3 s_mgd (mg_done_85,  mg_done_s,  clk_px);

    reg vg_reqA_last = 0, vg_reqB_last = 0, mg_req_last = 0;
    reg [1:0] cvg_ph = 0, cmg_ph = 0;
    reg [15:0] cvg_hi, cmg_hi;
    reg cvg_ch = 0;

    always @(posedge clk85) begin
        // unified CRAM read-start chain (drain/cst omitted: mem preloaded)
        if(cvg_ph==2'd0 && cmg_ph==2'd0
           && !cram_busy && !cram_read_en && !cram_write_en) begin
            if(vg_reqA_s != vg_reqA_last || vg_reqB_s != vg_reqB_last) begin
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
            end else if(mg_req_s != mg_req_last) begin
                mg_req_last  <= mg_req_s;
                cram_addr    <= mo_gfx_addr[22:1] - 22'h88000;
                cram_read_en <= 1'b1;
                cmg_ph       <= 2'd1;
            end
        end
        if(cvg_ph==2'd1) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin cvg_hi <= cram_dout; cvg_ph <= 2'd2; end
        end
        if(cvg_ph==2'd2 && !cram_busy && !cram_read_en) begin
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
                cvg_ph <= 2'd0;
            end
        end
        if(cmg_ph==2'd1) begin
            cram_read_en <= 1'b0;
            if(cram_avail) begin cmg_hi <= cram_dout; cmg_ph <= 2'd2; end
        end
        if(cmg_ph==2'd2 && !cram_busy && !cram_read_en) begin
            cram_addr    <= cram_addr | 22'd1;
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
    end

    // ---------------- debug counters
    integer n_issueA = 0, n_issueB = 0, n_doneA = 0, n_doneB = 0;
    integer n_cvg = 0, n_cmg = 0, n_avail = 0;
    always @(posedge clk_px) begin
        if(vg_reqA_px !== vg_reqA_px) ;
        if(inflA == 1'b0 && $time > 0) ;
    end
    always @(vg_reqA_px) n_issueA = n_issueA + 1;
    always @(vg_reqB_px) n_issueB = n_issueB + 1;
    always @(vg_doneA_85) begin n_doneA = n_doneA + 1;
        if(n_doneA < 4) $display("DBG doneA #%0d data=%h t=%0t", n_doneA, vg_dataA, $time);
    end
    always @(vg_doneB_85) n_doneB = n_doneB + 1;
    always @(posedge clk85) if(cram_avail === 1'b1) n_avail = n_avail + 1;
    always @(posedge clk85) if(cvg_ph==2'd3 && cram_avail===1'b1) n_cvg = n_cvg + 1;
    always @(posedge clk85) if(cmg_ph==2'd3 && cram_avail===1'b1) n_cmg = n_cmg + 1;
    initial begin
        #2000000;  // 2ms in
        $display("DBG @2ms: issueA=%0d issueB=%0d doneA=%0d doneB=%0d avail=%0d cvg=%0d cmg=%0d cvg_ph=%0d cmg_ph=%0d busy=%b pfq=%0d inflA=%b inflB=%b",
                 n_issueA, n_issueB, n_doneA, n_doneB, n_avail, n_cvg, n_cmg, cvg_ph, cmg_ph, cram_busy, pfq_count, inflA, inflB);
    end

    // ---------------- frame dump + finish
    integer fd, px_seen;
    reg dumping = 0;
    initial begin
        fd = $fopen("sim/build/pf_pixels.txt", "w");
        px_seen = 0;
        // let two full frames elapse (first frame fills pipes), dump the third
        @(posedge clk_px);
        repeat (2 * VID_V_TOTAL * VID_H_TOTAL) @(posedge clk_px);
        dumping = 1;
        repeat (VID_V_TOTAL * VID_H_TOTAL + 10) @(posedge clk_px);
        $fclose(fd);
        $display("TB_PF_CRAM DONE: %0d pixels dumped", px_seen);
        $finish;
    end
    always @(posedge clk_px) begin
        if(dumping
           && x_count >= VID_H_BPORCH && x_count < VID_H_BPORCH+VID_H_ACTIVE
           && y_count >= VID_V_BPORCH && y_count < VID_V_BPORCH+VID_V_ACTIVE) begin
            $fwrite(fd, "%0d %0d %h\n", visible_x, visible_y, pf_pix);
            px_seen = px_seen + 1;
        end
    end
endmodule

// 3-stage synchronizer (copy of the project's synch_3 semantics)
module synch_3 #(parameter WIDTH = 1) (
    input  wire [WIDTH-1:0] i,
    output reg  [WIDTH-1:0] o,
    input  wire clk
);
    reg [WIDTH-1:0] stage_1, stage_2;
    always @(posedge clk) begin
        stage_1 <= i;
        stage_2 <= stage_1;
        o       <= stage_2;
    end
endmodule
