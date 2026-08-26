#!/usr/bin/env python3
"""Decode the Developer-HUD diagnostic strip from a Pocket gameplay capture.

MOTEL-129 put a machine-readable frame counter on screen (eight 16px blocks,
native rows 222-227, x8..135, frame_count[7:0] MSB-left, white=1) precisely so
that slowdown could be measured from ANY capture as a per-frame NUMBER instead
of eyeballed from scroll motion. This is the tool that does the reading.

What it decodes per sampled video frame:
  * the 8-bit frame counter        -> logic-frames-per-video-frame, stall runs
  * the two cyan BUILD_ID digits   -> which build the capture actually shows
  * the 16 HUD hex slots (y100..123) -> whatever page is selected (page 6:
    slots 0-3 = {trunc, maxlat}, 5-8 = frame_count, 15 = dbgmode digit)

Geometry (device pixels -> capture pixels): the Pocket's 336x240 viewport is
scaled to the capture's active area. The active area is auto-detected once per
run; on a 1920x1080 Genki Arcade capture it is x 240..1679, y 0..1079
(sx=4.2857, sy=4.5). All native coordinates below match core_top.v exactly:
  frame bits  y 222..227, blocks at x 8+16k .. (MOTEL-129)
  chk2 bits   y 228..233, blocks at x 40+16k (16 blocks)
  BUILD_ID    y 228..233, glyphs at x 296..327 (ver_slot 2,3 = ID[7:4],[3:0])
  HUD hex     y 100..123, slot k at x 44+16k, glyph 4x6 at 4px/cell
The strip only exists while 'Developer HUD' is ON (diag_on); frames without it
decode as None and are reported as 'no strip'.

Frame extraction uses the session's AVFoundation extractor (xf), which takes
many timestamps per invocation: xf <video> <outprefix> t1 t2 ...  Point --xf at
it (default /tmp/xf). Extract at t = f/60 + 1/120 to hit frame centers.

Usage:
  capture_decode.py VIDEO --dur 134 [--t0 0] [--fps 60] [--xf /tmp/xf]
                    [--csv out.csv] [--keep-frames]
Prints a summary (build id seen, frame-counter coverage, delta histogram,
stall runs >= 2, effective logic fps) and optionally writes the per-frame CSV.
"""
import argparse, os, subprocess, sys, tempfile, shutil

# hexfont from core_top.v (4x6, bit 3 = leftmost column)
HEXFONT = {
 0x0:[0b1111,0b1001,0b1001,0b1001,0b1001,0b1111],
 0x1:[0b0010,0b0110,0b0010,0b0010,0b0010,0b0111],
 0x2:[0b1111,0b0001,0b1111,0b1000,0b1000,0b1111],
 0x3:[0b1111,0b0001,0b0111,0b0001,0b0001,0b1111],
 0x4:[0b1001,0b1001,0b1111,0b0001,0b0001,0b0001],
 0x5:[0b1111,0b1000,0b1111,0b0001,0b0001,0b1111],
 0x6:[0b1111,0b1000,0b1111,0b1001,0b1001,0b1111],
 0x7:[0b1111,0b0001,0b0010,0b0100,0b0100,0b0100],
 0x8:[0b1111,0b1001,0b1111,0b1001,0b1001,0b1111],
 0x9:[0b1111,0b1001,0b1111,0b0001,0b0001,0b1111],
 0xA:[0b0110,0b1001,0b1111,0b1001,0b1001,0b1001],
 0xB:[0b1110,0b1001,0b1110,0b1001,0b1001,0b1110],
 0xC:[0b1111,0b1000,0b1000,0b1000,0b1000,0b1111],
 0xD:[0b1110,0b1001,0b1001,0b1001,0b1001,0b1110],
 0xE:[0b1111,0b1000,0b1110,0b1000,0b1000,0b1111],
 0xF:[0b1111,0b1000,0b1110,0b1000,0b1000,0b1000],
}

class Geom:
    def __init__(self, left, top, sx, sy):
        self.left, self.top, self.sx, self.sy = left, top, sx, sy
    def at(self, nx, ny):
        return (int(self.left + nx * self.sx), int(self.top + ny * self.sy))

def glyph_score(px, g, nx0, ny0, cx, cy):
    """Best hexfont match for a 4x6 glyph at (nx0,ny0); returns (digit, score)
    with score out of 24 cells, or (None, -1) when there is no contrast."""
    grid = [[sum(px[g.at(nx0 + (c + 0.5) * cx, ny0 + (r + 0.5) * cy)])
             for c in range(4)] for r in range(6)]
    flat = sorted(v for row in grid for v in row)
    lo, hi = flat[0], flat[-1]
    if hi - lo < 150:
        return (None, -1)
    thr = (hi + lo) / 2
    best, bs = None, -1
    for d, rows in HEXFONT.items():
        sc = sum(1 for r in range(6) for c in range(4)
                 if (grid[r][c] > thr) == bool((rows[r] >> (3 - c)) & 1))
        if sc > bs:
            best, bs = d, sc
    return (best, bs)

def autocal(im):
    """Fit the capture's native-x mapping by maximizing the match score of the
    two BUILD_ID stamp glyphs (x 296../312.., y 228..233). Genki captures show
    per-session subpixel placement, so a fixed active-area mapping misreads
    glyph columns; searching (x0, sx) over the plausible range and keeping the
    best-scoring decode was validated at 48/48 cells on five captures spanning
    builds 124-128. Returns (Geom, build_id) or (None, None) if no frame-
    decodable stamp is present (HUD off, or menu screens)."""
    px = im.load()
    best = None
    for x0 in range(280, 365, 2):
        for sx in (3.95, 4.0, 4.05, 4.1, 4.15, 4.2, 4.25, 4.2857, 4.3):
            g = Geom(x0, 0, sx, 4.5)
            d1, s1 = glyph_score(px, g, 296, 228, 2, 1)
            d2, s2 = glyph_score(px, g, 312, 228, 2, 1)
            if s1 < 0 or s2 < 0:
                continue
            if best is None or s1 + s2 > best[0]:
                best = (s1 + s2, g, d1 * 16 + d2)
    if best is None or best[0] < 44:      # require >= 44/48 cells
        return (None, None)
    return (best[1], best[2])

def detect_area(im):
    """Find the game's active rectangle (columns/rows with content)."""
    W, H = im.size
    px = im.load()
    def colmax(x): return max(sum(px[x, y]) for y in range(0, H, 16))
    def rowmax(y): return max(sum(px[x, y]) for x in range(0, W, 16))
    left  = next((x for x in range(0, W, 4)      if colmax(x) > 40), 0)
    right = next((x for x in range(W - 1, 0, -4) if colmax(x) > 40), W - 1)
    top   = next((y for y in range(0, H, 2)      if rowmax(y) > 40), 0)
    bot   = next((y for y in range(H - 1, 0, -2) if rowmax(y) > 40), H - 1)
    return left, top, (right - left + 1) / 336.0, (bot - top + 1) / 240.0

def sample3(px, g, nx, ny):
    """Majority-brightness sample: 3 vertical points inside one native cell."""
    votes = []
    for dy in (0.25, 0.5, 0.75):
        x, y = g.at(nx, ny + dy * 0)  # x once
        x = int(g.left + nx * g.sx)
        y = int(g.top + (ny - 0.5 + dy) * g.sy)
        votes.append(px[x, y])
    return votes

def read_frame_bits(px, g):
    """MOTEL-129 row: 8 blocks, native y 222..227, x 8+16k, white=1/0x202020=0.
    Returns int 0..255 or None if the strip is absent."""
    bits = 0
    for k in range(8):
        nx = 8 + 16 * k + 8          # block center
        vals = [sum(px[g.at(nx, ny)]) for ny in (223.5, 224.5, 225.5)]
        if all(v > 600 for v in vals):
            bits |= 1 << (7 - k)
        elif all(v < 260 for v in vals):   # 0x202020*3 = 288; floor tiles are lighter
            pass
        else:
            return None                    # not the diagnostic strip
    return bits

def read_glyph(px, g, nx0, ny0, cell_x, cell_y):
    """Read a 4x6 hexfont glyph whose top-left native pixel is (nx0, ny0) with
    cell size (cell_x, cell_y) native px per font cell. Matches both polarities
    (HUD glyphs are drawn inverse-video on the field). Returns digit or None."""
    grid = []
    for r in range(6):
        row = []
        for c in range(4):
            x, y = g.at(nx0 + (c + 0.5) * cell_x, ny0 + (r + 0.5) * cell_y)
            row.append(sum(px[x, y]))
        grid.append(row)
    flat = sorted(v for row in grid for v in row)
    lo, hi = flat[0], flat[-1]
    if hi - lo < 150:
        return None                        # no contrast: no glyph here
    thr = (hi + lo) / 2
    best, bestscore = None, -1
    for pol in (1, 0):                     # bright-on-dark, then inverse
        for d, rows in HEXFONT.items():
            score = 0
            for r in range(6):
                for c in range(4):
                    bit = (rows[r] >> (3 - c)) & 1
                    on = grid[r][c] > thr
                    if (on == bool(bit)) == bool(pol):
                        score += 1
            if score > bestscore:
                best, bestscore = d, score
    return best if bestscore >= 21 else None   # 21/24 cells must agree

def read_build_id(px, g):
    """Cyan BUILD_ID[7:4],[3:0] glyphs: y 228..233, x 296..303 and 312..319
    (each glyph 4 cols x 2 native px wide, 6 rows x 1 native px)."""
    d1, s1 = glyph_score(px, g, 296, 228, 2, 1)
    d2, s2 = glyph_score(px, g, 312, 228, 2, 1)
    if s1 < 22 or s2 < 22:
        return None
    return d1 * 16 + d2

def read_hud_slots(px, g):
    """The 16 HUD hex slots: y 100..123, slot k at x 44+16k, 4px font cells."""
    out = []
    for k in range(16):
        out.append(read_glyph(px, g, 44 + 16 * k, 100, 4, 4))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('video')
    ap.add_argument('--dur', type=float, required=True)
    ap.add_argument('--t0', type=float, default=0.0)
    ap.add_argument('--fps', type=float, default=60.0)
    ap.add_argument('--xf', default='/tmp/xf')
    ap.add_argument('--csv')
    ap.add_argument('--keep-frames', action='store_true')
    ap.add_argument('--batch', type=int, default=240)
    args = ap.parse_args()
    from PIL import Image

    tmp = tempfile.mkdtemp(prefix='capdec_')
    n = int((args.dur - args.t0) * args.fps)
    ts = [args.t0 + f / args.fps + 1 / (2 * args.fps) for f in range(n)]
    geom = None
    rows = []          # (t, frame8, build)
    builds = {}
    for b0 in range(0, len(ts), args.batch):
        chunk = ts[b0:b0 + args.batch]
        subprocess.run([args.xf, args.video, os.path.join(tmp, 'f')] +
                       ['%.6f' % t for t in chunk],
                       check=True, capture_output=True)
        for i, t in enumerate(chunk):
            # xf names output <prefix>_NNN_tT.png with NNN the arg index
            cands = [p for p in os.listdir(tmp) if p.startswith('f_%03d_' % i)]
            if not cands:
                rows.append((t, None, None)); continue
            fp = os.path.join(tmp, cands[0])
            im = Image.open(fp).convert('RGB')
            if geom is None:
                geom, bid0 = autocal(im)
                if bid0 is not None:
                    builds[bid0] = builds.get(bid0, 0) + 1
                if geom is None:
                    rows.append((t, None, None))
                    os.unlink(fp)
                    continue
            px = im.load()
            fb = read_frame_bits(px, geom)
            bid = read_build_id(px, geom)
            if bid is not None:
                builds[bid] = builds.get(bid, 0) + 1
            rows.append((t, fb, bid))
            os.unlink(fp)
        for p in os.listdir(tmp):
            os.unlink(os.path.join(tmp, p))
    if not args.keep_frames:
        shutil.rmtree(tmp, ignore_errors=True)

    # ---- statistics
    seen = [(t, fb) for t, fb, _ in rows if fb is not None]
    print("video: %s" % args.video)
    print("frames sampled: %d, with frame-counter strip: %d (%.1f%%)" %
          (len(rows), len(seen), 100.0 * len(seen) / max(1, len(rows))))
    if builds:
        b = max(builds, key=builds.get)
        print("build id: %02X (seen %d times)" % (b, builds[b]))
    if len(seen) > 1:
        deltas = {}
        stall_runs = []
        run = 0
        prev = None
        for t, fb in seen:
            if prev is not None:
                d = (fb - prev) & 0xFF
                deltas[d] = deltas.get(d, 0) + 1
                if d == 0:
                    run += 1
                else:
                    if run >= 2:
                        stall_runs.append((t, run))
                    run = 0
            prev = fb
        total = sum(deltas.values())
        print("logic-frame deltas per video frame: " +
              ", ".join("%d:%d (%.1f%%)" % (d, c, 100.0 * c / total)
                        for d, c in sorted(deltas.items())))
        eff = sum(d * c for d, c in deltas.items()) / total * args.fps
        print("effective logic fps: %.2f" % eff)
        if stall_runs:
            print("stall runs (>=2 repeated frames): %d, longest %d frames at t=%.2f" %
                  (len(stall_runs), max(r for _, r in stall_runs),
                   max(stall_runs, key=lambda x: x[1])[0]))
        else:
            print("stall runs (>=2 repeated frames): none")
    if args.csv:
        with open(args.csv, 'w') as f:
            f.write("t,frame8,build\n")
            for t, fb, bid in rows:
                f.write("%.6f,%s,%s\n" % (t,
                        '' if fb is None else fb,
                        '' if bid is None else '%02X' % bid))
        print("csv: %s" % args.csv)

if __name__ == '__main__':
    main()
