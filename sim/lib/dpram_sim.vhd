-- Behavioral dual-port RAM for GHDL simulation, drop-in for the Altera
-- megafunction wrapper (third_party/.../rtl/lib/mem/dpram.vhd). Same entity
-- name/ports so instantiations bind unchanged. BIDIR_DUAL_PORT, unregistered
-- output, NEW_DATA read-during-write (matches the original config).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram is
    generic (
        addr_width_g : integer := 8;
        data_width_g : integer := 8
    );
    port (
        address_a : in  std_logic_vector(addr_width_g-1 downto 0);
        address_b : in  std_logic_vector(addr_width_g-1 downto 0);
        clock_a   : in  std_logic := '1';
        clock_b   : in  std_logic;
        data_a    : in  std_logic_vector(data_width_g-1 downto 0);
        data_b    : in  std_logic_vector(data_width_g-1 downto 0) := (others => '0');
        enable_a  : in  std_logic := '1';
        enable_b  : in  std_logic := '1';
        wren_a    : in  std_logic := '0';
        wren_b    : in  std_logic := '0';
        q_a       : out std_logic_vector(data_width_g-1 downto 0);
        q_b       : out std_logic_vector(data_width_g-1 downto 0)
    );
end dpram;

architecture sim of dpram is
    type mem_t is array (0 to 2**addr_width_g-1) of std_logic_vector(data_width_g-1 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));
begin
    process(clock_a)
    begin
        if rising_edge(clock_a) then
            if enable_a = '1' then
                if wren_a = '1' then
                    mem(to_integer(unsigned(address_a))) := data_a;
                    q_a <= data_a;
                else
                    q_a <= mem(to_integer(unsigned(address_a)));
                end if;
            end if;
        end if;
    end process;

    process(clock_b)
    begin
        if rising_edge(clock_b) then
            if enable_b = '1' then
                if wren_b = '1' then
                    mem(to_integer(unsigned(address_b))) := data_b;
                    q_b <= data_b;
                else
                    q_b <= mem(to_integer(unsigned(address_b)));
                end if;
            end if;
        end if;
    end process;
end sim;
