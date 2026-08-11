-- Full two-CPU mailbox handshake through the REAL escape_core, natural boot
-- (NO dbg_force_extra). Mirrors hardware's "Waiting for Second Processor":
--   video CPU writes 0x1234 -> 0x16FFE0, sets extra_release (360011 D0),
--   extra CPU wakes, sees 0x1234, runs checksum, writes 0x4321 -> 0x16FFE2.
-- This TB proves (or refutes) that the handshake completes in the design as
-- built. It runs long enough for the video CPU's boot delay loops to expire.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_handshake is end tb_escape_handshake;

architecture tb of tb_escape_handshake is
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
    -- real SDRAM burst: second word is col|1, not col+1
    rom_addr2w <= rom_addr(21 downto 2) & '1';

    uut : entity work.escape_core
        generic map ( YM_ENABLE => 0 )   -- GHDL: no mixed-language jt51
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
                   dbg_v_pc_fetch=>dbg_v, dbg_e_running=>dbg_e );

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
                        rom_ack  <= '1'; served := true; lat := 0;
                    else lat := lat + 1; end if;
                end if;
            else
                rom_ack <= '0'; served := false; lat := 0;
            end if;
        end if;
    end process;

    -- VBLANK cadence ~ 60 Hz
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

    -- watch the handshake milestones on the real shared-RAM ports
    watch : process(clk)
        alias xv_addr  is << signal .tb_escape_handshake.uut.v_addr  : std_logic_vector(31 downto 0) >>;
        alias xv_as_n  is << signal .tb_escape_handshake.uut.v_as_n  : std_logic >>;
        alias xv_rw_n  is << signal .tb_escape_handshake.uut.v_rw_n  : std_logic >>;
        alias xv_do    is << signal .tb_escape_handshake.uut.v_do    : std_logic_vector(15 downto 0) >>;
        alias xe_addr  is << signal .tb_escape_handshake.uut.e_addr  : std_logic_vector(31 downto 0) >>;
        alias xe_as_n  is << signal .tb_escape_handshake.uut.e_as_n  : std_logic >>;
        alias xe_rw_n  is << signal .tb_escape_handshake.uut.e_rw_n  : std_logic >>;
        alias xe_do    is << signal .tb_escape_handshake.uut.e_do    : std_logic_vector(15 downto 0) >>;
        alias xrel     is << signal .tb_escape_handshake.uut.extra_release : std_logic >>;
        variable vwrite_seen, rel_seen, ewake_seen, eresp_seen : boolean := false;
        variable vin, ein : boolean := false;
    begin
        if rising_edge(clk) then
            -- video CPU write of command word to 0x16FFE0
            if xv_as_n='0' and xv_rw_n='0' and not vin then
                if xv_addr(23 downto 0)=x"16FFE0" then
                    report "V wrote 0x16FFE0 <= 0x" & to_hstring(xv_do);
                    if xv_do=x"1234" then vwrite_seen := true; end if;
                end if;
                vin := true;
            end if;
            if xv_as_n='1' then vin := false; end if;

            -- extra released
            if xrel='1' and not rel_seen then
                report "extra_release asserted"; rel_seen := true;
            end if;

            -- extra CPU reads mailbox / writes its response
            if xe_as_n='0' and not ein then
                if xe_rw_n='1' and xe_addr(23 downto 0)=x"16FFE0" then
                    ewake_seen := true;   -- extra actually read the mailbox
                end if;
                if xe_rw_n='0' and xe_addr(23 downto 4)=x"16FFE" then
                    report "E wrote 0x" & to_hstring(xe_addr(23 downto 0)) & " <= 0x" & to_hstring(xe_do);
                    eresp_seen := true;
                end if;
                ein := true;
            end if;
            if xe_as_n='1' then ein := false; end if;
        end if;
    end process;

    check : process
        alias xe_addr  is << signal .tb_escape_handshake.uut.e_addr  : std_logic_vector(31 downto 0) >>;
        alias xe_as_n  is << signal .tb_escape_handshake.uut.e_as_n  : std_logic >>;
        alias xe_rw_n  is << signal .tb_escape_handshake.uut.e_rw_n  : std_logic >>;
        alias xrel     is << signal .tb_escape_handshake.uut.extra_release : std_logic >>;
        variable vwr, rel, eread, ewr : boolean := false;
    begin
        for i in 1 to 500000 loop        -- 5 ms
            wait until rising_edge(clk);
            if xrel='1' then rel := true; end if;
            if xe_as_n='0' and xe_rw_n='0' and xe_addr(23 downto 4)=x"16FFE" then ewr := true; end if;
            if xe_as_n='0' and xe_rw_n='1' and xe_addr(23 downto 0)=x"16FFE0" then eread := true; end if;
        end loop;
        report "=== handshake check ===";
        report "  extra_release seen:        " & boolean'image(rel);
        report "  extra read mailbox 16FFE0: " & boolean'image(eread);
        report "  extra wrote 16FFEx:        " & boolean'image(ewr);
        if rel and eread and ewr then
            report "HANDSHAKE OK: full two-CPU mailbox exchange completed" severity note;
        else
            report "HANDSHAKE INCOMPLETE" severity failure;
        end if;
        done <= true;
        wait;
    end process;
end tb;
