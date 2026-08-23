-- TAS-RACE bench: a REPRODUCTION of the build-101 freeze, not an assertion.
--
-- Two real TG68Ks inside the real escape_core, running the real inter-CPU
-- mutex primitives against the real lock byte $16CCCC:
--   * the EXTRA CPU executes `tas.b $16CCCC` (the acquire at extra ROM $9C8);
--   * the MAIN CPU holds the lock, then executes `clr.b $16CCCC` (the
--     release at $9FC / $4068C) at a phase that sweeps across trials.
-- Software oracle, evaluated by the main CPU itself every trial: once the
-- release has run, the spinning extra MUST get in.  If it does not, the byte
-- is set with nobody owning it and the extra spins forever - the wedge.
-- See sim/tools/make_tasrace_hex.py for the trial protocol.
--
-- Two release flavours, built by the same generator (see sim/run_tasrace.sh):
--   tasrace_words.hex     `clr.b`  - the game's own release.  On the 68000
--                         CLR is ITSELF a read-modify-write, so its read half
--                         is a second place the interlock can serialise.
--   tasrace_mv_words.hex  `move.b #0` - a PURE write, one bus cycle.  This is
--                         the flavour that separates a real interlock from one
--                         that only withholds DTACK, because the shared-RAM
--                         write strobes assert on EVERY clock of a stalled
--                         cycle by design (escape_core.vhd, SDSCHED-80).
--
-- Run matrix (G_TAS is escape_core's TASLOCK_EN):
--   clr.b  G_TAS=0  interlock OFF        -> swallows > 0  (the bug reproduced)
--   clr.b  G_TAS=1  interlock ON         -> swallows = 0  (the fix)
--   move.b G_TAS=0  interlock OFF        -> swallows > 0
--   move.b G_TAS=2  DTACK-ONLY           -> swallows > 0  (not enough)
--   move.b G_TAS=1  interlock ON         -> swallows = 0
-- G_EXPECT says which of those this run is, and the bench FAILS if the run
-- does not match.
--
-- ANTI-PHANTOM-MEASUREMENT METRICS (this project has been burned six times
-- by benches that measured nothing).  All are reported, and the bench FAILS
-- if any of them says the race was never actually constructed:
--   trials     completed trials             (must reach G_MINTRIAL)
--   acq        trials the extra acquired on the main.s FIRST release
--              (must be > 0, or the protocol never completed at all)
--   tasrmw     extra-CPU read-modify-write windows seen on $16CCCC
--              (must be large, or the acquire loop was never exercised)
--   stuck      trials where even the retries could not get the extra in
--   wrinwin    times the main's release write STROBE physically landed in
--              the DANGER GAP - after the extra's TAS read cycle ended and
--              before its write-back strobe.  > 0 in modes 0 and 2 is the
--              mechanism caught in the act; 0 in mode 1 is the fix.
--   overlap    times ANY main bus cycle on that byte overlapped the gap.
--              Mode-independent coverage: > 0 in every mode, including the
--              fixed one, where the cycle is stalled rather than dropped.
--   lockmax    longest observed RMW window, clks  (the TL_TTL justification)
--   holdmax    longest observed interlock stall, clks  (the never-wedge bound)
--   asgap      clks /AS spends HIGH between the TAS read and its write-back
--              (> 0 proves TAS is not indivisible in this CPU core)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_escape_tasrace is
    generic (
        G_TAS     : integer := 0;     -- escape_core TASLOCK_EN under test
        G_EXPECT  : integer := 0;     -- 0 = expect swallows, 1 = expect none
        G_FPEN    : integer := 1;     -- escape_core FASTPATH_EN
        G_FP      : integer := 1;     -- fastpath server latency model
        G_LAT     : integer := 2;     -- legacy rom service latency
        G_MINTRIAL: integer := 200;   -- bench is meaningless below this
        G_MAXUS   : integer := 20000; -- give up after this much sim time, us
        G_HEX     : string  := "sim/work/tasrace_words.hex"
    );
end tb_escape_tasrace;

architecture tb of tb_escape_tasrace is
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

    -- external-name mirrors into the DUT
    signal m_vaddr  : std_logic_vector(31 downto 0);
    signal m_vas    : std_logic;
    signal m_vrw    : std_logic;
    signal m_eaddr  : std_logic_vector(31 downto 0);
    signal m_eas    : std_logic;
    signal m_erw    : std_logic;
    signal m_wea    : std_logic;   -- we_shr_a  (main port write strobe)
    signal m_web    : std_logic;   -- we_shr_b  (extra port write strobe)
    signal m_saddr  : std_logic_vector(14 downto 0);   -- shr_a_addr
    signal m_sdin   : std_logic_vector(15 downto 0);   -- shr_a_din
    signal m_vlock  : std_logic;
    signal m_elock  : std_logic;
    signal m_vhold  : std_logic;
    signal m_ehold  : std_logic;
    signal m_owner  : std_logic_vector(1 downto 0);
    signal m_erel   : std_logic;
    signal m_vpc    : std_logic_vector(15 downto 0);  -- main last program fetch
    signal m_epc    : std_logic_vector(15 downto 0);  -- extra last program fetch

    -- results snooped out of shared RAM
    signal n_trials, n_swallow, n_stuck, n_acq, n_phase : integer := 0;
    -- bench-side observation counters
    signal n_wrinwin, n_overlap : integer := 0;
    signal lockmax, holdmax, asgap : integer := 0;
    signal n_tasrmw : integer := 0;   -- extra-CPU RMW windows on the lock byte

    function hex16(v : std_logic_vector(15 downto 0)) return string is
        variable s : string(1 to 4);
        constant d : string(1 to 16) := "0123456789ABCDEF";
    begin
        for i in 0 to 3 loop
            s(4-i) := d(to_integer(unsigned(v(4*i+3 downto 4*i))) + 1);
        end loop;
        return s;
    end function;
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

    m_vaddr <= << signal uut.v_addr : std_logic_vector(31 downto 0) >>;
    m_vas   <= << signal uut.v_as_n : std_logic >>;
    m_vrw   <= << signal uut.v_rw_n : std_logic >>;
    m_eaddr <= << signal uut.e_addr : std_logic_vector(31 downto 0) >>;
    m_eas   <= << signal uut.e_as_n : std_logic >>;
    m_erw   <= << signal uut.e_rw_n : std_logic >>;
    m_wea   <= << signal uut.we_shr_a : std_logic >>;
    m_web   <= << signal uut.we_shr_b : std_logic >>;
    m_saddr <= << signal uut.shr_a_addr : std_logic_vector(14 downto 0) >>;
    m_sdin  <= << signal uut.shr_a_din  : std_logic_vector(15 downto 0) >>;
    m_vlock <= << signal uut.v_lock : std_logic >>;
    m_elock <= << signal uut.e_lock : std_logic >>;
    m_vhold <= << signal uut.v_hold : std_logic >>;
    m_ehold <= << signal uut.e_hold : std_logic >>;
    m_owner <= << signal uut.tl_owner : std_logic_vector(1 downto 0) >>;
    m_erel  <= << signal uut.extra_release : std_logic >>;
    m_vpc   <= << signal uut.pc_i  : std_logic_vector(15 downto 0) >>;
    m_epc   <= << signal uut.epc_i : std_logic_vector(15 downto 0) >>;

    -- legacy ROM service (two words per request, G_LAT latency)
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
                        rom_data <= d32;
                        rom_par  <= xor d32;
                        rom_ack  <= '1'; served := true; lat := 0;
                    else lat := lat + 1; end if;
                end if;
            else rom_ack <= '0'; served := false; lat := 0; end if;
        end if;
    end process;

    fastsrv_v : process(clk)
        variable tag : std_logic_vector(23 downto 0) := (others=>'1');
        variable cnt : integer := 0;
        variable wi  : integer;
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
        variable cnt : integer := 0;
        variable wi  : integer;
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

    ----------------------------------------------------------------- observer
    watch : process(clk)
        -- word addresses inside shared RAM, derived from the byte addresses
        -- so a hand-typed bit pattern can never quietly disagree with the
        -- image generator (this project has lost days to exactly that)
        constant LOCKW : std_logic_vector(14 downto 0)
                       := std_logic_vector(to_unsigned(16#CCCC# / 2, 15));
        constant W_TRI : std_logic_vector(14 downto 0)
                       := std_logic_vector(to_unsigned(16#E000# / 2, 15));
        constant W_SWA : std_logic_vector(14 downto 0)
                       := std_logic_vector(to_unsigned(16#E002# / 2, 15));
        constant W_STK : std_logic_vector(14 downto 0)
                       := std_logic_vector(to_unsigned(16#E004# / 2, 15));
        constant W_AQQ : std_logic_vector(14 downto 0)
                       := std_logic_vector(to_unsigned(16#E006# / 2, 15));
        constant W_PHA : std_logic_vector(14 downto 0)
                       := std_logic_vector(to_unsigned(16#E008# / 2, 15));
        variable elk_d   : std_logic := '0';
        variable elk_run : integer := 0;
        variable vlk_d   : std_logic := '0';
        variable vlk_run : integer := 0;
        variable hld_run : integer := 0;
        variable win_wr  : boolean := false;   -- release strobe seen in window
        variable win_ov  : boolean := false;   -- release cycle seen in window
        variable win_tgt : boolean := false;   -- this window is on the lock byte
        variable eas_d   : std_logic := '1';
        variable gap     : integer := 0;
        variable in_gap  : boolean := false;
        variable danger  : boolean := false;
        variable e_cyc_rd : std_logic := '1';
        variable e_cyc_ad : std_logic_vector(14 downto 0) := (others=>'0');
    begin
        if rising_edge(clk) and resetn='1' then
            ------------------------------------------------ snoop the results
            if m_wea='1' then
                if    m_saddr = W_TRI then n_trials  <= to_integer(unsigned(m_sdin));
                elsif m_saddr = W_SWA then n_swallow <= to_integer(unsigned(m_sdin));
                elsif m_saddr = W_STK then n_stuck  <= to_integer(unsigned(m_sdin));
                elsif m_saddr = W_AQQ then n_acq     <= to_integer(unsigned(m_sdin));
                elsif m_saddr = W_PHA then n_phase   <= to_integer(unsigned(m_sdin));
                end if;
            end if;

            ------------------------------------- extra-CPU RMW window tracking
            -- THE DANGER WINDOW, precisely: from the clock the extra's TAS
            -- READ cycle ends (/AS rises) to the clock its WRITE-BACK strobe
            -- fires. A main-CPU write to the same byte inside that span is
            -- the swallowed release. Anything outside it - including a main
            -- write while the extra is merely stalled waiting to start its
            -- read - is a legitimate ordering, not the bug, and must not be
            -- counted or the fixed build would look broken.
            if m_eas='0' then
                e_cyc_rd := m_erw;
                e_cyc_ad := m_eaddr(15 downto 1);
            end if;
            if m_elock='1' then
                elk_run := elk_run + 1;
                if m_eas='0' and m_eaddr(15 downto 1) = LOCKW then
                    win_tgt := true;
                end if;
                if m_eas='1' and eas_d='0'
                   and e_cyc_rd='1' and e_cyc_ad = LOCKW then
                    danger := true;                     -- read done, write pending
                end if;
                -- NB: coverage counts ANY main bus cycle on the byte inside
                -- the gap, read half included. With the interlock on, the
                -- main is stalled in the READ half of its own clr.b, so a
                -- write-only coverage test would read zero on the fixed
                -- build and wrongly declare the bench invalid.
                if danger and m_vas='0'
                   and m_vaddr(23 downto 16) = x"16"
                   and m_vaddr(15 downto 1) = LOCKW then
                    win_ov := true;                     -- release CYCLE in the gap
                    if m_wea='1' and m_saddr = LOCKW then
                        win_wr := true;                 -- release STROBE in the gap
                    end if;
                end if;
                if m_web='1' and m_erw='0' and m_eaddr(15 downto 1) = LOCKW then
                    danger := false;                    -- write-back landed
                end if;
            elsif elk_d='1' then
                if elk_run > lockmax then lockmax <= elk_run; end if;
                if win_tgt then
                    n_tasrmw <= n_tasrmw + 1;
                    if win_wr then n_wrinwin <= n_wrinwin + 1; end if;
                    if win_ov then n_overlap <= n_overlap + 1; end if;
                end if;
                elk_run := 0; win_wr := false; win_ov := false;
                win_tgt := false; danger := false;
            end if;
            elk_d := m_elock;

            -- main-CPU RMW windows measured too (its clr.b is an RMW as well)
            if m_vlock='1' then vlk_run := vlk_run + 1;
            elsif vlk_d='1' then
                if vlk_run > lockmax then lockmax <= vlk_run; end if;
                vlk_run := 0;
            end if;
            vlk_d := m_vlock;

            ------------------------------------------------- interlock stalls
            if m_vhold='1' or m_ehold='1' then
                hld_run := hld_run + 1;
                if hld_run > holdmax then holdmax <= hld_run; end if;
            else
                hld_run := 0;
            end if;

            ---------------------------------------- /AS gap inside the extra's
            -- read-modify-write: the whole reason TAS is not atomic here.
            if m_elock='1' then
                if m_eas='1' and eas_d='0' then in_gap := true; gap := 0; end if;
                if in_gap then
                    if m_eas='1' then gap := gap + 1;
                    else
                        if gap > asgap then asgap <= gap; end if;
                        in_gap := false;
                    end if;
                end if;
            else
                in_gap := false;
            end if;
            eas_d := m_eas;
        end if;
    end process;

    ------------------------------------------------------------------ verdict
    judge : process
        variable fails : integer := 0;
        procedure say(s : string) is
        begin report s severity note; end procedure;
        variable t : integer := 0;
    begin
        -- run until the trial budget is met (or the ceiling), then stop the
        -- clock. GHDL --stop-time should be left generous; the bench decides.
        loop
            wait for 100 us;
            t := t + 100;
            report "  ... t=" & integer'image(t) & "us trials=" &
                   integer'image(n_trials) & " swallow=" &
                   integer'image(n_swallow) & " acq=" & integer'image(n_acq) &
                   " stuck=" & integer'image(n_stuck) &
                   " tasrmw=" & integer'image(n_tasrmw) &
                   " ovl=" & integer'image(n_overlap) &
                   " wrin=" & integer'image(n_wrinwin) &
                   "  mainPC=" & hex16(m_vpc) & " extraPC=" & hex16(m_epc)
                   severity note;
            exit when n_trials >= G_MINTRIAL * 2;
            exit when t >= G_MAXUS;
        end loop;
        done <= true;
        wait for 100 ns;
        say("=== TASRACE (TASLOCK_EN=" & integer'image(G_TAS) & ") ===");
        say("  trials              : " & integer'image(n_trials));
        say("  clean acquires      : " & integer'image(n_acq));
        say("  SWALLOWED RELEASES  : " & integer'image(n_swallow));
        say("  unrecoverable       : " & integer'image(n_stuck));
        say("  extra RMW windows on $16CCCC : " & integer'image(n_tasrmw));
        say("  release CYCLE inside window  : " & integer'image(n_overlap));
        say("  release STROBE inside window : " & integer'image(n_wrinwin));
        say("  longest RMW window   : " & integer'image(lockmax) & " clks");
        say("  longest interlock stall : " & integer'image(holdmax) & " clks");
        say("  /AS high inside the RMW : " & integer'image(asgap) & " clks");
        say("  core counters: dbg_tas_cnt=" & hex16(dbg_tas_cnt) &
            "  dbg_tas_addr=" & hex16(dbg_tas_addr));

        -- --- measurement-integrity gates (a bench that measured nothing
        -- --- must fail loudly, not report a comforting zero) ---
        if n_trials < G_MINTRIAL then
            report "TASRACE BENCH INVALID: only " & integer'image(n_trials) &
                   " trials completed (need " & integer'image(G_MINTRIAL) & ")"
                severity failure;
        end if;
        if n_acq = 0 then
            report "TASRACE BENCH INVALID: not one clean acquire - the extra " &
                   "never got the lock at all, so the protocol never ran"
                severity failure;
        end if;
        if n_tasrmw < 100 then
            report "TASRACE BENCH INVALID: only " & integer'image(n_tasrmw) &
                   " extra-CPU read-modify-write windows on $16CCCC were seen; " &
                   "the acquire loop was not exercised" severity failure;
        end if;
        if n_overlap = 0 then
            report "TASRACE BENCH INVALID: the release bus cycle never once " &
                   "overlapped the extra's read-modify-write window - the race " &
                   "was never constructed"
                severity failure;
        end if;

        -- --- the actual verdict ---
        if G_EXPECT = 0 then
            if n_swallow = 0 then
                report "TASRACE: expected to REPRODUCE the swallowed release and did not"
                    severity failure;
            end if;
            if n_wrinwin = 0 then
                report "TASRACE: swallows counted but no release strobe was ever " &
                       "seen inside the window - the oracle and the bus disagree"
                    severity failure;
            end if;
            say("TASRACE REPRODUCED: " & integer'image(n_swallow) &
                " ownerless locks out of " & integer'image(n_trials) & " trials");
        else
            if n_swallow /= 0 then
                report "TASRACE FIX FAILED: " & integer'image(n_swallow) &
                       " swallowed releases with the interlock on" severity failure;
            end if;
            if n_acq /= n_trials then
                report "TASRACE FIX FAILED: " & integer'image(n_trials - n_acq) &
                       " trials did not acquire on the first release"
                    severity failure;
            end if;
            if n_wrinwin /= 0 then
                report "TASRACE FIX FAILED: " & integer'image(n_wrinwin) &
                       " release strobes still landed inside an RMW window"
                    severity failure;
            end if;
            if dbg_tas_cnt = x"0000" then
                report "TASRACE FIX SUSPECT: zero swallows but the interlock " &
                       "never engaged either - it is not what prevented them"
                    severity failure;
            end if;
            say("TASRACE FIXED: 0 swallowed releases in " &
                integer'image(n_trials) & " trials, interlock engaged " &
                integer'image(to_integer(unsigned(dbg_tas_cnt(7 downto 0)))) &
                " times (" &
                integer'image(to_integer(unsigned(dbg_tas_cnt(15 downto 8)))) &
                " of them writes), first collision at $16" & hex16(dbg_tas_addr));
        end if;
        wait;
    end process;
end architecture;
