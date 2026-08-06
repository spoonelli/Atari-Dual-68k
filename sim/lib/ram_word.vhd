-- Simulation RAM: 16-bit wide with independent byte lanes (68000 UDS/LDS).
-- Combinational read, clocked write. Not synthesizable (sim bring-up only).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ram_word is
    generic (
        awidth : integer := 15             -- word-address width
    );
    port (
        clk   : in  std_logic;
        addr  : in  std_logic_vector(awidth-1 downto 0);
        din   : in  std_logic_vector(15 downto 0);
        we    : in  std_logic;             -- write enable (active high)
        uds_n : in  std_logic;             -- upper byte lane (active low)
        lds_n : in  std_logic;             -- lower byte lane (active low)
        dout  : out std_logic_vector(15 downto 0)
    );
end ram_word;

architecture sim of ram_word is
    type mem_t is array (0 to 2**awidth-1) of std_logic_vector(15 downto 0);
    signal mem : mem_t := (others => (others => '0'));
begin
    dout <= mem(to_integer(unsigned(addr)));

    process (clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                if uds_n = '0' then
                    mem(to_integer(unsigned(addr)))(15 downto 8) <= din(15 downto 8);
                end if;
                if lds_n = '0' then
                    mem(to_integer(unsigned(addr)))(7 downto 0) <= din(7 downto 0);
                end if;
            end if;
        end if;
    end process;
end sim;
