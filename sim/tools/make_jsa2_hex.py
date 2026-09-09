#!/usr/bin/env python3
"""Build sim/work/jsa2_words.hex: a self-contained image (no game ROM data) whose
JSA region (image 0x100000) holds a 30-byte 6502 program that drives the JSA-II
board's registers the way Klax/Guts firmware would - WRIO (OKI out of reset,
pin 7 high), MIX, two OKI command bytes, then a loop that polls the OKI status
and writes the 68k response latch. The 0x240000 ADPCM slot is filled with a
counting pattern so the second ROM client's fetches are visible. Used by
tb_escape_jsa2 (JSA2-164). The image is 0x280000 bytes = 0x140000 words.
"""
import os
here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
dst = os.path.join(repo, "sim", "work", "jsa2_words.hex")
img = bytearray(0x280000)
prog = {
 0xF000: bytes.fromhex("A90D 8D042A A90F 8D062A A981 8D002A A910 8D002A".replace(" ","")),
 0xF014: bytes.fromhex("AD0028 8D0001 A955 8D022A 4C14F0".replace(" ","")),   # loop
 0xF030: bytes.fromhex("8D0628 40".replace(" ","")),                          # IRQ: ack 2806, RTI
 0xFFFA: bytes.fromhex("14F0 00F0 30F0".replace(" ","")),                     # NMI, RESET, IRQ vectors
}
for a, b in prog.items():
    img[0x100000 + a : 0x100000 + a + len(b)] = b
for i in range(0x40000):
    img[0x240000 + i] = i & 0xFF
os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst, "w") as f:
    for i in range(0, len(img), 2):
        f.write(f"{img[i]:02x}{img[i+1]:02x}\n")
print("wrote", dst, len(img) // 2, "words")
