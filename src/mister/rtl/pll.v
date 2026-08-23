// Escape (MiSTer) PLL wrapper. See pll/pll_0002.v for the frequencies.
`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, //  7.159091 MHz  CPU/pixel
		output wire  outclk_1, // 57.272727 MHz  SDRAM controller
		output wire  outclk_2, // 57.272727 MHz  SDRAM chip clock (90 deg lag)
		output wire  locked
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.locked   (locked)
	);

endmodule
