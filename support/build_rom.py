#!/usr/bin/env python3
"""Assemble a single combined ROM image for the Atari Dual 68k core from user dumps.

Input: a folder OR a standard MAME eprom.zip / eprom2.zip containing the original chip
dumps (set 1 or set 2 are detected automatically; a clone folder may lean on the parent's
shared chips next to it).
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
  By default atari_escape.rom is written NEXT TO THIS SCRIPT; an explicit
  out_file overrides that. In the release package, move the result into
  Assets/eprom/common/ (the SD location the Pocket loads from -- "eprom" is
  the core platform id). romset default: ../eprom next to the project.
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
# set 2 (eprom2) program chips + MAME's name for the same chars chip
"136069-1025.50a":"b0c9a476","136069-1024.40a":"4cc2c50c","136069-1027.50b":"84f533ea",
"136069-1026.40b":"506396ce","136069-1029.50d":"99810b9b","136069-1028.40d":"08ab41f2",
"136069-1033.40k":"395fc203","136069-1032.50k":"a19c8acb","136069-1037.50e":"ad39a3dd",
"136069-1036.40e":"34fc8895","136069-1035.10s":"ffeb5647","136069-1034.10u":"c68f58dd",
"136069.125d":"409d818e",
# Klax prototypes (klaxp1/klaxp2) - eprom.cpp; the chars chip is Escape's 125d under another name
"klax_ft1.50a":"87ee72d1","klax_ft1.40a":"ba139fdb","klax_ft2.50a":"7d401937","klax_ft2.40a":"c5ca33a9",
"klaxsnd.10c":"744734cb","klaxprot.43s":"a523c966","klaxprot.76s":"dbc678cd","klaxprot.47u":"af184754",
"klaxprot.76u":"7a56ffab","klax125d":"409d818e","klaxadp0.1f":"ba1e864f","klaxadp1.1e":"dec9a5ac",
# Guts n' Glory (guts) - eprom.cpp
"guts-hi0.50a":"3afca24a","guts-lo0.40a":"ce86cf23","guts-hi1.50b":"a231f65d","guts-lo1.40b":"dbdd4910",
"guts-snd.10c":"9fe065d7","guts-alpha.bin":"ee965058","guts-adpcm0.1f":"92e9c35d","guts-adpcm1.1e":"0afddd3a",
"guts-mo0.bin":"b8d8d8da","guts-mo1.bin":"d01b5a7f","guts-mo2.bin":"4577b807","guts-mo3.bin":"4ab03c84",
"guts-mo4.bin":"04cae4fb","guts-mo5.bin":"c65322ec","guts-mo6.bin":"92602a5f","guts-mo7.bin":"71a1911d",
"guts-mo8.bin":"aa273234","guts-mo9.bin":"e85a12ef","guts-moa.bin":"da1cc76f","guts-mob.bin":"246e7955",
"guts-moc.bin":"1764c272","guts-mod.bin":"8220f2f6","guts-moe.bin":"ee372eac","guts-mof.bin":"028ec56e",
"guts-pf0.bin":"1669fdb3","guts-pf1.bin":"135c41bd","guts-pf2.bin":"c0408d39","guts-pf4.bin":"577f25a6",
"guts-pf5.bin":"43cbc0e3","guts-pf6.bin":"03c096f4","guts-pf8.bin":"2f078b09","guts-pf9.bin":"7cb7302d",
"guts-pfa.bin":"a3919dae","guts-pfc.bin":"7c571ee8","guts-pfd.bin":"979af5b2","guts-pfe.bin":"bf384e4d",
}

_zip = None   # set in main() when romdir is a zip

# the same chars chip appears under two names across MAME's two sets (identical CRC)
CHARS_NAMES = ("136069-1007.125d", "136069.125d", "klax125d")   # one chip, three MAME names, one CRC
ALIAS = {n: [m for m in CHARS_NAMES if m != n] for n in CHARS_NAMES}

def rd(romdir, name, size=0x10000):
    if _zip is not None and name not in _zip.namelist() and name in ALIAS:
        name = next((m for m in ALIAS[name] if m in _zip.namelist()), name)
    if _zip is None:
        cands = [name] + ALIAS.get(name, [])
        dirs = [romdir, os.path.dirname(os.path.abspath(romdir)), os.path.join(os.path.dirname(os.path.abspath(romdir)), "eprom")]
        found = next((os.path.join(d, c) for d in dirs for c in cands if os.path.exists(os.path.join(d, c))), None)
        if found:
            name = os.path.basename(found); romdir = os.path.dirname(found)
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

# --- the two Escape sets (MAME eprom / eprom2) -------------------------------
# Set 1 (eprom): revision-3/4 program, 512 KB main.  Set 2 (eprom2): revision-1
# program with ONE extra main pair (1037.50e/1036.40e) at CPU 0x80000-0x9FFFF.
# The core places that window at image 0x0A0000 (EPROM2-163); both sets share
# the JSA, chars and sprite chips.  The set is detected from which first main
# pair is present.
SETS = {
  "eprom": dict(
    MAIN=[("136069-3025.50a","136069-3024.40a"), ("136069-4027.50b","136069-4026.40b"),
          ("136069-4029.50d","136069-4028.40d"), ("136069-2033.40k","136069-2032.50k")],
    MAIN_HI=None,
    EXTRA_OWN=("136069-2035.10s","136069-2034.10u"),
    SHARED=("136069-2033.40k","136069-2032.50k"),
    CHARS="136069-1007.125d"),
  "eprom2": dict(
    MAIN=[("136069-1025.50a","136069-1024.40a"), ("136069-1027.50b","136069-1026.40b"),
          ("136069-1029.50d","136069-1028.40d"), ("136069-1033.40k","136069-1032.50k")],
    MAIN_HI=("136069-1037.50e","136069-1036.40e"),        # CPU 0x80000 -> image 0x0A0000
    EXTRA_OWN=("136069-1035.10s","136069-1034.10u"),
    SHARED=("136069-1033.40k","136069-1032.50k"),
    CHARS="136069.125d"),                                # MAME's eprom2 name; same chip as 1007.125d
  # --- Klax prototypes: single 68000 (no extra), JSA-II (OKI6295), 256 KB sprite
  # region, ADPCM at image 0x240000. Needs a core built with EXTRA_EN=0 and
  # JSA_BOARD=2 (KLAX-165 / JSA2-164; docs/investigations/KLAX_GUTS.md).
  "klaxp1": dict(
    MAIN=[("klax_ft1.50a","klax_ft1.40a")], MAIN_HI=None, EXTRA_OWN=None, SHARED=None,
    JSA="klaxsnd.10c", CHARS="klax125d",
    SPRITES=["klaxprot.43s","klaxprot.76s","klaxprot.47u","klaxprot.76u"],
    OKI=["klaxadp0.1f","klaxadp1.1e"], TILES=None, SIZE=0x280000),
  "klaxp2": dict(
    MAIN=[("klax_ft2.50a","klax_ft2.40a")], MAIN_HI=None, EXTRA_OWN=None, SHARED=None,
    JSA="klaxsnd.10c", CHARS="klax125d",
    SPRITES=["klaxprot.43s","klaxprot.76s","klaxprot.47u","klaxprot.76u"],
    OKI=["klaxadp0.1f","klaxadp1.1e"], TILES=None, SIZE=0x280000),
  # --- Guts n' Glory: single 68000, JSA-II, separate 1 MB tile region (four
  # 64 KB slices undumped/absent - zero, as MAME) at image 0x280000.
  "guts": dict(
    MAIN=[("guts-hi0.50a","guts-lo0.40a"), ("guts-hi1.50b","guts-lo1.40b")],
    MAIN_HI=None, EXTRA_OWN=None, SHARED=None,
    JSA="guts-snd.10c", CHARS="guts-alpha.bin",
    SPRITES=["guts-mo%x.bin" % i for i in range(16)],
    OKI=["guts-adpcm0.1f","guts-adpcm1.1e"],
    TILES=["guts-pf0.bin","guts-pf1.bin","guts-pf2.bin",None,
           "guts-pf4.bin","guts-pf5.bin","guts-pf6.bin",None,
           "guts-pf8.bin","guts-pf9.bin","guts-pfa.bin",None,
           "guts-pfc.bin","guts-pfd.bin","guts-pfe.bin",None],
    SIZE=0x380000),
}
ESCAPE_JSA = "136069-1040.7b"
ESCAPE_SPRITES = ["136069-1020.47s","136069-1013.43s","136069-1018.38s","136069-1023.32s",
           "136069-1016.76s","136069-1011.70s","136069-1017.64s","136069-1022.57s",
           "136069-1012.47u","136069-1010.43u","136069-1015.38u","136069-1021.32u",
           "136069-1008.76u","136069-1009.70u","136069-1014.64u","136069-1019.57u"]
for _n in ("eprom", "eprom2"):
    SETS[_n].update(JSA=ESCAPE_JSA, SPRITES=ESCAPE_SPRITES, OKI=None, TILES=None, SIZE=0x220000)

def repack_planar(romdir, names):
    """Four planar 1bpp banks (RGN_FRAC(n,4), plane 0 = MSB), bit-inverted
    (ROMREGION_INVERT), to chunky 4bpp: per tile row 4 bytes = 8 pixels, high
    nibble first. `names` lists the chips in region order; None = 64 KB hole
    (zero, as MAME leaves an unloaded slice). Plane size follows the region
    (256 KB for Escape's 1 MB, 64 KB for Klax's 256 KB)."""
    inv = bytes(b ^ 0xFF for b in range(256))
    planar = bytearray()
    for name in names:
        planar += rd(romdir, name).translate(inv) if name else bytes(0x10000)
    plane_sz = len(planar) // 4
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
    return chunky

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
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "atari_escape.rom")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    def present(name):
        if _zip is not None:
            return name in _zip.namelist()
        return os.path.exists(os.path.join(romdir, name))
    DETECT = [("136069-3025.50a", "eprom"), ("136069-1025.50a", "eprom2"),
              ("klax_ft1.50a", "klaxp1"), ("klax_ft2.50a", "klaxp2"), ("guts-hi0.50a", "guts")]
    setname = next((n for chip, n in DETECT if present(chip)), None)
    if setname is None:
        raise SystemExit("no supported set found in " + romdir + ": expected one of "
                         + ", ".join(c for c, _ in DETECT))
    T = SETS[setname]
    img = bytearray(T["SIZE"])
    DESC = {"eprom": "Escape set 1, rev 3/4 program", "eprom2": "Escape set 2, rev 1 program + 0x80000 window",
            "klaxp1": "Klax prototype set 1 - needs the single-CPU JSA-II core build (EXTRA_EN=0, JSA_BOARD=2)",
            "klaxp2": "Klax prototype set 2 - needs the single-CPU JSA-II core build (EXTRA_EN=0, JSA_BOARD=2)",
            "guts":   "Guts n' Glory prototype - needs the Guts core build (single CPU, JSA-II, FFxxxx video map)"}
    print(f"romset: {setname} ({DESC[setname]})")

    # maincpu @0x000000
    off = 0x000000
    for hi, lo in T["MAIN"]:
        seg = interleave(rd(romdir, hi), rd(romdir, lo)); img[off:off+len(seg)] = seg; off += len(seg)
    # set 2 only: CPU 0x80000-0x9FFFF lives at image 0x0A0000 (EPROM2-163 remap in escape_core)
    if T["MAIN_HI"]:
        seg = interleave(rd(romdir, T["MAIN_HI"][0]), rd(romdir, T["MAIN_HI"][1])); img[0x0A0000:0x0A0000+len(seg)] = seg

    # extra @0x080000: own program at +0, shared copy at +0x60000 (Escape only)
    base = 0x080000
    if T["EXTRA_OWN"]:
        seg = interleave(rd(romdir, T["EXTRA_OWN"][0]), rd(romdir, T["EXTRA_OWN"][1])); img[base:base+len(seg)] = seg
        seg = interleave(rd(romdir, T["SHARED"][0]), rd(romdir, T["SHARED"][1])); img[base+0x60000:base+0x60000+len(seg)] = seg

    # jsa 6502 @0x100000
    b = rd(romdir, T["JSA"]); img[0x100000:0x100000+len(b)] = b
    # chars @0x110000 (set 2 folders may name the chip 136069.125d, set 1 136069-1007.125d - same CRC)
    b = rd(romdir, T["CHARS"], 0x04000); img[0x110000:0x110000+len(b)] = b
    # sprites @0x120000: repacked to CHUNKY 4bpp for single-burst tile-row fetches
    # (Escape/Guts 1 MB, Klax 256 KB - the rest of the slot stays zero)
    chunky = repack_planar(romdir, T["SPRITES"]); img[0x120000:0x120000+len(chunky)] = chunky
    # JSA-II ADPCM @0x240000 (Klax/Guts): verbatim, 64 KB chips in region order
    if T["OKI"]:
        off = 0x240000
        for name in T["OKI"]:
            b = rd(romdir, name); img[off:off+len(b)] = b; off += len(b)
    # Guts playfield tiles @0x280000: own 1 MB planar region, same repack
    if T["TILES"]:
        chunky = repack_planar(romdir, T["TILES"]); img[0x280000:0x280000+len(chunky)] = chunky

    with open(out, "wb") as f:
        f.write(img)
    print(f"wrote {out}: {len(img)} bytes (0x{len(img):X})")
    print("  0x000000 maincpu | 0x080000 extra | 0x100000 jsa6502 | 0x110000 chars | 0x120000 sprites"
          + (" | 0x240000 adpcm" if T["OKI"] else "") + (" | 0x280000 tiles" if T["TILES"] else ""))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
