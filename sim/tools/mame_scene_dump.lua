-- Dump the video RAM blocks + palette + a screenshot at frame DUMPF, for the
-- offline priority/MO model. MAP=guts -> FFxxxx block, MAP=eprom -> 3Fxxxx.
local F = tonumber(os.getenv("DUMPF") or "2400")
local OUT = os.getenv("OUTDIR") or "."
local MAP = os.getenv("MAP") or "guts"
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
local frame = 0
emu.register_frame_done(function()
  frame = frame + 1
  if frame == F then
    for _,b in ipairs(blocks) do
      local f = io.open(OUT.."/"..b[1]..".bin","wb")
      local t = {}
      for a = b[2], b[2]+b[3]-1 do t[#t+1] = string.char(sp:read_u8(a)) end
      f:write(table.concat(t)); f:close()
    end
    m.video:snapshot()
    print("SCENE DUMPED at frame "..frame)
  end
  if frame >= F + 2 then m:exit() end
end)
