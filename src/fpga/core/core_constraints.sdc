#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

# sdram-sched: the four PLL outputs are one clock family (same refclk,
# same PLL - 85.909MHz = exactly 12 x 7.159MHz). Grouping them SYNCHRONOUS
# makes every CPU<->SDRAM crossing a timed path, which legalizes
# single-cycle handshakes in place of 3-stage synchronizer chains (the
# ack-return chain alone cost ~2 CPU clocks per SDRAM access).
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp1|mf_pllbase_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } 
