#
# user core constraints
#
# sdram-sched: the four PLL outputs are one clock family (same refclk, same
# PLL - 85.909MHz = exactly 12 x 7.159MHz). Grouped SYNCHRONOUS, every
# CPU<->SDRAM crossing becomes a timed path, legalizing single-cycle
# handshakes in place of 3-stage synchronizer chains.
# put your clock groups in here as well as any net assignments
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } 
