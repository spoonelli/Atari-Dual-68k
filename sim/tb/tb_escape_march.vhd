-- Runs the GAME'S OWN RAM-march routine (0xAAC) against color RAM inside the
-- real escape_core, via a reset-vector stub (sim/tools/make_march_hex.py).
-- The march result lands in alpha RAM: alpha[1]=0xABCD done, alpha[0]=d0
-- (0000 = march passed; nonzero = the EOR mismatch the game would report as
-- 'Color RAM BAD'). Reproduces the hardware failure in full visibility, or
-- proves the logic clean under ideal ROM latency.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_march is end tb_escape_march;

architecture tb of tb_escape_march is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;
    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';
    signal rom_par  : std_logic := '0';
    signal vblank   : std_logic := '0';
    signal alpha_vaddr : std_logic_vector(10 downto 0) := (others=>'0');
    signal alpha_vdata : std_logic_vector(15 downto 0);
    signal dbg_v, dbg_e : std_logic;
    signal romsrv_data, romsrv_data2 : std_logic_vector(15 downto 0);
    signal rom_addr2w : std_logic_vector(20 downto 0);
begin
    clk    <= not clk after 5 ns when not done else '0';
    resetn <= '0', '1' after 205 ns;
    rom_addr2w <= rom_addr(21 downto 2) & '1';   -- real col|1 burst

    uut : entity work.escape_core
        generic map ( YM_ENABLE => 0 )   -- GHDL: no mixed-language jt51
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
                   dbg_v_pc_fetch=>dbg_v, dbg_e_running=>dbg_e );

    romsrv : entity work.rom_words
        generic map ( hexfile => "sim/work/march_words.hex", awidth => 21 )
        port map ( addr => rom_addr(21 downto 1), data => romsrv_data );
    romsrv2 : entity work.rom_words
        generic map ( hexfile => "sim/work/march_words.hex", awidth => 21 )
        port map ( addr => rom_addr2w, data => romsrv_data2 );

    -- ROM server with hardware-realistic VARIABLE latency: LFSR picks 2..17
    -- cycles per transaction (models SDRAM contention + CDC phase randomness).
    serve : process(clk)
        variable lat    : integer := 0;
        variable target : integer := 2;
        variable served : boolean := false;
        variable lfsr   : std_logic_vector(15 downto 0) := x"ACE1";
    begin
        if rising_edge(clk) then
            if rom_req='1' then
                if not served then
                    if lat >= target then
                        rom_data <= romsrv_data & romsrv_data2;
                        rom_par  <= xor (romsrv_data & romsrv_data2);
                        rom_ack  <= '1'; served := true; lat := 0;
                        lfsr := lfsr(14 downto 0) &
                                (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
                        target := 2 + to_integer(unsigned(lfsr(3 downto 0)));
                    else lat := lat + 1; end if;
                end if;
            else rom_ack <= '0'; served := false; lat := 0; end if;
        end if;
    end process;

    vb : process
    begin
        wait for 100 us;
        loop
            vblank <= '1'; wait for 10 us;
            vblank <= '0'; wait for 6 us;
            exit when done;
        end loop;
        wait;
    end process;

    check : process
        variable result : std_logic_vector(15 downto 0);
    begin
        -- poll alpha[1] for the 0xABCD done marker
        loop
            alpha_vaddr <= std_logic_vector(to_unsigned(1, 11));
            wait until rising_edge(clk); wait until rising_edge(clk);
            exit when alpha_vdata = x"ABCD";
            wait for 20 us;
            if now > 4 ms then
                report "MARCH TIMEOUT: never finished (wedge reproduced?)" severity failure;
            end if;
        end loop;
        alpha_vaddr <= std_logic_vector(to_unsigned(0, 11));
        wait until rising_edge(clk); wait until rising_edge(clk);
        result := alpha_vdata;
        report "=== game march on color RAM (32 words) ===";
        report "  march result d0 = 0x" & to_hstring(result);
        if result = x"0000" then
            report "MARCH OK: game's own test passes on our color RAM" severity note;
        else
            report "MARCH FAIL: reproduced 'Color RAM BAD', bad bits 0x" & to_hstring(result) severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
