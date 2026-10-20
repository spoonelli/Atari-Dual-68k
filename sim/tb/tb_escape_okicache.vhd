-- OKICACHE-186 GATE: the JSA-II OKI6295 ROM cache under jt6295's real access
-- pattern. escape_jsa runs with OKI_STUB_MODE=1: a model of jt6295_rom /
-- jt6295_timing drives the chip address exactly as the Verilog core does
-- (ctrl address on six slots of every channel region, that channel's ADPCM
-- address on two, all the time), four channels walking through the 0x240000
-- slot (filled with byte = address & 0xFF), channel 3 restarting elsewhere
-- every 120 samples. The ROM port answers after G_LAT clocks, roughly the
-- Pocket's escape_core OWN_J + CDC + SDRAM round trip.
-- Checks:
--   1. no LIES: whenever the cache says rom_ok, the byte is the right one
--      (the pre-186 cache filed a fill that straddled a slot change under
--      the new address and served those bytes as its data);
--   2. no WARM misses: an ADPCM byte the chip latches past the first two
--      groups of a phrase is correct (the next-group prefetch had it);
--   3. OKI SDRAM requests per sample stay near the ideal (4 channels, one
--      4-byte group per 8 samples each = 0.5/sample). The pre-186 cache
--      thrashed between ctrl and ADPCM addresses: ~8 per sample, forever.
-- Run: python3 sim/tools/make_jsa2_hex.py && ./sim/run_tb.sh tb_escape_okicache 10ms
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_okicache is
    generic ( G_LAT : integer := 14; G_CYC : integer := 250000 );
end tb_escape_okicache;

architecture tb of tb_escape_okicache is
    signal clk     : std_logic := '0';
    signal resn    : std_logic := '0';
    signal done    : boolean   := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';

    signal resp_data : std_logic_vector(7 downto 0);
    signal resp_full : std_logic;
    signal cmd_full  : std_logic;
    signal snd_irq   : std_logic;
    signal audio_l, audio_r : std_logic_vector(15 downto 0);
    signal cpu_addr  : std_logic_vector(15 downto 0);
    signal cpu_sync  : std_logic;

    signal w_even, w_odd : std_logic_vector(20 downto 0);
    signal q_even, q_odd : std_logic_vector(15 downto 0);
begin
    clk  <= not clk after 2 ns when not done else '0';
    resn <= '0', '1' after 41 ns;

    dut : entity work.escape_jsa
        generic map ( YM_ENABLE => false, BOARD => 2, OKI_STUB_MODE => 1 )
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
            resp_rd   => '0',
            cmd_full  => cmd_full,
            resp_full => resp_full,
            snd_irq   => snd_irq,
            coin1     => '0',
            coin2     => '0',
            test_mode => '0',
            audio_l   => audio_l,
            audio_r   => audio_r,
            dbg_cpu_addr => cpu_addr,
            dbg_cpu_sync => cpu_sync );

    w_even <= rom_addr(21 downto 1);
    w_odd  <= rom_addr(21 downto 2) & '1';
    rom_e : entity work.rom_words
        generic map ( hexfile => "sim/work/jsa2_words.hex", awidth => 21 )
        port map ( addr => w_even, data => q_even );
    rom_o : entity work.rom_words
        generic map ( hexfile => "sim/work/jsa2_words.hex", awidth => 21 )
        port map ( addr => w_odd, data => q_odd );
    rom_data <= q_even & q_odd;

    serve : process(clk)
        variable lat : integer := 0;
    begin
        if rising_edge(clk) then
            if rom_req = '1' and rom_ack = '0' then
                if lat = G_LAT then rom_ack <= '1'; lat := 0; else lat := lat + 1; end if;
            elsif rom_req = '0' then
                rom_ack <= '0'; lat := 0;
            end if;
        end if;
    end process;

    monitor : process
        alias x_oaddr is << signal .tb_escape_okicache.dut.oki_addr  : std_logic_vector(17 downto 0) >>;
        alias x_ordat is << signal .tb_escape_okicache.dut.oki_rdata : std_logic_vector(7 downto 0) >>;
        alias x_ook   is << signal .tb_escape_okicache.dut.oki_ok    : std_logic >>;
        alias x_orst  is << signal .tb_escape_okicache.dut.oki_rst   : std_logic >>;
        alias x_n     is << signal .tb_escape_okicache.dut.pm_n      : integer >>;
        alias x_badw  is << signal .tb_escape_okicache.dut.pm_badw   : integer >>;
        alias x_badc  is << signal .tb_escape_okicache.dut.pm_badc   : integer >>;
        variable lies, oki_fetches, cpu_fetches, n0, f0 : integer := 0;
        variable last_req : std_logic := '0';
        variable warm : boolean := false;
    begin
        wait until resn = '1';
        for i in 1 to G_CYC loop
            wait until rising_edge(clk);
            if x_ook = '1' and x_ordat /= x_oaddr(7 downto 0) then lies := lies + 1; end if;
            if rom_req = '1' and last_req = '0' then
                if rom_addr(23 downto 18) = "001001" then oki_fetches := oki_fetches + 1;
                elsif rom_addr(23 downto 16) = x"10" then cpu_fetches := cpu_fetches + 1; end if;
            end if;
            last_req := rom_req;
            -- rate is measured after the first 40 samples (cold start excluded)
            if not warm and x_n >= 160 then warm := true; n0 := x_n; f0 := oki_fetches; end if;
        end loop;
        report "=== OKI cache under the jt6295 access pattern (lat " & integer'image(G_LAT) & ") ===";
        report "  ADPCM captures: " & integer'image(x_n) & "  (" & integer'image(x_n / 4) & " samples)";
        report "  wrong bytes latched - warm: " & integer'image(x_badw) & "  cold (phrase start): " & integer'image(x_badc);
        report "  rom_ok with wrong data (lies): " & integer'image(lies);
        report "  ROM requests - 6502: " & integer'image(cpu_fetches) & "  OKI: " & integer'image(oki_fetches)
               & "  OKI per 100 samples (warm): " & integer'image(((oki_fetches - f0) * 400) / (x_n - n0 + 1));
        if x_orst = '0' and x_n > 1000 and lies = 0 and x_badw = 0
           and ((oki_fetches - f0) * 400) / (x_n - n0 + 1) < 100 and cpu_fetches > 10 then
            report "TB_ESCAPE_OKICACHE OK: no lies, no warm misses, OKI traffic near ideal" severity note;
        else
            report "tb_escape_okicache FAIL" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
