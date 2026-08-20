-- tb_tms_phrase: replay the REAL announcer phrase-1 byte stream captured from
-- MAME's 6502 bus (sim/work/phrase1_bytes.txt: NOP padding, Speak External,
-- ~209 LPC bytes = the 0.8s phrase, then zero-fill silence frames) into the
-- chip alone, with authentic WRIO-style WS strobes and ready pacing.
-- Purpose: measure the phrase TAIL - when does TALK drop relative to the fed
-- frames, and does the audio truncate early ("phrases cut off too soon", 4E
-- device report). Dumps 48kHz samples + TALK to sim/build/phrase_audio.txt.
-- Run: ./sim/run_tb.sh tb_tms_phrase 2000ms
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_tms_phrase is end tb_tms_phrase;

architecture tb of tb_tms_phrase is
    signal clk    : std_logic := '0';
    signal done   : boolean := false;
    signal ctr    : unsigned(3 downto 0) := (others => '0');
    signal ena    : std_logic;
    signal wsn    : std_logic := '1';
    signal rsn    : std_logic := '1';
    signal dbus   : std_logic_vector(7 downto 0) := (others => '0');
    signal rdyn, intn : std_logic;
    signal spkr   : signed(13 downto 0);
    signal bytes_fed : integer := 0;
begin
    clk <= not clk after 69.84 ns when not done else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if ctr = "1111" then ctr <= "0101"; else ctr <= ctr + 1; end if;
        end if;
    end process;
    ena <= '1' when ctr = "1111" else '0';

    dut : entity work.TMS5220
    port map (
        I_OSC => clk, I_ENA => ena,
        I_WSn => wsn, I_RSn => rsn,
        I_DATA => '1', I_TEST => '1',
        I_DBUS => dbus,
        O_DBUS => open, O_RDYn => rdyn, O_INTn => intn,
        O_M0 => open, O_M1 => open, O_ADD8 => open, O_ADD4 => open,
        O_ADD2 => open, O_ADD1 => open, O_ROMCLK => open,
        O_T11 => open, O_IO => open, O_PRMOUT => open,
        O_SPKR => spkr
    );

    dump : process
        alias xTALK  is << signal .tb_tms_phrase.dut.m_TALK  : std_logic >>;
        alias xTALKD is << signal .tb_tms_phrase.dut.m_TALKD : std_logic >>;
        alias xPTR   is << signal .tb_tms_phrase.dut.m_FIFO_ptr : integer range 0 to 128 >>;
        alias xNRG   is << signal .tb_tms_phrase.dut.m_current_energy : integer range -8192 to 8191 >>;
        file f : text open write_mode is "sim/build/phrase_audio.txt";
        variable l : line;
    begin
        loop
            wait for 20833 ns;    -- 48kHz
            write(l, integer'image(to_integer(spkr)) & " " &
                     std_logic'image(xTALK) & " " &
                     std_logic'image(xTALKD) & " " &
                     integer'image(xPTR) & " " &
                     integer'image(xNRG) & " " &
                     integer'image(bytes_fed));
            writeline(f, l);
        end loop;
    end process;

    stim : process
        file fb : text open read_mode is "sim/work/phrase1_bytes.txt";
        variable l : line;
        variable s : string(1 to 2);
        variable b : std_logic_vector(7 downto 0);
        function h2b(s : string(1 to 2)) return std_logic_vector is
            variable r : std_logic_vector(7 downto 0);
            variable n : integer;
        begin
            n := 0;
            for i in 1 to 2 loop
                n := n * 16;
                case s(i) is
                    when '0' to '9' => n := n + character'pos(s(i)) - 48;
                    when 'a' to 'f' => n := n + character'pos(s(i)) - 87;
                    when 'A' to 'F' => n := n + character'pos(s(i)) - 55;
                    when others => null;
                end case;
            end loop;
            r := std_logic_vector(to_unsigned(n, 8));
            return r;
        end function;
    begin
        -- power-on WS+RS reset combo like escape_jsa (143us-class)
        wait for 20 us;
        wsn <= '0'; rsn <= '0';
        wait for 150 us;
        wsn <= '1'; rsn <= '1';
        wait for 20 us;
        report "PHRASE: replaying MAME byte stream";
        while not endfile(fb) loop
            readline(fb, l);
            read(l, s);
            b := h2b(s);
            -- firmware pacing: poll ready level, then WRIO-style strobe
            while rdyn = '1' loop wait for 2 us; end loop;
            dbus <= b;
            wait for 1 us;
            wsn  <= '0';
            wait for 3 us;
            wsn  <= '1';
            wait for 2 us;
            bytes_fed <= bytes_fed + 1;
        end loop;
        report "PHRASE: all bytes fed (" & integer'image(bytes_fed) & "), letting synthesis finish";
        wait for 900 ms;
        report "PHRASE DONE";
        done <= true;
        wait;
    end process;
end tb;
