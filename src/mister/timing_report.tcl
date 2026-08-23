# Dump the worst setup/hold paths so timing failures get diagnosed from data
# instead of guessed at. Run with:
#   quartus_sta -t timing_report.tcl Arcade-Escape
#
# Every report is wrapped in `catch` on purpose: a single unsupported option
# would otherwise abort the whole script and cost a 30-minute CI round trip
# for no information.

project_open Arcade-Escape
create_timing_netlist
read_sdc
update_timing_netlist

set core0 {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set core1 {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}

proc show {label args} {
    puts "\n=========== $label ==========="
    if {[catch {eval report_timing $args} err]} {
        puts "report_timing failed: $err"
    }
}

show "WORST SETUP, ALL CLOCKS"          -setup -npaths 12 -detail summary -stdout
show "WORST SETUP 7.16MHz -> 35.8MHz"   -setup -npaths 4 -detail full_path -stdout \
        -from_clock [list $core0] -to_clock [list $core1]
show "WORST SETUP 35.8MHz -> 35.8MHz"   -setup -npaths 3 -detail summary -stdout \
        -from_clock [list $core1] -to_clock [list $core1]
show "WORST SETUP SDRAM_CLK -> 35.8MHz" -setup -npaths 3 -detail summary -stdout \
        -from_clock [list SDRAM_CLK] -to_clock [list $core1]
show "WORST HOLD, ALL CLOCKS"           -hold  -npaths 12 -detail summary -stdout
show "WORST HOLD SDRAM_CLK -> 35.8MHz"  -hold  -npaths 4 -detail full_path -stdout \
        -from_clock [list SDRAM_CLK] -to_clock [list $core1]
show "WORST HOLD 7.16MHz -> 35.8MHz"    -hold  -npaths 4 -detail full_path -stdout \
        -from_clock [list $core0] -to_clock [list $core1]

project_close
