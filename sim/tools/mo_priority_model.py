#!/usr/bin/env python3
"""Reference model of the Escape (eprom) motion-object / playfield priority ASIC.

This is a literal transcription of the PAL/GAL equations quoted in
reference/eprom.cpp (screen_update_eprom, ~lines 300-500) together with the
MAME merge loop that consumes them.  It exists so the RTL compositor in
src/fpga/core/core_top.v can be checked pixel-for-pixel against the spec.

Pen formats (derived from MAME, see docs/mo_priority.md for the citation):

  MO   pen = (mopriority << 12) | 0x100 | (mocolor << 4) | mopix
  PF   pen = 0x200 | (pfcolor << 4) | pfpix

  pfpriority = (pf >> 4) & 3   -> low two bits of the playfield tile colour
  PFX3       = pf & 8          -> bit 3 of the playfield 4bpp pixel
"""

PRIORITY_SHIFT = 12
DATA_MASK = 0x0FFF

MO_TRANSPARENT = 0xFFFF


def pf_pen(pfcolor, pfpix):
    """Playfield pen as MAME's tilemap would produce it for eprom."""
    return 0x200 | ((pfcolor & 0x0F) << 4) | (pfpix & 0x0F)


def mo_pen(mopriority, mocolor, mopix):
    """Motion-object pen as atari_motion_objects_device would produce it."""
    return ((mopriority & 7) << PRIORITY_SHIFT) | 0x100 | ((mocolor & 0x0F) << 4) | (mopix & 0x0F)


def decide(mo, pf):
    """Merge one pixel.

    mo -- 16-bit MO bitmap value, or MO_TRANSPARENT when no MO covers it
    pf -- 16-bit playfield pen already in the frame buffer

    Returns (out_pen, info) where info is a dict of the intermediate ASIC
    signals so a bench can compare them individually.
    """
    info = dict(mo_valid=0, mopriority=0, pfpriority=0, pfx3=0,
                forcemc0=0, shade=0, pfm=0, m7=0, special=0, layer='pf')

    if mo == MO_TRANSPARENT:
        return pf, info

    info['mo_valid'] = 1
    mopriority = (mo >> PRIORITY_SHIFT) & 7
    pfpriority = (pf >> 4) & 3
    info['mopriority'] = mopriority
    info['pfpriority'] = pfpriority
    info['pfx3'] = 1 if (pf & 8) else 0

    # upper bit of MO priority signals special rendering and doesn't draw anything
    if mopriority & 4:
        info['special'] = 1
        return pf, info

    # --- FORCEMC0 -----------------------------------------------------------
    # FORCEMC0=!PFX3*PFX4*PFX5*!MPR0
    #         +!PFX3*PFX5*!MPR1
    #         +!PFX3*PFX4*!MPR0*!MPR1
    forcemc0 = 0
    if not (pf & 8):
        if (((pfpriority == 3) and not (mopriority & 1)) or
                ((pfpriority & 2) and not (mopriority & 2)) or
                ((pfpriority & 1) and (mopriority == 0))):
            forcemc0 = 1
    info['forcemc0'] = forcemc0

    # --- SHADE --------------------------------------------------------------
    # !SHADE=!MPX0+MPX1+MPX2+MPX3+!MPX4*!MPX5*!MPX6*!MPX7+FORCEMC0
    shade = 1
    if ((mo & 0x0F) != 1) or ((mo & 0xF0) == 0) or forcemc0:
        shade = 0
    info['shade'] = shade

    # --- PF/M ---------------------------------------------------------------
    # !PF/M=MPR0*MPR1+PFX3+!PFX4*MPR1+!PFX5*MPR1+!PFX5*MPR0
    #      +!PFX4*!PFX5*!MPR0*!MPR1
    pfm = 1
    if ((mopriority == 3) or
            (pf & 8) or
            (not (pfpriority & 1) and (mopriority & 2)) or
            (not (pfpriority & 2) and (mopriority & 2)) or
            (not (pfpriority & 2) and (mopriority & 1)) or
            ((pfpriority == 0) and (mopriority == 0))):
        pfm = 0
    info['pfm'] = pfm

    # --- M7 -----------------------------------------------------------------
    # M7=MPX0*!MPX1*!MPX2*!MPX3
    m7 = 1 if (mo & 0x0F) == 1 else 0
    info['m7'] = m7

    if (not pfm) and (not m7):
        info['layer'] = 'mo'
        if not forcemc0:
            return mo & DATA_MASK, info
        return mo & DATA_MASK & ~0x70, info

    info['layer'] = 'pf'
    out = pf
    if shade:
        out |= 0x100
    if m7:
        out |= 0x080
    return out, info


def decide_fields(mo_valid, mopriority, mocolor, mopix, pfcolor, pfpix):
    """Convenience wrapper taking the raw fields the RTL bench dumps."""
    pf = pf_pen(pfcolor, pfpix)
    mo = mo_pen(mopriority, mocolor, mopix) if mo_valid else MO_TRANSPARENT
    return decide(mo, pf)


def truth_table():
    """Enumerate the whole decision space (mopri x mocolor!=0 x mopix x pfpri x pfx3).

    Returns a list of rows; used by the bench comparison and by the exhaustive
    self-check below.
    """
    rows = []
    for mopri in range(8):
        for mocolor in range(16):
            for mopix in range(1, 16):          # pen 0 is transparent
                for pfcolor in range(16):
                    for pfpix in range(16):
                        out, info = decide_fields(1, mopri, mocolor, mopix,
                                                  pfcolor, pfpix)
                        rows.append((mopri, mocolor, mopix, pfcolor, pfpix,
                                     out, info))
    return rows


if __name__ == '__main__':
    import sys
    rows = truth_table()
    nmo = sum(1 for r in rows if r[6]['layer'] == 'mo' and not r[6]['special'])
    nsp = sum(1 for r in rows if r[6]['special'])
    print(f'{len(rows)} combinations: mo-wins={nmo} special={nsp} '
          f'pf-wins={len(rows) - nmo - nsp}')
    sys.exit(0)
