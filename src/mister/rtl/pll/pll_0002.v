// Escape (MiSTer) clock generator.
//
// Derived from the Altera PLL IP instance shipped with
// third_party/Arcade-Atari-system1_MiSTer (rtl/pll/pll_0002.v, GPL-2.0+),
// re-parameterised for this core. Only the output frequency/phase generics
// changed; the wrapper and .qip are otherwise the upstream files.
//
//   outclk_0 =  7.159091 MHz  CPU + pixel domain (Atari Escape native)
//   outclk_1 = 35.795455 MHz  SDRAM controller domain (exactly 5 x CPU)
//   outclk_2 = 35.795455 MHz  SDRAM chip clock, +90 deg (6984 ps)
//
// These are BIT-FOR-BIT the clock settings the Pocket build ships and that
// are proven on silicon (src/fpga/core/mf_pllbase/mf_pllbase_0002.v, after
// commits "v22: SDRAM 42.95 -> 35.8 MHz (5x CPU)" and "v45: SDRAM chip clock
// phase 180 -> 90 degrees").  The chip-clock phase was tuned empirically
// against sdram_simple's CL2 read FSM; the capture margin does NOT scale
// cleanly with frequency, so DO NOT raise the SDRAM clock without re-tuning
// the phase and proving reads on hardware.  See docs/MISTER.md "SDRAM".
`timescale 1ns/10ps
module  pll_0002(
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("7.159091 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("35.795455 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("35.795455 MHz"),
		.phase_shift2("6984 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
