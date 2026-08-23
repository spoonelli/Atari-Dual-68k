-- Equivalence check for the EEPROM RAM swap.
--
-- EESAVE-100 moved the 2804 EEPROM from spram_bytelane to dpram_bytelane_syn so
-- the save engine could have a second port. That is a change to a RAM the
-- 68000 boots through, so "port A behaves identically" needs proving, not
-- asserting. The two components differ in one place: spram_bytelane stores in
-- SIGNALS (a read scheduled alongside a write to the same address returns the
-- OLD byte) while dpram_bytelane_syn stores in SHARED VARIABLES (it returns the
-- NEW byte - the Quartus true-dual-port inference template requires that shape).
--
-- This testbench drives both parts from one stimulus stream, port B of the dual
-- left idle exactly as escape_core leaves it when the save engine is not
-- copying, and compares q every cycle.
--
-- Both RAMs register their reads, so the q visible in cycle T belongs to the
-- access driven in cycle T-1. That is what decides whether a mismatch matters:
--
--   * q captured while the PREVIOUS cycle was a write -> the known
--     read-during-write difference, and dead data either way. escape_core only
--     consults ee_q on read cycles ("ee_q when v_sel_eeprom='1'"), and a 68000
--     discards the data input during a write cycle, so nothing ever looks at
--     this value.
--   * q captured while the previous cycle was a READ -> data the CPU actually
--     consumes. Any difference there is a genuine behavioural change to a RAM
--     the boot depends on, and this testbench fails.
--
-- (The first cut of this file compared the previous WRITE address against the
-- CURRENT one and cried wolf 64 times on a write followed by a read of some
-- other address - which is the same benign case, just one cycle out of step.)
--
-- The stimulus deliberately includes the patterns the self-test uses: byte
-- writes on each lane, write-then-immediately-read of the same location, walking
-- addresses, and reads of never-written locations (which must return the erased
-- 2804's FF from BOTH parts - the game keys its factory-defaults path on that).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ee_ram_equiv is end tb_ee_ram_equiv;

architecture tb of tb_ee_ram_equiv is
    signal clk  : std_logic := '0';
    signal done : boolean := false;

    signal addr  : std_logic_vector(8 downto 0) := (others=>'0');
    signal din   : std_logic_vector(15 downto 0) := (others=>'0');
    signal we    : std_logic := '0';
    signal uds_n : std_logic := '1';
    signal lds_n : std_logic := '1';

    signal q_sp, q_dp : std_logic_vector(15 downto 0);

    -- port B of the dual, tied off the way escape_core leaves it when idle
    signal zero9  : std_logic_vector(8 downto 0)  := (others=>'0');
    signal ffdin  : std_logic_vector(15 downto 0) := (others=>'1');
    signal q_b    : std_logic_vector(15 downto 0);

    -- what the previous cycle did, so a mismatch can be classified
    signal pwe    : std_logic := '0';
    signal paddr  : std_logic_vector(8 downto 0) := (others=>'0');

    signal rdw_diffs  : integer := 0;   -- expected read-during-write differences
    signal real_diffs : integer := 0;   -- anything else: a genuine regression
    signal compares   : integer := 0;
    signal checking   : boolean := false;
begin

    clk <= not clk after 5 ns when not done else '0';

    sp : entity work.spram_bytelane
        generic map ( awidth=>9, initbyte=>x"FF" )
        port map ( clk=>clk, addr=>addr, din=>din, we=>we,
                   uds_n=>uds_n, lds_n=>lds_n, q=>q_sp );

    dp : entity work.dpram_bytelane_syn
        generic map ( awidth=>9, initbyte=>x"FF" )
        port map ( clk=>clk,
                   addr_a=>addr, din_a=>din, we_a=>we,
                   uds_a_n=>uds_n, lds_a_n=>lds_n, q_a=>q_dp,
                   addr_b=>zero9, din_b=>ffdin, we_b=>'0',
                   uds_b_n=>'1', lds_b_n=>'1', q_b=>q_b );

    -- record what drove the RAMs each cycle; q reflects it on the next one
    hist : process(clk)
    begin
        if rising_edge(clk) then
            pwe   <= we;
            paddr <= addr;
        end if;
    end process;

    -- compare continuously: every cycle after the first is a data point
    cmp : process(clk)
    begin
        if rising_edge(clk) then
            if checking then
                compares <= compares + 1;
                if q_sp /= q_dp then
                    if pwe = '1' then
                        -- q belongs to a write cycle: nothing reads it
                        rdw_diffs <= rdw_diffs + 1;
                    else
                        report "REAL divergence on a READ of addr 0x"
                             & to_hstring(paddr)
                             & ": spram=0x" & to_hstring(q_sp)
                             & " dpram=0x" & to_hstring(q_dp)
                             severity warning;
                        real_diffs <= real_diffs + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    stim : process
        procedure drive(a : integer; d : std_logic_vector(15 downto 0);
                        w, u, l : std_logic) is
        begin
            addr  <= std_logic_vector(to_unsigned(a,9));
            din   <= d;
            we    <= w;
            uds_n <= u;
            lds_n <= l;
            wait until rising_edge(clk);
        end procedure;

        procedure rd(a : integer) is begin drive(a, x"0000", '0','1','1'); end procedure;
        -- a 68000 byte store to an odd address: LDS only, which is the only way
        -- this part is ever written on the real board
        procedure wrlo(a : integer; b : std_logic_vector(7 downto 0)) is
        begin drive(a, x"FF" & b, '1','1','0'); end procedure;
        procedure wrhi(a : integer; b : std_logic_vector(7 downto 0)) is
        begin drive(a, b & x"FF", '1','0','1'); end procedure;
        procedure wrw(a : integer; d : std_logic_vector(15 downto 0)) is
        begin drive(a, d, '1','0','0'); end procedure;
    begin
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        checking <= true;

        -- 1) erased part: every location must read FF from both
        for a in 0 to 31 loop
            rd(a);
        end loop;
        rd(511); rd(256); rd(1);

        -- 2) byte stores on the real lane, then read back
        for a in 0 to 15 loop
            wrlo(a, std_logic_vector(to_unsigned(16#A0# + a, 8)));
            rd(a);
            rd(a);
        end loop;

        -- 3) write immediately followed by a read of the SAME address with no
        --    idle cycle - the pattern that exposes read-during-write
        for a in 20 to 27 loop
            wrlo(a, x"5A");
            rd(a);
        end loop;

        -- 4) back-to-back writes to the same address (no read between)
        wrlo(30, x"11");
        wrlo(30, x"22");
        wrlo(30, x"33");
        rd(30);
        rd(30);

        -- 5) the other lane and full words, to prove lane independence matches
        wrhi(40, x"7E");
        rd(40);
        wrlo(40, x"7F");
        rd(40);
        wrw(41, x"1234");
        rd(41);

        -- 6) walking address, write then read elsewhere then read back
        for i in 0 to 63 loop
            wrlo(100 + i, std_logic_vector(to_unsigned(i, 8)));
            rd(0);
            rd(100 + i);
        end loop;

        -- 7) top and bottom of the 512-location part
        wrlo(0,   x"C3");  rd(0);
        wrlo(511, x"3C");  rd(511);
        rd(510);           -- never written: still FF from both

        drive(0, x"0000", '0','1','1');
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        checking <= false;
        wait until rising_edge(clk);

        report "=== EEPROM RAM swap equivalence ===";
        report "  cycles compared:              " & integer'image(compares);
        report "  read-during-write differences: " & integer'image(rdw_diffs)
             & "  (q of a write cycle; nothing reads it)";
        report "  divergences on real reads:     " & integer'image(real_diffs);
        if real_diffs = 0 then
            report "EE_RAM_EQUIV OK: dpram_bytelane_syn port A matches spram_bytelane "
                 & "on every read cycle - the EEPROM swap is behaviour-preserving "
                 & "for the 68000" severity note;
        else
            report "EE_RAM_EQUIV FAIL: " & integer'image(real_diffs)
                 & " genuine divergences - the EEPROM swap changes what the CPU reads"
                 severity failure;
        end if;
        done <= true;
        wait;
    end process;

end tb;
