# Dump the worst setup/hold paths so timing failures can be diagnosed from a
# CI log instead of guessed at. Run with:
#   quartus_sta -t timing_report.tcl Arcade-Escape
project_open Arcade-Escape
create_timing_netlist
read_sdc
update_timing_netlist

set core0 {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set core1 {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}

puts "=========== WORST SETUP PATHS (any clock) ==========="
report_timing -setup -npaths 10 -detail summary -panel_name {} -stdout

puts "=========== WORST SETUP: 7.16MHz -> 35.8MHz ==========="
report_timing -setup -npaths 5 -detail full_path -stdout \
    -from_clock [get_clocks $core0] -to_clock [get_clocks $core1]

puts "=========== WORST SETUP: 35.8MHz -> 35.8MHz ==========="
report_timing -setup -npaths 3 -detail summary -stdout \
    -from_clock [get_clocks $core1] -to_clock [get_clocks $core1]

puts "=========== WORST SETUP: SDRAM_CLK -> 35.8MHz ==========="
report_timing -setup -npaths 3 -detail summary -stdout \
    -from_clock [get_clocks SDRAM_CLK] -to_clock [get_clocks $core1]

puts "=========== WORST HOLD PATHS (any clock) ==========="
report_timing -hold -npaths 10 -detail summary -stdout

puts "=========== WORST HOLD: SDRAM_CLK -> 35.8MHz ==========="
report_timing -hold -npaths 5 -detail full_path -stdout \
    -from_clock [get_clocks SDRAM_CLK] -to_clock [get_clocks $core1]

puts "=========== WORST HOLD: 7.16MHz -> 35.8MHz ==========="
report_timing -hold -npaths 5 -detail full_path -stdout \
    -from_clock [get_clocks $core0] -to_clock [get_clocks $core1]

project_close
