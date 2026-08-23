-- Synthesizable true dual-port 16-bit RAM with per-port 68000 byte lanes.
-- Registered reads on both ports; hi/lo byte banks as shared variables (Quartus
-- TDP inference template). Used for the Escape shared program RAM (160000-16FFFF).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_bytelane_syn is
    generic (
        awidth : integer := 15;
        -- initial fill byte, as in spram_bytelane: x"00" for RAMs, x"FF" for
        -- the EEPROM (an erased 2804 reads FF and the game writes its factory
        -- defaults over it; an all-zeros part looks like valid settings with
        -- pricing 0, and start is then never accepted)
        initbyte : std_logic_vector(7 downto 0) := x"00"
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
    shared variable hi, lo : bank_t := (others => initbyte);
    signal qa_ram, qb_ram : std_logic_vector(15 downto 0) := (others=>'0');
    signal din_a_d, din_b_d : std_logic_vector(15 downto 0) := (others=>'0');
    signal col_a_hi, col_a_lo, col_b_hi, col_b_lo : std_logic := '0';
begin
    -- SDSCHED-82b: cross-port same-address collision bypass, restructured.
    -- The RAM processes stay in the pristine Quartus TDP inference shape
    -- ('82's in-process bypass broke inference - RAM exploded to registers).
    -- Collision flags and write data are registered alongside the RAM read;
    -- a downstream mux overrides the (synthesizer-undefined) colliding read
    -- with the in-flight write data. Real arcade VRAM returned old data;
    -- undefined reads = location-locked garble where MO churn is highest.
    port_a : process(clk)
    begin
        if rising_edge(clk) then
            if we_a='1' and uds_a_n='0' then hi(to_integer(unsigned(addr_a))) := din_a(15 downto 8); end if;
            if we_a='1' and lds_a_n='0' then lo(to_integer(unsigned(addr_a))) := din_a(7 downto 0);  end if;
            qa_ram(15 downto 8) <= hi(to_integer(unsigned(addr_a)));
            qa_ram(7 downto 0)  <= lo(to_integer(unsigned(addr_a)));
        end if;
    end process;

    port_b : process(clk)
    begin
        if rising_edge(clk) then
            if we_b='1' and uds_b_n='0' then hi(to_integer(unsigned(addr_b))) := din_b(15 downto 8); end if;
            if we_b='1' and lds_b_n='0' then lo(to_integer(unsigned(addr_b))) := din_b(7 downto 0);  end if;
            qb_ram(15 downto 8) <= hi(to_integer(unsigned(addr_b)));
            qb_ram(7 downto 0)  <= lo(to_integer(unsigned(addr_b)));
        end if;
    end process;

    bypass_track : process(clk)
    begin
        if rising_edge(clk) then
            col_a_hi <= '0'; col_a_lo <= '0';
            col_b_hi <= '0'; col_b_lo <= '0';
            if we_b='1' and addr_b = addr_a then
                if uds_b_n='0' then col_a_hi <= '1'; end if;
                if lds_b_n='0' then col_a_lo <= '1'; end if;
            end if;
            if we_a='1' and addr_a = addr_b then
                if uds_a_n='0' then col_b_hi <= '1'; end if;
                if lds_a_n='0' then col_b_lo <= '1'; end if;
            end if;
            din_a_d <= din_a;
            din_b_d <= din_b;
        end if;
    end process;

    q_a(15 downto 8) <= din_b_d(15 downto 8) when col_a_hi='1' else qa_ram(15 downto 8);
    q_a(7 downto 0)  <= din_b_d(7 downto 0)  when col_a_lo='1' else qa_ram(7 downto 0);
    q_b(15 downto 8) <= din_a_d(15 downto 8) when col_b_hi='1' else qb_ram(15 downto 8);
    q_b(7 downto 0)  <= din_a_d(7 downto 0)  when col_b_lo='1' else qb_ram(7 downto 0);
end rtl;
