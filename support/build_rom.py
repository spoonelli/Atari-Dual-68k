#!/usr/bin/env python3
"""Assemble a single combined ROM image for the Atari Dual 68k core from user dumps.

The Pocket loads this one file into SDRAM via an APF data slot (see data.json); the
core's memory controller reads each region at the offsets below. ROMs are ~2 MB total,
far larger than on-chip BRAM, so they live in SDRAM. This tool never ships ROM data —
the user runs it against their own verified dumps.

Combined image layout (SDRAM byte offsets):
  0x000000  maincpu   512 KB  Video CPU program (16-bit, big-endian interleaved)
  0x080000  extra     512 KB  Extra CPU program (own + shared copy)
  0x100000  jsa6502    64 KB  JSA sound 6502 program + TMS5220 speech
  0x110000  chars      16 KB  alphanumerics tiles
  0x120000  sprites  1024 KB  motion-object graphics (bit-inverted, per ROMREGION_INVERT)

Usage: build_rom.py [romset_dir] [out_file]
  defaults: romset_dir = ../eprom (next to project), out_file = dist/assets/.../atari_escape.rom
"""
import os, sys

def rd(romdir, name, size=0x10000):
    b = open(os.path.join(romdir, name), "rb").read()
    if len(b) != size:
        raise SystemExit(f"size mismatch {name}: {len(b)} != {size}")
    return b

def interleave(hi, lo):                       # 16-bit big-endian: even=hi byte, odd=lo byte
    out = bytearray(len(hi) * 2)
    out[0::2] = hi
    out[1::2] = lo
    return bytes(out)

MAIN = [("136069-3025.50a","136069-3024.40a"), ("136069-4027.50b","136069-4026.40b"),
        ("136069-4029.50d","136069-4028.40d"), ("136069-2033.40k","136069-2032.50k")]
# extra: own program (2035/2034) at 0, shared copy (2033/2032) at 0x60000
EXTRA_OWN = ("136069-2035.10s","136069-2034.10u")
SHARED    = ("136069-2033.40k","136069-2032.50k")
JSA   = "136069-1040.7b"
CHARS = "136069-1007.125d"
SPRITES = ["136069-1020.47s","136069-1013.43s","136069-1018.38s","136069-1023.32s",
           "136069-1016.76s","136069-1011.70s","136069-1017.64s","136069-1022.57s",
           "136069-1012.47u","136069-1010.43u","136069-1015.38u","136069-1021.32u",
           "136069-1008.76u","136069-1009.70u","136069-1014.64u","136069-1019.57u"]

def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, ".."))
    romdir = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(os.path.join(repo, "..", "eprom"))
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        repo, "dist", "assets", "atari_escape", "common", "atari_escape.rom")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    img = bytearray(0x220000)

    # maincpu @0x000000
    off = 0x000000
    for hi, lo in MAIN:
        seg = interleave(rd(romdir, hi), rd(romdir, lo)); img[off:off+len(seg)] = seg; off += len(seg)

    # extra @0x080000: own program at +0, shared copy at +0x60000
    base = 0x080000
    seg = interleave(rd(romdir, EXTRA_OWN[0]), rd(romdir, EXTRA_OWN[1])); img[base:base+len(seg)] = seg
    seg = interleave(rd(romdir, SHARED[0]), rd(romdir, SHARED[1])); img[base+0x60000:base+0x60000+len(seg)] = seg

    # jsa 6502 @0x100000
    b = rd(romdir, JSA); img[0x100000:0x100000+len(b)] = b
    # chars @0x110000
    b = rd(romdir, CHARS, 0x04000); img[0x110000:0x110000+len(b)] = b
    # sprites @0x120000 (sequential, bit-inverted)
    off = 0x120000
    inv = bytes(b ^ 0xFF for b in range(256))
    for name in SPRITES:
        b = rd(romdir, name).translate(inv); img[off:off+len(b)] = b; off += len(b)

    with open(out, "wb") as f:
        f.write(img)
    print(f"wrote {out}: {len(img)} bytes (0x{len(img):X})")
    print("  0x000000 maincpu | 0x080000 extra | 0x100000 jsa6502 | 0x110000 chars | 0x120000 sprites")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
