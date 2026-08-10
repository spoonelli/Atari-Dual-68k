-- Extra-CPU path through the REAL escape_core (shared SDRAM arbiter, +0x080000
-- window) — the one path hardware exposed as unverified ("Waiting for Second
-- Processor"). Forces the extra CPU on early via dbg_force_extra and traces its
-- ROM transactions and shared-RAM writes. Expect: vectors from image 0x080000
-- (SP=0016FFDC, PC=00000342), execution at 0x342, then shared-RAM activity
-- (the mailbox poll/response at 0x16FFxx).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_extra_hw is end tb_escape_extra_hw;

architecture tb of tb_escape_extra_hw is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';
    signal rom_par  : std_logic := '0';
    signal vblank   : std_logic := '0';
    signal alpha_vaddr : std_logic_vector(10 downto 0) := (others=>'0');
    signal alpha_vdata : std_logic_vector(15 downto 0);
    signal dbg_v, dbg_e : std_logic;
    signal romsrv_data, romsrv_data2 : std_logic_vector(15 downto 0);
    signal rom_addr2w : std_logic_vector(20 downto 0);
begin
    clk    <= not clk after 5 ns when not done else '0';
    resetn <= '0', '1' after 205 ns;
    -- real SDRAM burst behavior: second word is col|1, not col+1
    rom_addr2w <= rom_addr(21 downto 2) & '1';

    uut : entity work.escape_core
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
                   dbg_force_extra=>'1',
                   dbg_v_pc_fetch=>dbg_v, dbg_e_running=>dbg_e );

    romsrv : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr(21 downto 1), data => romsrv_data );
    romsrv2 : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr2w, data => romsrv_data2 );

    serve : process(clk)
        variable lat    : integer := 0;
        variable served : boolean := false;
    begin
        if rising_edge(clk) then
            if rom_req='1' then
                if not served then
                    if lat = 2 then
                        rom_data <= romsrv_data & romsrv_data2;
                        rom_par  <= xor (romsrv_data & romsrv_data2);
                        rom_ack  <= '1';
                        served   := true;
                        lat := 0;
                    else
                        lat := lat + 1;
                    end if;
                end if;
            else
                rom_ack <= '0';
                served  := false;
                lat := 0;
            end if;
        end if;
    end process;

    -- trace extra-CPU ROM transactions (image window >= 0x080000) + shared-RAM writes
    trace : process(clk)
        alias xe_addr is << signal .tb_escape_extra_hw.uut.e_addr : std_logic_vector(31 downto 0) >>;
        alias xe_as_n is << signal .tb_escape_extra_hw.uut.e_as_n : std_logic >>;
        alias xe_rw_n is << signal .tb_escape_extra_hw.uut.e_rw_n : std_logic >>;
        alias xe_di   is << signal .tb_escape_extra_hw.uut.e_di   : std_logic_vector(15 downto 0) >>;
        alias xe_dtk  is << signal .tb_escape_extra_hw.uut.e_dtack_n : std_logic >>;
        alias xwe_b   is << signal .tb_escape_extra_hw.uut.we_shr_b : std_logic >>;
        variable n : integer := 0;
        variable shrw : integer := 0;
        variable in_cyc : boolean := false;
    begin
        if rising_edge(clk) then
            if xe_as_n='0' and xe_dtk='0' and not in_cyc then
                if n < 24 then
                    if xe_rw_n='1' then
                        report "e " & integer'image(n) & " R a=0x" & to_hstring(xe_addr(23 downto 0))
                               & " di=0x" & to_hstring(xe_di);
                    else
                        report "e " & integer'image(n) & " W a=0x" & to_hstring(xe_addr(23 downto 0));
                    end if;
                end if;
                n := n + 1;
                in_cyc := true;
            end if;
            if xe_as_n='1' then in_cyc := false; end if;
            if xwe_b='1' then shrw := shrw + 1; end if;
            if done and shrw > 0 then null; end if;
        end if;
    end process;

    check : process
        alias xwe_b is << signal .tb_escape_extra_hw.uut.we_shr_b : std_logic >>;
        variable wr_seen : boolean := false;
    begin
        for i in 1 to 60000 loop
            wait until rising_edge(clk);
            if xwe_b='1' then wr_seen := true; end if;
        end loop;
        report "=== extra-CPU hardware-path check ===";
        report "  extra shared-RAM write observed: " & boolean'image(wr_seen);
        if wr_seen then
            report "EXTRA-PATH OK: extra CPU executes and writes shared RAM via the real core" severity note;
        else
            report "EXTRA-PATH FAIL: no shared-RAM write from extra CPU" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
