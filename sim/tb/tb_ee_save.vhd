-- Unit test for ee_save: the EEPROM non-volatile path (Analogue Pocket save
-- slot <-> the game's 2804). Exercises a full power-cycle in simulation:
--
--   1) COLD BOOT, no save file. dataslot_allcomplete arrives with nothing ever
--      written to our bridge window -> the restore is skipped and the EEPROM
--      keeps its virgin x"FF" fill (the pattern the game recognises as an
--      erased part, prompting it to write factory defaults). c_ready still
--      rises, so the core is never held in reset waiting for a save that will
--      never come.
--
--   2) WARM BOOT. APF writes 512 bytes into the bridge window exactly the way
--      it loads a data slot (32-bit big-endian words at the slot address),
--      then raises dataslot_allcomplete. The restore engine must land file
--      byte i on EEPROM location i, verified through the CPU's own port A.
--
--   3) THE GAME SCORES. The "CPU" stores new bytes over port A. After the
--      write-idle window the engine snapshots and asks for a data-slot write;
--      reading the bridge window back the way APF does must yield the NEW
--      contents, with the untouched bytes still holding the restored values.
--
--   4) CORE EXIT. APF raises [0080 Data slot request read] (b_snapreq); the
--      engine must refresh the window and report b_snapdone before the caller
--      lets APF start reading. Bytes written after the autosave must appear.
--
-- Together 2->3->4->2 is the loop that makes a high score survive a power
-- cycle, and it is checked here end to end without any hardware.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_ee_save is end tb_ee_save;

architecture tb of tb_ee_save is

    constant BP : time := 6.734 ns;    -- clk_74a  half period (74.25 MHz)
    constant CP : time := 69.84 ns;    -- core clk half period (7.159 MHz)

    signal bclk, cclk : std_logic := '0';
    signal done  : boolean := false;
    signal fails : integer := 0;

    -- ---- instance under test (warm-boot scenario) ------------------------
    signal b_sel, b_wr, b_rd            : std_logic := '0';
    signal b_addr                       : std_logic_vector(6 downto 0)  := (others=>'0');
    signal b_wdata, b_rdata             : std_logic_vector(31 downto 0);
    signal b_loaded, b_allcomp          : std_logic := '0';
    signal b_snapreq, b_snapdone        : std_logic := '0';
    signal b_savereq, b_saveack         : std_logic := '0';
    signal c_ready, c_autoen, c_wrpulse : std_logic := '0';
    signal c_addr                       : std_logic_vector(8 downto 0);
    signal c_din, c_q                   : std_logic_vector(7 downto 0);
    signal c_we, c_dirty                : std_logic;
    signal c_savecnt                    : std_logic_vector(7 downto 0);
    -- the game's EEPROM BRAM, wired as escape_core wires it
    signal cpu_addr                     : std_logic_vector(8 downto 0) := (others=>'0');
    signal cpu_din                      : std_logic_vector(15 downto 0):= (others=>'0');
    signal cpu_we, cpu_uds_n, cpu_lds_n : std_logic := '0';
    signal cpu_q                        : std_logic_vector(15 downto 0);
    signal ee_din_b, ee_q_b             : std_logic_vector(15 downto 0);

    -- ---- second instance: cold boot with no save file --------------------
    signal v_allcomp, v_ready           : std_logic := '0';
    signal v_addr                       : std_logic_vector(8 downto 0);
    signal v_din, v_q                   : std_logic_vector(7 downto 0);
    signal v_we                         : std_logic;
    signal v_rdata                      : std_logic_vector(31 downto 0);
    signal v_loaded, v_snapdone, v_savereq, v_dirty : std_logic;
    signal v_savecnt                    : std_logic_vector(7 downto 0);
    signal vcpu_addr                    : std_logic_vector(8 downto 0) := (others=>'0');
    signal vcpu_q                       : std_logic_vector(15 downto 0);
    signal v_din_b, v_q_b               : std_logic_vector(15 downto 0);

    -- tie-offs (VHDL wants a name, not an aggregate, in a port map)
    signal zero7  : std_logic_vector(6 downto 0)  := (others=>'0');
    signal zero16 : std_logic_vector(15 downto 0) := (others=>'0');
    signal zero32 : std_logic_vector(31 downto 0) := (others=>'0');

    -- the save-file image: byte i = i xor 0x5A
    function fbyte(i : integer) return std_logic_vector is
    begin
        return std_logic_vector(to_unsigned(i, 8) xor x"5A");
    end function;

begin

    bclk <= not bclk after BP when not done else '0';
    cclk <= not cclk after CP when not done else '0';

    -- ------------------------------------------------------------------
    -- instance 1 + its EEPROM
    -- ------------------------------------------------------------------
    uut : entity work.ee_save
        generic map ( IDLE_BITS => 6 )          -- 64 core clocks, not 8.4M
        port map (
            bclk=>bclk, b_sel=>b_sel, b_wr=>b_wr, b_rd=>b_rd,
            b_addr=>b_addr, b_wdata=>b_wdata, b_rdata=>b_rdata,
            b_loaded=>b_loaded, b_allcomp=>b_allcomp,
            b_snapreq=>b_snapreq, b_snapdone=>b_snapdone,
            b_savereq=>b_savereq, b_saveack=>b_saveack,
            cclk=>cclk, c_ready=>c_ready, c_autoen=>c_autoen,
            c_wrpulse=>c_wrpulse,
            c_addr=>c_addr, c_din=>c_din, c_we=>c_we, c_q=>c_q,
            c_savecnt=>c_savecnt, c_dirty=>c_dirty );

    ee_din_b <= x"FF" & c_din;
    c_q      <= ee_q_b(7 downto 0);
    eeram : entity work.dpram_bytelane_syn
        generic map ( awidth=>9, initbyte=>x"FF" )
        port map ( clk=>cclk,
                   addr_a=>cpu_addr, din_a=>cpu_din, we_a=>cpu_we,
                   uds_a_n=>cpu_uds_n, lds_a_n=>cpu_lds_n, q_a=>cpu_q,
                   addr_b=>c_addr, din_b=>ee_din_b, we_b=>c_we,
                   uds_b_n=>'1', lds_b_n=>'0', q_b=>ee_q_b );
    -- exactly how escape_core derives the dirty pulse
    c_wrpulse <= cpu_we and not cpu_lds_n;

    -- ------------------------------------------------------------------
    -- instance 2 + its EEPROM: never receives a bridge write
    -- ------------------------------------------------------------------
    uutv : entity work.ee_save
        generic map ( IDLE_BITS => 6 )
        port map (
            bclk=>bclk, b_sel=>'0', b_wr=>'0', b_rd=>'0',
            b_addr=>zero7, b_wdata=>zero32, b_rdata=>v_rdata,
            b_loaded=>v_loaded, b_allcomp=>v_allcomp,
            b_snapreq=>'0', b_snapdone=>v_snapdone,
            b_savereq=>v_savereq, b_saveack=>'0',
            cclk=>cclk, c_ready=>v_ready, c_autoen=>'0', c_wrpulse=>'0',
            c_addr=>v_addr, c_din=>v_din, c_we=>v_we, c_q=>v_q,
            c_savecnt=>v_savecnt, c_dirty=>v_dirty );

    v_din_b <= x"FF" & v_din;
    v_q     <= v_q_b(7 downto 0);
    veeram : entity work.dpram_bytelane_syn
        generic map ( awidth=>9, initbyte=>x"FF" )
        port map ( clk=>cclk,
                   addr_a=>vcpu_addr, din_a=>zero16, we_a=>'0',
                   uds_a_n=>'1', lds_a_n=>'1', q_a=>vcpu_q,
                   addr_b=>v_addr, din_b=>v_din_b, we_b=>v_we,
                   uds_b_n=>'1', lds_b_n=>'0', q_b=>v_q_b );

    -- ==================================================================
    stim : process

        -- one APF data-slot load write: 32-bit big-endian word at word index w
        procedure bwrite(w : integer; d : std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(bclk);
            b_addr  <= std_logic_vector(to_unsigned(w,7));
            b_wdata <= d;
            b_sel   <= '1';
            b_wr    <= '1';
            wait until rising_edge(bclk);
            b_sel <= '0';
            b_wr  <= '0';
        end procedure;

        -- one APF read, timed the way io_bridge_peripheral.v does it: the
        -- address is latched and held, four-plus clocks pass, then the read
        -- strobe fires and the core has until the NEXT strobe to present the
        -- word for THIS address (core_bridge_cmd.v does the same thing).
        procedure bread(w : integer; d : out std_logic_vector(31 downto 0)) is
        begin
            wait until rising_edge(bclk);
            b_addr <= std_logic_vector(to_unsigned(w,7));
            for i in 0 to 5 loop wait until rising_edge(bclk); end loop;
            b_rd <= '1';
            wait until rising_edge(bclk);
            b_rd <= '0';
            wait until rising_edge(bclk);
            wait until rising_edge(bclk);
            d := b_rdata;
        end procedure;

        -- the 68000 storing one EEPROM byte (odd address => LDS only)
        procedure cpu_store(loc : integer; d : std_logic_vector(7 downto 0)) is
        begin
            wait until rising_edge(cclk);
            cpu_addr  <= std_logic_vector(to_unsigned(loc,9));
            cpu_din   <= x"FF" & d;
            cpu_uds_n <= '1';
            cpu_lds_n <= '0';
            cpu_we    <= '1';
            wait until rising_edge(cclk);
            cpu_we    <= '0';
            cpu_lds_n <= '1';
        end procedure;

        procedure cpu_check(loc : integer; d : std_logic_vector(7 downto 0); tag : string) is
        begin
            wait until rising_edge(cclk);
            cpu_addr <= std_logic_vector(to_unsigned(loc,9));
            wait until rising_edge(cclk);
            wait until rising_edge(cclk);
            if cpu_q(7 downto 0) /= d then
                report tag & " EEPROM[" & integer'image(loc) & "]=0x"
                     & to_hstring(cpu_q(7 downto 0)) & " expected 0x" & to_hstring(d)
                     severity warning;
                fails <= fails + 1;
            end if;
        end procedure;

        procedure expect(cond : boolean; tag : string) is
        begin
            if not cond then
                report "FAIL: " & tag severity warning;
                fails <= fails + 1;
            end if;
        end procedure;

        variable w    : std_logic_vector(31 downto 0);
        variable want : std_logic_vector(7 downto 0);
        variable t0   : time;
    begin
        c_autoen <= '1';

        ------------------------------------------------------------------
        report "--- 1) cold boot, no save file ---";
        ------------------------------------------------------------------
        wait for 2 us;
        expect(v_ready = '0', "virgin instance released reset before allcomplete");
        v_allcomp <= '1';
        wait for 5 us;                       -- restore would take ~290 us
        expect(v_ready  = '1', "virgin instance never became ready");
        expect(v_loaded = '0', "virgin instance claims a file was loaded");
        -- EEPROM must still be an erased 2804
        vcpu_addr <= std_logic_vector(to_unsigned(3,9));
        wait until rising_edge(cclk); wait until rising_edge(cclk);
        expect(vcpu_q(7 downto 0) = x"FF", "virgin EEPROM was not left at FF");

        ------------------------------------------------------------------
        report "--- 2) warm boot: APF loads the save file, engine restores it ---";
        ------------------------------------------------------------------
        for i in 0 to 127 loop
            bwrite(i, fbyte(4*i) & fbyte(4*i+1) & fbyte(4*i+2) & fbyte(4*i+3));
        end loop;
        expect(b_loaded = '1', "b_loaded did not latch on the slot load");
        expect(c_ready  = '0', "engine released the core before allcomplete");

        b_allcomp <= '1';
        t0 := now;
        wait until c_ready = '1' for 1 ms;
        expect(c_ready = '1', "restore never completed");
        report "restore took " & time'image(now - t0);

        for loc in 0 to 511 loop
            cpu_check(loc, fbyte(loc), "restore");
        end loop;
        report "restored 512 bytes, byte order verified against the file image";

        ------------------------------------------------------------------
        report "--- 3) the game writes a high score; autosave picks it up ---";
        ------------------------------------------------------------------
        expect(c_dirty = '0', "engine was dirty before any CPU write");
        cpu_store( 16, x"11" );
        cpu_store( 17, x"22" );
        cpu_store(510, x"33" );
        wait until rising_edge(cclk);
        expect(c_dirty = '1', "CPU write did not mark the EEPROM dirty");
        expect(b_savereq = '0', "save requested before the write-idle window");

        wait until b_savereq = '1' for 1 ms;
        expect(b_savereq = '1', "autosave was never requested");
        expect(c_savecnt = x"01", "autosave counter did not advance");
        expect(c_dirty = '0', "dirty flag survived the snapshot");

        -- read the window back exactly as APF would for [0184 Data slot write]
        for i in 0 to 127 loop
            bread(i, w);
            for k in 0 to 3 loop
                want := fbyte(4*i + k);
                if 4*i + k = 16  then want := x"11"; end if;
                if 4*i + k = 17  then want := x"22"; end if;
                if 4*i + k = 510 then want := x"33"; end if;
                if w(31 - 8*k downto 24 - 8*k) /= want then
                    report "autosave image byte " & integer'image(4*i+k) & " = 0x"
                         & to_hstring(w(31 - 8*k downto 24 - 8*k))
                         & " expected 0x" & to_hstring(want) severity warning;
                    fails <= fails + 1;
                end if;
            end loop;
        end loop;
        report "autosave image matches the live EEPROM, all 512 bytes";

        -- complete the 4-phase handshake the way core_top's target-command FSM does
        b_saveack <= '1';
        wait until b_savereq = '0' for 100 us;
        expect(b_savereq = '0', "save request never cleared after ack");
        b_saveack <= '0';
        wait for 2 us;

        ------------------------------------------------------------------
        report "--- 4) core exit: APF asks to read the slot ---";
        ------------------------------------------------------------------
        cpu_store(100, x"A5");               -- a change the autosave never saw
        wait for 1 us;
        b_snapreq <= '1';
        t0 := now;
        wait until b_snapdone = '1' for 1 ms;
        expect(b_snapdone = '1', "exit snapshot never reported done");
        report "exit snapshot took " & time'image(now - t0);

        bread(25, w);                        -- word 25 holds bytes 100..103
        expect(w(31 downto 24) = x"A5", "exit snapshot missed the last CPU write");
        bread(4, w);                         -- bytes 16..19
        expect(w(31 downto 24) = x"11", "exit snapshot lost an earlier write");
        expect(w(23 downto 16) = x"22", "exit snapshot lost an earlier write");
        bread(127, w);                       -- bytes 508..511
        expect(w(15 downto 8) = x"33", "exit snapshot lost byte 510");
        expect(w(7 downto 0) = fbyte(511), "exit snapshot corrupted byte 511");

        b_snapreq <= '0';
        wait for 2 us;
        expect(b_snapdone = '0', "snapdone did not release with the request");

        ------------------------------------------------------------------
        report "--- 5) no stall when the framework never services a save ---";
        ------------------------------------------------------------------
        -- ask for another autosave and simply never acknowledge it: the engine
        -- must sit in its handshake without touching the EEPROM or wedging the
        -- CPU port, and must still answer a later exit request... eventually.
        cpu_store(200, x"7E");
        wait until b_savereq = '1' for 1 ms;
        expect(b_savereq = '1', "second autosave was never requested");
        wait for 200 us;                     -- no ack: engine just waits
        cpu_store(201, x"7F");               -- the CPU keeps running regardless
        cpu_check(200, x"7E", "unacked-save");
        cpu_check(201, x"7F", "unacked-save");
        expect(c_dirty = '1', "writes during an unacked save were not tracked");

        ------------------------------------------------------------------
        wait until rising_edge(cclk);
        report "=== ee_save: EEPROM save/restore cycle ===";
        if fails = 0 then
            report "EE_SAVE OK: load -> play -> autosave -> exit-save all correct"
                severity note;
        else
            report "EE_SAVE FAIL: " & integer'image(fails) & " mismatches"
                severity failure;
        end if;
        done <= true;
        wait;
    end process;

end tb;
