# Escape from the Planet of the Robot Monsters: what changed between program revisions

Three program revisions are compared:

- **Set 2.** MAME `eprom2`. Every program chip is a -1xxx part. The 40E/50E pair is 64 KB each at 0x80000.
- **Rev B.** The owner's board, not in MAME. The 40A/50A chips are -2024/-2025. The 40B/50B and 40D/50D chips are -3026 to -3029. The 40E/50E pair (-1030/-1031) is 32 KB each at 0x90000.
- **Set 1.** MAME `eprom`, the parent set. Its 40A/50A, 40B/50B and 40D/50D chips are -3/-4 parts. The shared pair is 2032/2033 and the extra-CPU pair is 2034/2035. It has no 40E/50E chips.

Each claim carries one of three tags:

- **[MAME]**: confirmed by running MAME 0.289.
- **[code]**: confirmed by reading the disassembly.
- **[inferred]**: a reasoned reading that has not been verified.

Addresses are CPU addresses. "Video" means the maincpu program and "extra" means the second 68000.

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
| D5 | set 1 | Operator menu rebuilt. EEPROM option-word bit layout changed. New options FBI WARNING DISPLAYED and JOYSTICK POSITION. MAX LIVES reduced to 3/10. Labels uppercased | Operator. NVRAM is **not interchangeable** between sets | menu table 0x20119 (s2 = rb) / 0x20119 (s1) | [code], default words [MAME] |
| D6 | set 1 | Factory-default option word changed from 0x44BA to 0x46BA | Operator: defaults are max lives 10 and FBI screen on | EEPROM image after a cold boot | [MAME] |
| D7 | set 1 | The "Winners Don't Use Drugs" FBI screen becomes optional (bit 9). It is always shown in set 2 and rev B | Attract mode (it is at the end of the credits roll, which did not occur within 16,000 frames) | rb 0x33BFC-0x33C5E / s1 0x41FDC | [code] |
| D8 | set 1 | JOYSTICK POSITION "rotated 90 degrees clockwise" swaps each player's analog X and Y ADC channels in the OS stick reader | Only when enabled | s1 0x20BC-0x20D4 and 0x584A (sets the flag at 0x3F50A8); reader 0x5CFA-0x5E32 | [code] |
| D9 | set 1 | STAND BY appears in the idle player's panel during the canal stage (state 0x18) | Player (the known difference) | set 2 0x3D018 / rev B 0x3E502 / set 1 0x4B6A8 (P1) and 0x4BA36 (P2) | [MAME] (`can_*` runs) and on device |
| D10 | set 1 | Level-entry transition picture and music: when entering a type-0 level after a type-2 level, set 1 chooses the variant by bit 2 of the level index; set 2 and rev B use bit 1. Set 1 also sends the music cue about 60 frames later | Player: entering level 5 and level 13 plays cue 0x6E in set 1 but 0x6B in set 2 and rev B. Level 9 is the same in all | rb 0x340EE / s1 0x424A4 (start deferred through 0x16D35C, sent at 0x426CA) | [MAME] sound commands, [code] picture |
| D11 | set 1 | Level geometry data changed: level 1 in every sector; sector D level 7; levels 8, 12 and 15 | Player (map features). The level-1 map grid differs in 2 cells | type-0 list table s2 0x2DFF0 / s1 0x3B764; type-2 list table s2 0x738F6 / s1 0x3AEEE | [MAME] grid diff, [code] tables |
| D12 | set 1 | Developer level/sprite editor ("Factory:", PF/MOB editor) removed, with its debug hooks | No: it is unreachable in set 2 and rev B (see below) | rb 0x499D4-0x4D45A; start-flag checks on 0x16D2F0 | [code] |
| D13 | set 1 | Dead debug routine removed: it sent pulse codes on bit 6 of the 0x360010 latch | No | rb 0x3265C-0x32726, no callers | [code] |
| D14 | set 1 | Whole program rebuilt with newer code generation and a re-laid-out RAM map around 0x16D340-0x16D35C. The extra CPU and the shared ROM code were rebuilt too | Indirectly: CPU load and frame-phase timing differ, and random outcomes diverge | throughout | [code] |
| D15 | set 1 | OS game-time bookkeeping: the 14,400-frame (4-minute) audit-counter logic moved or changed | Operator audit statistics only | rb 0x4762-0x482E / s1 0x476C-0x4822 and 0x4946 | [inferred] |
| — | — | Things that do **not** differ | | | |
| N1 | — | Self-test and attract text; the attract sequence and its timing (title, high scores, demo); INSERT COIN(S) and ADD COINS TO START prompts | | attract timeline runs `att_*` | [MAME] |
| N2 | — | Canal countdown length: the time-out comes at frame 5222 in set 1 and frame 5224 in set 2, out of about 2,215 canal frames | | `can_*` runs | [MAME] |
| N3 | — | Per-sector level order, level-type table, bonus thresholds (100k/200k/400k), lives and continue tables | | shared tables 0x7391A-0x73C4C, 0x74240-0x7450E (set 2) and set 1 +0x1250 | [code] byte-identical |
| N4 | — | Input-port usage, the bits tested, the coin path | | see the cabinet section | [code] |

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
- **For a capture of the owner's board.** Rev B behaves like set 2 in every respect except D1 and timing phase. Running the core on set 2 is the closest reference. Expect pixel-identical attract mode and drift in gameplay.

## Set 1 compared with rev B, in detail

**Method caveat.** Set 1 was rebuilt with different code generation. For example, it uses `lea abs.l` and `pea #imm` where the older build used `movea.l #` and `move.l #,-(A7)`. It also allocates registers and schedules instructions differently, and it shifts the RAM map (for example 0x16D34E/50 became 0x16D352/54). Only about 19% of 32-byte blocks match at the same offset. Line-level diffs are therefore noisy. The items below were each checked by reading the disassembly or by running MAME. The search for gameplay-logic changes in the extra CPU is **not exhaustive** (see the open questions).

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
- **NVRAM compatibility.** The two EEPROM images differ in that word, in one more format/flag byte and in the checksums.
- **For the FPGA core:** do not carry an EEPROM image between sets. Set 1 reads a set 2 or rev B image with the continuation, special-cost and FBI bits reinterpreted. Max lives is also misread whenever bits 10-9 are not 00 or 11.

### D7: FBI screen

- In set 2 and rev B, step 5 of the attract credits roll always draws the FBI seal from alpha tiles and shows the "Winners Don't Use Drugs" text (rb 0x33C08-0x33C5E).
- Set 1 checks 0x16D350, which is option bit 9, first (0x41FDC).
- Set 1's default is "yes", so out of the box the behaviour is the same.

### D8: joystick rotation

- At boot, set 1's OS reads option bit 2 and stores it at 0x3F50A8.
- When the flag is set, the stick reader takes each player's horizontal reading from the vertical ADC byte and the vertical reading from the horizontal byte (0x3F7FE2/E3 for P1, 0x3F7FE4/E5 for P2).
- I did not determine whether an axis is also inverted.

### D10: level-entry transition

- The transition task (task 0x1A; rb 0x34274, s1 0x4264E) picks a playfield picture and a music cue.
- When the level being entered is type 0 and the adjacent level is type 2:
  - Rev B and set 2 test bit 1 of the level index. Bit 1 is 0 for indices 4, 8 and 12, so they always pick picture 0x184BF with cue 0x6B.
  - Set 1 tests bit 2. Indices 4 and 12 give picture 0x17A9D with cue 0x6E.
- In MAME with the level forced to 5, 9 and 13: set 1 sends cues 0x6E, 0x6B and 0x6E; set 2 and rev B send 0x6B every time [MAME].
- Set 1 sends the cue at frame 2640, in state 0x1E. Set 2 and rev B send it at frame 2580, in state 0x1F.
- I did not obtain a clean visual comparison of the picture.

### D11: level geometry data

Level maps are built from 6-byte records (type 0) or 8-byte records (type 2), each giving a feature type and a cell rectangle. The parsers are s2 0x40AF2 and s2 0x40FAA.

| Level list | Used by | Change in set 1 |
|---|---|---|
| Type-0 list 0 | **Level 1 of every sector** | Three single-cell type-0x12 records at cells (2,0xA0), (4,0xA4) and (6,0xA0) are replaced by one at (9,0xA5) |
| Type-0 list 4 | Sector D level 7 | The type-0x18 rectangle is removed; the type-0x16 and type-0x19 rectangles are reshaped |
| Type-2 lists 1, 3, 5, 7, 8 | Level 8 of sectors M, D and B; level 12 and level 15 of every sector | Two single-cell type-0x12 records are added at (0x17,0x0C,h4) and (0x17,0x0E,h4) |

- All other lists are byte-identical. Set 1 also swapped which ROM holds each group of lists.
- In MAME, the live level-1 map grid (0x1688E0) differs between set 1 and set 2 in exactly 2 cells, (4,0xA4) and (9,0xA5) [MAME].
- The on-screen meaning of type 0x12 has not been identified. These cells were not in view at the level-1 start, and the start screen matched apart from robot animation phase.
- This probably contributes to the earlier finding that set 1 gameplay "diverges deeper" than rev B's.

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

### D14: rebuild

The extra-CPU program and the code at the start of the shared ROM were also recompiled. A feature-level comparison of the extra CPU found many restructured routines (for example s2 0x4762, merged into s1 0x46FC, which uses difficulty 0x16D33C). I did not identify any confirmed rule change there. I also did not rule one out.

### Things checked and found not to differ

- The attract cycle and its screens.
- The canal timer length.
- The sector and level order.
- The bonus, lives and continue tables.
- All self-test text (only prefix bytes moved).
- The coin and credit menus.
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
  - different music on entry to levels 5 and 13, with the cue sent about 1 second later;
  - level-1 map features;
  - the 3/10 max-lives menu;
  - different EEPROM defaults;
  - larger timing drift, because of the rebuilt code.
- **The core.** It should use one EEPROM image per set.

## Method

- **Images.** I built 0xA0000 video images and 0x80000 extra images from the chip files using ROM_LOAD16_BYTE interleave, with rev B's 40E/50E pair at 0x90000. They are byte-identical to the standby agent's MAME dumps apart from unmapped fill. I reused the standby agent's full MAME disassemblies.
- **Tools.** All Python was run with `python3 -I`. The scripts are in `romdiff/tools/`:
  - `mdiff.py`: normalised instruction diff with move detection;
  - `rcmp_strict.py` and `gaps.py`: byte comparison with relocation, where pointers are validated through the address map;
  - `funcs.py`, `feat.py`, `fmatch.py` and `tokdiff.py`: routine split, feature signatures, matching and semantic token diffs;
  - `strs2.py`: string comparison;
  - plus jump-table, task-mask and RAM-variable cross-references.
- **MAME.** Version 0.289 headless with Lua (`romdiff/mame/`):
  - `tl.lua`: attract text timeline;
  - `canal.lua`: coin, start, forced level exit, alpha-text, sound-command tap and RAM dumps.

  Set 1 and set 2 ran from the original rompath; rev B ran from the standby agent's scratch rompath, where the 32 KB pair is mirrored, which is functionally equivalent.

## Open questions

1. **Extra CPU (set 2 to set 1).** The rebuild hides any rule changes. An exhaustive semantic comparison, or a long scripted-play RAM trace compared state by state, is still needed.
2. **Map feature type 0x12.** Its visual meaning is unknown. Run level 1 to cell (4,0xA4) or (9,0xA5) in both sets and compare snapshots.
3. **Transition pictures.** The pictures 0x17A9D and 0x184BF were not compared visually. The forced-exit snapshots showed only blank fade frames.
4. **D15 and the second EEPROM word.** The set 1 OS audit-timer change, and the meaning of the second differing EEPROM default word, are not yet decoded.
5. **The owner's 40K/50K and 10S/10U chips.** Their labels are still unread. All conclusions assume 1032/1033 and 1034/1035, because rev B only runs with those.
