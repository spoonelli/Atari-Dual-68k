-- tb_vfill: MEASURE the Video CPU's speculative-fill rate, rather than quoting it.
--
-- WHY THIS EXISTS. docs/investigations/VSHAD3.md:115 states that un-shadowing 0x54000 moves the
-- video CPU "from issuing fills on ~39% of its bus cycles to ~70%", and that
-- number was then taken as an INPUT to the SDRAM re-architecture analysis
-- (docs/investigations/SDRAM_ARCH.md). Its own source calls the neighbouring MO figure "an
-- estimate, not a measurement". An estimate that becomes the load model for a
-- memory-system decision has to be measured before it decides anything, so this
-- bench counts the real address stream instead.
--
-- HOW IT IS SOUND WITH SHAD_EN=0. The DUT is instantiated exactly as
-- tb_escape_core does (SHAD_EN=>0), because the shadow RAMs are never filled
-- under GHDL and the CPU would derail reading them. That does NOT bias this
-- measurement: the shadow holds a COPY of the same ROM words, so SHAD_EN only
-- changes WHICH memory answers a fetch, never WHAT data comes back. The
-- instruction stream - and therefore the address stream - is bit-identical
-- either way. So one capture can be classified against both shadow policies
-- offline, which is what the two totals below do.
--
-- The ranges are transcribed from escape_core.vhd:791-796 (v_shad_rng and
-- fast_v_spec), not from the prose:
--   fast_v_spec = FASTPATH_EN=1 and v_shad_rng=0 and addr <= 0x09FFFF
--   v_shad_rng  = r1 or r2 or (v_s3_en and r3)
--   r1 = addr(23:14)="0000000000" -> 0x000000-0x003FFF
--   r2 = addr(23:15)="000001001"  -> 0x048000-0x04FFFF
--   r3 = addr(23:14)="0000010101" -> 0x054000-0x057FFF   (the vshad3 16 KB)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_vfill is end tb_vfill;

architecture tb of tb_vfill is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';
    signal rom_par  : std_logic := '0';

    signal vblank : std_logic := '0';
    signal alpha_vaddr : std_logic_vector(10 downto 0) := (others=>'0');
    signal alpha_vdata : std_logic_vector(15 downto 0);
    signal dbg_v, dbg_e : std_logic;

    signal romsrv_data, romsrv_data2 : std_logic_vector(15 downto 0);
    signal rom_addr2w : std_logic_vector(20 downto 0);

    -- post-boot gate: counts are also kept for the window after the first
    -- VBLANK, so a boot-dominated figure cannot masquerade as steady state.
    signal warm : boolean := false;

    -- counts live as SIGNALS, not process variables: `done` stops the clock,
    -- so the reporting has to happen outside the clocked process.
    signal c_tot, c_elig, c_r1, c_r2, c_r3 : integer := 0;
    -- Spin-loop diagnostic: if the window is one tight loop, the page count is
    -- tiny and lo/hi bracket a few hundred bytes. That distinguishes "the CPU
    -- is still booting" from "the CPU is wedged".
    signal c_pages : integer := 0;
    signal c_lo : integer := 16#FFFFFF#;
    signal c_hi : integer := 0;
    signal w_tot, w_elig, w_r1, w_r2, w_r3 : integer := 0;
begin
    clk    <= not clk after 5 ns when not done else '0';
    resetn <= '0', '1' after 205 ns;
    rom_addr2w <= rom_addr(21 downto 2) & '1';

    uut : entity work.escape_core
        generic map ( YM_ENABLE => 0, SHAD_EN => 0 )
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par,
                   rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
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

    vb : process
    begin
        wait for 100 us;
        loop
            vblank <= '1'; warm <= true; wait for 10 us;
            vblank <= '0'; wait for 90 us;
            exit when done;
        end loop;
        wait;
    end process;

    -- Count one tally per COMPLETED bus cycle, using the same in_cycle edge
    -- discipline as tb_escape_core so a multi-clock cycle is counted once.
    count_p : process(clk)
        alias xv_addr  is << signal .tb_vfill.uut.v_addr    : std_logic_vector(31 downto 0) >>;
        alias xv_as_n  is << signal .tb_vfill.uut.v_as_n    : std_logic >>;
        alias xv_dtack is << signal .tb_vfill.uut.v_dtack_n : std_logic >>;
        variable in_cycle : boolean := false;
        variable a : unsigned(23 downto 0);
        type seen_t is array (0 to 65535) of boolean;
        variable seen : seen_t := (others => false);
    begin
        if rising_edge(clk) then
            if xv_as_n='0' and xv_dtack='0' and not in_cycle then
                in_cycle := true;
                a := unsigned(xv_addr(23 downto 0));
                c_tot <= c_tot + 1;
                if to_integer(a) < c_lo then c_lo <= to_integer(a); end if;
                if to_integer(a) > c_hi then c_hi <= to_integer(a); end if;
                if not seen(to_integer(a(23 downto 8))) then
                    seen(to_integer(a(23 downto 8))) := true;
                    c_pages <= c_pages + 1;
                end if;
                if warm then w_tot <= w_tot + 1; end if;
                if a <= x"09FFFF" then
                    c_elig <= c_elig + 1;
                    if warm then w_elig <= w_elig + 1; end if;
                    if a <= x"003FFF" then
                        c_r1 <= c_r1 + 1;
                        if warm then w_r1 <= w_r1 + 1; end if;
                    elsif a >= x"048000" and a <= x"04FFFF" then
                        c_r2 <= c_r2 + 1;
                        if warm then w_r2 <= w_r2 + 1; end if;
                    elsif a >= x"054000" and a <= x"057FFF" then
                        c_r3 <= c_r3 + 1;
                        if warm then w_r3 <= w_r3 + 1; end if;
                    end if;
                end if;
            end if;
            if xv_as_n='1' then in_cycle := false; end if;
        end if;
    end process;

    check : process
    begin
        wait for 480 us;
        report "=== VFILL: measured Video CPU speculative-fill rate ===";
        report "  cumulative bus cycles      : " & integer'image(c_tot);
        report "  ... fastpath-eligible      : " & integer'image(c_elig);
        report "  ... in r1 0x000000-0x003FFF: " & integer'image(c_r1);
        report "  ... in r2 0x048000-0x04FFFF: " & integer'image(c_r2);
        report "  ... in r3 0x054000-0x057FFF: " & integer'image(c_r3);
        report "  warm bus cycles            : " & integer'image(w_tot);
        report "  ... fastpath-eligible      : " & integer'image(w_elig);
        report "  ... in r1                  : " & integer'image(w_r1);
        report "  ... in r2                  : " & integer'image(w_r2);
        report "  ... in r3                  : " & integer'image(w_r3);
        report "  FILLS cum  vshad3 ON       : " & integer'image(c_elig-c_r1-c_r2-c_r3);
        report "  FILLS cum  vshad3 OFF      : " & integer'image(c_elig-c_r1-c_r2);
        report "  FILLS warm vshad3 ON       : " & integer'image(w_elig-w_r1-w_r2-w_r3);
        report "  FILLS warm vshad3 OFF      : " & integer'image(w_elig-w_r1-w_r2);
        -- Integrity: a bench that counted nothing, or a classifier that binned
        -- nothing, must not be readable as a comfortably low fill rate.
        if c_tot = 0 then
            report "VFILL: no bus cycles counted - measuring nothing" severity failure;
        end if;
        if c_elig = 0 then
            report "VFILL: no fastpath-eligible cycles - classifier is dead" severity failure;
        end if;
        if c_r1 = 0 then
            report "VFILL: zero hits in r1, but the reset vectors and boot code "
                 & "live at 0x0 - the range classifier is not working" severity failure;
        end if;
        if w_tot = 0 then
            report "VFILL: no warm cycles - the post-VBLANK window never opened"
                   severity failure;
        end if;
        report "  distinct 256B pages touched: " & integer'image(c_pages);
        report "  lowest addr  : 0x" & to_hstring(to_unsigned(c_lo,24));
        report "  highest addr : 0x" & to_hstring(to_unsigned(c_hi,24));
        report "VFILL DONE";
        done <= true;
        wait;
    end process;

end architecture;
