#!/usr/bin/env python3
"""Assemble the Escape Video (main) 68000 program ROM into a sim-loadable image.

Interleaves the byte-wide dumps into 16-bit big-endian words per MAME ROM_START(eprom)
(see docs/ROMMAP.md): even offset = high byte (D15-8), odd offset = low byte (D7-0).

Output: sim/work/maincpu_words.hex  — one 4-hex-digit word per line (0x40000 words).
ROMs are read from a local romset dir and never copied into the repo.

Usage: build_maincpu_rom.py [romset_dir]   (default: ../eprom next to the project)
"""
import os, sys

# (high-byte file, low-byte file) per 0x20000-byte segment, in address order
SEGMENTS = [
    ("136069-3025.50a", "136069-3024.40a"),  # 0x00000
    ("136069-4027.50b", "136069-4026.40b"),  # 0x20000
    ("136069-4029.50d", "136069-4028.40d"),  # 0x40000
    ("136069-2033.40k", "136069-2032.50k"),  # 0x60000 (shared program)
]

def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", ".."))
    default_roms = os.path.abspath(os.path.join(repo, "..", "eprom"))
    romdir = sys.argv[1] if len(sys.argv) > 1 else default_roms
    outdir = os.path.join(repo, "sim", "work")
    os.makedirs(outdir, exist_ok=True)
    outpath = os.path.join(outdir, "maincpu_words.hex")

    words = []
    for hi_name, lo_name in SEGMENTS:
        hi = open(os.path.join(romdir, hi_name), "rb").read()
        lo = open(os.path.join(romdir, lo_name), "rb").read()
        if len(hi) != 0x10000 or len(lo) != 0x10000:
            print(f"unexpected size: {hi_name}={len(hi)} {lo_name}={len(lo)}", file=sys.stderr)
            return 1
        for i in range(0x10000):
            words.append((hi[i] << 8) | lo[i])

    with open(outpath, "w") as f:
        f.write("\n".join(f"{w:04x}" for w in words) + "\n")

    sp = (words[0] << 16) | words[1]
    pc = (words[2] << 16) | words[3]
    print(f"wrote {outpath}: {len(words)} words ({len(words)*2} bytes)")
    print(f"reset SP = 0x{sp:08X}")
    print(f"reset PC = 0x{pc:08X}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
