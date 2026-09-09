`timescale 1ns/1ps
// Smoke bench: drive jotego's jt6295 the way the JSA-II 6502 would (phrase
// command then channel/attenuation byte), from a synthetic 256 KB ADPCM ROM
// with a one-clock rom_ok handshake, and check that (a) the phrase table is
// read, (b) sample data streams from the phrase's start address, (c) the
// output leaves zero.  clk = 7.159 MHz (the JSA board clock), cen = /6 =
// 1.193 MHz = JSA_MASTER_CLOCK/3 (MAME atarijsa.cpp), ss = 1 (PIN7_HIGH).
module tb;
  reg clk=0; always #69.84 clk=~clk;          // 7.159 MHz
  reg rst=1; reg [2:0] div=0; wire cen = (div==0);
  always @(posedge clk) div <= (div==5) ? 0 : div+1;
  reg wrn=1; reg [7:0] din=0; wire [7:0] dout;
  wire [17:0] rom_addr; reg [7:0] rom_data; reg rom_ok=0;
  wire signed [13:0] sound; wire sample;
  reg [7:0] rom [0:262143];
  integer i, nsmp, tbl_reads, dat_reads, nz;
  jt6295 #(.INTERPOL(0)) uut(.rst(rst),.clk(clk),.cen(cen),.ss(1'b1),.wrn(wrn),.din(din),.dout(dout),
     .rom_addr(rom_addr),.rom_data(rom_data),.rom_ok(rom_ok),.sound(sound),.sample(sample));
  // ROM model: 1-clock latency, rom_ok tracks address stability
  reg [17:0] last_a;
  always @(posedge clk) begin
    rom_data <= rom[rom_addr]; last_a <= rom_addr;
    rom_ok   <= (last_a == rom_addr);
    if (rom_ok && cen) begin
      if (rom_addr < 18'h400) tbl_reads = tbl_reads + 1;
      else if (rom_addr >= 18'h1000 && rom_addr < 18'h1800) dat_reads = dat_reads + 1;
    end
  end
  task cpu_write(input [7:0] d); begin
    @(posedge clk); din <= d; wrn <= 0; repeat (8) @(posedge clk); wrn <= 1; repeat (24) @(posedge clk);
  end endtask
  initial begin
    for (i=0;i<262144;i=i+1) rom[i]=8'h00;
    // phrase 1: start 0x001000, end 0x0017FF (table entry 8 bytes at 8*1)
    rom[8]=8'h00; rom[9]=8'h10; rom[10]=8'h00; rom[11]=8'h00; rom[12]=8'h17; rom[13]=8'hFF;
    for (i=18'h1000;i<18'h1800;i=i+1) rom[i] = (i[3]) ? 8'h88 : 8'h00;  // alternating ramps
    tbl_reads=0; dat_reads=0; nsmp=0; nz=0;
    repeat (20) @(posedge clk); rst=0; repeat (200) @(posedge clk);
    cpu_write(8'h81);   // phrase 1
    cpu_write(8'h10);   // channel 0, attenuation 0
    // run ~40 ms of board time
    for (i=0;i<286000;i=i+1) begin @(posedge clk); if (sample) begin nsmp=nsmp+1; if (sound!=0) nz=nz+1; end end
    $display("table reads=%0d  data reads=%0d  samples=%0d  nonzero samples=%0d  status=%02x", tbl_reads, dat_reads, nsmp, nz, dout);
    if (tbl_reads>0 && dat_reads>100 && nz>100) $display("JT6295 SMOKE OK"); else $display("JT6295 SMOKE FAIL");
    $finish;
  end
endmodule
