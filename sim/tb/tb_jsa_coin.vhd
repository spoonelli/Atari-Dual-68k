-- Coin-pipeline validation: escape_jsa with the real firmware, a held COIN1,
-- and a consuming 68k side (resp_rd pulsed whenever resp_full rises, like the
-- attract-mode IRQ6 handler). The coin scan lives in the BANKED ROM window and
-- runs off the 250Hz timed IRQ with multi-scan debounce, so this needs tens of
-- milliseconds: run with  ./sim/run_tb.sh tb_jsa_coin 30ms
-- Pass: a response byte that is neither 00 (idle) nor FF (boot announce)
-- reaches the latch - the firmware reporting the coin.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_jsa_coin is end tb_jsa_coin;

architecture tb of tb_jsa_coin is
    signal clk     : std_logic := '0';
    signal resn    : std_logic := '0';
    signal done    : boolean   := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';

    signal resp_data : std_logic_vector(7 downto 0);
    signal resp_full : std_logic;
    signal resp_rd   : std_logic := '0';
    signal cmd_full  : std_logic;
    signal snd_irq   : std_logic;
    signal audio_l, audio_r : std_logic_vector(15 downto 0);
    signal cpu_addr  : std_logic_vector(15 downto 0);
    signal cpu_sync  : std_logic;
    signal coin1     : std_logic := '0';

    signal w_even, w_odd : std_logic_vector(20 downto 0);
    signal q_even, q_odd : std_logic_vector(15 downto 0);

    signal coin_reported : boolean := false;
    signal banked_seen   : boolean := false;
begin
    clk  <= not clk after 2 ns when not done else '0';
    resn <= '0', '1' after 41 ns;
    coin1 <= '1' after 3 ms;    -- held coin, well after boot announce

    dut : entity work.escape_jsa
        generic map ( YM_ENABLE => false )
        port map (
            clk       => clk,
            reset_n   => resn,
            snd_res   => '0',
            rom_addr  => rom_addr,
            rom_data  => rom_data,
            rom_req   => rom_req,
            rom_ack   => rom_ack,
            cmd_data  => x"00",
            cmd_we    => '0',
            resp_data => resp_data,
            resp_rd   => resp_rd,
            cmd_full  => cmd_full,
            resp_full => resp_full,
            snd_irq   => snd_irq,
            coin1     => coin1,
            coin2     => '0',
            test_mode => '0',
            audio_l   => audio_l,
            audio_r   => audio_r,
            dbg_cpu_addr => cpu_addr,
            dbg_cpu_sync => cpu_sync );

    w_even <= rom_addr(21 downto 1);
    w_odd  <= rom_addr(21 downto 2) & '1';
    rom_e : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => w_even, data => q_even );
    rom_o : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => w_odd, data => q_odd );
    rom_data <= q_even & q_odd;

    serve : process(clk)
        variable lat : integer := 0;
    begin
        if rising_edge(clk) then
            if rom_req = '1' and rom_ack = '0' then
                if lat = 3 then
                    rom_ack <= '1';
                    lat := 0;
                else
                    lat := lat + 1;
                end if;
            elsif rom_req = '0' then
                rom_ack <= '0';
                lat := 0;
            end if;
        end if;
    end process;

    -- consuming 68k side: read (and log) each response ~20 cycles after it posts
    consume : process(clk)
        variable full_d : std_logic := '0';
        variable delay  : integer := 0;
        variable n      : integer := 0;
    begin
        if rising_edge(clk) then
            resp_rd <= '0';
            if resp_full = '1' and delay = 0 then
                delay := 20;
            elsif delay > 1 then
                delay := delay - 1;
            elsif delay = 1 then
                if n < 40 then
                    report "RESP consumed: 0x" & to_hstring(resp_data);
                    n := n + 1;
                end if;
                if resp_data /= x"00" and resp_data /= x"FF" then
                    coin_reported <= true;
                end if;
                resp_rd <= '1';
                delay := 0;
            end if;
            full_d := resp_full;
        end if;
    end process;

    -- prove the banked window executes: watch for opcode fetches in 3000-3FFF
    bank_watch : process(clk)
    begin
        if rising_edge(clk) then
            if cpu_sync = '1' and cpu_addr(15 downto 12) = x"3" then
                if not banked_seen then
                    report "BANKED fetch: PC 0x" & to_hstring(cpu_addr);
                end if;
                banked_seen <= true;
            end if;
        end if;
    end process;

    -- IRQ/scan visibility: timed-int edges, IRQ vector fetches, 2804 reads,
    -- and a coarse PC sample every 4 ms
    irq_watch : process(clk)
        alias xtint is << signal .tb_jsa_coin.dut.timed_int : std_logic >>;
        variable tint_d : std_logic := '0';
        variable tints, vecs, scans : integer := 0;
        variable next_dump : time := 4 ms;
    begin
        if rising_edge(clk) then
            if xtint='1' and tint_d='0' then
                tints := tints + 1;
                if tints <= 3 then report "TIMED IRQ #" & integer'image(tints); end if;
            end if;
            tint_d := xtint;
            if cpu_addr = x"FFFE" then
                vecs := vecs + 1;
                if vecs <= 3 then report "IRQ VECTOR fetch #" & integer'image(vecs); end if;
            end if;
            if cpu_addr = x"2804" or cpu_addr = x"280C" then
                scans := scans + 1;
                if scans <= 3 or scans mod 500 = 0 then
                    report "PORT2804 read #" & integer'image(scans);
                end if;
            end if;
            if now >= next_dump then
                report "PCDUMP @" & time'image(now) & " addr 0x" & to_hstring(cpu_addr)
                       & " tints=" & integer'image(tints) & " vecs=" & integer'image(vecs)
                       & " scans=" & integer'image(scans);
                next_dump := next_dump + 4 ms;
            end if;
        end if;
    end process;

    tmsprobe : process
        alias xDDIS is << signal .tb_jsa_coin.dut.u_tms.m_DDIS : std_logic >>;
        alias xSPEN is << signal .tb_jsa_coin.dut.u_tms.m_SPEN : std_logic >>;
        alias xTALK is << signal .tb_jsa_coin.dut.u_tms.m_TALK : std_logic >>;
        alias xPTR  is << signal .tb_jsa_coin.dut.u_tms.m_FIFO_ptr : integer range 0 to 128 >>;
        alias xWSn  is << signal .tb_jsa_coin.dut.u_tms.m_WSn : std_logic >>;
        alias xRSn  is << signal .tb_jsa_coin.dut.u_tms.m_RSn : std_logic >>;
    begin
        wait for 100 us;
        report "TMSP early: WSn=" & std_logic'image(xWSn) & " RSn=" & std_logic'image(xRSn)
             & " ptr=" & integer'image(xPTR);
        wait for 200 us;
        report "TMSP postrst: WSn=" & std_logic'image(xWSn) & " RSn=" & std_logic'image(xRSn)
             & " DDIS=" & std_logic'image(xDDIS) & " ptr=" & integer'image(xPTR);
        for i in 1 to 28 loop
            wait for 1 ms;
            report "TMSP t=" & integer'image(i) & "ms DDIS=" & std_logic'image(xDDIS)
                 & " SPEN=" & std_logic'image(xSPEN) & " TALK=" & std_logic'image(xTALK)
                 & " ptr=" & integer'image(xPTR);
        end loop;
        wait;
    end process;

    check : process
    begin
        wait for 118 ms;
        report "=== JSA coin pipeline ===";
        report "  banked code executed: " & boolean'image(banked_seen);
        report "  coin reported: " & boolean'image(coin_reported);
        if coin_reported then
            report "TB_JSA_COIN OK: held coin produced a report byte" severity note;
        else
            report "TB_JSA_COIN FAIL: no coin report in 115 ms of held coin" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
