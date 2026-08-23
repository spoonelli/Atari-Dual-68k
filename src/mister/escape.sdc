# Atari Escape (MiSTer) - core timing constraints.
#
# sys/sys_top.sdc creates the root clocks, runs derive_pll_clocks, and puts
# every output of THIS core's PLL into one clock group:
#
#   set_clock_groups -exclusive -group [get_clocks {*|pll|pll_inst|...|divclk}]
#
# That is exactly what this design needs.  The 7.159091 MHz CPU/pixel clock
# and the 35.795455 MHz SDRAM clock are 5:1 siblings off one PLL, and every
# CPU<->SDRAM handshake in rtl/escape_mister.v is a SINGLE-FF crossing that
# relies on being timed (the Pocket build's SDSCHED-73/74 arrangement,
# src/fpga/core/core_constraints.sdc).  Do not add a set_clock_groups line
# that separates them - the single-FF handshakes would go unanalysed and the
# design would be quietly unsafe rather than merely slow.

# ---------------------------------------------------------------------------
# SDRAM
# ---------------------------------------------------------------------------
# SDRAM_CLK is PLL output 2 (35.795455 MHz, +90 degrees).  Declaring it as a
# generated clock on the port lets the I/O delays below be analysed against
# the real launch/capture edges.
create_generated_clock -name SDRAM_CLK \
  -source [get_pins -compatibility_mode {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# MT48LC16M16A2-class part, CL2.  Same numbers the Atari System 1 MiSTer core
# uses for the same DE10-Nano SDRAM module.
# data access delay (tAC)
set_input_delay  -clock SDRAM_CLK -max 6.0  [get_ports {SDRAM_DQ[*]}]
# data output hold time (tOH)
set_input_delay  -clock SDRAM_CLK -min 2.5  [get_ports {SDRAM_DQ[*]}]
# data input setup time (tIS)
set_output_delay -clock SDRAM_CLK -max 1.5  [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_n* SDRAM_DQM* SDRAM_CKE}]
# data input hold time (tIH)
set_output_delay -clock SDRAM_CLK -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_n* SDRAM_DQM* SDRAM_CKE}]

# The controller runs on PLL output 1; SDRAM_CLK is a quarter period later, so
# the launch edge for a read return is one full period behind the capture
# edge.  Same multicycle the reference core applies - PLUS the matching hold
# multicycle, which the reference core omits.
#
# Omitting it is not cosmetic: a -setup 2 with -end moves the HOLD check to
# one destination period after the launch edge, so the analyser then demands
# that read data still be in flight a whole 27.9 ns later.  Our first build
# closed setup here but reported -10.922 ns of hold across the SDRAM_DQ
# inputs purely because of that.  "-hold -end 1" puts the hold check back on
# the edge it belongs to.
set_multicycle_path -setup -end \
  -rise_from [get_clocks {SDRAM_CLK}] \
  -rise_to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
set_multicycle_path -hold -end \
  -rise_from [get_clocks {SDRAM_CLK}] \
  -rise_to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] 1
