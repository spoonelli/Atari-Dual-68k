-- Escape "Video" (main) 68000 address decoder.
-- Original RTL derived from the authoritative memory map (schematic SP-332, sheet 16;
-- see docs/ARCHITECTURE.md). Combinational one-hot chip-selects, active high.
--
-- Input `addr` is the 68000 byte address (A23..A0). The 68000 has no A0 pin; byte lane
-- selection is via UDS/LDS, which this decoder does not need. `as_n` is the address
-- strobe (active low): selects are forced inactive when the bus cycle is not valid.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity escape_decode is
    port (
        addr            : in  std_logic_vector(23 downto 0); -- 68000 byte address
        as_n            : in  std_logic := '0';              -- address strobe (0 = valid)

        sel_rom         : out std_logic; -- 000000-05FFFF, 060000-07FFFF (shared), 080000-09FFFF
        sel_eeprom      : out std_logic; -- 0E0000-0E2FFF
        sel_eeprom_unlk : out std_logic; -- 1Fxxxx  (write: unlock EEPROM)
        sel_ram         : out std_logic; -- 160000-16FFFF (shared program RAM)
        sel_io          : out std_logic; -- 260000-26003F (P1/P2, ADC0-3, SCOM read, status)
        sel_watchdog    : out std_logic; -- 2E0000
        sel_vidctrl     : out std_logic; -- 360000-36003F (vblank ack, latch, snd reset, SCOM wr)
        sel_colorram    : out std_logic; -- 3E0000-3E0FFF (alpha/MO/pf/shadow/stain)
        sel_pfram       : out std_logic; -- 3F0000-3F1FFF (playfield picture)
        sel_moram       : out std_logic; -- 3F2000-3F3FFF (motion object)
        sel_alpharam    : out std_logic; -- 3F4000-3F4EFF (alphanumerics)
        sel_mobconfig   : out std_logic; -- 3F4F00-3F4F7F (scroll & MOB config)
        sel_slip        : out std_logic; -- 3F4F80-3F4FFF (SLIP / MO link pointers)
        sel_workram     : out std_logic; -- 3F5000-3F7FFF (working RAM)
        sel_pfpalette   : out std_logic  -- 3F8000-3F9FFF (playfield palette)
    );
end escape_decode;

architecture rtl of escape_decode is
    signal a  : unsigned(23 downto 0);
    signal en : std_logic;
begin
    a  <= unsigned(addr);
    en <= not as_n;

    process (a, en)
    begin
        sel_rom         <= '0';
        sel_eeprom      <= '0';
        sel_eeprom_unlk <= '0';
        sel_ram         <= '0';
        sel_io          <= '0';
        sel_watchdog    <= '0';
        sel_vidctrl     <= '0';
        sel_colorram    <= '0';
        sel_pfram       <= '0';
        sel_moram       <= '0';
        sel_alpharam    <= '0';
        sel_mobconfig   <= '0';
        sel_slip        <= '0';
        sel_workram     <= '0';
        sel_pfpalette   <= '0';

        if en = '1' then
            if    a <= x"05FFFF"                          then sel_rom         <= '1';
            elsif a >= x"060000" and a <= x"07FFFF"       then sel_rom         <= '1';
            elsif a >= x"080000" and a <= x"09FFFF"       then sel_rom         <= '1';
            elsif a >= x"0E0000" and a <= x"0E2FFF"       then sel_eeprom      <= '1';
            elsif a >= x"1F0000" and a <= x"1FFFFF"       then sel_eeprom_unlk <= '1';
            elsif a >= x"160000" and a <= x"16FFFF"       then sel_ram         <= '1';
            elsif a >= x"260000" and a <= x"26003F"       then sel_io          <= '1';
            elsif a >= x"2E0000" and a <= x"2E0001"       then sel_watchdog    <= '1';
            elsif a >= x"360000" and a <= x"36003F"       then sel_vidctrl     <= '1';
            elsif a >= x"3E0000" and a <= x"3E0FFF"       then sel_colorram    <= '1';
            elsif a >= x"3F0000" and a <= x"3F1FFF"       then sel_pfram       <= '1';
            elsif a >= x"3F2000" and a <= x"3F3FFF"       then sel_moram       <= '1';
            elsif a >= x"3F4000" and a <= x"3F4EFF"       then sel_alpharam    <= '1';
            elsif a >= x"3F4F00" and a <= x"3F4F7F"       then sel_mobconfig   <= '1';
            elsif a >= x"3F4F80" and a <= x"3F4FFF"       then sel_slip        <= '1';
            elsif a >= x"3F5000" and a <= x"3F7FFF"       then sel_workram     <= '1';
            elsif a >= x"3F8000" and a <= x"3F9FFF"       then sel_pfpalette   <= '1';
            end if;
        end if;
    end process;
end rtl;
