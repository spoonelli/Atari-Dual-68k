-- Atari JSA-I sound board (Escape variant: YM2151 + TMS5220 stub, no POKEY).
-- Re-implemented from the behavior documented in reference/atarijsa.cpp (MAME,
-- BSD-3-Clause) — no code copied. Full spec: docs/JSA.md.
--
-- 6502 (T65, from the System 1 tree) at 1.789773 MHz via clock-enable on the
-- shared 7.159091 MHz clock; YM2151 = jt51 (Verilog, bound by Quartus; GHDL sim
-- sets YM_ENABLE=false for a silence stub). Program ROM is the same external
-- request/ack bus escape_core uses, addressed into the combined image's
-- 0x100000 JSA window; the CPU clock-enable is gated while a fetch is pending,
-- with a word+prefetch cache so the even/odd byte pair costs one transaction.
--
-- 68k link is latch-level: core_top decodes 360031 (command write), 260031
-- (response read), 360020 (sound reset) and drives the pulses; cmd_full /
-- resp_full feed the 260010 D3/D2 status bits and snd_irq is the /SINT source.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity escape_jsa is
    generic (
        -- false = GHDL sim: skip the Verilog jt51, stub silence (docs/JSA.md)
        YM_ENABLE : boolean := true
    );
    port (
        clk       : in  std_logic;                      -- 7.159091 MHz
        reset_n   : in  std_logic;
        snd_res   : in  std_logic := '0';               -- pulse: 68k write 360020

        -- external program ROM bus (combined-image byte offsets; escape_core protocol)
        rom_addr  : out std_logic_vector(23 downto 0);
        rom_data  : in  std_logic_vector(31 downto 0);  -- [31:16]=addr, [15:0]=addr|1 word
        rom_req   : out std_logic;
        rom_ack   : in  std_logic;

        -- 68k command/response link (latch level)
        cmd_data  : in  std_logic_vector(7 downto 0) := (others => '0');
        cmd_we    : in  std_logic := '0';               -- pulse: 68k write 360031
        resp_data : out std_logic_vector(7 downto 0);
        resp_rd   : in  std_logic := '0';               -- pulse: 68k read 260031
        cmd_full  : out std_logic;                      -- 260010 D3 = NOT cmd_full
        resp_full : out std_logic;                      -- 260010 D2 = NOT resp_full
        snd_irq   : out std_logic;                      -- /SINT source (68k IRQ6 level)

        -- inputs (active-high pressed; coin1 = Pocket Select at integration)
        coin1     : in  std_logic := '0';
        coin2     : in  std_logic := '0';
        test_mode : in  std_logic := '0';

        -- audio out, signed
        audio_l   : out std_logic_vector(15 downto 0);
        audio_r   : out std_logic_vector(15 downto 0);

        -- observation
        dbg_cpu_addr : out std_logic_vector(15 downto 0);
        dbg_cpu_sync : out std_logic
    );
end escape_jsa;

architecture rtl of escape_jsa is
    -- jt51 (third_party/jt51/hdl/jt51.v); bound by Quartus, skipped in GHDL sim
    component jt51
        port (
            rst    : in  std_logic;
            clk    : in  std_logic;
            cen    : in  std_logic;      -- 3.58 MHz enable
            cen_p1 : in  std_logic;      -- 1.79 MHz enable
            cs_n   : in  std_logic;
            wr_n   : in  std_logic;
            a0     : in  std_logic;
            din    : in  std_logic_vector(7 downto 0);
            dout   : out std_logic_vector(7 downto 0);
            ct1    : out std_logic;
            ct2    : out std_logic;
            irq_n  : out std_logic;
            sample : out std_logic;
            left   : out std_logic_vector(15 downto 0);
            right  : out std_logic_vector(15 downto 0);
            xleft  : out std_logic_vector(15 downto 0);
            xright : out std_logic_vector(15 downto 0)
        );
    end component;

    -- clock enables
    signal enacnt   : unsigned(1 downto 0) := "00";
    signal cen_ym   : std_logic;                      -- clk/2 = 3.579545 MHz
    signal cen_ymp1 : std_logic;                      -- clk/4 = 1.789773 MHz
    signal cen_cpu  : std_logic;                      -- clk/4, CPU phase
    signal cpu_ena  : std_logic;                      -- cen_cpu gated by ROM stall

    -- 6502
    signal cpu_res_n  : std_logic;
    signal sres_cnt   : unsigned(3 downto 0) := (others => '0');
    signal cpu_a      : std_logic_vector(23 downto 0);
    signal cpu_di     : std_logic_vector(7 downto 0);
    signal cpu_do     : std_logic_vector(7 downto 0);
    signal cpu_rw_n   : std_logic;
    signal cpu_sync   : std_logic;
    signal cpu_irq_n  : std_logic;
    signal cpu_nmi_n  : std_logic;
    signal a16        : std_logic_vector(15 downto 0);

    -- decode
    signal sel_ram, sel_ym, sel_r28, sel_w2a, sel_pokey, sel_rom : std_logic;

    -- 8 KB program RAM (0000-1FFF)
    type ram_t is array (0 to 8191) of std_logic_vector(7 downto 0);
    signal ram   : ram_t;
    signal ram_q : std_logic_vector(7 downto 0);

    -- 68k link latches
    signal cmd_latch, resp_latch : std_logic_vector(7 downto 0) := (others => '0');
    signal cmd_full_i, resp_full_i : std_logic := '0';

    -- control registers
    signal bank      : std_logic_vector(1 downto 0) := "00";   -- WRIO D7:6
    signal wrio_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal mix_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal timed_int : std_logic := '0';
    signal irqctr    : unsigned(12 downto 0) := (others => '0'); -- /7168 @1.79MHz

    -- TMS5220 stub latches (wiring point; see docs/JSA.md)
    signal tms_data : std_logic_vector(7 downto 0) := (others => '0');
    signal tms_ws_n, tms_rs_n, tms_squeak : std_logic := '1';

    -- YM2151
    signal ym_rst    : std_logic;
    signal ym_dout   : std_logic_vector(7 downto 0);
    signal ym_irq_n  : std_logic;
    signal ym_ct1    : std_logic;
    signal ym_ct2    : std_logic;
    signal ym_xl, ym_xr : std_logic_vector(15 downto 0);
    signal ym_cs_n   : std_logic;

    -- ROM fetch (banked 16-bit offset into the 64KB region)
    signal rom_off     : std_logic_vector(15 downto 0);
    type rf_t is (RF_IDLE, RF_REQ, RF_DONE);
    signal rf          : rf_t := RF_IDLE;
    signal rom_req_i   : std_logic := '0';
    signal cache_word  : std_logic_vector(15 downto 0);
    signal cache_addr  : std_logic_vector(14 downto 0);   -- word index (off 15:1)
    signal cache_v     : std_logic := '0';
    signal pref_word   : std_logic_vector(15 downto 0);
    signal pref_addr   : std_logic_vector(14 downto 0);
    signal pref_v      : std_logic := '0';
    signal rom_hit     : std_logic;
    signal rom_stall   : std_logic;
    signal rom_byte    : std_logic_vector(7 downto 0);

    -- rdio port
    signal rdio : std_logic_vector(7 downto 0);

    -- mixer: YM gain = round(0.60*256*v/7), v = mix_reg(3:1)
    type gain_t is array (0 to 7) of unsigned(7 downto 0);
    constant YM_GAIN : gain_t := (to_unsigned(0,8),   to_unsigned(22,8),
                                  to_unsigned(44,8),  to_unsigned(66,8),
                                  to_unsigned(88,8),  to_unsigned(110,8),
                                  to_unsigned(132,8), to_unsigned(154,8));
begin
    ---------------------------------------------------------------- clock enables
    process(clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                enacnt <= "00";
            else
                enacnt <= enacnt + 1;
            end if;
        end if;
    end process;
    cen_ym   <= '1' when enacnt(0) = '1'  else '0';
    cen_ymp1 <= '1' when enacnt   = "11"  else '0';
    cen_cpu  <= '1' when enacnt   = "01"  else '0';
    cpu_ena  <= cen_cpu and not rom_stall;

    ---------------------------------------------------------------- 6502 + reset
    -- snd_res (68k 360020) pulses a short internal reset, MAME sound_reset_w
    process(clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                sres_cnt <= (others => '1');
            elsif snd_res = '1' then
                sres_cnt <= (others => '1');
            elsif sres_cnt /= 0 then
                sres_cnt <= sres_cnt - 1;
            end if;
        end if;
    end process;
    cpu_res_n <= '0' when sres_cnt /= 0 else '1';

    cpu : entity work.T65
        port map (
            Mode    => "00",
            Res_n   => cpu_res_n,
            Clk     => clk,
            Enable  => cpu_ena,
            Rdy     => '1',
            Abort_n => '1',
            IRQ_n   => cpu_irq_n,
            NMI_n   => cpu_nmi_n,
            SO_n    => '1',
            A       => cpu_a,
            DI      => cpu_di,
            DO      => cpu_do,
            R_W_n   => cpu_rw_n,
            Sync    => cpu_sync );

    a16 <= cpu_a(15 downto 0);
    dbg_cpu_addr <= a16;
    dbg_cpu_sync <= cpu_sync;

    ---------------------------------------------------------------- decode
    -- 0x2800/0x2A00 regions decode A15-A9 and A2-A1 only (mirror mask 0x01F9)
    sel_ram   <= '1' when a16(15 downto 13) = "000"     else '0';  -- 0000-1FFF
    sel_ym    <= '1' when a16(15 downto 11) = "00100"   else '0';  -- 2000-27FF
    sel_r28   <= '1' when a16(15 downto 9)  = "0010100" else '0';  -- 2800-29FF
    sel_w2a   <= '1' when a16(15 downto 9)  = "0010101" else '0';  -- 2A00-2BFF
    sel_pokey <= '1' when a16(15 downto 10) = "001011"  else '0';  -- 2C00-2FFF
    sel_rom   <= '1' when a16(15 downto 14) /= "00"
                       or a16(15 downto 12) = "0011"    else '0';  -- 3000-FFFF

    ---------------------------------------------------------------- program RAM
    process(clk)
    begin
        if rising_edge(clk) then
            if cpu_ena = '1' and cpu_rw_n = '0' and sel_ram = '1' then
                ram(to_integer(unsigned(a16(12 downto 0)))) <= cpu_do;
            end if;
            ram_q <= ram(to_integer(unsigned(a16(12 downto 0))));
        end if;
    end process;

    ---------------------------------------------------------------- ROM fetch
    -- banked window 3000-3FFF -> bank*0x1000; static 4000-FFFF -> identity
    rom_off <= "00" & bank & a16(11 downto 0) when a16(15 downto 12) = "0011"
               else a16;

    rom_hit <= '1' when (cache_v = '1' and rom_off(15 downto 1) = cache_addr)
                     or (pref_v  = '1' and rom_off(15 downto 1) = pref_addr)
               else '0';
    rom_stall <= '1' when sel_rom = '1' and cpu_rw_n = '1' and rom_hit = '0'
                 else '0';

    rom_byte <= cache_word(15 downto 8) when rom_off(15 downto 1) = cache_addr
                                             and rom_off(0) = '0' else
                cache_word(7 downto 0)  when rom_off(15 downto 1) = cache_addr else
                pref_word(15 downto 8)  when rom_off(0) = '0' else
                pref_word(7 downto 0);

    fetch : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                rf <= RF_IDLE; rom_req_i <= '0';
                cache_v <= '0'; pref_v <= '0';
            else
                case rf is
                    when RF_IDLE =>
                        if rom_stall = '1' and rom_ack = '0' then
                            rom_addr  <= x"10" & rom_off(15 downto 1) & '0';
                            rom_req_i <= '1';
                            rf <= RF_REQ;
                        end if;
                    when RF_REQ =>
                        if rom_ack = '1' then
                            rom_req_i  <= '0';
                            cache_word <= rom_data(31 downto 16);
                            cache_addr <= rom_off(15 downto 1);
                            cache_v    <= '1';
                            -- second burst word is addr|1: only a +2 prefetch
                            -- when the fetched word index is even (escape_core rule)
                            pref_word  <= rom_data(15 downto 0);
                            pref_addr  <= std_logic_vector(
                                unsigned(rom_off(15 downto 1)) + 1);
                            pref_v     <= not rom_off(1);
                            rf <= RF_DONE;
                        end if;
                    when RF_DONE =>                    -- wait out ack (4-phase)
                        if rom_ack = '0' then
                            rf <= RF_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;
    rom_req <= rom_req_i;

    ---------------------------------------------------------------- 68k link + regs
    regs : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' or sres_cnt /= 0 then
                cmd_full_i <= '0'; resp_full_i <= '0';
                timed_int <= '0'; irqctr <= (others => '0');
                bank <= "00"; wrio_reg <= (others => '0'); mix_reg <= (others => '0');
                tms_data <= (others => '0');
                tms_ws_n <= '1'; tms_rs_n <= '1'; tms_squeak <= '0';
                if reset_n = '0' then
                    cmd_latch <= (others => '0'); resp_latch <= (others => '0');
                end if;
            else
                -- timed interrupt: /7168 of the 1.79 MHz enable = 249.69 Hz
                if cen_cpu = '1' then
                    if irqctr = 7167 then
                        irqctr <= (others => '0');
                        timed_int <= '1';
                    else
                        irqctr <= irqctr + 1;
                    end if;
                end if;

                -- 6502 accesses (one per enabled tick)
                if cpu_ena = '1' then
                    -- /IRQACK 2806: read or write clears the timed interrupt
                    if sel_r28 = '1' and a16(2 downto 1) = "11" then
                        timed_int <= '0';
                    end if;
                    -- /RDP 2802 read: consume command, release NMI
                    if sel_r28 = '1' and a16(2 downto 1) = "01" and cpu_rw_n = '1' then
                        cmd_full_i <= '0';
                    end if;
                    if cpu_rw_n = '0' and sel_w2a = '1' then
                        case a16(2 downto 1) is
                            when "00" =>                            -- /VOICE
                                tms_data <= cpu_do;
                            when "01" =>                            -- /WRP response
                                resp_latch  <= cpu_do;
                                resp_full_i <= '1';
                            when "10" =>                            -- /WRIO
                                wrio_reg  <= cpu_do;
                                bank      <= cpu_do(7 downto 6);
                                tms_squeak<= cpu_do(3);
                                tms_rs_n  <= cpu_do(2);
                                tms_ws_n  <= cpu_do(1);
                            when others =>                          -- /MIX
                                mix_reg <= cpu_do;
                        end case;
                    end if;
                end if;

                -- 68k side (pulses from core_top decode); set wins over same-clk clear
                if resp_rd = '1' then
                    resp_full_i <= '0';
                end if;
                if cmd_we = '1' then
                    cmd_latch  <= cmd_data;
                    cmd_full_i <= '1';
                end if;
            end if;
        end if;
    end process;

    cmd_full  <= cmd_full_i;
    resp_full <= resp_full_i;
    resp_data <= resp_latch;
    snd_irq   <= resp_full_i;                       -- /SINT: level until 260031 read
    cpu_nmi_n <= not cmd_full_i;                    -- edge-detected inside T65
    cpu_irq_n <= ym_irq_n and not timed_int;

    ---------------------------------------------------------------- rdio 2804
    rdio <= test_mode                -- D7 self-test (MAME nets 0 in normal play)
            & (not cmd_full_i)       -- D6 /input-buffer-full (0 = command pending)
            & resp_full_i            -- D5 output-buffer-full (active high)
            & '1'                    -- D4 TMS5220 ready (stub: always ready)
            & "11"                   -- D3:2 +5V
            & coin2 & coin1;         -- D1:0 coins, 1 = pressed

    ---------------------------------------------------------------- YM2151 (jt51)
    ym_cs_n <= not sel_ym;
    ym_rst  <= (not reset_n) or (not cpu_res_n) or (not wrio_reg(0)); -- WRIO D0 active low

    ym_real : if YM_ENABLE generate
        ym : jt51
            port map (
                rst    => ym_rst,
                clk    => clk,
                cen    => cen_ym,
                cen_p1 => cen_ymp1,
                cs_n   => ym_cs_n,
                wr_n   => cpu_rw_n,
                a0     => a16(0),
                din    => cpu_do,
                dout   => ym_dout,
                ct1    => ym_ct1,
                ct2    => ym_ct2,
                irq_n  => ym_irq_n,
                sample => open,
                left   => open,
                right  => open,
                xleft  => ym_xl,
                xright => ym_xr );
    end generate;

    ym_stub : if not YM_ENABLE generate           -- GHDL sim: silence, never busy
        ym_dout  <= (others => '0');
        ym_irq_n <= '1';
        ym_ct1   <= '1';
        ym_ct2   <= '0';
        ym_xl    <= (others => '0');
        ym_xr    <= (others => '0');
    end generate;

    ---------------------------------------------------------------- CPU read mux
    cpu_di <= ram_q      when sel_ram = '1' else
              ym_dout    when sel_ym  = '1' else
              cmd_latch  when sel_r28 = '1' and a16(2 downto 1) = "01" else
              rdio       when sel_r28 = '1' and a16(2 downto 1) = "10" else
              x"00"      when sel_r28 = '1' and a16(2 downto 1) = "11" else
              x"FF"      when sel_r28 = '1' else
              x"FF"      when sel_pokey = '1' else   -- POKEY absent on Escape
              rom_byte   when sel_rom = '1' else
              x"FF";

    ---------------------------------------------------------------- mixer
    -- YM xleft/xright * (0.60 * mixvol/7) in Q8; TMS stub contributes silence.
    -- |coef| <= 154/256 < 1 so the scaled product needs no saturation.
    mixer : process(clk)
        variable coef : unsigned(7 downto 0);
        variable pl, pr : signed(24 downto 0);
    begin
        if rising_edge(clk) then
            coef := YM_GAIN(to_integer(unsigned(mix_reg(3 downto 1))));
            pl := signed(ym_xl) * signed('0' & coef);
            pr := signed(ym_xr) * signed('0' & coef);
            audio_l <= std_logic_vector(pl(23 downto 8));
            audio_r <= std_logic_vector(pr(23 downto 8));
        end if;
    end process;
end rtl;
