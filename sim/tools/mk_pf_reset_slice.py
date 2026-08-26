#!/usr/bin/env python3
"""PFRESET-111: cut the playfield fetch channel out of core_top.v, verbatim.

sim/tb/tb_pf_reset.v does not RE-IMPLEMENT the RTL it tests (tb_pf_cram.v
does, and that copy is a standing drift hazard - a fix applied to core_top.v
and not to the bench would be invisible there).  Instead this script slices
the three shipped blocks the bug lives in straight out of
src/fpga/core/core_top.v and writes them as `include fragments:

  pf_pixel.vh    the pixel-domain PF pipeline: enqueue -> A/B issue ->
                 completion -> slot ring          (core_top.v `always @(posedge
                 clk_sys_7159)` containing `case(vis_x[2:0])`)
  pf_service.vh  the sdram-domain CRAM read-start chain and the cvg_ph fetch
                 FSM that serves it, plus the vidkill drain arm and the cst
                 forensics reader that competes with it for the controller
  pf_resync.vh   the SDSCHED-75 reset resync - the block that eats the
                 request edges

The bench declares the surrounding nets and instantiates the REAL
third_party psram controller, so the logic under test is byte-identical to
what synthesises.  Every anchor is asserted; if core_top.v is restructured so
a slice cannot be found, this script fails loudly rather than emitting a
stale or partial fragment.

--defeat-fix additionally EXCISES the PFRESET-111 reset block from pf_pixel.vh,
reconstructing the pre-fix RTL.  That is how the bench produces its failing
case: not a hand-written imitation of the old code, but the shipped block with
exactly the fix removed.  It asserts the block is present, so it also fails if
the fix is ever deleted from core_top.v.
"""
import argparse
import os
import re
import sys

WORD_BEGIN = re.compile(r'\bbegin\b')
WORD_END = re.compile(r'\bend\b')


def strip_comment(line):
    # good enough for this file: no string literals carry // or begin/end
    i = line.find('//')
    return line if i < 0 else line[:i]


def match_end(lines, start):
    """Index of the `end` closing the `begin` on line `start`."""
    depth = 0
    seen = False
    for i in range(start, len(lines)):
        code = strip_comment(lines[i])
        depth += len(WORD_BEGIN.findall(code))
        if len(WORD_BEGIN.findall(code)):
            seen = True
        depth -= len(WORD_END.findall(code))
        if seen and depth == 0:
            return i
    raise SystemExit('mk_pf_reset_slice: unbalanced begin/end from line %d' % (start + 1))


def find(lines, needle, start=0, what=''):
    for i in range(start, len(lines)):
        if needle in lines[i]:
            return i
    raise SystemExit('mk_pf_reset_slice: anchor not found: %s (%s)'
                     % (needle, what or 'core_top.v restructured?'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default='src/fpga/core/core_top.v')
    # PFEXTRACT-120 moved the PF pixel pipeline into escape_pf.v. The pixel
    # fragment is cut from there; the sdram-domain fragments (CRAM drain,
    # service chain, SDSCHED-75 resync) still live in core_top.v. Without this
    # split the 'case(vis_x[2:0])' anchor matched core_top's ALPHA scanout -
    # a block that compiles and does nothing for the playfield - and every
    # phase reported NONE, which the gate's own honesty checks then flagged.
    ap.add_argument('--pixel-src', default='src/fpga/core/rtl/escape_pf.v')
    ap.add_argument('--outdir', default='sim/build/pfslice')
    ap.add_argument('--defeat-fix', action='store_true')
    args = ap.parse_args()

    with open(args.src) as f:
        lines = f.read().split('\n')
    with open(args.pixel_src) as f:
        plines = f.read().split('\n')

    # ---- pf_pixel: the always block whose first statement is case(vis_x[2:0])
    ci = find(plines, 'case(vis_x[2:0])', what='PF pixel pipeline (escape_pf.v)')
    ai = ci - 1
    while ai >= 0 and 'always @(posedge clk_sys_7159)' not in plines[ai]:
        ai -= 1
        if ci - ai > 4:
            raise SystemExit('mk_pf_reset_slice: case(vis_x[2:0]) is no longer '
                             'the head of a clk_sys_7159 always block')
    pf = plines[ai:match_end(plines, ai) + 1]

    fix_present = any('PFRESET-111' in l for l in pf)
    if not fix_present:
        raise SystemExit('mk_pf_reset_slice: the PFRESET-111 reset block is NOT '
                         'in the PF pixel pipeline (%s). The fix has been ' % args.pixel_src +
                         'removed or moved; tb_pf_reset.v cannot grade it.')
    if args.defeat_fix:
        m = find(pf, 'PFRESET-111', what='fix marker')
        fi = find(pf, 'if(!core_reset_n) begin', m, what='fix reset block')
        fe = match_end(pf, fi)
        pf = pf[:fi] + ['        // [pf_reset bench] PFRESET-111 reset block excised '
                        '(%d lines) - pre-fix RTL' % (fe - fi + 1)] + pf[fe + 1:]

    # ---- pf_drain: the CRAM download-mirror queue.  Outside the chk_state
    # case in core_top and therefore live at every chk_state, which is what
    # makes it the one client that can hold the controller away from the PF
    # read-start chain while the core is in reset.
    di = find(lines, 'cwr_snoop_d <= sd_wr_req;', what='CRAM download mirror')
    de = find(lines, 'cq_n <= cq_n + (cq_enq', di, what='end of CRAM drain')
    drain = lines[di:de + 1]

    # ---- pf_service: vidkill drain arm .. end of the cst forensics re-arm
    si = find(lines, 'if(vidkill_sd) begin', what='CRAM video drain arm')
    ti = find(lines, 'vb_cst_d <= vblank_w;', si, what='end of CRAM service chain')
    svc = lines[si:ti + 1]

    # ---- pf_resync: the SDSCHED-75 reset resync
    ri = find(lines, 'if(!core_rstn_sd) begin', what='SDSCHED-75 reset resync')
    resync = lines[ri:match_end(lines, ri) + 1]
    if not any('vg_reqA_last <= vg_reqA_s' in l for l in resync):
        raise SystemExit('mk_pf_reset_slice: the resync block no longer retires '
                         'vg_reqA_last - the bench is grading the wrong block.')

    os.makedirs(args.outdir, exist_ok=True)
    banner = ('// GENERATED by sim/tools/mk_pf_reset_slice.py from %s - '
              'DO NOT EDIT.\n' % args.src)
    # escape_pf.v's block references module parameters and PFCACHE wires that
    # the tb harness does not declare. Pin them to SHIPPING values here so the
    # fragment elaborates standalone - and so the bench always grades the
    # shipped configuration, not whatever a sweep last set.
    compat = ("localparam [8:0] LEAD = 9'd16;\n"
              "localparam [1:0] RP_OFF = 2'd0;\n"
              "localparam integer WRAPFIX = 0, PFC_EN = 0, NCH = 2;\n"
              "localparam integer PFC_N = 32, PFC_IX = 5;\n"
              "wire pc_hit = 1'b0;\n"
              "wire [31:0] pc_out = 32'd0;\n"
              "wire [1:0] qslot = 2'd0;\n"
              "reg  vg_doneC_last = 1'b0, vg_doneD_last = 1'b0;\n"
              "reg  inflC = 1'b0, inflD = 1'b0;\n"
              "wire vg_doneC_s = 1'b0, vg_doneD_s = 1'b0;\n"
              "wire [31:0] vg_dataC = 32'd0, vg_dataD = 32'd0;\n"
              "reg  [23:0] vg_addrC_px, vg_addrD_px;\n"
              "reg  vg_reqC_px = 1'b0, vg_reqD_px = 1'b0;\n"
              "reg  [1:0] pf_inflC, pf_inflD;\n"
              "reg  [31:0] pc_val;\n"
              "reg  [31:0] pc_data [0:31];\n"
              "reg  [16:0] pc_tag  [0:31];\n")
    for name, body in (('pf_pixel.vh', pf), ('pf_service.vh', svc),
                       ('pf_drain.vh', drain), ('pf_resync.vh', resync)):
        with open(os.path.join(args.outdir, name), 'w') as f:
            f.write(banner)
            if name == 'pf_pixel.vh':
                f.write(compat)
            f.write('\n'.join(body))
            f.write('\n')
    sys.stderr.write('mk_pf_reset_slice: pf_pixel %d lines, pf_service %d, '
                     'pf_drain %d, pf_resync %d%s\n'
                     % (len(pf), len(svc), len(drain), len(resync),
                        '  [FIX EXCISED]' if args.defeat_fix else '  [fix present]'))


if __name__ == '__main__':
    main()
