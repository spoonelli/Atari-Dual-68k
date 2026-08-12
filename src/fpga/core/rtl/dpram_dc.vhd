-- Simple dual-port RAM with independent write/read clocks (16-bit).
-- v58: hot-code shadow storage - written by the ROM download in the SDRAM
-- clock domain, read by a 68000 in the CPU clock domain. Quartus infers
-- dual-clock M10K; GHDL simulates directly.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_dc is
    generic ( awidth : integer := 15 );
    port (
        wrclk : in  std_logic;
        we    : in  std_logic;
        waddr : in  std_logic_vector(awidth-1 downto 0);
        wdata : in  std_logic_vector(15 downto 0);
        rdclk : in  std_logic;
        raddr : in  std_logic_vector(awidth-1 downto 0);
        q     : out std_logic_vector(15 downto 0)
    );
end dpram_dc;

architecture rtl of dpram_dc is
    type ram_t is array (0 to 2**awidth - 1) of std_logic_vector(15 downto 0);
    shared variable ram : ram_t := (others => (others => '0'));
begin
    wr : process(wrclk)
    begin
        if rising_edge(wrclk) then
            if we = '1' then
                ram(to_integer(unsigned(waddr))) := wdata;
            end if;
        end if;
    end process;
    rd : process(rdclk)
    begin
        if rising_edge(rdclk) then
            q <= ram(to_integer(unsigned(raddr)));
        end if;
    end process;
end rtl;
