# HOLD-108: name the worst hold paths, with full node names.
#
# ap_core.sta.rpt as written by `quartus_sh --flow compile` contains SUMMARY
# tables only: a clock, a slack and a TNS. That is enough to gate on and not
# enough to act on - when BUILD 108 came in at +0.005 ns of hold on the CPU
# clock, nothing in the artifact said WHICH register pair it was, so the only
# available move was to reason about which recent change looked most likely.
# This project has a documented history of losing to exactly that.
#
# Run after the compile, in the project directory:
#   quartus_sta -t support/report_hold_paths.tcl
#
# Writes src/fpga/output_files/ap_core.hold_paths.rpt with the 20 worst hold
# paths at the Fast 1100mV 0C corner (the corner hold is worst at, and the one
# the summary's worst row comes from), full path detail, plus the 10 worst at
# Fast 85C. Diagnostic only: it gates nothing and must never fail a build.

project_open ap_core

set out "output_files/ap_core.hold_paths.rpt"
if {[file exists "src/fpga/output_files"]} { set out "src/fpga/output_files/ap_core.hold_paths.rpt" }

# Fast 1100mV 0C - the corner the worst-case hold row is reported from
create_timing_netlist -model fast -temperature 0 -voltage 1100
read_sdc
update_timing_netlist
report_timing -hold -npaths 20 -detail full_path \
    -panel_name "Hold Paths (Fast 1100mV 0C)" -file $out
delete_timing_netlist

# Fast 1100mV 85C - second hold corner, appended so a path that is thin at
# only one corner is distinguishable from one that is thin at both
create_timing_netlist -model fast -temperature 85 -voltage 1100
read_sdc
update_timing_netlist
report_timing -hold -npaths 10 -detail full_path \
    -panel_name "Hold Paths (Fast 1100mV 85C)" -append -file $out
delete_timing_netlist

project_close
