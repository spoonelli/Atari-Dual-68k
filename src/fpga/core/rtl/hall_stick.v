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
    jx_m  <= joy_x;                    jx_s  <= jx_m;
    jy_m  <= joy_y;                    jy_s  <= jy_m;
end

// analog stick deflected? (small deadzone so a centered stick never fights
// the d-pad); either live axis hands the whole stick to analog
wire joy_live = (jx_s > 8'h88) || (jx_s < 8'h78)
             || (jy_s > 8'h88) || (jy_s < 8'h78);

// target position: analog stick wins, else d-pad absolutes
wire [7:0] tgt_x = joy_live ? ~jx_s          // reverse: right = low
                 : pad_s[3] ? 8'h00          // d-pad right -> full right
                 : pad_s[2] ? 8'hFF          // d-pad left
                 : 8'h80;
wire [7:0] tgt_y = joy_live ? jy_s
                 : pad_s[0] ? 8'h00          // d-pad up -> full up
                 : pad_s[1] ? 8'hFF          // d-pad down
                 : 8'h80;

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
