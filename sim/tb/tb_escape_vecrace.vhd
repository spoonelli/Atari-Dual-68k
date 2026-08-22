-- Interrupt-dispatch data-corruption hunt (SDSCHED-78/79 class), exhaustive
-- IRQ phase sweep. The extra CPU runs a synthetic mirror of the real ROM's
-- dispatch chain (autovector 0x70 -> stub 0x308 -> trampoline 0x800 -> ISR
-- 0x842 -> RTE) while vblank pulses arrive with a period that increments one
-- clock per IRQ, so over thousands of IRQs every phase alignment between the
-- interrupt and the main loop's bus activity (and the TG68K wrapper's 10-clk
-- E/sync rotation) is exercised.
--
-- Checkers (VHDL-2008 external names into the DUT):
--   a. every COMPLETED extra-CPU read below 0x10000 (ROM-backed space) must
--      return the image's true word - classified as VECTOR (0x64-0x7F),
--      STUB (0x308), TRAMPOLINE (0x800-0x823) or ROM;
--   b. wild-PC: a program-space fetch inside the 0xA58-0xB80 data table =
--      the hardware wedge reproduced;
--   c. EARLY-TERM: a read cycle that completed with DTACK never asserted
--      (the TG68K vpad/sync9 termination path firing on a normal cycle);
--   d. heartbeat: the main loop's counter write to $16F010 must keep moving.
--
-- G_SHAD=1 additionally fills vshad1/eshad1/eshad2 through the download port
-- before releasing reset, so the dispatch chain is BRAM-shadow-served (the
-- hardware path) while the 0x6000 main loop still fetches over SDRAM.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_escape_vecrace is
    generic (
        G_SHAD  : integer := 0;       -- escape_core SHAD_EN
        G_NIRQ  : integer := 20000;   -- IRQs to fire
        G_BASE  : integer := 500;     -- base IRQ period, clks
        G_SWEEP : integer := 613;     -- phase modulus (period = BASE + phase)
        G_PHOFF : integer := 0;       -- phase offset: phase = (G_PHOFF+i) mod G_SWEEP
                                      -- (parallel sweep slices use disjoint offsets)
        G_LAT   : integer := 2;       -- rom service latency, clks
        G_HEX   : string  := "sim/work/vecrace_words.hex"
    );
end tb_escape_vecrace;

architecture tb of tb_escape_vecrace is
    constant AW : integer := 19;                  -- image word-address width
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
            readline(f, l);
            hread(l, w, ok);
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

    signal shad_wclk  : std_logic := '0';
    signal shad_waddr : std_logic_vector(23 downto 0) := (others=>'0');
    signal shad_wdata : std_logic_vector(15 downto 0) := (others=>'0');
    signal shad_we    : std_logic := '0';
    signal fill_done  : boolean := false;

    -- sweep bookkeeping (written by the irq process, read by checkers)
    signal irq_idx   : integer := 0;
    signal irq_phase : integer := 0;

    -- heartbeat snoop
    signal hb : std_logic_vector(15 downto 0) := (others=>'0');

    -- external-name mirrors into the DUT
    signal m_eaddr  : std_logic_vector(31 downto 0);
    signal m_edi    : std_logic_vector(15 downto 0);
    signal m_edo    : std_logic_vector(15 downto 0);
    signal m_eas    : std_logic;
    signal m_erw    : std_logic;
    signal m_edtack : std_logic;
    signal m_efc    : std_logic_vector(2 downto 0);
    signal m_epc    : std_logic_vector(15 downto 0);
    signal m_sstate : std_logic_vector(1 downto 0);
    signal m_vpad   : std_logic;
    signal m_waitm  : std_logic;

    -- observation counters
    signal iack_cyc_cnt   : integer := 0;  -- clk cycles with FC=111 & AS low
    signal earlyterm_cnt  : integer := 0;  -- reads completed with DTACK high
    signal rd_checked_cnt : integer := 0;  -- completed ROM-space reads checked

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
        generic map ( YM_ENABLE => 0, SHAD_EN => G_SHAD )
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par,
                   rom_req=>rom_req, rom_ack=>rom_ack,
                   shad_wclk=>shad_wclk, shad_waddr=>shad_waddr,
                   shad_wdata=>shad_wdata, shad_we=>shad_we,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   dbg_force_extra=>'1' );

    -- external names: DUT bus + TG68K wrapper internals
    m_eaddr  <= << signal uut.e_addr    : std_logic_vector(31 downto 0) >>;
    m_edi    <= << signal uut.e_di      : std_logic_vector(15 downto 0) >>;
    m_edo    <= << signal uut.e_do      : std_logic_vector(15 downto 0) >>;
    m_eas    <= << signal uut.e_as_n    : std_logic >>;
    m_erw    <= << signal uut.e_rw_n    : std_logic >>;
    m_edtack <= << signal uut.e_dtack_n : std_logic >>;
    m_efc    <= << signal uut.e_fc      : std_logic_vector(2 downto 0) >>;
    m_epc    <= << signal uut.epc_i     : std_logic_vector(15 downto 0) >>;
    m_sstate <= << signal uut.ecpu.S_state : std_logic_vector(1 downto 0) >>;
    m_vpad   <= << signal uut.ecpu.vpad    : std_logic >>;
    m_waitm  <= << signal uut.ecpu.waitm   : std_logic >>;

    -- ROM service: two 16-bit words per request (addr, addr+2), G_LAT-cycle
    -- latency, 4-phase level handshake - same shape as the proven irq bench.
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

    -- shadow fill (G_SHAD=1): stream the image's shadowed ranges through the
    -- download port while reset is held. Ranges: video 0x0000-0x3FFF
    -- (vshad1), extra 0x080000-0x083FFF (eshad1), 0x08F000-0x08FFFF (eshad2).
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

    -- IRQ phase sweep: pulse period = G_BASE + (i mod G_SWEEP) clks, so the
    -- IRQ arrival slides one clock per pulse against every internal rhythm.
    irq_gen : process
        variable period : integer;
    begin
        wait until resetn = '1';
        wait for 50 us;                       -- let the main loop settle
        for i in 1 to G_NIRQ loop
            irq_idx   <= i;
            irq_phase <= (G_PHOFF + i) mod G_SWEEP;
            vblank <= '1';
            wait for 200 ns;                  -- 20-clk pulse
            vblank <= '0';
            period := G_BASE + ((G_PHOFF + i) mod G_SWEEP);
            wait for period * 10 ns;
            if (i mod 1000) = 0 then
                report "vecrace progress: irq " & integer'image(i) & "/" &
                       integer'image(G_NIRQ) & "  phase " &
                       integer'image((G_PHOFF + i) mod G_SWEEP) & "  hb " & hex16(hb) &
                       "  reads_checked " & integer'image(rd_checked_cnt) &
                       "  iack_cyc " & integer'image(iack_cyc_cnt) &
                       "  earlyterm " & integer'image(earlyterm_cnt);
            end if;
            exit when done;
        end loop;
        wait for 100 us;                      -- drain
        report "=== vecrace sweep COMPLETE: " & integer'image(G_NIRQ) &
               " IRQs, reads_checked " & integer'image(rd_checked_cnt) &
               ", iack_cyc " & integer'image(iack_cyc_cnt) &
               ", earlyterm " & integer'image(earlyterm_cnt) &
               ", hb " & hex16(hb) & " - NO CORRUPTION" severity note;
        done <= true;
        wait;
    end process;

    -- checker: read-completion truth compare + wild-PC trap.
    -- TG68K captures DATAI at the same rising edge where it releases AS, so
    -- at the first edge that samples AS high, the *_q values (sampled one
    -- edge earlier) are exactly what the CPU latched.
    check : process(clk)
        variable as_q     : std_logic := '1';
        variable rw_q     : std_logic := '1';
        variable dtack_q  : std_logic := '1';
        variable di_q     : std_logic_vector(15 downto 0) := (others=>'0');
        variable addr_q   : std_logic_vector(23 downto 0) := (others=>'0');
        variable fc_q     : std_logic_vector(2 downto 0) := "000";
        variable a        : integer;
        variable exp      : std_logic_vector(15 downto 0);
        variable kind     : line;
    begin
        if rising_edge(clk) and resetn='1' then
            -- wild-PC: program-space fetch inside the data table = the wedge
            if m_eas='0' and m_erw='1' and m_efc(1)='1' and m_efc(0)='0'
               and m_eaddr(23 downto 16) = x"00" then
                a := to_integer(unsigned(m_eaddr(15 downto 0)));
                if a >= 16#A58# and a <= 16#B80# then
                    report "VECRACE WEDGE REPRODUCED: wild program fetch at 0x" &
                           hex16(m_eaddr(15 downto 0)) &
                           "  time " & time'image(now) &
                           "  irq " & integer'image(irq_idx) &
                           "  phase " & integer'image(irq_phase) &
                           "  epc_i " & hex16(m_epc)
                        severity failure;
                end if;
            end if;

            -- IACK-shaped cycles (FC=111, AS low): count them
            if m_eas='0' and m_efc="111" then
                iack_cyc_cnt <= iack_cyc_cnt + 1;
            end if;

            -- completed READ detection (AS just released after a read)
            if m_eas='1' and as_q='0' and rw_q='1' then
                if dtack_q='1' and fc_q /= "111" then
                    earlyterm_cnt <= earlyterm_cnt + 1;
                    report "VECRACE EARLY-TERM: read of 0x" &
                           hex16(addr_q(15 downto 0)) & " (hi 0x" &
                           hex16(x"00" & addr_q(23 downto 16)) &
                           ") completed with DTACK never asserted; data 0x" &
                           hex16(di_q) & "  fc " &
                           integer'image(to_integer(unsigned(fc_q))) &
                           "  time " & time'image(now) &
                           "  irq " & integer'image(irq_idx) &
                           "  phase " & integer'image(irq_phase)
                        severity warning;
                end if;
                -- truth compare for ROM-backed extra space (addr < 0x10000)
                if addr_q(23 downto 16) = x"00" and fc_q /= "111" then
                    a   := to_integer(unsigned(addr_q(15 downto 0)));
                    exp := img((16#080000# + a) / 2);
                    rd_checked_cnt <= rd_checked_cnt + 1;
                    if di_q /= exp then
                        if a >= 16#64# and a <= 16#7F# then
                            write(kind, string'("VECTOR READ"));
                        elsif a >= 16#800# and a <= 16#823# then
                            write(kind, string'("TRAMPOLINE FETCH"));
                        elsif a >= 16#308# and a <= 16#30D# then
                            write(kind, string'("STUB FETCH"));
                        else
                            write(kind, string'("ROM READ"));
                        end if;
                        report "VECRACE CORRUPTION (" & kind.all & "): addr 0x" &
                               hex16(addr_q(15 downto 0)) &
                               " expected 0x" & hex16(exp) &
                               " received 0x" & hex16(di_q) &
                               "  fc " & integer'image(to_integer(unsigned(fc_q))) &
                               "  dtack_at_capture " & std_logic'image(dtack_q) &
                               "  time " & time'image(now) &
                               "  irq " & integer'image(irq_idx) &
                               "  phase " & integer'image(irq_phase) &
                               "  epc_i " & hex16(m_epc)
                            severity failure;
                    end if;
                end if;
            end if;

            -- heartbeat snoop: main-loop counter write to $16F010
            if m_eas='0' and m_erw='0' and m_eaddr(23 downto 0) = x"16F010" then
                hb <= m_edo;
            end if;

            as_q    := m_eas;
            rw_q    := m_erw;
            dtack_q := m_edtack;
            di_q    := m_edi;
            addr_q  := m_eaddr(23 downto 0);
            fc_q    := m_efc;
        end if;
    end process;

    -- heartbeat watchdog: the main loop must keep counting; a silent wedge
    -- (derailed somewhere the traps don't cover) shows up here.
    hb_watch : process
        variable hb_prev : std_logic_vector(15 downto 0) := (others=>'0');
    begin
        wait until resetn='1';
        wait for 300 us;
        loop
            wait for 500 us;
            exit when done;
            if hb = hb_prev then
                report "VECRACE WEDGE (heartbeat stall): hb stuck at 0x" &
                       hex16(hb) & "  epc_i 0x" & hex16(m_epc) &
                       "  e_addr 0x" & hex16(m_eaddr(15 downto 0)) &
                       "  S_state " & integer'image(to_integer(unsigned(m_sstate))) &
                       "  vpad " & std_logic'image(m_vpad) &
                       "  waitm " & std_logic'image(m_waitm) &
                       "  time " & time'image(now) &
                       "  irq " & integer'image(irq_idx) &
                       "  phase " & integer'image(irq_phase)
                    severity failure;
            end if;
            hb_prev := hb;
        end loop;
        wait;
    end process;
end tb;
