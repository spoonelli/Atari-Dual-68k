-- Testbench for the ADC0809 model in escape_core: needs NO game ROM. A
-- stub image (sim/work/adc_words.hex, hand-assembled words only, rebuilt by
-- run_tb.sh via sim/tools/make_adc_hex.py) boots the video CPU, which walks the four ADC
-- channels the way the game does -- read 260020+2n to select/start, poll
-- 260010 D4 (ADEOC), read back the result -- storing each to alpha RAM plus
-- a done marker. The tb drives the adc_* ports with distinct values and
-- checks the results through the video-side alpha read port, proving the
-- channel select, conversion delay, EOC status bit and read-back data path
-- end to end at the 68k-visible level.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_adc is end tb_escape_adc;

architecture tb of tb_escape_adc is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';
    signal rom_par  : std_logic := '0';

    signal alpha_vaddr : std_logic_vector(10 downto 0) := (others=>'0');
    signal alpha_vdata : std_logic_vector(15 downto 0);

    -- known, distinct axis values (channel order: P1Y, P1X, P2Y, P2X)
    constant P1Y : std_logic_vector(7 downto 0) := x"12";
    constant P1X : std_logic_vector(7 downto 0) := x"34";
    constant P2Y : std_logic_vector(7 downto 0) := x"56";
    constant P2X : std_logic_vector(7 downto 0) := x"9A";

    signal romsrv_data, romsrv_data2 : std_logic_vector(15 downto 0);
    signal rom_word, rom_word2 : std_logic_vector(15 downto 0);
    signal rom_addr2w : std_logic_vector(11 downto 0);
begin
    clk    <= not clk after 5 ns when not done else '0';
    resetn <= '0', '1' after 205 ns;
    -- same REAL-SDRAM burst model as tb_escape_core: second word is col|1
    rom_addr2w <= rom_addr(12 downto 2) & '1';

    uut : entity work.escape_core
        generic map ( YM_ENABLE => 0 )   -- GHDL: no mixed-language jt51
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>'0',      -- no vblank: watchdog never ticks
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   adc_p1x=>P1X, adc_p1y=>P1Y, adc_p2x=>P2X, adc_p2y=>P2Y,
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata );

    -- stub-image ROM server: 8 KB window, everything outside it (extra CPU at
    -- +0x080000, JSA at the top of the image) reads as 0000, which parks the
    -- unused CPUs harmlessly
    romsrv : entity work.rom_words
        generic map ( hexfile => "sim/work/adc_words.hex", awidth => 12 )
        port map ( addr => rom_addr(12 downto 1), data => romsrv_data );
    romsrv2 : entity work.rom_words
        generic map ( hexfile => "sim/work/adc_words.hex", awidth => 12 )
        port map ( addr => rom_addr2w, data => romsrv_data2 );
    rom_word  <= romsrv_data  when unsigned(rom_addr(23 downto 13)) = 0 else x"0000";
    rom_word2 <= romsrv_data2 when unsigned(rom_addr(23 downto 13)) = 0 else x"0000";

    -- strict 4-phase, 3-cycle latency (SDRAM-ish), as in tb_escape_core
    serve : process(clk)
        variable lat    : integer := 0;
        variable served : boolean := false;
    begin
        if rising_edge(clk) then
            if rom_req='1' then
                if not served then
                    if lat = 2 then
                        rom_data <= rom_word & rom_word2;
                        rom_par  <= xor (rom_word & rom_word2);
                        rom_ack  <= '1';
                        served   := true;
                        lat := 0;
                    else
                        lat := lat + 1;
                    end if;
                end if;
            else
                rom_ack <= '0';
                served  := false;
                lat := 0;
            end if;
        end if;
    end process;

    check : process
        variable w : std_logic_vector(15 downto 0);

        -- read an alpha word through the video port (registered BRAM output)
        procedure rd_alpha(idx : integer) is
        begin
            alpha_vaddr <= std_logic_vector(to_unsigned(idx, 11));
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            wait until rising_edge(clk);
            w := alpha_vdata;
        end procedure;

        procedure expect(idx : integer; exp : std_logic_vector(15 downto 0);
                         name : string) is
        begin
            rd_alpha(idx);
            report "  " & name & " = 0x" & to_hstring(w)
                   & " (expect 0x" & to_hstring(exp) & ")";
            if w /= exp then
                report "ADC channel mismatch: " & name severity failure;
            end if;
        end procedure;
    begin
        -- wait for the stub's done marker (alpha word 4)
        loop
            rd_alpha(4);
            exit when w = x"ABCD";
            if now > 400 us then
                report "ADC stub never finished (marker=0x" & to_hstring(w) & ")"
                       severity failure;
            end if;
            wait for 1 us;
        end loop;
        report "=== escape_core ADC0809 (68k-visible, via stub program) ===";
        expect(0, x"00" & P1Y, "ch0 P1 Y");
        expect(1, x"00" & P1X, "ch1 P1 X");
        expect(2, x"00" & P2Y, "ch2 P2 Y");
        expect(3, x"00" & P2X, "ch3 P2 X");
        report "ESCAPE-ADC OK: channel select, conversion delay, ADEOC and "
               & "read-back all check out" severity note;
        done <= true;
        wait;
    end process;
end tb;
