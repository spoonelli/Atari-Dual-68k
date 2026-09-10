-- Dump video RAM + palette + a screenshot for one or more frames, for the
-- offline renderers (render_scene.py for Escape, guts_render.py for Guts).
--   MAP=guts|eprom   video block at FFxxxx or 3Fxxxx
--   DUMPF=2400[,2700,...]   frames to dump (each into OUTDIR/f<N>/)
--   OUTDIR=...              run MAME with -snapshot_directory OUTDIR -snapname %i
--                           and pair the numbered PNGs with the folders by order
-- Pairing: video:snapshot() re-renders the screen from the RAM as it is at
-- the moment of the call, so the RAM is grabbed in the same frame_done
-- callback. (A previous-frame buffer, the fix scenedump2.lua needed for
-- -video none-less runs, pairs WORSE here: 94% vs 99% on the same frame.)
local OUT = os.getenv("OUTDIR") or "."
local MAP = os.getenv("MAP") or "guts"
local want = {}
local last = 0
for n in (os.getenv("DUMPF") or "2400"):gmatch("%d+") do want[tonumber(n)] = true; if tonumber(n) > last then last = tonumber(n) end end
local m = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]
local blocks
if MAP == "guts" then
  blocks = { {"pf",0xff8000,0x2000},{"pfext",0xff0000,0x2000},{"mo",0xffa000,0x2000},
             {"alpha_cfg_slip",0xffc000,0x1000},{"palette",0x3e0000,0x1000},{"work",0xffd000,0x3000} }
else
  blocks = { {"pf",0x3f0000,0x2000},{"pfext",0x3f8000,0x2000},{"mo",0x3f2000,0x2000},
             {"alpha_cfg_slip",0x3f4000,0x1000},{"palette",0x3e0000,0x1000},{"work",0x3f5000,0x3000} }
end
local function grab()
  local snap = {}
  for _, b in ipairs(blocks) do
    local t = {}
    for a = b[2], b[2] + b[3] - 1 do t[#t + 1] = string.char(sp:read_u8(a)) end
    snap[b[1]] = table.concat(t)
  end
  return snap
end
local function writeall(snap, dir)
  os.execute('mkdir -p "' .. dir .. '"')
  for _, b in ipairs(blocks) do
    local f = io.open(dir .. "/" .. b[1] .. ".bin", "wb"); f:write(snap[b[1]]); f:close()
  end
end
local frame = 0
emu.register_frame_done(function()
  frame = frame + 1
  if want[frame] then
    local dir = OUT .. "/f" .. frame
    writeall(grab(), dir)
    m.video:snapshot()
    print("SCENE DUMPED frame " .. frame)
  end
  if frame >= last + 2 then m:exit() end
end)
