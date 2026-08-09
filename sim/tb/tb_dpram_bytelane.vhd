-- Unit test for dpram_bytelane_syn: the shared program RAM the extra CPU's
-- destructive RAM test (extra ROM 0x440) hammers. Verifies word writes, byte
-- lanes (UDS=hi/even, LDS=lo/odd), registered-read data, and cross-port
-- coherency (port A writes visible on port B and vice-versa). If any of these
-- is wrong, the extra CPU's power-on RAM test fails and it never answers the
-- mailbox -> "Waiting for Second Processor" forever.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_dpram_bytelane is end tb_dpram_bytelane;

architecture tb of tb_dpram_bytelane is
    signal clk : std_logic := '0';
    signal done : boolean := false;
    signal aa, ab : std_logic_vector(14 downto 0) := (others=>'0');
    signal da, db : std_logic_vector(15 downto 0) := (others=>'0');
    signal wea, web : std_logic := '0';
    signal udsa, ldsa, udsb, ldsb : std_logic := '1';
    signal qa, qb : std_logic_vector(15 downto 0);
    signal fails : integer := 0;

    procedure step(signal c : std_logic) is begin
        wait until rising_edge(c);
    end procedure;
begin
    clk <= not clk after 5 ns when not done else '0';

    dut : entity work.dpram_bytelane_syn generic map ( awidth => 15 )
        port map ( clk=>clk,
                   addr_a=>aa, din_a=>da, we_a=>wea, uds_a_n=>udsa, lds_a_n=>ldsa, q_a=>qa,
                   addr_b=>ab, din_b=>db, we_b=>web, uds_b_n=>udsb, lds_b_n=>ldsb, q_b=>qb );

    stim : process
        procedure wr_a(addr : integer; d : std_logic_vector(15 downto 0); u,l : std_logic) is
        begin
            aa <= std_logic_vector(to_unsigned(addr,15)); da <= d; udsa<=u; ldsa<=l; wea<='1';
            wait until rising_edge(clk);
            wea<='0'; udsa<='1'; ldsa<='1';
        end procedure;
        procedure wr_b(addr : integer; d : std_logic_vector(15 downto 0); u,l : std_logic) is
        begin
            ab <= std_logic_vector(to_unsigned(addr,15)); db <= d; udsb<=u; ldsb<=l; web<='1';
            wait until rising_edge(clk);
            web<='0'; udsb<='1'; ldsb<='1';
        end procedure;
        -- read port A: present address, wait for registered data
        procedure rd_a(addr : integer; expect : std_logic_vector(15 downto 0); tag : string) is
        begin
            aa <= std_logic_vector(to_unsigned(addr,15));
            wait until rising_edge(clk);      -- address registered
            wait until rising_edge(clk);      -- data valid
            if qa /= expect then
                report tag & " A["&integer'image(addr)&"]=0x"&to_hstring(qa)&" expected 0x"&to_hstring(expect) severity warning;
                fails <= fails + 1;
            end if;
        end procedure;
        procedure rd_b(addr : integer; expect : std_logic_vector(15 downto 0); tag : string) is
        begin
            ab <= std_logic_vector(to_unsigned(addr,15));
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            if qb /= expect then
                report tag & " B["&integer'image(addr)&"]=0x"&to_hstring(qb)&" expected 0x"&to_hstring(expect) severity warning;
                fails <= fails + 1;
            end if;
        end procedure;
    begin
        wait until rising_edge(clk);
        -- 1) word write on A, read back on A
        wr_a(5, x"A55A", '0','0');
        rd_a(5, x"A55A", "word-A");
        -- 2) coherency: A write visible on B
        rd_b(5, x"A55A", "coh-A2B");
        -- 3) word write on B, read on A (coherency both ways)
        wr_b(6, x"1234", '0','0');
        rd_a(6, x"1234", "coh-B2A");
        -- 4) byte lanes: start 0x0000, write only UDS(hi)=0xAB -> expect 0xAB00
        wr_a(7, x"0000", '0','0');       -- clear
        wr_a(7, x"ABCD", '0','1');       -- UDS only: hi<=0xAB, lo untouched(=0x00)
        rd_a(7, x"AB00", "uds-hi");
        -- 5) byte lanes: write only LDS(lo)=0xEF over prior -> expect 0xABEF
        wr_a(7, x"12EF", '1','0');       -- LDS only: lo<=0xEF, hi untouched(=0xAB)
        rd_a(7, x"ABEF", "lds-lo");
        -- 6) byte write from port B lane check
        wr_b(8, x"0000", '0','0');
        wr_b(8, x"55AA", '1','0');       -- LDS: lo<=0xAA
        rd_b(8, x"00AA", "lds-B");
        wr_b(8, x"5500", '0','1');       -- UDS: hi<=0x55
        rd_b(8, x"55AA", "uds-B");
        -- 7) small march: fill 0..15 via B, verify via A
        for i in 0 to 15 loop
            wr_b(i, std_logic_vector(to_unsigned(16#C000# + i,16)), '0','0');
        end loop;
        for i in 0 to 15 loop
            rd_a(i, std_logic_vector(to_unsigned(16#C000# + i,16)), "march");
        end loop;

        wait until rising_edge(clk);
        report "=== dpram byte-lane check ===";
        if fails = 0 then
            report "DPRAM OK: word/byte lanes and cross-port coherency correct" severity note;
        else
            report "DPRAM FAIL: " & integer'image(fails) & " mismatches" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
