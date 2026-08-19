// Hall-effect joystick emulator. The real cabinet gives each player a 2-axis
// hall-effect stick whose axes feed the ADC0809 in escape_core; the Pocket has
// a d-pad. A held d-pad direction reads as the stick held at the stop
// (0x00/0xFF), released reads centered (0x80) — absolute positions, exactly
// like the physical stick. If the analog stick (dock / wired controller) is
// deflected it takes priority over the d-pad, so dock users get true analog
// with no config option. X axes are reversed on the real harness (full right
// = 0x00, per MAME's PORT_REVERSE on ADC1/ADC3), so targets are pre-reversed
// here; escape_core's ADC model digitizes exactly what it is handed.
module hall_stick (
    input  wire       clk,        // 7.159 MHz core clock
    input  wire       up,         // d-pad, active high (async; synced here)
    input  wire       down,
    input  wire       left,
    input  wire       right,
    input  wire       inv_x,      // config: invert axes (Interact menu)
    input  wire       inv_y,
    input  wire       swap_xy,    // config: swap analog axes (dock variance)
    input  wire [4:0] deadzone,   // config: analog deadzone, counts from center
    input  wire       has_analog, // documented APF type field says a docked
                                  // controller (type >= 2) is connected
    input  wire [7:0] joy_x,      // APF analog stick, unsigned, 0x80 center
    input  wire [7:0] joy_y,      //   (0x00 = left/up, 0xFF = right/down)
    output reg  [7:0] adc_x = 8'h80,   // to ADC0809 IN1/IN3 (0x00 = full right)
    output reg  [7:0] adc_y = 8'h80    // to ADC0809 IN0/IN2 (0x00 = full up)
);

// 2FF synchronizers; the slew stepper below also rides out any mid-flight
// analog bytes (a one-step wrong sample moves the axis by at most 1 count)
reg [3:0] pad_m = 4'b0000, pad_s = 4'b0000;   // {right, left, down, up}
reg [7:0] jx_m = 8'h80, jx_s = 8'h80;
reg [7:0] jy_m = 8'h80, jy_s = 8'h80;
always @(posedge clk) begin
    pad_m <= {right, left, down, up};  pad_s <= pad_m;
    jx_m  <= swap_xy ? joy_y : joy_x;  jx_s  <= jx_m;
    jy_m  <= swap_xy ? joy_x : joy_y;  jy_s  <= jy_m;
end

// LANE3p: ANALOG PRESENCE, not just deflection. An undocked Pocket sends
// joy = 0x00/0x00 (no stick fitted) - the old check read exact zero as a
// full-corner deflection and JAMMED the game's stick at left+down (the
// held directions in the self-test Control Inputs screen, and a likely
// gameplay killer). Exact (0,0) means "absent": a real stick pinned to
// the exact corner momentarily just falls back to the d-pad for a frame.
// presence: the documented cont_key[31:28] type field (>=2 = docked pad
// with possible analog) gated by the exact-zero guard (absent stick data)
wire joy_present = has_analog && !(jx_s == 8'h00 && jy_s == 8'h00);
wire [7:0] dz_hi = 8'h80 + {3'b000, deadzone};
wire [7:0] dz_lo = 8'h80 - {3'b000, deadzone};
wire joy_live = joy_present &&
             ( (jx_s > dz_hi) || (jx_s < dz_lo)
            || (jy_s > dz_hi) || (jy_s < dz_lo) );

// target position: analog stick wins, else d-pad absolutes; menu inverts
wire [7:0] tgt_x_raw = joy_live ? ~jx_s      // reverse: right = low
                 : pad_s[3] ? 8'h00          // d-pad right -> full right
                 : pad_s[2] ? 8'hFF          // d-pad left
                 : 8'h80;
wire [7:0] tgt_y_raw = joy_live ? jy_s
                 : pad_s[0] ? 8'h00          // d-pad up -> full up
                 : pad_s[1] ? 8'hFF          // d-pad down
                 : 8'h80;
wire [7:0] tgt_x = inv_x ? ~tgt_x_raw : tgt_x_raw;
wire [7:0] tgt_y = inv_y ? ~tgt_y_raw : tgt_y_raw;

// subtle slew toward the target — a physical stick takes a moment to travel.
// One step per 256 clocks = ~4.6 ms center-to-stop at 7.159 MHz, well under
// a frame of extra latency but enough to look like a real deflection ramp.
reg [7:0] presc = 8'd0;
always @(posedge clk) begin
    presc <= presc + 8'd1;
    if (presc == 8'd0) begin
        if      (adc_x < tgt_x) adc_x <= adc_x + 8'd1;
        else if (adc_x > tgt_x) adc_x <= adc_x - 8'd1;
        if      (adc_y < tgt_y) adc_y <= adc_y + 8'd1;
        else if (adc_y > tgt_y) adc_y <= adc_y - 8'd1;
    end
end

endmodule
