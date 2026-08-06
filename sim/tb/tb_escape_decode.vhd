-- Self-checking testbench for escape_decode (main/Video CPU address map, sheet 16).
-- Drives representative addresses (region boundaries, midpoints, and unmapped gaps)
-- and asserts that exactly the expected one-hot chip-select is active.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_decode is end tb_escape_decode;

architecture tb of tb_escape_decode is
    -- select vector index map (must match port wiring below)
    constant ROM      : integer := 0;
    constant EEPROM   : integer := 1;
    constant EE_UNLK  : integer := 2;
    constant RAM      : integer := 3;
    constant IO       : integer := 4;
    constant WDOG     : integer := 5;
    constant VIDCTRL  : integer := 6;
    constant COLOR    : integer := 7;
    constant PFRAM    : integer := 8;
    constant MORAM    : integer := 9;
    constant ALPHA    : integer := 10;
    constant MOBCFG   : integer := 11;
    constant SLIP     : integer := 12;
    constant WORKRAM  : integer := 13;
    constant PFPAL    : integer := 14;
    constant NONE     : integer := -1;

    signal addr : std_logic_vector(23 downto 0) := (others => '0');
    signal sel  : std_logic_vector(14 downto 0);
    signal errors : integer := 0;
begin
    uut: entity work.escape_decode
        port map (
            addr => addr, as_n => '0',
            sel_rom=>sel(ROM), sel_eeprom=>sel(EEPROM), sel_eeprom_unlk=>sel(EE_UNLK),
            sel_ram=>sel(RAM), sel_io=>sel(IO), sel_watchdog=>sel(WDOG),
            sel_vidctrl=>sel(VIDCTRL), sel_colorram=>sel(COLOR), sel_pfram=>sel(PFRAM),
            sel_moram=>sel(MORAM), sel_alpharam=>sel(ALPHA), sel_mobconfig=>sel(MOBCFG),
            sel_slip=>sel(SLIP), sel_workram=>sel(WORKRAM), sel_pfpalette=>sel(PFPAL));

    stim: process
        variable err : integer := 0;

        procedure chk(a : integer; idx : integer; name : string) is
            variable exp : std_logic_vector(14 downto 0) := (others => '0');
        begin
            addr <= std_logic_vector(to_unsigned(a, 24));
            wait for 1 ns;
            if idx /= NONE then exp(idx) := '1'; end if;
            if sel /= exp then
                report "MISMATCH @ 0x" & to_hstring(to_unsigned(a, 24))
                       & " (" & name & "): got " & to_string(sel)
                       & " exp " & to_string(exp) severity error;
                err := err + 1;
            end if;
        end procedure;
    begin
        chk(16#000000#, ROM,     "rom base");
        chk(16#05FFFF#, ROM,     "rom end");
        chk(16#060000#, ROM,     "rom shared base");
        chk(16#07FFFF#, ROM,     "rom shared end");
        chk(16#080000#, ROM,     "rom hi base");
        chk(16#09FFFF#, ROM,     "rom hi end");
        chk(16#0A0000#, NONE,    "gap after rom");
        chk(16#0E0000#, EEPROM,  "eeprom base");
        chk(16#0E2FFF#, EEPROM,  "eeprom end");
        chk(16#0E3000#, NONE,    "gap after eeprom");
        chk(16#1F0000#, EE_UNLK, "eeprom unlock");
        chk(16#160000#, RAM,     "shared ram base");
        chk(16#16FFFF#, RAM,     "shared ram end");
        chk(16#170000#, NONE,    "gap after ram");
        chk(16#260000#, IO,      "io p1");
        chk(16#260010#, IO,      "io p2/status");
        chk(16#260020#, IO,      "adc0");
        chk(16#260026#, IO,      "adc3");
        chk(16#260030#, IO,      "scom read");
        chk(16#2E0000#, WDOG,    "watchdog");
        chk(16#360000#, VIDCTRL, "vblank ack");
        chk(16#360010#, VIDCTRL, "latch");
        chk(16#360030#, VIDCTRL, "scom write");
        chk(16#3E0000#, COLOR,   "color ram alpha");
        chk(16#3E0200#, COLOR,   "color ram MO");
        chk(16#3E0FFF#, COLOR,   "color ram end");
        chk(16#3F0000#, PFRAM,   "playfield ram");
        chk(16#3F1FFF#, PFRAM,   "playfield ram end");
        chk(16#3F2000#, MORAM,   "motion object ram");
        chk(16#3F3FFF#, MORAM,   "motion object ram end");
        chk(16#3F4000#, ALPHA,   "alpha ram");
        chk(16#3F4EFF#, ALPHA,   "alpha ram end");
        chk(16#3F4F00#, MOBCFG,  "mob config base");
        chk(16#3F4F7F#, MOBCFG,  "mob config end");
        chk(16#3F4F80#, SLIP,    "slip pointers base");
        chk(16#3F4FFF#, SLIP,    "slip pointers end");
        chk(16#3F5000#, WORKRAM, "working ram base");
        chk(16#3F7FFF#, WORKRAM, "working ram end");
        chk(16#3F8000#, PFPAL,   "pf palette base");
        chk(16#3F9FFF#, PFPAL,   "pf palette end");
        chk(16#3FA000#, NONE,    "gap after pf palette");

        errors <= err;
        if err = 0 then
            report "tb_escape_decode: ALL CHECKS PASSED" severity note;
        else
            report "tb_escape_decode: " & integer'image(err) & " FAILURES" severity failure;
        end if;
        wait;
    end process;
end tb;
