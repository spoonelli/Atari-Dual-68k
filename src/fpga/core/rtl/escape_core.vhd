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
    port (
        clk        : in  std_logic;   -- 7.159091 MHz (CPU + pixel domain)
        reset_n    : in  std_logic;   -- hold low until ROM image is in SDRAM

        -- external program ROM bus (combined-image byte offsets; word reads)
        rom_addr   : out std_logic_vector(23 downto 0);
        rom_data   : in  std_logic_vector(15 downto 0);
        rom_req    : out std_logic;
        rom_ack    : in  std_logic;

        -- raster position (from video counters in core_top for now)
        vblank_in  : in  std_logic;

        -- player inputs, active-high pressed (mapped to active-low bus bits)
        p1_buttons : in  std_logic_vector(3 downto 0);  -- D11 duck..D8 start
        p2_buttons : in  std_logic_vector(3 downto 0);

        -- video-side read ports + latches for the video chain
        alpha_vaddr : in  std_logic_vector(10 downto 0) := (others => '0');
        alpha_vdata : out std_logic_vector(15 downto 0);
        color_vaddr : in  std_logic_vector(10 downto 0) := (others => '0');
        color_vdata : out std_logic_vector(15 downto 0);
        intensity_out : out std_logic_vector(3 downto 0);
        video_off_out : out std_logic;

        -- debug/observation
        dbg_v_pc_fetch : out std_logic;
        dbg_e_running  : out std_logic;
        dbg_alpha_wr   : out std_logic
    );
end escape_core;

architecture rtl of escape_core is
    signal v_addr : std_logic_vector(31 downto 0);
    signal v_do, v_di : std_logic_vector(15 downto 0);
    signal v_as_n, v_uds_n, v_lds_n, v_rw_n : std_logic;
    signal v_dtack_n : std_logic;
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
    signal e_sel_rom, e_sel_ram : std_logic;
    signal e_unused : std_logic_vector(12 downto 0);

    signal extra_release, video_off : std_logic;
    signal intensity : std_logic_vector(3 downto 0);
    signal virq, vblank_d, v_pc_seen : std_logic;

    type rom_owner_t is (OWN_IDLE, OWN_V, OWN_E);
    signal rom_owner : rom_owner_t;
    signal last_was_v : std_logic;   -- fair round-robin: alternate priority
    signal rom_addr_i : std_logic_vector(23 downto 0);
    signal rom_req_i  : std_logic;
    signal v_rom_pend, e_rom_pend, v_rom_dtack, e_rom_dtack : std_logic;
    signal v_rom_hold, e_rom_hold : std_logic_vector(15 downto 0);

    signal shr_qa, shr_qb : std_logic_vector(15 downto 0);
    signal pf_q, mo_q, alpha_q, work_q, pfpal_q, color_q, cfg_q, ee_q : std_logic_vector(15 downto 0);
    signal we_pf, we_mo, we_alpha, we_work, we_pfpal, we_color, we_cfg, we_ee : std_logic;
    signal v_wr, we_shr_a, we_shr_b : std_logic;
    signal alpha_wr_stretch : unsigned(19 downto 0);
begin
    ---------------------------------------------------------------- CPUs
    -- 68010 per schematic sheet 4 (45J "U68010"); autovectored IRQs via VPA
    vcpu : entity work.TG68K generic map ( CPU => "01" )
        port map ( CLK=>clk, RESET=>reset_n, HALT=>reset_n, BERR=>'0', IPL=>v_ipl,
                   ADDR=>v_addr, FC=>v_fc, DATAI=>v_di, DATAO=>v_do,
                   AS=>v_as_n, UDS=>v_uds_n, LDS=>v_lds_n, RW=>v_rw_n,
                   DTACK=>v_dtack_n, E=>open, VPA=>v_vpa_n, VMA=>open );

    e_resn <= reset_n and extra_release;
    -- also a 68010 per schematic sheet 5 (20P "U68010")
    ecpu : entity work.TG68K generic map ( CPU => "01" )
        port map ( CLK=>clk, RESET=>e_resn, HALT=>e_resn, BERR=>'0', IPL=>e_ipl,
                   ADDR=>e_addr, FC=>e_fc, DATAI=>e_di, DATAO=>e_do,
                   AS=>e_as_n, UDS=>e_uds_n, LDS=>e_lds_n, RW=>e_rw_n,
                   DTACK=>e_dtack_n, E=>open, VPA=>e_vpa_n, VMA=>open );

    v_ipl <= "011" when virq='1' else "111";     -- IRQ4 (IPL active low)
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
    v_rom_pend <= '1' when v_sel_rom='1' and v_as_n='0' else '0';
    e_rom_pend <= '1' when e_sel_rom='1' and e_as_n='0' else '0';

    rom_arb : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                rom_owner <= OWN_IDLE; rom_req_i <= '0'; last_was_v <= '0';
                v_rom_dtack <= '0'; e_rom_dtack <= '0';
            else
                v_rom_dtack <= '0'; e_rom_dtack <= '0';
                case rom_owner is
                    when OWN_IDLE =>
                        -- fair round-robin: whoever was NOT served last gets priority,
                        -- otherwise the video CPU's constant fetch stream starves the
                        -- extra CPU (observed on hardware as an ERESET retry loop)
                        if rom_ack='1' then
                            null;                        -- wait out previous ack (4-phase)
                        elsif e_rom_pend='1' and (last_was_v='1' or v_rom_pend='0') then
                            rom_owner <= OWN_E; last_was_v <= '0';
                            rom_addr_i <= std_logic_vector(
                                unsigned(x"0" & e_addr(19 downto 1) & '0') + x"080000");
                            rom_req_i <= '1';
                        elsif v_rom_pend='1' then
                            rom_owner <= OWN_V; last_was_v <= '1';
                            rom_addr_i <= x"0" & v_addr(19 downto 1) & '0';
                            rom_req_i <= '1';
                        end if;
                    when OWN_V =>
                        if v_as_n='1' then                       -- CPU ended cycle: abort
                            rom_req_i <= '0'; rom_owner <= OWN_IDLE;
                        elsif rom_ack='1' then
                            rom_req_i <= '0'; v_rom_hold <= rom_data;
                            v_rom_dtack <= '1'; rom_owner <= OWN_IDLE;
                        end if;
                    when OWN_E =>
                        if e_as_n='1' then
                            rom_req_i <= '0'; rom_owner <= OWN_IDLE;
                        elsif rom_ack='1' then
                            rom_req_i <= '0'; e_rom_hold <= rom_data;
                            e_rom_dtack <= '1'; rom_owner <= OWN_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;
    rom_addr <= rom_addr_i;
    rom_req  <= rom_req_i;

    ---------------------------------------------------------------- memories
    v_wr     <= '1' when v_as_n='0' and v_rw_n='0' else '0';
    we_shr_a <= v_wr and v_sel_ram;
    we_shr_b <= '1' when e_as_n='0' and e_rw_n='0' and e_sel_ram='1' else '0';

    shared_ram : entity work.dpram_bytelane_syn generic map ( awidth => 15 )
        port map ( clk=>clk,
                   addr_a=>v_addr(15 downto 1), din_a=>v_do,
                   we_a=>we_shr_a, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>shr_qa,
                   addr_b=>e_addr(15 downto 1), din_b=>e_do,
                   we_b=>we_shr_b, uds_b_n=>e_uds_n, lds_b_n=>e_lds_n, q_b=>shr_qb );

    we_pf    <= v_wr and v_sel_pf;
    we_mo    <= v_wr and v_sel_mo;
    we_alpha <= v_wr and v_sel_alpha;
    we_work  <= v_wr and v_sel_work;
    we_pfpal <= v_wr and v_sel_pfpal;
    we_color <= v_wr and v_sel_color;
    we_cfg   <= v_wr and (v_sel_mobc or v_sel_slip);
    we_ee    <= v_wr and v_sel_eeprom;

    pf_ram    : entity work.spram_bytelane generic map ( awidth=>12 )
        port map ( clk=>clk, addr=>v_addr(12 downto 1), din=>v_do, we=>we_pf,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, q=>pf_q );
    mo_ram    : entity work.spram_bytelane generic map ( awidth=>12 )
        port map ( clk=>clk, addr=>v_addr(12 downto 1), din=>v_do, we=>we_mo,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, q=>mo_q );
    work_ram  : entity work.spram_bytelane generic map ( awidth=>13 )
        port map ( clk=>clk, addr=>v_addr(13 downto 1), din=>v_do, we=>we_work,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, q=>work_q );
    pfpal_ram : entity work.spram_bytelane generic map ( awidth=>12 )
        port map ( clk=>clk, addr=>v_addr(12 downto 1), din=>v_do, we=>we_pfpal,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, q=>pfpal_q );
    color_ram : entity work.dpram_bytelane_syn generic map ( awidth => 11 )
        port map ( clk=>clk,
                   addr_a=>v_addr(11 downto 1), din_a=>v_do,
                   we_a=>we_color, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>color_q,
                   addr_b=>color_vaddr, din_b=>(others=>'0'),
                   we_b=>'0', uds_b_n=>'1', lds_b_n=>'1', q_b=>color_vdata );
    cfg_ram   : entity work.spram_bytelane generic map ( awidth=>7 )
        port map ( clk=>clk, addr=>v_addr(7 downto 1), din=>v_do, we=>we_cfg,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, q=>cfg_q );
    ee_ram    : entity work.spram_bytelane generic map ( awidth=>13 )
        port map ( clk=>clk, addr=>v_addr(13 downto 1), din=>v_do, we=>we_ee,
                   uds_n=>v_uds_n, lds_n=>v_lds_n, q=>ee_q );

    -- alpha RAM: dual-port so the video chain can read while the CPU writes
    alpha_ram : entity work.dpram_bytelane_syn generic map ( awidth => 11 )
        port map ( clk=>clk,
                   addr_a=>v_addr(11 downto 1), din_a=>v_do,
                   we_a=>we_alpha, uds_a_n=>v_uds_n, lds_a_n=>v_lds_n, q_a=>alpha_q,
                   addr_b=>alpha_vaddr, din_b=>(others=>'0'),
                   we_b=>'0', uds_b_n=>'1', lds_b_n=>'1', q_b=>alpha_vdata );

    ---------------------------------------------------------------- latches + IRQ
    latches : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                extra_release <= '0'; video_off <= '0'; intensity <= (others=>'0');
                virq <= '0'; vblank_d <= '0'; v_pc_seen <= '0';
            else
                vblank_d <= vblank_in;
                if vblank_in='1' and vblank_d='0' then virq <= '1'; end if;

                if v_as_n='0' and v_rw_n='0' and v_sel_vctl='1' then
                    case v_addr(5 downto 4) is
                        when "00"   => virq <= '0';                    -- 360000 vblank ack
                        when "01"   => extra_release <= v_do(0);       -- 360010 latch
                                       intensity     <= v_do(4 downto 1);
                                       video_off     <= v_do(5);
                        when others => null;                           -- 360020/30: sound (stub)
                    end case;
                end if;

                if v_as_n='0' and v_addr(23 downto 0)=x"000694" then v_pc_seen <= '1'; end if;
            end if;
        end if;
    end process;
    dbg_v_pc_fetch <= v_pc_seen;
    dbg_e_running  <= extra_release;
    intensity_out  <= intensity;
    video_off_out  <= video_off;

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
    -- I/O: 260000 P1 (D11-D8), 260010 status+P2, 260020-26 ADC (centered), 260030 SCOM
    v_di <= v_rom_hold when v_sel_rom='1' else
            shr_qa   when v_sel_ram='1' else
            pf_q     when v_sel_pf='1' else
            mo_q     when v_sel_mo='1' else
            alpha_q  when v_sel_alpha='1' else
            work_q   when v_sel_work='1' else
            pfpal_q  when v_sel_pfpal='1' else
            color_q  when v_sel_color='1' else
            cfg_q    when (v_sel_mobc='1' or v_sel_slip='1') else
            ee_q     when v_sel_eeprom='1' else
            -- 260000: P1 inputs on D11-D8 (duck/spare/fire/jump, active low)
            (x"F" & not p1_buttons & x"FF")  when v_sel_io='1' and v_addr(5 downto 4)="00" else
            -- 260010: P2 inputs + status: D4 ADEOC=1(done), D3 /SCBSY=1(idle),
            -- D2 /SINT=1(no snd irq), D1 S-TEST=1(normal play), D0 /VBLANK
            (x"F" & not p2_buttons & "1111" & "111" & not vblank_in)
                                             when v_sel_io='1' and v_addr(5 downto 4)="01" else
            x"0080" when v_sel_io='1' and v_addr(5 downto 4)="10" else
            x"0000" when v_sel_io='1' else
            (others => '0');

    e_di <= e_rom_hold when e_sel_rom='1' else
            shr_qb   when e_sel_ram='1' else
            (others => '0');

    ---------------------------------------------------------------- DTACK
    dtack_gen : process(clk)
    begin
        if rising_edge(clk) then
            if reset_n='0' then
                v_dtack_n <= '1'; e_dtack_n <= '1';
            else
                -- latch DTACK low until the CPU ends the bus cycle (AS high)
                if v_as_n='0' then
                    if v_sel_rom='1' then
                        if v_rom_dtack='1' then v_dtack_n <= '0'; end if;
                    else
                        v_dtack_n <= '0';
                    end if;
                else
                    v_dtack_n <= '1';
                end if;
                if e_as_n='0' then
                    if e_sel_rom='1' then
                        if e_rom_dtack='1' then e_dtack_n <= '0'; end if;
                    else
                        e_dtack_n <= '0';
                    end if;
                else
                    e_dtack_n <= '1';
                end if;
            end if;
        end if;
    end process;
end rtl;
