-- logic_cadence.lua -- measure Escape's game-logic cadence in MAME.
--
-- THE QUESTION: a fixed-raster arcade board cannot drop a video frame; the
-- raster free-runs.  What it does under load is MISS ITS LOGIC DEADLINE, so
-- the world updates every 2nd or 3rd video frame.  The number to measure is
-- therefore "logic updates per video frame", and it comes off the game's own
-- code, not off the picture.
--
-- WHAT THE GAME DOES (read from the ROM disassembly, both CPUs):
--
--   extra ("world") 68000, level-4 (vblank) handler:
--     0308  btst #1,$260011 / beq -> rte     ; service-switch escape
--     08fa  tas    $16cc00                   ; shared-RAM semaphore
--     090e  tst.b  $16ccd6 / bne $93e        ; "logic frame still running?" -> drop
--     0916  move.b #$50,$16ccd6              ; BODY START
--     091e  addq.w #1,$16c992                ; logic-frame counter
--     0932  jsr    $f792                     ; the whole world update
--                  ($f792 bumps $16c996 then dispatches up to 32 task slots
--                   from the table at $1bd0a, gated by the mask at $16cce2)
--     0938  clr.b  $16ccd6                   ; BODY END
--
--   main ("video") 68000: its IRQ4 vector points at $05CC, which is only a
--   wrapper -- $05d0 tst.w $3f7f0c picks the boot/march handler at $05e4, and
--   the GAME's handler is reached by $05d8 jsr $20006 -> jmp $404e0:
--     404e4  tas    $16cc00                  ; same semaphore
--     404fe  addq.w #1,$16c990               ; video logic-frame counter
--     40510  tst.b  $16ccd4 / bne            ; same "already running?" gate
--     40518  move.b #$50,$16ccd4             ; BODY START
--     4052e  jsr $5673e / jsr $56120         ; the frame's work
--     4053a  clr.b  $16ccd4                  ; BODY END
--
--   So a write of $50 to $16CCD6 / $16CCD4 starts a logic frame on that CPU
--   and a write of $00 ends it, and no ROM patching is needed to see either.
--
-- THE DEADLINE RULE (measured, not assumed -- see VALIDATION):
--   The vblank IRQ is acked early in the frame by whichever CPU reaches the
--   ack first, so a body that overruns does NOT restart the moment it RTEs --
--   it waits for the next vblank.  A body of duration D therefore occupies
--   ceil(D / 16688.15us) video frames, and
--       updates/frame = n_bodies / sum(frames_consumed).
--   sim/tools/cadence_report.py reproduces every measured cadence in the
--   injection sweep from the measured duration distribution with this rule.
--
-- OUTPUT: CSV, one row per *video* frame (see the header line below).
--   Bus-cycle columns vcyc/ecyc are the same quantity the core's HUD reports
--   as dbg_vcyc/dbg_ecyc, so MAME can serve as the zero-waitstate reference
--   for an on-hardware reading.
--
-- VALIDATION -- a metric that reads 1.00 everywhere is broken, so prove it can
--   read less.  PERF_INJECT=N (world CPU) and PERF_VINJECT=N (video CPU)
--   retarget one JSR through a stub in unused ROM space that burns N DBRA
--   iterations (10 clocks each) before falling through to the real routine.
--   That injects a KNOWN number of 68000 cycles into every logic frame.  The
--   patch is applied after the ROM self-test has passed (PERF_INJECT_AT), so
--   the checksum test still sees the unmodified ROM.
--
-- ENV: PERF_OUT (dir)  PERF_TAG (csv name)  PERF_T0 / PERF_TEND (seconds)
--      PERF_MODE = attract | play (2 players) | play1 (1 player)
--      PERF_SNAP (screen snapshot every N frames, 0 = off)
--      PERF_INJECT / PERF_VINJECT (DBRA iterations per logic frame, 0 = off)
--      PERF_INJECT_AT (when to install the injection stub, seconds)

local OUT   = os.getenv("PERF_OUT") or "/tmp"
local T0    = tonumber(os.getenv("PERF_T0")   or "0")
local TEND  = tonumber(os.getenv("PERF_TEND") or "60")
local MODE  = os.getenv("PERF_MODE") or "attract"
local SNAP  = tonumber(os.getenv("PERF_SNAP") or "0")
local TAG    = os.getenv("PERF_TAG") or "run"
local INJECT = tonumber(os.getenv("PERF_INJECT") or "0")
local INJECT_AT = tonumber(os.getenv("PERF_INJECT_AT") or "18")
local VINJECT   = tonumber(os.getenv("PERF_VINJECT") or "0")

local machine = manager.machine
local ex  = machine.devices[":extra"]
local ma  = machine.devices[":maincpu"]
local se  = ex.spaces["program"]
local sm  = ma.spaces["program"]
local mm  = sm
local scr = machine.screens[":screen"]

local CPUHZ = 7159090.0

----------------------------------------------------------------- crowd proxy
-- Walk the motion-object link lists exactly the way atarimo does: one chain
-- per 8-scanline SLIP band, each band walked independently (a per-band visited
-- set, NOT a global one -- sharing it across bands silently truncates every
-- band after the first).
local function crowd()
  local union, objs, tiles, spans = {}, 0, 0, 0
  for band = 0, 29 do
    local seen = {}
    local link = mm:read_u16(0x3F4F80 + band * 2) & 0x3FF
    for _ = 1, 1024 do
      if seen[link] then break end
      seen[link] = true
      spans = spans + 1
      local a  = 0x3F2000 + link * 8
      local w3 = mm:read_u16(a + 6)
      if not union[link] then
        union[link] = true
        objs  = objs + 1
        tiles = tiles + (((w3 >> 4) & 7) + 1) * ((w3 & 7) + 1)
      end
      local nl = mm:read_u16(a) & 0x3FF
      if nl == link then break end
      link = nl
    end
  end
  return objs, tiles, spans
end

------------------------------------------------------------------- the taps
local body_start   = nil      -- anchor for splitting busy time across frames
local body_origin  = nil      -- true start of the current body (never moved!)
local busy_acc     = 0.0      -- world-CPU body seconds inside this video frame
local body_started = 0        -- bodies started inside this video frame
local body_ended   = 0
local last_dur     = 0.0
local overrun      = 0        -- bodies that ran past a frame boundary

_G.tap_ccd6 = se:install_write_tap(0x16CCD6, 0x16CCD7, "ccd6", function(off, data, mask)
  local hi = (data >> 8) & 0xff
  local t  = machine.time:as_double()
  if hi == 0x50 then
    body_start  = t
    body_origin = t
    body_started = body_started + 1
  elseif hi == 0x00 and body_start then
    busy_acc   = busy_acc + (t - body_start)
    last_dur   = t - body_origin          -- TRUE duration, not the split piece
    body_ended = body_ended + 1
    body_start, body_origin = nil, nil
  end
  return data
end)

local tick992 = 0
_G.tap_992 = se:install_write_tap(0x16C992, 0x16C993, "c992", function(off, data, mask)
  tick992 = tick992 + 1
  return data
end)

-- The world CPU's logic frame opens with  jsr $954  =  "tst.b $16cc00 / bne"
-- i.e. a spin on the shared-RAM semaphore held by the video CPU.  Each spin
-- iteration is a data read of $16cc00, so a read tap counts them exactly.
-- (Opcode fetches do NOT go through Lua taps in MAME 0.289 -- verified -- so
-- data accesses are the only usable probe.)
local spin_reads = 0
_G.tap_spin = se:install_read_tap(0x16CC00, 0x16CC01, "spin", function(off, data, mask)
  spin_reads = spin_reads + 1
  return data
end)

-- ---------------------------------------------------------------- video CPU
-- The video 68000 has the SAME structure, one level deeper.  Its IRQ4 vector
-- points at $05CC, which is only the boot/self-test wrapper:
--     05cc  tst.w $3f7f0c / bne $5e4      ; boot & march handler
--     05d8  jsr   $20006  -> jmp $404e0   ; the GAME's vblank handler
-- and $404e0 is a mirror image of the extra CPU's $08f6:
--     404e4  tas    $16cc00               ; same shared-RAM semaphore
--     404fe  addq.w #1,$16c990            ; video logic-frame counter
--     40510  tst.b  $16ccd4 / bne         ; "already running?" -> drop the vblank
--     40518  move.b #$50,$16ccd4          ; BODY START
--     4052e  jsr $5673e / jsr $56120      ; the frame's work
--     4053a  clr.b  $16ccd4               ; BODY END
-- so the video CPU is bracketed by $16CCD4 exactly as the world CPU is by
-- $16CCD6, and needs no ROM patching at all.
local m_start, m_origin, m_busy, m_started, m_ended, m_last = nil, nil, 0.0, 0, 0, 0.0
_G.tap_ccd4 = sm:install_write_tap(0x16CCD4, 0x16CCD5, "ccd4", function(off, data, mask)
  local hi = (data >> 8) & 0xff
  local t  = machine.time:as_double()
  if hi == 0x50 then
    m_start, m_origin = t, t
    m_started = m_started + 1
  elseif hi == 0x00 and m_start then
    m_busy = m_busy + (t - m_start)
    m_last = t - m_origin
    m_ended = m_ended + 1
    m_start, m_origin = nil, nil
  end
  return data
end)

-- Video-CPU load injection, for the same deadline calibration: retarget the
-- jsr $5673e at $4052e through a stub that burns VINJECT DBRA iterations.
local function patch_video_inject()
  local rgn = machine.memory.regions[":maincpu"]
  local S = 0x7F700
  local w = { 0x2F07, 0x3E3C, VINJECT, 0x51CF, 0xFFFE, 0x2E1F,
              0x4EF9, 0x0005, 0x673E }
  for i, v in ipairs(w) do rgn:write_u16(S + (i-1)*2, v) end
  rgn:write_u16(0x40530, (S >> 16) & 0xffff)
  rgn:write_u16(0x40532, S & 0xffff)
end

-- ------------------------------------------------------- bus-cycle counters
-- The core's HUD reports dbg_vcyc / dbg_ecyc = completed bus cycles per frame
-- per CPU (AS falling edges).  To have anything to compare those against we
-- need the same count from MAME.  A WIDE read tap does see the m68k's opcode
-- fetches (a narrow one does not -- the direct-read cache is only bypassed for
-- a large enough region; verified by counting 0 hits on a 2-byte tap at $0308
-- while the handler ran every frame, and 15.5k hits/frame on a whole-ROM tap),
-- so taps over the entire address space give every bus cycle: fetches, data
-- reads and writes.  A long-word access on a 16-bit bus taps twice, which is
-- what the hardware counter sees too.
local vcyc, ecyc = 0, 0
_G.tap_ecyc_r = se:install_read_tap (0x000000, 0xFFFFFF, "ecycr", function(o,d,m) ecyc = ecyc + 1 return d end)
_G.tap_ecyc_w = se:install_write_tap(0x000000, 0xFFFFFF, "ecycw", function(o,d,m) ecyc = ecyc + 1 return d end)
_G.tap_vcyc_r = sm:install_read_tap (0x000000, 0xFFFFFF, "vcycr", function(o,d,m) vcyc = vcyc + 1 return d end)
_G.tap_vcyc_w = sm:install_write_tap(0x000000, 0xFFFFFF, "vcycw", function(o,d,m) vcyc = vcyc + 1 return d end)

-- video CPU: count vblank acks it performs ($360000 write inside its IRQ4)
local mainack = 0
_G.tap_ack = sm:install_write_tap(0x360000, 0x360001, "ack", function(off, data, mask)
  mainack = mainack + 1
  return data
end)

-------------------------------------------------------------------- driving
local io_ = machine.ioport
local function ff(nm)
  for _, p in pairs(io_.ports) do for n, f in pairs(p.fields) do if n == nm then return f end end end
end
local coin, b1, b2, b3 = ff("Coin 1"), ff("P1 Button 1"), ff("P1 Button 2"), ff("P1 Button 3")
local sx, sy = ff("AD Stick X"), ff("AD Stick Y")
local p2b1, p2b2, p2b3 = ff("P2 Button 1"), ff("P2 Button 2"), ff("P2 Button 3")
local sx2, sy2 = ff("AD Stick X 2"), ff("AD Stick Y 2")

------------------------------------------------------------------- CSV loop
local f = assert(io.open(OUT .. "/" .. TAG .. ".csv", "w"))
f:write("frame,time,bodies_started,bodies_ended,busy_us,last_dur_us,busy_cycles," ..
        "tick992,mainacks,straddle,spin_reads,vid_started,vid_ended,vid_busy_us," ..
        "vid_last_us,vcyc,ecyc,mo_objs,mo_tiles,mo_spans\n")

local n, vf = 0, 0
local injected = false
local vidpatched = false
_G.nb = emu.add_machine_frame_notifier(function()
  local t = machine.time:as_double()

  if MODE == "play" or MODE == "play1" then
    -- keep the machine fed with credits and keep restarting; hold fire and
    -- walk, so we spend as much time as possible in real level-1 combat.
    local c = (t % 12.0)
    coin:set_value(((c > 0.0 and c < 0.25) or (c > 0.5 and c < 0.75)) and 1 or 0)
    b1:set_value((vf % 4 < 2) and 1 or 0)              -- fire
    b2:set_value((vf % 90 < 4) and 1 or 0)             -- start / jump
    b3:set_value((vf % 53 < 3) and 1 or 0)
    if p2b1 and MODE == "play" then p2b1:set_value((vf % 4 < 2) and 1 or 0) end
    if p2b2 and MODE == "play" then p2b2:set_value(((vf + 45) % 90 < 4) and 1 or 0) end
    if p2b3 and MODE == "play" then p2b3:set_value(((vf + 26) % 53 < 3) and 1 or 0) end
    if sx2 and MODE == "play" then
      local ph2 = ((vf + 80) // 40) % 4
      sx2:set_value(({208, 128, 48, 128})[ph2 + 1])
      sy2:set_value(({128, 208, 128, 48})[ph2 + 1])
    end
    local ph = (vf // 40) % 4
    sx:set_value(({208, 128, 48, 128})[ph + 1])
    sy:set_value(({128, 208, 128, 48})[ph + 1])
  end

  if VINJECT > 0 and not vidpatched and t > INJECT_AT then
    patch_video_inject(); vidpatched = true
    print(string.format("VINJECT %d dbra iterations (~%d cycles) installed at t=%.2f", VINJECT, VINJECT*10, t))
  end

  if INJECT > 0 and not injected and t > INJECT_AT then
    -- stub in unused extra-ROM space (0x1CCAD..0x1FFFF is all zero in the ROM)
    local rgn = machine.memory.regions[":extra"]
    local S   = 0x1CD00
    local w   = { 0x2F07,                    -- move.l D7,-(A7)
                  0x3E3C, INJECT,            -- move.w #N,D7
                  0x51CF, 0xFFFE,            -- dbra   D7,*
                  0x2E1F,                    -- move.l (A7)+,D7
                  0x4EF9, 0x0000, 0xF792 }   -- jmp    $f792
    for i, v in ipairs(w) do rgn:write_u16(S + (i-1)*2, v) end
    rgn:write_u16(0x0934, (S >> 16) & 0xffff)   -- retarget the JSR at $0932
    rgn:write_u16(0x0936, S & 0xffff)
    injected = true
    print(string.format("INJECT %d dbra iterations (~%d cycles) installed at t=%.2f", INJECT, INJECT*10, t))
  end

  vf = vf + 1
  if t < T0 then
    -- every accumulator has to be cleared here too, or the first CSV row
    -- carries the whole warm-up period and poisons every per-frame mean
    busy_acc, body_started, body_ended, tick992, mainack, spin_reads = 0, 0, 0, 0, 0, 0
    m_busy, m_started, m_ended = 0.0, 0, 0
    vcyc, ecyc = 0, 0
    return
  end
  if t > TEND then f:close(); print("CADENCE ROWS " .. n); machine:exit(); return end
  n = n + 1

  -- A body that straddles the frame boundary must have its time split, or the
  -- frame it started in looks idle and the frame it ended in looks impossible.
  local straddle = 0
  if body_start then
    busy_acc  = busy_acc + (t - body_start)
    body_start = t
    straddle  = 1
    overrun   = overrun + 1
  end
  if m_start then m_busy = m_busy + (t - m_start); m_start = t end
  local o, ti, sp = crowd()
  f:write(string.format("%d,%.6f,%d,%d,%.2f,%.2f,%.0f,%d,%d,%d,%d,%d,%d,%.2f,%.2f,%d,%d,%d,%d,%d\n",
      n, t, body_started, body_ended, busy_acc * 1e6, last_dur * 1e6,
      busy_acc * CPUHZ, tick992, mainack, straddle, spin_reads,
      m_started, m_ended, m_busy * 1e6, m_last * 1e6, vcyc, ecyc, o, ti, sp))
  busy_acc, body_started, body_ended, tick992, mainack, spin_reads = 0, 0, 0, 0, 0, 0
  m_busy, m_started, m_ended = 0.0, 0, 0
  vcyc, ecyc = 0, 0
  if SNAP > 0 and (SNAP == 1 or n % SNAP == 1) then scr:snapshot() end
end)
