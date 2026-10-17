# Security chip (slapstic/SLOOP) — ruled out for this core

**Verdict: the security chip is NOT a factor in any observed misbehavior, and
this core is correct not to implement it.**

Evidence, strongest first:

1. **MAME's `eprom` driver instantiates no slapstic device.** The machine
   config (`src/mame/atari/eprom.cpp`) contains no `SLAPSTIC` device, no
   slapstic memory handlers, and no bank-switched main-CPU ROM window. MAME
   has emulated slapstic variants precisely for decades (`slapstic.cpp` covers
   types 100-118); if Escape's shipped code needed one, the driver would carry
   it. It never has.

2. **The game code flat-references the entire address space.** Disassembly of
   the shipped ROMs shows direct `jmp`/`jsr` targets across the full program
   region (including the 0x20000-0x40586 quiesce path this project traced
   during boot debugging) with no banked window discipline anywhere.

3. **The part is fitted, but the decode never lets it bank.** The SP-332
   schematic does show a slapstic on the board — sheet 4, designator **60E**
   `SLAPSTK5`, with `/STIK` decode and outputs wired to the ROM bank selects
   BS13/BS14 (see [`ARCHITECTURE.md`](ARCHITECTURE.md), schematic re-scan
   findings). What the package does *not* show is anything that depends on it:
   the address decode PALs (2L/2M on the audio side, the main decode sheet 2/3)
   are plain region selects, and nothing in the shipped code exercises a banked
   window (point 2). Present on the board, never banked by the game, not
   implemented here.

4. **On-device confirmation.** As of build 0068 the game's own service-mode
   ROM checksum screen passes and matches MAME's reference values byte-for-
   byte (50A 0DFF / 50B 96DF / 50D ECBF / 40K 1B9F / 40A 51FE / 40B 2ADE /
   40D DCBE / 50K 539E). Code protected by an unimplemented security chip
   could not checksum itself correctly, boot to attract, run its self test,
   or run the attract demo - all of which this core now does.

Historical note: Atari shipped "SLOOP" (slapstic-on-a-chip variants) on some
G1/G-X boards. "Escape from the Planet of the Robot Monsters" (SP-332,
A046145) carries a slapstic (60E above) but MAME models none and the game
runs without one. If a future ROM set variant were found to need one, the
GPL-3.0 System 1 `SLAPSTIC.vhd` in this repo's third_party tree
(`third_party/Arcade-Atari-system1_MiSTer/rtl/atarisys1/`; the chip type is
selected by its `I_SLAP_TYPE` input port, which can change at runtime) is the
drop-in contingency.
