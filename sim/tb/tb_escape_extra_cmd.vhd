-- Extra CPU given its command: force the extra CPU released AND continuously
-- inject 0x1234 into shared-RAM mailbox 0x16FFE0 (word 0x7FF0) via the sim
-- backdoor, so the extra CPU's poll at 0x346 succeeds immediately regardless of
-- the (slow-booting) video CPU. Traces the extra CPU past its self-test to the
-- 0x4321 response write. This isolates the extra-CPU + shared-RAM + ROM path.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_escape_extra_cmd is end tb_escape_extra_cmd;

architecture tb of tb_escape_extra_cmd is
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
        port map ( clk=>clk, reset_n=>resetn,
                   rom_addr=>rom_addr, rom_data=>rom_data, rom_par=>rom_par, rom_req=>rom_req, rom_ack=>rom_ack,
                   vblank_in=>vblank,
                   p1_buttons=>"0000", p2_buttons=>"0000",
                   alpha_vaddr=>alpha_vaddr, alpha_vdata=>alpha_vdata,
                   dbg_force_extra=>'1',
                   dbg_shr_we=>'1', dbg_shr_addr=>"111111111110000",   -- 0x7FF0 = 0x16FFE0/2
                   dbg_shr_din=>x"1234",
                   dbg_v_pc_fetch=>dbg_v, dbg_e_running=>dbg_e );

    romsrv : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr(21 downto 1), data => romsrv_data );
    romsrv2 : entity work.rom_words
        generic map ( hexfile => "sim/work/combined_words.hex", awidth => 21 )
        port map ( addr => rom_addr2w, data => romsrv_data2 );

    serve : process(clk)
        variable lat : integer := 0; variable served : boolean := false;
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
            else rom_ack <= '0'; served := false; lat := 0; end if;
        end if;
    end process;

    -- trace extra CPU: PC-ish (opcode fetches), shared-RAM writes to 0x16FFEx
    trace : process(clk)
        alias xe_addr is << signal .tb_escape_extra_cmd.uut.e_addr : std_logic_vector(31 downto 0) >>;
        alias xe_as_n is << signal .tb_escape_extra_cmd.uut.e_as_n : std_logic >>;
        alias xe_rw_n is << signal .tb_escape_extra_cmd.uut.e_rw_n : std_logic >>;
        alias xe_do   is << signal .tb_escape_extra_cmd.uut.e_do   : std_logic_vector(15 downto 0) >>;
        alias xe_fc   is << signal .tb_escape_extra_cmd.uut.e_fc   : std_logic_vector(2 downto 0) >>;
        variable in_cyc : boolean := false;
        variable maxpc  : unsigned(23 downto 0) := (others=>'0');
        variable nwr : integer := 0;
    begin
        if rising_edge(clk) then
            if xe_as_n='0' and not in_cyc then
                -- log every shared-RAM write in the mailbox region
                if xe_rw_n='0' and xe_addr(23 downto 4)=x"16FFE" then
                    report "E W " & to_hstring(xe_addr(23 downto 0)) & " <= " & to_hstring(xe_do);
                    nwr := nwr + 1;
                end if;
                -- track furthest instruction fetch (FC=110 program) as rough PC high-water
                if xe_fc="110" and xe_rw_n='1' and unsigned(xe_addr(23 downto 0)) < x"080000" then
                    if unsigned(xe_addr(23 downto 0)) > maxpc then
                        maxpc := unsigned(xe_addr(23 downto 0));
                    end if;
                end if;
                in_cyc := true;
            end if;
            if xe_as_n='1' then in_cyc := false; end if;
            if done then report "extra PC high-water: 0x" & to_hstring(std_logic_vector(maxpc))
                                 & "  mailbox writes: " & integer'image(nwr); end if;
        end if;
    end process;

    check : process
        alias xe_addr is << signal .tb_escape_extra_cmd.uut.e_addr : std_logic_vector(31 downto 0) >>;
        alias xe_as_n is << signal .tb_escape_extra_cmd.uut.e_as_n : std_logic >>;
        alias xe_rw_n is << signal .tb_escape_extra_cmd.uut.e_rw_n : std_logic >>;
        alias xe_do   is << signal .tb_escape_extra_cmd.uut.e_do   : std_logic_vector(15 downto 0) >>;
        variable resp4321 : boolean := false;
        variable in_cyc : boolean := false;
    begin
        for i in 1 to 300000 loop     -- 3 ms
            wait until rising_edge(clk);
            if xe_as_n='0' and not in_cyc then
                if xe_rw_n='0' and xe_addr(23 downto 0)=x"16FFE2" and xe_do=x"4321" then
                    resp4321 := true;
                end if;
                in_cyc := true;
            end if;
            if xe_as_n='1' then in_cyc := false; end if;
        end loop;
        report "=== extra-cmd check ===";
        report "  extra wrote 0x4321 -> 0x16FFE2 (self-test passed & responded): " & boolean'image(resp4321);
        if resp4321 then
            report "EXTRA-CMD OK: extra CPU completes self-test and answers the mailbox" severity note;
        else
            report "EXTRA-CMD FAIL: extra CPU never wrote the 0x4321 response" severity failure;
        end if;
        done <= true;
        wait for 1 us;
        wait;
    end process;
end tb;
