-- VSHAD3-107 BUS-RATE bench: how many CPU clocks does one main-CPU ROM bus
-- cycle actually cost, on the shipped escape_core, shadowed vs fastpath?
--
-- BUILD 107 runs the video CPU at 22,203 bus cycles/frame against MAME's
-- 25,630 (0.866), and the extra CPU at 20,509 against 22,244 (0.922). The
-- structural difference between the two is how much of each CPU's hot code is
-- SHADOWED: 80 KB for the main CPU, 20 KB for the extra. Since the zero-wait
-- fastpath landed, that is the wrong way round - a fastpath hit closes the
-- cycle at the authentic 4-clock phase, the shadow BRAM path takes the +1
-- waitstate arm - so the shadows now cost the main CPU a clock on exactly its
-- hottest code, and v_shad_rng suppresses the fastpath there so it cannot
-- make the difference back.
--
-- That claim is arithmetic on a clock count, so measure the clock count.
--
-- METHOD. The image (sim/tools/make_busrate_hex.py) is a 128-byte NOP loop at
-- a chosen address. NOP touches no data, so every bus cycle is an instruction
-- fetch from the region under test. Count v_as_n falling edges - the same
-- edge escape_core's own vcyc_fr meter counts, which is the same number the
-- hardware HUD reports - over a fixed window of CPU clocks, after a warmup.
-- Report cycles, and clocks per cycle.
--
-- WHAT THIS MEASURES: the per-access cost of each path, on the real RTL.
-- WHAT IT DOES NOT MEASURE: how much of the real game's execution lands in
-- each range (that is a MAME page profile), and what the fastpath hit rate is
-- under real MO + refresh contention. The G_FP knob is the honest handle on
-- the second one: it is the fill latency the fastpath server takes to answer,
-- so sweeping it says how fast the gain decays if contention grows. Nothing
-- here is a substitute for the owner's hardware.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_escape_busrate is
    generic (
        G_FPEN   : integer := 1;      -- escape_core FASTPATH_EN
        G_FP     : integer := 1;      -- fastpath server fill latency, clks
        G_SHAD   : integer := 1;      -- shadow BRAMs filled + enabled
        G_VS3    : integer := 1;      -- escape_core VSHAD3_EN (compile-time)
        G_VS3ON  : integer := 1;      -- escape_core vshad3_on port (runtime)
        G_LAT    : integer := 2;      -- legacy rom service latency
        G_WARM   : integer := 20000;  -- clocks to settle before counting
        G_CLKS   : integer := 200000; -- clocks to count over
        G_HEX    : string  := "sim/work/busrate_words.hex"
    );
end tb_escape_busrate;

architecture tb of tb_escape_busrate is
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

    signal m_vas   : std_logic;
    signal m_vaddr : std_logic_vector(31 downto 0);

    signal vs3on    : std_logic;
    signal cyc_cnt  : integer := 0;   -- v_as_n falling edges inside the window
    signal clk_cnt  : integer := 0;   -- clocks inside the window
    -- VSHAD3-112: the old range was one 32 KB block; it is now two 16 KB
    -- halves, only the HIGH one of which is shadowed (measured: 94.5% of the
    -- main CPU's gameplay traffic in 0x50000-0x57FFF lands in 0x54000-0x57FFF
    -- and pages 0x50000-0x52FFF are never touched at all). Count both halves
    -- separately so the bench STATES where the loop ran instead of assuming.
    signal lohalf_cnt : integer := 0; -- cycles in 0x50000-0x53FFF (NOT shadowed)
    signal shad_cnt   : integer := 0; -- cycles in 0x54000-0x57FFF (shadowed)
    signal fast_cnt : integer := 0;   -- ...and how many were fastpath-eligible
begin
    clk <= not clk after 5 ns when not done else '0';

    uut : entity work.escape_core
        generic map ( YM_ENABLE => 0, SHAD_EN => G_SHAD, VSHAD3_EN => G_VS3,
                      FASTPATH_EN => G_FPEN, EIRQ_MODE => 2 )
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
                   vshad3_on=>vs3on,
                   p1_buttons=>"0000", p2_buttons=>"0000" );
    vs3on <= '1' when G_VS3ON = 1 else '0';

    m_vas   <= << signal uut.v_as_n : std_logic >>;
    m_vaddr <= << signal uut.v_addr : std_logic_vector(31 downto 0) >>;

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

    -- fastpath server model, as validated in tb_escape_vecrace / worldwake.
    -- G_FP is the fill latency in CPU clocks: 1 is the authentic hit (the
    -- ~13 clk_sdram fill lands well before the first post-AS CPU edge), and
    -- larger values model SDRAM contention deferring the fill.
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

    -- shadow fill through the download port while reset is held. Every range
    -- escape_core decodes as a shadow is filled, including vshad3 - filling
    -- less than the decode covers would serve stale zeroes as instructions.
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
            fill_range(16#000000#, 16#4000#);      -- vshad
            fill_range(16#048000#, 16#8000#);      -- vshad2
            if G_VS3 = 1 then
                -- VSHAD3-112: the shadow is 16 KB (0x54000-0x57FFF) but this
                -- still offers the whole old 32 KB. escape_core's vshad3_we
                -- decode drops everything below 0x54000, so the other half is
                -- simply not written - a superset fill is safe, an undersized
                -- one would serve zeroes as instructions. Deliberately NOT
                -- gated by G_VS3ON: the runtime toggle gates the decode, not
                -- the fill, and the bench has to be able to toggle the shadow
                -- back ON and still find real code in the BRAM.
                fill_range(16#050000#, 16#8000#);  -- vshad3
            end if;
            fill_range(16#080000#, 16#4000#);      -- eshad
            fill_range(16#08F000#, 16#1000#);      -- eshad2
        end if;
        fill_done <= true;
        wait;
    end process;

    -- the measurement
    meter : process
        variable vas_d : std_logic := '1';
        variable l : line;
    begin
        wait until fill_done;
        wait for 100 ns;
        resetn <= '1';
        for i in 1 to G_WARM loop wait until rising_edge(clk); end loop;
        vas_d := m_vas;
        for i in 1 to G_CLKS loop
            wait until rising_edge(clk);
            clk_cnt <= clk_cnt + 1;
            if m_vas = '0' and vas_d = '1' then
                cyc_cnt <= cyc_cnt + 1;
                if m_vaddr(23 downto 14) = "0000010100" then
                    lohalf_cnt <= lohalf_cnt + 1;
                end if;
                if m_vaddr(23 downto 14) = "0000010101" then
                    shad_cnt <= shad_cnt + 1;
                end if;
                if unsigned(m_vaddr(23 downto 0)) <= x"09FFFF" then
                    fast_cnt <= fast_cnt + 1;
                end if;
            end if;
            vas_d := m_vas;
        end loop;

        write(l, string'("=== BUSRATE: fpen=")); write(l, G_FPEN);
        write(l, string'(" fp=")); write(l, G_FP);
        write(l, string'(" shad=")); write(l, G_SHAD);
        write(l, string'(" vs3=")); write(l, G_VS3);
        write(l, string'(" vs3on=")); write(l, G_VS3ON);
        writeline(output, l);
        write(l, string'("BUSRATE clocks=")); write(l, clk_cnt);
        write(l, string'(" buscycles=")); write(l, cyc_cnt);
        write(l, string'(" in_50000_53FFF=")); write(l, lohalf_cnt);
        write(l, string'(" in_54000_57FFF=")); write(l, shad_cnt);
        write(l, string'(" in_rom=")); write(l, fast_cnt);
        writeline(output, l);
        -- clocks per bus cycle, to three decimals, without real arithmetic
        if cyc_cnt > 0 then
            write(l, string'("BUSRATE milliclocks_per_cycle="));
            write(l, (clk_cnt * 1000) / cyc_cnt);
            write(l, string'("  (i.e. clocks/cycle x1000)"));
            writeline(output, l);
        else
            write(l, string'("BUSRATE FAIL: the CPU issued no bus cycles - "
                             & "the image or the reset vector is wrong, "
                             & "this is NOT a result"));
            writeline(output, l);
        end if;
        done <= true;
        wait;
    end process;
end tb;
