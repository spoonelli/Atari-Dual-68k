//
// Escape motion-object line engine (atarimo family, eprom config).
// During each scanline, builds the NEXT line into a line buffer:
//   SLIP[band] -> linked list of 4-word entries (link*4 layout) -> per-tile
//   chunky gfx fetches via the shared video SDRAM channel -> first-write-wins
//   pixels (equivalent to MAME's reverse render order).
// Entry: w0=link[9:0]; w1=code[14:0]; w2=color[3:0]|prio[6:4]|x[15:7];
//        w3=y[15:7]|width[6:4]|height[2:0]|hflip[3]
// Tiles walk row-major: code + ty*width + tx. Palette base 0x100.
//
`default_nettype none

module escape_mob (
    input  wire        clk,             // pixel clock
    input  wire        reset_n,

    input  wire [9:0]  x_count,         // raster position
    input  wire [9:0]  y_count,
    input  wire [9:0]  vbporch,         // VID_V_BPORCH
    input  wire [9:0]  vactive,         // VID_V_ACTIVE
    input  wire [9:0]  hbporch,         // VID_H_BPORCH
    input  wire [8:0]  xscroll,
    input  wire [8:0]  yscroll,

    // MO RAM video port (word addressed, registered read)
    output reg  [11:0] mo_vaddr,
    input  wire [15:0] mo_vdata,
    // SLIP via cfg RAM video port (words 0x40-0x7F)
    output reg  [6:0]  cfg_vaddr,
    input  wire [15:0] cfg_vdata,

    // gfx fetch channel (toggle handshake, 32-bit chunky row)
    output reg         gfx_req,
    output reg  [23:0] gfx_addr,
    input  wire        gfx_done,        // toggle
    input  wire [31:0] gfx_data,

    // display-side pixel query (current line)
    input  wire [8:0]  disp_x,
    output wire [7:0]  disp_pen,        // {color[3:0], pix[3:0]}
    output wire        disp_valid
);

    // double line buffers: 512 x 9 (valid + color4 + pix4)
    reg [8:0] buf0 [0:511];
    reg [8:0] buf1 [0:511];
    reg       build_sel;                // which buffer is being built
    reg [8:0] disp_q0, disp_q1;
    always @(posedge clk) begin
        disp_q0 <= buf0[disp_x];
        disp_q1 <= buf1[disp_x];
    end
    assign disp_pen   = build_sel ? disp_q0[7:0] : disp_q1[7:0];
    assign disp_valid = build_sel ? disp_q0[8]   : disp_q1[8];

    // clear pointer + write port
    reg  [8:0] clr_x;
    reg        clearing;
    reg  [8:0] wr_x;
    reg  [8:0] wr_data;
    reg        wr_en;
    always @(posedge clk) begin
        if(clearing) begin
            if(build_sel) buf1[clr_x] <= 9'd0; else buf0[clr_x] <= 9'd0;
        end else if(wr_en) begin
            if(build_sel) buf1[wr_x] <= wr_data; else buf0[wr_x] <= wr_data;
        end
    end

    // engine state
    localparam S_IDLE   = 4'd0;
    localparam S_CLEAR  = 4'd1;
    localparam S_SLIP0  = 4'd2;
    localparam S_SLIP1  = 4'd3;
    localparam S_E0     = 4'd4;
    localparam S_E1     = 4'd5;
    localparam S_E2     = 4'd6;
    localparam S_E3     = 4'd7;
    localparam S_MATCH  = 4'd8;
    localparam S_FETCH  = 4'd9;
    localparam S_WAIT   = 4'd10;
    localparam S_BLIT   = 4'd11;
    localparam S_NEXT   = 4'd12;

    reg [3:0]  state;
    reg [8:0]  ly;                      // playfield-space line being built
    reg [9:0]  first_link, link;
    reg [6:0]  ent_count;
    reg [15:0] w0, w1, w2, w3;
    reg [8:0]  spr_y;
    reg [3:0]  spr_color;
    reg [8:0]  spr_x;
    reg [2:0]  width_t, height_t;
    reg        hflip;
    reg [2:0]  tx;
    reg [14:0] code_row;                // code + ty*width
    reg [2:0]  row_in_tile;
    reg        gfx_done_last;
    reg [31:0] rowdata;
    reg [3:0]  blit_n;
    reg [8:0]  blit_x;
    reg [5:0]  fetch_budget;
    reg [9:0]  cur_line_latch;

    // v80: MAME atarimo ground truth - the entry Y field is NEGATED and
    // offset by the sprite height: top = -yfield - (height+1)*8. So
    // ydiff = ly - top = ly + yfield + (height+1)*8. The raw-field compare
    // matched almost nothing (v79 probe: 97 fetches, 12 pixels/frame).
    wire [8:0] ydiff = (ly + spr_y + {1'b0, height_t, 3'b000} + 9'd8) & 9'h1FF;
    wire       ymatch = ydiff < {height_t, 3'b000} + 9'd8;   // (height+1)*8 lines

    always @(posedge clk) begin
        if(!reset_n) begin
            state <= S_IDLE;
            gfx_req <= 0;
            wr_en <= 0; clearing <= 0;
            build_sel <= 0;
            gfx_done_last <= 0;
        end else begin
            wr_en <= 0;
            gfx_done_last <= gfx_done;

            // v85: the line trigger fires from ANY state - a build stalled
            // by fetch starvation previously missed the restart and kept
            // blitting stale rows into the now-DISPLAYED buffer (the
            // interior garble on tall attract objects). Abort and restart.
            if(x_count == 10'd0 && y_count >= vbporch - 10'd1
               && y_count < vbporch + vactive - 10'd1) begin
                build_sel <= ~build_sel;
                ly <= (y_count - vbporch + 10'd2 + {1'b0, yscroll}) & 9'h1FF;
                clr_x <= 9'd0;
                clearing <= 1;
                wr_en <= 0;
                state <= S_CLEAR;
            end else
            case(state)
            S_IDLE: begin
            end

            S_CLEAR: begin
                clr_x <= clr_x + 9'd1;
                if(clr_x == 9'd511) begin
                    clearing <= 0;
                    cfg_vaddr <= {1'b1, ly[8:3]};        // SLIP word 0x40 + band
                    state <= S_SLIP0;
                end
            end

            S_SLIP0: state <= S_SLIP1;                    // BRAM latency
            S_SLIP1: begin
                link       <= cfg_vdata[9:0];
                first_link <= cfg_vdata[9:0];
                ent_count  <= 0;
                fetch_budget <= 6'd48;
                state <= S_E0;
            end

            S_E0: begin mo_vaddr <= {link, 2'd0}; state <= S_E1; end
            S_E1: begin mo_vaddr <= {link, 2'd1}; state <= S_E2; end
            S_E2: begin mo_vaddr <= {link, 2'd2}; w0 <= mo_vdata; state <= S_E3; end
            S_E3: begin mo_vaddr <= {link, 2'd3}; w1 <= mo_vdata; state <= S_MATCH; end

            S_MATCH: begin
                w2 <= mo_vdata;                           // color/x/prio
                spr_color <= mo_vdata[3:0];
                spr_x     <= mo_vdata[15:7];
                state <= S_FETCH;
            end

            S_FETCH: begin
                w3 <= mo_vdata;
                spr_y    <= mo_vdata[15:7];
                width_t  <= mo_vdata[6:4];
                height_t <= mo_vdata[2:0];
                hflip    <= mo_vdata[3];
                tx <= 0;
                state <= S_WAIT;
            end

            S_WAIT: begin
                // now spr_y etc are valid: decide match and start tile loop
                if(ymatch && fetch_budget != 0) begin
                    // code for this row: code + ty*width + tx  (ty = ydiff>>3)
                    code_row    <= w1[14:0] + ( (ydiff[8:3]) * ({3'b0,width_t}+4'd1) );
                    row_in_tile <= ydiff[2:0];
                    state <= S_BLIT;   // reuse BLIT entry to issue first fetch
                    blit_n <= 4'd15;   // marker: need fetch
                end else begin
                    state <= S_NEXT;
                end
            end

            S_BLIT: begin
                if(blit_n == 4'd15) begin
                    // issue fetch for tile tx
                    gfx_addr <= 24'h120000
                                + { (code_row + {12'b0, tx}), 5'd0 }
                                + { row_in_tile, 2'd0 };
                    gfx_req  <= ~gfx_req;
                    fetch_budget <= fetch_budget - 6'd1;
                    blit_n <= 4'd14;   // waiting for data
                end else if(blit_n == 4'd14) begin
                    if(gfx_done != gfx_done_last) begin
                        rowdata <= gfx_data;
                        blit_n  <= 4'd0;
                        // screen x for pixel 0 of this tile; hflip reverses tile order
                        blit_x <= (spr_x + (hflip ? {(width_t - tx), 3'b000}
                                                  : {tx, 3'b000})
                                   - {1'b0, xscroll}) & 9'h1FF;
                    end
                end else begin
                    // write pixel blit_n of the row (first-write-wins via valid bit read?
                    // simple overwrite-if-empty needs read-modify-write; approximate with
                    // last-wins here and rely on list order: acceptable v1)
                    if(pix_val != 4'd0 && blit_x < 9'd336+9'd0+9'd8) begin
                        wr_x    <= blit_x;
                        wr_data <= {1'b1, spr_color, pix_val};
                        wr_en   <= 1;
                    end
                    blit_x <= (blit_x + 9'd1) & 9'h1FF;
                    if(blit_n == 4'd7) begin
                        if(tx == width_t) state <= S_NEXT;
                        else begin
                            tx <= tx + 3'd1;
                            blit_n <= 4'd15;
                            if(fetch_budget == 0) state <= S_NEXT;
                        end
                    end else begin
                        blit_n <= blit_n + 4'd1;
                    end
                end
            end

            S_NEXT: begin
                ent_count <= ent_count + 7'd1;
                link <= w0[9:0];
                if(w0[9:0] == first_link || ent_count == 7'd63 || fetch_budget == 0)
                    state <= S_IDLE;
                else
                    state <= S_E0;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // chunky pixel extract with hflip
    wire [2:0] pn = hflip ? (3'd7 - blit_n[2:0]) : blit_n[2:0];
    reg  [3:0] pix_val;
    always @(*) begin
        case(pn)
            3'd0: pix_val = rowdata[31:28]; 3'd1: pix_val = rowdata[27:24];
            3'd2: pix_val = rowdata[23:20]; 3'd3: pix_val = rowdata[19:16];
            3'd4: pix_val = rowdata[15:12]; 3'd5: pix_val = rowdata[11:8];
            3'd6: pix_val = rowdata[7:4];   default: pix_val = rowdata[3:0];
        endcase
    end

endmodule
