-- Simulation ROM: loads a word-per-line hex file (4 hex digits, big-endian words)
-- into a 16-bit-wide memory. Combinational read. Used to load the assembled Escape
-- program ROM (sim/work/maincpu_words.hex) for CPU bring-up. Not synthesizable.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity rom_words is
    generic (
        hexfile : string;
        awidth  : integer := 18            -- word-address width (2^18 words = 512 KB)
    );
    port (
        addr : in  std_logic_vector(awidth-1 downto 0);
        data : out std_logic_vector(15 downto 0)
    );
end rom_words;

architecture sim of rom_words is
    type mem_t is array (0 to 2**awidth-1) of std_logic_vector(15 downto 0);

    impure function load_hex return mem_t is
        file     f   : text open read_mode is hexfile;
        variable l   : line;
        variable w   : std_logic_vector(15 downto 0);
        variable ok  : boolean;
        variable idx : integer := 0;
        variable m   : mem_t := (others => (others => '0'));
    begin
        while not endfile(f) and idx < 2**awidth loop
            readline(f, l);
            hread(l, w, ok);
            if ok then
                m(idx) := w;
                idx := idx + 1;
            end if;
        end loop;
        return m;
    end function;

    constant rom : mem_t := load_hex;
begin
    data <= rom(to_integer(unsigned(addr)));
end sim;
