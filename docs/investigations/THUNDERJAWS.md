# ThunderJaws (Atari, 1990) — could this core run it?

**Status: research only. No RTL, no ROM builder, no romset on this machine.**
Everything below is read from MAME source (`thunderj.cpp`, `atarivad.cpp`,
`atarijsa.cpp`, `atarimo.cpp`, master branch, fetched 2026-09-09), from the
owner's *ThunderJaws Universal Kit Installation Instructions* (TM-349, 56 pp,
scanned — cited as "manual pN" by PDF page, with the printed sheet number where
one exists), and from this repo's RTL and docs. Where a claim is inferred rather
than read, it says so.

Short version: ThunderJaws is the same CPU/sound/memory architecture as Escape
with a **different video chip** (Atari VAD) in place of Escape's discrete
playfield/MO/GPC logic. The CPU pair, shared RAM, interlock, SDRAM fabric, JSA
board and the motion-object line engine carry over; the two-playfield scanout,
the priority PAL, the palette and the alpha bank do not. It is a **separate
core built from this repo's blocks**, not a switch in this one.

---

## 1. Board inventory (MAME + manual)

### 1.1 CPUs and clocks

| Item | ThunderJaws | Source | Escape (for contrast) |
|---|---|---|---|
| Main ("video") CPU | 68000 in MAME; **`U68010` on the schematic** (10D) | `thunderj.cpp` `M68000(config, m_maincpu, 14.318181_MHz_XTAL / 2)`; manual p40 (sheet 5-6) | same story: MAME 68000, SP-332 `U68010`, `CPU_AND_ARBITER.md` §1.6 |
| Extra ("secondary") CPU | 68000 in MAME; `U68010` on schematic (13M) | `thunderj.cpp` `M68000(config, m_extra, ...)`; manual p42 (5-8) | same |
| CPU clock | 7.159 MHz: 14.318 MHz crystal X1 → F04 → F74 (3J) ÷2 = `MCKR`; `VCLOCK`/`ECLOCK` | manual p44 (5-10), p40, p42 | identical |
| Sound CPU | 6502A @ 3.579545/2 = 1.79 MHz | `atarijsa.cpp` `M6502(config, m_jsacpu, JSA_MASTER_CLOCK/2)`; manual p48 (5-14) 1D, "1790K" on Ø0 | identical |
| Pixel clock / raster | 7.159 MHz, 456 × 262 total, 336 × 240 active | `thunderj.cpp` `set_raw(14.318181_MHz_XTAL/2, 456, 0, 336, 262, 0, 240)` — MAME's own comment: "from published specs, not derived; the board uses a VAD chip to generate video signals" | identical numbers (`eprom.cpp:892`) |
| Manual's monitor spec | 15.750 kHz H, 60 Hz V, RGB positive or negative composite sync | manual p8, Table 1-1; p27 Table 3-4 (VID connector: +H, +V, −composite) | — |

The `CPU_TYPE` generic argument from Escape (`escape_core.vhd`, CPU-110)
transfers unchanged: the kit schematic draws 68010s, MAME instantiates 68000s,
and no evidence here says which shipped in the kit. Both TG68K modes exist.

### 1.2 Memory map — main CPU (`thunderj.cpp` `main_map`)

| Range | Size | Purpose | Notes |
|---|---|---|---|
| `000000-09FFFF` | 640 KB | program ROM | 14E/C,15E/C,16E/C = `0x00000-5FFFF`; **15H/16H = `0x60000-7FFFF` is the common ROM on the ECPU bus** (manual p43, `CROM` U27512 pair, `/CROM` from PAL16L8 `ECOM` 13J); 17E/17C = `0x80000-9FFFF` |
| `0E0000-0E0FFF` | 2 KB × 8 | EEPROM 2816, **low byte only** (`umask16(0x00ff)`), `lock_after_write` | manual p40: 2816A-30 at 12C, `/UNLOCK` LS74 10H |
| `160000-16FFFF` | 64 KB | shared RAM ("common") | manual p43: two 32K×8 (13/14H, 17H), `/COMRAM` from `ECOM` PAL |
| `1F0000-1FFFFF` | — | W: EEPROM unlock | |
| `260000-26000F` | — | R: port "260000" — **all bits unused** in MAME | manual p38: LS257 17A reads a `PT-` test connector, RP1 "NOT STUFFED" |
| `260010` | — | R: P1 joystick/buttons (D15..D8) | manual p38: 13B/16A LS257s |
| `260012` | — | R: P2 joystick/buttons (D15..D8) + status D0 `/VBLANK`, D1 self-test, D2 `/SINT`, D3 `/SCBSY` | manual p38 16B; MAME `special_port2_r` XORs bit 4 |
| `260031` | byte | R: JSA response latch | via SCOM serial link, manual p37 (15B) |
| `2E0000` | — | W: watchdog | manual p40: LS197 9H clocked by `/VBLANK`, `WDIS` jumper |
| `360010` | — | W: latch — D0 `/ERESET` (extra CPU reset, 0 = held), D2..D4 alpha bank (`(data>>2)&7`) | manual p39: LS174 17B — `/ERESET`, `CRBK0`, `ALBK0..2` |
| `360020` | — | W: sound reset | |
| `360031` | byte | W: JSA command latch | |
| `3E0000-3E0FFF` | 4 KB | palette, 2048 × 16, format **IRGB 1555** | `PALETTE(...).set_format(palette_device::IRGB_1555, 2048)` |
| `3EFFC0-3EFFFF` | 64 B | **VAD control registers** (32 words) | `atari_vad_device::control_read/write` |
| `3F0000-3F1FFF` | 8 KB | playfield 2 RAM (`playfield2_latched_msb_w`) | VAD |
| `3F2000-3F3FFF` | 8 KB | playfield 1 RAM (`playfield_latched_lsb_w`) | VAD |
| `3F4000-3F5FFF` | 8 KB | playfield **ext** RAM, shared by both playfields (`playfield_upper_w`) | low byte → PF1 attributes, high byte → PF2 |
| `3F6000-3F7FFF` | 8 KB | motion-object RAM | |
| `3F8000-3F8EFF` | 3.75 KB | alpha RAM (64 × 30 + the rowscroll columns) | |
| `3F8F00-3F8F7F` | 128 B | VAD **EOF list**: up to 0x1C control words re-applied every frame | `eof_update` |
| `3F8F80-3F8FFF` | 128 B | SLIP pointers | |
| `3F9000-3FFFFF` | 28 KB | work RAM | |

Compared with Escape (`ARCHITECTURE.md` "Memory map"): the I/O block
(`260xxx`/`360xxx`) is the same decoder family (LS138 9J, manual p39, decodes
`/SCOMRD`, `/SWITCH`, `/SCOMWR`, `/SNDRES`, `/LATCH` — the same five strobes),
the shared RAM is at the same address and size, the video RAM block is laid out
differently and there is no ADC, no video-off/intensity latch and no per-layer
colour RAM.

### 1.3 Memory map — extra CPU (`extra_map`)

| Range | Purpose |
|---|---|
| `000000-03FFFF` | own ROM: only 17L/17N (128 KB) populated; 16L/N and 15L/N are empty sockets (manual p42; MAME loads 2 × 64 KB) |
| `060000-07FFFF` | `ROM_COPY` of main `0x60000` — physically the common ROM 15H/16H seen through the ECPU bus (manual p43) |
| `160000-16FFFF` | shared RAM |
| `260000-260013`, `260031`, `360010`, `360020`, `360031` | the same I/O as the main CPU |

### 1.4 How the two 68000s share memory

**Identical to Escape, part for part.** Manual p40 (sheet 5-6) draws the
cross-coupled NOR latch `ENOWAI = NOR(/ECOM, EWAI)`, `EWAI = NOR(/COM, ENOWAI)`
at 9M (LS02), the F163 wait-state counter at 12H feeding `/DTACK`, and the main
address decoder `MAIN PAL20L10` at 12/13E producing `/COM`, `/ROM0-3`, `BS13/14`.
Manual p42/p43 draw the ECPU side: LS163A 11M wait counter, LS158 11L control
mux selected by `EWAI`, PAL16L8 `ECOM` 13J producing `/ECOM /COMRAM /CROM /CIO
/EROM0-2`. Compare `ARCHITECTURE.md` "Findings from the full schematic re-scan":
60N/20J NOR pair, 30D/30L counters, 50P decoder, 30M LS158 — same circuit, new
designators. MAME models none of this and uses `set_perfect_quantum`
("perfect synchronization due to shared RAM").

Consequences for us: `shared_ram` (dual-port BRAM), the TAS interlock
(`TASLOCK_EN`), the `e_bus_yield` fairness fix (BUS-99) and the extra-CPU
reset-bit semantics all apply as they stand. What does **not** carry over is
the game-specific handshake: Escape's `0x16FFE0/E2` mailbox, `$16CCD4/D6`
frame flags and the `EIRQ_MODE=2` arming address are Escape ROM conventions
(`PIPELINES.md` §4.2 says so explicitly). ThunderJaws' equivalents are unknown
until traced; `thunderj.cpp`'s header names one — CPU 1 stores VAD scanline
reads in a table at `$163484` and CPU 2 checks them (§5).

SLAPSTIC: socket 13C `SLAPSTK5` is drawn and marked **NOT STUFFED** (manual
p40); MAME has no slapstic window. Same situation as Escape, resolved the same
way (absent).

### 1.5 Interrupts

| Line | Source | Sink | Source of claim |
|---|---|---|---|
| IRQ4, both CPUs | **VAD scanline interrupt** — fires at the scanline programmed in VAD register 3, acked by a write to register 0x1E | `scanline_int_write_line` sets IRQ4 on `m_maincpu` and `m_extra`; manual p40/p42 IPL wiring (`/VINT`) | Escape: fixed VBLANK, acked at `360000` |
| IRQ6, main only | JSA `/SINT` | `m_jsa->main_int_cb().set_inputline(m_maincpu, M68K_IRQ_6)`; manual p40 11H LS08 combining `/VINT`,`/SINT` onto IPL | identical |
| autovector | VPA from FC=111 (LS11 10J / LS00 12J) | manual p40, p42 | identical |

Register 0 of the VAD reads back the **current scanline** (clamped to 255) with
bit 0x4000 set in vblank (`control_read`). MAME's driver header explains it
must fake this ($F5/$F7 alternately) because its CPU interleaving cannot hit
the tolerances CPU 2 checks; a raster-exact core does not need the fake, but it
does need its line counter to agree with the VAD's numbering, which nothing in
MAME derives.

### 1.6 Inputs and EEPROM

- Per player: 8-way joystick + two buttons ("Fire/attack", "Jump"), manual p13;
  kit ships 2 × `A040933-03 8-Way Joystick Assembly`, red and blue button
  assemblies (p8 Table 1-2). Switch-test names: Left/Right FIRE, JUMP, Joystick
  R/L/D/U (p21 Fig 2-6). No analog input — the `hall_stick.v`/ADC path is not
  needed.
- Bit map (MAME `260010`/`260012` + manual p38): D8 FIRE, D9 JUMP (`ACTA`),
  D10/D11 unused (`ACTB`, `STRT` — wired to the LS257 but MAME marks them
  unused), D12 right, D13 left, D14 down, D15 up, all active low.
- **Coins go to the JSA-II**: JAMMA COIN1/COIN2 (JAM-16 / JAM-T) are routed
  straight to the audio connector AUD-36/AUD-35 (manual p36, sheet 5-2), and
  `jsa_ii_ioports` reads them at `/RDIO` bits 0/1. Same as Escape's JSA-I.
- Self-test switch: SW1 on the game PCB (p37) and a second on the JSA (p50),
  read at `260012` D1 and mirrored to the JSA `/RDIO` bit 7 via `test_read_cb`.
- EEPROM: **2816 (2 KB × 8)**, not Escape's 2804 (512 B). `ee_save.vhd` scales
  (the APF save slot size and the `ee_ram` width change); the unlock protocol
  (`1Fxxxx` write, lock after write) is the same `eeprom_parallel_28xx_device`.

### 1.7 Video — the VAD

What MAME tells us (`atarivad.cpp`, `thunderj.cpp`); the manual's schematic set
**does not include the VAD or its memories** — the game-PCB sheets are SI/O,
I/O, VCPU, ECPU, VRAM (which is only the sync buffers and the clock oscillator)
and RGB (pp. 36–45). The VAD is a black box here except for its register map
and the priority GAL equations that MAME quotes as "verified from the GALs on
the real PCB".

**Layers.**

| Layer | Geometry | Tile word(s) | Pen / palette | MAME |
|---|---|---|---|---|
| Playfield 1 | 64 × 64 tiles of 8 × 8, `TILEMAP_SCAN_COLS` | base word: code `[14:0]`, hflip `[15]`; ext low byte: colour `[3:0]`, **priority category `[5:4]`** | gfx 0 ("tiles", 4bpp planar), colour `0x10 + c` → pens `0x200 + c*16 + pix` | `get_playfield_tile_info` |
| Playfield 2 | same, own base RAM at `3F0000`; own scroll | base word same; ext **high** byte: colour `[3:0]`, category `[5:4]` | same gfx 0, colour `c` → drawn with priority-bitmap flag `0x80`; the GAL sets **CRA9 = PFXS** so PF2 pixels index `0x300 + c*16 + pix` | `get_playfield2_tile_info`, `screen_update` |
| Motion objects | atarimo, 4-word entries, linked, SLIP every 8 lines, reverse order, 1 bank | w0 link `[9:0]`; w1 code `[14:0]`, **hflip `[15]`**; w2 colour `[3:0]`, priority `[6:4]`, x `[15:7]`; w3 y `[15:7]`, width `[6:4]`, height `[2:0]` | gfx 1 ("sprites"), palette base `0x100` | `s_mob_config` |
| Alpha | 64 × 30, `TILEMAP_SCAN_ROWS` | code `[8:0]` + bit 9 selects the **3-bit bank** from the `360010` latch (`bank * 0x200`); colour `[13:10]` + bit 14 → `0x20`; opaque `[15]` | gfx 2 ("chars", 2bpp `anlayout`), base 0 | `get_alpha_tile_info`, `latch_w` |

So: **not** an 8bpp playfield made of two 4bpp tilemaps — two independent 4bpp
playfields, PF2 drawn over PF1 where its pixel is non-zero, each with a per-tile
2-bit priority class against sprites. Escape has one playfield and no
per-tile priority class (its 2-bit PF priority is the low two colour bits,
`escape_prio.v` header).

**MO entry vs Escape** (`eprom.cpp` `s_mob_config` vs `thunderj.cpp`): every
mask is identical except **hflip** (Escape w3 bit 3, ThunderJaws w1 bit 15 —
the same place as Escape's *guts* config). Palette base, transparent pen,
SLIP height, link mask, reverse order, 1 bank: all the same.

**Priority / colour-index generation** (`thunderj.cpp` `screen_update`, GAL
equations quoted there; MO priority bits MPR2..0 = w2 `[6:4]`):

1. MPR2 set → "special": draws nothing, but marks the pixel; second pass runs
   `apply_stain` (OR `0x400` into the pen) from pixels whose pen has bit 1 set
   — **byte-identical to Escape's stain mechanism** (`atarimo.cpp`
   `apply_stain`, `escape_stain.v`).
2. `PF/M = 1` (playfield wins) if MO pen byte `== 0x01` (colour 0, pixel 1 —
   `MPX0*!MPX1..!MPX7`), else if PF pixel bit 3 (`PFX3`) is set and
   `(pfpri==3 && !MPR0) || (pfpri&1 && MPR==0) || (pfpri&2 && !MPR1)`, where
   `pfpri` is PF2's category if a PF2 pixel is showing (`pri & 0x80`), else
   PF1's. Reading those three terms as a table: category 1 beats MO priority
   0, category 2 beats 0–1, category 3 beats 0–2 — i.e. **PF wins ⇔ PFX3 ∧
   (MPR < category)**. Inference from the equations, to be machine-checked
   the way `tb_prio.v` checks Escape's (`escape_prio.v` header).
3. Otherwise the MO pen (`0x100 | colour<<4 | pix`) replaces the playfield pen.
4. Alpha drawn last, wins outright wherever `APIX != 0` or opaque (`CS0/CS1`
   both require `!ALBG*!APIX0*!APIX1`) — same rule as Escape (`PIPELINES.md`
   §5.3).
5. No SHADE, no FORCEMC0, no M7-to-colour-RAM path: ThunderJaws' GAL has
   nothing corresponding to Escape's alternate playfield colour bank.

**Palette**: 2048 entries, `IRGB_1555` — 5 bits per gun plus one shared
intensity LSB. The RGB sheet (manual p45, 5-11) confirms it: each gun is an
R/2R pack (RP2/3/4) with D1..D5 = `R1..R5` and D0 = the shared `RGB0`. Escape
is IRGB4444 with a 4-bit intensity and a global intensity latch
(`eprom.cpp` `update_palette`, `core_top.v:2763`). Different, and simpler.

**VAD control registers** (`atarivad.cpp` comment block; MAME implements only
a subset): 0 enable, 1–2 vsync/vblank loads, **3 scanline IRQ line**, 4–5
hsync/hblank loads ("batman/thunderj = 0xBEB1"), 6 SLIP load, 7 alpha/PF DMA
config, 8–9 RAM base addresses, **0x0A option bits** (PF2 enable 0x4000,
linescroll enable 0x2000, attribute autostore 0x0080, palette bank 0x0400, and
DMA-cycle options MAME ignores), 0x10–0x1B indexed parameters (MO/PF1/PF2
h/v scroll, 9 bits each, PF1 x-scroll adds PF2's low 3 bits), 0x1E IRQ ack.
The EOF list at `3F8F00` re-applies up to 0x1C words each frame; when
linescroll is enabled, alpha RAM columns 48–63 of each row hold per-scanline
scroll parameters (`update_tilerow`). Whether ThunderJaws enables linescroll
is not stated anywhere read (the comment lists other games' 0x0A values, not
ThunderJaws'); it needs a MAME trace.

### 1.8 Sound — JSA-II

MAME `atarijsa.cpp` (`atari_jsa_ii_device`) and manual pp. 46–51 (sheets
5-12 … 5-17), which **do** include the full JSA Audio II schematic:

| Item | Value | Source |
|---|---|---|
| 6502A | 3.579545/2 MHz | `M6502(config, m_jsacpu, JSA_MASTER_CLOCK/2)`; p48 |
| RAM | 8 KB (8K×8 at 2B) | p48; `atarijsa2_map` `0000-1FFF` |
| Program ROM | 64 KB 27512 at 1B, banked `3000-3FFF` by WRIO[7:6] | p48, `m_cpu_bank` |
| YM2151 | 3.579545 MHz, at 3A, `/YAMRES` from WRIO bit 0 | p50; `YM2151(config, m_ym2151, JSA_MASTER_CLOCK)` |
| OKI MSM6295 | **1.193 MHz** (= 3.579545/3, LS74 6F divide-by-3, p47), **pin 7 = `VFREQ` = WRIO bit 3**, `/OKIRES` = WRIO bit 2; MAME instantiates `PIN7_HIGH` and then follows the bit | p46/p47/p48; `OKIM6295(config, m_oki1, JSA_MASTER_CLOCK/3, PIN7_HIGH)`, `wrio_w` |
| ADPCM ROM | 4 × 27512 = 256 KB at 7D/7E/7J/7K, addressed directly by the 6295's A0–A17 (no banking on JSA-II) | p48/p49; `ROM_REGION(0x40000, "jsa:oki1")` |
| Timed IRQ | LS393 chain from 3579K → `/IRQ`, same period as JSA-I (`JSA_MASTER_CLOCK/4/16/16/14`) | p47; `device_add_mconfig` |
| TMS5220 / POKEY | **none** — the map has `/RDV`,`/WRV` (OKI) where JSA-I has `/VOICE` and POKEY | `atarijsa2_map` vs `atarijsa1_map` |
| `/RDIO` bits | 7 self-test, 6 `/NMI` state, 5 SFULL, 4..2 +5 V, 1 coin 2, 0 coin 1 | `rdio_r`; p47 LS240 2F |
| `/WRIO` bits | 7:6 ROM bank, 5:4 coin counters, 3 VFREQ, 2 `/OKIRES`, 0 `/YAMRES` | `wrio_w`; p49 LS273 4D |
| `/MIX` bits | 5 LPF (unimplemented), 3:1 YM volume 0–7, 0 OKI volume (1.0 / 0.5) | `mix_w`; p49 LS174 3C |
| Routes | YM 0.60, OKI 0.75, **mono** | `device_add_mconfig`; TDA2030 p47 |
| Link to game PCB | SCOM serial (3D, p50) ↔ SCOM 15B on the game PCB (p37) | same as Escape's sheet-2 SCOM |

---

## 2. ROM inventory

From `ROM_START(thunderj)` (rev 3; `thunderja` differs only in `3001/3002` →
`2001/2002`):

| Region | Chips | Bytes | Notes |
|---|---|---|---|
| `maincpu` | 10 × 27512 (14E/C … 17E/C, 15H/16H) | 655,360 (`0xA0000`) | 16-bit interleave (`ROM_LOAD16_BYTE`), as Escape |
| `extra` | 2 × 27512 (17L/17N) + `ROM_COPY` of main `0x60000` (128 KB) | 131,072 loaded; region declared `0x80000` | the copy costs 131,072 more if the image mirrors MAME's region, as Escape's does (`ROMS.md` §2) |
| `jsa:cpu` | 1 × 27512 (1B) | 65,536 | |
| `tiles` | 16 × 27512, `ROMREGION_INVERT`, 4 planes × 256 KB | 1,048,576 | playfield graphics only |
| `sprites` | 16 × 27512, `ROMREGION_INVERT`, 4 planes × 256 KB | 1,048,576 | motion objects only |
| `chars` | 1 × 27512 (4M) | 65,536 | 8 banks of 512 2bpp chars (manual p22: "In the ROM at 4M are eight separate banks") |
| `jsa:oki1` | 4 × 27512 (7D/7E/7J/7K) | 262,144 | |
| `plds` | 7 GALs | 3,584 | not loaded into the core; the priority GAL equations are what matter and MAME quotes them |

**Total loaded: 3,276,800 bytes** (3.125 MB); **3,407,872** if the extra
region keeps MAME's copy in place, Escape-style. Escape's image is 2,228,224
bytes (`ROMS.md`). Both gfx regions would get the same bit-invert + planar→
chunky repack Escape applies to `spr_tiles` (`ROMS.md` §2), size unchanged.

Memory budget: Pocket SDRAM is a 512 Mbit (64 MB) part of which Escape uses
2.2 MB (`PIPELINES.md` §3.2); the Pocket CRAM0 PSRAM is 8 MB; MiSTer's SDRAM
is 32 MB minimum. Capacity is not a concern anywhere. Bandwidth is — §4.

Note the manual's ROM-test screen (p21 Fig 2-8) names the sockets by CPU and
address range (`14E (v0H)`, `15H (c6H)`, `17L (s0H)`, …) and confirms that
15H/16H are "c" = common and 17E/17C are "v8" = main `0x80000`. That is a
free cross-check for a future `build_rom.py` map, the way `ROMMAP.md` was
for Escape.

---

## 3. Reuse map

Blocks named as in `src/fpga/core/rtl/` and `core_top.v`.

| Block | Verdict | Why |
|---|---|---|
| `TG68K` × 2, `escape_decode` split, `CPU_TYPE` generic | **REUSE AS-IS** (CPUs) / **ADAPT** (decode) | Same CPUs, same clock, same autovector scheme. The address decoder is a new table (§1.2/§1.3); `escape_decode.vhd` is 81 lines. |
| `shared_ram` (dpram 64 KB), TASLOCK interlock, `e_bus_yield`, `/ERESET` reset bit | **REUSE AS-IS** | Same address, size and hardware interlock (§1.4). The `EIRQ_MODE=2` arming detector and mailbox snoops are Escape-ROM-specific and must be re-derived or disabled. |
| SDRAM fabric: `sdram_simple`/`sdram_openrow`, speculative fastpath, ROM CDC parity, download writer | **REUSE AS-IS** | ROM regions only move; the per-CPU fastpath caches are address-agnostic. |
| ROM shadows (`vshad*`, `eshad*`) | **ADAPT (re-profile)** | Their ranges came from Escape page profiles (`PIPELINES.md` §3.3). ThunderJaws needs its own profile or none (see the VSHAD3 lesson: a fastpath hit is cheaper than a shadow). |
| `jshad` (64 KB 6502 ROM in BRAM) | **REUSE AS-IS** | Same 64 KB region, same banking. |
| `escape_jsa.vhd` | **ADAPT → JSA-II** | Keep T65, jt51, command/response latches, timed IRQ, bank logic, watchdog (JSAWDG-133). Replace the TMS5220 path with an OKI6295 at `2800`/`2A00`, re-map `/RDIO`/`/WRIO`/`/MIX` bits (§1.8), mono mix at 0.60/0.75. Needs a 6295 core — `jotego/jt6295` is being vendored as `third_party/jt6295` in the working tree right now (uncommitted, with `sim/tb/tb_jt6295.v`), for the Klax/Guts JSA-II work in `KLAX_GUTS.md`; the JSA-II adaptation is therefore shared with that effort, not new to ThunderJaws. |
| `TMS5220.vhd` | **DROP** | Not on JSA-II. |
| `hall_stick.v`, ADC path | **DROP** | Digital joysticks only. |
| `ee_save.vhd`, `ee_ram` | **ADAPT** | 2 KB instead of 512 B; same unlock/lock semantics. |
| `escape_mob.v` (+ `escape_mo_cache.v`) | **ADAPT (small)** | Entry format identical except hflip (w1[15] vs w3[3]) — one mask change. Gfx base becomes the `sprites` region instead of Escape's shared `spr_tiles`. Line-buffer entry `{fpar, tag, special, prio[1:0], colour[3:0], pix[3:0]}` already carries exactly what the ThunderJaws GAL needs (MPR1:0 and the MPR2 special flag). SLIP at a new address, same 8-line granularity. |
| `escape_stain.v` | **REUSE AS-IS** | `apply_stain` is the same atarimo function with the same START/END markers; `thunderj.cpp`'s second pass is the same loop as `eprom.cpp`'s. |
| `escape_prio.v` | **NEW (same shape)** | Different equations: PF wins ⇔ `PFX3 ∧ MPR < category`, plus the "MO pen == 0x01" rule; no SHADE/FORCEMC0/M7-to-CRA; CRA9 = PF2-select. Needs a second playfield pen input, a 2-bit category from the ext byte rather than from the colour, and a PF2-showing flag. Keep the `tb_prio` exhaustive-check method. |
| `escape_pf.v` + fetch ring | **ADAPT ×2** | Two instances: PF1 (base `3F2000`, ext low byte) and PF2 (base `3F0000`, ext high byte), separate 9-bit x/y scrolls (PF1 x adds PF2's low 3 bits), both from the `tiles` region. PF2 pixels non-zero override PF1 before the MO compare. Rowscroll (per-scanline parameters from alpha RAM) is new if the game turns it on. |
| Alpha scanout (`core_top.v:2404-2477`, `chr_ram`) | **ADAPT** | 64 × 30 instead of 64 × 31; 9-bit code + 3-bit bank from the `360010` latch; 64 KB of chars instead of 16 KB. Colour field wider (bit 14 → 0x20). See §4 for where the 64 KB goes. |
| Colour RAM → RGB (`color_ram`, IRGB4444 + intensity) | **NEW (trivial)** | 2048 × 16 stays; decode becomes IRGB1555 (5-bit guns, shared LSB); no intensity/video-off latch. |
| VBLANK IRQ generator + `360000` ack | **NEW** | VAD scanline compare (register 3), ack at register 0x1E, scanline read-back at register 0 with the 0x4000 vblank bit, EOF-list re-application each frame. Small, but it is the piece MAME had to fake, so it deserves a bench against a MAME trace of the values CPU 2 expects. |
| Raster timing (`SYNGEN`-style counters in `core_top.v`) | **REUSE, verify** | Same 456 × 262 / 336 × 240 numbers in MAME. The VAD's H/V load registers are programmable, so the real machine's blanking positions may differ from MAME's "published specs" — record what the game writes to registers 1/2/4/5 before trusting the numbers. |
| HUD / forensics / crash latches | **REUSE AS-IS** | Nothing game-specific in the mechanisms; the probed addresses change. |
| `build_rom.py`, packager ROM guards, `.mra` | **NEW data, same tools** | New chip list, CRCs, layout; the zero-ROM guarantees (`ROMS.md`) carry over unchanged. |

---

## 4. Block-RAM and bandwidth risk

### 4.1 Pocket M10K

Escape sits at **283/308 with VSHAD3 off, 299–308 with it on**
(`PIPELINES.md` §3.2, `SDRAM_ARCH.md` §5, `core_top.v:2914`). Counting 16-bit
memories at ~1 KB per M10K (512 × 20 geometry), the game-RAM demand moves:

| Memory | Escape | ThunderJaws | Δ (KB) |
|---|---|---|---|
| shared RAM | 64 | 64 | 0 |
| playfield RAM(s) | 8 (pf) + 8 (pfpal) | 8 (PF1) + 8 (PF2) + 8 (ext) | +8 |
| MO RAM | 8 | 8 | 0 |
| work RAM | 16 | 28 | +12 |
| colour/palette RAM | 4 | 4 | 0 |
| alpha + cfg/SLIP/EOF | 4 + 0.25 | 4 | 0 |
| EEPROM | 0.5 | 2 | +1.5 |
| char ROM copy (`chr_ram`) | 16 | **64** if whole ROM resident | **+48** |
| line buffers (4 × 256 × 20) | 4 blocks | 4 blocks | 0 |
| `jshad` | 64 | 64 | 0 |
| 6502 RAM | 8 | 8 | 0 |
| 68k shadows | up to 100 (`vshad`,`vshad2`,`vshad3`,`eshad`,`eshad2`) | to be profiled | −100 … 0 |

Read that table as: the fixed game memories grow by ~22 KB, and the alpha
character ROM is the one item that could blow the budget (+48). Two ways to
keep it off the ceiling, both cheap: (a) keep `chr_ram` at 8–16 KB and DMA the
selected 8 KB bank from SDRAM when `360010` changes the bank (bank changes are
latch writes, rare, and the manual's alpha test cycles them by button press —
p22); or (b) fetch alpha rows from the PSRAM/SDRAM per cell (one 16-bit word
per 8 pixels per line, ~42 words per line — negligible traffic, but it adds a
third arbiter client and a new deadline, which is exactly the class of thing
`LESSONS.md` warns costs builds). (a) is the recommendation.

With (a) and **no 68k shadows**, the estimate is ≈ 240 blocks before the
fetch rings, jt51/OKI internals and HUD — roughly Escape's footprint minus its
shadows plus the two new playfield rings. There is room, but only if the
shadows are treated as optional from day one rather than ported. Every new
array must be declared MLAB or justified as M10K up front (`LESSONS.md`,
"At the M10K ceiling…").

### 4.2 Bandwidth

- **Pocket**: Escape's split — playfield tiles on CRAM0 PSRAM, MO tiles and CPU
  ROM on SDRAM (`PIPELINES.md` §3.2) — still fits. Playfield traffic
  **doubles** (two 4-byte fetches per 8 pixels per line instead of one), which
  the PSRAM lane carries comfortably on paper (Escape's PF channel already has
  4 fetch channels and a 16-px lead, `escape_pf.v` parameters) but the strip/
  left-edge history says measure it, not assume it. MO traffic is unchanged in
  kind; ThunderJaws' crowd scenes are unknown in size.
- **MiSTer**: one SDRAM for everything, playfield already outranks the CPUs and
  the fastpath must never be blocked long (`MISTER.md`, `escape_mister.v`
  header: "THIS IS THE #1 THING TO WATCH"). Doubling the top-priority client's
  traffic is the single most likely place a ThunderJaws port fails first. The
  bank-partition trick (tile mirror in another bank) extends naturally: PF1,
  PF2 and MO tiles in three banks.
- Both: the 68k program ROM is 640 KB + 256 KB versus 512 KB + 512 KB — the
  fastpath/shadow question is the same size as Escape's.

---

## 5. Blockers, unknowns, effort, recommendation

### 5.1 Blockers and unknowns

1. **ROM availability** — the owner's matter; nothing on this machine, none
   sought. Everything in this document was done without a romset and the next
   step that *needs* one is the MAME trace work below.
2. **The VAD is undocumented in the manual.** The kit schematics stop at the
   CPU/IO/RGB sheets; there is no VAD pinout, no video-RAM sheet, no MO DMA
   timing. MAME's `atarivad.cpp` register comment is the only written
   description, and MAME itself ignores the DMA/timing options and derives
   the raster from "published specs". A real-board capture (as done for Escape,
   `real-board-reference-capture`) would be the only ground truth for timing
   and for the priority corner cases.
3. **Scanline-IRQ / read-back tolerance.** The `$163484` table check in CPU 2
   "aggressively trash[es] memory" if the interrupt timing is wrong
   (`thunderj.cpp` header, code at `$1E56`). A raster-exact core should pass
   naturally, but the VAD's scanline numbering vs our counters must be pinned
   with a trace before first flash, or the failure mode is Escape's
   "world-death" all over again (`NIGHT-ANALYSIS.md`).
4. **Rowscroll and EOF usage** by this specific game: unknown until traced.
5. **PF/MO priority table**: inferred in §1.7; must be checked exhaustively
   against a literal transcription of `screen_update`, as `tb_prio.v` does.
6. **OKI6295 core**: `jt6295` is GPL-3.0 like the repo, Pocket-proven in
   jotego cores, and is in the middle of being vendored for the Klax/Guts
   JSA-II work (`KLAX_GUTS.md`, uncommitted at the time of writing); it still
   needs the donor-IP validation `LESSONS.md` demands ("proven only for the
   data it has seen") on ThunderJaws' own 256 KB ADPCM set, which is twice
   Klax's.
7. **Two boards?** Same 68000/68010 ambiguity as Escape; harmless to the RTL.

### 5.2 Effort, in phases

| Phase | Work | Gate |
|---|---|---|
| 0. Instruments first | `build_rom.py` map + CRC table; MAME Lua taps on `3EFFC0-3EFFFF` (VAD writes, EOF list, register-0 reads), `360010`, the shared-RAM handshake; scene dumps (PF1/PF2/ext/MO/SLIP/palette) | traces + fixtures exist before any RTL |
| 1. Offline video model | Python renderer of PF1+PF2+MO+alpha with the new priority, validated pixel-exact against MAME screenshots on the dumped scenes; exhaustive priority-table check | 100% on ≥3 scenes incl. a stain scene |
| 2. CPU pair + JSA-II, alpha only | new decode, VAD register block with scanline IRQ, EEPROM 2816, JSA-II with OKI, alpha bank DMA; self-test screens legible | boots to self-test and attract text; CPU 2 communication test passes |
| 3. Playfields | two `escape_pf` instances, IRGB1555 palette, PF2-over-PF1 | dual-playfield test screen (manual p22 Fig 2-9) matches MAME |
| 4. Motion objects + priority + stain | `escape_mob` hflip change, new comparator, stain pass | `mob_vs_mame`-style gate on crowd scenes |
| 5. Platform | Pocket fit at ≤ 308 with timing gates, MiSTer arbiter with three gfx banks, save, MRA/packaging | release checklist |

Phases 2–4 are where Escape spent ~150 builds; most of that was the memory
fabric, which is being reused, and the instruments, which exist. A realistic
expectation is that Phase 4 (the new priority/compositor path) and Phase 5 on
MiSTer dominate.

### 5.3 Recommendation

**Separate core, sharing this repo's RTL as a library — not a variant of the
Escape core.** Reasons: the video top (`core_top.v`, ~3000 lines, where the
playfield, alpha, compositor and arbitration live and which no testbench
compiles) is Escape-shaped end to end; a game generic threading through it
would double the untestable surface. The platform identity (Pocket `eprom`
platform id, save-slot size, `.mra`) is per-game anyway. What is shared —
`TG68K`, `shared_ram`/TASLOCK, the SDRAM controllers and fastpath, `escape_jsa`
minus TMS plus OKI, `escape_mob`, `escape_stain`, `ee_save`, the HUD — is
already in separately compiled files and can be lifted as a common directory
with the Escape-specific pieces (`escape_prio`, `escape_pf` ×2 wrapper, the new
VAD register block, palette decode) beside them. Batman, Relief Pitcher, Shuuz
and Off the Wall are also VAD boards (`atarivad.cpp` comments), so a VAD
scanout written once has a longer life than a ThunderJaws-only patch.

**If it proceeds, do first:** Phase 0 and Phase 1 in full, with no RTL. The
video is the new part, MAME is the only reference for it, and every Escape
lesson says the same thing: model and trace it offline, prove the priority
table can fail, and only then spend flash cycles.
