-- dump native screen pixels while scripting level-1 play
local OUT   = os.getenv("PF_OUT")  or "/tmp/pf"
local T0    = tonumber(os.getenv("PF_T0")  or "40")
local TEND  = tonumber(os.getenv("PF_TEND") or "130")
local EVERY = tonumber(os.getenv("PF_EVERY") or "15")

local scr
for _, s in pairs(manager.machine.screens) do scr = s break end
print(string.format("SCREEN %dx%d fmt=%s", scr.width, scr.height, tostring(scr.format)))

local io_ = manager.machine.ioport
local function ff(nm)
  for _, p in pairs(io_.ports) do for n, f in pairs(p.fields) do if n == nm then return f end end end
end
local coin, b1, b2, b3 = ff("Coin 1"), ff("P1 Button 1"), ff("P1 Button 2"), ff("P1 Button 3")
local sx, sy = ff("AD Stick X"), ff("AD Stick Y")

local fh = assert(io.open(OUT .. "/frames.raw", "wb"))
local idx = assert(io.open(OUT .. "/frames.txt", "w"))
local vf, ndump = 0, 0

_G.nb = emu.add_machine_frame_notifier(function()
  local t = manager.machine.time:as_double()
  local c = (t % 12.0)
  coin:set_value(((c > 0.0 and c < 0.25) or (c > 0.5 and c < 0.75)) and 1 or 0)
  b1:set_value((vf % 4 < 2) and 1 or 0)
  b2:set_value((vf % 90 < 4) and 1 or 0)
  b3:set_value((vf % 53 < 3) and 1 or 0)
  local ph = (vf // 40) % 4
  sx:set_value(({208, 128, 48, 128})[ph + 1])
  sy:set_value(({128, 208, 128, 48})[ph + 1])
  vf = vf + 1

  if t >= T0 and t <= TEND and (vf % EVERY == 0) then
    fh:write(scr:pixels())
    idx:write(string.format("%d %.4f\n", ndump, t))
    ndump = ndump + 1
  end
  if t > TEND then
    fh:close(); idx:close()
    print(string.format("DUMPED %d frames of %dx%d", ndump, scr.width, scr.height))
    manager.machine:exit()
  end
end)
