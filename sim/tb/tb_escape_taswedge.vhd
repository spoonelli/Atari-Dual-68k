-- TASWEDGE bench: the never-wedge proof for the TASLOCK-102 interlock.
--
-- The whole point of the interlock is that one CPU can hold the other off a
-- shared byte.  The obvious way to trade one hang for another is to let that
-- hold-off run forever.  This bench forces the pathological case that the
-- design must survive: a CPU whose LOCK (read-modify-write in flight) NEVER
-- DROPS - a stuck RMW, a CPU halted mid-TAS, any failure of the owner to
-- finish.  Under that adversary the design must still let the other CPU run.
--
-- What the RTL promises (escape_core.vhd, tas_lock):
--   * only one window exists at a time and the owner is never itself held,
--   * TL_TTL_MAX force-closes a window that overstays, and tl_v_inh/tl_e_inh
--     then bar THAT CPU from re-opening one until its LOCK drops.
--   => a stuck LOCK costs the other CPU at most ONE window, i.e. at most
--      TL_TTL_MAX+1 = 64 clocks, ever.  Not 64 per access - 64 total.
--
-- This bench measures exactly that, with a positive throughput metric on the
-- side so a "no stalls" verdict cannot come from a dead machine.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_escape_taswedge is
    generic (
        G_TAS   : integer := 1;
        G_BOUND : integer := 64;      -- TL_TTL_MAX+1, the claimed hard bound
        G_FPEN  : integer := 1;
        G_FP    : integer := 1;
        G_LAT   : integer := 2;
        G_HEX   : string  := "sim/work/tasrace_words.hex"
    );
end tb_escape_taswedge;

architecture tb of tb_escape_taswedge is
    constant AW : integer := 19;
    type mem_t is array (0 to 2**AW - 1) of std_logic_vector(15 downto 0);

    impure function load_hex return mem_t is
        file     f   : text open read_mode is G_HEX;
        variable l   : line;
        variable w   : std_logic_vector(15 downto 0);
        variable ok  : boolean;
        variable idx : integer := 0;
        variable m   : mem_t := (others => (others => '0'));
    begin
        while not endfile(f) and idx < 2**AW loop
            readline(f, l); hread(l, w, ok);
            if ok then m(idx) := w; idx := idx + 1; end if;
        end loop;
        return m;
    end function;
    constant img : mem_t := load_hex;

    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0) := (others=>'0');
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';
    signal rom_par  : std_logic := '0';
    signal fast_v_addr, fast_e_addr : std_logic_vector(23 downto 0);
    signal fast_v_spec, fast_e_spec : std_logic;
    signal fast_v_data, fast_e_data : std_logic_vector(15 downto 0) := (others=>'0');
    signal fast_v_ready, fast_e_ready : std_logic := '0';
    signal dbg_tas_cnt, dbg_tas_addr : std_logic_vector(15 downto 0);

    signal m_vas, m_eas, m_vhold, m_ehold : std_logic;
    signal m_owner : std_logic_vector(1 downto 0);

    -- phase control / measurement
    signal phase       : integer := 0;   -- 0 free-run 1 v_lock stuck 2 e_lock stuck
    signal vcyc, ecyc  : integer := 0;   -- bus cycles in the current phase
    signal vcyc_0, ecyc_0 : integer := 0;
    signal vcyc_1, ecyc_1 : integer := 0;
    signal vcyc_2, ecyc_2 : integer := 0;
    signal vhold_clk, ehold_clk : integer := 0;   -- hold clocks in the current phase
    signal vh_1, eh_1, vh_2, eh_2 : integer := 0;
    signal runmax : integer := 0;        -- longest single uninterrupted hold
begin
    clk <= not clk after 5 ns when not done else '0';

    uut : entity work.escape_core
        generic map ( YM_ENABLE => 0, SHAD_EN => 0,
                      FASTPATH_EN => G_FPEN, EIRQ_MODE => 0,
                      TASLOCK_EN => G_TAS )
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par,
                   rom_req=>rom_req, rom_ack=>rom_ack,
                   fast_v_addr=>fast_v_addr, fast_v_spec=>fast_v_spec,
                   fast_v_data=>fast_v_data, fast_v_ready=>fast_v_ready,
                   fast_e_addr=>fast_e_addr, fast_e_spec=>fast_e_spec,
                   fast_e_data=>fast_e_data, fast_e_ready=>fast_e_ready,
                   dbg_tas_cnt=>dbg_tas_cnt, dbg_tas_addr=>dbg_tas_addr,
                   vblank_in=>'0',
                   p1_buttons=>"0000", p2_buttons=>"0000" );

    m_vas   <= << signal uut.v_as_n : std_logic >>;
    m_eas   <= << signal uut.e_as_n : std_logic >>;
    m_vhold <= << signal uut.v_hold : std_logic >>;
    m_ehold <= << signal uut.e_hold : std_logic >>;
    m_owner <= << signal uut.tl_owner : std_logic_vector(1 downto 0) >>;

    serve : process(clk)
        variable lat : integer := 0; variable served : boolean := false;
        variable wi  : integer;
        variable d32 : std_logic_vector(31 downto 0);
    begin
        if rising_edge(clk) then
            if rom_req='1' then
                if not served then
                    if lat = G_LAT then
                        wi  := to_integer(unsigned(rom_addr(AW downto 1)));
                        d32 := img(wi) & img((wi + 1) mod 2**AW);
                        rom_data <= d32; rom_par <= xor d32;
                        rom_ack <= '1'; served := true; lat := 0;
                    else lat := lat + 1; end if;
                end if;
            else rom_ack <= '0'; served := false; lat := 0; end if;
        end if;
    end process;

    fastsrv_v : process(clk)
        variable tag : std_logic_vector(23 downto 0) := (others=>'1');
        variable cnt : integer := 0; variable wi : integer;
    begin
        if rising_edge(clk) and G_FP > 0 then
            if fast_v_spec='1' then
                if fast_v_addr /= tag then tag := fast_v_addr; cnt := G_FP; end if;
                if cnt > 0 then
                    cnt := cnt - 1;
                    if cnt = 0 then
                        wi := to_integer(unsigned(tag(AW downto 1)));
                        fast_v_data <= img(wi); fast_v_ready <= '1';
                    else fast_v_ready <= '0'; end if;
                else fast_v_ready <= '1'; end if;
            else fast_v_ready <= '0'; end if;
        end if;
    end process;

    fastsrv_e : process(clk)
        variable tag : std_logic_vector(23 downto 0) := (others=>'1');
        variable cnt : integer := 0; variable wi : integer;
    begin
        if rising_edge(clk) and G_FP > 0 then
            if fast_e_spec='1' then
                if fast_e_addr /= tag then tag := fast_e_addr; cnt := G_FP; end if;
                if cnt > 0 then
                    cnt := cnt - 1;
                    if cnt = 0 then
                        wi := to_integer(unsigned(tag(AW downto 1)));
                        fast_e_data <= img(wi); fast_e_ready <= '1';
                    else fast_e_ready <= '0'; end if;
                else fast_e_ready <= '1'; end if;
            else fast_e_ready <= '0'; end if;
        end if;
    end process;

    resetn <= '0', '1' after 205 ns;

    meter : process(clk)
        variable vas_d, eas_d : std_logic := '1';
        variable run : integer := 0;
    begin
        if rising_edge(clk) and resetn='1' then
            if m_vas='0' and vas_d='1' then vcyc <= vcyc + 1; end if;
            if m_eas='0' and eas_d='1' then ecyc <= ecyc + 1; end if;
            vas_d := m_vas; eas_d := m_eas;
            if m_vhold='1' then vhold_clk <= vhold_clk + 1; end if;
            if m_ehold='1' then ehold_clk <= ehold_clk + 1; end if;
            if m_vhold='1' or m_ehold='1' then
                run := run + 1;
                if run > runmax then runmax <= run; end if;
            else
                run := 0;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------- driver
    drive : process
        procedure snap(p : integer) is
        begin
            if p = 0 then vcyc_0 <= vcyc; ecyc_0 <= ecyc;
            elsif p = 1 then vcyc_1 <= vcyc; ecyc_1 <= ecyc;
                             vh_1 <= vhold_clk; eh_1 <= ehold_clk;
            else vcyc_2 <= vcyc; ecyc_2 <= ecyc;
                 vh_2 <= vhold_clk; eh_2 <= ehold_clk; end if;
        end procedure;
    begin
        wait for 600 us;                       -- free-running baseline
        snap(0);
        vcyc <= 0; ecyc <= 0; vhold_clk <= 0; ehold_clk <= 0;
        wait for 20 ns;

        -- ADVERSARY 1: the video CPU's RMW never finishes.
        phase <= 1;
        << signal uut.v_lock : std_logic >> <= force '1';
        wait for 600 us;
        snap(1);
        << signal uut.v_lock : std_logic >> <= release;
        vcyc <= 0; ecyc <= 0; vhold_clk <= 0; ehold_clk <= 0;
        wait for 20 ns;

        -- ADVERSARY 2: the extra CPU's RMW never finishes.
        phase <= 2;
        << signal uut.e_lock : std_logic >> <= force '1';
        wait for 600 us;
        snap(2);
        << signal uut.e_lock : std_logic >> <= release;
        wait for 1 us;
        done <= true;
        wait for 100 ns;

        report "=== TASWEDGE (TASLOCK_EN=" & integer'image(G_TAS) & ") ===" severity note;
        report "  baseline 600us : main " & integer'image(vcyc_0) &
               " cyc, extra " & integer'image(ecyc_0) & " cyc" severity note;
        report "  v_lock STUCK   : main " & integer'image(vcyc_1) &
               " cyc, extra " & integer'image(ecyc_1) & " cyc, extra held " &
               integer'image(eh_1) & " clks" severity note;
        report "  e_lock STUCK   : main " & integer'image(vcyc_2) &
               " cyc, extra " & integer'image(ecyc_2) & " cyc, main held " &
               integer'image(vh_2) & " clks" severity note;
        report "  longest single hold, whole run : " & integer'image(runmax) &
               " clks (bound " & integer'image(G_BOUND) & ")" severity note;

        -- the machine must still be alive under both adversaries
        if ecyc_0 = 0 or vcyc_0 = 0 then
            report "TASWEDGE BENCH INVALID: no baseline bus traffic" severity failure;
        end if;
        if ecyc_1 * 2 < ecyc_0 then
            report "TASWEDGE FAIL: extra CPU throughput collapsed with the main's " &
                   "LOCK stuck (" & integer'image(ecyc_1) & " vs " &
                   integer'image(ecyc_0) & " cycles)" severity failure;
        end if;
        if vcyc_2 * 2 < vcyc_0 then
            report "TASWEDGE FAIL: main CPU throughput collapsed with the extra's " &
                   "LOCK stuck (" & integer'image(vcyc_2) & " vs " &
                   integer'image(vcyc_0) & " cycles)" severity failure;
        end if;
        -- and the stall must be bounded, once, not per access
        if runmax > G_BOUND then
            report "TASWEDGE FAIL: a single hold lasted " & integer'image(runmax) &
                   " clks, over the claimed bound of " & integer'image(G_BOUND)
                severity failure;
        end if;
        if eh_1 > G_BOUND then
            report "TASWEDGE FAIL: extra held for " & integer'image(eh_1) &
                   " clks total against a permanently stuck main LOCK - the " &
                   "re-arm inhibit is not working" severity failure;
        end if;
        if vh_2 > G_BOUND then
            report "TASWEDGE FAIL: main held for " & integer'image(vh_2) &
                   " clks total against a permanently stuck extra LOCK - the " &
                   "re-arm inhibit is not working" severity failure;
        end if;
        report "TASWEDGE OK: both CPUs survive a permanently stuck LOCK; worst " &
               "single stall " & integer'image(runmax) & " clks, total stall " &
               "against a stuck peer <= " & integer'image(G_BOUND) & " clks"
            severity note;
        wait;
    end process;
end architecture;
