-- Sim-only inert stand-in for escape_jsa, analyzed AFTER the real one by
-- run_vecrace.sh so it wins elaboration. The vecrace bench hunts an
-- extra-68k interrupt-dispatch race; the JSA's T65 + speech engine touch
-- none of the extra CPU's timing (since v63 the JSA fetches from its own
-- shadow, off the ROM arbiter) yet dominate sim wall-clock churning garbage
-- from an unfilled shadow. Behavior stubbed: link empty, no IRQ, silence.
library ieee;
use ieee.std_logic_1164.all;

entity escape_jsa is
    generic ( YM_ENABLE : boolean := true );
    port (
        clk       : in  std_logic;
        reset_n   : in  std_logic;
        snd_res   : in  std_logic := '0';
        rom_addr  : out std_logic_vector(23 downto 0);
        rom_data  : in  std_logic_vector(31 downto 0);
        rom_req   : out std_logic;
        rom_ack   : in  std_logic;
        cmd_data  : in  std_logic_vector(7 downto 0) := (others => '0');
        cmd_we    : in  std_logic := '0';
        resp_data : out std_logic_vector(7 downto 0);
        resp_rd   : in  std_logic := '0';
        cmd_full  : out std_logic;
        resp_full : out std_logic;
        snd_irq   : out std_logic;
        coin1     : in  std_logic := '0';
        coin2     : in  std_logic := '0';
        test_mode : in  std_logic := '0';
        irq_strict : in std_logic := '0';
        uvol_ym    : in  std_logic_vector(2 downto 0) := "111";
        uvol_tms   : in  std_logic_vector(2 downto 0) := "111";
        -- MIX-100 added uvol_fm to the real entity; a stub that does not
        -- track the entity it stands in for stops every GHDL bench that uses
        -- it from elaborating at all (which is how run_worldwake.sh and
        -- run_vecrace.sh came to be unrunnable on this branch).
        uvol_fm    : in  std_logic_vector(23 downto 0) := (others => '1');
        audio_l   : out std_logic_vector(15 downto 0);
        audio_r   : out std_logic_vector(15 downto 0);
        dbg_cpu_addr : out std_logic_vector(15 downto 0);
        dbg_cpu_sync : out std_logic
    );
end escape_jsa;

architecture vecstub of escape_jsa is
begin
    rom_addr  <= (others => '0');
    rom_req   <= '0';
    resp_data <= (others => '0');
    cmd_full  <= '0';
    resp_full <= '0';
    snd_irq   <= '0';
    audio_l   <= (others => '0');
    audio_r   <= (others => '0');
    dbg_cpu_addr <= (others => '0');
    dbg_cpu_sync <= '0';
end vecstub;
