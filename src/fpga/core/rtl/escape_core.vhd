-- Atari Escape core: dual 68000 subsystem, synthesizable.
-- The sim-proven design (escape_decode + dual TG68K + memories) re-hosted for
-- hardware. Program ROM is an external request/ack bus: core_top serves it from
-- SDRAM (loaded from the APF data slot); simulation serves it from rom_words.
-- On-chip BRAM holds the small RAMs (shared, work, video, color, EEPROM stub).
--
-- "Hello world" skeleton: CPUs boot and run the real program against BRAM +
-- external ROM; SCOM (sound) stubbed as buffers-empty; VBLANK IRQ4 with ack at
-- 360000; 360010 latch: D0 extra-CPU run, D5 video off, D4-D1 intensity.
-- Video layers land on top of this (alpha first) — see docs/ARCHITECTURE.md.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity escape_core is
    generic (
        -- 1 = bind jt51 (Quartus mixed-language); 0 = GHDL sim stub (docs/JSA.md)
        YM_ENABLE : integer := 1;
        -- 1 = serve low-64KB code from the download-filled shadows (hardware);
        -- 0 = disable (GHDL tbs: shadows unfilled, all fetches via arbiter)
        SHAD_EN   : integer := 1;
        -- SDSCHED-81: 1 = per-byte parity on the ROM CDC (rom_par4 valid).
        -- The legacy single bit passes any 2-bit error - and a passed error
        -- is EXECUTED. Per-byte detection feeds the existing retry path.
        -- 0 = legacy single-bit check only (testbenches).
        PAR4_EN   : integer := 0
    );
    port (
        clk        : in  std_logic;   -- 7.159091 MHz (CPU + pixel domain)
        reset_n    : in  std_logic;   -- hold low until ROM image is in SDRAM

        -- external program ROM bus (combined-image byte offsets; word reads)
        rom_addr   : out std_logic_vector(23 downto 0);
        rom_data   : in  std_logic_vector(31 downto 0);  -- [31:16]=addr, [15:0]=addr+2
        rom_par    : in  std_logic := '0';   -- even parity over rom_data, from server
        rom_par4   : in  std_logic_vector(3 downto 0) := "0000";  -- per-byte parity (PAR4_EN=1)
        rom_req    : out std_logic;
        rom_ack    : in  std_logic;

        -- v58 hot-code shadows: 64KB BRAM per CPU covering its low address
        -- space (vectors + ISR + main loop + boot). Filled during the ROM
        -- download via this write port (image byte addr; video shadow takes
        -- 0x000000-0x00FFFF, extra shadow 0x080000-0x08FFFF). Fetches in
        -- range are served zero-wait through the proven BRAM dtack path -
        -- restoring the real board's ~4-cycle fetch budget the game's frame
        -- architecture assumes (MAME fetches in zero time; SDRAM cost 15-25
        -- cycles and starved the main loop behind the vblank ISR).
        shad_wclk  : in  std_logic := '0';
        shad_waddr : in  std_logic_vector(23 downto 0) := (others=>'0');
        shad_wdata : in  std_logic_vector(15 downto 0) := (others=>'0');
        shad_we    : in  std_logic := '0';

        -- raster position (from video counters in core_top for now)
        vblank_in  : in  std_logic;

        -- player inputs, active-high pressed (mapped to active-low bus bits)
        p1_buttons : in  std_logic_vector(3 downto 0);  -- D11 duck..D8 start
        p2_buttons : in  std_logic_vector(3 downto 0);
        -- hall-effect joystick axes into the ADC0809 (0x80 = centered).
        -- Channel order per MAME eprom: IN0 = P1 Y, IN1 = P1 X, IN2 = P2 Y,
        -- IN3 = P2 X. X axes arrive pre-reversed (0x00 = full right), Y normal
        -- (0x00 = full up) — the harness wiring, not something we invert here.
        adc_p1x    : in  std_logic_vector(7 downto 0) := x"80";
        adc_p1y    : in  std_logic_vector(7 downto 0) := x"80";
        adc_p2x    : in  std_logic_vector(7 downto 0) := x"80";
        adc_p2y    : in  std_logic_vector(7 downto 0) := x"80";
        -- self-test lever (260010 D1, active low: 0 = service mode)
        svc_n      : in  std_logic := '1';
        -- JSA coin inputs (active high; coin1 = Pocket Select at core_top)
        coin1      : in  std_logic := '0';
        coin2      : in  std_logic := '0';
        -- 260000 D0: factory step/continue switch (unpopulated on production
        -- cabs, MAME marks it unused, but the self-test error loop reads it:
        -- 0x776 btst #0,$260000 — held low = step past a failed region)
        step_btn   : in  std_logic := '0';   -- active-high pressed
        -- diagnostic: force reads of the tests-passed flag ($3F7F0C) to 0x0100
        -- so the boot takes its already-passed branch (Interact "Skip Self-Test")
        skip_test  : in  std_logic := '0';
        irq_strict : in  std_logic := '0';   -- v71: JSA timed-IRQ ack strictness
        -- LANE4k user audio mixer (Interact): 0=mute .. 7=unity
        uvol_ym    : in  std_logic_vector(2 downto 0) := "111";
        uvol_tms   : in  std_logic_vector(2 downto 0) := "111";

        -- JSA-I audio out (signed 16-bit)
        audio_l    : out std_logic_vector(15 downto 0);
        audio_r    : out std_logic_vector(15 downto 0);

        -- video-side read ports + latches for the video chain
        alpha_vaddr : in  std_logic_vector(10 downto 0) := (others => '0');
        alpha_vdata : out std_logic_vector(15 downto 0);
        color_vaddr : in  std_logic_vector(10 downto 0) := (others => '0');
        color_vdata : out std_logic_vector(15 downto 0);
        pf_vaddr    : in  std_logic_vector(11 downto 0) := (others => '0');
        pf_vdata    : out std_logic_vector(15 downto 0);
        pfx_vaddr   : in  std_logic_vector(11 downto 0) := (others => '0');
        pfx_vdata   : out std_logic_vector(15 downto 0);
        mo_vaddr    : in  std_logic_vector(11 downto 0) := (others => '0');
        mo_vdata    : out std_logic_vector(15 downto 0);
        cfg_vaddr   : in  std_logic_vector(6 downto 0)  := (others => '0');
        cfg_vdata   : out std_logic_vector(15 downto 0);
        xscroll_out : out std_logic_vector(8 downto 0);
        yscroll_out : out std_logic_vector(8 downto 0);
        intensity_out : out std_logic_vector(3 downto 0);
        video_off_out : out std_logic;

        -- debug/observation (dbg_force_extra: sim-only early release of the extra CPU)
        dbg_force_extra : in  std_logic := '0';
        -- sim-only backdoor: force a word into shared RAM port A (mailbox injection).
        -- Defaults keep it inert; on real hardware these tie off and cost nothing.
        dbg_shr_we   : in  std_logic := '0';
        dbg_shr_addr : in  std_logic_vector(14 downto 0) := (others => '0');
        dbg_shr_din  : in  std_logic_vector(15 downto 0) := (others => '0');
        dbg_v_pc_fetch : out std_logic;
        dbg_e_running  : out std_logic;
        dbg_alpha_wr   : out std_logic;
        -- live snoop of the two-CPU handshake mailbox (shared RAM 0x16FFEx):
        --   cmd  = 0x16FFE0 (video->extra command, 1234/5A5A)
        --   resp = 0x16FFE2 (extra->video answer, 4321 = self-test done)
        --   ramr = 0x16FFE8 (extra RAM-test result, 0000 = pass)
        --   sum  = 0x16FFEA (extra ROM checksum word)
        dbg_mbox_cmd  : out std_logic_vector(15 downto 0);
        dbg_mbox_resp : out std_logic_vector(15 downto 0);
        dbg_mbox_ramr : out std_logic_vector(15 downto 0);
        dbg_mbox_sum  : out std_logic_vector(15 downto 0);
        -- LANE4r: {video 5A5A commands, extra 4321 acks} since power-on. The
        -- '68 freeze: both CPUs alive, 16 extra restarts, game logic waiting
        -- on this exchange forever. Equal counts = video missed the ack;
        -- commands ahead = extra never answered. One photo decides.
        dbg_mbox_cnts : out std_logic_vector(15 downto 0);
        mbox_dead     : out std_logic;   -- 5A5A unanswered ~4.7s post-boot
        -- playfield-write activity: is the game drawing a picture at all?
        dbg_pf_wcnt   : out std_logic_vector(15 downto 0);  -- nonzero PF-RAM writes
        dbg_pf_last   : out std_logic_vector(15 downto 0);  -- last nonzero PF word
        dbg_col_wcnt  : out std_logic_vector(15 downto 0);  -- color-RAM writes (palette)
        -- boot-flow milestones: [15:8] last byte written to the 'tests done'
        -- flag $3F7F0C (01 = self-test passed), [7:0] soft-reboot count
        -- (extra-CPU re-reset via 360010 D0 clearing = boot pass transitions)
        dbg_boot      : out std_logic_vector(15 downto 0);
        dbg_retry     : out std_logic_vector(15 downto 0);  -- CDC parity retries
        -- targeted probe for the deterministic glyph corruption: alpha word 0x42
        -- (byte addr 0x3F4084, the 'e' of "Testing Ram." printed by ROM 0x342-0x356;
        -- expected word 0x0065). wr = last CPU-written value, rd = last scanout value.
        dbg_engine    : out std_logic_vector(15 downto 0);   -- actor-table head word
        dbg_mode      : out std_logic_vector(15 downto 0);   -- {3F7F16, 3F7F23}
        -- LANE4f: extra-CPU first-fault latch (0000 until a genuine exception)
        dbg_ecrash_pc   : out std_logic_vector(15 downto 0);
        dbg_ecrash_data : out std_logic_vector(15 downto 0);
        -- LANE4h: extra-CPU reset-vector fetch count (restart detector)
        dbg_erestart    : out std_logic_vector(7 downto 0);
        -- LANE4l: longest bus cycle since last read of this register
        dbg_estall      : out std_logic_vector(15 downto 0);
        -- LANE4s: completed bus cycles per frame, per CPU (as_n falling
        -- edges, latched at vblank). Direct speed meter against the MAME
        -- reference - answers "are the processors actually at speed?"
        dbg_vcyc        : out std_logic_vector(15 downto 0);
        dbg_ecyc        : out std_logic_vector(15 downto 0);
        -- LANE4s: source PC of the extra's last jump into the 0xA62-0xB7F
        -- data table, and a live flag that it is currently executing there
        dbg_ewild       : out std_logic_vector(15 downto 0);
        dbg_eintab      : out std_logic;
        -- SDSCHED-75: alpha writes per frame. The attract wipe covers the
        -- old scene with alpha tiles (~380 wr/frame in MAME); the stalled
        -- red panel on device is either those writes missing (game-logic
        -- divergence) or written-but-not-rendered. One HUD reading decides.
        dbg_awr         : out std_logic_vector(15 downto 0);
        -- SDSCHED-76: impostor word served at extra 0x80E (0 = never) and
        -- how many times (saturates at 15)
        dbg_ewrong      : out std_logic_vector(15 downto 0);
        dbg_ewrong_cnt  : out std_logic_vector(3 downto 0);
        dbg_ewrong_prev : out std_logic_vector(15 downto 0);  -- addr of prior read
        -- LANE4i: extra CPU has executed no bus cycle for ~0.59s post-boot
        -- (the stop #\$2700 die state) - core_top treats it like a watchdog
        -- timeout so a frozen world reboots instead of hanging forever
        e_dead          : out std_logic;
        dbg_a84_wr    : out std_logic_vector(15 downto 0);
        dbg_a84_rd    : out std_logic_vector(15 downto 0);
        -- live wedge-locator: last video-CPU instruction-fetch address (low 16,
        -- boot/march code all sits below 0x10000) + last data-write addr [23:8]
        -- (names the RAM region the march is currently in: 16xx shared, 3F5x work,
        --  3F0x pf, 3F2x mo, 3F4x alpha, 3E0x color)
        dbg_pc        : out std_logic_vector(15 downto 0);
        dbg_wrhi      : out std_logic_vector(15 downto 0);
        -- last exception vector fetched by the video CPU (supervisor-data read
        -- below 0x400): 0008 bus err, 000C addr err, 0010 illegal, 0060 spurious,
        -- 0064..7C autovectors. All fault vectors point to 0x100 = STOP #$2700
        -- (Atari's die-and-let-the-watchdog-reboot handler).
        dbg_vec       : out std_logic_vector(15 downto 0);
        -- 1-cycle strobe when a FAULT vector (offset < 0x60: bus/addr/illegal/
        -- div0/chk/trapv/priv/trace/lineA/lineF) is fetched; dbg_pc still holds
        -- the faulting instruction's address at that moment
        dbg_fault     : out std_logic;
        -- data word of the last completed program-space fetch before the fault
        -- (the opcode the CPU actually received) + which unit served it:
        -- 00 = BRAM/other, 01 = ROM prefetch hit, 10 = ROM last-word cache,
        -- 11 = ROM SDRAM transaction
        dbg_fdata     : out std_logic_vector(15 downto 0);
        dbg_fsrc      : out std_logic_vector(1 downto 0);
        -- extra-CPU visibility (the last uninstrumented corner): live low-16
        -- program-fetch address in its own space (reset 0x342, self-test loops)
        dbg_epc       : out std_logic_vector(15 downto 0);
        -- JSA link state: [15] cmd_full [14] resp_full [13] snd_irq [12] 0,
        -- [11:8] 0, [7:0] last command byte the 68k wrote to 360031
        dbg_jsa_link  : out std_logic_vector(15 downto 0);
        dbg_jsa_pc    : out std_logic_vector(15 downto 0);
        -- coin-chain probes (HUD): every link from switch to credit.
        -- v62: resp_stat = {NONZERO-response count, last NONZERO byte}.
        -- v61 on-device result: total reads churn at frame rate (link
        -- healthy), input edges clean, yet credits appeared - the phantom
        -- bytes are sub-frame; this pins their count and value.
        dbg_resp_stat : out std_logic_vector(15 downto 0);
        -- coin_cred = {coin-line edge count, game's credit count ($3F7F55)}
        -- - edges ticking with no Select presses = the input line itself
        -- glitches; credits climbing while edges hold = downstream bug.
        dbg_coin_cred : out std_logic_vector(15 downto 0);
        -- watchdog: game strobes 2E0000 (MAME eprom.cpp truth); if no strobe for 64
        -- vblanks (~1.07s, authentic recover-by-reboot) this pulses high once
        wdog_expired  : out std_logic
    );
end escape_core;

architecture rtl of escape_core is
    signal v_addr : std_logic_vector(31 downto 0);
    signal v_do, v_di : std_logic_vector(15 downto 0);
    signal v_as_n, v_uds_n, v_lds_n, v_rw_n : std_logic;
    signal v_dtack_n : std_logic;
    signal v_ws, e_ws : std_logic;   -- +1 waitstate on non-ROM acks (v30)
    signal v_ipl : std_logic_vector(2 downto 0);
    signal v_fc, e_fc : std_logic_vector(2 downto 0);
    signal v_vpa_n, e_vpa_n : std_logic;
    signal e_ipl : std_logic_vector(2 downto 0);

    signal e_addr : std_logic_vector(31 downto 0);
    signal e_do, e_di : std_logic_vector(15 downto 0);
    signal e_as_n, e_uds_n, e_lds_n, e_rw_n : std_logic;
    signal e_dtack_n : std_logic;
    signal e_resn : std_logic;

    signal v_sel_rom, v_sel_eeprom, v_sel_unlk, v_sel_ram, v_sel_io, v_sel_wdog,
           v_sel_vctl, v_sel_color, v_sel_pf, v_sel_mo, v_sel_alpha, v_sel_mobc,
           v_sel_slip, v_sel_work, v_sel_pfpal : std_logic;
    signal e_sel_rom, e_sel_ram, e_sel_io : std_logic;
    signal e_unused : std_logic_vector(12 downto 0);

    signal extra_release, video_off : std_logic;
    signal xscroll, yscroll : std_logic_vector(8 downto 0);
    -- v83: pending scroll (written any time) vs applied scroll (latched at
    -- frame start) - MAME eprom scanline_update applies alpha 780/781 only
    -- at scanline 0; instant application tore animated-scroll screens
    signal xs_pend, ys_pend : std_logic_vector(8 downto 0);
    signal intensity : std_logic_vector(3 downto 0);
    signal virq, vblank_d, v_pc_seen : std_logic;

    -- even parity over the 32-bit ROM delivery (checked against rom_par)
    function parity32(v : std_logic_vector(31 downto 0)) return std_logic is
        variable p : std_logic := '0';
    begin
        for i in 0 to 31 loop p := p xor v(i); end loop;
        return p;
    end function;

    -- v63: OWN_J retired - the JSA fetches from its own BRAM shadow now,
    -- shrinking this to a two-client arbiter and freeing SDRAM slots for
    -- the video fetch path (playfield corruption relief)
    type rom_owner_t is (OWN_IDLE, OWN_V, OWN_E, OWN_VP, OWN_EP);
    signal rom_owner : rom_owner_t;
    signal last_was_v : std_logic;   -- fair round-robin: alternate priority
    signal rom_addr_i : std_logic_vector(23 downto 0);
    signal rom_req_i  : std_logic;
    signal v_rom_pend, e_rom_pend, v_rom_dtack, e_rom_dtack : std_logic;
    signal v_rom_hold, e_rom_hold : std_logic_vector(15 downto 0);
    signal v_pref_data, e_pref_data : std_logic_vector(15 downto 0);
    signal v_pref_addr, e_pref_addr : std_logic_vector(19 downto 0);
    signal v_pref_valid, e_pref_valid : std_logic;
    -- last-word cache: ROM is read-only, so a repeat read of the same word
    -- (68k byte reads fetch the same word twice for even/odd bytes) is served
    -- from a register with no SDRAM transaction. With the +2 prefetch this cuts
    -- the extra CPU's self-test checksum traffic ~3x.
    -- speed2: v56/v57 speculative word-0 prefetch (ported; OWN_J-era
    -- starvation victim is gone - JSA fetches from its own shadow since v63)
    signal vp_want, ep_want : std_logic;
    signal vp_addr, ep_addr : std_logic_vector(19 downto 0);
    signal v_hit_dly, e_hit_dly : unsigned(1 downto 0);
    signal v_served, e_served : std_logic;
    signal v_last_data, e_last_data : std_logic_vector(15 downto 0);
    signal v_last_addr, e_last_addr : std_logic_vector(19 downto 0);
    signal v_last_valid, e_last_valid : std_logic;
    -- LANE4d A/B: cache serves gated off (see arbiter comment)
    constant LW_CACHE_EN : std_logic := '0';

    signal alpha_vq : std_logic_vector(15 downto 0);
    signal a84_wr_i, a84_rd_i : std_logic_vector(15 downto 0);
    signal pc_i, wrhi_i, epc_i : std_logic_vector(15 downto 0);
    signal ewild_src : std_logic_vector(15 downto 0) := (others=>'0');
    signal e_in_tab  : std_logic := '0';
    signal ewrong_val : std_logic_vector(15 downto 0) := (others=>'0');
    signal ewrong_cnt : unsigned(3 downto 0) := (others=>'0');
    signal ewrong_prev : std_logic_vector(16 downto 1) := (others=>'0');
    signal e_lastrd    : std_logic_vector(16 downto 1) := (others=>'0');
    signal vec_i : std_logic_vector(15 downto 0);
    -- LANE4f: extra-CPU first-fault forensics
    signal e_fdata_i, ecrash_pc_i, ecrash_data_i : std_logic_vector(15 downto 0)
        := (others=>'0');
    signal e_vec_seen : std_logic := '0';
    signal e_restart_cnt : unsigned(7 downto 0) := (others=>'0');
    -- LANE4i freeze rescue: extra-CPU bus-idle detector (STOP state)
    signal e_idle_cnt : unsigned(22 downto 0) := (others=>'0');
    signal e_dead_i   : std_logic := '0';
    -- LANE4l stall probe: longest extra-CPU bus cycle (clk counts). A cycle
    -- stuck waiting for dtack (write-path stall) shows as a huge value -
    -- the freeze mode the idle detector CANNOT see (bus stays active).
    signal e_cyc_cur, e_cyc_max : unsigned(15 downto 0) := (others=>'0');
    -- JSA sound board link
    signal jsa_rom_addr : std_logic_vector(23 downto 0);
    signal jsa_rom_req : std_logic;
    signal jsa_resp : std_logic_vector(7 downto 0);
    signal jsa_cpu_addr : std_logic_vector(15 downto 0);
    signal jsa_last_cmd : std_logic_vector(7 downto 0);
    -- v58 hot-code shadows
    signal vshad_q, eshad_q : std_logic_vector(15 downto 0);
    signal v_sel_shad, e_sel_shad : std_logic;
    signal vshad_we, eshad_we : std_logic;
    -- LANE4n gameplay shadows: MAME PC profile of demo gameplay showed 85%
    -- of MAIN-CPU time at 0x40000-0x57FFF (page 0x4E000 alone = 51%) and
    -- 21% of EXTRA time at 0xF000 - all outside the v58 shadows = the
    -- gameplay slowdown (audio at 100% proved the JSA-shadowed CPU keeps
    -- real time). Shadow2: main 0x48000-0x4FFFF (57% of gameplay fetches),
    -- extra 0xF000-0xFFFF. Funded by the EEPROM shrink (16KB -> real 1KB).
    signal vshad2_q, eshad2_q, vshad3_q : std_logic_vector(15 downto 0);

    signal v_sel_shad1, v_sel_shad2, v_sel_shad3, e_sel_shad1, e_sel_shad2 : std_logic;
    signal vshad2_we, eshad2_we, vshad3_we : std_logic;
    -- v63: JSA 6502 BRAM shadow (whole 64KB sound ROM, image 100000-10FFFF).
    -- The 6502 fetched every opcode over the marginal SDRAM path (the 68ks
    -- got shadows in v58, the 6502 never did) - one corrupt fetch derails
    -- it into RAM (observed: jsa_pc frame-latched at 0001/0162) where
    -- runaway FF opcodes spray the response latch = phantom credits /
    -- dead coins / intermittent sound, differing every boot.
    signal jshad_we    : std_logic;
    signal jshad_q     : std_logic_vector(15 downto 0);
    signal jshad_raddr : std_logic_vector(14 downto 0) := (others=>'0');
    signal jsa_srv     : unsigned(2 downto 0) := "000";
    signal jsa_rom_data32 : std_logic_vector(31 downto 0) := (others=>'0');
    signal jsa_shad_ack   : std_logic := '0';
    signal jsa_cmd_full, jsa_resp_full, jsa_snd_irq : std_logic;
    signal snd_cmd_we, snd_resp_rd, snd_res_p : std_logic;
    -- v61 coin-chain probe state
    signal resp_rd_d  : std_logic := '0';
    signal resp_reads : unsigned(7 downto 0) := (others => '0');
    signal resp_last  : std_logic_vector(7 downto 0) := (others => '0');
    signal coin1_d, coin2_d : std_logic := '0';
    signal actorhead_sn : std_logic_vector(15 downto 0) := (others=>'0');
    signal mode16_sn, mode23_sn : std_logic_vector(7 downto 0) := (others=>'0');
    signal coin_edges : unsigned(7 downto 0) := (others => '0');
    signal credits_sn : std_logic_vector(7 downto 0) := (others => '0');
    signal wdog_ctr : unsigned(5 downto 0);
    signal wdog_expired_i : std_logic;
    signal fault_p, vec_seen : std_logic;
    signal v_rom_src : std_logic_vector(1 downto 0);
    signal fdata_i : std_logic_vector(15 downto 0);
    signal fsrc_i  : std_logic_vector(1 downto 0);
    signal alpha_vaddr_d : std_logic_vector(10 downto 0);
    signal shr_qa, shr_qb : std_logic_vector(15 downto 0);
    signal pf_q, mo_q, alpha_q, work_q, pfpal_q, color_q, cfg_q, ee_q : std_logic_vector(15 downto 0);
    signal we_pf, we_mo, we_alpha, we_work, we_pfpal, we_color, we_cfg, we_ee : std_logic;
    signal v_wr, we_shr_a, we_shr_b : std_logic;
    signal shr_a_addr : std_logic_vector(14 downto 0);
    signal shr_a_din  : std_logic_vector(15 downto 0);
    signal shr_a_uds, shr_a_lds : std_logic;
    signal v_addr_q, e_addr_q : std_logic_vector(23 downto 1) := (others=>'0');
    signal mbox_cmd, mbox_resp, mbox_ramr, mbox_sum : std_logic_vector(15 downto 0) := (others=>'0');
    -- LANE4r mailbox forensics + deadlock rescue
    signal cmd5a_cnt, ack_cnt : unsigned(7 downto 0) := (others=>'0');
    signal mb_cmd_we_d, mb_ack_we_d : std_logic := '0';
    signal mb_wait     : std_logic := '0';
    signal mb_timer    : unsigned(25 downto 0) := (others=>'0');
    signal mbox_dead_i : std_logic := '0';
    -- LANE4s bus-cycle meters
    signal vcyc_ctr, ecyc_ctr, vcyc_fr, ecyc_fr : unsigned(15 downto 0) := (others=>'0');
    signal vas_d, eas_d, vb_cyc_d : std_logic := '1';
    signal awr_ctr, awr_fr : unsigned(15 downto 0) := (others=>'0');
    signal awr_we_d, vb_awr_d : std_logic := '0';
    signal pf_wcnt, pf_last, col_wcnt : std_logic_vector(15 downto 0) := (others=>'0');
    signal boot_flag  : std_logic_vector(7 downto 0) := (others=>'0');
    signal reboot_cnt : unsigned(7 downto 0) := (others=>'0');
    signal retry_cnt  : unsigned(15 downto 0) := (others=>'0');
    signal rom_par_ok : std_logic;
    signal alpha_wr_stretch : unsigned(19 downto 0);
    -- ADC0809 behavioral model (260020-2E)
    signal adc_data : std_logic_vector(7 downto 0) := x"80";
    signal adc_chan : std_logic_vector(1 downto 0) := "00";
    signal adc_busy : unsigned(9 downto 0) := (others=>'0');
    signal adc_rd, adc_rd_d, adc_eoc : std_logic;
begin
    ---------------------------------------------------------------- CPUs
    -- 68000 (schematic says U68010 but real boards carry 68000s); autovectored IRQs via VPA
    vcpu : entity work.TG68K generic map ( CPU => "00" )
        port map ( CLK=>clk, RESET=>reset_n, HALT=>reset_n, BERR=>'0', IPL=>v_ipl,
                   ADDR=>v_addr, FC=>v_fc, DATAI=>v_di, DATAO=>v_do,
                   AS=>v_as_n, UDS=>v_uds_n, LDS=>v_lds_n, RW=>v_rw_n,
                   DTACK=>v_dtack_n, E=>open, VPA=>v_vpa_n, VMA=>open );

    e_resn <= reset_n and (extra_release or dbg_force_extra);
    -- also a 68000 (same schematic-vs-board story as the video CPU)
    ecpu : entity work.TG68K generic map ( CPU => "00" )
        port map ( CLK=>clk, RESET=>e_resn, HALT=>e_resn, BERR=>'0', IPL=>e_ipl,
                   ADDR=>e_addr, FC=>e_fc, DATAI=>e_di, DATAO=>e_do,
                   AS=>e_as_n, UDS=>e_uds_n, LDS=>e_lds_n, RW=>e_rw_n,
                   DTACK=>e_dtack_n, E=>open, VPA=>e_vpa_n, VMA=>open );

    -- IPL active low: sound /SINT = IRQ6 (vector 0x78 -> $134C), vblank =
    -- IRQ4. Re-enabled in v49: the v37 mask was diagnostic; the scattered
    -- crashes were the SDRAM wrong-row serve (fixed v45/v48), not IPL
    -- transitions. Coin-in routes through the JSA (6502 reads the switches,
    -- reports over the sound link) so coins need this live.
    v_ipl <= "001" when jsa_snd_irq='1' else
             "011" when virq='1' else "111";
    e_ipl <= "011" when virq='1' else "111";     -- VBLANK also interrupts the extra CPU
    -- autovector: assert VPA during interrupt acknowledge (FC=111), per schematic 60L/55L
    v_vpa_n <= '0' when v_fc="111" and v_as_n='0' else '1';
    e_vpa_n <= '0' when e_fc="111" and e_as_n='0' else '1';

    ---------------------------------------------------------------- decoders
    vdec : entity work.escape_decode
        port map ( addr=>v_addr(23 downto 0), as_n=>v_as_n,
                   sel_rom=>v_sel_rom, sel_eeprom=>v_sel_eeprom, sel_eeprom_unlk=>v_sel_unlk,
                   sel_ram=>v_sel_ram, sel_io=>v_sel_io, sel_watchdog=>v_sel_wdog,
                   sel_vidctrl=>v_sel_vctl, sel_colorram=>v_sel_color, sel_pfram=>v_sel_pf,
                   sel_moram=>v_sel_mo, sel_alpharam=>v_sel_alpha, sel_mobconfig=>v_sel_mobc,
                   sel_slip=>v_sel_slip, sel_workram=>v_sel_work, sel_pfpalette=>v_sel_pfpal );

    edec : entity work.escape_decode
        port map ( addr=>e_addr(23 downto 0), as_n=>e_as_n,
                   sel_rom=>e_sel_rom, sel_eeprom=>e_unused(0), sel_eeprom_unlk=>e_unused(1),
                   sel_ram=>e_sel_ram, sel_io=>e_unused(2), sel_watchdog=>e_unused(3),
                   sel_vidctrl=>e_unused(4), sel_colorram=>e_unused(5), sel_pfram=>e_unused(6),
                   sel_moram=>e_unused(7), sel_alpharam=>e_unused(8), sel_mobconfig=>e_unused(9),
                   sel_slip=>e_unused(10), sel_workram=>e_unused(11), sel_pfpalette=>e_unused(12) );

    ---------------------------------------------------------------- ROM bus arbitration
    v_rom_pend <= '1' when v_sel_rom='1' and v_sel_shad='0' and v_as_n='0' else '0';
    e_rom_pend <= '1' when e_sel_rom='1' and e_sel_shad='0' and e_as_n='0' else '0';

    rom_arb : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                rom_owner <= OWN_IDLE; rom_req_i <= '0'; last_was_v <= '0';
                v_pref_valid <= '0'; e_pref_valid <= '0';
                v_last_valid <= '0'; e_last_valid <= '0';
                v_rom_dtack <= '0'; e_rom_dtack <= '0';
                retry_cnt <= (others=>'0');
                vp_want <= '0'; ep_want <= '0';
                v_hit_dly <= "00"; e_hit_dly <= "00";
                v_served <= '0'; e_served <= '0';
            else
                v_rom_dtack <= '0'; e_rom_dtack <= '0';
                -- v57 serve-once + paced register serves
                if v_as_n='1' then v_served <= '0'; end if;
                if e_as_n='1' then e_served <= '0'; end if;
                if v_hit_dly /= "00" then
                    v_hit_dly <= v_hit_dly - 1;
                    if v_hit_dly = "01" then v_rom_dtack <= '1'; end if;
                end if;
                if e_hit_dly /= "00" then
                    e_hit_dly <= e_hit_dly - 1;
                    if e_hit_dly = "01" then e_rom_dtack <= '1'; end if;
                end if;
                case rom_owner is
                    when OWN_IDLE =>
                        -- fair round-robin: whoever was NOT served last gets priority,
                        -- otherwise the video CPU's constant fetch stream starves the
                        -- extra CPU (observed on hardware as an ERESET retry loop)
                        if rom_ack='1' then
                            null;                        -- wait out previous ack (4-phase)
                        -- prefetch hits: no SDRAM transaction, v57-paced serve
                        elsif v_rom_pend='1' and v_served='0' and v_hit_dly="00"
                              and v_pref_valid='1'
                              and (v_addr(19 downto 1) & '0') = v_pref_addr then
                            v_rom_hold   <= v_pref_data;
                            v_hit_dly    <= "10";
                            v_served     <= '1';
                            v_rom_src    <= "01";
                            v_pref_valid <= '0';
                            v_last_data  <= v_pref_data;
                            v_last_addr  <= v_pref_addr;
                            v_last_valid <= '1';
                        elsif e_rom_pend='1' and e_served='0' and e_hit_dly="00"
                              and e_pref_valid='1'
                              and (e_addr(19 downto 1) & '0') = e_pref_addr then
                            e_rom_hold   <= e_pref_data;
                            e_hit_dly    <= "10";
                            e_served     <= '1';
                            e_pref_valid <= '0';
                            e_last_data  <= e_pref_data;
                            e_last_addr  <= e_pref_addr;
                            e_last_valid <= '1';
                        -- last-word cache (still gated OFF by LANE4d A/B)
                        elsif LW_CACHE_EN='1' and v_rom_pend='1' and v_served='0'
                              and v_hit_dly="00" and v_last_valid='1'
                              and (v_addr(19 downto 1) & '0') = v_last_addr then
                            v_rom_hold  <= v_last_data;
                            v_hit_dly   <= "10";
                            v_served    <= '1';
                            v_rom_src   <= "10";
                        elsif LW_CACHE_EN='1' and e_rom_pend='1' and e_served='0'
                              and e_hit_dly="00" and e_last_valid='1'
                              and (e_addr(19 downto 1) & '0') = e_last_addr then
                            e_rom_hold  <= e_last_data;
                            e_hit_dly   <= "10";
                            e_served    <= '1';
                        -- v57: no grant while a paced serve counts down
                        elsif e_rom_pend='1' and e_hit_dly="00" and e_served='0'
                              and (last_was_v='1' or v_rom_pend='0' or v_hit_dly/="00") then
                            rom_owner <= OWN_E; last_was_v <= '0';
                            rom_addr_i <= std_logic_vector(
                                unsigned(x"0" & e_addr(19 downto 1) & '0') + x"080000");
                            rom_req_i <= '1';
                        elsif v_rom_pend='1' and v_hit_dly="00" and v_served='0' then
                            rom_owner <= OWN_V; last_was_v <= '1';
                            rom_addr_i <= x"0" & v_addr(19 downto 1) & '0';
                            rom_req_i <= '1';
                        -- v56: speculative word-0 follow-ups, lowest priority
                        elsif vp_want='1' then
                            rom_owner <= OWN_VP; vp_want <= '0';
                            rom_addr_i <= x"0" & vp_addr;
                            rom_req_i <= '1';
                        elsif ep_want='1' then
                            rom_owner <= OWN_EP; ep_want <= '0';
                            rom_addr_i <= std_logic_vector(
                                unsigned(x"0" & ep_addr) + x"080000");
                            rom_req_i <= '1';
                        end if;
                    when OWN_V =>
                        if v_as_n='1' then                       -- CPU ended cycle: abort
                            rom_req_i <= '0'; rom_owner <= OWN_IDLE;
                        elsif rom_req_i='0' then                 -- parity retry: re-issue
                            if rom_ack='0' then rom_req_i <= '1'; end if;
                        elsif rom_ack='1' and rom_par_ok='0' then -- bad CDC data: retry
                            rom_req_i <= '0';
                            retry_cnt <= retry_cnt + 1;
                        elsif rom_ack='1' then
                            rom_req_i <= '0'; v_rom_hold <= rom_data(31 downto 16);
                            -- speed2: word 1 never consumed (marginal capture);
                            -- arm a speculative follow-up txn for addr+2 whose
                            -- word 0 becomes the prefetch (v56 mechanism)
                            vp_addr <= std_logic_vector(
                                unsigned(v_addr(19 downto 1) & '0') + 2);
                            vp_want <= '1';
                            v_last_data  <= rom_data(31 downto 16);
                            v_last_addr  <= v_addr(19 downto 1) & '0';
                            v_last_valid <= '1';
                            v_rom_dtack <= '1'; rom_owner <= OWN_IDLE;
                            v_served    <= '1';
                            v_rom_src   <= "11";
                        end if;
                    when OWN_VP =>
                        if rom_req_i='0' then
                            if rom_ack='0' then rom_req_i <= '1'; end if;
                        elsif rom_ack='1' and rom_par_ok='0' then
                            rom_req_i <= '0';
                            retry_cnt <= retry_cnt + 1;
                        elsif rom_ack='1' then
                            rom_req_i <= '0';
                            v_pref_data  <= rom_data(31 downto 16);  -- word 0 only
                            v_pref_addr  <= vp_addr;
                            v_pref_valid <= '1';
                            rom_owner <= OWN_IDLE;
                        end if;
                    when OWN_EP =>
                        if rom_req_i='0' then
                            if rom_ack='0' then rom_req_i <= '1'; end if;
                        elsif rom_ack='1' and rom_par_ok='0' then
                            rom_req_i <= '0';
                            retry_cnt <= retry_cnt + 1;
                        elsif rom_ack='1' then
                            rom_req_i <= '0';
                            e_pref_data  <= rom_data(31 downto 16);
                            e_pref_addr  <= ep_addr;
                            e_pref_valid <= '1';
                            rom_owner <= OWN_IDLE;
                        end if;
                    when OWN_E =>
                        if e_as_n='1' then
                            rom_req_i <= '0'; rom_owner <= OWN_IDLE;
                        elsif rom_req_i='0' then                 -- parity retry: re-issue
                            if rom_ack='0' then rom_req_i <= '1'; end if;
                        elsif rom_ack='1' and rom_par_ok='0' then
                            rom_req_i <= '0';
                            retry_cnt <= retry_cnt + 1;
                        elsif rom_ack='1' then
                            rom_req_i <= '0'; e_rom_hold <= rom_data(31 downto 16);
                            ep_addr <= std_logic_vector(
                                unsigned(e_addr(19 downto 1) & '0') + 2);
                            ep_want <= '1';                -- speed2 follow-up
                            e_last_data  <= rom_data(31 downto 16);
                            e_last_addr  <= e_addr(19 downto 1) & '0';
                            e_last_valid <= '1';
                            e_rom_dtack <= '1'; rom_owner <= OWN_IDLE;
                            e_served    <= '1';
                        end if;
                end case;
            end if;
        end if;
    end process;
    rom_addr <= rom_addr_i;
    rom_req  <= rom_req_i;

    ---------------------------------------------------------------- memories
    -- SDSCHED-80 WRITE-SIDE DISCIPLINE: strobes fire only once the address
    -- has been stable a full clk. '79 eliminated the entire read side (both
    -- dispatch-chain traps silent through a live freeze) - the remaining
    -- bus-level suspect is a boundary-edge write landing at a mixed
    -- old/new address during back-to-back cycles (exception stacking is a
    -- train of consecutive pushes). A stale-address push corrupts the
    -- stack; the RTE then pops garbage - correct reads of corrupt content,
    -- silent to every read watchdog. Writes repeat every stable clk of the
    -- (dtack-extended) cycle, so excluding the first edge loses nothing.
    v_wr     <= '1' when v_as_n='0' and v_rw_n='0'
                         and v_addr(23 downto 1) = v_addr_q else '0';
    we_shr_a <= '1' when dbg_shr_we='1' else (v_wr and v_sel_ram);
    we_shr_b <= '1' when e_as_n='0' and e_rw_n='0' and e_sel_ram='1'
                         and e_addr(23 downto 1) = e_addr_q else '0';
    -- sim backdoor mux on port A (dbg_shr_we tied '0' on hardware -> collapses away)
    shr_a_addr <= dbg_shr_addr    when dbg_shr_we='1' else v_addr(15 downto 1);
    shr_a_din  <= dbg_shr_din     when dbg_shr_we='1' else v_do;
    shr_a_uds  <= '0'             when dbg_shr_we='1' else v_uds_n;
    shr_a_lds  <= '0'             when dbg_shr_we='1' else v_lds_n;

    shared_ram : entity work.dpram_bytelane_syn generic map ( awidth => 15 )
        port map ( clk=>clk,
                   addr_a=>shr_a_addr, din_a=>shr_a_din,
                   we_a=>we_shr_a, uds_a_n=>shr_a_uds, lds_a_n=>shr_a_lds, q_a=>shr_qa,
                   addr_b=>e_addr(15 downto 1), din_b=>e_do,
                   we_b=>we_shr_b, uds_b_n=>e_uds_n, lds_b_n=>e_lds_n, q_b=>shr_qb );

    -- snoop handshake mailbox writes (0x16FFE0..EA) from either CPU port, for HUD
    mbox_snoop : process(clk)
    begin
        if rising_edge(clk) then
            -- port A (video CPU) writes the command word
            if we_shr_a='1' and shr_a_addr = "111111111110000" then mbox_cmd  <= shr_a_din; end if; -- E0
            -- port B (extra CPU) writes its answer + self-test results
            if we_shr_b='1' then
                case e_addr(15 downto 1) is
                    when "111111111110000" => mbox_cmd  <= e_do;   -- E0
                    when "111111111110001" => mbox_resp <= e_do;   -- E2
                    when "111111111110100" => mbox_ramr <= e_do;   -- E8
                    when "111111111110101" => mbox_sum  <= e_do;   -- EA
                    when others => null;
                end case;
            end if;
        end if;
    end process;
    dbg_mbox_cmd  <= mbox_cmd;
    dbg_mbox_resp <= mbox_resp;
    dbg_mbox_ramr <= mbox_ramr;
    dbg_mbox_sum  <= mbox_sum;

    -- LANE4r: handshake ledger + deadlock watch. Counts one per bus write
    -- (strobes span many clks; addr/data are stable, so edge-detect on the
    -- fully-qualified condition is exact). The watch arms on each video-CPU
    -- 5A5A command post-boot and clears on the extra's 4321 ack; ~4.7s
    -- unanswered (MAME warm ack: instant; 10x margin) latches mbox_dead.
    mbox_ledger : process(clk)
        variable cmd_we, ack_we : std_logic;
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                cmd5a_cnt <= (others=>'0'); ack_cnt <= (others=>'0');
                mb_cmd_we_d <= '0'; mb_ack_we_d <= '0';
                mb_wait <= '0'; mb_timer <= (others=>'0'); mbox_dead_i <= '0';
            else
                cmd_we := '0'; ack_we := '0';
                if we_shr_a='1' and shr_a_addr = "111111111110000"
                   and shr_a_din = x"5A5A" then cmd_we := '1'; end if;
                if we_shr_b='1' and e_addr(15 downto 1) = "111111111110001"
                   and e_do = x"4321" then ack_we := '1'; end if;
                if cmd_we='1' and mb_cmd_we_d='0' then
                    cmd5a_cnt <= cmd5a_cnt + 1;
                    if boot_flag = x"01" then
                        mb_wait <= '1'; mb_timer <= (others=>'0');
                    end if;
                end if;
                if ack_we='1' and mb_ack_we_d='0' then
                    ack_cnt <= ack_cnt + 1;
                    mb_wait <= '0';
                end if;
                if mb_wait='1' then
                    if mb_timer(25)='1' then
                        mbox_dead_i <= '1';   -- latched until the reset it causes
                    else
                        mb_timer <= mb_timer + 1;
                    end if;
                end if;
                mb_cmd_we_d <= cmd_we; mb_ack_we_d <= ack_we;
            end if;
        end if;
    end process;
    dbg_mbox_cnts <= std_logic_vector(cmd5a_cnt) & std_logic_vector(ack_cnt);
    mbox_dead     <= mbox_dead_i;

    -- LANE4s: per-frame bus-cycle meters. A real 7.16MHz 68000 completes a
    -- bus cycle in 4 clocks minimum; every wait state here shows up as a
    -- lower count. Compare against MAME's cycles/frame for ground truth.
    awr_meter : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                awr_ctr <= (others=>'0'); awr_fr <= (others=>'0'); awr_we_d <= '0'; vb_awr_d <= '0';
            else
                awr_we_d <= we_alpha; vb_awr_d <= vblank_in;
                if vblank_in='1' and vb_awr_d='0' then
                    awr_fr <= awr_ctr; awr_ctr <= (others=>'0');
                elsif we_alpha='1' and awr_we_d='0' then
                    awr_ctr <= awr_ctr + 1;
                end if;
            end if;
        end if;
    end process;
    dbg_awr <= std_logic_vector(awr_fr);

    cyc_meter : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                vcyc_ctr <= (others=>'0'); ecyc_ctr <= (others=>'0');
                vcyc_fr  <= (others=>'0'); ecyc_fr  <= (others=>'0');
                vas_d <= '1'; eas_d <= '1'; vb_cyc_d <= '0';
            else
                vas_d <= v_as_n; eas_d <= e_as_n; vb_cyc_d <= vblank_in;
                if vblank_in='1' and vb_cyc_d='0' then
                    vcyc_fr <= vcyc_ctr; ecyc_fr <= ecyc_ctr;
                    vcyc_ctr <= (others=>'0'); ecyc_ctr <= (others=>'0');
                else
                    if v_as_n='0' and vas_d='1' then vcyc_ctr <= vcyc_ctr + 1; end if;
                    if e_as_n='0' and eas_d='1' then ecyc_ctr <= ecyc_ctr + 1; end if;
                end if;
            end if;
        end if;
    end process;
    dbg_vcyc <= std_logic_vector(vcyc_fr);
    dbg_ecyc <= std_logic_vector(ecyc_fr);

    -- playfield / palette write activity probes (per bus write, not per cycle:
    -- count on the DTACK'd first cycle only via write-edge detect)
    pf_probe : process(clk)
        variable v_wr_d : std_logic := '0';
    begin
        if rising_edge(clk) then
            if v_wr='1' and v_wr_d='0' then          -- one count per CPU write cycle
                if v_sel_pf='1' and v_do /= x"0000" then
                    pf_wcnt <= std_logic_vector(unsigned(pf_wcnt) + 1);
                    pf_last <= v_do;
                end if;
                if v_sel_color='1' then
                    col_wcnt <= std_logic_vector(unsigned(col_wcnt) + 1);
                end if;
                -- 'tests done' flag $3F7F0C: written 1 when the self-test passes
                if v_sel_work='1' and v_addr(15 downto 1)&'0' = x"7F0C" then
                    boot_flag <= v_do(7 downto 0);
                end if;
            end if;
            v_wr_d := v_wr;
        end if;
    end process;
    dbg_pf_wcnt  <= pf_wcnt;
    dbg_pf_last  <= pf_last;
    dbg_col_wcnt <= col_wcnt;
    dbg_boot     <= boot_flag & std_logic_vector(reboot_cnt);
    rom_par_ok   <= '1' when PAR4_EN = 0 and parity32(rom_data) = rom_par else
                    '1' when PAR4_EN = 1
                             and (xor rom_data(31 downto 24)) = rom_par4(3)
                             and (xor rom_data(23 downto 16)) = rom_par4(2)
                             and (xor rom_data(15 downto 8))  = rom_par4(1)
                             and (xor rom_data(7 downto 0))   = rom_par4(0)
                             else '0';
    dbg_retry    <= std_logic_vector(retry_cnt);

    we_pf    <= v_wr and v_sel_pf;
    we_mo    <= v_wr and v_sel_mo;
    we_alpha <= v_wr and v_sel_alpha;
    we_work  <= v_wr and v_sel_work;
    we_pfpal <= v_wr and v_sel_pfpal;
    we_color <= v_wr and v_sel_color;
    we_cfg   <= v_wr and (v_sel_mobc or v_sel_slip);
    we_ee    <= v_wr and v_sel_eeprom;

    pf_ram    : entity work.dpram_bytelane_syn generic map ( awidth=>12 )
        port map ( clk=>clk,
                   addr_a=>v_addr(12 downto 1), din_a=>v_do,
                   we_a=>we_pf, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>pf_q,
                   addr_b=>pf_vaddr, din_b=>(others=>'0'),
                   we_b=>'0', uds_b_n=>'1', lds_b_n=>'1', q_b=>pf_vdata );
    mo_ram    : entity work.dpram_bytelane_syn generic map ( awidth=>12 )
        port map ( clk=>clk,
                   addr_a=>v_addr(12 downto 1), din_a=>v_do,
                   we_a=>we_mo, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>mo_q,
                   addr_b=>mo_vaddr, din_b=>(others=>'0'),
                   we_b=>'0', uds_b_n=>'1', lds_b_n=>'1', q_b=>mo_vdata );
    work_ram  : entity work.spram_bytelane generic map ( awidth=>13 )
        port map ( clk=>clk, addr=>v_addr(13 downto 1), din=>v_do, we=>we_work,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, q=>work_q );
    pfpal_ram : entity work.dpram_bytelane_syn generic map ( awidth=>12 )
        port map ( clk=>clk,
                   addr_a=>v_addr(12 downto 1), din_a=>v_do,
                   we_a=>we_pfpal, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>pfpal_q,
                   addr_b=>pfx_vaddr, din_b=>(others=>'0'),
                   we_b=>'0', uds_b_n=>'1', lds_b_n=>'1', q_b=>pfx_vdata );
    color_ram : entity work.dpram_bytelane_syn generic map ( awidth => 11 )
        port map ( clk=>clk,
                   addr_a=>v_addr(11 downto 1), din_a=>v_do,
                   we_a=>we_color, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>color_q,
                   addr_b=>color_vaddr, din_b=>(others=>'0'),
                   we_b=>'0', uds_b_n=>'1', lds_b_n=>'1', q_b=>color_vdata );
    cfg_ram   : entity work.dpram_bytelane_syn generic map ( awidth=>7 )
        port map ( clk=>clk,
                   addr_a=>v_addr(7 downto 1), din_a=>v_do,
                   we_a=>we_cfg, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>cfg_q,
                   addr_b=>cfg_vaddr, din_b=>(others=>'0'),
                   we_b=>'0', uds_b_n=>'1', lds_b_n=>'1', q_b=>cfg_vdata );
    ee_ram    : entity work.spram_bytelane
        generic map ( awidth=>9, initbyte=>x"FF" )    -- real 2804 = 512 bytes
        port map ( clk=>clk, addr=>v_addr(9 downto 1), din=>v_do, we=>we_ee,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, q=>ee_q );

    -- v58 hot-code shadows: 32K x 16 dpram each; port A = CPU fetch (read),
    -- port B = download fill. In-range fetches bypass the ROM arbiter and use
    -- the standard BRAM dtack path (+1 waitstate) - the proven-solid timing.
    -- v63: shadows narrowed 64KB -> 32KB to fit the new JSA shadow in the
    -- 308-M10K budget (fitter overflow at 64/64/64). Every hot address ever
    -- disassembled sits below 0x8000 on both CPUs: vectors, jump table $106,
    -- boot $694-$88A, IRQ6 $134C, dequeue $14A4, start-accept $39EE, input
    -- scan $F7E; extra-CPU reset/march/quiesce ($40586 = offset $586).
    -- LANE4o2: shadow1s narrowed 32KB -> 16KB to fund vshad3 (fitter hit
    -- the 308-M10K ceiling). Profile truth: gameplay uses 0x1000-0x2FFF
    -- (main) and page 0 (extra); all boot/ISR/march code sits below 0x4000
    -- on both CPUs (v58 hot-address inventory concurs).
    v_sel_shad1 <= '1' when SHAD_EN=1 and v_sel_rom='1'
                            and v_addr(23 downto 14) = "0000000000" else '0';
    v_sel_shad2 <= '1' when SHAD_EN=1 and v_sel_rom='1'
                            and v_addr(23 downto 15) = "000001001" else '0';
    v_sel_shad3 <= '1' when SHAD_EN=1 and v_sel_rom='1'
                            and v_addr(23 downto 15) = "000001010" else '0';
    -- MOSDRAM-72: MAME miss-profiles (attract incl. demo gameplay) put 77%
    -- of the extra's SDRAM reads in 0xA000-0xBFFF - eshad3 shadows it.
    -- (A matching main-CPU 0x46xxx shadow overflowed the 308-M10K ceiling;
    -- the extra is the starved CPU, so it kept the blocks.)
    v_sel_shad <= v_sel_shad1 or v_sel_shad2 or v_sel_shad3;
    e_sel_shad1 <= '1' when SHAD_EN=1 and e_sel_rom='1'
                            and e_addr(23 downto 14) = "0000000000" else '0';
    e_sel_shad2 <= '1' when SHAD_EN=1 and e_sel_rom='1'
                            and e_addr(23 downto 12) = x"00F" else '0';
    -- sdram-sched: no eshad3 here - this branch buys speed with the
    -- synchronizer cut instead of BRAM (the 308-M10K ceiling is spent).
    e_sel_shad <= e_sel_shad1 or e_sel_shad2;
    vshad_we  <= '1' when shad_we='1' and shad_waddr(23 downto 14) = "0000000000" else '0';
    vshad2_we <= '1' when shad_we='1' and shad_waddr(23 downto 15) = "000001001" else '0';
    vshad3_we <= '1' when shad_we='1' and shad_waddr(23 downto 15) = "000001010" else '0';
    eshad_we  <= '1' when shad_we='1' and shad_waddr(23 downto 14) = "0000100000" else '0';
    eshad2_we <= '1' when shad_we='1' and shad_waddr(23 downto 12) = x"08F" else '0';
    jshad_we <= '1' when shad_we='1' and shad_waddr(23 downto 16) = x"10" else '0';

    vshad : entity work.dpram_dc generic map ( awidth => 13 )
        port map ( wrclk=>shad_wclk, we=>vshad_we,
                   waddr=>shad_waddr(13 downto 1), wdata=>shad_wdata,
                   rdclk=>clk, raddr=>v_addr(13 downto 1), q=>vshad_q );
    eshad : entity work.dpram_dc generic map ( awidth => 13 )
        port map ( wrclk=>shad_wclk, we=>eshad_we,
                   waddr=>shad_waddr(13 downto 1), wdata=>shad_wdata,
                   rdclk=>clk, raddr=>e_addr(13 downto 1), q=>eshad_q );
    vshad2 : entity work.dpram_dc generic map ( awidth => 14 )
        port map ( wrclk=>shad_wclk, we=>vshad2_we,
                   waddr=>shad_waddr(14 downto 1), wdata=>shad_wdata,
                   rdclk=>clk, raddr=>v_addr(14 downto 1), q=>vshad2_q );
    vshad3 : entity work.dpram_dc generic map ( awidth => 14 )
        port map ( wrclk=>shad_wclk, we=>vshad3_we,
                   waddr=>shad_waddr(14 downto 1), wdata=>shad_wdata,
                   rdclk=>clk, raddr=>v_addr(14 downto 1), q=>vshad3_q );
    eshad2 : entity work.dpram_dc generic map ( awidth => 11 )
        port map ( wrclk=>shad_wclk, we=>eshad2_we,
                   waddr=>shad_waddr(11 downto 1), wdata=>shad_wdata,
                   rdclk=>clk, raddr=>e_addr(11 downto 1), q=>eshad2_q );

    -- v63: JSA shadow serves the whole 64KB sound ROM from BRAM.
    jshad : entity work.dpram_dc generic map ( awidth => 15 )
        port map ( wrclk=>shad_wclk, we=>jshad_we,
                   waddr=>shad_waddr(15 downto 1), wdata=>shad_wdata,
                   rdclk=>clk, raddr=>jshad_raddr, q=>jshad_q );

    -- two-word serve matching the SDRAM client protocol (data[31:16] = word
    -- at rom_addr, data[15:0] = word at rom_addr+2), 4-phase level handshake.
    -- BRAM read latency is one cycle, hence the capture states.
    jsa_shadow_serve : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                jsa_srv <= "000"; jsa_shad_ack <= '0';
            else
                case jsa_srv is
                    when "000" =>
                        if jsa_rom_req='1' and jsa_shad_ack='0' then
                            jshad_raddr <= jsa_rom_addr(15 downto 1);
                            jsa_srv <= "001";
                        elsif jsa_rom_req='0' then
                            jsa_shad_ack <= '0';
                        end if;
                    when "001" =>
                        jshad_raddr <= std_logic_vector(
                            unsigned(jsa_rom_addr(15 downto 1)) + 1);
                        jsa_srv <= "010";
                    when "010" =>
                        jsa_rom_data32(31 downto 16) <= jshad_q;
                        jsa_srv <= "011";
                    when "011" =>
                        jsa_rom_data32(15 downto 0) <= jshad_q;
                        jsa_shad_ack <= '1';
                        jsa_srv <= "100";
                    when others =>
                        if jsa_rom_req='0' then
                            jsa_shad_ack <= '0';
                            jsa_srv <= "000";
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- alpha RAM: dual-port so the video chain can read while the CPU writes
    alpha_ram : entity work.dpram_bytelane_syn generic map ( awidth => 11 )
        port map ( clk=>clk,
                   addr_a=>v_addr(11 downto 1), din_a=>v_do,
                   we_a=>we_alpha, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>alpha_q,
                   addr_b=>alpha_vaddr, din_b=>(others=>'0'),
                   we_b=>'0', uds_b_n=>'1', lds_b_n=>'1', q_b=>alpha_vq );
    alpha_vdata <= alpha_vq;

    -- probe alpha word 0x42: what the CPU wrote vs what scanout reads back.
    -- alpha_vq is valid one cycle after alpha_vaddr (registered BRAM address).
    a84_probe : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                a84_wr_i <= (others=>'0'); a84_rd_i <= (others=>'0');
                alpha_vaddr_d <= (others=>'0');
            else
                alpha_vaddr_d <= alpha_vaddr;
                if we_alpha='1' and v_addr(11 downto 1) = "00001000010" then
                    a84_wr_i <= v_do;
                end if;
                if alpha_vaddr_d = "00001000010" then
                    a84_rd_i <= alpha_vq;
                end if;
            end if;
        end if;
    end process;
    dbg_a84_wr <= a84_wr_i;
    dbg_a84_rd <= a84_rd_i;

    -- wedge locator: FC(1:0)="10" marks program-space reads (user or supervisor)
    pc_probe : process(clk)
        variable tramp_exp : std_logic_vector(15 downto 0);
        variable vec_exp   : std_logic_vector(15 downto 0);
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                pc_i <= (others=>'0'); wrhi_i <= (others=>'0');
            else
                if e_as_n='0' and e_rw_n='1' and e_fc(1)='1' and e_fc(0)='0' then
                    epc_i <= e_addr(15 downto 0);
                    if e_dtack_n='0' then                  -- completing: capture data
                        e_fdata_i <= e_di;
                    end if;
                    -- SDSCHED-77 trampoline watchdog (widened from 76's
                    -- single word): freezes jump off the extra's interrupt
                    -- dispatch table - '69 from slot 0x80C's operand, '76
                    -- session from slot 0x800's (wild_src=0x804). Compare
                    -- EVERY completed fetch of 0x800-0x823 against the ROM
                    -- truth; latch the FIRST impostor (root evidence), count
                    -- all. Cycling p1 display = re-corruption every dispatch.
                    -- SDSCHED-79: the VECTOR READS themselves (0x64-0x7F,
                    -- data reads - invisible to the trampoline trap). A
                    -- stale word here dispatches straight into the table
                    -- with the trampoline never touched = silent '78 freeze.
                    if e_dtack_n='0' and e_addr(23 downto 5) = "0000000000000000011"
                       and e_addr(4 downto 1) /= "0000" and e_addr(4 downto 1) /= "0001" then
                        -- words 0x64..0x7E; even-index = 0000, odd = 0300
                        -- except 0x72 = 0308 and 0x7A = 0306
                        if e_addr(1) = '0' then
                            vec_exp := x"0000";
                        elsif e_addr(4 downto 1) = "1001" then
                            vec_exp := x"0308";           -- 0x72
                        elsif e_addr(4 downto 1) = "1101" then
                            vec_exp := x"0306";           -- 0x7A
                        else
                            vec_exp := x"0300";
                        end if;
                        if e_di /= vec_exp and ewrong_cnt /= x"F" then
                            if ewrong_cnt = x"0" then
                                ewrong_val  <= e_di;
                                ewrong_prev <= e_lastrd;
                            end if;
                            ewrong_cnt <= ewrong_cnt + 1;
                        end if;
                    end if;
                    -- SDSCHED-81 replay forensic: remember the last completed
                    -- extra-CPU read address; pair it with any impostor.
                    if e_dtack_n='0' and e_rw_n='1' then
                        e_lastrd <= e_addr(16 downto 1);
                    end if;
                    if e_dtack_n='0' and e_addr(23 downto 6) = "000000000000100000"
                       and unsigned(e_addr(5 downto 1)) <= 17 then
                        case e_addr(5 downto 1) is
                            when "00000" | "00011" | "00110" | "01001" | "01100" | "01111" =>
                                tramp_exp := x"4EF9";   -- jmp opcodes
                            when "00001" | "00100" | "00111" | "01010" | "01101" | "10000" =>
                                tramp_exp := x"0000";   -- target hi words
                            when "00010" => tramp_exp := x"0970";
                            when "00101" => tramp_exp := x"08F6";
                            when "01000" | "01011" | "01110" => tramp_exp := x"0842";
                            when others  => tramp_exp := x"0994";  -- 0x822
                        end case;
                        if e_di /= tramp_exp and ewrong_cnt /= x"F" then
                            if ewrong_cnt = x"0" then
                                ewrong_val  <= e_di;
                                ewrong_prev <= e_lastrd;
                            end if;
                            ewrong_cnt <= ewrong_cnt + 1;
                        end if;
                    end if;
                    -- LANE4s wild-jump locator: the '69 freeze parks the
                    -- extra EXECUTING the 0xA58-0xB7F data table (all
                    -- harmless adda/suba encodings - no trap ever fires).
                    -- Latch the last fetch OUTSIDE the table on every entry;
                    -- once wedged inside, ewild_src = the jump-off point.
                    if e_addr(23 downto 16) = x"00"
                       and unsigned(e_addr(15 downto 0)) >= x"0A58"
                       and unsigned(e_addr(15 downto 0)) <= x"0B80" then
                        if e_in_tab = '0' then
                            ewild_src <= epc_i;
                            e_in_tab  <= '1';
                        end if;
                    else
                        e_in_tab <= '0';
                    end if;
                end if;
                if v_as_n='0' and v_rw_n='1' and v_fc(1)='1' and v_fc(0)='0' then
                    pc_i <= v_addr(15 downto 0);
                    if v_dtack_n='0' then                  -- completing: capture data
                        fdata_i <= v_di;
                        if v_sel_rom='1' then fsrc_i <= v_rom_src;
                        else fsrc_i <= "00"; end if;
                    end if;
                end if;
                if v_as_n='0' and v_rw_n='0' then
                    wrhi_i <= v_addr(23 downto 8);
                end if;
            end if;
        end if;
    end process;
    dbg_pc   <= pc_i;
    dbg_epc  <= epc_i;
    dbg_ewild  <= ewild_src;
    dbg_eintab <= e_in_tab;
    dbg_ewrong     <= ewrong_val;
    dbg_ewrong_cnt <= std_logic_vector(ewrong_cnt);
    dbg_ewrong_prev <= ewrong_prev & '0';
    dbg_wrhi <= wrhi_i;
    dbg_ecrash_pc   <= ecrash_pc_i;
    dbg_ecrash_data <= ecrash_data_i;
    dbg_erestart    <= std_logic_vector(e_restart_cnt);
    e_dead          <= e_dead_i;
    dbg_estall      <= std_logic_vector(e_cyc_max);

    -- LANE4l: bus-cycle duration tracker (saturating max)
    e_stall_watch : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                e_cyc_cur <= (others=>'0'); e_cyc_max <= (others=>'0');
            elsif e_as_n='0' then
                if e_cyc_cur /= x"FFFF" then
                    e_cyc_cur <= e_cyc_cur + 1;
                end if;
                if e_cyc_cur > e_cyc_max then
                    e_cyc_max <= e_cyc_cur;
                end if;
            else
                e_cyc_cur <= (others=>'0');
            end if;
        end if;
    end process;

    -- LANE4i: freeze-rescue detector. A live world engine fetches
    -- constantly; STOP produces zero bus cycles (IRQs masked at 2700, so
    -- no acks either). Gated on released + boot complete so the boot-time
    -- quiesce windows cannot trip it.
    e_dead_watch : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                e_idle_cnt <= (others=>'0'); e_dead_i <= '0';
            elsif boot_flag = x"01" and extra_release = '1' then
                if e_as_n = '1' then
                    if e_idle_cnt(22) = '1' then
                        e_dead_i <= '1';
                    else
                        e_idle_cnt <= e_idle_cnt + 1;
                    end if;
                else
                    e_idle_cnt <= (others=>'0');
                end if;
            else
                e_idle_cnt <= (others=>'0');
            end if;
        end if;
    end process;

    -- exception-vector probe + authentic watchdog timeout
    vec_wdog : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                vec_i <= (others=>'0'); wdog_ctr <= (others=>'0');
                wdog_expired_i <= '0'; fault_p <= '0'; vec_seen <= '0';
                ecrash_pc_i <= (others=>'0'); ecrash_data_i <= (others=>'0');
                e_vec_seen <= '0'; e_restart_cnt <= (others=>'0');
            else
                -- vector fetch = supervisor-data read (FC=101) below 0x400
                fault_p <= '0';
                if v_as_n='0' and v_rw_n='1' and v_fc="101"
                   and v_addr(23 downto 10)="00000000000000" then
                    vec_i <= "000000" & v_addr(9 downto 0);
                    -- LANE4h: armed only post-boot (checksum reads this region
                    -- as data during boot - see e-side comment)
                    if unsigned(v_addr(9 downto 0)) >= 8
                       and unsigned(v_addr(9 downto 0)) < 96 and vec_seen='0'
                       and boot_flag = x"01" then
                        fault_p <= '1'; vec_seen <= '1';  -- once per bus cycle pair
                    end if;
                elsif v_as_n='1' then
                    vec_seen <= '0';
                end if;
                -- LANE4h REWRITE. '56' device lesson: on a 68000 bus, vector
                -- fetches are indistinguishable from supervisor DATA reads of
                -- low memory - and the boot ROM CHECKSUM legitimately reads
                -- 0x008-0x05F as data on both CPUs, so the '4f/'4g trap
                -- latched checksum noise (the deterministic 0B8A/0044). Two
                -- fixes: (1) traps ARM only after the tests-done flag is set
                -- (boot_flag = 01: checksum long finished; runtime code has
                -- no business data-reading the vector region); (2) a RESTART
                -- COUNTER on the extra's reset-vector reads (0-7) - the new
                -- freeze front-runner is the extra RESTARTING mid-game
                -- (0xB00 churn = its march/checksum re-running, world state
                -- lost). Boot gives a small known count; an increment at the
                -- freeze moment confirms the restart in one photo.
                if e_as_n='0' and e_rw_n='1' and e_fc="101"
                   and e_addr(23 downto 10)="00000000000000" then
                    if unsigned(e_addr(9 downto 0)) < 8 then
                        if e_vec_seen='0' then
                            e_restart_cnt <= e_restart_cnt + 1;
                            e_vec_seen <= '1';
                        end if;
                    elsif unsigned(e_addr(9 downto 0)) < 96 and e_vec_seen='0'
                       and ecrash_pc_i = x"0000" and boot_flag = x"01" then
                        ecrash_pc_i   <= epc_i;
                        ecrash_data_i <= e_fdata_i;
                        e_vec_seen    <= '1';
                    end if;
                elsif e_as_n='1' then
                    e_vec_seen <= '0';
                end if;
                if v_sel_wdog='1' and v_as_n='0' and v_rw_n='0' then
                    wdog_ctr <= (others=>'0');
                elsif vblank_in='1' and vblank_d='0' then
                    if wdog_ctr = "111111" then
                        wdog_expired_i <= '1';   -- latched until the reset it causes
                    else
                        wdog_ctr <= wdog_ctr + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
    dbg_vec      <= vec_i;
    dbg_fault    <= fault_p;
    dbg_fdata    <= fdata_i;
    dbg_fsrc     <= fsrc_i;
    wdog_expired <= wdog_expired_i;

    ---------------------------------------------------------------- latches + IRQ
    latches : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                extra_release <= '0'; video_off <= '0'; intensity <= (others=>'0');
                virq <= '0'; vblank_d <= '0'; v_pc_seen <= '0';
                xscroll <= (others=>'0'); yscroll <= (others=>'0');
                xs_pend <= (others=>'0'); ys_pend <= (others=>'0');
            else
                vblank_d <= vblank_in;
                if vblank_in='1' and vblank_d='0' then
                    virq <= '1';
                    xscroll <= xs_pend;       -- v83: frame-latched scroll
                    yscroll <= ys_pend;
                end if;

                -- LANE3l: the EXTRA CPU acks vblank too. MAME's extra_map has
                -- video_int_ack_w at 360000 and clearing is shared: EITHER
                -- CPU's write drops IRQ4 for both. Our decode only listened
                -- to the video CPU; the extra's ack was swallowed by the
                -- catch-all dtack, so once gameplay enabled its IRQ4 the
                -- extra re-entered its ISR whenever its RTE beat the main
                -- CPU's ack - runaway exception frames, stack death, wild PC
                -- (the frozen mode-2 reading). Boot/self-test are IRQ-masked
                -- which is why the handshake always worked.
                if e_as_n='0' and e_rw_n='0'
                   and e_addr(23 downto 16) = x"36" and e_addr(5 downto 4) = "00"
                   and e_addr(3 downto 1) = "000" then                 -- LANE4j: exact
                    virq <= '0';                                       -- 360000 ack (extra)
                end if;

                if v_as_n='0' and v_rw_n='0' and v_sel_vctl='1' then
                    -- LANE4j: EXACT register widths (MAME eprom.cpp truth).
                    -- The old 16-byte-wide windows were THE mid-game restart
                    -- bug: MAME maps the run latch at the single byte 360011;
                    -- our whole-window decode let game writes to unmapped
                    -- 360012-1F stop the extra CPU (restart count 16 by
                    -- mid-game on '58' vs MAME's 2-at-boot; each stray stop =
                    -- self-test re-run = mid-game slow draws; one raced
                    -- handshake = THE FREEZE).
                    case v_addr(5 downto 4) is
                        when "00"   =>                                 -- 360000-01 only
                            if v_addr(3 downto 1)="000" then
                                virq <= '0';                           -- vblank ack
                            end if;
                        when "01"   =>                                 -- 360011 byte only
                            if v_addr(3 downto 1)="000" and v_lds_n='0' then
                                extra_release <= v_do(0);
                                -- count soft reboots: release cleared while set
                                if extra_release='1' and v_do(0)='0' then
                                    reboot_cnt <= reboot_cnt + 1;
                                end if;
                                intensity     <= v_do(4 downto 1);
                                video_off     <= v_do(5);
                            end if;
                        when "10"   => null;                           -- 360020: sound reset (pulse below)
                        when others => null;                           -- 360030: sound cmd (latched below)
                    end case;
                end if;

                if v_as_n='0' and v_addr(23 downto 0)=x"000694" then v_pc_seen <= '1'; end if;

                -- playfield scroll: latched from cfg writes (3F4F00 word0=X, word1=Y)
                if we_cfg='1' then
                    if v_addr(7 downto 1) = "0000000" then
                        xs_pend <= v_do(15 downto 7);
                    elsif v_addr(7 downto 1) = "0000001" then
                        ys_pend <= v_do(15 downto 7);
                    end if;
                end if;
            end if;
        end if;
    end process;
    ---------------------------------------------------------------- ADC0809
    -- Hall-effect joystick digitizer. A read of 260020+2n returns the last
    -- completed conversion in the low byte, then latches channel n (A2..A1)
    -- and starts a new one (the read strobe doubles as ALE/START; behavioral
    -- reference: MAME eprom adc_r = data_r + address_offset_start_w). 260027
    -- upward mirrors at +8. Conversion runs 64 ADC clocks at 14.318MHz/16 =
    -- 512 core clocks (~71.5 us); 260010 D4 (ADEOC) drops while busy. A start
    -- during a conversion restarts it on the new channel, data reg untouched.
    -- LANE4e: the ADC start strobe fires on EITHER CPU's read. The gameplay
    -- engine runs on the EXTRA 68k and polls the stick itself; with a v-side
    -- -only strobe the extra CPU read frozen adc_data (0x80 from boot) =
    -- buttons worked but Jake never moved, while the test-mode Control
    -- Inputs screen (main-CPU polled) showed live directions. On the real
    -- board the '0809 START/ALE strobes on any bus access - both CPUs share
    -- the bus through the arbiter.
    adc_rd <= '1' when (v_as_n='0' and v_rw_n='1' and v_sel_io='1'
                        and v_addr(5 downto 4)="10")
                    or (e_as_n='0' and e_rw_n='1' and e_sel_io='1'
                        and e_addr(5 downto 4)="10") else '0';

    adc_model : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                adc_data <= x"80"; adc_chan <= "00";
                adc_busy <= (others=>'0'); adc_rd_d <= '0';
            else
                adc_rd_d <= adc_rd;
                if adc_rd='1' and adc_rd_d='0' then          -- once per bus cycle
                    -- channel from whichever CPU is reading (e-side wins a tie)
                    if e_as_n='0' and e_rw_n='1' and e_sel_io='1'
                       and e_addr(5 downto 4)="10" then
                        adc_chan <= e_addr(2 downto 1);
                    else
                        adc_chan <= v_addr(2 downto 1);
                    end if;
                    adc_busy <= to_unsigned(512, adc_busy'length);
                elsif adc_busy /= 0 then
                    if adc_busy = 1 then                     -- conversion complete
                        case adc_chan is
                            when "00"   => adc_data <= adc_p1y;
                            when "01"   => adc_data <= adc_p1x;
                            when "10"   => adc_data <= adc_p2y;
                            when others => adc_data <= adc_p2x;
                        end case;
                    end if;
                    adc_busy <= adc_busy - 1;
                end if;
            end if;
        end if;
    end process;
    adc_eoc <= '1' when adc_busy = 0 else '0';

    ---------------------------------------------------------------- JSA-I sound board
    -- link strobes: level-per-bus-cycle is safe (data stable across the cycle;
    -- escape_jsa's full/NMI logic is edge-derived internally)
    -- LANE4j: exact widths here too (MAME: 360031 byte, 360020-21, 260031 byte)
    snd_cmd_we  <= '1' when v_wr='1' and v_sel_vctl='1'
                            and v_addr(5 downto 4)="11"
                            and v_addr(3 downto 1)="000" and v_lds_n='0' else '0';
    snd_res_p   <= '1' when v_wr='1' and v_sel_vctl='1'
                            and v_addr(5 downto 4)="10"
                            and v_addr(3 downto 1)="000" else '0';
    snd_resp_rd <= '1' when v_as_n='0' and v_rw_n='1' and v_sel_io='1'
                            and v_addr(5 downto 4)="11"
                            and v_addr(3 downto 1)="000" and v_lds_n='0' else '0';

    jsa : entity work.escape_jsa
        generic map ( YM_ENABLE => (YM_ENABLE = 1) )
        port map ( clk=>clk, reset_n=>reset_n, snd_res=>snd_res_p,
                   rom_addr=>jsa_rom_addr, rom_data=>jsa_rom_data32,
                   rom_req=>jsa_rom_req, rom_ack=>jsa_shad_ack,
                   cmd_data=>v_do(7 downto 0), cmd_we=>snd_cmd_we,
                   resp_data=>jsa_resp, resp_rd=>snd_resp_rd,
                   cmd_full=>jsa_cmd_full, resp_full=>jsa_resp_full,
                   snd_irq=>jsa_snd_irq,
                   coin1=>coin1, coin2=>coin2, test_mode=>not svc_n,
                   irq_strict=>irq_strict,
                   uvol_ym=>uvol_ym, uvol_tms=>uvol_tms,
                   audio_l=>audio_l, audio_r=>audio_r,
                   dbg_cpu_addr=>jsa_cpu_addr, dbg_cpu_sync=>open );

    -- JSA link observation: capture the last command byte at the write strobe
    jsa_obs : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                jsa_last_cmd <= (others=>'0');
            elsif snd_cmd_we='1' then
                jsa_last_cmd <= v_do(7 downto 0);
            end if;
        end if;
    end process;
    dbg_jsa_link <= jsa_cmd_full & jsa_resp_full & jsa_snd_irq & '0'
                    & x"0" & jsa_last_cmd;
    dbg_jsa_pc   <= jsa_cpu_addr;

    -- v61 coin-chain probes: count 68k response reads (frozen while
    -- resp_full is up = the game stopped listening to the JSA), latch the
    -- last response byte, count raw coin-line edges, and snoop the game's
    -- own credit counter (work-RAM byte $3F7F55, found via MAME watchpoint)
    coin_probe : process(clk)
    begin
        if rising_edge(clk) then
            resp_rd_d <= snd_resp_rd;
            -- v62: total read count proved healthy on device (frame-rate
            -- churn) while credits appeared with the displayed byte stuck
            -- 00 - the phantom bytes are a sub-frame burst. Count only
            -- NONZERO response bytes and hold the last one: if the count
            -- lands at ~6 right after boot with credits=6, the 6502's
            -- post-reset greeting is leaking into the coin parser, and the
            -- byte value names the leaking message.
            if snd_resp_rd='1' and resp_rd_d='0' and jsa_resp /= x"00" then
                resp_reads <= resp_reads + 1;
                resp_last  <= jsa_resp;
            end if;
            coin1_d <= coin1;
            coin2_d <= coin2;
            if (coin1='1' and coin1_d='0') or (coin2='1' and coin2_d='0') then
                coin_edges <= coin_edges + 1;
            end if;
            if v_as_n='0' and v_rw_n='0' and v_sel_work='1' and v_lds_n='0'
               and v_addr(15 downto 1)&'0' = x"7F54" then
                credits_sn <= v_do(7 downto 0);
            end if;
            -- LANE3r engine-state probes (MAME attract study): the actor
            -- table head word 3F5000 is 0x12xx-patterned when the demo/game
            -- engine has spawned actors, 0000 on art pages; mode bytes
            -- 3F7F16 (60 art / 54 demo) and 3F7F23 (18 art / 2a demo).
            if v_as_n='0' and v_rw_n='0' and v_sel_work='1'
               and v_addr(15 downto 1)&'0' = x"5000" then
                actorhead_sn <= v_do;
            end if;
            if v_as_n='0' and v_rw_n='0' and v_sel_work='1'
               and v_addr(15 downto 1)&'0' = x"7F16" and v_uds_n='0' then
                mode16_sn <= v_do(15 downto 8);
            end if;
            if v_as_n='0' and v_rw_n='0' and v_sel_work='1'
               and v_addr(15 downto 1)&'0' = x"7F22" and v_lds_n='0' then
                mode23_sn <= v_do(7 downto 0);
            end if;
        end if;
    end process;
    dbg_engine <= actorhead_sn;
    dbg_mode   <= mode16_sn & mode23_sn;
    dbg_resp_stat <= std_logic_vector(resp_reads) & resp_last;
    dbg_coin_cred <= std_logic_vector(coin_edges) & credits_sn;

    dbg_v_pc_fetch <= v_pc_seen;
    dbg_e_running  <= extra_release;
    intensity_out  <= intensity;
    video_off_out  <= video_off;
    xscroll_out    <= xscroll;
    yscroll_out    <= yscroll;

    -- ~0.15 s pulse stretcher on alpha-RAM writes so activity is visible on screen
    stretch : process(clk)
    begin
        if rising_edge(clk) then
            if we_alpha='1' then
                alpha_wr_stretch <= (others => '1');
            elsif alpha_wr_stretch /= 0 then
                alpha_wr_stretch <= alpha_wr_stretch - 1;
            end if;
        end if;
    end process;
    dbg_alpha_wr <= '1' when alpha_wr_stretch /= 0 else '0';

    ---------------------------------------------------------------- read muxes
    -- I/O: 260000 P1 (D11-D8), 260010 status+P2, 260020-2E ADC0809, 260030 SCOM
    v_di <= vshad3_q   when v_sel_shad3='1' else
            vshad2_q   when v_sel_shad2='1' else
            vshad_q    when v_sel_shad1='1' else
            v_rom_hold when v_sel_rom='1' else
            shr_qa   when v_sel_ram='1' else
            pf_q     when v_sel_pf='1' else
            mo_q     when v_sel_mo='1' else
            alpha_q  when v_sel_alpha='1' else
            -- (v61: the compare was a 15-bit literal that decoded as byte
            -- address FF0C, not 7F0C - Skip Self-Test could never match)
            x"0100"  when v_sel_work='1' and skip_test='1'
                          and v_addr(15 downto 1)&'0' = x"7F0C" else
            work_q   when v_sel_work='1' else
            pfpal_q  when v_sel_pfpal='1' else
            color_q  when v_sel_color='1' else
            cfg_q    when (v_sel_mobc='1' or v_sel_slip='1') else
            ee_q     when v_sel_eeprom='1' else
            -- 260000: P1 inputs on D11-D8 (duck/spare/fire/jump, active low);
            -- D0 = step/continue switch (active low)
            (x"F" & not p1_buttons & "1111111" & not step_btn)
                                             when v_sel_io='1' and v_addr(5 downto 4)="00" else
            -- 260010: P2 inputs + status: D4 ADEOC (conversion done, from the
            -- ADC model), D3 /SCBSY, D2 /SINT, D1 self-test lever, D0 /VBLANK
            (x"F" & not p2_buttons & "111" & adc_eoc & (not jsa_cmd_full) & (not jsa_resp_full)
             & svc_n & not vblank_in)
                                             when v_sel_io='1' and v_addr(5 downto 4)="01" else
            -- 260020-2E: ADC0809 result, low byte (read also selects/starts)
            (x"00" & adc_data) when v_sel_io='1' and v_addr(5 downto 4)="10" else
            (x"00" & jsa_resp) when v_sel_io='1' and v_addr(5 downto 4)="11" else
            x"0000" when v_sel_io='1' else
            (others => '0');

    -- LANE3q: the EXTRA CPU's IO reads were never decoded - every read of
    -- 260000/260010/ADC/SCOM returned 0x0000 (MAME's extra_map maps them
    -- all). Zeros meant: service lever ON, all buttons PRESSED (active
    -- low), ADC never done, JSA never ready. The extra's self-test made
    -- its skip/config decisions on that garbage, posted its handshake with
    -- no checksum results, and the main CPU painted 'Rom at 000000 error
    -- U L 0000' and flagged the second processor bad - the suspected
    -- game-start gate. Serve the extra the same port values as the main.
    e_di <= eshad2_q   when e_sel_shad2='1' else
            eshad_q    when e_sel_shad1='1' else
            e_rom_hold when e_sel_rom='1' else
            shr_qb   when e_sel_ram='1' else
            (x"F" & not p1_buttons & "1111111" & not step_btn)
                     when e_sel_io='1' and e_addr(5 downto 4)="00" else
            (x"F" & not p2_buttons & "111" & adc_eoc & (not jsa_cmd_full) & (not jsa_resp_full)
             & svc_n & not vblank_in)
                     when e_sel_io='1' and e_addr(5 downto 4)="01" else
            (x"00" & adc_data) when e_sel_io='1' and e_addr(5 downto 4)="10" else
            (x"00" & jsa_resp) when e_sel_io='1' and e_addr(5 downto 4)="11" else
            (others => '0');
    e_sel_io <= '1' when e_as_n='0' and e_addr(23 downto 16) = x"26" else '0';

    ---------------------------------------------------------------- DTACK
    dtack_gen : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                v_dtack_n <= '1'; e_dtack_n <= '1';
                v_ws <= '0'; e_ws <= '0';
                v_addr_q <= (others=>'0'); e_addr_q <= (others=>'0');
            else
                -- latch DTACK low until the CPU ends the bus cycle (AS high).
                -- Non-ROM accesses take one extra waitstate so the BRAM output
                -- has a full settled cycle in the read mux before capture.
                -- SDSCHED-78 STALE-SERVE FIX: the waitstate now restarts on
                -- ANY address change, not just on AS edges. TG68K's exception
                -- microcode can run bus cycles back-to-back without a clean
                -- AS gap; with e_ws still set, the next access got DTACK
                -- before the BRAM read mux reflected the new address - the
                -- CPU captured the PREVIOUS read's word. Caught in the act
                -- by the '77 trampoline watchdog: impostor 0x080C = the
                -- stack word an RTE had just read, served again as the
                -- first instruction fetch after it. Every freeze traced to
                -- this class. Address-qualified settle makes it impossible.
                v_addr_q <= v_addr(23 downto 1);
                e_addr_q <= e_addr(23 downto 1);
                if v_as_n='0' then
                    if v_fc = "111" then
                        v_dtack_n <= '1';        -- IACK: autovector via VPA only
                    elsif v_addr(23 downto 1) /= v_addr_q then
                        v_ws <= '0'; v_dtack_n <= '1';
                    elsif v_sel_rom='1' and v_sel_shad='0' then
                        if v_rom_dtack='1' then v_dtack_n <= '0'; end if;
                    elsif v_ws='1' then
                        v_dtack_n <= '0';
                    else
                        v_ws <= '1';
                    end if;
                else
                    v_dtack_n <= '1'; v_ws <= '0';
                end if;
                if e_as_n='0' then
                    if e_fc = "111" then
                        e_dtack_n <= '1';        -- IACK: autovector via VPA only
                    elsif e_addr(23 downto 1) /= e_addr_q then
                        e_ws <= '0'; e_dtack_n <= '1';
                    elsif e_sel_rom='1' and e_sel_shad='0' then
                        if e_rom_dtack='1' then e_dtack_n <= '0'; end if;
                    elsif e_ws='1' then
                        e_dtack_n <= '0';
                    else
                        e_ws <= '1';
                    end if;
                else
                    e_dtack_n <= '1'; e_ws <= '0';
                end if;
            end if;
        end if;
    end process;
end rtl;
