// sdram_model_mem: the MEMORY-BACKED SDRAM model, for benches that must render
// real image data (tb_mister_pf).
//
// MERGE-117: this used to be called `sdram_model`, and the Pocket open-row work
// independently added a DIFFERENT model under that same name. They are not
// substitutes and neither could replace the other:
//
//   * sdram_model      - no storage at all. Returns a hash of the full 24-bit
//                        word address, served FROM THE PHYSICALLY OPEN ROW, so
//                        a controller that reads the wrong row is caught on
//                        every access rather than sampled. Plus a JEDEC timing
//                        checker. Cannot hold an image.
//   * sdram_model_mem  - a real `reg [15:0] mem [0:WORDS-1]`, loadable, which
//                        is what a bench needs to prove pixels come out right.
//                        No protocol checking.
//
// Keeping both under distinct names is deliberate: collapsing them would cost
// one of the two properties, and each is the only thing proving what it proves.
//
// Behavioural MT48LC16M16A2-class SDRAM, enough of one to close the loop
// around rtl/sdram_simple.v in simulation: ACTIVE / READ / WRITE / PRECHARGE /
// REFRESH, CL2, single-location accesses (sdram_simple issues two back-to-back
// single reads, not a hardware burst).
//
// The model captures commands on posedge and presents read data one model
// clock later.  sdram_simple drives its command pins with NONBLOCKING
// assignments and the real board runs the chip clock 90 degrees late, so one
// model clock of skew here is the same sampling point the hardware has.
// The bench proves the model is calibrated by reading back a known pattern
// through the CPU port (SDMODEL check) - if the latency were wrong that
// check fails, which is what makes it a check.
`default_nettype none

module sdram_model_mem #(
    parameter WORDS = 25'h0120000        // 16-bit words backed (covers the image)
) (
    input  wire        clk,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    inout  wire [15:0] dq,
    input  wire [1:0]  dqm,
    input  wire        cas_n,
    input  wire        ras_n,
    input  wire        we_n,
    input  wire        cke
);
    reg [15:0] mem [0:WORDS-1];
    reg [12:0] row [0:3];

    reg [15:0] dout;
    reg        doe = 1'b0;
    assign dq = doe ? dout : 16'hZZZZ;

    // command decode: {ras,cas,we}
    wire [2:0] cmd = {ras_n, cas_n, we_n};
    localparam C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101,
               C_WR  = 3'b100, C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;

    integer i;
    initial begin
        for (i = 0; i < 4; i = i + 1) row[i] = 13'd0;
    end

    wire [23:0] full = {ba, row[ba], a[8:0]};

    always @(posedge clk) begin
        doe <= 1'b0;
        if (cke) begin
            case (cmd)
            C_ACT: row[ba] <= a;
            C_RD: begin
                dout <= (full < WORDS) ? mem[full] : 16'hDEAD;
                doe  <= 1'b1;
            end
            C_WR: begin
                if (full < WORDS) begin
                    if (!dqm[1]) mem[full][15:8] <= dq[15:8];
                    if (!dqm[0]) mem[full][7:0]  <= dq[7:0];
                end
            end
            default: ;
            endcase
        end
    end
endmodule

`default_nettype wire
