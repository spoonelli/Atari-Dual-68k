-- Escape "Extra" (second) 68000 bring-up in simulation.
-- Same harness as tb_escape_cpu but loads the extra-CPU ROM image. The extra CPU's
-- reset SP (0x0016FFDC) lives in the SHARED RAM (160000-16FFFF) and its reset PC is
-- 0x000342 in its own program ROM. Seeing it fetch reset vectors and execute from PC
-- proves the second CPU boots against the shared memory map.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_extracpu is end tb_escape_extracpu;

architecture tb of tb_escape_extracpu is
    signal clk   : std_logic := '0';
    signal resn  : std_logic := '0';
    signal done  : boolean   := false;

    signal cpu_addr : std_logic_vector(31 downto 0);
    signal cpu_do   : std_logic_vector(15 downto 0);
    signal cpu_di   : std_logic_vector(15 downto 0);
    signal fc       : std_logic_vector(2 downto 0);
    signal as_n, uds_n, lds_n, rw_n : std_logic;
    signal dtack_n  : std_logic := '1';
    signal vma      : std_logic;

    signal a24 : std_logic_vector(23 downto 0);
    signal sel_rom, sel_eeprom, sel_eeprom_unlk, sel_ram, sel_io, sel_watchdog,
           sel_vidctrl, sel_colorram, sel_pfram, sel_moram, sel_alpharam,
           sel_mobconfig, sel_slip, sel_workram, sel_pfpalette : std_logic;
    signal sel_hi : std_logic;

    signal rom_data, sram_data, hiram_data : std_logic_vector(15 downto 0);
    signal we_sram, we_hi : std_logic;
begin
    clk  <= not clk after 5 ns when not done else '0';
    resn <= '0', '1' after 205 ns;
    a24  <= cpu_addr(23 downto 0);

    cpu : entity work.TG68K
        generic map ( CPU => "00" )
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

    rom : entity work.rom_words
        generic map ( hexfile => "sim/work/extracpu_words.hex", awidth => 18 )
        port map ( addr => cpu_addr(18 downto 1), data => rom_data );

    sram : entity work.ram_word
        generic map ( awidth => 15 )
        port map ( clk=>clk, addr=>cpu_addr(15 downto 1), din=>cpu_do,
                   we=>we_sram, uds_n=>uds_n, lds_n=>lds_n, dout=>sram_data );

    hiram : entity work.ram_word
        generic map ( awidth => 16 )
        port map ( clk=>clk, addr=>cpu_addr(16 downto 1), din=>cpu_do,
                   we=>we_hi, uds_n=>uds_n, lds_n=>lds_n, dout=>hiram_data );

    we_sram <= '1' when as_n='0' and rw_n='0' and sel_ram='1' else '0';
    we_hi   <= '1' when as_n='0' and rw_n='0' and sel_hi='1'  else '0';

    cpu_di <= rom_data   when sel_rom='1'  else
              sram_data  when sel_ram='1'  else
              hiram_data when sel_hi='1'   else
              (others => '0');

    dtack_gen : process(clk)
    begin
        if rising_edge(clk) then
            if as_n = '0' then dtack_n <= '0'; else dtack_n <= '1'; end if;
        end if;
    end process;

    monitor : process
        variable n      : integer := 0;
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
            if cpu_addr(23 downto 0) = x"000342" then pc_hit := true; end if;
            n := n + 1;
            exit when n >= 20 or done;
        end loop;
        if pc_hit then
            report "EXTRA-CPU BRING-UP OK: fetched at reset PC 0x000342 (executing ROM)" severity note;
        else
            report "extra reset PC 0x000342 not observed in first " & integer'image(n) & " cycles" severity warning;
        end if;
        done <= true;
        wait;
    end process;
end tb;
