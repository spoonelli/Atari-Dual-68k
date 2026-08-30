//
// sdram_openrow: MT48LC16M16A2 controller with an OPEN-ROW policy and
// per-client BANK INTERLEAVING. Drop-in port-compatible with sdram_simple.
//
// SEPARATE MODULE ON PURPOSE. sdram_simple.v carries five documented freeze
// fixes and ~25 builds of debugging; it is not edited here at all. This module
// sits beside it so the two can be A/B'd, and so a bad night's work cannot
// regress the shipping controller by accident.
//
// ---------------------------------------------------------------------------
// WHY BOTH CHANGES, AND WHY IN THIS ORDER
// ---------------------------------------------------------------------------
// Measured first (sim/run_sdram_traffic_tb.sh, Stage 1), against the real
// motion-object fetch stream and the real arbiter's access sequence:
//
//   row-hit rate an open-row policy would achieve, ALONE ......  6.7%
//   misses caused by CLIENT SWITCH ...........................  87.4%
//   misses caused by same-client stride ......................   0.2%
//   misses caused by refresh .................................   5.6%
//
// So open-row on its own is nearly worthless HERE, and the reason is the
// address map, not the policy. Every read client lives in bank 0:
//
//   video CPU program   image 0x000000-0x07FFFF
//   extra CPU program   image 0x080000-0x0FFFFF
//   sprite graphics     image 0x120000-0x21FFFF
//
// with `{ba,row,col} = {wa[23:22], wa[21:9], wa[8:0]}` and the whole 2.2 MB
// image fitting inside wa[20:0], so wa[23:22] is always 0 and three of four
// banks are dead. A row is 512 words = 1 KB of byte address, so no row can
// span two of those regions: EVERY client switch is necessarily a row miss.
// That is structural, not statistical, and it is why the hit rate is ~7%
// regardless of how good each client's own locality is (swept: 6.19% at
// CPU_ROW_RES=8 through 6.81% on the real captured trace - a 0.6-point spread).
//
// Give each client its own bank and a client switch stops closing anybody's
// row, because each bank keeps its own open row. Open-row is what makes a
// retained row useful; banking is what stops the clients evicting each other.
// Neither is worth much here without the other, so both are implemented, and
// both are independently switchable so they can be measured separately.
//
// ---------------------------------------------------------------------------
// THE BANK MAP, AND WHY ITS BLAST RADIUS IS SMALL
// ---------------------------------------------------------------------------
// The remap is applied identically to `wr_addr` and `rd_addr` INSIDE this
// module. The SDRAM image is created by the download writes themselves, so
// remapping both sides stores the image in the remapped layout and finds it
// there. The external byte-address contract is unchanged, which means:
//
//   NO change to support/build_rom.py, docs/ROMMAP.md, the MiSTer loader, or
//   any client's address arithmetic.
//
// The brief anticipated a wide blast radius across all of those. It is avoided
// entirely by doing the mapping here rather than in the image. The one thing
// that must stay true is that reads and writes use the SAME function - so it
// is one function, used by both, and the write/read-back path is gated by
// sim/run_sdram_model_tb.sh modes 6 and 7 (cross-bank write/read-back, and
// same-row read-after-write with no gap).
//
// Bank assignment (word addresses; byte = word*2):
//   bank 0  wa < 0x040000            video CPU program   (image 0x000000+)
//   bank 1  0x040000 <= wa < 0x080000  extra CPU program (image 0x080000+)
//   bank 2  0x080000 <= wa < 0x090000  JSA 6502 + chars  (image 0x100000+)
//   bank 3  wa >= 0x090000             sprite graphics   (image 0x120000+)
//
// row/col are wa[21:9]/wa[8:0] in BOTH modes - no offset arithmetic is needed,
// because every region is smaller than one bank (4M words) and the regions are
// already disjoint in wa[21:0]. The bank select is three 8-bit comparisons on
// wa[23:16]; the row and column wiring is bit-identical to sdram_simple's.
//
// ---------------------------------------------------------------------------
// TIMING. Which minimums are honoured and where the numbers come from.
// ---------------------------------------------------------------------------
// MT48LC16M16A2, -75 speed grade (the SLOWEST grade the part is offered in;
// no speed grade is recorded anywhere in this repo for the fitted part, so the
// conservative one is assumed - see sim/tb/sdram_model.v). At 35.795455 MHz
// the clock period is 27.936508 ns, so:
//
//   tRCD  ACTIVE -> READ/WRITE      20 ns  -> 1 clk   (T_RCD_CLK = 2, kept)
//   tRP   PRECHARGE -> ACTIVE       20 ns  -> 1 clk   (T_RP_CLK  = 2, kept)
//   tRAS  ACTIVE -> PRECHARGE (min) 45 ns  -> 2 clks  (T_RAS_CLK = 2)
//   tRC   ACTIVE -> ACTIVE same bk  65 ns  -> 3 clks  (implied by tRP+tRCD)
//   tRFC  REFRESH -> any command    66 ns  -> 3 clks  (T_RFC_CLK = 9, kept)
//   tRAS  max row-open time        120 us  -> 4295 clks
//
// The kept values are the ones sdram_simple ships; they are 2-3x the minimum
// and are left alone deliberately, because this module is already changing the
// row policy and shortening the waits at the same time would confound any
// hardware A/B. They are PARAMETERS IN CLOCKS so a clock change scales them
// explicitly rather than silently - which is the failure mode that put refresh
// 6.6% outside JEDEC spec for months (docs/investigations/RETROSPECTIVE.md section 5).
//
// tRAS(max) is the one new obligation an open-row policy takes on: a row may
// not stay open longer than 120 us. Refresh precharges all banks and runs
// every REFRESH_INTERVAL (160) clocks = 4.47 us typical, worst case measured
// at 224 clocks = 6.26 us, so a row can never be held even 6% of the limit.
// sim/tb/sdram_model.v checks tRAS(max) explicitly rather than assuming it.
//
// ---------------------------------------------------------------------------
// REFRESH AND THE OPEN ROW - the hazard that had to be got right
// ---------------------------------------------------------------------------
// AUTO REFRESH requires ALL banks precharged. An open row must never survive a
// refresh window. So S_IDLE, when it decides to refresh, issues PRECHARGE ALL
// first (if any bank is open), waits tRP, and only then issues AUTO REFRESH,
// clearing all four open-row registers as it goes. sim/tb/sdram_model.v
// reports `refresh_with_open_bank` and its own mutation gate proves that
// detector fires, so this is checked rather than argued.
//
// The refresh policy itself (REFRESH_INTERVAL / DEFER_CAP, and the fact that
// `refresh_due` is only consumed from S_IDLE so the true worst case is
// INTERVAL + DEFER_CAP + in-flight) is UNCHANGED from sdram_simple. Note the
// in-flight term gets SMALLER here, not larger: the longest transaction drops
// from 15 clocks to 11, and the extra PRECHARGE ALL before a refresh costs
// T_RP_CLK. sim/run_sdram_refresh_tb.sh measures it against this FSM, and both
// of its negative controls must still be rejected.
//
`default_nettype none

module sdram_openrow #(
    parameter REFRESH_INTERVAL = 160,
    parameter DEFER_CAP        = 48,
    // 1 = hold rows open across accesses. 0 = precharge every access, which
    // reproduces sdram_simple's policy and exists so the two halves of this
    // change can be measured apart.
    parameter OPENROW_EN       = 1,
    // 1 = per-client bank interleaving (see the map above). 0 = sdram_simple's
    // {ba,row,col} = {wa[23:22], wa[21:9], wa[8:0]}, i.e. everything in bank 0.
    parameter BANKMAP_EN       = 1,
    // MISTER-150: route byte window 0x600000-0x6FFFFF (word 0x300000-0x37FFFF)
    // to bank 2 - the MO tile MIRROR. Bank 2's real tenants (JSA + chars,
    // rows 0x400-0x47F) are BRAM-shadowed after boot, so the bank sits cold;
    // the mirror occupies rows 0x1800-0x1BFF, no overlap. Off by default:
    // the Pocket's map is untouched (constant-folds away at 0).
    parameter MIRROR_BANK2_EN  = 0,
    // Device minimums in CLOCKS at the target clock. See the timing block above.
    parameter T_RCD_CLK        = 2,
    parameter T_RP_CLK         = 2,
    parameter T_RAS_CLK        = 2,
    parameter T_RFC_CLK        = 9
) (
    input  wire        clk,
    input  wire        reset_n,

    output reg  [12:0] dram_a,
    output reg  [1:0]  dram_ba,
    inout  wire [15:0] dram_dq,
    output reg  [1:0]  dram_dqm,
    output reg         dram_cas_n,
    output reg         dram_ras_n,
    output reg         dram_we_n,
    output reg         dram_cke,

    input  wire        wr_req,
    output reg         wr_ack,
    input  wire [24:0] wr_addr,
    input  wire [31:0] wr_data,

    input  wire        rd_req,
    output reg         rd_ack,
    input  wire [24:0] rd_addr,
    input  wire        rd_pre,     // accepted for port compatibility; see below
    output reg  [31:0] rd_data,

    output reg         init_done
);

    reg  [15:0] dq_out;
    reg         dq_oe;
    assign dram_dq = dq_oe ? dq_out : 16'hZZZZ;

    wire [23:0] wr_word = wr_addr[24:1];
    wire [23:0] rd_word = rd_addr[24:1];

    // ---- the address map -------------------------------------------------
    // ONE function, used for both the read and the write path. If these two
    // ever diverge the download writes to one place and the CPU reads another,
    // which is a silent whole-image corruption - so they are not allowed to be
    // two functions.
    function [1:0] bank_of(input [23:0] wa);
        begin
            if (BANKMAP_EN == 0)          bank_of = wa[23:22];
            else if (MIRROR_BANK2_EN != 0
                     && wa[23:16] >= 8'h30
                     && wa[23:16] <  8'h38) bank_of = 2'd2;  // MO tile mirror
            else if (wa[23:16] < 8'h04)   bank_of = 2'd0;   // video CPU program
            else if (wa[23:16] < 8'h08)   bank_of = 2'd1;   // extra CPU program
            else if (wa[23:16] < 8'h09)   bank_of = 2'd2;   // JSA 6502 + chars
            else                          bank_of = 2'd3;   // sprite graphics
        end
    endfunction
    function [12:0] row_of(input [23:0] wa);
        begin
            row_of = wa[21:9];
        end
    endfunction

    localparam CMD_NOP      = 3'b111;
    localparam CMD_ACTIVE   = 3'b011;
    localparam CMD_READ     = 3'b101;
    localparam CMD_WRITE    = 3'b100;
    localparam CMD_PRECHG   = 3'b010;
    localparam CMD_REFRESH  = 3'b001;
    localparam CMD_MODE     = 3'b000;

    task cmd(input [2:0] c);
        begin
            dram_ras_n <= c[2];
            dram_cas_n <= c[1];
            dram_we_n  <= c[0];
        end
    endtask

    reg [15:0] init_ctr;
    reg [3:0]  state;
    reg [3:0]  wait_ctr;
    reg [9:0]  refresh_ctr;
    reg        refresh_due;
    // DEFERCAP-WIDTH: 7 bits, not the 6 sdram_simple uses. DEFER_CAP is a
    // PARAMETER compared as DEFER_CAP[5:0] there, so any value >= 64 silently
    // wraps - 67 becomes 3, 70 becomes 6 - and the deferral looks configured
    // while being almost entirely absent. Harmless at the shipping 48, and it
    // stops being harmless the moment the clock changes, because DEFER_CAP is
    // counted in CLOCKS and scaling it for a faster clock is what pushes it
    // past 63. Found on sdram-clock-EXPERIMENTAL, where scaling 48 -> 67 for
    // 50.113637 MHz produced a measured worst-case refresh gap of 372 clocks
    // against a paper prediction of 436; widening the counter made the two
    // agree exactly. Fixed here too so the trap is not re-inherited.
    reg [6:0]  refresh_age;
    reg [23:0] word;
    reg        is_write;
    reg [31:0] wdata_l;

    // per-bank open-row registers - the whole point of the module
    reg [3:0]  bk_act;
    reg [12:0] bk_row [0:3];
    reg [3:0]  ras_ctr;          // clocks since the most recent ACTIVE

    // state numbering deliberately does NOT reuse sdram_simple's, and every
    // value is distinct. (sdram_simple shipped a build where S_PREALL and
    // S_WR2 were both 4'd8 and every download was corrupted - v44.)
    localparam S_INIT      = 4'd0;
    localparam S_IDLE      = 4'd1;
    localparam S_ACTIVE    = 4'd2;
    localparam S_RW        = 4'd3;
    localparam S_RD2       = 4'd4;
    localparam S_WR2       = 4'd5;
    localparam S_DATA      = 4'd6;
    localparam S_DATA1     = 4'd7;
    localparam S_TAIL      = 4'd8;
    localparam S_PRE1      = 4'd9;    // precharge ONE bank, then re-activate
    localparam S_PREALL    = 4'd10;   // precharge ALL, then refresh
    localparam S_REFRESH   = 4'd11;

    wire [1:0]  rd_bank = bank_of(rd_word);
    wire [12:0] rd_row  = row_of(rd_word);
    wire [1:0]  wr_bank = bank_of(wr_word);
    wire [12:0] wr_row  = row_of(wr_word);

    // A row hit needs OPENROW_EN, the bank open, and the row to match. With
    // OPENROW_EN=0 these are always false and every access takes the
    // activate-read-precharge path, reproducing sdram_simple's policy.
    wire rd_hit = (OPENROW_EN != 0) && bk_act[rd_bank] && (bk_row[rd_bank] == rd_row);
    wire wr_hit = (OPENROW_EN != 0) && bk_act[wr_bank] && (bk_row[wr_bank] == wr_row);

    wire any_open = |bk_act;

    integer bi;

    always @(posedge clk) begin
        if (~reset_n) begin
            state      <= S_INIT;
            init_ctr   <= 16'd0;
            init_done  <= 1'b0;
            dram_cke   <= 1'b0;
            dram_dqm   <= 2'b11;
            dq_oe      <= 1'b0;
            wr_ack     <= 1'b0;
            rd_ack     <= 1'b0;
            refresh_ctr<= 10'd0;
            refresh_due<= 1'b0;
            refresh_age<= 7'd0;
            bk_act     <= 4'd0;
            ras_ctr    <= 4'd15;
            for (bi = 0; bi < 4; bi = bi + 1) bk_row[bi] <= 13'd0;
            cmd(CMD_NOP);
        end else begin
            cmd(CMD_NOP);
            refresh_ctr <= refresh_ctr + 10'd1;
            if (ras_ctr != 4'd15) ras_ctr <= ras_ctr + 4'd1;

            if (refresh_ctr == REFRESH_INTERVAL[9:0]) begin
                refresh_due <= 1'b1;
                refresh_ctr <= 10'd0;
            end
            if (refresh_due) begin
                if (refresh_age != 7'd127) refresh_age <= refresh_age + 7'd1;
            end else
                refresh_age <= 7'd0;

            case (state)
            S_INIT: begin
                init_ctr <= init_ctr + 16'd1;
                dram_cke <= 1'b1;
                if (init_ctr == 16'd9000) begin
                    cmd(CMD_PRECHG); dram_a[10] <= 1'b1;
                end else if (init_ctr == 16'd9010 || init_ctr == 16'd9030) begin
                    cmd(CMD_REFRESH);
                end else if (init_ctr == 16'd9060) begin
                    cmd(CMD_MODE);
                    dram_ba <= 2'b00;
                    dram_a  <= 13'b000_0_00_010_0_000;  // CL2, burst 1, sequential
                end else if (init_ctr == 16'd9080) begin
                    init_done <= 1'b1;
                    dram_dqm  <= 2'b00;
                    state     <= S_IDLE;
                end
            end

            S_IDLE: begin
                dq_oe <= 1'b0;
                if (wr_ack && ~wr_req) wr_ack <= 1'b0;
                else if (rd_ack && ~rd_req) rd_ack <= 1'b0;
                // Refresh, with the SAME bounded-deferral policy as
                // sdram_simple (SDSCHED-88 / REFRESH-111). Unchanged on
                // purpose: this module is not the place to re-litigate it.
                else if (refresh_due && ((DEFER_CAP == 0) || !(rd_req && ~rd_ack)
                                         || refresh_age >= DEFER_CAP[6:0])) begin
                    // AUTO REFRESH needs every bank precharged. If any row is
                    // open it MUST be closed first - this is the open-row
                    // hazard, and it is handled by construction rather than by
                    // hoping the row happens to be closed.
                    if (any_open && (ras_ctr >= T_RAS_CLK[3:0])) begin
                        cmd(CMD_PRECHG);
                        dram_a[10] <= 1'b1;          // all banks
                        bk_act     <= 4'd0;
                        wait_ctr   <= T_RP_CLK[3:0];
                        state      <= S_PREALL;
                    end else if (!any_open) begin
                        cmd(CMD_REFRESH);
                        refresh_due <= 1'b0;
                        wait_ctr    <= T_RFC_CLK[3:0];
                        state       <= S_REFRESH;
                    end
                    // else: a row is open but tRAS(min) has not elapsed. Wait
                    // here; the deferral bound is on refresh_age, which keeps
                    // counting, and tRAS is 2 clocks.
                end else if (wr_req && ~wr_ack) begin
                    word <= wr_word; wdata_l <= wr_data; is_write <= 1'b1;
                    if (wr_hit) begin
                        // row already open: go straight to the column command
                        cmd(CMD_WRITE);
                        dram_ba <= wr_bank;
                        dram_a  <= {4'b0000, wr_word[8:0]};
                        dq_out  <= wr_data[31:16];
                        dq_oe   <= 1'b1;
                        state   <= S_WR2;
                    end else if (bk_act[wr_bank] && (ras_ctr >= T_RAS_CLK[3:0])) begin
                        cmd(CMD_PRECHG);
                        dram_ba          <= wr_bank;
                        dram_a[10]       <= 1'b0;     // this bank only
                        bk_act[wr_bank]  <= 1'b0;
                        wait_ctr         <= T_RP_CLK[3:0];
                        state            <= S_PRE1;
                    end else if (!bk_act[wr_bank]) begin
                        cmd(CMD_ACTIVE);
                        dram_ba <= wr_bank;
                        dram_a  <= wr_row;
                        bk_act[wr_bank] <= 1'b1;
                        bk_row[wr_bank] <= wr_row;
                        ras_ctr  <= 4'd0;
                        wait_ctr <= T_RCD_CLK[3:0];
                        state    <= S_ACTIVE;
                    end
                end else if (rd_req && ~rd_ack) begin
                    word <= rd_word; is_write <= 1'b0;
                    // rd_pre is IGNORED here, deliberately. In sdram_simple it
                    // selects a precharge-all "armor" path added at v42 to
                    // defeat a wrong-row serve; core_top.v hardwires it to 1 at
                    // all four grant sites, so every read pays it. The armor
                    // was a workaround for not tracking which row was open.
                    // This module tracks it per bank, which is the actual fix,
                    // and the wrong-row serve is caught directly by
                    // sim/tb/sdram_model.v (mutation mode 1) rather than
                    // prevented by closing everything.
                    if (rd_hit) begin
                        cmd(CMD_READ);
                        dram_ba <= rd_bank;
                        dram_a  <= {4'b0000, rd_word[8:0]};
                        state   <= S_RD2;
                    end else if (bk_act[rd_bank] && (ras_ctr >= T_RAS_CLK[3:0])) begin
                        cmd(CMD_PRECHG);
                        dram_ba          <= rd_bank;
                        dram_a[10]       <= 1'b0;
                        bk_act[rd_bank]  <= 1'b0;
                        wait_ctr         <= T_RP_CLK[3:0];
                        state            <= S_PRE1;
                    end else if (!bk_act[rd_bank]) begin
                        cmd(CMD_ACTIVE);
                        dram_ba <= rd_bank;
                        dram_a  <= rd_row;
                        bk_act[rd_bank] <= 1'b1;
                        bk_row[rd_bank] <= rd_row;
                        ras_ctr  <= 4'd0;
                        wait_ctr <= T_RCD_CLK[3:0];
                        state    <= S_ACTIVE;
                    end
                end
            end

            // precharge of ONE bank done; now activate the row we actually want
            S_PRE1: begin
                wait_ctr <= wait_ctr - 4'd1;
                if (wait_ctr == 0) begin
                    cmd(CMD_ACTIVE);
                    dram_ba <= bank_of(word);
                    dram_a  <= row_of(word);
                    bk_act[bank_of(word)] <= 1'b1;
                    bk_row[bank_of(word)] <= row_of(word);
                    ras_ctr  <= 4'd0;
                    wait_ctr <= T_RCD_CLK[3:0];
                    state    <= S_ACTIVE;
                end
            end

            S_ACTIVE: begin
                wait_ctr <= wait_ctr - 4'd1;
                if (wait_ctr == 0) state <= S_RW;
            end

            S_RW: begin
                if (is_write) begin
                    cmd(CMD_WRITE);
                    dram_ba <= bank_of(word);
                    dram_a  <= {4'b0000, word[8:0]};
                    dq_out  <= wdata_l[31:16];
                    dq_oe   <= 1'b1;
                    state   <= S_WR2;
                end else begin
                    cmd(CMD_READ);
                    dram_ba <= bank_of(word);
                    dram_a  <= {4'b0000, word[8:0]};
                    state   <= S_RD2;
                end
            end

            // Second beat of the burst-of-2. A10 stays LOW: no auto-precharge,
            // because the row is being kept open. This is the one-line
            // difference that the whole policy hangs on, and it is why the
            // row-tracking above has to be right.
            S_RD2: begin
                cmd(CMD_READ);
                dram_ba <= bank_of(word);
                dram_a  <= {4'b0000, word[8:1], 1'b1};
                state   <= S_DATA;
            end

            S_WR2: begin
                cmd(CMD_WRITE);
                dram_ba  <= bank_of(word);
                dram_a   <= {4'b0000, word[8:1], 1'b1};
                dq_out   <= wdata_l[15:0];
                dq_oe    <= 1'b1;
                wait_ctr <= 4'd2;                   // tWR before anything else
                state    <= S_TAIL;
            end

            // SDSCHED-83: the capture timing relative to the READ command is
            // IDENTICAL to sdram_simple - READ issued two states before
            // S_DATA, rd_data[31:16] captured in S_DATA and [15:0] in S_DATA1.
            // The phase-dependent one-clock skew this design relies on is
            // therefore unchanged. Do not "tidy" these two states.
            S_DATA: begin
                rd_data[31:16] <= dram_dq;
                state <= S_DATA1;
            end

            S_DATA1: begin
                rd_data[15:0] <= dram_dq;
                rd_ack   <= 1'b1;
                state    <= S_IDLE;      // row stays OPEN - no precharge
            end

            S_TAIL: begin
                dq_oe <= 1'b0;
                if (is_write && wait_ctr == 4'd1) wr_ack <= 1'b1;
                wait_ctr <= wait_ctr - 4'd1;
                if (wait_ctr == 0) state <= S_IDLE;
            end

            S_PREALL: begin
                wait_ctr <= wait_ctr - 4'd1;
                if (wait_ctr == 0) begin
                    cmd(CMD_REFRESH);
                    refresh_due <= 1'b0;
                    wait_ctr    <= T_RFC_CLK[3:0];
                    state       <= S_REFRESH;
                end
            end

            S_REFRESH: begin
                wait_ctr <= wait_ctr - 4'd1;
                if (wait_ctr == 0) state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
