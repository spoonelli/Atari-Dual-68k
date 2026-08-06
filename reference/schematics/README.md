# Schematics

**Atari Games Schematic Package SP-332** (1st printing, 1989) — *Escape From the
Planet of the Robot Monsters*. © Atari Games Corporation ("Reproduction forbidden").

The PDF is **not** committed to this public repo (it's git-ignored). Download your own
copy for reference — it is archived publicly at arcade-museum.com — and place it at
`reference/schematics/Escape_Schematic_Package.pdf`. The factual memory map transcribed
in `docs/ARCHITECTURE.md` is not copyrightable and stays in the repo.

## Sheet index → RTL module

| Sheets | Contents | RTL relevance |
|--------|----------|---------------|
| 1      | Main wiring diagram | I/O, control inputs |
| 2–10   | Escape Main PCB assembly | dual 68000, memory decode/PALs, video (playfield / motion objects / alpha), palette, SLAPSTIC, clock & sync generation |
| 11–14  | Stand-Alone Audio PCB (JSA) | 6502, YM2151, POKEY, TMS5220, banking |
| 15     | Power supply / coin door | not needed for the core |
| 16     | Memory map, RAM/ROM error locations, Hall-effect joystick PCB | authoritative address map; analog joystick handling |

Note (from the package): sheets have cross-references labeled "SHT n" that use the
*original* drawing numbers, not the package page numbers. Conversion:

- Main PCB: labeled SHT 1–9 → package sheets 2–10
- Audio PCB: labeled SHT 1–4 → package sheets 11–14

## Rendering pages locally

The PDF is scanned (no text layer). To view a sheet as an image:

```bash
python3 -m pip install --user pymupdf
python3 - <<'PY'
import fitz
doc = fitz.open("Escape_Schematic_Package.pdf")
doc[15].get_pixmap(dpi=150).save("_png/page16.png")  # 0-indexed: page 16 = memory map
PY
```

(`_png/` is git-ignored.)
