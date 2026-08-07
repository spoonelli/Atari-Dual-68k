#!/usr/bin/env python3
"""Convert the combined ROM image (support/build_rom.py output) to a word-per-line
hex file for the simulation ROM server (rom_words).

Usage: rom_to_hex.py [in.rom] [out.hex]
  defaults: sim/work/atari_escape.rom -> sim/work/combined_words.hex
"""
import os, sys, struct

def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", ".."))
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(repo, "sim", "work", "atari_escape.rom")
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(repo, "sim", "work", "combined_words.hex")
    data = open(src, "rb").read()
    with open(dst, "w") as f:
        for i in range(0, len(data), 2):
            f.write(f"{(data[i] << 8) | data[i+1]:04x}\n")
    print(f"wrote {dst}: {len(data)//2} words")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
