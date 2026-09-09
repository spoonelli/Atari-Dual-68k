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
        -- false = GHDL sim: skip the Verilog jt51 (and jt6295), stub silence (docs/JSA.md)
        YM_ENABLE : boolean := true;
        -- JSA2-164: 1 = JSA-I (YM2151 + TMS5220; Escape), 2 = JSA-II (YM2151 +
        -- OKI6295; Klax prototypes, Guts n' Glory). The 6502 map is the same
        -- except 2800 reads / 2A00 writes go to the OKI instead of N/C / the
        -- TMS, POKEY space is not decoded, and WRIO D3:2 / MIX D0 / RDIO D4
        -- change meaning. docs/investigations/KLAX_GUTS.md section 2.
        BOARD : integer := 1
    );
    port (
        clk       : in  std_logic;                      -- 7.159091 MHz
        reset_n   : in  std_logic;
        pause      : in  std_logic := '0';   -- MISTER-155: freezes the whole board
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
        -- v71: restrict the timed-IRQ ack to the exact 2806 address instead
        -- of every a(2:1)="11" alias across 2800-29FF - if main-loop code
        -- touches an alias, the coin-scan IRQ is swallowed before it is taken
        irq_strict : in std_logic := '0';
        -- LANE4k user audio mixer: 0 = mute, 7 = unity (x(n+1)/8)
        uvol_ym    : in  std_logic_vector(2 downto 0) := "111";
        uvol_tms   : in  std_logic_vector(2 downto 0) := "111";
        -- MIX-100 per-channel FM mixer: 8 x 3-bit gains, channel 0 in the low
        -- bits. 7 = unity (the authentic default), 0 = mute. Control surface
        -- only - the shipped defaults leave the mix exactly as the board mixed
        -- it; nothing is rebalanced.
        uvol_fm    : in  std_logic_vector(23 downto 0) := (others => '1');

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
    -- jt6295 (third_party/jt6295/hdl/jt6295.v); bound by Quartus, stubbed in GHDL
    component jt6295
        port (
            rst      : in  std_logic;
            clk      : in  std_logic;
            cen      : in  std_logic;      -- 1.193 MHz enable (JSA_MASTER_CLOCK/3)
            ss       : in  std_logic;      -- pin 7: 1 = /132, 0 = /165
            wrn      : in  std_logic;
            din      : in  std_logic_vector(7 downto 0);
            dout     : out std_logic_vector(7 downto 0);
            rom_addr : out std_logic_vector(17 downto 0);
            rom_data : in  std_logic_vector(7 downto 0);
            rom_ok   : in  std_logic;
            sound    : out std_logic_vector(13 downto 0);
            sample   : out std_logic
        );
    end component;

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
            xright : out std_logic_vector(15 downto 0);
            ch_gain: in  std_logic_vector(23 downto 0)
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
    -- SCHEM-95: serial-link transit model (8 bits + framing at 894.9kHz
    -- ~= 11us; this core's clk is 7.159MHz => ~80 clocks)
    constant SCOM_XFER : unsigned(6 downto 0) := to_unsigned(80, 7);
    signal   scom_ctr  : unsigned(6 downto 0) := (others => '0');
    signal   cmd_pend  : std_logic := '0';

    -- control registers
    signal bank      : std_logic_vector(1 downto 0) := "00";   -- WRIO D7:6
    type t_tmsgain is array (0 to 3) of unsigned(7 downto 0);
    constant TMS_GAIN : t_tmsgain := (x"00", x"55", x"AA", x"FF");
    signal wrio_reg  : std_logic_vector(7 downto 0) := (others => '0');
    signal mix_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal timed_int : std_logic := '0';
    signal irqctr    : unsigned(12 downto 0) := (others => '0'); -- /7168 @1.79MHz

    -- TMS5220 (LANE3u: the real chip - d18c7db's MAME-faithful core from
    -- the System 1 tree; Speak External mode is exactly what JSA firmware
    -- uses). Strobes/data ride the same LS273 latch bits as before.
    signal tms_data : std_logic_vector(7 downto 0) := (others => '0');
    -- LANE3x: LS273s clear at POR on the real board - strobes power up
    -- ASSERTED (both low = TMS reset held) until the firmware's first WRIO
    -- write releases them. This is the authentic chip-reset mechanism; the
    -- timed combo below remains as belt-and-suspenders.
    signal tms_ws_n, tms_rs_n : std_logic := '0';
    signal tms_squeak : std_logic := '0';
    signal tms_ctr   : unsigned(3 downto 0) := (others => '0');
    -- LANE4b: NO auto-WS logic. MAME 6502-bus trace (mix_trace.lua) proved
    -- the firmware strobes WS through the WRIO latch on EVERY byte
    -- (2A04=07 -> 2A00=data -> 2A04=05), exactly the real board's LS273
    -- wiring and the donor CART.vhd hookup. The '48 auto-pulse (added on a
    -- misdiagnosis; '47's real bug was power-on FIFO state, fixed in '49)
    -- made TWO WS edges per byte = every byte delivered twice = the buzz.
    -- LANE3w: power-on/sound-reset chip reset - the core's FIFO reads FULL
    -- until the WS+RS combo initializes it (bench-proven: without it the
    -- first command wedges ready busy forever = the frozen mission text).
    signal tms_rst_cnt  : unsigned(9 downto 0) := (others => '1');
    signal tms_rst_idle : std_logic := '0';
    signal tms_en    : std_logic;
    signal tms_rdy_n : std_logic := '1';
    signal tms_int_n : std_logic;
    signal tms_do    : std_logic_vector(7 downto 0);
    signal tms_spkr  : signed(13 downto 0) := (others => '0');

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
    signal rdio_d4 : std_logic;

    -- JSA2-164: OKI6295 (jt6295). ADPCM ROM = combined-image slot 0x240000-
    -- 0x27FFFF (256 KB aligned so the 18-bit chip address drops straight
    -- in). The chip's byte reads are served through this board's existing
    -- ROM request port as a second client behind the 6502, one 4-byte
    -- group cached (the req/ack burst returns the word pair at addr and
    -- addr|2).
    signal oki_rst, oki_ss, oki_wrn : std_logic := '1';
    signal oki_din, oki_dout : std_logic_vector(7 downto 0) := (others => '0');
    signal oki_addr  : std_logic_vector(17 downto 0) := (others => '0');
    signal oki_rdata : std_logic_vector(7 downto 0);
    signal oki_ok    : std_logic;
    signal oki_snd   : std_logic_vector(13 downto 0) := (others => '0');
    signal oki_cen   : std_logic := '0';
    signal oki_cctr  : unsigned(2 downto 0) := (others => '0');
    signal oki_wrctr : unsigned(3 downto 0) := (others => '0');
    signal oki_cache : std_logic_vector(31 downto 0) := (others => '0');
    signal oki_tag   : std_logic_vector(15 downto 0) := (others => '0');
    signal oki_cv    : std_logic := '0';
    signal oki_miss  : std_logic;
    signal rf_oki    : std_logic := '0';   -- the in-flight request belongs to the OKI

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
    -- MISTER-155 pause: gating the enable ladder freezes the 6502, YM2151
    -- and TMS5220 coherently mid-cycle; resume is a plain re-enable.
    cen_ym   <= '1' when enacnt(0) = '1' and pause = '0' else '0';
    cen_ymp1 <= '1' when enacnt   = "11" and pause = '0' else '0';
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

    -- JSA2-164: the OKI's 4-byte group is a miss when its tag differs
    oki_ok   <= '1' when BOARD = 2 and oki_cv = '1' and oki_tag = oki_addr(17 downto 2) else '0';
    oki_miss <= '1' when BOARD = 2 and oki_rst = '0' and oki_ok = '0' else '0';
    oki_rdata <= oki_cache(31 downto 24) when oki_addr(1 downto 0) = "00" else
                 oki_cache(23 downto 16) when oki_addr(1 downto 0) = "01" else
                 oki_cache(15 downto 8)  when oki_addr(1 downto 0) = "10" else
                 oki_cache(7 downto 0);

    fetch : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                rf <= RF_IDLE; rom_req_i <= '0'; rf_oki <= '0';
                cache_v <= '0'; pref_v <= '0'; oki_cv <= '0';
            else
                case rf is
                    when RF_IDLE =>
                        if rom_stall = '1' and rom_ack = '0' then
                            rom_addr  <= x"10" & rom_off(15 downto 1) & '0';
                            rom_req_i <= '1';
                            rf_oki    <= '0';
                            rf <= RF_REQ;
                        elsif oki_miss = '1' and rom_ack = '0' then
                            -- 0x240000 | (group << 2): word pair at +0 and +2
                            rom_addr  <= "001001" & oki_addr(17 downto 2) & "00";
                            rom_req_i <= '1';
                            rf_oki    <= '1';
                            rf <= RF_REQ;
                        end if;
                    when RF_REQ =>
                        if rom_ack = '1' then
                            rom_req_i  <= '0';
                            if rf_oki = '1' then
                                oki_cache <= rom_data;      -- bytes +0..+3, big-endian words
                                oki_tag   <= oki_addr(17 downto 2);
                                oki_cv    <= '1';
                            else
                                cache_word <= rom_data(31 downto 16);
                                cache_addr <= rom_off(15 downto 1);
                                cache_v    <= '1';
                                -- second burst word is addr|1: only a +2 prefetch
                                -- when the fetched word index is even (escape_core rule)
                                pref_word  <= rom_data(15 downto 0);
                                pref_addr  <= std_logic_vector(
                                    unsigned(rom_off(15 downto 1)) + 1);
                                pref_v     <= not rom_off(1);
                            end if;
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
                cmd_pend <= '0'; scom_ctr <= (others => '0');
                timed_int <= '0'; irqctr <= (others => '0');
                -- v63: WRIO (bank/YAMRES/squeak/TMS strobes) and MIX live in
                -- LS273s cleared only by /POR on the real board (SP-332
                -- sheets 12/13) - they survive a 68k sound reset
                if reset_n = '0' then
                    bank <= "00"; wrio_reg <= (others => '0');
                    mix_reg <= (others => '0');
                    tms_ws_n <= '0'; tms_rs_n <= '0'; tms_squeak <= '0';
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
                    -- (v71: strict mode requires the exact 2806/2807 address)
                    if sel_r28 = '1' and a16(2 downto 1) = "11" and
                       (irq_strict = '0' or a16(8 downto 3) = "000000") then
                        timed_int <= '0';
                    end if;
                    -- /RDP 2802 read: consume command, release NMI
                    if sel_r28 = '1' and a16(2 downto 1) = "01" and cpu_rw_n = '1' then
                        cmd_full_i <= '0';
                        cmd_pend   <= '0';          -- channel free again
                    end if;
                    if cpu_rw_n = '0' and sel_w2a = '1' then
                        case a16(2 downto 1) is
                            when "00" =>                            -- /VOICE
                                -- LANE3v: a 2A00 write IS a complete TMS
                                -- byte transfer (MAME data_w semantics).
                                -- LANE3y: byte capture + WS handshake FSM
                                -- both live in the ws_pulse process below
                                -- (single driver for tms_data).
                                null;
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
                -- SCHEM-95 SERIAL SCOM LINK TIMING (sheet p5/p6: main 20K <->
                -- audio 1M, clocked by /B4H = 894.9kHz). A byte takes >10us to
                -- cross REGARDLESS of CPU speed, and each arrival NMIs the
                -- 6502. Modelling instant delivery let a fast main CPU
                -- NMI-storm the sound CPU through its software-timed /WS
                -- pulse and coin handling: speech cut mid-phrase, coins
                -- dropped. Now: the main sees the channel busy immediately
                -- (it cannot stuff a second byte mid-transit), the sound side
                -- is notified only after the transit delay.
                if cmd_we = '1' then
                    cmd_latch <= cmd_data;
                    cmd_pend  <= '1';
                    scom_ctr  <= (others => '0');
                end if;
                if cmd_pend = '1' and cmd_full_i = '0' then
                    if scom_ctr = SCOM_XFER then
                        cmd_full_i <= '1';          -- byte lands: NMI the 6502
                    else
                        scom_ctr <= scom_ctr + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    cmd_full  <= cmd_pend or cmd_full_i;   -- busy from write until 6502 reads
    resp_full <= resp_full_i;
    resp_data <= resp_latch;
    snd_irq   <= resp_full_i;                       -- /SINT: level until 260031 read
    cpu_nmi_n <= not cmd_full_i;                    -- edge-detected inside T65
    cpu_irq_n <= ym_irq_n and not timed_int;

    ---------------------------------------------------------------- rdio 2804
    rdio <= test_mode                -- D7 self-test (MAME nets 0 in normal play)
            & (not cmd_full_i)       -- D6 /input-buffer-full (0 = command pending)
            & resp_full_i            -- D5 output-buffer-full (active high)
            -- LANE3u: D4 = the REAL TMS5220 ready (v71's irqctr toggle was a
            -- stand-in; the real readyq transitions as the chip accepts data
            -- - the same behavior the 6502 boot poll expects on hardware)
            & rdio_d4                -- D4: JSA-I the TMS5220's own READY; JSA-II reads 0 (MAME jsa_ii_ioports: unused)
            -- D3:2 idle LOW. The schematic doc calls these "+5V", but the
            -- JSA harness wires 0x04 as a third coin input (MAME JSAI port:
            -- Coin 3, IP_ACTIVE_HIGH; measured idle 2804 = 0x50/0x40, D3:2
            -- = 00). Holding them '1' meant Coin 3 permanently pressed:
            -- credits raced on their own, the response queue flooded, and
            -- stuck-coin protection suppressed start acceptance.
            & "00"
            -- D1:0 coins ACTIVE HIGH (MAME JSAI: IP_ACTIVE_HIGH; measured:
            -- idle 0, held coin reads 1)
            & coin2 & coin1;

    rdio_d4 <= (not tms_rdy_n) when BOARD = 1 else '0';

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
                xright => ym_xr,
                ch_gain=> uvol_fm );
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
              oki_dout   when sel_r28 = '1' and a16(2 downto 1) = "00" and BOARD = 2 else  -- /RDV
              x"FF"      when sel_r28 = '1' else
              x"FF"      when sel_pokey = '1' else   -- POKEY absent on Escape
              rom_byte   when sel_rom = '1' else
              x"FF";

    ---------------------------------------------------------------- TMS5220 (JSA-I)
    tms_board : if BOARD = 1 generate
    -- clock enable: 7.159MHz / (16 - preset); preset 5 (squeak=0) = /11 =
    -- 650.8kHz, preset 7 (squeak=1) = /9 = 795.4kHz (System 1 14S law)
    tms_clk : process(clk)
    begin
        if rising_edge(clk) then
            if tms_ctr = "1111" or reset_n = '0' then
                tms_ctr <= unsigned'("01") & tms_squeak & '1';
            else
                tms_ctr <= tms_ctr + 1;
            end if;
        end if;
    end process;
    tms_en <= '1' when tms_ctr = "1111" else '0';

    -- LANE4b: 2A00 write latches the byte onto the chip's data bus (the
    -- 74LS374 on the real board); the firmware's WRIO writes strobe WS.
    ws_pulse : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                tms_data <= (others => '0');
            elsif cpu_ena = '1' and cpu_rw_n = '0' and sel_w2a = '1'
                  and a16(2 downto 1) = "00" then
                tms_data <= cpu_do;
            end if;
            -- chip-reset combo generator: full countdown (~143us, several
            -- OSC enables) after any reset source releases
            if reset_n = '0' or sres_cnt /= 0 then
                tms_rst_cnt <= (others => '1');
            elsif tms_rst_cnt /= 0 then
                tms_rst_cnt <= tms_rst_cnt - 1;
            end if;
            if tms_rst_cnt = 0 then tms_rst_idle <= '1'; else tms_rst_idle <= '0'; end if;
        end if;
    end process;

    u_tms : entity work.TMS5220
    port map (
        I_OSC    => clk,
        I_ENA    => tms_en,
        I_WSn    => tms_ws_n and tms_rst_idle,
        I_RSn    => tms_rs_n and tms_rst_idle,
        I_DATA   => '1',
        I_TEST   => '1',
        I_DBUS   => tms_data,
        O_DBUS   => tms_do,
        O_RDYn   => tms_rdy_n,
        O_INTn   => tms_int_n,
        O_M0     => open, O_M1 => open,
        O_ADD8   => open, O_ADD4 => open, O_ADD2 => open, O_ADD1 => open,
        O_ROMCLK => open, O_T11 => open, O_IO => open, O_PRMOUT => open,
        O_SPKR   => tms_spkr
    );
    end generate;

    ---------------------------------------------------------------- OKI6295 (JSA-II, jt6295)
    -- WRIO D2 = OKI reset (active low), D3 = pin 7 (sample-rate select);
    -- both LS273 bits clear at POR, so the chip is held in reset until the
    -- firmware's first WRIO write, like the YM. 2A00 write = command byte
    -- (/WRV), 2800 read = status (/RDV). MIX D0 = 1.0 / 0.5 volume.
    oki_board : if BOARD = 2 generate
        oki_rst <= (not reset_n) or (not cpu_res_n) or (not wrio_reg(2));
        oki_ss  <= wrio_reg(3);
        oki_wrn <= '0' when oki_wrctr /= 0 else '1';
        oki_ctl : process(clk)
        begin
            if rising_edge(clk) then
                -- 1.193 MHz enable = clk/6
                if oki_cctr = 5 then oki_cctr <= (others => '0'); oki_cen <= '1';
                else oki_cctr <= oki_cctr + 1; oki_cen <= '0'; end if;
                -- 8-clock /WRV pulse, data held for its duration
                if cpu_ena = '1' and cpu_rw_n = '0' and sel_w2a = '1' and a16(2 downto 1) = "00" then
                    oki_din   <= cpu_do;
                    oki_wrctr <= "1000";
                elsif oki_wrctr /= 0 then
                    oki_wrctr <= oki_wrctr - 1;
                end if;
            end if;
        end process;

        oki_real : if YM_ENABLE generate
            u_oki : jt6295
                port map (
                    rst      => oki_rst,
                    clk      => clk,
                    cen      => oki_cen,
                    ss       => oki_ss,
                    wrn      => oki_wrn,
                    din      => oki_din,
                    dout     => oki_dout,
                    rom_addr => oki_addr,
                    rom_data => oki_rdata,
                    rom_ok   => oki_ok,
                    sound    => oki_snd,
                    sample   => open );
        end generate;
        -- GHDL: no Verilog. Status reads idle (0xF0 = no channel busy, the
        -- MSM6295 idle pattern), silence, and a ROM-address walker that
        -- advances one byte per enable whenever the current byte is served,
        -- so the second-client fetch path is exercised by the benches.
        oki_stub : if not YM_ENABLE generate
            oki_dout <= x"F0";
            oki_snd  <= (others => '0');
            walker : process(clk)
            begin
                if rising_edge(clk) then
                    if oki_rst = '1' then
                        oki_addr <= (others => '0');
                    elsif oki_cen = '1' and oki_ok = '1' then
                        oki_addr <= std_logic_vector(unsigned(oki_addr) + 1);
                    end if;
                end if;
            end process;
        end generate;
    end generate;

    ---------------------------------------------------------------- mixer
    -- YM xleft/xright * (0.60 * mixvol/7) in Q8; TMS stub contributes silence.
    -- |coef| <= 154/256 < 1 so the scaled product needs no saturation.
    mixer : process(clk)
        variable coef  : unsigned(7 downto 0);
        variable tcoef : unsigned(7 downto 0);
        variable ocoef : unsigned(7 downto 0);
        variable pl, pr, tv, ov : signed(24 downto 0);
        variable suml, sumr : signed(17 downto 0);
    begin
        if rising_edge(clk) then
            coef := YM_GAIN(to_integer(unsigned(mix_reg(3 downto 1))));
            -- LANE4k: user volume (Interact slider) - 0 mutes, else x(n+1)/8
            if uvol_ym = "000" then
                coef := (others=>'0');
            else
                coef := resize(shift_right(coef * (unsigned('0' & uvol_ym) + 1), 3), 8);
            end if;
            -- TMS vol 0-3 -> {0, 85, 170, 255}/256 (vol/3 x route gain 1.0).
            -- CT1 gating deliberately NOT applied yet (polarity unverified;
            -- ungated proves the speech engine - revisit after device test).
            tcoef := TMS_GAIN(to_integer(unsigned(mix_reg(7 downto 6))));
            if uvol_tms = "000" then
                tcoef := (others=>'0');
            else
                tcoef := resize(shift_right(tcoef * (unsigned('0' & uvol_tms) + 1), 3), 8);
            end if;
            -- JSA-II: OKI route 0.75 (MAME) x MIX D0 (1.0 / 0.5) = 192 / 96,
            -- through the same user slider as the TMS on JSA-I
            if BOARD = 2 then
                if mix_reg(0) = '1' then ocoef := to_unsigned(192, 8); else ocoef := to_unsigned(96, 8); end if;
                if uvol_tms = "000" then
                    ocoef := (others=>'0');
                else
                    ocoef := resize(shift_right(ocoef * (unsigned('0' & uvol_tms) + 1), 3), 8);
                end if;
            else
                ocoef := (others=>'0');
            end if;
            pl := signed(ym_xl) * signed('0' & coef);
            pr := signed(ym_xr) * signed('0' & coef);
            tv := (signed(tms_spkr) & "00") * signed('0' & tcoef);
            ov := (signed(oki_snd) & "00") * signed('0' & ocoef);
            suml := resize(pl(23 downto 8), 18) + resize(tv(23 downto 8), 18) + resize(ov(23 downto 8), 18);
            sumr := resize(pr(23 downto 8), 18) + resize(tv(23 downto 8), 18) + resize(ov(23 downto 8), 18);
            if    suml > 32767  then audio_l <= x"7FFF";
            elsif suml < -32768 then audio_l <= x"8000";
            else  audio_l <= std_logic_vector(suml(15 downto 0)); end if;
            if    sumr > 32767  then audio_r <= x"7FFF";
            elsif sumr < -32768 then audio_r <= x"8000";
            else  audio_r <= std_logic_vector(sumr(15 downto 0)); end if;
        end if;
    end process;
end rtl;
