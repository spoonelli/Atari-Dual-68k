# JSA-I sound board — implementation spec

Block B of the core: the Atari JSA-I audio board used by Escape from the Planet of
the Robot Monsters (YM2151 + TMS5220; **no POKEY** on Escape's JSA-I, the socket is
present but unpopulated — MAME's eprom driver instantiates none).

Behavioral reference: `reference/atarijsa.cpp` (+ `atarijsa.h`, `eprom.cpp`), MAME,
BSD-3-Clause. **Re-implemented, no code copied.** RTL: `src/fpga/core/rtl/escape_jsa.vhd`.

## Building blocks

| Block   | Source | License |
|---------|--------|---------|
| 6502    | `third_party/Arcade-Atari-system1_MiSTer/rtl/lib/T65/` (`T65.vhd`, `T65_MCode.vhd`, `T65_ALU.vhd`, `T65_Pack.vhd`) — already compiled into the GHDL sim library by `sim/run_tb.sh`, and System 1's own audio board (`rtl/atarisys1/AUDIO.vhd`) shows the reference wiring (Enable-pin clock-enable at 1.7 MHz on a 7 MHz clock). | BSD-style 3-clause (FPGAArcade/OpenCores, Wallner/Johnson/Scherr/Leikvoll) |
| YM2151  | `third_party/jt51` submodule (jotego/jt51), `hdl/jt51.v` top | GPL-3.0 (same as repo) |
| TMS5220 | **stub** (interface + silence) — see "TMS5220 stub" below | n/a |

## Clocks

One input clock, enables derived — same 7.159091 MHz domain as `escape_core`:

| Rate | Use | Generation |
|------|-----|------------|
| 7.159091 MHz | `clk` in | shared with escape_core (2× YM master) |
| 3.579545 MHz | YM2151 master (`jt51 cen`) | clk ÷2 enable |
| 1.789773 MHz | 6502 (`T65 Enable`), `jt51 cen_p1` | clk ÷4 enable |
| 249.69 Hz | timed IRQ | ÷7168 of the 1.79 MHz enable (= 3.579545 MHz /4/16/16/14, per MAME `sound_irq_gen` period) |

## 6502 memory map (JSA-I, from `atarijsa1_map` + mirror analysis)

The `0x2800`/`0x2A00` regions mirror with mask `0x01F9`: hardware decodes only
A15–A9 and A2–A1 there. RAM is **8 KB** (0x0000–0x1FFF, MAME map; earlier 4 KB
note was wrong).

| Address | R/W | Function |
|---------|-----|----------|
| `0000-1FFF` | R/W | program RAM (8 KB) |
| `2000-2001` | R/W | YM2151 (A0 selects addr/data; mirrors through 27FF in our decode) |
| `2800` (+mirror) | R | n/c (reads 0xFF) |
| `2802` (+mirror) | R | **/RDP** command latch read (68k→6502); clears input-buffer-full + 6502 NMI |
| `2804` (+mirror) | R | **/RDIO** status/coin port (bit table below) |
| `2806` (+mirror) | R/W | **/IRQACK** — read *or* write clears the timed interrupt |
| `2A00` (+mirror) | W | **/VOICE** TMS5220 data latch (stubbed) |
| `2A02` (+mirror) | W | **/WRP** response latch write (6502→68k); sets output-buffer-full + main /SINT |
| `2A04` (+mirror) | W | **/WRIO** control port (bit table below) |
| `2A06` (+mirror) | W | **/MIX** mixer register (bit table below) |
| `2C00-2C0F` (+mirror 0x03F0) | R/W | POKEY — absent on Escape; reads return 0xFF, writes ignored |
| `3000-3FFF` | R | **banked ROM**: one of 4 pages of 0x1000 from ROM offsets `0x0000/0x1000/0x2000/0x3000`, bank = WRIO[7:6]; reset bank = 0 |
| `4000-FFFF` | R | static ROM = ROM offsets `0x4000-0xFFFF` |

ROM region = 64 KB at combined-image offset **`0x100000`** (`docs/ROMMAP.md`,
`support/build_rom.py`; chip `136069-1040.7b`, includes TMS5220 LPC data read by
the 6502 and fed byte-wise to /VOICE). Note the banked window exposes offsets
0x0000–0x3FFF, which the linear map never shows — the full 64 KB is reachable.
Escape's reset vector (image offset 0x10FFFC/D) points at 0x4000.

### /RDIO read (0x2804)

| Bit | Meaning |
|-----|---------|
| D7 | self-test. MAME quirk: its double inversion nets to constant 0 in normal play; we present `test_mode` (1 = test switch on, 0 = normal) |
| D6 | /input-buffer-full — **0 when a 68k command is pending** (main→sound ready, active low) |
| D5 | output-buffer-full — **1 while the response latch is full** (active high) |
| D4 | TMS5220 /READY pin state per MAME: bit **set when the chip is ready** (readyq low). Stub drives 1 (always ready) |
| D3 | +5V (reads 1) |
| D2 | +5V (reads 1) |
| D1 | coin 2, **1 = coin switch closed** (MAME models the port active-high; Pocket buttons arrive active-high, passed straight through) |
| D0 | coin 1 (= Pocket **Select**, wired at core_top integration) |

### /WRIO write (0x2A04) — resets to 0x00

| Bit | Meaning |
|-----|---------|
| D7:6 | ROM bank select for 0x3000-0x3FFF (page = bank × 0x1000 of the ROM region) |
| D5 | coin counter 2 (ignored) |
| D4 | coin counter 1 (ignored) |
| D3 | "squeak" — TMS5220 clock tweak: 5220 clock = 3.579545×2 MHz / (16 − (5 | (D3<<1))), i.e. /11 vs /9 (stub: latched, unused) |
| D2 | TMS5220 read strobe /RS (active low) (stub: latched) |
| D1 | TMS5220 write strobe /WS (active low) (stub: latched) |
| D0 | YM2151 reset, **active low** (0 = hold jt51 in reset). Reset value 0 ⇒ YM held reset until the program releases it |

### /MIX write (0x2A06) — resets to 0x00

| Bit | Meaning | Gain law (MAME) |
|-----|---------|-----------------|
| D7:6 | TMS5220 volume 0-3 | vol/3 × route-gain 1.0, gated by YM CT1 |
| D5:4 | POKEY volume 0-3 | vol/3 × 0.40, gated by CT1 (no POKEY on Escape) |
| D3:1 | YM2151 volume 0-7 | vol/7 × route-gain **0.60 per channel** (stereo) |
| D0 | low-pass filter enable (unimplemented in MAME too; latched only) |

Implementation: YM gain = Q8 coefficient table `round(0.6×256×v/7)` =
{0,22,44,66,88,110,132,154}, applied to jt51 `xleft/xright`; TMS path adds
silence for now. YM CT1 output gates the TMS (and would-be POKEY) volume;
CT2 unused on JSA-I.

## Interrupts

* **6502 IRQ** (level) = `timed_int OR ym2151_irq`. `timed_int` is set by the
  249.69 Hz counter, cleared by any read/write of 0x2806. jt51 `irq_n` is the
  other source. IRQ line stays asserted while either is pending.
* **6502 NMI** (edge, handled inside T65) = asserted when the 68k writes the
  command latch, released when the 6502 reads 0x2802.
* **Main-CPU /SINT** (68k IRQ6) = asserted while the response latch is full;
  cleared by the 68k read of 0x260031.

## 68k-side link (from `eprom.cpp` main_map)

| 68k address | Dir | Function |
|-------------|-----|----------|
| `0x360031` (W, **lower byte**, D7-D0) | main→sound | command latch write; sets input-buffer-full, 6502 NMI |
| `0x260031` (R, **lower byte**, D7-D0) | sound→main | response latch read; clears output-buffer-full and /SINT. (Byte at the odd address ⇒ D7-D0 lane — earlier "upper byte" notes were wrong; matches `docs/ARCHITECTURE.md` "260030 R D0-D7") |
| `0x360020` (W, any data) | — | sound reset: pulses the 6502 reset, clears both latch-full flags, timed IRQ, WRIO/MIX/bank |
| `0x260010` (R) | — | D2 = **/output-buffer-full** (0 = response waiting @260030); D3 = **/input-buffer-full** (0 = command still pending @360030) |

`escape_jsa` exposes this as latch-level ports (`cmd_data/cmd_we`,
`resp_data/resp_rd`, `cmd_full/resp_full`, `snd_irq`, `snd_res`), driven from
the 68k bus decode in `escape_core` (fully wired — an early stub that idled the
flags is long gone).
Schematic note: on the real board these travel over the serial **SCOM** link
(sheet 2); we model the latch semantics directly, which is what the programs
observe.

## Program ROM bus

The 6502 exposes the same request/ack protocol as `escape_core`: `rom_addr`
(combined-image byte address, here always `0x100000 + resolved 16-bit offset`,
even), `rom_req` raised and held until `rom_ack`, data in `rom_data[31:16]` =
word at addr, `[15:0]` = word at addr|1. ROM bytes are big-endian in the 16-bit
image words: even byte = bits 15:8.

**Since v63 those requests never reach SDRAM.** `escape_core` serves the
`0x100000` window from a dedicated 32 KB dual-port BRAM shadow (`jshad`,
`escape_core.vhd` — write side filled during ROM download, gated by
`jshad_we` on the `0x10xxxx` address range), so 6502 fetches cost BRAM
latency, add no SDRAM traffic, and cannot be starved by the 68k pair. The
last-word + prefetch-word cache in `escape_jsa` still smooths sequential code.
No third arbiter client exists or is needed.

## Command-latch watchdog (JSAWDG-133)

One field failure (unreproducible; survived soft reset) left the 6502 wedged
mid-tune with the YM2151 droning at ~64.5 Hz and the command latch stuck full.
`escape_core` now watches CMD_FULL: if the 6502 has not consumed a command for
**0.75 s** (5,400,000 pixel clocks), it pulses the existing `snd_res` path —
the same reset the 68k can issue at `0x360020` — and the sound program
recovers on its own. Diagnostics ride the HUD debug bus: the wedge count in
`dbg_jsa_link[11:8]`, and the 6502 PC frozen at the *first* wedge in
`dbg_jsa_pc` so the faulting address survives the self-heal.

## TMS5220 speech — real core, wired

`escape_jsa` instantiates the real TMS5220 model (d18c7db's MAME-faithful
core, `TMS5220.vhd` — see `NOTICE.md` for provenance): `tms_data` (last
/VOICE byte), `tms_ws_n`/`tms_rs_n` (WRIO D1/D2), and the WRIO D3 "squeak"
clock select (3.579545×2/11 vs /9 MHz) drive it; /RDIO D4 reads back its real
/READY; its signed output mixes at gain `mix[7:6]/3 × CT1` into both
channels. An earlier stub that latched the interface and output silence is
gone (LANE3u).

## GHDL simulation vs jt51 (mixed language)

jt51 is Verilog; the repo's GHDL flow is VHDL-only (mcode has no mixed-language
support). `escape_jsa` therefore takes `YM_ENABLE : boolean` (default **true**):

* synthesis (Quartus, mixed-language): leave true — the `jt51` component binds
  to `third_party/jt51/hdl/jt51.v` (add jt51's `hdl/*.v` to the project files).
* GHDL sim: instantiate with `YM_ENABLE => false` — the if-generate skips the
  component, and a stub drives `dout=0x00` (never busy), `irq_n=1`, `ct1=1`,
  silence. `sim/tb/tb_escape_jsa.vhd` does this.

Run: `./sim/run_tb.sh tb_escape_jsa` — needs the user-generated (never
committed) `sim/work/combined_words.hex`; the TB serves the 6502 ROM from word
offset `0x100000/2` of it via `rom_words` and checks reset-vector fetch,
execution from PC 0x4000, and the first response-latch write.
