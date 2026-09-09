#!/usr/bin/env python3
"""GAL16V8 fuse-map decoder for the Escape PCB PALs (MOSHADE-162).

The romset ships the six GAL16V8 fuse dumps as MAME "jedbin" files
(4-byte big-endian fuse count = 0x892 = 2194, then LSB-first packed fuses;
fuse 0 = link intact = input connected).  MAME's `jedutil` does the same
job but the downloaded binary is quarantined on this Mac, so this is the
40-line equivalent for complex mode (PAL16L8 emulation): columns are the
pins 2,1,3,18,4,17,5,16,6,15,7,14,8,13,9,11 (true/complement pairs), rows
0..63 are eight product terms per OLMC for pins 19..12, the first row of
each group is the output enable.  Outputs are active low (XOR=0).

Usage:
  gal16v8.py <fuses.bin> '{"pin":"NAME",...}'
Pin names for 100T/100V are in docs/investigations/MAP_HALFTONE.md.
ROM data is read from the local romset only and never enters the repo.
"""
def load(path):
    b=open(path,'rb').read(); n=int.from_bytes(b[:4],'big'); fu=b[4:]
    return [ (fu[i//8]>>(i%8))&1 for i in range(n) ]
# complex-mode column pins (true, complement) left to right
COLS=[2,1,3,18,4,17,5,16,6,15,7,14,8,13,9,11]
OUTPINS=[19,18,17,16,15,14,13,12]
def decode(path, names):
    f=load(path)
    syn,ac0=f[2192],f[2193]
    ac1=f[2120:2128]; xor=f[2048:2056]; pten=f[2128:2192]
    print(f"{path}: fuses={len(f)} SYN={syn} AC0={ac0} AC1={ac1} XOR={xor}")
    for o,pin in enumerate(OUTPINS):
        terms=[]
        for r in range(8):
            row=o*8+r; fuses=f[row*32:(row+1)*32]
            if all(fuses):   # all blown = term absent (always false)
                terms.append(None); continue
            lits=[]
            for c in range(16):
                t,cm=fuses[2*c],fuses[2*c+1]
                p=COLS[c]; nm=names.get(p,f"p{p}")
                if t==0 and cm==0: lits.append("0")     # both connected -> always 0
                elif t==0: lits.append(nm)
                elif cm==0: lits.append("/"+nm)
            terms.append(" & ".join(lits) if lits else "1")
        oe=terms[0]; sums=[t for t in terms[1:] if t is not None]
        onm=names.get(pin,f"p{pin}")
        pol="" if xor[o] else "/"
        print(f"  pin{pin:2d} {onm:8s}: OE=[{oe}]  {pol}{onm} = " + ("\n" + " "*22 + "+ ").join(sums) if sums else f"  pin{pin:2d} {onm}: (unused)")
if __name__=="__main__":
    import json
    names=json.loads(sys.argv[2]) if len(sys.argv)>2 else {}
    decode(sys.argv[1], {int(k):v for k,v in names.items()})
