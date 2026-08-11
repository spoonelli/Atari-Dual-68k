#!/usr/bin/env python3
"""Build sim/work/adc_words.hex: a self-contained boot image for
tb_escape_adc, containing NO game ROM content -- only reset vectors and a
hand-assembled stub, so the tb runs without the user-supplied combined
image (run_tb.sh regenerates it automatically; hex files are never
committed, per repo policy).

The stub walks the four ADC0809 channels the way the game does:
  read 260020+2n  -> select channel n, start a conversion (stale data ignored)
  poll 260010 D4  -> ADEOC, high when the conversion completes
  read 260020+2n  -> the fresh result, stored to alpha RAM
giving
  alpha[0..3] = ADC ch0..ch3 (P1 Y, P1 X, P2 Y, P2 X) in the low byte
  alpha[4]    = 0xABCD done marker
"""
import os

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
dst = os.path.join(repo, "sim", "work", "adc_words.hex")
os.makedirs(os.path.dirname(dst), exist_ok=True)

words = [0] * 4096            # 8 KB image (tb serves it with awidth 12)

def poke(byte_addr, *ws):
    for i, w in enumerate(ws):
        words[byte_addr // 2 + i] = w & 0xFFFF

# reset vectors: SSP = top of shared RAM, PC = stub at 0x400
poke(0x0, 0x0016, 0xFF00,
          0x0000, 0x0400)

code = []
for n in range(4):
    adc = 0x260020 + 2 * n
    dst_a = 0x3F4000 + 2 * n
    code += [0x3039, adc >> 16, adc & 0xFFFF,      # move.w ADCn,d0   (select+start)
             0x3239, 0x0026, 0x0010,               # .p: move.w $260010,d1
             0x0801, 0x0004,                       #     btst  #4,d1  (ADEOC)
             0x67F4,                               #     beq.s .p
             0x3039, adc >> 16, adc & 0xFFFF,      # move.w ADCn,d0   (result)
             0x33C0, dst_a >> 16, dst_a & 0xFFFF]  # move.w d0,alpha[n]
code += [0x33FC, 0xABCD, 0x003F, 0x4008,           # move.w #$ABCD,$3F4008 (done)
         0x60FE]                                   # bra.s *
poke(0x400, *code)

with open(dst, "w") as f:
    for w in words:
        f.write(f"{w:04x}\n")
print(f"wrote {dst}: {len(words)} words (ADC channel-walk stub, no game ROM)")
