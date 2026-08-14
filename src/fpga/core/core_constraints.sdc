#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } 

# --- SDRAM interface constraints (experimental branch) ---
# MT48LC16M16A2-7E @ 85.9 MHz CL2. The interface was previously entirely
# unconstrained: Quartus never analyzed the DQ capture window, so read
# margin floated with every placement (the residual corruption class).
create_generated_clock -name sdram_chip_clk \
  -source [get_pins -compatibility_mode {*mf_pllbase_inst*general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {dram_clk}]
# reads: tAC(CL2)=7.5ns max, tOH=2.7ns min (+~0.3ns board)
set_input_delay  -clock sdram_chip_clk -max 7.8 [get_ports {dram_dq[*]}]
set_input_delay  -clock sdram_chip_clk -min 2.7 [get_ports {dram_dq[*]}]
# writes/control: tIS=1.5ns, tIH=0.8ns
set_output_delay -clock sdram_chip_clk -max 1.5 [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_cke}]
set_output_delay -clock sdram_chip_clk -min -0.8 [get_ports {dram_dq[*] dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_cke}]
