#!/usr/bin/env python3
"""Summarise logic_cadence.lua output: cadence, headroom, the deadline-model
validation against the injection sweeps, and the slow-CPU conversion table.

  cadence_report.py <run_dir> [<reference.csv>]
"""
import csv, glob, os, re, sys
import numpy as np

T      = 16688.15                       # one video frame, us (7159090/(456*262))
FRAMECY = 119318                        # 68000 clocks in one video frame
CPUUS  = 7.15909                        # clocks per us

def rows(p):
    return [x for x in csv.DictReader(open(p)) if x.get("mo_spans")]

def col(r, k):
    return np.array([float(x[k]) for x in r])

def durs(r, who):
    if who == "world":
        return col(r, "last_dur_us")[col(r, "bodies_ended") == 1]
    return col(r, "vid_last_us")[col(r, "vid_ended") == 1]

def model(D, scale=1.0, add=0.0, ovh=0.0):
    """updates/frame for logic frames of duration D/scale + add.
    A body of duration d occupies ceil((d+ovh)/T) video frames -- the vblank IRQ
    is acked early by whichever CPU gets there first, so an overrunning body
    does not restart on RTE, it waits for the next vblank.  `ovh` is the
    per-frame work OUTSIDE the timed bracket (handler prologue/epilogue, the
    shared-RAM TAS, the CPU's background loop); it is fitted from the injection
    sweep, not assumed."""
    d = D / scale + add
    return len(d) / np.ceil((d + ovh) / T).sum()


def fit_ovh(base, pat, who):
    """least-squares fit of the out-of-bracket overhead against a sweep."""
    fs = sorted(glob.glob(os.path.join(base, pat)),
                key=lambda p: int(re.search(r"(\d+)\.csv", p).group(1)))
    pts = []
    for f in fs:
        n = int(re.search(r"(\d+)\.csv", f).group(1))
        r = rows(f)
        st = col(r, "bodies_started" if who == "world" else "vid_started")
        D = durs(r, who)
        if len(D) > 100: pts.append((D, st.mean()))
    if not pts: return 0.0, 0.0
    best = min(((np.mean([abs(model(D, ovh=o) - m) for D, m in pts]), o)
                for o in np.arange(0, 4000, 25)))
    return best[1], best[0]

def describe(r, who, label):
    st = col(r, "bodies_started" if who == "world" else "vid_started")
    D  = durs(r, who)
    print(f"  {label:<22s} updates/frame {st.mean():.4f}   frames with none "
          f"{int((st==0).sum())}/{len(st)} ({100*(st==0).mean():.3f}%)")
    q = np.percentile(D, [50, 90, 99, 99.9])
    print(f"  {'':22s} logic-frame  mean {D.mean():6.0f}us = {100*D.mean()/T:4.1f}% of frame "
          f"({D.mean()*CPUUS:6.0f} of {FRAMECY} cycles)")
    print(f"  {'':22s}              p50 {q[0]:.0f}  p90 {q[1]:.0f}  p99 {q[2]:.0f} "
          f" p99.9 {q[3]:.0f}  max {D.max():.0f} ({100*D.max()/T:.0f}%)")
    return D

def sweep(base, pat, who, label, ovh=0.0):
    fs = sorted(glob.glob(os.path.join(base, pat)),
                key=lambda p: int(re.search(r"(\d+)\.csv", p).group(1)))
    if not fs: return
    print(f"\n== deadline-model validation: {label} ==")
    print(f"{'inject':>7} {'+us/frame':>10} {'measured':>9} {'model':>8} {'meanD':>7} {'maxD':>7}")
    for f in fs:
        n = int(re.search(r"(\d+)\.csv", f).group(1))
        r = rows(f)
        st = col(r, "bodies_started" if who == "world" else "vid_started")
        D = durs(r, who)
        if len(D) < 100: continue
        print(f"{n:7d} {n*10/CPUUS:10.0f} {st.mean():9.4f} {model(D, ovh=ovh):8.4f} "
              f"{D.mean():7.0f} {D.max():7.0f}")

if __name__ == "__main__":
    base = sys.argv[1]
    ref  = sys.argv[2] if len(sys.argv) > 2 else os.path.join(base, "final2p.csv")
    r = rows(ref)
    print(f"== reference run: {os.path.basename(ref)}  {len(r)} video frames "
          f"({len(r)/59.9227:.0f} s of play) ==")
    mo = col(r, "mo_objs"); ti = col(r, "mo_tiles")
    print(f"  sprite load: objects p50 {np.percentile(mo,50):.0f} p99 {np.percentile(mo,99):.0f} "
          f"max {mo.max():.0f};  tiles p50 {np.percentile(ti,50):.0f} p99 {np.percentile(ti,99):.0f} "
          f"max {ti.max():.0f}")
    Dw = describe(r, "world", "world (extra) 68000")
    Dv = describe(r, "video", "video (main) 68000")
    if "vcyc" in r[0]:
        v, e = col(r, "vcyc"), col(r, "ecyc")
        print(f"\n  bus cycles/frame (MAME = a zero-waitstate board):")
        print(f"    video CPU  median {np.median(v):.0f} (0x{int(np.median(v)):04X})  "
              f"p5 {np.percentile(v,5):.0f}  p95 {np.percentile(v,95):.0f}")
        print(f"    extra CPU  median {np.median(e):.0f} (0x{int(np.median(e)):04X})  "
              f"p5 {np.percentile(e,5):.0f}  p95 {np.percentile(e,95):.0f}")
    ow, ew = fit_ovh(base, "inj[0-9]*.csv",  "world")
    ov, ev = fit_ovh(base, "vinj[0-9]*.csv", "video")
    sweep(base, "inj[0-9]*.csv",  "world", "world CPU, cycles injected into $f792", ow)
    sweep(base, "vinj[0-9]*.csv", "video", "video CPU, cycles injected into $4052e", ov)
    print(f"\n  fitted out-of-bracket overhead: world {ow:.0f} us/frame (mean model error {ew:.4f}), "
          f"video {ov:.0f} us/frame (mean model error {ev:.4f})")
    print("\n== what a SLOWER CPU would do to this same workload ==")
    print(f"{'CPU speed':>10} {'world upd/frame':>17} {'video upd/frame':>17}")
    for s in (1.00, 0.95, 0.92, 0.90, 0.88, 0.86, 0.83, 0.80, 0.76, 0.70, 0.65, 0.60, 0.50):
        print(f"{s*100:9.0f}% {model(Dw, s, ovh=ow):17.4f} {model(Dv, s, ovh=ov):17.4f}")
