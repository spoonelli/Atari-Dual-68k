# Memory Architecture Bake-off

Three contenders replace the ad-hoc SDRAM arbiter+queue stack. Same game,
same test protocol, judged on hardware. Branches build independently via CI.

## Contenders
1. **branch `tdm-sched`** — one SDRAM, fixed time-division slots
   (pf / sprite / CPU / refresh every cell). Determinism by timetable.
2. **branch `linebuf`** — blanking-time bulk fetch: whole pf scanline +
   sprite rows burst into BRAM during hblank; active line touches only BRAM.
   Closest in spirit to the real MOHLB line-buffer chips.
3. **branch `cram-gfx`** — graphics assets move to the Pocket's cellular RAM
   (CRAM0, 8MB, own bus); SDRAM keeps program ROM. True separate buses -
   the actual PCB topology. Primary candidate.

## Judging criteria (each flashed on-device)
- Attract totem scene + title logo vs MAME refs (scratchpad/title3)
- In-game floor solidity during sprite-heavy scenes
- Boot ROM self-test stability across 3 cold boots
- 10-minute warm soak: no degradation
- Fitter: builds reproducibly at fixed seed, positive internal slack

Winner becomes the release architecture; losers are deleted, and the
shadows/scrubber/probe scaffolding shrink accordingly.
