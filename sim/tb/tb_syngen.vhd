-- Smoke + timing testbench for the Atari System 1 sync generator (SYNGEN).
-- Clocks it and measures the horizontal line length (clocks between HSYNC edges)
-- and the peak H counter value. Proves the native GHDL simulate loop end-to-end and
-- gives us real horizontal timing to compare against Escape's 456-clock line.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_syngen is end tb_syngen;

architecture tb of tb_syngen is
    signal ck : std_logic := '0';
    signal hsyncn, vsyncn, hblkn, vblkn, vidbn, vresn : std_logic;
    signal hh : std_logic_vector(8 downto 0);
    signal vv : std_logic_vector(7 downto 0);
    -- outputs we don't check but must connect
    signal c0,c1,c2,lmpdn,pfhstn,bufclrn,vsck,ck0n,ck0,h2dl,h4dl,h4dd,nxl : std_logic;
    signal done : boolean := false;
begin
    uut: entity work.SYNGEN
        port map(
            I_CK=>ck, O_C0=>c0, O_C1=>c1, O_C2=>c2, O_LMPDn=>lmpdn,
            O_VIDBn=>vidbn, O_VRESn=>vresn, O_HSYNCn=>hsyncn, O_VSYNCn=>vsyncn,
            O_PFHSTn=>pfhstn, O_BUFCLRn=>bufclrn, O_HBLKn=>hblkn, O_VBLKn=>vblkn,
            O_VSCK=>vsck, O_CK0n=>ck0n, O_CK0=>ck0, O_2HDLn=>h2dl, O_4HDLn=>h4dl,
            O_4HDDn=>h4dd, O_NXLn=>nxl, O_V=>vv, O_H=>hh);

    clk: process begin
        while not done loop
            ck <= '0'; wait for 5 ns;
            ck <= '1'; wait for 5 ns;
        end loop;
        wait;
    end process;

    stim: process
        variable maxh      : integer := 0;
        variable clkcnt    : integer := 0;
        variable edge_clk  : integer := -1;
        variable hsync_prev: std_logic := '1';
        variable reported  : integer := 0;
    begin
        for i in 0 to 4000 loop
            wait until rising_edge(ck);
            clkcnt := clkcnt + 1;
            if to_integer(unsigned(hh)) > maxh then
                maxh := to_integer(unsigned(hh));
            end if;
            if hsync_prev = '1' and hsyncn = '0' then      -- HSYNC falling edge
                if edge_clk >= 0 and reported < 3 then
                    report "HSYNC line length = " & integer'image(clkcnt - edge_clk)
                           & " clocks";
                    reported := reported + 1;
                end if;
                edge_clk := clkcnt;
            end if;
            hsync_prev := hsyncn;
        end loop;
        report "SYNGEN simulated " & integer'image(clkcnt)
               & " clocks OK; peak H counter = " & integer'image(maxh);
        done <= true;
        wait;
    end process;
end tb;
