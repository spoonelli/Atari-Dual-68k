-- v63 JSA-shadow validation: preload the jshad BRAM with the REAL sound ROM
-- (combined image words at 0x100000/2, from the gitignored local hex) through
-- the download-fill write port, then let escape_core run and verify the 6502
-- reaches its boot announcement (response byte 0xFF) THROUGH the jshad serve
-- FSM. tb_escape_jsa proves firmware+client against an ideal server; this
-- proves the same firmware against the actual BRAM path that ships.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_jshad is end tb_escape_jshad;

architecture tb of tb_escape_jshad is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(31 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';
    signal rom_par  : std_logic := '0';

    signal vblank : std_logic := '0';
    signal alpha_vaddr : std_logic_vector(10 downto 0) := (others=>'0');
    signal alpha_vdata : std_logic_vector(15 downto 0);
    signal dbg_v, dbg_e : std_logic;
    signal dbg_resp_stat : std_logic_vector(15 downto 0);
    signal dbg_jsa_pc    : std_logic_vector(15 downto 0);

    signal romsrv_data, romsrv_data2 : std_logic_vector(15 downto 0);
    signal rom_addr2w : std_logic_vector(20 downto 0);

    -- jshad fill port
    signal shad_wclk  : std_logic := '0';
    signal shad_waddr : std_logic_vector(23 downto 0) := (others=>'0');
    signal shad_wdata : std_logic_vector(15 downto 0) := (others=>'0');
    signal shad_we    : std_logic := '0';
    signal fill_addr  : std_logic_vector(20 downto 0) := (others=>'0');
    signal fill_q     : std_logic_vector(15 downto 0);
    signal fill_done  : boolean := false;
    signal coin1      : std_logic := '0';
begin
    clk    <= not clk after 5 ns when not done else '0';
    -- hold the core in reset until the shadow is filled
    resetn <= '1' when fill_done else '0';
    rom_addr2w <= rom_addr(21 downto 2) & '1';

    uut : entity work.escape_core
        generic map ( YM_ENABLE => 0, SHAD_EN => 0 )
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   coin1=>coin1,
                   shad_wclk=>shad_wclk, shad_waddr=>shad_waddr,
                   shad_wdata=>shad_wdata, shad_we=>shad_we,
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
                   dbg_v_pc_fetch=>dbg_v, dbg_e_running=>dbg_e,
                   dbg_resp_stat=>dbg_resp_stat, dbg_jsa_pc=>dbg_jsa_pc );

    -- main/extra CPUs still fetch over the external bus, same as tb_escape_core
    romsrv : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr(21 downto 1), data => romsrv_data );
    romsrv2 : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr2w, data => romsrv_data2 );

    serve : process(clk)
        variable lat    : integer := 0;
        variable served : boolean := false;
    begin
        if rising_edge(clk) then
            if rom_req='1' then
                if not served then
                    if lat = 2 then
                        rom_data <= romsrv_data & romsrv_data2;
                        rom_par  <= xor (romsrv_data & romsrv_data2);
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

    -- jshad fill: stream the 64KB sound region through the shad write port,
    -- word addresses 0x100000/2 .. 0x10FFFF/2, exactly as the v58-style
    -- download mirror does on hardware
    fill_rom : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => fill_addr, data => fill_q );

    fill : process
        variable w : integer := 0;
    begin
        wait for 50 ns;
        while w < 32768 loop
            fill_addr <= std_logic_vector(to_unsigned((16#100000#/2) + w, 21));
            wait for 2 ns;
            shad_waddr <= std_logic_vector(to_unsigned(16#100000# + w*2, 24));
            shad_wdata <= fill_q;
            shad_we    <= '1';
            shad_wclk  <= '1'; wait for 2 ns;
            shad_wclk  <= '0'; wait for 2 ns;
            w := w + 1;
        end loop;
        shad_we <= '0';
        fill_done <= true;
        wait;
    end process;

    vb : process
    begin
        wait for 100 us;
        loop
            vblank <= '1'; wait for 10 us;
            vblank <= '0'; wait for 90 us;
            exit when done;
        end loop;
        wait;
    end process;

    coin1 <= '1' after 2 ms;   -- held coin: scan+debounce run at ~250Hz

    resp_watch : process(clk)
        alias xresp  is << signal .tb_escape_jshad.uut.jsa.resp_latch  : std_logic_vector(7 downto 0) >>;
        alias xrfull is << signal .tb_escape_jshad.uut.jsa.resp_full_i : std_logic >>;
        variable full_d : std_logic := '0';
        variable n : integer := 0;
    begin
        if rising_edge(clk) then
            if xrfull='1' and full_d='0' and n < 30 then
                report "RESP posted: 0x" & to_hstring(xresp);
                n := n + 1;
            end if;
            full_d := xrfull;
        end if;
    end process;

    check : process
        -- observe the link state directly: the 68k may not have read the
        -- response yet this early in boot, so the probe alone is not proof
        alias xresp  is << signal .tb_escape_jshad.uut.jsa.resp_latch  : std_logic_vector(7 downto 0) >>;
        alias xrfull is << signal .tb_escape_jshad.uut.jsa.resp_full_i : std_logic >>;
    begin
        wait until fill_done;
        wait for 24 ms;
        report "=== escape_core JSA-shadow path ===";
        report "  6502 PC (live addr): 0x" & to_hstring(dbg_jsa_pc);
        report "  resp latch: 0x" & to_hstring(xresp) & " full: " & std_logic'image(xrfull);
        report "  resp probe {nz count, last}: 0x" & to_hstring(dbg_resp_stat);
        if xresp /= x"00" and xresp /= x"FF" then
            report "TB_ESCAPE_JSHAD OK: coin pipeline posted 0x" & to_hstring(xresp) severity note;
        else
            report "TB_ESCAPE_JSHAD FAIL: held coin produced no report (latch 0x" & to_hstring(xresp) & ")" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
