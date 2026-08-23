-- WORLD-WAKE bench: the faithful dual-CPU runtime IRQ contract test that
-- the 87-91 regression saga proved was missing. Natural boot, NO
-- dbg_force_extra: the synthetic MAIN releases the extra through the real
-- 360011 write, supervises the handshake with an authentic timeout+restart,
-- and its vblank ISR writes the 360000 ack ~60 CPU clocks after vblank (the
-- shared-latch pulse). The synthetic EXTRA mirrors the REAL runtime ROM:
--   * boots IRQ-MASKED into a multi-frame POST (mini-march over the flag
--     page + calibrated delay), then unmasks — THE HAZARD POINT: any design
--     that holds a pending vblank across the masked POST delivers it here,
--     into an ISR whose RAM pointer ($16CCE0) still aims at POST workspace;
--     the trampled canary fails the POST verify and the extra parks at
--     0xBAC (the march band where builds 90/91 spun on device);
--   * its runtime vblank ISR (real address 0x908) sets the wake flag
--     $16CCD6 and has NO 360000 store (flight-recorder truth);
--   * its world loop is the real critical-section poll loop at 0x9B4:
--     save SR / mask lvl5 / tst $16CCD6 / restore SR from $16CCD0 / loop.
--
-- METRICS (final "WORLDWAKE VERDICT" line):
--   ready      : extra completed POST + handshake and initialized runtime
--   wakes      : poll-loop flag consumptions (writes to $16F010) — the
--                world-alive metric; ALIVE requires ~1/frame after ready
--   iacks      : extra IACK cycles taken (one per delivered interrupt)
--   premature  : IACKs taken BEFORE runtime init (flag cleared) — the
--                POST-derail count; any nonzero = the 87-91 device killer
--   restarts   : main's supervision restarts (device erestart analog)
--   storm      : >2 IACKs inside one frame (the 87/88 re-entry storm)
--   ackdly     : measured vblank->360000 main ack delay (authenticity)
--
-- FAILURE SEMANTICS: storm and post-ready wake stalls are severity FAILURE
-- (they are wrong in every mode); premature/restarts/DEAD are REPORTED and
-- judged by the run matrix (mode 0 is EXPECTED to show rare prematures,
-- mode 1 is EXPECTED to be DEAD — that reproduction is the point).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_escape_worldwake is
    generic (
        G_EIRQ   : integer := 2;      -- escape_core EIRQ_MODE under test
        G_FPEN   : integer := 1;      -- escape_core FASTPATH_EN
        G_FP     : integer := 1;      -- fastpath server model (0=none,1=authentic,N=slow)
        G_SHAD   : integer := 0;      -- shadow BRAMs filled + enabled
        G_LAT    : integer := 2;      -- legacy rom service latency
        G_FRAME  : integer := 2500;   -- base vblank period, clks
        G_SWEEP  : integer := 613;    -- period modulus (1 = LOCKED period)
        G_PHOFF  : integer := 0;      -- phase offset for parallel slices
        G_NFRM   : integer := 400;    -- frames to run
        G_VBW    : integer := 200;    -- vblank pulse width, clks (~8% frame)
        G_HEX    : string  := "sim/work/worldwake_words.hex"
    );
end tb_escape_worldwake;

architecture tb of tb_escape_worldwake is
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
    signal vblank   : std_logic := '0';

    signal fast_v_addr, fast_e_addr : std_logic_vector(23 downto 0);
    signal fast_v_spec, fast_e_spec : std_logic;
    signal fast_v_data, fast_e_data : std_logic_vector(15 downto 0) := (others=>'0');
    signal fast_v_ready, fast_e_ready : std_logic := '0';

    signal shad_wclk  : std_logic := '0';
    signal shad_waddr : std_logic_vector(23 downto 0) := (others=>'0');
    signal shad_wdata : std_logic_vector(15 downto 0) := (others=>'0');
    signal shad_we    : std_logic := '0';
    signal fill_done  : boolean := false;

    -- external-name mirrors
    signal m_vaddr  : std_logic_vector(31 downto 0);
    signal m_vas    : std_logic;
    signal m_vrw    : std_logic;
    signal m_vdo    : std_logic_vector(15 downto 0);
    signal m_eaddr  : std_logic_vector(31 downto 0);
    signal m_eas    : std_logic;
    signal m_erw    : std_logic;
    signal m_edo    : std_logic_vector(15 downto 0);
    signal m_efc    : std_logic_vector(2 downto 0);
    signal m_epc    : std_logic_vector(15 downto 0);
    signal m_evirq  : std_logic;
    signal m_erel   : std_logic;

    -- bookkeeping (integers written by watch, read by verdict)
    signal frame_i      : integer := 0;
    signal wake_cnt     : integer := 0;
    signal iack_cnt     : integer := 0;
    signal prem_cnt     : integer := 0;
    signal restart_cnt  : integer := 0;
    signal storm_max    : integer := 0;
    signal fail_park    : integer := 0;   -- POSTFAIL loop iterations seen
    signal ready_seen   : boolean := false;
    signal ready_frame  : integer := -1;
    signal wake_at_rdy  : integer := 0;
    signal ack_sum      : integer := 0;   -- accumulated vblank->ack delays
    signal ack_n        : integer := 0;
    signal rel_seen     : boolean := false;
    signal reldrop_cnt  : integer := 0;   -- release drops (stops/restarts)

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
        generic map ( YM_ENABLE => 0, SHAD_EN => G_SHAD,
                      FASTPATH_EN => G_FPEN, EIRQ_MODE => G_EIRQ )
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par,
                   rom_req=>rom_req, rom_ack=>rom_ack,
                   fast_v_addr=>fast_v_addr, fast_v_spec=>fast_v_spec,
                   fast_v_data=>fast_v_data, fast_v_ready=>fast_v_ready,
                   fast_e_addr=>fast_e_addr, fast_e_spec=>fast_e_spec,
                   fast_e_data=>fast_e_data, fast_e_ready=>fast_e_ready,
                   shad_wclk=>shad_wclk, shad_waddr=>shad_waddr,
                   shad_wdata=>shad_wdata, shad_we=>shad_we,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000" );

    m_vaddr <= << signal uut.v_addr : std_logic_vector(31 downto 0) >>;
    m_vas   <= << signal uut.v_as_n : std_logic >>;
    m_vrw   <= << signal uut.v_rw_n : std_logic >>;
    m_vdo   <= << signal uut.v_do   : std_logic_vector(15 downto 0) >>;
    m_eaddr <= << signal uut.e_addr : std_logic_vector(31 downto 0) >>;
    m_eas   <= << signal uut.e_as_n : std_logic >>;
    m_erw   <= << signal uut.e_rw_n : std_logic >>;
    m_edo   <= << signal uut.e_do   : std_logic_vector(15 downto 0) >>;
    m_efc   <= << signal uut.e_fc   : std_logic_vector(2 downto 0) >>;
    m_epc   <= << signal uut.epc_i  : std_logic_vector(15 downto 0) >>;
    m_evirq <= << signal uut.e_virq : std_logic >>;
    m_erel  <= << signal uut.extra_release : std_logic >>;

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

    -- fastpath server models (as validated in tb_escape_vecrace)
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

    -- shadow fill (G_SHAD=1): video 0x0000-0x3FFF, extra 0x080000-0x083FFF
    -- + 0x08F000-0x08FFFF, through the download port while reset held
    fill : process
        procedure fill_range(bybase, bylen : integer) is
        begin
            for b in 0 to bylen/2 - 1 loop
                shad_waddr <= std_logic_vector(to_unsigned(bybase + 2*b, 24));
                shad_wdata <= img((bybase + 2*b)/2);
                shad_we    <= '1';
                shad_wclk  <= '0'; wait for 2 ns;
                shad_wclk  <= '1'; wait for 2 ns;
            end loop;
            shad_we <= '0'; shad_wclk <= '0';
        end procedure;
    begin
        if G_SHAD = 1 then
            wait for 20 ns;
            fill_range(16#000000#, 16#4000#);
            fill_range(16#080000#, 16#4000#);
            fill_range(16#08F000#, 16#1000#);
        end if;
        fill_done <= true;
        wait;
    end process;

    rst : process
    begin
        wait until fill_done;
        wait for 205 ns;
        resetn <= '1';
        wait;
    end process;

    -- vblank generator: period sweeps one clk per frame (G_SWEEP=1 locks it)
    vb : process
        variable period : integer;
    begin
        wait until resetn='1';
        wait for 20 us;                        -- let both CPUs reach code
        for i in 1 to G_NFRM loop
            frame_i <= i;
            vblank <= '1';
            wait for G_VBW * 10 ns;
            vblank <= '0';
            period := G_FRAME + ((G_PHOFF + i) mod G_SWEEP) - G_VBW;
            wait for period * 10 ns;
            exit when done;
        end loop;
        wait for 50 us;
        done <= true;
        wait;
    end process;

    -- the one observer: classifies both CPUs' bus traffic
    watch : process(clk)
        variable vin, ein   : boolean := false;   -- one event per bus cycle
        variable iack_lo    : boolean := false;
        variable vb_d       : std_logic := '0';
        variable clks_vb    : integer := 0;       -- clks since vblank edge
        variable acked_this : boolean := false;
        variable iack_frame : integer := 0;
        variable frames_rdy : integer := 0;
        variable wake_prev  : integer := 0;
        variable stall_frm  : integer := 0;
        variable init_done  : boolean := false;   -- extra runtime init proven
        variable erel_d     : std_logic := '0';
        variable a          : std_logic_vector(23 downto 0);
    begin
        if rising_edge(clk) and resetn='1' then
            clks_vb := clks_vb + 1;
            -- frame boundary accounting
            if vblank='1' and vb_d='0' then
                clks_vb := 0; acked_this := false;
                if iack_frame > storm_max then storm_max <= iack_frame; end if;
                if iack_frame > 2 then
                    report "WORLDWAKE STORM: " & integer'image(iack_frame) &
                           " extra IACKs in one frame (frame " &
                           integer'image(frame_i) & ")" severity failure;
                end if;
                iack_frame := 0;
                if ready_seen then
                    frames_rdy := frames_rdy + 1;
                    if not init_done then
                        stall_frm := 0;   -- extra is re-POSTing (restart)
                    elsif wake_cnt = wake_prev then
                        stall_frm := stall_frm + 1;
                        if stall_frm >= 4 and m_erel='1' then
                            report "WORLDWAKE LOST WAKEUP: no poll-loop wake for "
                                   & integer'image(stall_frm) & " frames (frame "
                                   & integer'image(frame_i) & ", epc 0x" &
                                   hex16(m_epc) & ", e_virq " &
                                   std_logic'image(m_evirq) & ")"
                                severity failure;
                        end if;
                    else
                        stall_frm := 0;
                    end if;
                    wake_prev := wake_cnt;
                end if;
            end if;
            vb_d := vblank;

            -- release drops (supervision restart OR wave-transition pulse)
            -- reset the extra: its runtime init is gone until re-proven
            if m_erel='0' and erel_d='1' then
                init_done := false;
                reldrop_cnt <= reldrop_cnt + 1;
                report "worldwake: extra STOPPED (release drop " &
                       integer'image(reldrop_cnt + 1) & ", frame " &
                       integer'image(frame_i) & ")";
            end if;
            erel_d := m_erel;

            -- video-CPU writes
            if m_vas='0' and m_vrw='0' and not vin then
                a := m_vaddr(23 downto 0);
                if a = x"360000" and not acked_this then
                    acked_this := true;
                    ack_sum <= ack_sum + clks_vb;
                    ack_n   <= ack_n + 1;
                elsif a = x"360011" then
                    if not rel_seen and m_vdo(0)='1' then
                        rel_seen <= true;
                        report "worldwake: extra RELEASED at frame " &
                               integer'image(frame_i);
                    end if;
                elsif a = x"3F7F20" then
                    restart_cnt <= restart_cnt + 1;   -- supervision timeout
                end if;
                vin := true;
            end if;
            if m_vas='1' then vin := false; end if;

            -- extra-CPU cycles
            if m_eas='0' and not ein then
                a := m_eaddr(23 downto 0);
                if m_erw='0' then
                    -- runtime-init marker: the extra's handshake response
                    -- (the POST march also writes 16CCD6, so the flag
                    -- address itself cannot mark readiness)
                    if a = x"16FFE2" and m_edo = x"4321" then
                        if not init_done then
                            init_done := true;
                            if not ready_seen then
                                ready_seen  <= true;
                                ready_frame <= frame_i;
                                wake_at_rdy <= wake_cnt;
                                report "worldwake: extra RUNTIME READY at frame "
                                       & integer'image(frame_i) &
                                       " (restarts so far " &
                                       integer'image(restart_cnt) & ")";
                            end if;
                        end if;
                    elsif a = x"16F010" then
                        wake_cnt <= wake_cnt + 1;
                    elsif a = x"16F030" then
                        fail_park <= fail_park + 1;
                    end if;
                end if;
                ein := true;
            end if;
            if m_eas='1' then ein := false; end if;

            -- extra IACK cycles (FC=111, AS low): count completions
            if m_eas='0' and m_efc="111" then
                iack_lo := true;
            elsif m_eas='1' and iack_lo then
                iack_lo := false;
                iack_cnt   <= iack_cnt + 1;
                iack_frame := iack_frame + 1;
                if not init_done then
                    prem_cnt <= prem_cnt + 1;
                    report "worldwake PREMATURE DELIVERY: extra IACK before "
                           & "runtime init (frame " & integer'image(frame_i) &
                           ", " & integer'image(clks_vb) &
                           " clks after vblank) - the POST-derail hazard"
                        severity warning;
                end if;
            end if;
        end if;
    end process;

    verdict : process
        variable alive : boolean;
        variable exp_w : integer;
    begin
        wait until done;
        wait for 1 us;
        exp_w := frame_i - ready_frame;
        alive := ready_seen and (frame_i - ready_frame) > 20 and
                 (wake_cnt - wake_at_rdy) * 10 >= exp_w * 8;   -- >=80% of frames
        report "=== WORLDWAKE METRICS: frames " & integer'image(frame_i) &
               "  ready_frame " & integer'image(ready_frame) &
               "  wakes " & integer'image(wake_cnt) &
               "  iacks " & integer'image(iack_cnt) &
               "  premature " & integer'image(prem_cnt) &
               "  restarts " & integer'image(restart_cnt) &
               "  reldrops " & integer'image(reldrop_cnt) &
               "  storm_max " & integer'image(storm_max) &
               "  failpark " & integer'image(fail_park) &
               "  ackdly_avg " &
               integer'image(ack_sum / (ack_n + boolean'pos(ack_n = 0))) &
               " ===" severity note;
        if alive then
            report "WORLDWAKE VERDICT: ALIVE (mode " & integer'image(G_EIRQ) &
                   ", fpen " & integer'image(G_FPEN) & ")" severity note;
        else
            report "WORLDWAKE VERDICT: DEAD (mode " & integer'image(G_EIRQ) &
                   ", fpen " & integer'image(G_FPEN) & ") - ready " &
                   boolean'image(ready_seen) & ", epc 0x" & hex16(m_epc)
                severity note;
        end if;
        wait;
    end process;
end tb;
