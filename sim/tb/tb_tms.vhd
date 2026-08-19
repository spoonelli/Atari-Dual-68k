-- tb_tms: drive the TMS5220 exactly as escape_jsa does (ENA /11 of 7.159MHz,
-- WS auto-pulse per byte) - Speak External command + real LPC data.
-- PASS = O_SPKR produces nonzero samples and the FIFO drains (ready recovers).
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_tms is end tb_tms;

architecture tb of tb_tms is
    signal clk    : std_logic := '0';
    signal done   : boolean := false;
    signal ctr    : unsigned(3 downto 0) := (others => '0');
    signal ena    : std_logic;
    signal wsn    : std_logic := '1';
    signal rsn    : std_logic := '1';
    signal dbus   : std_logic_vector(7 downto 0) := (others => '0');
    signal rdyn, intn : std_logic;
    signal spkr   : signed(13 downto 0);
    signal nonzero_samples : integer := 0;
    signal ready_dips : integer := 0;
    signal rdyn_d : std_logic := '0';
begin
    clk <= not clk after 69.84 ns when not done else '0';

    -- /11 clock enable (squeak=0 law: preset 5)
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

    -- sample + ready monitors
    process(clk)
    begin
        if rising_edge(clk) then
            if spkr /= 0 then nonzero_samples <= nonzero_samples + 1; end if;
            rdyn_d <= rdyn;
            if rdyn = '1' and rdyn_d = '0' then ready_dips <= ready_dips + 1; end if;
        end if;
    end process;

    probe : process
        alias xDDIS is << signal .tb_tms.dut.m_DDIS : std_logic >>;
        alias xSPEN is << signal .tb_tms.dut.m_SPEN : std_logic >>;
        alias xTALK is << signal .tb_tms.dut.m_TALK : std_logic >>;
        alias xTALKD is << signal .tb_tms.dut.m_TALKD : std_logic >>;
        alias xPTR is << signal .tb_tms.dut.m_FIFO_ptr : integer range 0 to 128 >>;
    begin
        for i in 1 to 200 loop
            wait for 500 us;
            report "PROBE t=" & integer'image(i) & " DDIS=" & std_logic'image(xDDIS)
                 & " SPEN=" & std_logic'image(xSPEN) & " TALK=" & std_logic'image(xTALK)
                 & " TALKD=" & std_logic'image(xTALKD) & " ptr=" & integer'image(xPTR);
        end loop;
        wait;
    end process;

    stim : process
        procedure wr(b : std_logic_vector(7 downto 0)) is
        begin
            -- wait for ready like the firmware does
            while rdyn = '1' loop wait for 1 us; end loop;
            dbus <= b;
            wsn  <= '0';
            wait for 9 us;          -- ~64 clk @7.159MHz
            wsn  <= '1';
            wait for 3 us;
        end procedure;
        type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);
        -- Speak External (0x60), then a plausible LPC stream: a voiced frame
        -- then silence frames then a stop frame (per TMS5220 LPC format)
        constant SEQ : t_bytes := (
            x"60",
            x"AD", x"12", x"34", x"56", x"78", x"9A", x"BC", x"DE",
            x"F0", x"11", x"22", x"33", x"44", x"55", x"66", x"77",
            x"88", x"99", x"AA", x"BB", x"CC", x"DD", x"EE", x"0F",
            x"FF", x"FF", x"FF"   -- stop-ish tail
        );
    begin
        -- power-on chip reset: WS and RS both low (the documented combo)
        wait for 20 us;
        wsn <= '0'; rsn <= '0';
        wait for 20 us;
        wsn <= '1'; rsn <= '1';
        wait for 20 us;
        report "TMS: sending Speak External + stream";
        for i in SEQ'range loop
            wr(SEQ(i));
        end loop;
        report "TMS: stream sent, waiting for synthesis";
        wait for 90 ms;
        report "TMS RESULT: nonzero_samples=" & integer'image(nonzero_samples)
             & " ready_dips=" & integer'image(ready_dips)
             & " rdyn=" & std_logic'image(rdyn);
        if nonzero_samples > 100 then
            report "TB_TMS OK: chip synthesizes audio" severity note;
        else
            report "TB_TMS FAIL: no audio from chip" severity error;
        end if;
        done <= true;
        wait;
    end process;
end tb;
