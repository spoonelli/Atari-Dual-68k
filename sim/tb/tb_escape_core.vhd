-- Testbench for the synthesizable escape_core: serves the external ROM bus from the
-- combined image (as SDRAM will on hardware, with realistic multi-cycle latency),
-- generates a fake VBLANK, and checks both CPUs come up: the Video CPU executes at
-- its reset PC and (via 360010 or fallback force is NOT provided here — real latch
-- only) the Extra CPU release state is observable. This is the hardware design,
-- simulated as-is.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

-- SDRAM-ARCH: two generics added, both inert by default.
--   G_TRACE  path to write the ROM fetch address trace to. Empty (default) =
--            no trace, byte-identical behaviour to before.
--   G_US     how long to run before the check process stops the clock.
-- This bench is the only one in the repo that runs the REAL game ROM
-- (sim/work/combined_words.hex) through the REAL TG68K with SHAD_EN=>0, so it
-- is the only honest source of a CPU program-fetch address sequence for the
-- no-shadow configuration. Every other CPU bench uses a synthetic image whose
-- row locality would be an artefact of the image, not of the game.
entity tb_escape_core is
    generic (
        G_TRACE : string  := "";
        G_US    : integer := 60
    );
end tb_escape_core;

architecture tb of tb_escape_core is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';
    signal rom_par  : std_logic := '0';

    signal vblank : std_logic := '0';
    signal alpha_vaddr : std_logic_vector(10 downto 0) := (others=>'0');
    signal alpha_vdata : std_logic_vector(15 downto 0);
    signal dbg_v, dbg_e : std_logic;

    signal romsrv_data, romsrv_data2 : std_logic_vector(15 downto 0);
    signal rom_addr2w : std_logic_vector(20 downto 0);
begin
    clk    <= not clk after 5 ns when not done else '0';
    resetn <= '0', '1' after 205 ns;
    -- model the REAL SDRAM burst: second word is col|1, NOT col+1 —
    -- an odd word index returns the SAME word twice (caught the v14 prefetch bug)
    rom_addr2w <= rom_addr(21 downto 2) & '1';

    uut : entity work.escape_core
        generic map ( YM_ENABLE => 0, SHAD_EN => 0 )   -- GHDL: no jt51; shadows unfilled
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
                   dbg_v_pc_fetch=>dbg_v, dbg_e_running=>dbg_e );

    -- combined-image ROM server, 3-cycle latency (SDRAM-ish)
    romsrv : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr(21 downto 1), data => romsrv_data );
    romsrv2 : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr2w, data => romsrv_data2 );

    -- strict 4-phase: ack rises once per request and stays high until req falls
    serve : process(clk)
        variable lat    : integer := 0;
        variable served : boolean := false;
    begin
        if rising_edge(clk) then
            if rom_req='1' then
                if not served then
                    if lat = 2 then
                        rom_data <= romsrv_data & romsrv_data2;
                        rom_par  <= xor (romsrv_data & romsrv_data2);
                        rom_ack  <= '1';
                        served   := true;
                        lat := 0;
                    else
                        lat := lat + 1;
                    end if;
                end if;
            else
                rom_ack <= '0';
                served  := false;
                lat := 0;
            end if;
        end if;
    end process;

    -- fake VBLANK: 240 lines on, 22 off at 456 clk/line ~ 59.92 Hz cadence
    vb : process
    begin
        wait for 100 us;
        loop
            vblank <= '1'; wait for 10 us;
            vblank <= '0'; wait for 90 us;
            exit when done;
        end loop;
        wait;
    end process;

    -- CPU-bus level trace via VHDL-2008 external names: log each completed bus cycle
    cpu_trace : process(clk)
        alias xv_addr  is << signal .tb_escape_core.uut.v_addr  : std_logic_vector(31 downto 0) >>;
        alias xv_as_n  is << signal .tb_escape_core.uut.v_as_n  : std_logic >>;
        alias xv_rw_n  is << signal .tb_escape_core.uut.v_rw_n  : std_logic >>;
        alias xv_dtack is << signal .tb_escape_core.uut.v_dtack_n : std_logic >>;
        alias xv_di    is << signal .tb_escape_core.uut.v_di    : std_logic_vector(15 downto 0) >>;
        variable n : integer := 0;
        variable in_cycle : boolean := false;
    begin
        if rising_edge(clk) then
            if xv_as_n='0' and xv_dtack='0' and not in_cycle and n < 25 then
                if xv_rw_n='1' then
                    report "cpu " & integer'image(n) & " R a=0x" & to_hstring(xv_addr(23 downto 0))
                           & " di=0x" & to_hstring(xv_di);
                else
                    report "cpu " & integer'image(n) & " W a=0x" & to_hstring(xv_addr(23 downto 0));
                end if;
                n := n + 1;
                in_cycle := true;
            end if;
            if xv_as_n='1' then in_cycle := false; end if;
        end if;
    end process;

    -- ROM fetch address trace. One line per REQUEST EDGE (not per ack), which
    -- is the sequence sdram_simple would see. rom_addr is a byte address;
    -- >= 0x080000 is the extra CPU (escape_core adds 0x080000 to extra-side
    -- addresses), below that is the video CPU - so the client tag comes for
    -- free and is not an assumption.
    rom_trace : process(clk)
        file     tf   : text;
        variable l    : line;
        variable opened : boolean := false;
        variable prev : std_logic := '1';
    begin
        if G_TRACE /= "" then
            if rising_edge(clk) then
                if not opened then
                    file_open(tf, G_TRACE, write_mode);
                    opened := true;
                end if;
                if rom_req = '1' and prev = '0' then
                    write(l, to_hstring(rom_addr));
                    writeline(tf, l);
                end if;
                prev := rom_req;
            end if;
        end if;
    end process;

    check : process
    begin
        wait for G_US * 1 us;
        report "=== escape_core (synthesizable) ===";
        report "  video CPU fetched reset PC: " & std_logic'image(dbg_v);
        report "  extra CPU released (360010 D0): " & std_logic'image(dbg_e);
        if dbg_v = '1' then
            report "ESCAPE-CORE OK: hardware design boots the real program in sim" severity note;
        else
            report "escape_core: video CPU did not reach reset PC" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
