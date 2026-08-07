-- Escape Video (main) 68000 bring-up in simulation.
-- TG68K (configured as a 68000) -> escape_decode -> program ROM + work/shared RAM.
-- Releases reset and traces the boot bus cycles: we expect the 68000 to read the
-- reset SP (longword @ 0x000000) and PC (longword @ 0x000004), then fetch its first
-- instruction at the reset PC (0x000694). Seeing that sequence = the CPU is executing
-- the real Escape program out of the assembled ROM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_cpu is end tb_escape_cpu;

architecture tb of tb_escape_cpu is
    signal clk   : std_logic := '0';
    signal resn  : std_logic := '0';
    signal done  : boolean   := false;

    -- CPU bus
    signal cpu_addr : std_logic_vector(31 downto 0);
    signal cpu_do   : std_logic_vector(15 downto 0);
    signal cpu_di   : std_logic_vector(15 downto 0);
    signal fc       : std_logic_vector(2 downto 0);
    signal as_n, uds_n, lds_n, rw_n : std_logic;
    signal dtack_n  : std_logic := '1';
    signal vma      : std_logic;

    -- decode
    signal a24 : std_logic_vector(23 downto 0);
    signal sel_rom, sel_eeprom, sel_eeprom_unlk, sel_ram, sel_io, sel_watchdog,
           sel_vidctrl, sel_colorram, sel_pfram, sel_moram, sel_alpharam,
           sel_mobconfig, sel_slip, sel_workram, sel_pfpalette : std_logic;
    signal sel_hi : std_logic;

    -- memories
    signal rom_data, sram_data, hiram_data : std_logic_vector(15 downto 0);
    signal we_sram, we_hi : std_logic;
begin
    ----------------------------------------------------------------------------
    clk  <= not clk after 5 ns when not done else '0';
    resn <= '0', '1' after 205 ns;             -- hold reset ~20 clocks
    a24  <= cpu_addr(23 downto 0);

    ----------------------------------------------------------------------------
    cpu : entity work.TG68K
        generic map ( CPU => "01" )            -- 68000 (Escape); System 1 used 68010
        port map (
            CLK => clk, RESET => resn, HALT => resn, BERR => '0',
            IPL => "111", ADDR => cpu_addr, FC => fc,
            DATAI => cpu_di, DATAO => cpu_do,
            AS => as_n, UDS => uds_n, LDS => lds_n, RW => rw_n,
            DTACK => dtack_n, E => open, VPA => '1', VMA => vma );

    dec : entity work.escape_decode
        port map (
            addr => a24, as_n => as_n,
            sel_rom=>sel_rom, sel_eeprom=>sel_eeprom, sel_eeprom_unlk=>sel_eeprom_unlk,
            sel_ram=>sel_ram, sel_io=>sel_io, sel_watchdog=>sel_watchdog,
            sel_vidctrl=>sel_vidctrl, sel_colorram=>sel_colorram, sel_pfram=>sel_pfram,
            sel_moram=>sel_moram, sel_alpharam=>sel_alpharam, sel_mobconfig=>sel_mobconfig,
            sel_slip=>sel_slip, sel_workram=>sel_workram, sel_pfpalette=>sel_pfpalette );

    sel_hi <= sel_colorram or sel_pfram or sel_moram or sel_alpharam or
              sel_mobconfig or sel_slip or sel_workram or sel_pfpalette;

    ----------------------------------------------------------------------------
    -- Program ROM (0x00000-0x7FFFF), word-addressed
    rom : entity work.rom_words
        generic map ( hexfile => "sim/work/maincpu_words.hex", awidth => 18 )
        port map ( addr => cpu_addr(18 downto 1), data => rom_data );

    -- Shared program RAM 160000-16FFFF
    sram : entity work.ram_word
        generic map ( awidth => 15 )
        port map ( clk=>clk, addr=>cpu_addr(15 downto 1), din=>cpu_do,
                   we=>we_sram, uds_n=>uds_n, lds_n=>lds_n, dout=>sram_data );

    -- Video + work RAM 3E0000-3FFFFF (grouped as plain RAM for bring-up)
    hiram : entity work.ram_word
        generic map ( awidth => 16 )
        port map ( clk=>clk, addr=>cpu_addr(16 downto 1), din=>cpu_do,
                   we=>we_hi, uds_n=>uds_n, lds_n=>lds_n, dout=>hiram_data );

    we_sram <= '1' when as_n='0' and rw_n='0' and sel_ram='1' else '0';
    we_hi   <= '1' when as_n='0' and rw_n='0' and sel_hi='1'  else '0';

    -- read data mux
    cpu_di <= rom_data   when sel_rom='1'  else
              sram_data  when sel_ram='1'  else
              hiram_data when sel_hi='1'   else
              (others => '0');

    -- simple DTACK: acknowledge one clock after AS asserts (0 external wait states)
    dtack_gen : process(clk)
    begin
        if rising_edge(clk) then
            if as_n = '0' then dtack_n <= '0'; else dtack_n <= '1'; end if;
        end if;
    end process;

    ----------------------------------------------------------------------------
    monitor : process
        variable n   : integer := 0;
        variable pc_hit : boolean := false;
    begin
        wait until resn = '1';
        loop
            wait until falling_edge(as_n);
            wait until dtack_n = '0';
            wait until rising_edge(clk);
            if rw_n = '1' then
                report "cyc " & integer'image(n) & " R addr=0x"
                       & to_hstring(cpu_addr(23 downto 0)) & "  data=0x" & to_hstring(cpu_di);
            else
                report "cyc " & integer'image(n) & " W addr=0x"
                       & to_hstring(cpu_addr(23 downto 0)) & "  data=0x" & to_hstring(cpu_do);
            end if;
            if cpu_addr(23 downto 0) = x"000694" then pc_hit := true; end if;
            n := n + 1;
            exit when n >= 20 or done;
        end loop;
        -- keep running deeper into boot, logging only I/O (26xxxx/36xxxx) traffic so we
        -- can see whether boot blocks on the sound (SCOM) handshake
        while n < 4000 loop
            wait until falling_edge(as_n);
            wait until dtack_n = '0';
            wait until rising_edge(clk);
            if cpu_addr(23 downto 16) = x"26" or cpu_addr(23 downto 16) = x"36"
               or cpu_addr(23 downto 16) = x"2E" then
                if rw_n = '1' then
                    report "io  " & integer'image(n) & " R addr=0x"
                           & to_hstring(cpu_addr(23 downto 0)) & " data=0x" & to_hstring(cpu_di);
                else
                    report "io  " & integer'image(n) & " W addr=0x"
                           & to_hstring(cpu_addr(23 downto 0)) & " data=0x" & to_hstring(cpu_do);
                end if;
            end if;
            n := n + 1;
        end loop;
        report "deep-boot scan done at cycle " & integer'image(n)
               & ", last PC region 0x" & to_hstring(cpu_addr(23 downto 0));
        if pc_hit then
            report "BRING-UP OK: CPU fetched at reset PC 0x000694 (executing ROM)" severity note;
        else
            report "reset PC 0x000694 not observed in first " & integer'image(n) & " cycles" severity warning;
        end if;
        done <= true;
        wait;
    end process;
end tb;
