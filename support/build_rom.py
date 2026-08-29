#!/usr/bin/env python3
"""Assemble a single combined ROM image for the Atari Dual 68k core from user dumps.

Input: a folder OR a standard MAME eprom.zip containing the original chip dumps.
Every chip is CRC32-verified against known-good values; wrong dumps are refused.
No ROM data ships with this repository - you must supply your own.

The Pocket loads this one file into SDRAM via an APF data slot (see data.json); the
core's memory controller reads each region at the offsets below. ROMs are ~2 MB total,
far larger than on-chip BRAM, so they live in SDRAM. This tool never ships ROM data —
the user runs it against their own verified dumps.

Combined image layout (SDRAM byte offsets):
  0x000000  maincpu   512 KB  Video CPU program (16-bit, big-endian interleaved)
  0x080000  extra     512 KB  Extra CPU program (own at +0, ROM_COPY at +0x60000,
                              0x0A0000-0x0DFFFF zero-filled as MAME leaves it)
  0x100000  jsa6502    64 KB  JSA sound 6502 program + TMS5220 speech
  0x110000  chars      16 KB  alphanumerics tiles (padded to 0x10000)
  0x120000  spr_tiles 1024 KB playfield AND motion-object tiles -- MAME's
                              "spr_tiles" region, decoded by pfmolayout for both
                              layers. TWO transforms vs the raw chips: bit-invert
                              (ROMREGION_INVERT) then repack 4 bit-planes into
                              chunky 4bpp. This is NOT a raw MAME region dump.

Usage: build_rom.py [romset_dir_or_zip] [out_file]
  Run from an unzipped release package (Assets/eprom/common/ next to this
  script), the ROM is written straight into Assets/eprom/common/ -- copy the
  package to the SD card and it is already in place. Otherwise the repo-dev
  default is dist/assets/eprom/common/atari_escape.rom. An explicit out_file
  overrides both. ("eprom" is the core platform id -- the same folder name
  the SD card uses.) romset default: ../eprom next to the project.
"""
import os, sys, zipfile, zlib

# known-good CRC32s (MAME eprom set) - build refuses chips that do not match
CRCS = {
"136069-3025.50a":"08888dec","136069-3024.40a":"29cb1e97","136069-4027.50b":"702241c9",
"136069-4026.40b":"fecbf9e2","136069-4029.50d":"0f2f1502","136069-4028.40d":"bc6f6ae8",
"136069-2033.40k":"130650f6","136069-2032.50k":"1da21ed8","136069-2035.10s":"deff6469",
"136069-2034.10u":"5d7afca2","136069-1040.7b":"86e93695",
"136069-1020.47s":"0de9d98d","136069-1013.43s":"8eb106ad","136069-1018.38s":"bf3d0e18",
"136069-1023.32s":"48fb2e42","136069-1016.76s":"602d939d","136069-1011.70s":"f6c973af",
"136069-1017.64s":"9cd52e30","136069-1022.57s":"4e2c2e7e","136069-1012.47u":"e7edcced",
"136069-1010.43u":"9d3e144d","136069-1015.38u":"23f40437","136069-1021.32u":"2a47ff7b",
"136069-1008.76u":"b0cead58","136069-1009.70u":"fbc3934b","136069-1014.64u":"0e07493b",
"136069-1019.57u":"34f8f0ed","136069-1007.125d":"409d818e",
}

_zip = None   # set in main() when romdir is a zip

def rd(romdir, name, size=0x10000):
    if _zip is not None:
        try:
            b = _zip.read(name)
        except KeyError:
            raise SystemExit(f"missing {name} in {romdir}")
    else:
        path = os.path.join(romdir, name)
        if not os.path.exists(path):
            raise SystemExit(f"missing {name} in {romdir}")
        b = open(path, "rb").read()
    if len(b) != size:
        raise SystemExit(f"size mismatch {name}: {len(b)} != {size}")
    crc = format(zlib.crc32(b) & 0xffffffff, "08x")
    if name in CRCS and crc != CRCS[name]:
        raise SystemExit(f"CRC mismatch {name}: got {crc}, expected {CRCS[name]} "
                         f"(wrong or modified dump - refusing to build)")
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
    global _zip
    if romdir.lower().endswith(".zip"):
        if not os.path.isfile(romdir):
            raise SystemExit(f"no such file: {romdir}")
        try:
            _zip = zipfile.ZipFile(romdir)
        except zipfile.BadZipFile:
            raise SystemExit(f"not a zip file: {romdir}")
    elif not os.path.isdir(romdir):
        raise SystemExit(f"no such romset directory: {romdir}\n"
                         f"pass a folder of 136069-* chip dumps, or a MAME eprom.zip")
    if len(sys.argv) > 2:
        out = sys.argv[2]
    elif os.path.isdir(os.path.join(here, "Assets", "eprom", "common")):
        # unzipped release package: drop the ROM where the Pocket expects it
        out = os.path.join(here, "Assets", "eprom", "common", "atari_escape.rom")
    else:
        out = os.path.join(repo, "dist", "assets", "eprom", "common", "atari_escape.rom")
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
    # sprites @0x120000: repacked to CHUNKY 4bpp for single-burst tile-row fetches.
    # Source is 4 planar banks of 256KB (RGN_FRAC(n,4), plane0 = MSB), bit-inverted
    # (ROMREGION_INVERT). Output: per tile-row, 4 bytes = 8 pixels of 4-bit chunky:
    # byte0 = px0px1, byte1 = px2px3, byte2 = px4px5, byte3 = px6px7.
    inv = bytes(b ^ 0xFF for b in range(256))
    planar = bytearray()
    for name in SPRITES:
        planar += rd(romdir, name).translate(inv)
    plane_sz = len(planar) // 4                       # 256KB per plane
    chunky = bytearray(len(planar))
    for i in range(plane_sz):                         # i = tile*8 + row
        b0 = planar[i]; b1 = planar[plane_sz + i]
        b2 = planar[2*plane_sz + i]; b3 = planar[3*plane_sz + i]
        for half in range(4):                         # 2 pixels per output byte
            n0 = half*2; n1 = half*2 + 1
            p0 = (((b0 >> (7-n0)) & 1) << 3) | (((b1 >> (7-n0)) & 1) << 2) | \
                 (((b2 >> (7-n0)) & 1) << 1) | ((b3 >> (7-n0)) & 1)
            p1 = (((b0 >> (7-n1)) & 1) << 3) | (((b1 >> (7-n1)) & 1) << 2) | \
                 (((b2 >> (7-n1)) & 1) << 1) | ((b3 >> (7-n1)) & 1)
            chunky[i*4 + half] = (p0 << 4) | p1
    img[0x120000:0x120000+len(chunky)] = chunky

    with open(out, "wb") as f:
        f.write(img)
    print(f"wrote {out}: {len(img)} bytes (0x{len(img):X})")
    print("  0x000000 maincpu | 0x080000 extra | 0x100000 jsa6502 | 0x110000 chars | 0x120000 sprites")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
