#!/usr/bin/env python3
"""Golden checker for tb_pf_cram: reconstructs each displayed 8px cell's
32-bit word from the dumped nibbles and verifies it equals the CRAM words
of the tile the map assigns to that cell. Reports mismatches per display
column - the accumulating-rightward latency signature seen on hardware
(build 39, the one-in-flight design) shows up directly as rising counts
toward the right edge.

PFSIM-113 - this checker never agreed with the bench it checks. Two faults,
both here rather than in the RTL:

  * cram_word() modelled low16(a * 2654435761) while tb_pf_cram.v filled its
    chip model with the identity cmem[k]=k[15:0]. Resolved toward the hash;
    the bench now generates it. Rationale and the cost of that choice are
    recorded at the CRAM FILL PATTERN comment in sim/tb/tb_pf_cram.v - the
    short version is that the identity pattern is structured enough that the
    old sliding offset search scored 128/296 on a 16-cell shift, so a real
    addressing error could be absorbed by the search instead of reported.

  * the map index was computed ROW-major, (ycell<<6)|xcell. The RTL has been
    COLUMN-major, (xcell<<6)|ycell, since LANE3j - core_top.v:2262, whose own
    comment records that the row-major read "transposed every map lookup
    since v13". This checker was written against the convention LANE3j
    deleted.

Also hardened here, because a checker that cannot fail is worse than no
checker: the global column offset is PINNED, not searched (see COLUMN OFFSET
below), and the run's own stimulus counters are audited so a rig that quietly
stops exercising the A/B ping-pong fails instead of reporting a clean frame.
"""
import sys
from collections import defaultdict

PIX = "sim/build/pf_pixels.txt"
STATS = "sim/build/pf_stats.txt"

# must match tb_pf_cram.v's video constants
VID_V_ACTIVE = 240
VID_H_TOTAL = 456
# enqueue window is [VID_V_BPORCH-2, VID_V_BPORCH+VID_V_ACTIVE) x every 8px cell
EXPECT_ENQUEUED = (VID_V_ACTIVE + 2) * (VID_H_TOTAL // 8)

# COLUMN OFFSET. This is pinned, not searched. The pixel pipeline reads the
# map for cell (cx + 4) - pf_x2 = vis_x + 32, i.e. 32px = 4 cells of lead -
# and the show registers deliver it exactly 4 cells later (pfcol_q0..q3 then
# pfcol_show). The two cancel, so display column cx shows map column cx and
# the offset is identically zero. The original checker searched d in 0..5 and
# took the best-scoring value. That search is precisely how a real one-cell
# addressing shift hides: it would be absorbed as "offset +1" and reported as
# a clean frame. The search still runs below, but only as a diagnostic, and a
# nonzero winner is a FAILURE rather than a calibration.
COLUMN_OFFSET = 0


def cram_word(a21):
    """Matches the CRAM FILL PATTERN loop in sim/tb/tb_pf_cram.v.
    Change one only by changing both."""
    return (a21 * 2654435761) & 0xFFFF


def map_vdata(vaddr):
    """Matches the tb map model: pf_vdata = (vaddr<<2) | vaddr, low 16."""
    return (((vaddr & 0xFFF) << 2) | (vaddr & 0xFFF)) & 0xFFFF


def map_index(cx, y, doff=0):
    """COLUMN-major, matching pf_vaddr <= {pf_x2[8:3], pf_y[8:3]}
    (core_top.v:2262 / tb_pf_cram.v). NOT (ycell<<6)|xcell."""
    xcell = (cx + doff) & 0x3F
    ycell = (y >> 3) & 0x3F
    return (xcell << 6) | ycell


def tile_words(code15, row3):
    byte = 0x120000 + (code15 << 5) + (row3 << 2)
    wa = (byte >> 1) - 0x88000
    return (cram_word(wa & 0x1FFFFF) << 16) | cram_word((wa | 1) & 0x1FFFFF)


def read_stats():
    stats = {}
    try:
        for line in open(STATS):
            parts = line.split()
            if len(parts) == 2:
                stats[parts[0]] = int(parts[1])
    except OSError:
        pass
    return stats


def main():
    grid = {}
    xpix = 0
    try:
        lines = open(PIX).read().splitlines()
    except OSError as e:
        print(f"FIXTURE ERROR: cannot read {PIX}: {e}")
        print("TB_PF_CRAM FAIL")
        return 1
    for line in lines:
        if not line.strip():
            continue
        x, y, v = line.split()
        if 'x' in v or 'z' in v:
            grid[(int(x), int(y))] = -1     # undefined pixel: always mismatches
            xpix += 1
        else:
            grid[(int(x), int(y))] = int(v, 16)
    if xpix:
        print(f"undefined (x/z) pixels: {xpix}")

    # A zero-size or short dump is a MISSING FIXTURE, never a pass.
    if len(grid) < 1000:
        print(f"FIXTURE ERROR: only {len(grid)} pixels in {PIX} - the sim did "
              f"not produce a frame (missing sim/work fixtures? build failure?)")
        print("TB_PF_CRAM FAIL")
        return 1

    xs = max(x for x, _ in grid) + 1
    ys = max(y for _, y in grid) + 1
    cells_x, rows = xs // 8, ys

    def observed(cx, y):
        w = 0
        for i in range(8):
            p = grid.get((cx * 8 + i, y), 0)
            if p < 0:
                return None
            w = (w << 4) | p
        return w

    def expected(cx, y, doff=COLUMN_OFFSET):
        code = map_vdata(map_index(cx, y, doff)) & 0x7FFF
        return tile_words(code, y & 7)

    # ---- stimulus audit: did the run actually drive the thing under test? ----
    stats = read_stats()
    stim_fail = []
    if not stats:
        stim_fail.append(f"no {STATS} - cannot confirm the run exercised "
                         f"anything; treat as a failed run, not a clean one")
    else:
        single_ch = stats.get("single_ch", 0)
        issueA = stats.get("issueA", 0)
        issueB = stats.get("issueB", 0)
        doneA = stats.get("doneA", 0)
        doneB = stats.get("doneB", 0)
        print(f"stimulus: issueA={issueA} issueB={issueB} "
              f"doneA={doneA} doneB={doneB} single_ch={single_ch}")
        if stats.get("pixels", 0) == 0:
            stim_fail.append("zero pixels dumped")
        if not single_ch and issueB == 0:
            # This is the fault that made this rig useless from 3d03b63 until
            # PFSIM-113: it reported on a two-in-flight design while only ever
            # issuing on channel A.
            stim_fail.append(
                "channel B was NEVER armed (issueB=0) - the A/B ping-pong this "
                "rig exists to validate went unexercised, so a clean frame "
                "here would prove nothing")
        if not single_ch and issueA + issueB != EXPECT_ENQUEUED:
            # Guards the other direction: if someone raises the contention
            # until the PF queue overflows, cells get dropped at enqueue and
            # the resulting mismatches are raw starvation, not an A/B defect.
            # Scoped to the two-channel configuration on purpose - under
            # SINGLE_CH the drops ARE the injected defect (one channel plus
            # the old wait-for-competitor issue gate cannot keep up), so
            # demanding zero drops there would reject the negative control for
            # doing exactly what it is supposed to do.
            stim_fail.append(
                f"issueA+issueB={issueA + issueB} != {EXPECT_ENQUEUED} enqueued "
                f"cells - the PF queue overflowed and dropped fetches; the "
                f"contention level exceeds the design's flow control and any "
                f"mismatch below is unattributable")
        elif single_ch:
            print(f"note: single-channel control dropped "
                  f"{EXPECT_ENQUEUED - issueA - issueB} of {EXPECT_ENQUEUED} "
                  f"enqueued fetches - expected for the one-in-flight design")
        if doneA != issueA or doneB != issueB:
            stim_fail.append(f"completions do not match issues "
                             f"(A {doneA}/{issueA}, B {doneB}/{issueB})")

    # ---- diagnostic offset scan (pinned above; a nonzero winner is a bug) ----
    best, best_hits = None, -1
    for d in range(0, 6):
        hits = sum(1 for cx in range(4, cells_x - 1) for y in range(64, 72)
                   if observed(cx, y) == expected(cx, y, d))
        if hits > best_hits:
            best, best_hits = d, hits
    print(f"column offset: pinned +{COLUMN_OFFSET}; "
          f"best-scoring in scan +{best} (sample hits {best_hits})")
    off_fail = best != COLUMN_OFFSET and best_hits > 0

    colerr = defaultdict(int)
    total = bad = 0
    for y in range(rows):
        for cx in range(2, cells_x):     # skip 2 line-start settling cells
            total += 1
            if observed(cx, y) != expected(cx, y):
                bad += 1
                colerr[cx] += 1
    print(f"cells checked {total}, mismatches {bad} ({100.0*bad/total:.3f}%)")
    if bad:
        print("per-column mismatch counts (col: count):")
        for cx in sorted(colerr):
            print(f"  {cx:3d}: {colerr[cx]}")

    if off_fail:
        print(f"OFFSET ERROR: the frame aligns at column offset +{best}, not "
              f"the +{COLUMN_OFFSET} the pipeline geometry requires - that is a "
              f"real horizontal addressing shift, not a calibration constant")
    for m in stim_fail:
        print(f"STIMULUS ERROR: {m}")

    ok = (bad == 0) and not off_fail and not stim_fail
    print("TB_PF_CRAM " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
