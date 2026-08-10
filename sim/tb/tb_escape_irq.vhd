-- TG68K 68010 exception-frame test: heartbeat loop with IRQs ENABLED while the
-- game's REAL vblank ISR (0x5CC: movem, jsr $20006, rte) fires repeatedly.
-- Healthy: alpha[2] heartbeat keeps counting across many IRQs and the ISR acks
-- 360000 each time. Broken frames: heartbeat freezes / CPU derails.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_irq is end tb_escape_irq;

architecture tb of tb_escape_irq is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;
    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';
    signal vblank   : std_logic := '0';
    signal alpha_vaddr : std_logic_vector(10 downto 0) := (others=>'0');
    signal alpha_vdata : std_logic_vector(15 downto 0);
    signal dbg_v, dbg_e : std_logic;
    signal romsrv_data, romsrv_data2 : std_logic_vector(15 downto 0);
    signal rom_addr2w : std_logic_vector(20 downto 0);
begin
    clk    <= not clk after 5 ns when not done else '0';
    resetn <= '0', '1' after 205 ns;
    rom_addr2w <= rom_addr(21 downto 2) & '1';

    uut : entity work.escape_core
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
                   dbg_v_pc_fetch=>dbg_v, dbg_e_running=>dbg_e );

    romsrv : entity work.rom_words
        generic map ( hexfile => "sim/work/irq_words.hex", awidth => 21 )
        port map ( addr => rom_addr(21 downto 1), data => romsrv_data );
    romsrv2 : entity work.rom_words
        generic map ( hexfile => "sim/work/irq_words.hex", awidth => 21 )
        port map ( addr => rom_addr2w, data => romsrv_data2 );

    serve : process(clk)
        variable lat : integer := 0; variable served : boolean := false;
    begin
        if rising_edge(clk) then
            if rom_req='1' then
                if not served then
                    if lat = 2 then
                        rom_data <= romsrv_data & romsrv_data2;
                        rom_ack  <= '1'; served := true; lat := 0;
                    else lat := lat + 1; end if;
                end if;
            else rom_ack <= '0'; served := false; lat := 0; end if;
        end if;
    end process;

    -- fast vblank cadence so many ISR round-trips fit in a short sim
    vb : process
    begin
        wait for 150 us;
        loop
            vblank <= '1'; wait for 5 us;
            vblank <= '0'; wait for 45 us;
            exit when done;
        end loop;
        wait;
    end process;

    check : process
        variable hb_prev : std_logic_vector(15 downto 0) := (others=>'0');
        variable hb_now  : std_logic_vector(15 downto 0);
        variable alive, stalls : integer := 0;
    begin
        alpha_vaddr <= std_logic_vector(to_unsigned(2, 11));
        wait for 200 us;                       -- past reset + first heartbeat
        for i in 1 to 30 loop                  -- 30 windows x 100us = 3ms, ~60 IRQs
            wait for 100 us;
            wait until rising_edge(clk); wait until rising_edge(clk);
            hb_now := alpha_vdata;
            if hb_now /= hb_prev then alive := alive + 1; else stalls := stalls + 1; end if;
            hb_prev := hb_now;
        end loop;
        report "=== IRQ/exception-frame check (TG68K CPU=01) ===";
        report "  heartbeat advanced in " & integer'image(alive) & "/30 windows, stalled " & integer'image(stalls);
        if alive >= 28 then
            report "IRQ OK: CPU survives repeated real-ISR round-trips" severity note;
        else
            report "IRQ FAIL: heartbeat stalled - exception frames corrupt the CPU" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
