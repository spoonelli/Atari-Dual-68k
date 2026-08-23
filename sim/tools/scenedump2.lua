-- scenedump2.lua : like scenedump.lua, but writes the video state as it was at
-- the END OF THE PREVIOUS FRAME.
--
-- MAME's eprom screen is VIDEO_UPDATE_BEFORE_VBLANK: frame N is composited
-- after its last visible scanline, and only then does the vblank IRQ4 handler
-- run and rewrite MO RAM for frame N+1. A machine frame notifier fires after
-- that handler, so reading RAM there gives frame N+1's state next to frame N's
-- snapshot. Buffering one frame removes that skew.
local OUT = os.getenv("SCENE_OUT") or "/tmp"
local IDX = tonumber(os.getenv("SCENE_IDX") or "108")
-- MOPLACE-3: shots are counted from SCENE_START seconds on. The default keeps
-- the in-game capture this was written for; set it below the attract/coin
-- sequence to capture a zero-scroll attract frame instead.
local TSTART = tonumber(os.getenv("SCENE_START") or "46.0")

local machine = manager.machine
local mm  = machine.devices[":maincpu"].spaces["program"]
local scr = machine.screens[":screen"]
local ioport = machine.ioport

local function ff(name)
    for _, p in pairs(ioport.ports) do
        for n, f in pairs(p.fields) do if n == name then return f end end
    end
end
local coin, start = ff("Coin 1"), ff("P1 Button 2")

local REGIONS = {
    { "scene_pf.bin",    0x3F0000, 0x3F1FFF },
    { "scene_pfext.bin", 0x3F8000, 0x3F9FFF },
    { "scene_al.bin",    0x3F4000, 0x3F4F7F },
    { "scene_mo.bin",    0x3F2000, 0x3F3FFF },
    { "scene_slip.bin",  0x3F4F80, 0x3F4FFF },
    { "scene_pal.bin",   0x3E0000, 0x3E0FFF },
}

local function grab()
    local snap = {}
    for i, r in ipairs(REGIONS) do
        local t = {}
        local k = 0
        for a = r[2], r[3], 2 do
            local w = mm:read_u16(a)
            k = k + 1
            t[k] = string.char(math.floor(w / 256) % 256, w % 256)
        end
        snap[i] = table.concat(t)
    end
    snap.xs = (mm:read_u16(0x3F4F00) >> 7) & 0x1ff
    snap.ys = (mm:read_u16(0x3F4F02) >> 7) & 0x1ff
    return snap
end

local phase, n, shots, done, prev, buffering = 0, 0, 0, false, nil, false
_G.nb = emu.add_machine_frame_notifier(function()
    local t = machine.time:as_double()
    if phase == 0 and t > 8.0 then coin:set_value(1);  phase = 1
    elseif phase == 1 and t > 8.3 then coin:set_value(0); phase = 2
    elseif phase == 2 and t > 8.6 then coin:set_value(1); phase = 3
    elseif phase == 3 and t > 8.9 then coin:set_value(0); phase = 4
    elseif phase == 4 and t > 10.0 then start:set_value(1); phase = 5
    elseif phase == 5 and t > 10.4 then start:set_value(0); phase = 6
    elseif phase == 6 and t > 45.0 then start:set_value(1); phase = 7
    elseif phase == 7 and t > 45.4 then start:set_value(0); phase = 8 end

    n = n + 1
    if t <= TSTART then return end

    if n % 30 == 0 then
        if shots == IDX and not done and prev then
            done = true
            for i, r in ipairs(REGIONS) do
                local f = assert(io.open(OUT .. "/" .. r[1], "wb"))
                f:write(prev[i]); f:close()
            end
            local f = assert(io.open(OUT .. "/scene_info.txt", "w"))
            f:write(string.format("t=%f\nidx=%d\nxscroll=%d\nyscroll=%d\n",
                                  t, IDX, prev.xs, prev.ys))
            f:close()
            scr:snapshot()
            print(string.format("SCENE DUMPED (prev-frame state) idx=%d t=%f xs=%d ys=%d",
                                IDX, t, prev.xs, prev.ys))
        end
        if shots >= IDX - 1 then buffering = true end
        shots = shots + 1
    end

    if buffering and not done then prev = grab() end
end)
print("scenedump2 armed, IDX=" .. IDX .. " OUT=" .. OUT)
