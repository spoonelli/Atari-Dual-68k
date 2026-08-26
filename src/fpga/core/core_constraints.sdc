#
# user core constraints
#
# sdram-sched: the four PLL outputs are one clock family (same refclk, same
# PLL). LOWLAT-124: the SDRAM outputs run 42.954546 MHz = exactly 6 x
# 7.159091 MHz - still an INTEGER ratio, so the synchronous grouping stays
# valid (it was 5x). Grouped SYNCHRONOUS, every
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
