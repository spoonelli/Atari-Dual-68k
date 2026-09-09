-- GUTS-166: escape_decode in both video maps. Every block boundary of the
-- Escape map (SP-332 sheet 16) and of MAME's guts_map is probed at its first
-- and last byte address plus one address outside each end; exactly one select
-- must be active inside, none of the video selects outside. Common blocks
-- (ROM, EEPROM, shared RAM, I/O, watchdog, vidctrl, colour RAM) must decode
-- identically in both maps. Run: ./sim/run_tb.sh tb_escape_vmap 1us  (the Escape-only map has its own bench, tb_escape_decode)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_vmap is end tb_escape_vmap;

architecture tb of tb_escape_vmap is
    signal addr : std_logic_vector(23 downto 0) := (others => '0');
    type selv is array (0 to 1) of std_logic_vector(14 downto 0);
    signal sel : selv;
begin
    g : for m in 0 to 1 generate
        d : entity work.escape_decode generic map ( VIDEO_MAP => m )
            port map ( addr => addr, as_n => '0',
                sel_rom => sel(m)(0), sel_eeprom => sel(m)(1), sel_eeprom_unlk => sel(m)(2),
                sel_ram => sel(m)(3), sel_io => sel(m)(4), sel_watchdog => sel(m)(5),
                sel_vidctrl => sel(m)(6), sel_colorram => sel(m)(7), sel_pfram => sel(m)(8),
                sel_moram => sel(m)(9), sel_alpharam => sel(m)(10), sel_mobconfig => sel(m)(11),
                sel_slip => sel(m)(12), sel_workram => sel(m)(13), sel_pfpalette => sel(m)(14) );
    end generate;

    check : process
        type rng is record lo, hi : integer; bit : integer; end record;
        type rngs is array (natural range <>) of rng;
        -- video blocks per map (bit index into sel)
        constant ESC : rngs := ((16#3F0000#,16#3F1FFF#,8),(16#3F2000#,16#3F3FFF#,9),(16#3F4000#,16#3F4EFF#,10),
                                (16#3F4F00#,16#3F4F7F#,11),(16#3F4F80#,16#3F4FFF#,12),(16#3F5000#,16#3F7FFF#,13),
                                (16#3F8000#,16#3F9FFF#,14));
        constant GUT : rngs := ((16#FF0000#,16#FF1FFF#,14),(16#FF8000#,16#FF9FFF#,8),(16#FFA000#,16#FFBFFF#,9),
                                (16#FFC000#,16#FFCEFF#,10),(16#FFCF00#,16#FFCF7F#,11),(16#FFCF80#,16#FFCFFF#,12),
                                (16#FFD000#,16#FFFFFF#,13));
        constant COMMON : rngs := ((16#000000#,16#09FFFF#,0),(16#0E0000#,16#0E2FFF#,1),(16#1F0000#,16#1FFFFF#,2),
                                   (16#160000#,16#16FFFF#,3),(16#260000#,16#26003F#,4),(16#2E0000#,16#2E0001#,5),
                                   (16#360000#,16#36003F#,6),(16#3E0000#,16#3E0FFF#,7));
        variable errs : integer := 0;
        procedure probe(a : integer; m : integer; want : integer) is   -- want = bit or -1 for none
            variable exp : std_logic_vector(14 downto 0) := (others => '0');
        begin
            addr <= std_logic_vector(to_unsigned(a, 24)); wait for 1 ns;
            if want >= 0 then exp(want) := '1'; end if;
            if sel(m) /= exp then
                errs := errs + 1;
                report "map " & integer'image(m) & " addr " & to_hstring(to_unsigned(a,24)) & " got " & to_string(sel(m)) & " want " & to_string(exp) severity warning;
            end if;
        end procedure;
        procedure probe_set(r : rngs; m : integer) is
        begin
            for i in r'range loop
                probe(r(i).lo, m, r(i).bit); probe(r(i).hi, m, r(i).bit);
                probe(r(i).lo + (r(i).hi - r(i).lo)/2, m, r(i).bit);
            end loop;
        end procedure;
    begin
        for m in 0 to 1 loop
            probe_set(COMMON, m);
            if m = 0 then probe_set(ESC, m); else probe_set(GUT, m); end if;
        end loop;
        -- the other map's video block must be dead in each map
        for i in GUT'range loop probe(GUT(i).lo, 0, -1); probe(GUT(i).hi, 0, -1); end loop;
        for i in ESC'range loop probe(ESC(i).lo, 1, -1); probe(ESC(i).hi, 1, -1); end loop;
        -- gaps: just outside each video block on both sides
        probe(16#3EFFFF#, 0, -1); probe(16#3FA000#, 0, -1); probe(16#FF2000#, 1, -1); probe(16#FF7FFF#, 1, -1);
        if errs = 0 then
            report "TB_ESCAPE_VMAP OK: Escape and Guts maps decode as specified" severity note;
        else
            report "tb_escape_vmap: " & integer'image(errs) & " mismatches" severity failure;
        end if;
        wait;
    end process;
end tb;
