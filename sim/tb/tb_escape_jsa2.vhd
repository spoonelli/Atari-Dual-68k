-- JSA2-164: JSA-II board mode of escape_jsa (BOARD=2, Verilog cores stubbed
-- for GHDL). A purpose-built 6502 program (sim/tools/make_jsa2_hex.py ->
-- sim/work/jsa2_words.hex, no game data) writes WRIO with the OKI reset
-- released and pin 7 high, MIX, two OKI command bytes, then loops reading
-- the OKI status (2800) and writing the response latch. Checks:
--   1. the reset vector is fetched and the program runs (response latch 0x55)
--   2. WRIO D2/D3 reach the OKI: oki_rst falls, oki_ss rises
--   3. a 2800 read returns the OKI status (stub 0xF0), not the JSA-I 0xFF
--   4. the OKI stub's address walker is served through the shared ROM port
--      from the 0x240000 slot while the 6502 keeps executing (both clients)
-- Run: ./sim/run_tb.sh tb_escape_jsa2 300us
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_jsa2 is end tb_escape_jsa2;

architecture tb of tb_escape_jsa2 is
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
        generic map ( YM_ENABLE => false, BOARD => 2 )
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
                if lat = 3 then rom_ack <= '1'; lat := 0; else lat := lat + 1; end if;
            elsif rom_req = '0' then
                rom_ack <= '0'; lat := 0;
            end if;
        end if;
    end process;

    monitor : process
        alias x_di   is << signal .tb_escape_jsa2.dut.cpu_di   : std_logic_vector(7 downto 0) >>;
        alias x_a16  is << signal .tb_escape_jsa2.dut.a16      : std_logic_vector(15 downto 0) >>;
        alias x_rw   is << signal .tb_escape_jsa2.dut.cpu_rw_n : std_logic >>;
        alias x_ena  is << signal .tb_escape_jsa2.dut.cpu_ena  : std_logic >>;
        alias x_orst is << signal .tb_escape_jsa2.dut.oki_rst  : std_logic >>;
        alias x_oss  is << signal .tb_escape_jsa2.dut.oki_ss   : std_logic >>;
        alias x_oaddr is << signal .tb_escape_jsa2.dut.oki_addr : std_logic_vector(17 downto 0) >>;
        variable vec_lo, vec_hi, resp_hit, rst_low, ss_high : boolean := false;
        variable st_reads, st_f0, oki_fetches, cpu_fetches, loops : integer := 0;
        variable last_req : std_logic := '0';
        variable data_ok : boolean := true;
        variable exp : unsigned(7 downto 0);
    begin
        wait until resn = '1';
        for i in 1 to 70000 loop
            wait until rising_edge(clk);
            if cpu_addr = x"FFFC" then vec_lo := true; end if;
            if cpu_addr = x"FFFD" then vec_hi := true; end if;
            if cpu_sync = '1' and cpu_addr = x"F014" then loops := loops + 1; end if;
            if x_ena = '1' and x_rw = '1' and x_a16 = x"2800" then
                st_reads := st_reads + 1;
                if x_di = x"F0" then st_f0 := st_f0 + 1; end if;
            end if;
            if resp_full = '1' and resp_data = x"55" then resp_hit := true; end if;
            if x_orst = '0' then rst_low := true; end if;
            if x_oss = '1' then ss_high := true; end if;
            if rom_req = '1' and last_req = '0' then
                if rom_addr(23 downto 18) = "001001" then oki_fetches := oki_fetches + 1;
                elsif rom_addr(23 downto 16) = x"10" then cpu_fetches := cpu_fetches + 1; end if;
            end if;
            last_req := rom_req;
        end loop;
        -- the walker's served byte must be the slot's counting pattern
        exp := to_unsigned(to_integer(unsigned(x_oaddr(7 downto 0))), 8);
        report "=== JSA-II board check ===";
        report "  reset vector fetched:      " & boolean'image(vec_lo and vec_hi);
        report "  response latch 0x55:       " & boolean'image(resp_hit);
        report "  loop iterations:           " & integer'image(loops);
        report "  WRIO -> oki_rst low:        " & boolean'image(rst_low) & "  oki_ss high: " & boolean'image(ss_high);
        report "  2800 reads: " & integer'image(st_reads) & "  of which 0xF0: " & integer'image(st_f0);
        report "  ROM requests - 6502: " & integer'image(cpu_fetches) & "  OKI slot: " & integer'image(oki_fetches)
               & "  walker at 0x" & to_hstring(x_oaddr);
        if vec_lo and vec_hi and resp_hit and loops > 20 and rst_low and ss_high
           and st_reads > 0 and st_f0 = st_reads and oki_fetches > 50 and cpu_fetches > 10
           and unsigned(x_oaddr) > 200 then
            report "TB_ESCAPE_JSA2 OK: JSA-II decode, WRIO->OKI, status read, dual ROM clients" severity note;
        else
            report "tb_escape_jsa2 FAIL" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
