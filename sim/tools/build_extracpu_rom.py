#!/usr/bin/env python3
"""Assemble the Escape "Extra" (second) 68000 program ROM into a sim image.

Per MAME ROM_START(eprom), region "extra" (0x80000):
  0x00000: 136069-2035.10s (high) / 136069-2034.10u (low)   -- extra CPU's own program
  0x20000-0x5FFFF: empty
  0x60000: copy of maincpu 0x60000 (shared program ROM: 2033.40k/2032.50k)

Output: sim/work/extracpu_words.hex  (one big-endian word per line, 0x40000 words).
ROMs read locally, never copied into the repo. Usage: [romset_dir]  (default ../eprom)
"""
import os, sys

def load(romdir, name):
    b = open(os.path.join(romdir, name), "rb").read()
    if len(b) != 0x10000:
        raise SystemExit(f"unexpected size {name}={len(b)}")
    return b

def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, "..", ".."))
    romdir = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(os.path.join(repo, "..", "eprom"))
    out = os.path.join(repo, "sim", "work", "extracpu_words.hex")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    words = [0] * 0x40000                                    # 0x80000 bytes, zero-filled

    hi, lo = load(romdir, "136069-2035.10s"), load(romdir, "136069-2034.10u")
    for i in range(0x10000):                                # 0x00000..0x1FFFF
        words[i] = (hi[i] << 8) | lo[i]

    hi, lo = load(romdir, "136069-2033.40k"), load(romdir, "136069-2032.50k")
    for i in range(0x10000):                                # 0x60000..0x7FFFF (word 0x30000)
        words[0x30000 + i] = (hi[i] << 8) | lo[i]

    with open(out, "w") as f:
        f.write("\n".join(f"{w:04x}" for w in words) + "\n")

    sp = (words[0] << 16) | words[1]
    pc = (words[2] << 16) | words[3]
    print(f"wrote {out}: {len(words)} words ({len(words)*2} bytes)")
    print(f"extra reset SP = 0x{sp:08X}")
    print(f"extra reset PC = 0x{pc:08X}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
