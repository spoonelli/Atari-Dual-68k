# EEPROM persistence (high scores and operator settings)

The Escape board keeps its high-score table and every operator setting - coin
pricing, difficulty, lives, the language and volume options in the self-test
menu - in a 2804 parallel EEPROM. The core emulates that part as BRAM, so
before this change every power-on came up factory-fresh. This document is how
the BRAM got hooked to the Analogue Pocket's save-data mechanism, why each
choice was made, and what still needs a real Pocket to confirm.

## 1. What the game actually stores

MAME's `eprom.cpp` maps the part twice (`reference/eprom.cpp:623`):

    map(0x0e0000, 0x0e03ff).rw("eeprom", ...).umask16(0x00ff);
    map(0x1f0000, 0x1fffff).w("eeprom", ... unlock_write16);
    EEPROM_2804(config, "eeprom").lock_after_write(true);

`umask16(0x00ff)` is the load-bearing detail: the EEPROM sits on the **low data
byte only**. 0x400 bytes of address space, 512 storage locations, one per odd
68000 byte address. `escape_decode.vhd:64` decodes the same window (a little
wider, 0E0000-0E2FFF, harmlessly aliasing) and `escape_core.vhd` addresses the
RAM with `v_addr(9 downto 1)`, so location *i* is the LDS byte of word *i*.

That is the definition of the save file this change writes: **512 bytes, byte
*i* = EEPROM location *i*.** No header, no wrapper. The same shape a MAME
`nvram` dump has, so images are interchangeable by hand if anyone wants to.

## 2. How APF's save mechanism works

Everything below is from the framework sources in this repo plus Analogue's
developer documentation; file and line references are to this tree.

### Data slots

`data.json` declares slots. The fields that matter here are `address` (where in
the core's **bridge** address space APF puts the file), `nonvolatile` ("the slot
persists to disk on core exit and reloads on startup") and `parameters`, a
bitfield. Bit 5 is *Initialize nonvolatile data on load*: with it set, "Data is
loaded if it exists, otherwise the slot's memory is overwritten with 0xFF's up
to `size_maximum`". For an EEPROM that is precisely the right default - an
erased 2804 reads FF, and the game recognises that pattern and writes its
factory defaults. (An all-zero part instead looks like *valid* settings with
pricing 0, and then start is never accepted - which is why
`spram_bytelane.vhd` already carried an `initbyte` of FF.)

### The load path

At startup APF sends host command `[0082 Data slot request write]` per slot and
then simply **writes the file into the bridge**, finishing with
`[008F Data slot access all complete]`. In `core_bridge_cmd.v` those arrive as
`dataslot_requestwrite` (line 369) and `dataslot_allcomplete` (line 390). The
core already gates its reset on the latter (`core_top.v`, `core_reset_n`), which
is what makes the ROM download safe, and is exactly the hook the EEPROM restore
needs.

### The save path

Two mechanisms exist, and this core uses **both**:

1. **On exit.** APF sends `[0080 Data slot request read]` for each nonvolatile
   slot and reads that bridge window back out to the SD card.
   `core_bridge_cmd.v:358` shows the handshake: the command sits in `ST_PARSE`
   asserting `dataslot_requestread` **until the core raises
   `dataslot_requestread_ack`**. That back-pressure is the clean way to say
   "wait, I am not ready" - and it is how this core guarantees APF never reads a
   half-built buffer.

2. **On demand.** Target command `[0184 Data slot write]`
   (`core_bridge_cmd.v:495`) hands APF a slot id, a slot offset, a **bridge
   address to read from** and a length; APF reads that window and writes the
   file. This is what makes a score survive a power-off that never reaches a
   clean exit.

### Bridge read timing - the one subtle part

Writes are immediate. Reads are not. `io_bridge_peripheral.v:40`:

> please note that while writes are immediate, reads are buffered by 1 word.

and Analogue's bus documentation: "upon receiving a read the core may not
immediately provide the read data and has until the next read strobe to drive
`bridge_rd_data`."

Reading the state machine confirms the shape (`io_bridge_peripheral.v:209`):
`pmp_addr` is latched, `pmp_addr_valid` rises, **four clocks pass, the current
`pmp_rd_data` is sampled and sent**, and only then does `pmp_rd` strobe. So the
word APF ships in transaction *N* is the one the core latched on the strobe of
transaction *N-1*, and the pipeline is one word deep.

Analogue's own reference implementation in this repo does exactly that: in
`core_bridge_cmd.v` the datatable address tracks `bridge_addr` unconditionally
every cycle (line 238) so the BRAM output is settled long before the strobe, and
`bridge_rd_data_out` is then latched **inside `if(bridge_rd)`** (line 275).
`ee_save.vhd` copies that structure signal for signal.

Two consequences fell out of this and are worth stating, because both are easy
to get wrong:

* APF must issue one transaction **past** the end of a block to collect the last
  word. So the read decode in `core_top.v` covers the whole `0x20xxxxxx` region,
  not just the 512 bytes - if the trailing address missed the mux, the final
  four bytes of every save would be garbage. Writes are still decoded strictly
  to 512 bytes so nothing can alias into the buffer.
* The read latch is gated to reads aimed at our region, so a bridge read of some
  other device between the last data word and APF's trailing pipeline read
  cannot clobber the word still owed to APF.

**This is the part I could not verify without hardware.** The sources agree with
each other and the implementation follows Analogue's own reference module, but
the buffered-read contract is only exercised for real when a Pocket writes the
file. Section 6 says how to tell in thirty seconds whether it is right.

## 3. What was built

    src/fpga/core/rtl/ee_save.vhd     the engine (new)
    src/fpga/core/rtl/escape_core.vhd EEPROM BRAM gains a second port
    src/fpga/core/core_top.v          bridge window, [0184] issuer, reset gate
    data.json                         slot 2, nonvolatile, 512 bytes @ 0x20000000
    interact.json                     'EEPROM Autosave' toggle
    sim/tb/tb_ee_save.vhd             GHDL testbench for the whole cycle

The EEPROM RAM changes from `spram_bytelane` to `dpram_bytelane_syn` (which
gained the same `initbyte` generic). Port A stays the 68000's, byte lanes and
all. Port B is byte-wide, LDS-only, and belongs to `ee_save` - it cannot touch
the unused upper bank even by accident.

`ee_save` straddles the two clock domains with two 128 x 32 buffers, each
written in one domain and read in the other - the same simple-dual-port shape
`dpram_dc.vhd` already uses for the hot-code shadows:

    dlbuf   bridge writes (clk_74a)    ->  restore engine (7.159 MHz)
    ulbuf   snapshot engine (7.159 MHz) ->  bridge reads   (clk_74a)

and one core-clock FSM owns EEPROM port B:

* **Restore.** On `dataslot_allcomplete`, if anything was ever written to our
  bridge window, copy 512 bytes into the EEPROM (4 clocks per byte, ~290 us).
  If nothing was written, skip it and leave the virgin FFs. `core_reset_n` now
  includes `ee_ready_c`, so the 68000s cannot read a half-restored EEPROM. That
  flag latches once and survives watchdog and soft resets, which must not re-run
  the restore over scores earned since boot.
* **Snapshot.** Copy 512 bytes out to `ulbuf` (3 clocks per byte, ~215 us),
  triggered either by APF's exit-time read request or by the autosave timer.

Autosave fires when the CPU has written the EEPROM and then left it alone for
2^23 core clocks (~1.2 s). `core_top.v` turns the resulting request into a
`[0184 Data slot write]` of 512 bytes from `0x20000000`. The **+** menu carries
an `EEPROM Autosave` checkbox (default on) in case it ever needs disabling; with
it off, saving still happens the normal way when the core is exited.

The diagnostic strip at the bottom of dev builds gained a segment (7th of 8) for
this: red = virgin EEPROM, teal = save file loaded, amber = unsaved changes
pending, blue = snapshot taken but APF has not confirmed, green = APF wrote the
file, magenta = APF refused or never answered.

## 4. Why it cannot corrupt or stall anything

**An interrupted save cannot corrupt the EEPROM.** The game's live copy is BRAM.
Nothing writes it except the 68000 and the one-shot restore at boot. A save only
ever *reads* it. If a save dies half-way - APF errors, the handheld loses power
mid-write - the worst case is the previous file surviving, or the SD card
holding a partially rewritten file that the *next* boot loads. That second case
is real but it is APF's file write, not something this design can prevent from
inside the FPGA, and it is no different from any other Pocket core's save; the
mitigation is that autosaves happen at quiet moments, ~1.2 s after the game
stopped writing, not continuously.

**A partial snapshot can never be read.** APF's exit read is held off by
`dataslot_requestread_ack` until the snapshot completes, and the autosave path
only raises `b_savereq` after the snapshot has finished. The buffer APF reads is
always a complete image - the current one, or failing that an older complete
one, never a mixture.

**A write that races a save is not lost.** `dirty` is cleared when a snapshot
*starts*, not when it finishes, and a CPU write always re-sets it (the
`c_wrpulse` check sits after the FSM in the same process, so it wins the tie).
A store landing mid-snapshot therefore schedules another save.

**Nothing can stall the game.** `ee_save` owns only port B of the EEPROM BRAM;
the 68000s use port A and never wait on any of this. If the framework never
services a save, `b_savereq` simply stays up and the game runs on untouched.
Every handshake is bounded anyway:

| wait | bound | what happens when it expires |
|---|---|---|
| restore after `allcomplete` | ~290 us, unconditional | n/a - the FSM always terminates |
| APF answering `[0184]` | ~226 ms (`ee_tw_to`) | save abandoned, error counter ticks, engine returns to idle |
| snapshot before exit read | ~452 ms (`ee_rd_to`) | `dataslot_requestread_ack` is forced; APF reads the previous complete image |

The one thing `core_reset_n` now depends on is `ee_ready_c`, and that is reached
unconditionally within ~290 us of `dataslot_allcomplete` whether or not a save
file exists - so a missing, empty or refused save slot cannot brick a boot.

## 5. Simulated proof

`sim/tb/tb_ee_save.vhd` runs the whole power cycle under GHDL against the real
`ee_save` and a real `dpram_bytelane_syn` EEPROM:

    ./sim/run_tb.sh tb_ee_save 3ms

1. **Cold boot, no save file.** `allcomplete` with nothing ever written to the
   window: the restore is skipped, `c_ready` still rises (no stall), the EEPROM
   is still FF.
2. **Warm boot.** 512 bytes written into the window the way APF loads a slot
   (32-bit big-endian words), then `allcomplete`. All 512 EEPROM locations are
   read back through the CPU's own port and checked against the file image -
   this is what pins the byte order down.
3. **The game scores.** Three CPU stores, then the write-idle window elapses;
   the engine snapshots and raises the save request, and the window read back
   the way APF reads it for `[0184]` matches the live EEPROM byte for byte.
4. **Core exit.** A further CPU store, then `b_snapreq`: the refreshed window
   must contain the new byte *and* still hold the earlier ones.
5. **No stall.** An autosave that is never acknowledged: the CPU keeps reading
   and writing the EEPROM normally and the writes are still tracked.

Measured in that run: restore 287 us, snapshot 215 us.

Quartus Analysis & Elaboration passes on the whole project with the new module
bound from `core_top.v`.

## 6. On-device test procedure

Nothing extra to install, but **the whole `Cores/` folder has to be copied, not
just the bitstream** - the save slot is declared in `data.json`, and a core that
does not know about slot 2 has nowhere to put high scores. Build and package as
usual (`./support/package.sh <bitstream.rbf_r>`) and merge onto the SD card; the
ROM is still user-supplied and no ROM data is in the package.

The save file is created by the Pocket itself at
`/Saves/eprom/common/atari_escape.sav`, 512 bytes. You do not have to create it
- but if you already have a MAME `eprom` nvram dump you can drop it there and it
will load.

**The five-minute check:**

1. Launch the core with no save file present. The 7th diagnostic segment (turn
   the overlay on with **L**) should be **red** - virgin EEPROM.
2. Enter the operator menu (Interact -> Service Mode, then Soft Reset Core) and
   change something you will recognise: coins-per-credit, or lives per game.
   Exit the menu back to attract mode.
3. Watch the segment go **amber** (unsaved change), then within about a second
   and a half **green** - APF has written the file. If it goes **blue** and
   stays there, the core snapshotted but APF never answered `[0184]`; if it goes
   **magenta**, APF answered with an error.
4. Exit the core from the Pocket menu, then **power the Pocket fully off** and
   back on. Relaunch the core.
5. The segment should now be **teal or green** (a save file was loaded), and the
   setting you changed in step 2 should still be set. Check it in the operator
   menu.
6. Repeat for a high score: play until you place on the table, enter initials,
   let the game return to attract, power-cycle, and confirm the score and
   initials are still in the table.

**If step 5 shows the setting reverted but a `.sav` file does exist on the
card**, copy that file off and look at it: if its bytes are the EEPROM contents
shifted by four positions, the bridge-read pipeline assumption in section 2 is
off by one word and the fix is a one-line change to where `ee_save` latches
`b_rdata_r`. That is the single failure mode this design could not settle from
the sources alone, and this is how to tell.

**If saving works but you want it off**, uncheck `EEPROM Autosave` in the
Interact (**+**) menu. Saving on a clean core exit still happens.

## 7. Known limits

* **Ungraceful power loss inside the ~1.2 s window** loses whatever the game
  wrote in that window. Shortening `IDLE_BITS` in `ee_save.vhd` trades SD writes
  for a tighter window.
* **Whether `[0184 Data slot write]` can create a file that does not exist yet
  is not settled by the documentation.** Result code 1 is "slot not defined";
  it is not spelled out whether a nonvolatile slot whose file is still absent
  counts as defined. If it does not, the very first autosave fails - the
  indicator goes magenta - and the file only appears when the core is next
  exited cleanly, after which every autosave works. Persistence is not lost
  either way; the first save is just deferred. The indicator makes this visible
  rather than mysterious, and is worth a glance on the first run with a fresh
  card.
* **The save filename is fixed** (`atari_escape.sav`) rather than derived from
  the ROM's name. `data.json` `parameters` bit 2 ("Nonvolatile filename":
  filename cloned from slot 0 with this slot's extension) would make it follow
  the ROM, which is what a multi-variant build wants once Klax and Guts are
  selectable. Left clear for now because the derived-name behaviour is one more
  thing that cannot be checked without a Pocket, and today there is exactly one
  ROM filename.
* **The EEPROM's write-lock is still not emulated.** The real 2804 is
  `lock_after_write(true)` and needs the 0x1F0000 unlock sequence before each
  store; `escape_core.vhd` accepts every write (`we_ee <= v_wr and
  v_sel_eeprom`, no unlock gating). That predates this change and does not
  affect persistence, but it does mean a wild store into 0x0E0000-0E03FF can
  scribble on the EEPROM where real hardware would have ignored it - and now
  that scribble persists. Worth closing separately.
