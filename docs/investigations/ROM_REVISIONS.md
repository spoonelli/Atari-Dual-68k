# Escape from the Planet of the Robot Monsters: what changed between program revisions

Three program revisions are compared:

- **Set 2.** MAME `eprom2`. Every program chip is a -1xxx part. The 40E/50E pair is 64 KB each at 0x80000.
- **Rev B.** The owner's board, not in MAME. The 40A/50A chips are -2024/-2025. The 40B/50B and 40D/50D chips are -3026 to -3029. The 40E/50E pair (-1030/-1031) is 32 KB each at 0x90000.
- **Set 1.** MAME `eprom`, the parent set. Its 40A/50A, 40B/50B and 40D/50D chips are -3/-4 parts. The shared pair is 2032/2033 and the extra-CPU pair is 2034/2035. It has no 40E/50E chips.

Each claim carries one of three tags:

- **[MAME]**: confirmed by running MAME 0.289.
- **[code]**: confirmed by reading the disassembly.
- **[inferred]**: a reasoned reading that has not been verified.

Addresses are CPU addresses. "Video" means the maincpu program and "extra" means the second 68000. Map cells are written (column, row) as in the level grid at 0x1688E0 (36 columns of 16-bit words per row).

## Which chips actually differ (read this first)

- **Sound (JSA 6502).** Both MAME sets use the same `136069-1040.7b`, with the same CRC. **The sound program does not differ.** Any audio difference comes from the commands the 68000 sends.
- **Extra-CPU program (10S/10U).** Rev B runs with set 2's 1034/1035. The prior work found that the rev B chips only boot over set 2's shared and extra pairs. **Rev B and set 2 therefore have the same extra-CPU program.** Set 1's 2034/2035 is different.
- **Shared ROM (40K/50K, at 0x60000-0x7FFFF in both CPUs).** Rev B and set 2 share 1032/1033. Set 1 has 2032/2033, which is different.
- **Video program.** All three are different.

So **rev B versus set 2 is a video-program-only change**. Set 1 changes the video program, the extra program and the shared ROM.

## Chronology verdict: set 2, then rev B, then set 1. Confirmed.

Every change that rev B makes to set 2 is still present in set 1. There is no case where set 1 matches set 2 but rev B does not.

- **Game-reset routine.** Rev B merged set 2's game-reset routine (video 0x3AD22) with the option loader to make 0x3C14A [code]. The merged routine has a distinctive order of operations: clear the per-game state, then reload the 8 option bytes, then re-read the EEPROM option word. Set 1's 0x496EC has exactly this structure. Set 1 even kept rev B's older code generation in this one module [code].
- **Max Lives Awarded.** Rev B fixed a bug where this setting was never applied (see D1 below). Set 1 also reads its own field for this setting [code, MAME].
- **Self-test glyph.** Rev B changed one self-test glyph from 0xD1 to 0xD3. Set 1 also uses 0xD3 [code].
- **Changes that build up.** Text and menus are identical in set 2 and rev B, and new in set 1. The developer editor is present in set 2 and rev B, and removed in set 1. The 40E/50E block shrinks from 128 KB of space in set 2, to 32 KB in rev B, to absent in set 1. Rev B had already moved about 14 KB of code out of 40E/50E (set 2's 0x8FC0A-0x93422 moved to rev B's 0x20298-0x23AA8).
- **Chip labels.** These agree with the order: -1 parts, then -2/-3, then -3/-4. The 40K/50K pair goes from 1032/1033 to 2032/2033.

## Summary of differences

| # | Introduced in | Area | Visible to player or operator? | Evidence: set 2 / rev B / set 1 | Confidence |
|---|---|---|---|---|---|
| D1 | rev B | Bonus lives: the MAX LIVES AWARDED setting was ignored in set 2 (copy-paste bug) | Player, at high scores. Set 2 stops awarding at row[bonus][bonus] instead of row[bonus][max] (default about 1.0 M points instead of 1.6 M) | load 0x33C9E and 0x48202 / 0x34F1E and 0x496F8 / 0x43362 and 0x497xx; award logic s2 0x3B630, s1 0x4A090 | [MAME] variable values, [code] effect |
| D2 | rev B | Game-reset routine re-reads the operator options every time | Only after the operator changes a setting (not checked in MAME) | 0x3AD22 / 0x3C14A / 0x496EC | [code] |
| D3 | rev B | Self-test histogram bar glyph changed | Operator (self-test) | 0x4D8E / 0x4D8E / 0x4D90 | [code] |
| D4 | rev B | ROM layout: 40E/50E shrank to a 27256 pair at 0x90000 and code moved; checksum pads | No (only the self-test checksum screen) | — | [code]; prior work [MAME] |
| D5 | set 1 | Operator menu rebuilt. EEPROM option-word bit layout changed. New options FBI WARNING DISPLAYED and JOYSTICK POSITION. MAX LIVES reduced to 3/10. Labels uppercased | Operator. NVRAM is **not interchangeable** between sets (see also D16) | menu table 0x20119 (s2 = rb) / 0x20119 (s1) | [code], default words [MAME] |
| D6 | set 1 | Factory-default option word changed from 0x44BA to 0x46BA | Operator: defaults are max lives 10 and FBI screen on | EEPROM image after a cold boot | [MAME] |
| D7 | set 1 | The "Winners Don't Use Drugs" FBI screen becomes optional (bit 9). It is always shown in set 2 and rev B | Attract mode (it is at the end of the credits roll, which did not occur within 16,000 frames) | rb 0x33BFC-0x33C5E / s1 0x41FDC | [code] |
| D8 | set 1 | JOYSTICK POSITION "rotated 90 degrees clockwise" swaps each player's analog X and Y ADC channels in the OS stick reader | Only when enabled | s1 0x20BC-0x20D4 and 0x584A (sets the flag at 0x3F50A8); reader 0x5CFA-0x5E32 | [code] |
| D9 | set 1 | STAND BY appears in the idle player's panel during the canal stage (state 0x18) | Player (the known difference) | set 2 0x3D018 / rev B 0x3E502 / set 1 0x4B6A8 (P1) and 0x4BA36 (P2) | [MAME] (`can_*` runs) and on device |
| D10 | set 1 | Level-entry wrist-communicator picture and music: when entering a type-0 level after a type-2 level, set 1 chooses the variant by bit 2 of the level index; set 2 and rev B use bit 1. Set 1 also sends the music cue about 60 frames later | **Player: entering levels 5 and 13, set 1 shows "GOOD JOB! NOW GET TO THE NEXT FACTORY AND RESCUE OUR PEOPLE!" with cue 0x6E; set 2 and rev B show "RESCUE HOSTAGES BEFORE THEY ARE TURNED INTO ROBO-ZOMBIES!" with cue 0x6B.** Level 9 shows the RESCUE HOSTAGES picture in all three | rb 0x340EE / s1 0x424A4 (start deferred through 0x16D35C, sent at 0x426CA); pictures 0x17A9D (GOOD JOB) and 0x184BF (RESCUE HOSTAGES) | [MAME] pictures and sound commands, [code] |
| D11 | set 1 | Level geometry data changed: level 1 in every sector; sector D level 7; levels 8, 12 and 15. In level 1 an invisible one-cell solid block was moved | Player, as collision only (nothing is drawn differently). Level 1: set 2 has an invisible solid cell in open floor in front of the STARS arcade cabinet at (4,0xA4); set 1 removes it and instead makes the west tip of the console bank at (9,0xA5) solid from every side | type-0 list table s2 0x2DFF0 / s1 0x3B764; type-2 list table s2 0x738F6 / s1 0x3AEEE | [MAME] grid diff, snapshots and movement tests; [code] tables |
| D12 | set 1 | Developer level/sprite editor ("Factory:", PF/MOB editor) removed, with its debug hooks | No: it is unreachable in set 2 and rev B (see below) | rb 0x499D4-0x4D45A; start-flag checks on 0x16D2F0 | [code] |
| D13 | set 1 | Dead debug routine removed: it sent pulse codes on bit 6 of the 0x360010 latch | No | rb 0x3265C-0x32726, no callers | [code] |
| D14 | set 1 | Whole program rebuilt with newer code generation and a re-laid-out RAM map around 0x16D340-0x16D35C. The extra CPU and the shared ROM code were rebuilt too | Indirectly: CPU load and frame-phase timing differ, and random outcomes diverge | throughout | [code] |
| D15 | set 1 | OS bookkeeping: "Total Sessions" is counted per player game instead of per session, and the end-of-session flush of the 0/1/2-player minute counters was removed | Operator, Statistics screen. A two-player game adds 1 to Total Sessions in set 2 and rev B, 2 in set 1 | rb 0x4762-0x482E and 0x493A / s1 0x476C-0x4822 and 0x492E (count at 0x4946) | [code], [MAME] breakpoint count |
| D16 | set 1 | OS histograms cut from 6 to 4: "Time per Level, Single" and "Time per Level, Double" are dropped. The EEPROM directory and the statistics block move accordingly | Operator, self-test histogram screens. This is the "second differing EEPROM word" | game header byte 0x2006F: 0x3E / 0x3E / 0x3C | [MAME] self-test screens, [code] |
| D17 | set 1 | Collision response at the edges and corners of raised floor features (rails, ropes, steps): two extra-CPU edge tables changed | Player, subtle: at rail ends and corners the player is now blocked from more directions and is deflected (slides) along the edge instead of stopping or passing | extra s2/rb 0x196DA and 0x19752 / s1 0x186AC and 0x18724; reader s2 0x10D26-0x10E56 and 0x10864-0x108E4 | [code] tables, [MAME] A/B ROM-patch test |
| — | — | Things that do **not** differ | | | |
| N1 | — | Self-test and attract text; the attract sequence and its timing (title, high scores, demo); INSERT COIN(S) and ADD COINS TO START prompts; the Statistics screen labels | | attract timeline runs `att_*` | [MAME] |
| N2 | — | Canal countdown length: the time-out comes at frame 5222 in set 1 and frame 5224 in set 2, out of about 2,215 canal frames | | `can_*` runs | [MAME] |
| N3 | — | Per-sector level order, level-type table, bonus thresholds (100k/200k/400k), lives and continue tables | | shared tables 0x7391A-0x73C4C, 0x74240-0x7450E (set 2) and set 1 +0x1250 | [code] byte-identical |
| N4 | — | Input-port usage, the bits tested, the coin path | | see the cabinet section | [code] |
| N5 | — | Extra-CPU gameplay constants; all extra-CPU data tables except the two D17 tables (animation tables, handler tables, the solid-block edge table at s2 0x197CA, the feature-height table at s2 0x19A4A) | | see "Extra CPU" below | [code], relocation-tolerant byte comparison |
| N6 | — | Scenery graphics at the D11 cells | | pixel diff of matching level-1 snapshots: only robot animation frames differ | [MAME] |

## Rev B compared with set 2, in detail

I compared every routine and data block. Instructions were matched with relocation and move detection, and pointers were checked through the address map. Apart from D1-D4, everything differs only by relocation.

- **D1, Max Lives Awarded (fixed in rev B).**
  - The EEPROM option word (index 10, read through vector 0x17A) is decoded into RAM variables.
  - In set 2, *both* 0x16D344 (Bonus Lives) and 0x16D346 (Max Lives) are taken from bits 7-8 of the option word.
  - Rev B takes 0x16D346 from bits 9-10, which is where the menu stores MAX LIVES AWARDED (prefix byte 0xA9 = bits 10..9).
  - Above 500,000 points, the award routine keeps giving lives every 100k/200k/400k up to a cap. The cap comes from a table indexed [bonus][max]: for "every 200,000" it is 600k / 1.0 M / 1.6 M / 2.0 M.
  - So set 2 ignores the operator's choice: with "every 200,000" it always caps at 1.0 M.
  - In MAME with factory settings, 0x16D346 is 1 in set 2 and 2 in rev B (the "8 lives" setting) [MAME]. Set 1 gives 3 for its default of "10".
- **D2, options re-read at game reset.**
  - Rev B's game-reset routine 0x3C14A also re-reads the option word and re-derives every option variable. Set 2's 0x3AD22 relied on separate loaders.
  - The 2-credit start price (0x16CD1C) is computed from a freshly loaded Special Cost bit.
- **D3, self-test glyph.** The time-histogram screen in self-test draws its bar with alpha tile 0xD3 instead of 0xD1.
- **D4, layout.**
  - Set 2's 0x80000-0x8FBFE data maps to rev B 0x90000 and onward unchanged.
  - Code moved from 40E/50E into the 0x20000 page.
  - A block of data moved from 0x24CB2 to 0x1A4D0.
  - One pair of hint texts swapped places in ROM. The hint table still references them in the same order, so the behaviour is unchanged [code].
  - Words after an `rts` were changed only so each chip's byte sum lands on its self-test tag.
- **Everything else.** There are no other code, constant, string or table changes. The attract screens are identical [MAME]. The prior work's gameplay "camera a few pixels ahead" effect is frame-phase drift: rev B's game-reset path does extra EEPROM reads, so it runs at a slightly different cost. In our runs the demo diverged at about frame 12,700 and random outcomes differ: after a failed canal the computer chose sector B in set 2 and sector M in rev B, chosen by `random(3)` at rb 0x344EA.
- **OS bookkeeping.** Rev B's OS session counting (D15) and histogram set (D16) are the same as set 2's: a two-player test game counted one session in rev B [MAME].
- **For a capture of the owner's board.** Rev B behaves like set 2 in every respect except D1 and timing phase. Running the core on set 2 is the closest reference. Expect pixel-identical attract mode and drift in gameplay.

## Set 1 compared with rev B, in detail

**Method caveat.** Set 1 was rebuilt with different code generation. For example, it uses `lea abs.l` and `pea #imm` where the older build used `movea.l #` and `move.l #,-(A7)`. It also allocates registers and schedules instructions differently, and it shifts the RAM map (for example 0x16D34E/50 became 0x16D352/54). Only about 19% of 32-byte blocks match at the same offset. Line-level diffs are therefore noisy. The items below were each checked by reading the disassembly or by running MAME. How far the extra-CPU comparison got is stated under "Extra CPU" below.

### D5 and D6: operator options and EEPROM layout

The prefix byte of each menu label encodes its bit range (high nibble = top bit, low nibble = bottom bit).

| Bits | Set 2 and rev B | Set 1 |
|---|---|---|
| 15 | Clear high scores | same |
| 14 | Difficulty ramping | same |
| 13 | Restore factory | same |
| 12-11 | Lives 3/4/5 | same |
| 10-9 | MAX LIVES AWARDED 3/5/8/10 | bit 10: MAX LIVES 3/10; bit 9: FBI WARNING DISPLAYED |
| 8-7 | Bonus lives every 100k/200k/400k/none | same |
| 6-5 | Difficulty easy/moderate/hard | same |
| 4 | Music in attract | same |
| 3-2 | Continuations unlimited/8/10/15 | bit 3: SPECIAL COST; bit 2: JOYSTICK POSITION |
| 1-0 | bit 1: Special Cost | bits 1-0: CONTINUATIONS |

- **Cold-boot defaults** [MAME]: 0x44BA in set 2 and rev B, 0x46BA in set 1. Set 1 defaults to max lives 10 and FBI screen on.
- **NVRAM compatibility.** Apart from the option word, the cold-boot EEPROM images differ in the OS's EEPROM directory bytes and their checksums, and the statistics block sits at a different EEPROM address. All of that comes from D16, not from an operator option (see D16).
- **For the FPGA core:** do not carry an EEPROM image between sets. Set 1 reads a set 2 or rev B image with the continuation, special-cost and FBI bits reinterpreted. Max lives is also misread whenever bits 10-9 are not 00 or 11. The statistics and histogram records are also laid out differently (D16).

### D7: FBI screen

- In set 2 and rev B, step 5 of the attract credits roll always draws the FBI seal from alpha tiles and shows the "Winners Don't Use Drugs" text (rb 0x33C08-0x33C5E).
- Set 1 checks 0x16D350, which is option bit 9, first (0x41FDC).
- Set 1's default is "yes", so out of the box the behaviour is the same.

### D8: joystick rotation

- At boot, set 1's OS reads option bit 2 and stores it at 0x3F50A8.
- When the flag is set, the stick reader takes each player's horizontal reading from the vertical ADC byte and the vertical reading from the horizontal byte (0x3F7FE2/E3 for P1, 0x3F7FE4/E5 for P2).
- I did not determine whether an axis is also inverted.

### D10: level-entry transition

- The transition task (task 0x1A; rb 0x34274, s1 0x4264E) decompresses a full-screen playfield picture into playfield RAM and sends a music cue. The pictures are the wrist-communicator message screens shown between levels.
- When the level being entered is type 0 and the adjacent level is type 2:
  - Rev B and set 2 test bit 1 of the level index. Bit 1 is 0 for indices 4, 8 and 12, so they always pick picture 0x184BF with cue 0x6B.
  - Set 1 tests bit 2. Indices 4 and 12 give picture 0x17A9D with cue 0x6E.
- **What the player sees** [MAME, snapshots at frame 2700 of a forced exit into levels 5, 9 and 13, sector M]:
  - Picture 0x184BF: a fist with a wrist communicator and the speech balloon "RESCUE HOSTAGES BEFORE THEY ARE TURNED INTO ROBO-ZOMBIES!".
  - Picture 0x17A9D: the same fist and communicator with "GOOD JOB! NOW GET TO THE NEXT FACTORY AND RESCUE OUR PEOPLE!".
  - Level 5 and level 13: set 1 shows GOOD JOB; set 2 and rev B show RESCUE HOSTAGES.
  - Level 9: all three show RESCUE HOSTAGES.
  - The rest of the screen (fist, communicator, frame) is identical.
- Set 2 and rev B still contain and use the GOOD JOB picture on a different transition path (s2 0x3399E, rb 0x34C26; that routine picks GOOD JOB whenever the level's type is 0) [code]. On the type-2 to type-0 entries, bit 1 is never set, so set 2 and rev B never show it there. Set 1's bit-2 test looks like the intended alternation [inferred].
- Sound commands [MAME]: set 1 sends cues 0x6E, 0x6B and 0x6E for levels 5, 9 and 13; set 2 and rev B send 0x6B every time. Set 1 sends the cue at frame 2640, in state 0x1E. Set 2 and rev B send it at frame 2580, in state 0x1F.
- Harness note: in these forced-exit runs the HUD shows LEVEL 05/09/13 in set 1 but 04/08/12 in set 2 and rev B. The harness writes the level index directly and skips the normal exit routine. The level-number readout is not evidence of a revision difference.
- Snapshots: MAME captures comparing the revisions were taken; they are kept with the analysis, not in this repository (game imagery).

### D11: level geometry data

Level maps are built from 6-byte records (type 0) or 8-byte records (type 2), each giving a feature type and a cell rectangle. The parsers are s2 0x40AF2 and s2 0x40FAA.

| Level list | Used by | Change in set 1 |
|---|---|---|
| Type-0 list 0 | **Level 1 of every sector** | Three single-cell type-0x12 records at cells (2,0xA0), (4,0xA4) and (6,0xA0) are replaced by one at (9,0xA5) |
| Type-0 list 4 | Sector D level 7 | The type-0x18 rectangle is removed; the type-0x16 and type-0x19 rectangles are reshaped |
| Type-2 lists 1, 3, 5, 7, 8 | Level 8 of sectors M, D and B; level 12 and level 15 of every sector | Two single-cell type-0x12 records are added at (0x17,0x0C,h4) and (0x17,0x0E,h4) |

- All other lists are byte-identical. Set 1 also swapped which ROM holds each group of lists.
- **What a grid cell holds** [code]. Each word packs an edge code (bits 15-12, which edge or corner of the source rectangle the cell lies on; 0xF = interior or solid), a feature type (bits 11-7) and a floor height (bits 6-0). Types 1-7 are raised floor features whose step height comes from the table at extra s2 0x19A4A (8 up to 0x60 units). Type 0x1F is a wall. Types 8-0x1D are object cells handled through the jump table at extra s2 0x10FDE.
- **What type 0x12 is** [code]. The extra CPU's cell handler (s2 0x10B38, the player-movement collision check) sends types 0x12, 0x13 and 0x15 to the same case (s2 0x11170): result code 4 (solid object), with the per-direction edge table at s2 0x197CA deciding which approach directions are blocked. Type 0x12 has no graphics of its own. The scenery is drawn from the level's playfield picture, which is independent of the grid. **Type 0x12 is an invisible one-cell solid block** with the same collision behaviour as a console (type 0x15). The parser also makes type 0x12 itself when a type 8-0xE record lands on a non-solid cell (s2 0x40D14).
- **The live level-1 grid** differs in exactly 2 cells [MAME]:
  - (4,0xA4): set 2 = type 0x12, edge 0xF (fully solid); set 1 = type 4, edge 8 (a corner cell of a raised 0x30-high feature).
  - (9,0xA5): both are type 0x15 (console); set 2 has edge 2 (solid only from some directions); set 1 has edge 0xF (solid from every direction).
  - (2,0xA0) and (6,0xA0) are overwritten by the later desk and cabinet rectangles in both sets, so they do not differ.
- **Where these cells are on screen** [MAME]. Snapshots were taken with the player held at the same position in both sets (the camera follows the player; scroll 0x30/0xD8). The cells were located with the playfield scroll registers and the extra CPU's position-to-cell conversion (s2 0x1CFC6: column from X/32, row from Y/8, rows staggered).
  - (4,0xA4) is open grey floor in front of and to the left of the STARS arcade cabinet, between the hostage's desk and the cabinet.
  - (9,0xA5) is the west tip of the long console bank, where the yellow rope from the cabinet ends.
  - **Nothing is drawn differently.** A pixel diff of the two snapshots differs only in robot animation frames (N6).
- **Movement tests** [MAME]. The player was placed with RAM pokes (player object 62 at 0x160BA0: Y at +0xA, X at +0xE, 25.7 fixed point), the stick was held for 30 frames in four directions, and the displacement was recorded:
  - Placed on (4,0xA4): in set 2 the player cannot move in any direction (inside a solid cell); in set 1 the player walks off west and south.
  - Placed on (9,0xA5): in set 1 the player cannot move in any direction; in set 2 the player moves in three of the four directions.
  - Walking north into the gap between the rope end and the console: set 2 lets the player in, up to Y = 1312 px, standing between the rope and the console. Set 1 stops the player about 14 px earlier, at Y = 1326 px.
- **Reading.** Set 1 removes a stray invisible obstacle from open floor in level 1, and closes the slip-through gap at the end of the rope by the console. Together with D17 this looks like a deliberate collision clean-up around the rope enclosures [inferred]. The two type-0x12 cells added to type-2 levels 8, 12 and 15 are presumably the same kind of invisible block; they were not visited [inferred].
- Snapshots: MAME captures comparing the revisions were taken; they are kept with the analysis, not in this repository (game imagery).

### D17: edge collision tables for raised floor features

- When the player's cell check meets a raised floor feature (types 1-7) on an edge or corner cell, the extra CPU looks up a byte per (edge code, movement direction) [code]:
  - T2 (s2/rb 0x19752, s1 0x18724) is used when the player's height equals the feature's base, so the player is walking at ground level into the feature.
  - T1 (s2/rb 0x196DA, s1 0x186AC) is used when the player is on top of the feature.
  - Bit 0 set means pass. Otherwise the move is blocked, and the high nibble gives a slide direction (0x10, 0x30, 0x50, 0x70), or none (0xF0). The solid-object table T3 (s2 0x197CA) uses the same format and is identical in both sets.
- What set 1 changed:
  - T2 rows for edge codes 1, 2, 3, 4, 6 and 8 (the end and corner cells of rails, ropes and steps) now equal the solid-object table T3. In set 1, T2 is identical to T3 for every edge code except 0xF. In set 2 those rows were mostly "pass": at ground level the player could walk into rail ends and corners from most directions. In set 1 they block like the corner of a solid object and deflect the player along it.
  - T1 adds slide directions to several blocked moves on top of features: edge 1 dir 0, edge 2 dirs 2/6, edge 3 dirs 0/6, edge 4 dir 0, edge 6 dirs 0/2, edge 8 dirs 2/6.
  - Edge codes 5 and 0xA (combinations the parser does not normally produce) become fully blocking in both tables.
  - Rows 7, 9 and 0xB-0xF are unchanged. These include 9 and 0xC, the straight runs of rails, which are the most common edge codes in level 1.
- **MAME A/B test.** I overwrote set 1's two tables with set 2's in the extra ROM region and kept everything else identical:
  - The same scripted walk (8 stick directions, 40 frames each) diverges from unpatched set 1 at frame 2194, near cell (8,0xAE).
  - The reverse patch on set 2 diverges at frame 2033.
  - At the level-1 rope corner (4,0xA4), walking west: with set 1's tables the player is deflected 6-8 px south while walking; with set 2's tables the player walks straight. One run also went 11 px further.
- **Player-visible effect.** This is subtle. At rail ends and corners, set 1 blocks more approaches and slides the player along the edge. Set 2 lets the player cut through or stop dead. No graphics change.

### D9: STAND BY

- The P1 panel prints the text at 0x3F198 and the P2 panel at 0x3F1EC, when that player is idle in states 0x0F, 0x0C or 0x18.
- Set 2 and rev B accept only states 0x0F and 0x0C.
- MAME `can_s1` shows STAND BY in the canal; `can_s2` and `can_rb` do not.

### D12, D13: dead and debug code

- **The editor in set 2 and rev B is unreachable.**
  - It runs as scheduler task 4: bit 26 of the task mask 0x16CCF2, dispatched through the table at rb 0x2F2E0.
  - Neither CPU's ROM ever starts that task. Every mask passed to the task-start routines (rb 0x3D1CE, extra 0xD3E6) was checked.
  - The only code touching bit 26 *stops* the task.
  - Only a debugger or a RAM poke could reach the editor. Once running, it is driven by both players pressing the same button.
  - Its flag 0x16D2F0 is checked in about 18 gameplay routines (scroll clamps and similar). Set 1 deletes those checks. With the flag clear, behaviour is unchanged.
- The latch pulse-code routine has no callers.

### D14 and the extra CPU: how far the comparison got

The extra-CPU program and the code at the start of the shared ROM were recompiled. What was compared (set 2 extra against set 1 extra):

- **Routines.** The set 2 extra program splits into 292 code routines (prior split). After normalising the RAM map:
  - About 219 have identical feature signatures (constants, RAM references, strings, call counts).
  - 61 differ in their signature, 12 have no direct counterpart (merged or inlined) and 10 set 1 routines are new (split out or new helpers).
- **Constant audit** (new). I made a histogram of every immediate operand used as a value (compares, arithmetic, masks, shift counts, pushed arguments) across both programs, ignoring stack and frame offsets. Every constant whose count differs was traced to code generation, with no changed gameplay value:
  - argument loading through `movea.l #n` versus `pea`;
  - embedded switch tables;
  - divisions replaced by flat indexing;
  - task masks moved into a helper (set 1 0x98FC);
  - one function split into three (the cell handler s2 0x10B38 became s1 0xFED6, 0xFFA0 and 0x1001A).

  Examples of logic-preserving restructuring:
  - The object-occupancy array at 0x163048 is addressed as 270-byte screen blocks in set 2 (s2 0x12D12 and siblings) and as a flat 72-byte-per-row array in set 1 (s1 0x1186A).
  - s2 0x4762 is merged into s1 0x46FC; both read difficulty 0x16D33C.
- **Data audit** (new). I compared the extra program's data area (s2 0x17C64-0x1CFC6) and the shared ROM data byte by byte, tolerating pointer relocation. In the extra program, the **only content changes are the two D17 tables**, plus one checksum pad word at 0x3938. Animation-sequence tables, handler tables, the solid-object edge table and the height table are identical apart from relocated pointers.
- **Shared ROM data** besides the D11 level lists: about ten small blocks differ in content, not only by relocation. I did not resolve them (see open questions).
- **Exhaustiveness.** Constants, RAM references and data tables are covered completely for the extra program. Control flow in the 61 signature-changed routines was not compared instruction by instruction. So a changed condition that uses the same constants and variables could still be hidden.
- **RAM-trace method.** A plain set 2 against set 1 trace diverges within a few hundred frames from timing and random-number phase (D14). I used the patch A/B instead: same program, one table swapped. It isolates a single cause, and it confirmed D17.

### D15: OS session and minute bookkeeping

The OS keeps the operator Statistics screen. Its counters, by OS index, are: 0 = Plyr 0 Coins, 1 = Plyr 1 Coins, 2 = Total Sessions, 3/4/5 = 0/1/2 Plyr Mins, 6/7 = L/R Plyr Mins, then Error Count. The game reports through OS vectors: 0x192 = player starts, 0x172 = a player's game ends (the game calls it once per player, from rb 0x4945E and 0x494BC), and 0x186 = update with the current player mask (called at attract start and game reset). The time routine (rb 0x4762, s1 0x476C) adds the frames since its last call to each active player's accumulator and to the 0-, 1- or 2-player bucket. Every 14,400 frames (4 minutes) it converts whole minutes (3,600 frames) into counters 3-5 [code].

- **Set 2 and rev B.** Inside the time routine, when the player mask goes from non-zero to zero, the routine adds 1 to Total Sessions and forces the 4-minute flush at once. A session is "from the first player starting until no one is playing".
- **Set 1.** That block is gone from the time routine (s1 goes straight from the bucket update to the 4-minute check at 0x47C0). Instead the per-player end routine adds 1 to Total Sessions every time it runs (s1 0x4946). So **Total Sessions counts player games**, and the 0/1/2-player minutes are flushed only on the 4-minute cadence.
- MAME, with breakpoints on the counter-add routine (rb/s2 0x4322, s1 0x432C, counter 2) and a two-player game with both players dying [MAME]:
  - set 2: player-end for P1 at frame 2924 (no count), for P2 at 3381, one count;
  - rev B: one count, at the second player-end;
  - set 1: player-end at 2932 and 3811, a count at each, two counts.
- **What the operator sees.** For the same play, set 1's Total Sessions is higher by one for every two-player game, and "Avg Time/Coin" is unaffected. A 1-player game counts 1 in all three revisions. Statistics from a set 1 board and a set 2 or rev B board are not comparable for this line.

### D16: histograms and the EEPROM directory

- The game header word at 0x2006E holds an OS configuration byte at 0x2006F: 0x3E in set 2 and rev B, 0x3C in set 1. Its low three bits are the number of histograms (6 versus 4). The OS uses this number to size its RAM statistics buffer (s1 0x3DBC: n x 0x14 + 0xE6 bytes) and to check the stored EEPROM record count, 9 + 2n (s1 0x3E5A) [code].
- **Self-test** [MAME, service-mode boot, stepping with Left Jump + Left Fire]:
  - Set 2 shows Histograms 1-6: New Games, Continuations, Level Quit At, Deaths per Level, Time per Level Single, Time per Level Double.
  - Set 1 shows only Histograms 1-4, ending at Deaths per Level with the "clear all histograms" prompt.
  - Both histogram name strings are still in set 1's ROM.
  - The Statistics screen labels are identical in both.
- **EEPROM consequences** [MAME, cold-boot images]:
  - the directory byte at EEPROM offset 0x1D (mirrored at 0x3B) is 0x15 in set 2 and 0x11 in set 1, which is 9 + 2n;
  - the bytes at 0x0F, 0x11, 0x13 and 0x17 (and mirrors) also differ; they are the directory's other fields and checksums [inferred];
  - the statistics block starts at EEPROM 0x13B in set 2 and 0xFF in set 1, which is 0x3C bytes earlier, two 30-byte histogram records fewer.
- This explains the earlier "second differing EEPROM default word": it is the OS layout descriptor, not an operator option.

### Things checked and found not to differ

- The attract cycle and its screens.
- The canal timer length.
- The sector and level order.
- The bonus, lives and continue tables.
- All self-test text (only prefix bytes moved).
- The coin and credit menus.
- The Statistics screen layout.
- The extra CPU's gameplay constants and all its data tables except the two D17 tables.
- "INSERT COIN(S)" and "ADD COINS TO START": all three revisions contain both and show both in attract [MAME]. **Seeing INSERT COIN(S) on the owner's cabinet does not identify a revision.**

## Cabinet type (JAMMA or dedicated): nothing found

- **Input ports.** All three video programs read 0x260000, 0x260010/11 and the ADC 0x260020-27 the same number of times, with the same bit tests:
  - bit 0 of 0x260000, nine times;
  - bits 0, 1, 3 and 4 of 0x260011, 14, 10, 2 and 1 times.

  The extra CPU programs match each other too.
- **Hardware writes.** These are the same apart from D13. Watchdog, latch, JSA reset and command, and EEPROM unlock all match.
- **Coins.** Coins are read by the JSA 6502, whose program is identical in both sets. The coin menus (left and right mech multipliers, bonus adder, coin modes) are identical text, and the coin code paths match.
- **No cabinet setting.** There is no option bit, EEPROM field or string for cabinet type or control style in any revision.
- **The one control-related addition** is set 1's JOYSTICK POSITION (normal or rotated 90° clockwise). It is an orientation setting for how the stick is mounted, available on any cabinet. It cannot be what separates the sets, because the owner's dedicated cabinet runs rev B, which comes *between* set 2 and set 1 [inferred].
- **Conclusion.** Nothing in the code supports a "set 1 = JAMMA, set 2 = dedicated" split, or the reverse. This agrees with the earlier findings: identical memory maps, the last two digits of the part number being a board-position code, and the CPU part varying across both cabinet types.

## What this means for comparing captures

- **Owner's board (rev B) against the core running set 2.** The attract sequence should match pixel for pixel. Gameplay drifts in phase and random outcomes. The only rule difference is the bonus-life cap above 1,000,000 points.
- **Owner's board against the core running set 1.** Expect these differences:
  - STAND BY during the canal;
  - the GOOD JOB communicator picture and cue 0x6E on entry to levels 5 and 13 (RESCUE HOSTAGES and 0x6B on rev B), with the cue sent about 1 second later;
  - level-1 collision around the rope by the STARS cabinet (no visual difference), and slightly different sliding at rail ends and corners everywhere (D17);
  - the 3/10 max-lives menu;
  - only 4 histograms in self-test, and Total Sessions counted per player game;
  - different EEPROM defaults and layout;
  - larger timing drift, because of the rebuilt code.
- **The core.** It should use one EEPROM image per set.

## Method

The analysis tools and MAME Lua harnesses read ROM data, so they are kept outside this repository; the descriptions below say what each did.


- **Images.** I built 0xA0000 video images and 0x80000 extra images from the chip files using ROM_LOAD16_BYTE interleave, with rev B's 40E/50E pair at 0x90000. They are byte-identical to the earlier STAND BY investigation's MAME dumps apart from unmapped fill. I reused the earlier STAND BY investigation's full MAME disassemblies.
- **Tools.** All Python was run with `python3 -I`.
  - The first pass is in the analysis workspace:
    - `mdiff.py`: normalised instruction diff with move detection;
    - `rcmp_strict.py` and `gaps.py`: byte comparison with relocation, where pointers are validated through the address map;
    - `funcs.py`, `feat.py`, `fmatch.py` and `tokdiff.py`: routine split, feature signatures, matching and semantic token diffs;
    - `strs2.py`: string comparison;
    - plus jump-table, task-mask and RAM-variable cross-references.
  - This follow-up is in the analysis workspace:
    - `kconst.py` and `kctx.py`: global constant histogram and per-constant instruction contexts;
    - `xrel.py` and `xwin.py`: relocation-tolerant data comparison;
    - `grid.py`: level-grid dump and diff;
    - `png.py` and `annot.py`: pure-Python PNG compositing and cell annotation;
    - `trcmp.py`: trajectory divergence.
- **MAME.** Version 0.289 headless with Lua.
  - First pass (the analysis workspace):
    - `tl.lua`: attract text timeline;
    - `canal.lua`: coin, start, forced level exit, alpha-text, sound-command tap and RAM dumps.
  - Follow-up (the analysis workspace):
    - `h.lua`: coin and start, analog stick schedule, RAM pokes, RAM dumps, snapshots, EEPROM write tap, and patching the extra ROM region for the A/B test;
    - `hd.lua` with `-debug -debugger none`: breakpoints with printf on the OS vectors and the counter-add routine;
    - `canal.lua` (copy): transition snapshots;
    - `tl.lua` (copy, plus soft reset): service-mode navigation.

  Set 1 and set 2 ran from the original rompath. Rev B ran from the earlier STAND BY investigation's scratch rompath, where the 32 KB pair is mirrored, which is functionally equivalent.

## Open questions

1. **Extra CPU control flow (set 2 to set 1).** Constants, RAM references and all extra data tables are covered. The 61 signature-changed routines were not compared at the control-flow level, so a changed condition built from the same constants could remain.
2. **Unresolved shared-ROM data blocks.** Besides the D11 level lists, a few shared-ROM blocks differ in content. Set 2 offsets:
   - 0x6E312: animation or behaviour script, with commands inserted in set 1;
   - 0x70C92: a script sequence;
   - 0x72B72: an object list used by video 0x34EDC, with one entry removed;
   - 0x72CF2: one record's flag byte, 0x20 to 0x04;
   - 0x75DD2: a run of 0x3Fxx words that becomes flat 0x4000;
   - 0x76492: one cell word, 0x000C to a wall cell 0x1FF0;
   - 0x76B72 and 0x76C12: grid-cell stamp templates using cell words such as 0x8260 and 0x61B0, with cells added or changed.

   Their users and on-screen effect were not traced. Several look like map or collision templates, related to D11 and D17 [inferred].
3. **The type-2 level additions of D11** (two type-0x12 cells in levels 8, 12 and 15) were not visited in MAME.
4. **The owner's 40K/50K and 10S/10U chips.** Their labels are still unread. All conclusions assume 1032/1033 and 1034/1035, because rev B only runs with those.
