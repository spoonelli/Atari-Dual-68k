// ---------------------------------------------------------------------------
// tb_psram_timing - MEASURED timing bench for the CRAM (PSRAM) controller.
//
// WHY THIS EXISTS
// ---------------
// CRAM holds the PLAYFIELD graphics (MO graphics come from SDRAM). The whole
// FPGA<->PSRAM interface is asynchronous, and every wait state in psram.sv is
// derived from ONE parameter:
//
//     localparam PERIOD = 1000.0 / CLOCK_SPEED;
//     localparam TOTAL_READ_CYCLE_COUNT = `CEIL(MAX_ACCESS_TIME_FROM_ADV / PERIOD);
//
// so if CLOCK_SPEED and the clock actually wired to `clk` ever disagree, every
// external memory timing silently changes and nothing complains. That is the
// bug class BUILD 106 fixed by hand (`clk_sdram` is 35.795455 MHz, not the
// 85.909 several comments assumed). Nothing else catches it: neither
// apf_constraints.sdc nor core_constraints.sdc puts a set_input_delay /
// set_output_delay on any cram_* pin, so Quartus never times this interface -
// the full-chip slack number says nothing at all about it.
//
// WHAT IT MEASURES (rather than re-derives)
// -----------------------------------------
// A behavioural CellularRAM model drives the bus using the datasheet numbers
// and POISONS cram_dq until the access time has elapsed, so a controller that
// samples early reads 16'hDEAD instead of "the right answer, early". Two
// clocks are separate on purpose:
//
//   DECLARED_CLOCK_MHZ - what core_top.v tells psram.sv the clock is
//   ACTUAL_CLOCK_MHZ   - what the PLL really produces
//
// and the bench runs the DUT at the ACTUAL one. Setting them apart is what
// makes this gate able to fail on the real bug (see run_psram_tb.sh).
//
// The round-trip I/O delay (FPGA clock->pin + board + board + pin->FF setup)
// is a swept knob; the bench reports the LARGEST value at which every read
// still returns the right word. That number is this interface's real headroom
// and it is what the pass criterion checks.
//
// It also asserts the async pulse-width rules on every transaction
// (t_vp, t_avs, t_avh, t_cvs, t_wp, t_dw, t_aw) and watches for a bus fight.
//
// Override with iverilog -Ptb_psram_timing.NAME=value.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_psram_timing;

  // ---- knobs -------------------------------------------------------------
  // core_top.v: psram #(.CLOCK_SPEED(35.795455)) cram0 (.clk(clk_sdram), ...)
  parameter real DECLARED_CLOCK_MHZ = 35.795455;
  parameter real ACTUAL_CLOCK_MHZ   = 35.795455;
  parameter real MIN_IO_BUDGET_NS   = 5.0;
  parameter integer SWEEP_MAX_NS    = 60;

  // datasheet numbers, same names/values psram.sv uses
  parameter real T_AA   = 70.0;  // address access time (max)
  parameter real T_VP   = 5.0;   // adv# low pulse (min)
  parameter real T_AVS  = 5.0;   // address setup before adv# high (min)
  parameter real T_AVH  = 2.0;   // address hold after adv# high (min)
  parameter real T_CVS  = 7.0;   // ce# low before adv# high (min)
  parameter real T_WP   = 45.0;  // we# low pulse (min)
  parameter real T_DW   = 20.0;  // data setup before we# high (min)
  parameter real T_AW   = 70.0;  // write cycle from adv# low (min)

  localparam real PERIOD_NS = 1000.0 / ACTUAL_CLOCK_MHZ;

  // ---- clock -------------------------------------------------------------
  reg clk = 0;
  always #(PERIOD_NS/2.0) clk = ~clk;

  // ---- DUT ---------------------------------------------------------------
  reg  [21:0] addr = 0;
  reg         write_en = 0, read_en = 0;
  reg  [15:0] data_in = 0;
  wire [15:0] data_out;
  wire        read_avail, busy;

  wire [21:16] cram_a;
  wire [15:0]  cram_dq;
  wire cram_clk, cram_adv_n, cram_cre, cram_ce0_n, cram_ce1_n;
  wire cram_oe_n, cram_we_n, cram_ub_n, cram_lb_n;

  psram #(.CLOCK_SPEED(DECLARED_CLOCK_MHZ)) dut (
    .clk(clk), .bank_sel(1'b0), .addr(addr),
    .write_en(write_en), .data_in(data_in),
    .write_high_byte(1'b1), .write_low_byte(1'b1),
    .read_en(read_en), .read_avail(read_avail), .data_out(data_out),
    .busy(busy),
    .cram_a(cram_a), .cram_dq(cram_dq), .cram_wait(1'b0),
    .cram_clk(cram_clk), .cram_adv_n(cram_adv_n), .cram_cre(cram_cre),
    .cram_ce0_n(cram_ce0_n), .cram_ce1_n(cram_ce1_n),
    .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n),
    .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n)
  );

  // ---- behavioural CellularRAM -------------------------------------------
  // round-trip I/O delay the model charges against the access time; swept
  // below. 0 = an ideal FPGA on an ideal board, i.e. physically impossible.
  real io_ns = 0.0;

  reg [15:0] mem [0:63];
  reg [21:0] latched_addr = 0;
  reg [15:0] drive_data   = 16'hDEAD;   // poison until the access time elapses
  reg        drive_en     = 1'b0;
  real       t_adv_fall   = 0.0;
  real       t_adv_rise   = 0.0;
  real       t_ce_fall    = 0.0;
  real       t_we_fall    = 0.0;
  real       t_data_set   = 0.0;
  real       ready_at     = 0.0;
  real       last_read_ns = 0.0;   // MEASURED adv# fall -> controller sample
  real       last_write_ns = 0.0;  // MEASURED adv# fall -> we# rise
  integer    viol         = 0;
  integer    bad_reads    = 0;

  assign cram_dq = drive_en ? drive_data : 16'hzzzz;

  // What the CONTROLLER is putting on dq. Taken from inside the DUT rather
  // than off the resolved net: the model and the controller must never drive
  // together, and sourcing it this way makes that assumption checkable
  // (ctrl_drives && drive_en is a bus fight, asserted below).
  wire        ctrl_drives = dut.data_out_en;
  wire [15:0] ctrl_dq     = dut.cram_data;

  task tviol(input [511:0] what, input real got, input real need);
    begin
      viol = viol + 1;
      $display("TIMING VIOLATION %0s: %.2f ns, needs >= %.2f ns", what, got, need);
    end
  endtask

  always @(posedge clk) if (ctrl_drives && drive_en) begin
    viol = viol + 1;
    $display("BUS FIGHT at %.2f ns: controller and memory both driving cram_dq", $realtime);
  end

  // address latch + async pulse-width rules
  always @(negedge cram_adv_n) t_adv_fall = $realtime;
  always @(negedge cram_ce0_n) t_ce_fall  = $realtime;
  always @(negedge cram_we_n)  t_we_fall  = $realtime;

  always @(posedge cram_adv_n) begin
    t_adv_rise = $realtime;
    // the part latches the address on adv# rising
    latched_addr = {cram_a, ctrl_dq};
    if (t_adv_rise - t_adv_fall < T_VP)
      tviol("t_vp  (adv# low pulse)", t_adv_rise - t_adv_fall, T_VP);
    if (t_adv_rise - t_adv_fall < T_AVS)
      tviol("t_avs (addr setup before adv# high)", t_adv_rise - t_adv_fall, T_AVS);
    if (t_adv_rise - t_ce_fall < T_CVS)
      tviol("t_cvs (ce# low before adv# high)", t_adv_rise - t_ce_fall, T_CVS);
  end

  // READ: drive POISON the moment oe# goes low, and only swap in the real word
  // once t_AA (+ the modelled round trip) has elapsed since adv# fell.
  always @(negedge cram_oe_n) begin : read_serve
    drive_data = 16'hDEAD;
    drive_en   = 1'b1;
    ready_at   = t_adv_fall + T_AA + io_ns;
    if ($realtime < ready_at) #(ready_at - $realtime);
    if (cram_oe_n === 1'b0) drive_data = mem[latched_addr[5:0]];
  end
  always @(posedge cram_oe_n) begin
    drive_en   = 1'b0;
    drive_data = 16'hDEAD;
  end
  // the controller latches cram_dq on the same edge that raises read_avail
  always @(posedge read_avail) last_read_ns = $realtime - t_adv_fall;

  // WRITE: the controller drops data_out_en on the same edge that raises we#,
  // so capture from ctrl_dq (which still holds the write word) rather than
  // from the already-tristated net.
  always @(posedge cram_we_n) begin
    last_write_ns = $realtime - t_adv_fall;
    if ($realtime - t_we_fall < T_WP)
      tviol("t_wp  (we# low pulse)", $realtime - t_we_fall, T_WP);
    if ($realtime - t_adv_fall < T_AW)
      tviol("t_aw  (write cycle from adv# low)", $realtime - t_adv_fall, T_AW);
    if ($realtime - t_data_set < T_DW)
      tviol("t_dw  (data setup before we# high)", $realtime - t_data_set, T_DW);
    mem[latched_addr[5:0]] = ctrl_dq;
  end

  // moment the controller stops driving the address and starts driving write
  // data (used for t_dw)
  always @(posedge ctrl_drives) if (cram_we_n === 1'b0) t_data_set = $realtime;

  // t_avh: the address must survive adv# rising
  always @(negedge ctrl_drives) begin
    if ($realtime - t_adv_rise < T_AVH)
      tviol("t_avh (addr hold after adv# high)", $realtime - t_adv_rise, T_AVH);
  end

  // ---- stimulus ----------------------------------------------------------
  integer i, guard, sweep_steps;
  real    budget;
  reg     bad_write;

  task do_read(input [21:0] a, input [15:0] expect_data);
    begin
      // idle first: a `wait` on a read_avail still high from the PREVIOUS
      // transaction returns immediately and compares STALE data_out, which
      // would make this bench unable to fail. Drain explicitly.
      guard = 0;
      while ((busy === 1'b1 || read_avail === 1'b1) && guard < 60) begin
        @(posedge clk); guard = guard + 1;
      end
      @(posedge clk);
      addr    <= a;
      read_en <= 1'b1;
      @(posedge clk);
      read_en <= 1'b0;
      guard = 0;
      while (read_avail !== 1'b1 && guard < 60) begin
        @(posedge clk); guard = guard + 1;
      end
      if (read_avail !== 1'b1) begin
        bad_reads = bad_reads + 1;
        $display("  READ NEVER COMPLETED addr=%06h io=%.1f ns", a, io_ns);
      end else if (data_out !== expect_data) begin
        bad_reads = bad_reads + 1;
        if (bad_reads < 4)
          $display("  READ MISMATCH addr=%06h io=%.1f ns got=%04h want=%04h",
                   a, io_ns, data_out, expect_data);
      end
      @(posedge clk);
    end
  endtask

  task do_write(input [21:0] a, input [15:0] d);
    begin
      guard = 0;
      while (busy === 1'b1 && guard < 60) begin @(posedge clk); guard = guard + 1; end
      @(posedge clk);
      addr     <= a;
      data_in  <= d;
      write_en <= 1'b1;
      @(posedge clk);
      write_en <= 1'b0;
      @(posedge clk);                       // controller is busy from here
      guard = 0;
      while (busy === 1'b1 && guard < 60) begin @(posedge clk); guard = guard + 1; end
      @(posedge clk);
    end
  endtask

  initial begin
    for (i = 0; i < 64; i = i + 1) mem[i] = 16'hA500 ^ (i * 16'h1111);

    $display("TB_PSRAM_TIMING declared=%.6f MHz  actual=%.6f MHz  period=%.3f ns",
             DECLARED_CLOCK_MHZ, ACTUAL_CLOCK_MHZ, PERIOD_NS);
    if (DECLARED_CLOCK_MHZ != ACTUAL_CLOCK_MHZ)
      $display("  NOTE: declared != actual - wait states are being derived for the WRONG clock");

    repeat (8) @(posedge clk);

    // writes first: this is the path the ROM download uses to fill CRAM, so a
    // write-timing failure is the "written wrong at download" case
    io_ns     = 0.0;
    bad_write = 1'b0;
    do_write(22'd7, 16'h1234);
    do_write(22'd8, 16'h5678);
    if (mem[7] !== 16'h1234 || mem[8] !== 16'h5678) begin
      bad_write = 1'b1;
      $display("  WRITE MISMATCH mem[7]=%04h (want 1234) mem[8]=%04h (want 5678)",
               mem[7], mem[8]);
    end
    $display("  MEASURED write cycle: adv# fall -> we# rise = %.2f ns (t_AW needs %.1f ns)",
             last_write_ns, T_AW);

    // sweep the round-trip I/O delay to find the real headroom
    budget      = -1.0;
    sweep_steps = 0;
    for (i = 0; i <= SWEEP_MAX_NS; i = i + 1) begin
      io_ns       = i * 1.0;
      bad_reads   = 0;
      sweep_steps = sweep_steps + 1;
      do_read(22'd7,  16'h1234);
      do_read(22'd8,  16'h5678);
      do_read(22'd21, 16'hA500 ^ (21 * 16'h1111));
      do_read(22'd34, 16'hA500 ^ (34 * 16'h1111));
      if (i == 0)
        $display("  MEASURED read cycle : adv# fall -> dq sample = %.2f ns (t_AA needs %.1f ns)",
                 last_read_ns, T_AA);
      if (bad_reads == 0) budget = io_ns;
      else i = SWEEP_MAX_NS + 1;      // first failure ends the sweep
    end

    $display("TB_PSRAM_TIMING swept io=0..%0d ns in %0d steps, %0d reads checked",
             SWEEP_MAX_NS, sweep_steps, sweep_steps * 4);
    $display("TB_PSRAM_TIMING measured I/O headroom = %.1f ns", budget);
    $display("  (largest FPGA clock->pin + board + board + pin->FF round trip the");
    $display("   current wait-state count tolerates before reads corrupt)");
    $display("TB_PSRAM_TIMING async-rule violations = %0d", viol);

    if (bad_write) begin
      $display("TB_PSRAM_TIMING FAIL: the write path did not land the data");
      $finish;
    end
    if (viol != 0) begin
      $display("TB_PSRAM_TIMING FAIL: %0d async pulse-width violation(s)", viol);
      $finish;
    end
    if (budget < 0.0) begin
      $display("TB_PSRAM_TIMING FAIL: reads are wrong even with a ZERO ns I/O round trip");
      $display("  -> psram.sv samples cram_dq before t_AA has elapsed at this clock");
      $finish;
    end
    if (budget >= SWEEP_MAX_NS * 1.0) begin
      $display("TB_PSRAM_TIMING FAIL: headroom exceeded the sweep range - raise SWEEP_MAX_NS");
      $display("  (an un-bounded measurement is not a measurement)");
      $finish;
    end
    if (budget < MIN_IO_BUDGET_NS) begin
      $display("TB_PSRAM_TIMING FAIL: headroom %.1f ns < required %.1f ns",
               budget, MIN_IO_BUDGET_NS);
      $finish;
    end
    $display("TB_PSRAM_TIMING PASS headroom %.1f ns >= %.1f ns required, %0d violations",
             budget, MIN_IO_BUDGET_NS, viol);
    $finish;
  end

  initial begin
    #500000;
    $display("TB_PSRAM_TIMING FAIL: timeout (controller never completed a transaction)");
    $finish;
  end

endmodule
