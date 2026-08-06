#!/usr/bin/env python3
"""Reverse the bit order of every byte in a Quartus .rbf to produce the
Analogue Pocket .rbf_r the APF loader expects.

Usage: python3 reverse_bits.py input.rbf output.rbf_r
"""
import sys

def main() -> int:
    if len(sys.argv) != 3:
        print("usage: reverse_bits.py <input.rbf> <output.rbf_r>", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
    with open(src, "rb") as f:
        data = f.read()
    with open(dst, "wb") as f:
        f.write(data.translate(table))
    print(f"wrote {dst} ({len(data)} bytes, bit-reversed)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
