-- Starts a game in a chosen stage, plays it with the scripted pad, and saves or loads
-- MAME save states. Works on dino and on the Mega Drive build: both run the same
-- program on the same work RAM.
-- env: TRACE_OUT       folder for level.csv, RAM dumps and snapshots
--      TRACE_FRAMES    frames to run (default 3600)
--      LEVEL           stage 0-7, held from power-on until play begins (see docs/05)
--      SAVE            name@frame or name@+frames (counted from the frame play begins)
--      LOAD            name: save state loaded on the first frame
--      SNAP_EVERY      snapshot and level.csv row every N frames (default 300)
--      DUMP_RAM=1      also write work RAM beside each snapshot
--      HOLD            hex address=value rewritten every frame; two digits a byte, four a word
--                      (ffb2e0=0064 keeps player 1's health full)
--      POKE            hex address=value@frame, written once
--      PLAY=none       no pad once play has begun
--      STOP_AFTER      leave this many frames after play begins (for making states)
local out_dir = os.getenv("TRACE_OUT") or "."
local max_frames = tonumber(os.getenv("TRACE_FRAMES") or "3600")
local every = tonumber(os.getenv("SNAP_EVERY") or "300")
local level = tonumber(os.getenv("LEVEL") or "")
local load_name = os.getenv("LOAD")
local dump_ram = os.getenv("DUMP_RAM") == "1"
local play = os.getenv("PLAY") ~= "none"
local stop_after = tonumber(os.getenv("STOP_AFTER") or "")
local cpu = manager.machine.devices[":maincpu"]
local prog = cpu.spaces["program"]

local STEPS, IN_GAME, MODE, STAGE, AREA = 0xff8000, 0xff84cc, 0xff84d0, 0xff84d9, 0xff8786
local P1_ACTIVE, P1_X, P1_HEALTH = 0xffb274, 0xffb27c, 0xffb2e0

local function write(a, v, digits)
  if digits > 2 then prog:write_u16(a, v) else prog:write_u8(a, v) end
end
local holds, pokes, saves = {}, {}, {}
for a, v in string.gmatch(os.getenv("HOLD") or "", "(%x+)=(%x+)") do holds[#holds + 1] = { tonumber(a, 16), tonumber(v, 16), #v } end
for a, v, f in string.gmatch(os.getenv("POKE") or "", "(%x+)=(%x+)@(%d+)") do pokes[#pokes + 1] = { tonumber(a, 16), tonumber(v, 16), #v, tonumber(f) } end
for n, rel, f in string.gmatch(os.getenv("SAVE") or "", "([%w_]+)@(%+?)(%d+)") do saves[#saves + 1] = { n, rel == "+", tonumber(f) } end

local arcade = { coin = "Coin 1", start = "1 Player Start", right = "P1 Right", left = "P1 Left", up = "P1 Up", down = "P1 Down", attack = "P1 Button 1", jump = "P1 Button 2" }
local md = { coin = "P1 A", start = "P1 Start", right = "P1 Right", left = "P1 Left", up = "P1 Up", down = "P1 Down", attack = "P1 B", jump = "P1 C" }
local function field(name)
  for _, p in pairs(manager.machine.ioport.ports) do
    if p.fields[name] then return p.fields[name] end
  end
end
local names = field("Coin 1") and arcade or md
local inputs = {}
for k, n in pairs(names) do inputs[k] = field(n) end
local function press(k, on)
  if inputs[k] then inputs[k]:set_value(on and 1 or 0) end
end

local csv = io.open(out_dir .. "/level.csv", "w")
csv:write("frame,since_play,stage,area,mode,in_game,steps,p1_active,p1_health,p1_x,pc\n")
local frame, began = 0, nil
local function row()
  csv:write(string.format("%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%06x\n", frame, began and frame - began or -1,
    prog:read_u8(STAGE), prog:read_u8(AREA), prog:read_u8(MODE), prog:read_u8(IN_GAME),
    prog:read_u16(STEPS), prog:read_u8(P1_ACTIVE), prog:read_u16(P1_HEALTH), prog:read_u16(P1_X), cpu.state["PC"].value))
  csv:flush()
end

local function playing()
  return prog:read_u8(IN_GAME) == 1 and prog:read_u8(MODE) == 12
end

local errs = 0
local function on_frame()
  frame = frame + 1
  if frame == 1 and load_name then
    manager.machine:load(load_name)
    began = 1
    return
  end
  for _, h in ipairs(holds) do write(h[1], h[2], h[3]) end
  for _, p in ipairs(pokes) do if p[4] == frame then write(p[1], p[2], p[3]) end end
  if not began then
    local cyc = frame % 120
    press("coin", cyc < 6)
    press("start", cyc >= 60 and cyc < 66)
    press("attack", cyc >= 90 and cyc < 96)
    if level then prog:write_u8(STAGE, level) end
    if playing() then
      began = frame
      print(string.format("play began at frame %d", frame))
      press("coin", false)
      press("start", false)
    end
  elseif play then
    local t = frame - began
    local cyc = t % 300
    local walk = cyc < 200
    local fight = cyc >= 200 and cyc < 280
    press("right", walk)
    press("left", cyc >= 280)
    press("up", fight and t % 80 < 20)
    press("down", fight and t % 80 >= 40 and t % 80 < 55)
    press("attack", t % 12 < 4)
    press("jump", walk and t % 140 >= 70 and t % 140 < 76)
  end
  for _, s in ipairs(saves) do
    local at = s[2] and began and began + s[3] or not s[2] and s[3]
    if at == frame then
      manager.machine:save(s[1])
      print(string.format("saved %s at frame %d", s[1], frame))
    end
  end
  if frame % every == 0 then
    row()
    if dump_ram then
      local f = io.open(string.format("%s/ram_%06d.ram", out_dir, frame), "wb")
      f:write(prog:read_range(0xff8000, 0xffffff, 8))
      f:close()
    end
    manager.machine.video:snapshot()
  end
  if frame >= max_frames or (stop_after and began and frame >= began + stop_after) then
    row()
    csv:close()
    manager.machine:exit()
  end
end
sub = emu.add_machine_frame_notifier(function()
  local ok, e = pcall(on_frame)
  if not ok and errs < 5 then errs = errs + 1 print("level error: " .. tostring(e)) end
end)
