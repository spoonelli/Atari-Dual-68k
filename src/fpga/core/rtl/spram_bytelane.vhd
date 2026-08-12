-- Synthesizable single-port 16-bit RAM with 68000 byte lanes (UDS/LDS).
-- Registered read (1 wait state), independent hi/lo byte banks so partial writes
-- never disturb the other byte. Infers Cyclone V M10K BRAM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spram_bytelane is
    generic (
        awidth : integer := 12;                 -- word-address bits
        -- initial fill byte: x"00" for RAMs; x"FF" for the EEPROM (a real
        -- erased 2804 reads FF - the game detects the virgin pattern and
        -- writes factory defaults; an all-zeros part reads as pathological
        -- 'valid-shaped' settings with pricing 0 = start never accepted)
        initbyte : std_logic_vector(7 downto 0) := x"00"
    );
    port (
        clk   : in  std_logic;
        addr  : in  std_logic_vector(awidth-1 downto 0);
        din   : in  std_logic_vector(15 downto 0);
        we    : in  std_logic;
        uds_n : in  std_logic;
        lds_n : in  std_logic;
        q     : out std_logic_vector(15 downto 0)
    );
end spram_bytelane;

architecture rtl of spram_bytelane is
    type bank_t is array (0 to 2**awidth-1) of std_logic_vector(7 downto 0);
    signal hi, lo : bank_t := (others => initbyte);
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if we='1' and uds_n='0' then
                hi(to_integer(unsigned(addr))) <= din(15 downto 8);
            end if;
            if we='1' and lds_n='0' then
                lo(to_integer(unsigned(addr))) <= din(7 downto 0);
            end if;
            q(15 downto 8) <= hi(to_integer(unsigned(addr)));
            q(7 downto 0)  <= lo(to_integer(unsigned(addr)));
        end if;
    end process;
end rtl;
