// tb_hps_bridge.v - NVRAM-170: escape_hps_bridge against an hps_io-shaped
// stimulus on clk_ram and an EEPROM model on clk_sys, the two clocks
// phase-locked at the real 5:1 ratio.
//
//  T1 game select: the index-1 byte latches at all five strobe phases.
//     Control: the pre-NVRAM-170 latch (sampling the 28 ns strobe on clk_sys)
//     must MISS at least once over the same strobes, or the bench is blind.
//  T2 NVRAM load: 512 bytes through the ioctl_wait handshake land in the
//     EEPROM exactly; a 513th byte is ignored; the load does not mark dirty.
//  T3 save: after a scrub pass, an upload (hps_io order: addr 0 first, din
//     sampled at each strobe, then addr+1) returns the EEPROM exactly.
//  T4 dirty: a CPU write raises upload_req; an upload clears it; a write
//     during the upload raises it again; the new byte reaches the save.
// Run: ./sim/run_hps_bridge_tb.sh   (prints HPS BRIDGE PASS / FAIL)
`timescale 1ns/1ps
`default_nettype none

module tb_hps_bridge;
    reg clk_ram = 0, clk_sys = 0;
    always #13.968 clk_ram = ~clk_ram;      // 35.795455 MHz
    always #69.84  clk_sys = ~clk_sys;      //  7.159091 MHz, edges coincide

    reg         ioctl_download = 0, ioctl_upload = 0, ioctl_wr = 0;
    reg  [26:0] ioctl_addr = 0;
    reg   [7:0] ioctl_dout = 0;
    reg  [15:0] ioctl_index = 0;
    wire  [7:0] ioctl_din;
    wire        nv_wait, upload_req;
    wire  [1:0] game_sel;
    wire  [8:0] ee_saddr;
    wire  [7:0] ee_sdin;
    wire        ee_swe;
    reg   [7:0] ee_sq = 8'hFF;
    reg         ee_wrpulse = 0;

    escape_hps_bridge dut (
        .clk_ram(clk_ram), .clk_sys(clk_sys),
        .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_index(ioctl_index), .ioctl_din(ioctl_din), .nv_wait(nv_wait),
        .upload_req(upload_req), .game_sel(game_sel),
        .ee_saddr(ee_saddr), .ee_sdin(ee_sdin), .ee_swe(ee_swe),
        .ee_sq(ee_sq), .ee_wrpulse(ee_wrpulse));

    // EEPROM port B model: write-through, one-cycle registered read (as
    // dpram_bytelane_syn), plus a CPU-side writer standing in for port A.
    reg [7:0] ee [0:511];
    reg       cpu_we = 0;
    reg [8:0] cpu_a  = 0;
    reg [7:0] cpu_d  = 0;
    integer i;
    initial for (i = 0; i < 512; i = i + 1) ee[i] = 8'hFF;
    always @(posedge clk_sys) begin
        if (ee_swe) ee[ee_saddr] = ee_sdin;
        if (cpu_we) ee[cpu_a] = cpu_d;
        ee_sq <= ee[ee_saddr];
        ee_wrpulse <= cpu_we;
    end
    // the test owns cpu_we: one clk_sys long, raised and dropped by cpu_write
    task cpu_write(input [8:0] a, input [7:0] d);
        begin
            @(posedge clk_sys); cpu_a <= a; cpu_d <= d; cpu_we <= 1;
            @(posedge clk_sys); cpu_we <= 0;
        end
    endtask

    // control: the old latch from builds 164-167
    reg [1:0] old_gs = 0;
    always @(posedge clk_sys)
        if (ioctl_wr && ioctl_download && ioctl_index == 16'd1 && ioctl_addr == 0)
            old_gs <= ioctl_dout[1:0];

    integer errors = 0, old_miss = 0, k, ph;
    reg [7:0] img [0:511];
    reg [7:0] got;

    task hps_byte(input [26:0] a, input [7:0] d);
        begin
            while (nv_wait) @(posedge clk_ram);
            ioctl_addr <= a; ioctl_dout <= d; ioctl_wr <= 1;
            @(posedge clk_ram); ioctl_wr <= 0;
            repeat (2) @(posedge clk_ram);        // tighter than the real HPS
        end
    endtask

    initial begin
        repeat (20) @(posedge clk_ram);

        // ---------------- T1
        for (k = 0; k < 10; k = k + 1) begin
            ph = k % 5;
            @(posedge clk_sys); repeat (ph) @(posedge clk_ram);
            ioctl_index <= 16'd1; ioctl_download <= 1;
            ioctl_addr <= 0; ioctl_dout <= (k % 2) ? 8'h02 : 8'h01; ioctl_wr <= 1;
            @(posedge clk_ram); ioctl_wr <= 0;
            repeat (3) @(posedge clk_ram); ioctl_download <= 0;
            repeat (6) @(posedge clk_sys);
            if (game_sel !== ((k % 2) ? 2'd2 : 2'd1)) begin
                errors = errors + 1;
                $display("T1 FAIL phase %0d: game_sel=%0d", ph, game_sel);
            end
            if (old_gs !== ((k % 2) ? 2'd2 : 2'd1)) old_miss = old_miss + 1;
            old_gs = 0;
        end
        $display("T1 game select: 10/10 strobes checked at 5 phases; old clk_sys latch missed %0d of 10", old_miss);
        if (old_miss == 0) begin
            errors = errors + 1;
            $display("T1 CONTROL FAIL: the old latch never missed - the bench cannot see the bug");
        end

        // ---------------- T2
        for (i = 0; i < 512; i = i + 1) img[i] = (i * 37 + 11) ^ (i >> 3);
        ioctl_index <= 16'd4; ioctl_download <= 1;
        for (i = 0; i < 512; i = i + 1) hps_byte(i, img[i]);
        hps_byte(512, 8'h5A);                      // past the end: ignored
        while (nv_wait) @(posedge clk_ram);
        repeat (4) @(posedge clk_ram); ioctl_download <= 0;
        repeat (10) @(posedge clk_sys);
        k = 0;
        for (i = 0; i < 512; i = i + 1) if (ee[i] !== img[i]) k = k + 1;
        $display("T2 NVRAM load: %0d/512 bytes wrong; upload_req=%0d after load", k, upload_req);
        if (k != 0 || upload_req !== 1'b0) errors = errors + 1;

        // ---------------- T3
        repeat (3 * 512 + 50) @(posedge clk_sys);  // one full scrub pass
        ioctl_index <= 16'd4; ioctl_upload <= 1; ioctl_addr <= 0;
        k = 0;
        for (i = 0; i < 512; i = i + 1) begin
            repeat (3) @(posedge clk_ram);
            got = ioctl_din;
            if (got !== ee[i]) k = k + 1;
            ioctl_addr <= ioctl_addr + 1;
        end
        ioctl_upload <= 0;
        $display("T3 save: %0d/512 bytes differ from the EEPROM", k);
        if (k != 0) errors = errors + 1;

        // ---------------- T4
        cpu_write(9'd77, 8'hC3);
        repeat (10) @(posedge clk_ram);
        if (upload_req !== 1'b1) begin errors = errors + 1; $display("T4 FAIL: CPU write did not raise upload_req"); end
        repeat (3 * 512 + 50) @(posedge clk_sys);
        ioctl_upload <= 1; ioctl_addr <= 0;
        repeat (3) @(posedge clk_ram);
        if (upload_req !== 1'b0) begin errors = errors + 1; $display("T4 FAIL: upload did not clear upload_req"); end
        cpu_write(9'd300, 8'h3C);                  // write during the upload
        k = 0;
        for (i = 0; i < 512; i = i + 1) begin
            repeat (3) @(posedge clk_ram);
            if (i == 77 && ioctl_din !== 8'hC3) k = k + 1;
            ioctl_addr <= ioctl_addr + 1;
        end
        ioctl_upload <= 0;
        repeat (10) @(posedge clk_ram);
        if (k != 0) begin errors = errors + 1; $display("T4 FAIL: byte 77 not 0xC3 in the save"); end
        if (upload_req !== 1'b1) begin errors = errors + 1; $display("T4 FAIL: write during upload did not re-raise upload_req"); end
        $display("T4 dirty flag: write -> raise, upload -> clear, write during upload -> raise again; new byte saved");

        if (errors == 0) $display("HPS BRIDGE PASS");
        else             $display("HPS BRIDGE FAIL: %0d checks failed", errors);
        $finish;
    end
endmodule

`default_nettype wire
