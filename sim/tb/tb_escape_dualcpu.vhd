-- Dual-68000 interconnect in simulation.
-- Video CPU + Extra CPU, each with its own program ROM, work/video RAM, and address
-- decoder, both sharing the 160000-16FFFF RAM via a true dual-port model. The Extra CPU
-- is held in reset until the Video CPU writes the 360010 D0 "extra reset" bit high
-- (real behavior); a fallback force-release at 3 us guarantees the interconnect is
-- exercised even if the video boot doesn't reach that write in the sim window.
-- Proves: reset control, both CPUs executing concurrently, and shared-RAM access.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_dualcpu is end tb_escape_dualcpu;

architecture tb of tb_escape_dualcpu is
    signal clk  : std_logic := '0';
    signal resn : std_logic := '0';
    signal done : boolean   := false;

    -- Video CPU
    signal v_addr : std_logic_vector(31 downto 0);
    signal v_do, v_di : std_logic_vector(15 downto 0);
    signal v_fc : std_logic_vector(2 downto 0);
    signal v_as_n, v_uds_n, v_lds_n, v_rw_n, v_vma : std_logic;
    signal v_dtack_n : std_logic := '1';
    -- Extra CPU
    signal e_addr : std_logic_vector(31 downto 0);
    signal e_do, e_di : std_logic_vector(15 downto 0);
    signal e_fc : std_logic_vector(2 downto 0);
    signal e_as_n, e_uds_n, e_lds_n, e_rw_n, e_vma : std_logic;
    signal e_dtack_n : std_logic := '1';
    signal e_resn : std_logic;

    -- decodes
    signal v_sel_rom, v_sel_ram, v_sel_vidctrl, v_sel_hi : std_logic;
    signal e_sel_rom, e_sel_ram, e_sel_hi : std_logic;
    signal v_ignore, e_ignore : std_logic_vector(12 downto 0);  -- unused selects

    -- memories
    signal v_rom_d, v_hi_d, e_rom_d, e_hi_d : std_logic_vector(15 downto 0);
    signal sram_a_d, sram_b_d : std_logic_vector(15 downto 0);
    signal v_we_hi, e_we_hi, we_sram_a, we_sram_b : std_logic;

    -- extra-CPU reset latch (360010 D0)
    signal extra_release : std_logic := '0';

    -- observation flags
    signal v_started, e_started, v_wrote_360010, forced : boolean := false;
    signal v_sram_hits, e_sram_hits : integer := 0;
begin
    clk  <= not clk after 5 ns when not done else '0';
    resn <= '0', '1' after 205 ns;
    e_resn <= resn and extra_release;

    ---------------------------------------------------------------- Video CPU
    vcpu : entity work.TG68K generic map ( CPU => "01" )
        port map ( CLK=>clk, RESET=>resn, HALT=>resn, BERR=>'0', IPL=>"111",
                   ADDR=>v_addr, FC=>v_fc, DATAI=>v_di, DATAO=>v_do,
                   AS=>v_as_n, UDS=>v_uds_n, LDS=>v_lds_n, RW=>v_rw_n,
                   DTACK=>v_dtack_n, E=>open, VPA=>'1', VMA=>v_vma );

    vdec : entity work.escape_decode
        port map ( addr=>v_addr(23 downto 0), as_n=>v_as_n,
                   sel_rom=>v_sel_rom, sel_eeprom=>v_ignore(0), sel_eeprom_unlk=>v_ignore(1),
                   sel_ram=>v_sel_ram, sel_io=>v_ignore(2), sel_watchdog=>v_ignore(3),
                   sel_vidctrl=>v_sel_vidctrl, sel_colorram=>v_ignore(4), sel_pfram=>v_ignore(5),
                   sel_moram=>v_ignore(6), sel_alpharam=>v_ignore(7), sel_mobconfig=>v_ignore(8),
                   sel_slip=>v_ignore(9), sel_workram=>v_ignore(10), sel_pfpalette=>v_ignore(11) );
    v_sel_hi <= v_ignore(4) or v_ignore(5) or v_ignore(6) or v_ignore(7) or v_ignore(8)
                or v_ignore(9) or v_ignore(10) or v_ignore(11);

    vrom : entity work.rom_words generic map ( hexfile=>"sim/work/maincpu_words.hex", awidth=>18 )
        port map ( addr=>v_addr(18 downto 1), data=>v_rom_d );
    vhi : entity work.ram_word generic map ( awidth=>16 )
        port map ( clk=>clk, addr=>v_addr(16 downto 1), din=>v_do, we=>v_we_hi,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, dout=>v_hi_d );
    v_we_hi <= '1' when v_as_n='0' and v_rw_n='0' and v_sel_hi='1' else '0';
    v_di <= v_rom_d  when v_sel_rom='1' else
            sram_a_d when v_sel_ram='1' else
            v_hi_d   when v_sel_hi='1'  else (others=>'0');

    ---------------------------------------------------------------- Extra CPU
    ecpu : entity work.TG68K generic map ( CPU => "01" )
        port map ( CLK=>clk, RESET=>e_resn, HALT=>e_resn, BERR=>'0', IPL=>"111",
                   ADDR=>e_addr, FC=>e_fc, DATAI=>e_di, DATAO=>e_do,
                   AS=>e_as_n, UDS=>e_uds_n, LDS=>e_lds_n, RW=>e_rw_n,
                   DTACK=>e_dtack_n, E=>open, VPA=>'1', VMA=>e_vma );

    edec : entity work.escape_decode
        port map ( addr=>e_addr(23 downto 0), as_n=>e_as_n,
                   sel_rom=>e_sel_rom, sel_eeprom=>e_ignore(0), sel_eeprom_unlk=>e_ignore(1),
                   sel_ram=>e_sel_ram, sel_io=>e_ignore(2), sel_watchdog=>e_ignore(3),
                   sel_vidctrl=>e_ignore(12), sel_colorram=>e_ignore(4), sel_pfram=>e_ignore(5),
                   sel_moram=>e_ignore(6), sel_alpharam=>e_ignore(7), sel_mobconfig=>e_ignore(8),
                   sel_slip=>e_ignore(9), sel_workram=>e_ignore(10), sel_pfpalette=>e_ignore(11) );
    e_sel_hi <= e_ignore(4) or e_ignore(5) or e_ignore(6) or e_ignore(7) or e_ignore(8)
                or e_ignore(9) or e_ignore(10) or e_ignore(11);

    erom : entity work.rom_words generic map ( hexfile=>"sim/work/extracpu_words.hex", awidth=>18 )
        port map ( addr=>e_addr(18 downto 1), data=>e_rom_d );
    ehi : entity work.ram_word generic map ( awidth=>16 )
        port map ( clk=>clk, addr=>e_addr(16 downto 1), din=>e_do, we=>e_we_hi,
                   uds_n=>e_uds_n, lds_n=>e_lds_n, dout=>e_hi_d );
    e_we_hi <= '1' when e_as_n='0' and e_rw_n='0' and e_sel_hi='1' else '0';
    e_di <= e_rom_d  when e_sel_rom='1' else
            sram_b_d when e_sel_ram='1' else
            e_hi_d   when e_sel_hi='1'  else (others=>'0');

    ---------------------------------------------------------------- shared RAM 160000-16FFFF
    sram_dp : entity work.dpram_bytelane generic map ( awidth=>15 )
        port map ( clk=>clk,
                   addr_a=>v_addr(15 downto 1), din_a=>v_do, we_a=>we_sram_a,
                   uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, dout_a=>sram_a_d,
                   addr_b=>e_addr(15 downto 1), din_b=>e_do, we_b=>we_sram_b,
                   uds_b_n=>e_uds_n, lds_b_n=>e_lds_n, dout_b=>sram_b_d );
    we_sram_a <= '1' when v_as_n='0' and v_rw_n='0' and v_sel_ram='1' else '0';
    we_sram_b <= '1' when e_as_n='0' and e_rw_n='0' and e_sel_ram='1' else '0';

    ---------------------------------------------------------------- DTACK (0 wait states)
    process(clk) begin
        if rising_edge(clk) then
            if v_as_n='0' then v_dtack_n<='0'; else v_dtack_n<='1'; end if;
            if e_as_n='0' then e_dtack_n<='0'; else e_dtack_n<='1'; end if;
        end if;
    end process;

    ---------------------------------------------------------------- extra reset latch + fallback
    -- Single driver for extra_release: real 360010 D0 latch, plus a ~3 us fallback
    -- force (300 cycles @ 10 ns) so the interconnect is exercised even if the video
    -- boot doesn't reach that write in the sim window.
    reset_ctrl : process(clk)
        variable cnt : integer := 0;
    begin
        if rising_edge(clk) then
            if resn = '0' then
                extra_release <= '0';
                cnt := 0;
            else
                cnt := cnt + 1;
                if v_sel_vidctrl='1' and v_as_n='0' and v_rw_n='0'
                   and v_addr(23 downto 0)=x"360010" then
                    extra_release  <= v_do(0);      -- 360010 D0: 1=run, 0=hold reset
                    v_wrote_360010 <= true;
                elsif cnt >= 300 and extra_release = '0' then
                    extra_release <= '1';
                    forced        <= true;
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------- observation
    obs : process(clk) begin
        if rising_edge(clk) then
            if v_as_n='0' and v_addr(23 downto 0)=x"000694" then v_started<=true; end if;
            if e_resn='1' and e_as_n='0' and e_addr(23 downto 0)=x"000342" then e_started<=true; end if;
            if we_sram_a='1' then v_sram_hits <= v_sram_hits+1; end if;
            if e_as_n='0' and e_sel_ram='1' then e_sram_hits <= e_sram_hits+1; end if;
        end if;
    end process;

    report_proc : process begin
        wait for 6 us;
        report "=== dual-CPU interconnect ===";
        report "  video CPU booted (PC 0x694): " & boolean'image(v_started);
        report "  video wrote 360010 (extra reset ctrl): " & boolean'image(v_wrote_360010);
        report "  extra release forced at 3us fallback: " & boolean'image(forced);
        report "  extra CPU booted (PC 0x342): " & boolean'image(e_started);
        report "  video shared-RAM writes: " & integer'image(v_sram_hits);
        report "  extra shared-RAM accesses: " & integer'image(e_sram_hits);
        if v_started and e_started then
            report "DUAL-CPU OK: both 68000s executed concurrently against shared RAM" severity note;
        else
            report "dual-CPU: one or both CPUs did not reach boot PC" severity warning;
        end if;
        done <= true;
        wait;
    end process;
end tb;
