-- ee_save: non-volatile backing for the game's 2804 EEPROM (high scores and
-- operator settings) using the Analogue Pocket APF "nonvolatile data slot"
-- mechanism.
--
-- THE APF CONTRACT (derived from src/fpga/apf/* and Analogue's developer docs;
-- see docs/EEPROM_SAVE.md for the full citation trail):
--
--   * A data slot declared nonvolatile in data.json gets its file contents
--     written into the core's BRIDGE address space at the slot's `address`
--     during startup ([0082 Data slot request write], then plain bridge writes,
--     then [008F Data slot access all complete]).
--   * At shutdown APF sends [0080 Data slot request read] for each nonvolatile
--     slot and then READS that same bridge window back out, byte for byte, and
--     writes the file. The core must have valid data there by then.
--   * A core may also push a slot to disk at any time with target command
--     [0184 Data slot write] (target_dataslot_write in core_bridge_cmd.v),
--     naming a bridge address + length that APF reads from.
--   * Bridge reads are BUFFERED BY ONE WORD: "upon receiving a read the core
--     may not immediately provide the read data and has until the next read
--     strobe to drive bridge_rd_data". Analogue's own core_bridge_cmd.v
--     implements exactly that - it latches the word for the CURRENT
--     bridge_addr on the bridge_rd strobe. This module does the same.
--
-- STRUCTURE. Two 128 x 32 simple-dual-port buffers straddle the clock domains,
-- each written in one domain and read in the other (the proven dpram_dc shape):
--
--     dlbuf  bridge writes (clk_74a)  ->  restore engine (core clk)   [load]
--     ulbuf  snapshot engine (core clk) -> bridge reads (clk_74a)     [save]
--
-- and a single core-clock FSM owns port B of the game's EEPROM BRAM:
--
--     restore   dlbuf -> EEPROM,  once, while the core is still in reset
--     snapshot  EEPROM -> ulbuf,  on demand
--
-- Snapshots are triggered two ways, both of which end with ulbuf holding a
-- complete, self-consistent 512-byte image:
--
--     b_snapreq  APF is about to read the slot (shutdown). The caller holds
--                dataslot_requestread_ack low until b_snapdone comes back, so
--                APF cannot read a half-built buffer. Bounded: the FSM always
--                terminates, and the caller times the handshake out anyway.
--     autosave   the CPU wrote the EEPROM and then left it alone for
--                2**IDLE_BITS core clocks (~1.2 s at 7.159 MHz). The FSM
--                snapshots and raises b_savereq; the caller turns that into a
--                [0184 Data slot write]. This is what makes a high score
--                survive an ungraceful power-off rather than only a clean exit.
--
-- SAFETY PROPERTIES (see docs/EEPROM_SAVE.md for the argument in full):
--   * Nothing here can stall the game. The FSM only touches port B of the
--     EEPROM BRAM; the 68000s use port A and never wait on this logic. If APF
--     never services a save, b_savereq simply stays up (the caller times it
--     out) and the game runs on untouched.
--   * An interrupted save cannot corrupt the stored EEPROM. The game's live
--     copy is BRAM and is never written except by the CCPU and by the one-shot
--     restore. A save that dies half-way leaves the previous file on the SD
--     card - APF either wrote the whole 512 bytes or it did not.
--   * A save that races a CPU write cannot lose that write: `dirty` is cleared
--     when a snapshot STARTS, and any write during the snapshot sets it again,
--     scheduling another save.
--   * With no save file present the caller reports b_loaded = '0', the restore
--     is skipped, and the EEPROM keeps its x"FF" power-on fill - a virgin 2804,
--     which is what makes the game write its factory defaults.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ee_save is
    generic (
        -- write-idle delay before an autosave, in core clocks (2**IDLE_BITS).
        -- 23 = ~1.17 s at 7.159 MHz: long enough that the game has finished a
        -- burst of EEPROM stores, short enough to beat a power-off.
        IDLE_BITS : integer := 23
    );
    port (
        -- ===================== APF bridge domain (clk_74a) =====================
        bclk        : in  std_logic;
        b_sel       : in  std_logic;                     -- bridge_addr in our window
        b_wr        : in  std_logic;                     -- bridge_wr
        b_rd        : in  std_logic;                     -- bridge_rd
        b_addr      : in  std_logic_vector(6 downto 0);  -- bridge_addr[8:2], word index
        b_wdata     : in  std_logic_vector(31 downto 0);
        b_rdata     : out std_logic_vector(31 downto 0);
        b_loaded    : out std_logic;   -- sticky: APF wrote our window at least once
        b_allcomp   : in  std_logic;   -- dataslot_allcomplete (raw, synced inside)
        b_snapreq   : in  std_logic;   -- level: refresh ulbuf, APF wants to read
        b_snapdone  : out std_logic;   -- level: ulbuf is fresh
        b_savereq   : out std_logic;   -- level: please issue [0184 Data slot write]
        b_saveack   : in  std_logic;   -- level: that write finished (or timed out)

        -- ======================= core domain (7.159 MHz) =======================
        cclk        : in  std_logic;
        c_ready     : out std_logic;   -- restore finished; safe to release core reset
        c_autoen    : in  std_logic;   -- '1' = autosave enabled
        c_wrpulse   : in  std_logic;   -- CPU wrote an EEPROM byte this cycle
        -- port B of the EEPROM BRAM inside escape_core
        c_addr      : out std_logic_vector(8 downto 0);
        c_din       : out std_logic_vector(7 downto 0);
        c_we        : out std_logic;
        c_q         : in  std_logic_vector(7 downto 0);
        -- diagnostics for the on-screen HUD (core domain)
        c_savecnt   : out std_logic_vector(7 downto 0);  -- completed autosaves
        c_dirty     : out std_logic                      -- unsaved EEPROM writes
    );
end ee_save;

architecture rtl of ee_save is

    type buf_t is array(0 to 127) of std_logic_vector(31 downto 0);
    -- virgin fill = FF, matching the erased 2804 that spram_bytelane models
    shared variable dlbuf : buf_t := (others => (others => '1'));
    shared variable ulbuf : buf_t := (others => (others => '1'));

    -- BUILD 103: the design sits exactly at the Pocket Cyclone V's 308-M10K
    -- ceiling, so these two 4 Kbit buffers MUST NOT infer block RAM -- doing so
    -- is what failed the first 103 fit (Error 170048), the same wall that killed
    -- builds 72/72b/72c. Force them into MLABs (ALM-based LUTRAM), which is a
    -- resource class this design is not short of. 128x32 = 8 MLABs each.
    attribute ramstyle : string;
    attribute ramstyle of dlbuf : variable is "MLAB";
    attribute ramstyle of ulbuf : variable is "MLAB";

    -- ---- bclk side
    signal dl_seen_b  : std_logic := '0';
    signal ul_raddr_b : std_logic_vector(6 downto 0)  := (others => '0');
    signal ul_q_b     : std_logic_vector(31 downto 0) := (others => '1');
    signal b_rdata_r  : std_logic_vector(31 downto 0) := (others => '1');

    -- ---- cclk side
    signal dl_raddr_c : std_logic_vector(6 downto 0)  := (others => '0');
    signal dl_q_c     : std_logic_vector(31 downto 0) := (others => '1');
    signal ul_we_c    : std_logic := '0';
    signal ul_waddr_c : std_logic_vector(6 downto 0)  := (others => '0');
    signal ul_wdata_c : std_logic_vector(31 downto 0) := (others => '0');

    -- ---- clock-domain crossings (3-FF, the synch_3 shape used everywhere else)
    signal ac_sy, sr_sy, sa_sy, dl_sy : std_logic_vector(2 downto 0) := "000";
    signal sd_sy, sq_sy               : std_logic_vector(2 downto 0) := "000";

    -- ---- FSM
    type st_t is (S_BOOT, S_RD0, S_RD1, S_RD2, S_RD3,
                  S_RDY, S_IDLE, S_SN0, S_SN1, S_SN2, S_SNDONE);
    signal st        : st_t := S_BOOT;
    signal idx       : unsigned(9 downto 0) := (others => '0');   -- 0..511
    signal acc       : std_logic_vector(31 downto 0) := (others => '0');
    signal kind_exit : std_logic := '0';        -- '1' = snapshot for APF readback
    signal snapdone_c: std_logic := '0';
    signal savereq_c : std_logic := '0';
    signal dirty     : std_logic := '0';
    signal idle_ctr  : unsigned(IDLE_BITS-1 downto 0) := (others => '0');
    signal savecnt   : unsigned(7 downto 0) := (others => '0');
    signal ready_c   : std_logic := '0';

    constant IDLE_MAX : unsigned(IDLE_BITS-1 downto 0) := (others => '1');

    -- big-endian byte select: file byte 4W+0 lives in bits 31..24
    function bsel(w : std_logic_vector(31 downto 0);
                  k : unsigned(1 downto 0)) return std_logic_vector is
    begin
        case k is
            when "00"   => return w(31 downto 24);
            when "01"   => return w(23 downto 16);
            when "10"   => return w(15 downto  8);
            when others => return w( 7 downto  0);
        end case;
    end function;

begin

    ------------------------------------------------------------------
    -- bclk: APF writes the save file into dlbuf; APF reads ulbuf back
    ------------------------------------------------------------------
    b_wr_p : process(bclk)
    begin
        if rising_edge(bclk) then
            if b_sel = '1' and b_wr = '1' then
                dlbuf(to_integer(unsigned(b_addr))) := b_wdata;
            end if;
        end if;
    end process;

    b_seen_p : process(bclk)
    begin
        if rising_edge(bclk) then
            if b_sel = '1' and b_wr = '1' then
                dl_seen_b <= '1';
            end if;
        end if;
    end process;

    -- Address is tracked unconditionally (exactly what core_bridge_cmd.v does
    -- with b_datatable_addr), so the BRAM output is settled long before the
    -- read strobe; bridge_rd then latches the word for the CURRENT address.
    b_rd_p : process(bclk)
    begin
        if rising_edge(bclk) then
            ul_raddr_b <= b_addr;
            ul_q_b     <= ulbuf(to_integer(unsigned(ul_raddr_b)));
            if b_rd = '1' then
                b_rdata_r <= ul_q_b;
            end if;
        end if;
    end process;

    b_rdata  <= b_rdata_r;
    b_loaded <= dl_seen_b;

    ------------------------------------------------------------------
    -- clock-domain crossings
    ------------------------------------------------------------------
    cdc_c : process(cclk)
    begin
        if rising_edge(cclk) then
            ac_sy <= ac_sy(1 downto 0) & b_allcomp;
            sr_sy <= sr_sy(1 downto 0) & b_snapreq;
            sa_sy <= sa_sy(1 downto 0) & b_saveack;
            dl_sy <= dl_sy(1 downto 0) & dl_seen_b;
        end if;
    end process;

    cdc_b : process(bclk)
    begin
        if rising_edge(bclk) then
            sd_sy <= sd_sy(1 downto 0) & snapdone_c;
            sq_sy <= sq_sy(1 downto 0) & savereq_c;
        end if;
    end process;

    b_snapdone <= sd_sy(2);
    b_savereq  <= sq_sy(2);

    ------------------------------------------------------------------
    -- core clock: dlbuf read port, ulbuf write port
    ------------------------------------------------------------------
    c_dlrd_p : process(cclk)
    begin
        if rising_edge(cclk) then
            dl_q_c <= dlbuf(to_integer(unsigned(dl_raddr_c)));
        end if;
    end process;

    c_ulwr_p : process(cclk)
    begin
        if rising_edge(cclk) then
            if ul_we_c = '1' then
                ulbuf(to_integer(unsigned(ul_waddr_c))) := ul_wdata_c;
            end if;
        end if;
    end process;

    ------------------------------------------------------------------
    -- core clock: the one FSM that owns EEPROM port B
    ------------------------------------------------------------------
    fsm_p : process(cclk)
        variable v_acc : std_logic_vector(31 downto 0);
    begin
        if rising_edge(cclk) then
            c_we    <= '0';
            ul_we_c <= '0';

            -- write-idle timer (re-armed after the case below by c_wrpulse)
            if c_wrpulse = '0' and idle_ctr /= IDLE_MAX then
                idle_ctr <= idle_ctr + 1;
            end if;

            case st is

                -- wait for APF to finish loading every slot, then restore
                when S_BOOT =>
                    if ac_sy(2) = '1' then
                        idx <= (others => '0');
                        if dl_sy(2) = '1' then
                            st <= S_RD0;        -- a save file was loaded
                        else
                            st <= S_RDY;        -- none: leave the virgin FFs
                        end if;
                    end if;

                -- ---- restore: dlbuf -> EEPROM, one byte per 4 clocks
                when S_RD0 =>
                    dl_raddr_c <= std_logic_vector(idx(8 downto 2));
                    st <= S_RD1;
                when S_RD1 =>
                    st <= S_RD2;                -- dl_q_c settles during this state
                when S_RD2 =>
                    c_addr <= std_logic_vector(idx(8 downto 0));
                    c_din  <= bsel(dl_q_c, idx(1 downto 0));
                    c_we   <= '1';
                    st <= S_RD3;
                when S_RD3 =>
                    if idx = 511 then
                        st <= S_RDY;
                    else
                        idx <= idx + 1;
                        st  <= S_RD0;
                    end if;

                when S_RDY =>
                    ready_c <= '1';
                    dirty   <= '0';             -- the restore itself is not a change
                    st <= S_IDLE;

                when S_IDLE =>
                    if sr_sy(2) = '1' and snapdone_c = '0' and savereq_c = '0' then
                        -- APF is about to read the slot: refresh it now
                        kind_exit <= '1';
                        idx <= (others => '0');
                        acc <= (others => '0');
                        dirty <= '0';
                        st <= S_SN0;
                    elsif savereq_c = '1' then
                        -- finish the 4-phase handshake with the bridge side
                        if sa_sy(2) = '1' then
                            savereq_c <= '0';
                        end if;
                    elsif c_autoen = '1' and dirty = '1' and idle_ctr = IDLE_MAX
                          and sr_sy(2) = '0' then
                        kind_exit <= '0';
                        idx <= (others => '0');
                        acc <= (others => '0');
                        dirty <= '0';
                        st <= S_SN0;
                    end if;

                -- ---- snapshot: EEPROM -> ulbuf, one byte per 3 clocks
                when S_SN0 =>
                    c_addr <= std_logic_vector(idx(8 downto 0));
                    st <= S_SN1;
                when S_SN1 =>
                    st <= S_SN2;                -- c_q settles during this state
                when S_SN2 =>
                    v_acc := acc(23 downto 0) & c_q;
                    acc   <= v_acc;
                    if idx(1 downto 0) = "11" then
                        ul_waddr_c <= std_logic_vector(idx(8 downto 2));
                        ul_wdata_c <= v_acc;
                        ul_we_c    <= '1';
                    end if;
                    if idx = 511 then
                        st <= S_SNDONE;
                    else
                        idx <= idx + 1;
                        st  <= S_SN0;
                    end if;

                when S_SNDONE =>
                    if kind_exit = '1' then
                        snapdone_c <= '1';
                    else
                        savereq_c <= '1';
                        savecnt   <= savecnt + 1;
                    end if;
                    st <= S_IDLE;

            end case;

            -- release the exit handshake once APF drops the request
            if sr_sy(2) = '0' then
                snapdone_c <= '0';
            end if;

            -- A CPU write always wins the race against a snapshot start, so a
            -- store that lands mid-snapshot schedules another save instead of
            -- being silently dropped.
            if c_wrpulse = '1' then
                idle_ctr <= (others => '0');
                if ready_c = '1' then
                    dirty <= '1';
                end if;
            end if;
        end if;
    end process;

    c_ready   <= ready_c;
    c_savecnt <= std_logic_vector(savecnt);
    c_dirty   <= dirty;

end rtl;
