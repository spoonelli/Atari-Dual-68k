-- Synthesizable true dual-port 16-bit RAM with per-port 68000 byte lanes.
-- Registered reads on both ports; hi/lo byte banks as shared variables (Quartus
-- TDP inference template). Used for the Escape shared program RAM (160000-16FFFF).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_bytelane_syn is
    generic (
        awidth : integer := 15
    );
    port (
        clk     : in  std_logic;
        addr_a  : in  std_logic_vector(awidth-1 downto 0);
        din_a   : in  std_logic_vector(15 downto 0);
        we_a    : in  std_logic;
        uds_a_n : in  std_logic;
        lds_a_n : in  std_logic;
        q_a     : out std_logic_vector(15 downto 0);
        addr_b  : in  std_logic_vector(awidth-1 downto 0);
        din_b   : in  std_logic_vector(15 downto 0);
        we_b    : in  std_logic;
        uds_b_n : in  std_logic;
        lds_b_n : in  std_logic;
        q_b     : out std_logic_vector(15 downto 0)
    );
end dpram_bytelane_syn;

architecture rtl of dpram_bytelane_syn is
    type bank_t is array (0 to 2**awidth-1) of std_logic_vector(7 downto 0);
    shared variable hi, lo : bank_t := (others => (others => '0'));
begin
    port_a : process(clk)
    begin
        if rising_edge(clk) then
            if we_a='1' and uds_a_n='0' then hi(to_integer(unsigned(addr_a))) := din_a(15 downto 8); end if;
            if we_a='1' and lds_a_n='0' then lo(to_integer(unsigned(addr_a))) := din_a(7 downto 0);  end if;
            q_a(15 downto 8) <= hi(to_integer(unsigned(addr_a)));
            q_a(7 downto 0)  <= lo(to_integer(unsigned(addr_a)));
        end if;
    end process;

    port_b : process(clk)
    begin
        if rising_edge(clk) then
            if we_b='1' and uds_b_n='0' then hi(to_integer(unsigned(addr_b))) := din_b(15 downto 8); end if;
            if we_b='1' and lds_b_n='0' then lo(to_integer(unsigned(addr_b))) := din_b(7 downto 0);  end if;
            q_b(15 downto 8) <= hi(to_integer(unsigned(addr_b)));
            q_b(7 downto 0)  <= lo(to_integer(unsigned(addr_b)));
        end if;
    end process;
end rtl;
