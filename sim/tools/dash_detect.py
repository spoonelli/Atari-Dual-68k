import numpy as np
def scan(fr, win=32, bg_std_max=18.0, rel=0.55, absmin=60, min_hits=6, ac_min=0.40,
         play_rows=range(14,96)):
    """Intruder-on-uniform-background detector, RELATIVE contrast.
    dark pixel := L < rel*bmean  AND  bmean-L > absmin  (works on dark and bright bg)."""
    L=fr.sum(axis=2).astype(np.float32); H,W=L.shape
    expo=0; dets=[]
    for y in play_rows:
        if y-5<0 or y+5>=H: continue
        bg=np.concatenate([L[y-5:y-2],L[y+3:y+6]],axis=0)
        bmean=bg.mean(axis=0); bstd=bg.std(axis=0)
        dark=(L[y] < rel*bmean) & ((bmean-L[y]) > absmin)
        for x0 in range(0,W-win,8):
            sl=slice(x0,x0+win)
            if bstd[sl].mean()>bg_std_max: continue
            expo+=1
            seg=dark[sl].astype(np.float32); h=int(seg.sum())
            if h<min_hits: continue
            s=seg-seg.mean(); den=float((s*s).sum())
            if den<=0: continue
            best=(0.0,0)
            for lag in (4,5,6):
                ac=float((s[:-lag]*s[lag:]).sum())/den
                if ac>best[0]: best=(ac,lag)
            if best[0]>ac_min: dets.append((y,x0,h,best[1],round(best[0],3)))
    return expo, dets


# ---------------------------------------------------------------- self-test
# A detector that cannot fail is worthless. `python3 dash_detect.py <mame.raw>`
# runs three controls and REFUSES to report a rate unless all three behave:
#   POSITIVE : a synthetic 2-row period-4 dash injected onto a uniform wall
#              MUST be detected (an earlier version of this file used an
#              ABSOLUTE contrast floor and silently could not fire on dark
#              backgrounds at all -- it scored a perfectly clean negative
#              control for that reason alone).
#   NEGATIVE : pristine MAME frames of the same game MUST score ~0.
#   LOSSY    : MAME frames pushed through the Pocket scaler kernel
#              (240->1080 rows as 4,5 alternating; 336->1440 cols as 30/7)
#              and JPEG at a quality NOISIER than the real capture, then
#              point-resampled back, MUST also score ~0. This is what rules
#              out H.264 ringing as the source.
if __name__ == "__main__":
    import sys, io
    from PIL import Image
    raw = np.fromfile(sys.argv[1], dtype=np.uint8)
    per = 336*240*4 + 6                      # MAME screen:pixels() + "336""240"
    n   = len(raw)//per
    def mf(i):
        b = raw[i*per:i*per+336*240*4].reshape(240,336,4)
        return b[:,:,[2,1,0]]
    rowmap = np.array([k for k in range(240) for _ in range(4 if k%2==0 else 5)])
    colmap = np.array([min(335,(x*7)//30) for x in range(1440)])
    rinv = np.array([int(round(np.where(rowmap==k)[0].mean())) for k in range(240)])
    cinv = np.array([int(round(np.where(colmap==k)[0].mean())) for k in range(336)])
    def lossy(fr, q=88):
        big = fr[rowmap][:,colmap]
        c = np.zeros((1080,1920,3), np.uint8); c[:,240:1680] = big
        b = io.BytesIO(); Image.fromarray(c).save(b,'JPEG',quality=q)
        d = np.asarray(Image.open(io.BytesIO(b.getvalue())).convert('RGB'))
        return d[:,240:1680][rinv][:,cinv]
    def inject(fr, y, x):
        f = fr.copy()
        for xx in range(x, x+32):
            if xx % 5 in (0,1): f[y,xx] = [0,0,0]; f[y+1,xx] = [0,0,0]
        return f
    pos = any(scan(inject(mf(i), y, x))[1]
              for i in range(0, n, max(1,n//40)) for (y,x) in ((80,0),(86,8)))
    E=D=0
    for i in range(n):
        e,d = scan(mf(i)); E+=e; D+=len(d)
    EL=DL=0
    for i in range(0, n, 7):
        e,d = scan(lossy(mf(i))); EL+=e; DL+=len(d)
    print("POSITIVE control (injected dash detected) : %s" % ("PASS" if pos else "FAIL"))
    print("NEGATIVE control (pristine MAME)          : %d/%d = %.7f" % (D,E,D/max(E,1)))
    print("LOSSY    control (scaler+JPEG88+resample) : %d/%d = %.7f" % (DL,EL,DL/max(EL,1)))
    if not pos:
        sys.exit("REFUSING to report: the detector could not detect an injected dash.")
