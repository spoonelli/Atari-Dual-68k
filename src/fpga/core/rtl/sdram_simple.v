//
// Minimal single-beat SDRAM controller for the MT48LC16M16A2 (16-bit),
// running in the 35.795455 MHz SDRAM domain. Two clients over 4-phase
// toggle-free level handshakes (both synchronized externally):
//   - write port: ROM download from the APF bridge
//   - read port:  escape_core program-ROM fetches
// Conservative timing (CL2, tRCD/tRP 3 cycles).
// Word-addressed externally? No — byte addresses in, we use addr[24:1] as the
// 16-bit word address.
//
// CLKFIX-106/REFRESH-111: the header used to say "the 28.636 MHz SDRAM domain
// (4x CPU)". That is a THIRD wrong figure for this clock, alongside the 85.909
// that CLKFIX-106 removed elsewhere. The authority is the PLL IP itself:
// src/fpga/core/mf_pllbase/mf_pllbase_0002.v declares
// output_clock_frequency2 = "35.795455 MHz", and core_top wires outclk_2 to
// clk_sdram. Period 27.936508 ns. Quote the PLL, not a neighbouring comment.
//
`default_nettype none

module sdram_simple #(
    // REFRESH-111: these were hardcoded, and three branches then hardcoded
    // three DIFFERENT values (Pocket 160, mister-port 224, sdram-sched 250
    // with the deferral deleted) for the same JEDEC violation. Parameterising
    // them is the reconciliation: one source of truth for the FSM, per-platform
    // values chosen at instantiation and visible side by side. See
    // docs/DEVIATIONS.md "SDRAM refresh interval" before changing either.
    //
    //   REFRESH_INTERVAL - clocks between refresh requests.
    //   DEFER_CAP        - SDSCHED-88 bounded deferral: a due refresh yields to
    //                      a pending read until it has been due this many
    //                      clocks. 0 disables the deferral entirely.
    //
    // Worst-case row interval is NOT interval+DEFER_CAP: the FSM must also
    // finish whatever transaction is in flight when the cap expires, and clear
    // the read ack. It is interval+DEFER_CAP+16, measured by
    // sim/tb/tb_sdram_refresh.v, which is the only thing that should be used to
    // justify a value here.
    parameter REFRESH_INTERVAL = 160,
    parameter DEFER_CAP        = 48
) (
    input  wire        clk,           // 35.795455 MHz (mf_pllbase outclk_2)
    input  wire        reset_n,

    // SDRAM chip
    output reg  [12:0] dram_a,
    output reg  [1:0]  dram_ba,
    inout  wire [15:0] dram_dq,
    output reg  [1:0]  dram_dqm,
    output reg         dram_cas_n,
    output reg         dram_ras_n,
    output reg         dram_we_n,
    output reg         dram_cke,

    // write client (level req / level ack, 4-phase)
    // 32-bit burst: wr_data[31:16] -> wr_addr, wr_data[15:0] -> wr_addr+2
    // (addresses are 32-bit aligned, so both words share one row)
    input  wire        wr_req,
    output reg         wr_ack,
    input  wire [24:0] wr_addr,       // byte address, bit0 ignored
    input  wire [31:0] wr_data,

    // read client (level req / level ack, 4-phase)
    input  wire        rd_req,
    output reg         rd_ack,
    input  wire [24:0] rd_addr,
    input  wire        rd_pre,    // v42: precharge-all armor for this read
    output reg  [31:0] rd_data,   // burst of 2: [31:16]=addr word, [15:0]=addr+2

    output reg         init_done
);

    // dq tristate
    reg  [15:0] dq_out;
    reg         dq_oe;
    assign dram_dq = dq_oe ? dq_out : 16'hZZZZ;

    // address split: {ba[1:0], row[12:0], col[8:0]} from word address [23:0]
    wire [23:0] wr_word = wr_addr[24:1];
    wire [23:0] rd_word = rd_addr[24:1];

    localparam CMD_NOP      = 3'b111;  // {ras,cas,we}
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
    reg [5:0]  refresh_age;    // SDSCHED-88: clocks spent due (deferral bound)
    reg [23:0] word;
    reg        is_write;
    reg [31:0] wdata_l;

    localparam S_INIT      = 4'd0;
    localparam S_IDLE      = 4'd1;
    localparam S_ACTIVE    = 4'd2;
    localparam S_RW        = 4'd3;
    localparam S_CL        = 4'd4;
    localparam S_DATA      = 4'd5;
    localparam S_PRECHG    = 4'd6;
    localparam S_PREALL    = 4'd11;  // v40: precharge-all before ACT (v44: was 4'd8, COLLIDED with S_WR2 - every write burst derailed into the precharge arm, corrupting all downloads since v40)
    localparam S_REFRESH   = 4'd7;
    localparam S_WR2       = 4'd8;
    localparam S_RD2       = 4'd9;
    localparam S_DATA1     = 4'd10;

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
            refresh_age<= 6'd0;
            cmd(CMD_NOP);
        end else begin
            cmd(CMD_NOP);
            refresh_ctr <= refresh_ctr + 10'd1;
            // CLKFIX-106: this clock is 35.795455 MHz (mf_pllbase outclk_2), NOT
            // the 85.909 the old comment assumed -- a period of 27.94ns, not
            // 11.64ns. At the original 250 the interval was really 6.98us
            // typical, and the deferral below pushed the worst case past the
            // 7.8125us JEDEC per-row limit: a latent retention violation on the
            // memory holding sprite graphics and CPU RAM.
            //
            // REFRESH-111: the arithmetic everyone used to justify a
            // replacement value was wrong in the SAFE-LOOKING direction. It
            // assumed worst case = REFRESH_INTERVAL + DEFER_CAP. It is not.
            // When the deferral cap expires the FSM may be part-way through a
            // transaction, and a precharge-armored CPU read (rd_pre) takes 15
            // clocks; the read-ack cleanup in S_IDLE costs one more. So the
            // true worst case is REFRESH_INTERVAL + DEFER_CAP + 16, measured
            // by sim/tb/tb_sdram_refresh.v against the real FSM rather than
            // computed on paper. Do not re-derive it by hand; run the bench.
            if (refresh_ctr == REFRESH_INTERVAL[9:0]) begin
                refresh_due <= 1'b1;
                refresh_ctr <= 10'd0;
            end
            if (refresh_due) begin
                if (refresh_age != 6'd63) refresh_age <= refresh_age + 6'd1;
            end else
                refresh_age <= 6'd0;

            case (state)
            S_INIT: begin
                init_ctr <= init_ctr + 16'd1;
                dram_cke <= 1'b1;
                // >100us powerup = 8600 cycles; then precharge-all, 2 refresh, mode
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
                if (wr_ack && ~wr_req) wr_ack <= 1'b0;      // finish 4-phase
                else if (rd_ack && ~rd_req) rd_ack <= 1'b0;
                // SDSCHED-88: a refresh DEFERS (bounded) to a pending read -
                // the zero-wait CPU fastpath budgets ~24 spare clocks per bus
                // cycle and a 10-clk tRFC in front of the fill blows it.
                // REFRESH-111: the justification here used to read "the 250-clk
                // interval is 2.9us against the 7.8us/row spec, so even the
                // 63-clk deferral cap keeps >2x margin". Both halves were
                // wrong: 250 clocks is 6.98us not 2.9us (that was the 85.909MHz
                // arithmetic), the cap that acts is DEFER_CAP not the 63 the
                // age counter saturates at, and the margin was negative, not
                // 2x. The deferral is kept because the fastpath needs it; the
                // interval is what was made to pay for it.
                else if (refresh_due && ((DEFER_CAP == 0) || !(rd_req && ~rd_ack)
                                         || refresh_age >= DEFER_CAP[5:0])) begin
                    cmd(CMD_REFRESH);
                    refresh_due <= 1'b0;
                    wait_ctr <= 4'd9;                        // tRFC
                    state <= S_REFRESH;
                end else if (wr_req && ~wr_ack) begin
                    // writes stay on the fast path: the wrong-row serve is a
                    // READ phenomenon, and the ROM download (bridge writes,
                    // no backpressure) can't afford +3 cycles per word -
                    // v40's precharge-all on writes starved it -> black screen
                    word <= wr_word; wdata_l <= wr_data; is_write <= 1'b1;
                    cmd(CMD_ACTIVE);
                    dram_ba <= wr_word[23:22];
                    dram_a  <= wr_word[21:9];
                    wait_ctr <= 4'd2;                        // tRCD
                    state <= S_ACTIVE;
                end else if (rd_req && ~rd_ack) begin
                    word <= rd_word; is_write <= 1'b0;
                    if (rd_pre) begin
                        // CPU reads: close any open row first (wrong-row serve)
                        cmd(CMD_PRECHG);
                        dram_a[10] <= 1'b1;
                        wait_ctr <= 4'd2;
                        state <= S_PREALL;
                    end else begin
                        // video/scrub reads: fast path (scanline deadlines)
                        cmd(CMD_ACTIVE);
                        dram_ba <= rd_word[23:22];
                        dram_a  <= rd_word[21:9];
                        wait_ctr <= 4'd2;
                        state <= S_ACTIVE;
                    end
                end
            end

            S_PREALL: begin
                wait_ctr <= wait_ctr - 4'd1;
                if (wait_ctr == 0) begin
                    cmd(CMD_ACTIVE);
                    dram_ba <= word[23:22];
                    dram_a  <= word[21:9];
                    wait_ctr <= 4'd3;                        // tRCD +1 margin (v40)
                    state <= S_ACTIVE;
                end
            end

            S_ACTIVE: begin
                wait_ctr <= wait_ctr - 4'd1;
                if (wait_ctr == 0) state <= S_RW;
            end

            S_RW: begin
                dram_a       <= {4'b0010, word[8:0]};        // A10=1: auto-precharge
                if (is_write) begin
                    cmd(CMD_WRITE);
                    dram_a <= {4'b0000, word[8:0]};          // first word: NO auto-precharge
                    dq_out <= wdata_l[31:16];
                    dq_oe  <= 1'b1;
                    state <= S_WR2;
                end else begin
                    cmd(CMD_READ);
                    dram_a <= {4'b0000, word[8:0]};          // first read: NO auto-precharge
                    state <= S_RD2;
                end
            end

            S_RD2: begin
                cmd(CMD_READ);
                dram_a <= {4'b0010, word[8:1], 1'b1};        // col+1, auto-precharge
                state <= S_DATA;                              // CL2: data0 next cycle
            end

            S_WR2: begin
                cmd(CMD_WRITE);
                dram_a <= {4'b0010, word[8:1], 1'b1};        // second word: col+1, auto-precharge
                dq_out <= wdata_l[15:0];
                dq_oe  <= 1'b1;
                wait_ctr <= 4'd3;                            // tWR + tRP
                state <= S_PRECHG;
            end

            S_DATA: begin
                rd_data[31:16] <= dram_dq;                   // data0
                state <= S_DATA1;
            end

            S_DATA1: begin
                rd_data[15:0] <= dram_dq;                    // data1
                rd_ack  <= 1'b1;
                wait_ctr <= 4'd2;                            // tRP after auto-precharge
                state <= S_PRECHG;
            end

            S_PRECHG: begin
                dq_oe <= 1'b0;
                if (is_write && wait_ctr == 4'd1) wr_ack <= 1'b1;
                wait_ctr <= wait_ctr - 4'd1;
                if (wait_ctr == 0) state <= S_IDLE;
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
