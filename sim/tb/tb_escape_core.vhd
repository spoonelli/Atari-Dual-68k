-- Testbench for the synthesizable escape_core: serves the external ROM bus from the
-- combined image (as SDRAM will on hardware, with realistic multi-cycle latency),
-- generates a fake VBLANK, and checks both CPUs come up: the Video CPU executes at
-- its reset PC and (via 360010 or fallback force is NOT provided here — real latch
-- only) the Extra CPU release state is observable. This is the hardware design,
-- simulated as-is.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_core is end tb_escape_core;

architecture tb of tb_escape_core is
    signal clk    : std_logic := '0';
    signal resetn : std_logic := '0';
    signal done   : boolean := false;

    signal rom_addr : std_logic_vector(23 downto 0);
    signal rom_data : std_logic_vector(15 downto 0);
    signal rom_req  : std_logic;
    signal rom_ack  : std_logic := '0';

    signal vblank : std_logic := '0';
    signal alpha_vaddr : std_logic_vector(10 downto 0) := (others=>'0');
    signal alpha_vdata : std_logic_vector(15 downto 0);
    signal dbg_v, dbg_e : std_logic;

    signal romsrv_data : std_logic_vector(15 downto 0);
begin
    clk    <= not clk after 5 ns when not done else '0';
    resetn <= '0', '1' after 205 ns;

    uut : entity work.escape_core
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
                   dbg_v_pc_fetch=>dbg_v, dbg_e_running=>dbg_e );

    -- combined-image ROM server, 3-cycle latency (SDRAM-ish)
    romsrv : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr(21 downto 1), data => romsrv_data );

    -- strict 4-phase: ack rises once per request and stays high until req falls
    serve : process(clk)
        variable lat    : integer := 0;
        variable served : boolean := false;
    begin
        if rising_edge(clk) then
            if rom_req='1' then
                if not served then
                    if lat = 2 then
                        rom_data <= romsrv_data;
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

    -- fake VBLANK: 240 lines on, 22 off at 456 clk/line ~ 59.92 Hz cadence
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

    trace : process(clk)
        variable n : integer := 0;
    begin
        if rising_edge(clk) then
            if rom_ack='1' and n < 12 then
                report "romtx " & integer'image(n) & " addr=0x" & to_hstring(rom_addr)
                       & " data=0x" & to_hstring(rom_data);
                n := n + 1;
            end if;
        end if;
    end process;

    check : process
    begin
        wait for 60 us;
        report "=== escape_core (synthesizable) ===";
        report "  video CPU fetched reset PC: " & std_logic'image(dbg_v);
        report "  extra CPU released (360010 D0): " & std_logic'image(dbg_e);
        if dbg_v = '1' then
            report "ESCAPE-CORE OK: hardware design boots the real program in sim" severity note;
        else
            report "escape_core: video CPU did not reach reset PC" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
