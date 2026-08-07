-- Dual-port 16-bit RAM with per-port byte lanes (68000 UDS/LDS). Models the Escape
-- shared program RAM (160000-16FFFF) accessed by both the Video and Extra CPUs.
-- Combinational read per port, clocked write. Sim only (true dual-port; real hardware
-- arbitrates the two 68000s onto one bus, but this proves the shared-memory logic).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_bytelane is
    generic (
        awidth : integer := 15
    );
    port (
        clk     : in  std_logic;
        -- port A
        addr_a  : in  std_logic_vector(awidth-1 downto 0);
        din_a   : in  std_logic_vector(15 downto 0);
        we_a    : in  std_logic;
        uds_a_n : in  std_logic;
        lds_a_n : in  std_logic;
        dout_a  : out std_logic_vector(15 downto 0);
        -- port B
        addr_b  : in  std_logic_vector(awidth-1 downto 0);
        din_b   : in  std_logic_vector(15 downto 0);
        we_b    : in  std_logic;
        uds_b_n : in  std_logic;
        lds_b_n : in  std_logic;
        dout_b  : out std_logic_vector(15 downto 0)
    );
end dpram_bytelane;

architecture sim of dpram_bytelane is
    type mem_t is array (0 to 2**awidth-1) of std_logic_vector(15 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));
begin
    dout_a <= mem(to_integer(unsigned(addr_a)));
    dout_b <= mem(to_integer(unsigned(addr_b)));

    process (clk)
    begin
        if rising_edge(clk) then
            if we_a = '1' then
                if uds_a_n = '0' then mem(to_integer(unsigned(addr_a)))(15 downto 8) := din_a(15 downto 8); end if;
                if lds_a_n = '0' then mem(to_integer(unsigned(addr_a)))( 7 downto 0) := din_a( 7 downto 0); end if;
            end if;
            if we_b = '1' then
                if uds_b_n = '0' then mem(to_integer(unsigned(addr_b)))(15 downto 8) := din_b(15 downto 8); end if;
                if lds_b_n = '0' then mem(to_integer(unsigned(addr_b)))( 7 downto 0) := din_b( 7 downto 0); end if;
            end if;
        end if;
    end process;
end sim;
