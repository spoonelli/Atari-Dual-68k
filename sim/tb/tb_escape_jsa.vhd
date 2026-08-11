-- JSA-I sound board bring-up: escape_jsa (YM stubbed for VHDL-only GHDL) with
-- the real 6502 program served from the user's combined image hex
-- (sim/work/combined_words.hex, NEVER committed) at word offset 0x100000/2 via
-- rom_words, through the same req/ack + col|1-burst ROM bus the SDRAM side
-- presents. Pass criteria: the 6502 fetches its reset vector (FFFC/FFFD),
-- executes from the vectored PC, and its early self-init writes the response
-- latch (resp_full rises). Run: ./sim/run_tb.sh tb_escape_jsa
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_jsa is end tb_escape_jsa;

architecture tb of tb_escape_jsa is
    signal clk     : std_logic := '0';
    signal resn    : std_logic := '0';
    signal done    : boolean   := false;
    signal timeout : boolean   := false;

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

    -- combined image as 16-bit words; 0x220000 bytes -> 0x110000 words < 2^21
    signal w_even, w_odd : std_logic_vector(20 downto 0);
    signal q_even, q_odd : std_logic_vector(15 downto 0);
begin
    -- 7.159 MHz domain; short period so 500 us of sim time covers ~60k CPU cycles
    clk  <= not clk after 2 ns when not done else '0';
    resn <= '0', '1' after 41 ns;

    dut : entity work.escape_jsa
        generic map ( YM_ENABLE => false )     -- jt51 is Verilog: silence stub
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

    -- serve the combined image; second burst word is addr|1 (SDRAM col|1 rule)
    w_even <= rom_addr(21 downto 1);
    w_odd  <= rom_addr(21 downto 2) & '1';

    rom_e : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => w_even, data => q_even );
    rom_o : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => w_odd, data => q_odd );

    rom_data <= q_even & q_odd;

    -- 4-phase req/ack server with a few cycles of latency
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

    monitor : process
        variable vec_lo, vec_hi : boolean := false;
        variable exec_pc  : boolean := false;
        variable resp_hit : boolean := false;
        variable syncs    : integer := 0;
        variable pc       : std_logic_vector(15 downto 0);
    begin
        wait until resn = '1';
        while not timeout loop
            wait until rising_edge(clk);
            if cpu_addr = x"FFFC" then vec_lo := true; end if;
            if cpu_addr = x"FFFD" then vec_hi := true; end if;
            if cpu_sync = '1' then
                if syncs = 0 and vec_lo and vec_hi then
                    pc := cpu_addr;
                    report "JSA 6502: reset vector fetched, first opcode at PC 0x"
                           & to_hstring(cpu_addr);
                end if;
                syncs := syncs + 1;
                exec_pc := exec_pc or (vec_lo and vec_hi);
            end if;
            if resp_full = '1' and not resp_hit then
                resp_hit := true;
                report "JSA 6502: response latch written, value 0x"
                       & to_hstring(resp_data) & " after "
                       & integer'image(syncs) & " opcodes (snd_irq="
                       & std_logic'image(snd_irq) & ")";
                exit;
            end if;
        end loop;
        if vec_lo and vec_hi and exec_pc and resp_hit then
            report "TB_ESCAPE_JSA OK: reset vector + execution + response write"
                severity note;
        elsif timeout then
            report "tb_escape_jsa: window ended without a response-latch write; "
                 & "last CPU addr 0x" & to_hstring(cpu_addr)
                 & " opcodes=" & integer'image(syncs)
                 & " vector_fetched=" & boolean'image(vec_lo and vec_hi)
                severity warning;
        end if;
        done <= true;
        wait;
    end process;

    watchdog : process
    begin
        wait for 480 us;
        timeout <= true;
        wait;
    end process;
end tb;
