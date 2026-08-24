-- CADENCE-107 meter bench: does the logic-frame cadence counter in
-- escape_core.vhd count what it claims to count?
--
-- The counter is a new HUD number, and a HUD number nobody has ever made
-- WRONG is not evidence of anything. The image (sim/tools/make_cadence_hex.py)
-- executes an exactly known number of the write the meter taps - the main
-- CPU's "logic frame starting" flag write, move.b #$50,$16CCD4 - plus three
-- decoys it must ignore: the same address with the wrong data, the WORLD
-- flag written by the wrong CPU, and the odd byte of the same word (low lane).
--
-- The bench requires the live counter to equal the expected number EXACTLY,
-- and requires the world counter (tapped on the extra CPU's port, and the
-- extra CPU is never released here) to be exactly zero. Off-by-one from a
-- multi-clock write strobe, a byte-lane mistake, or a too-loose address
-- compare each fail on one of those two numbers.
--
-- This bench does NOT prove the 256-frame window arithmetic or the HUD
-- plumbing; it proves the tap. The window is a divider and a latch.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_escape_cadence is
    generic (
        G_FPEN   : integer := 1;      -- escape_core FASTPATH_EN
        G_FP     : integer := 1;      -- fastpath server fill latency, clks
        G_SHAD   : integer := 1;      -- shadow BRAMs filled + enabled
        G_VS3    : integer := 1;      -- escape_core VSHAD3_EN
        G_LAT    : integer := 2;      -- legacy rom service latency
        G_RUN    : integer := 400000; -- clocks to let the image finish in
        G_GOOD   : integer := 137;    -- make_cadence_hex.py N_GOOD
        G_HEX    : string  := "sim/work/cadence_words.hex"
    );
end tb_escape_cadence;

architecture tb of tb_escape_cadence is
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

    signal probe_v, probe_w : unsigned(15 downto 0);
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
                   p1_buttons=>"0000", p2_buttons=>"0000" );

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
                fill_range(16#050000#, 16#8000#);  -- vshad3
            end if;
            fill_range(16#080000#, 16#4000#);      -- eshad
            fill_range(16#08F000#, 16#1000#);      -- eshad2
        end if;
        fill_done <= true;
        wait;
    end process;

    -- the check
    probe_v <= << signal uut.cad_v_ctr : unsigned(15 downto 0) >>;
    probe_w <= << signal uut.cad_w_ctr : unsigned(15 downto 0) >>;

    checker : process
        variable l : line;
        variable gv, gw : integer;
    begin
        wait until fill_done;
        wait for 100 ns;
        resetn <= '1';
        for i in 1 to G_RUN loop wait until rising_edge(clk); end loop;
        gv := to_integer(probe_v);
        gw := to_integer(probe_w);
        write(l, string'("CADENCE video_starts=")); write(l, gv);
        write(l, string'(" expected=")); write(l, G_GOOD);
        write(l, string'("   world_starts=")); write(l, gw);
        write(l, string'(" expected=0"));
        writeline(output, l);
        if gv = 0 then
            write(l, string'("CADENCE FAIL: the meter counted nothing - the CPU never ran, or the tap is dead. This is NOT a pass."));
            writeline(output, l);
        elsif gv /= G_GOOD then
            write(l, string'("CADENCE FAIL: video counter is wrong (decoys counted, or a write double-counted)"));
            writeline(output, l);
        elsif gw /= 0 then
            write(l, string'("CADENCE FAIL: world counter moved, but the extra CPU never ran"));
            writeline(output, l);
        else
            write(l, string'("CADENCE PASS: exact count, all three decoys rejected"));
            writeline(output, l);
        end if;
        assert gv = G_GOOD and gw = 0
            report "CADENCE meter check failed" severity failure;
        done <= true;
        wait;
    end process;
end tb;
